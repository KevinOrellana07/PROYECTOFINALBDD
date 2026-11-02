"""
AutoAudit - Servidor web (FastAPI)

Cada usuario inicia sesión con SU usuario de PostgreSQL. Todas las operaciones
se ejecutan con esa conexión, de modo que:
  * los permisos los decide PostgreSQL (solo autoaudit_admin configura),
  * la bitácora registra al usuario real que hizo el cambio.

Ejecutar:  uvicorn main:app --host 0.0.0.0 --port 8000   (ver run.sh)
"""
from __future__ import annotations

import csv
import io
import json
import os
import secrets
import time
from contextlib import contextmanager
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any, Optional

import psycopg
from psycopg import sql
from psycopg.rows import dict_row
from psycopg.types.json import set_json_loads
from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Configuración (variables de entorno o archivo .env junto a este script)
# ---------------------------------------------------------------------------
BASE = Path(__file__).resolve().parent


def _cargar_env() -> None:
    env = BASE / ".env"
    if env.exists():
        for linea in env.read_text(encoding="utf-8").splitlines():
            linea = linea.strip()
            if linea and not linea.startswith("#") and "=" in linea:
                k, v = linea.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


_cargar_env()
# jsonb numérico como Decimal para no perder decimales (1500.00 y no 1500.0)
set_json_loads(lambda s: json.loads(s, parse_float=Decimal))
DB_HOST = os.getenv("AUTOAUDIT_DB_HOST", "127.0.0.1")
DB_PORT = int(os.getenv("AUTOAUDIT_DB_PORT", "5432"))
DB_NAME = os.getenv("AUTOAUDIT_DB_NAME", "autoaudit_db")
SESION_MINUTOS = int(os.getenv("AUTOAUDIT_SESION_MINUTOS", "120"))
COOKIE = "autoaudit_sesion"

app = FastAPI(title="AutoAudit", version="1.0", docs_url="/api/docs", redoc_url=None)

# token -> {usuario, clave, expira, es_admin, es_consulta}
SESIONES: dict[str, dict[str, Any]] = {}


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
def _json_default(o: Any):
    if isinstance(o, (datetime, date)):
        return o.isoformat()
    if isinstance(o, Decimal):
        return str(o)
    if isinstance(o, (bytes, memoryview)):
        return "\\x" + bytes(o).hex()
    return str(o)


def responder(data: Any, status: int = 200) -> Response:
    return Response(json.dumps(data, default=_json_default, ensure_ascii=False),
                    status_code=status, media_type="application/json")


def ip_cliente(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for")
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else "desconocida"


def conectar(usuario: str, clave: str) -> psycopg.Connection:
    return psycopg.connect(host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
                           user=usuario, password=clave, row_factory=dict_row,
                           application_name="AutoAudit Web", connect_timeout=5)


def traducir_error(e: Exception) -> HTTPException:
    """Convierte errores de PostgreSQL en mensajes legibles para la interfaz."""
    if isinstance(e, psycopg.Error) and getattr(e, "diag", None):
        d = e.diag
        msg = d.message_primary or str(e)
        if d.message_hint:
            msg += f" ({d.message_hint})"
        codigo = 403 if d.sqlstate == "42501" else 400
        return HTTPException(codigo, msg)
    return HTTPException(500, str(e))


class Sesion:
    def __init__(self, token: str, datos: dict, request: Request):
        self.token = token
        self.usuario: str = datos["usuario"]
        self.clave: str = datos["clave"]
        self.es_admin: bool = datos["es_admin"]
        self.es_consulta: bool = datos["es_consulta"]
        self.ip = ip_cliente(request)

    @contextmanager
    def db(self):
        """Conexión con las credenciales del usuario + contexto para la bitácora."""
        try:
            con = conectar(self.usuario, self.clave)
        except psycopg.Error as e:
            raise HTTPException(503, f"No se pudo conectar a PostgreSQL: {e}")
        try:
            with con.cursor() as cur:
                cur.execute("SELECT set_config('autoaudit.equipo', %s, false),"
                            "       set_config('autoaudit.usuario_app', %s, false)",
                            (f"web {self.ip}", self.usuario))
            yield con
            con.commit()
        except HTTPException:
            con.rollback()
            raise
        except Exception as e:
            con.rollback()
            raise traducir_error(e)
        finally:
            con.close()

    def consultar(self, query, params=None) -> list[dict]:
        with self.db() as con, con.cursor() as cur:
            cur.execute(query, params)
            return cur.fetchall() if cur.description else []

    def uno(self, query, params=None) -> Optional[dict]:
        filas = self.consultar(query, params)
        return filas[0] if filas else None


def sesion_actual(request: Request) -> Sesion:
    token = request.cookies.get(COOKIE)
    datos = SESIONES.get(token or "")
    if not datos or datos["expira"] < time.time():
        SESIONES.pop(token or "", None)
        raise HTTPException(401, "Sesión no iniciada o expirada")
    datos["expira"] = time.time() + SESION_MINUTOS * 60
    return Sesion(token, datos, request)


def solo_admin(s: Sesion = Depends(sesion_actual)) -> Sesion:
    if not s.es_admin:
        raise HTTPException(403, "Solo los administradores de auditoría pueden realizar esta acción")
    return s


# ---------------------------------------------------------------------------
# Autenticación
# ---------------------------------------------------------------------------
class Login(BaseModel):
    usuario: str
    clave: str


@app.post("/api/login")
def login(body: Login, response: Response):
    try:
        with conectar(body.usuario, body.clave) as con, con.cursor() as cur:
            cur.execute("""
                SELECT pg_has_role(current_user, 'autoaudit_admin', 'MEMBER')    AS es_admin,
                       pg_has_role(current_user, 'autoaudit_consulta', 'MEMBER') AS es_consulta,
                       COALESCE((SELECT rolsuper FROM pg_roles WHERE rolname = current_user), false) AS su
            """)
            r = cur.fetchone()
    except psycopg.OperationalError as e:
        texto = str(e)
        if "password authentication failed" in texto or "autenticación" in texto:
            raise HTTPException(401, "Usuario o contraseña incorrectos")
        raise HTTPException(503, f"No se pudo conectar a PostgreSQL ({DB_HOST}:{DB_PORT}): {texto.strip()}")

    token = secrets.token_urlsafe(32)
    SESIONES[token] = {
        "usuario": body.usuario, "clave": body.clave,
        "es_admin": bool(r["es_admin"] or r["su"]),
        "es_consulta": bool(r["es_consulta"] or r["es_admin"] or r["su"]),
        "expira": time.time() + SESION_MINUTOS * 60,
    }
    response.set_cookie(COOKIE, token, httponly=True, samesite="strict", max_age=SESION_MINUTOS * 60)
    return {"usuario": body.usuario, "es_admin": SESIONES[token]["es_admin"],
            "es_consulta": SESIONES[token]["es_consulta"]}


@app.post("/api/logout")
def logout(request: Request, response: Response):
    SESIONES.pop(request.cookies.get(COOKIE, ""), None)
    response.delete_cookie(COOKIE)
    return {"ok": True}


@app.get("/api/sesion")
def sesion(s: Sesion = Depends(sesion_actual)):
    return {"usuario": s.usuario, "es_admin": s.es_admin, "es_consulta": s.es_consulta, "ip": s.ip,
            "servidor": f"{DB_HOST}:{DB_PORT}/{DB_NAME}"}


def requiere_consulta(s: Sesion = Depends(sesion_actual)) -> Sesion:
    if not s.es_consulta:
        raise HTTPException(403, "Su usuario no tiene acceso a la bitácora de auditoría "
                                 "(puede usar el módulo de Datos)")
    return s


# ---------------------------------------------------------------------------
# Panel
# ---------------------------------------------------------------------------
@app.get("/api/estadisticas")
def estadisticas(dias: int = 14, s: Sesion = Depends(requiere_consulta)):
    r = s.uno("SELECT auditoria.fn_estadisticas(%s) AS e", (dias,))
    recientes = s.consultar("""
        SELECT encabezado_id, fecha_hora, operacion, esquema, tabla, usuario,
               string_agg(columna, ', ' ORDER BY columna) AS columnas, llave_registro
          FROM auditoria.v_bitacora
         WHERE encabezado_id IN (SELECT encabezado_id FROM auditoria.bitacora_encabezado
                                  ORDER BY encabezado_id DESC LIMIT 8)
         GROUP BY encabezado_id, fecha_hora, operacion, esquema, tabla, usuario, llave_registro
         ORDER BY encabezado_id DESC""")
    return responder({**r["e"], "recientes": recientes})


# ---------------------------------------------------------------------------
# Diccionario de datos
# ---------------------------------------------------------------------------
@app.get("/api/diccionario/tablas")
def dic_tablas(s: Sesion = Depends(requiere_consulta)):
    return responder(s.consultar("""
        SELECT tabla_oid, esquema, tabla, comentario, propietario, filas_estimadas, tamano,
               num_columnas, tiene_pk, tabla_id, estado_auditoria
          FROM auditoria.v_dic_tablas ORDER BY esquema, tabla"""))


@app.get("/api/diccionario/{esquema}/{tabla}/columnas")
def dic_columnas(esquema: str, tabla: str, s: Sesion = Depends(requiere_consulta)):
    cols = s.consultar("""
        SELECT d.posicion, d.columna, d.tipo_dato, d.admite_nulos, d.valor_defecto, d.comentario,
               d.es_pk, d.es_fk, d.columna_id, d.auditada,
               COALESCE(bool_or(cf.activo) FILTER (WHERE cf.evento_id = 1), false) AND d.auditada AS ev_insert,
               COALESCE(bool_or(cf.activo) FILTER (WHERE cf.evento_id = 2), false) AND d.auditada AS ev_update,
               COALESCE(bool_or(cf.activo) FILTER (WHERE cf.evento_id = 3), false) AND d.auditada AS ev_delete
          FROM auditoria.v_dic_columnas d
          LEFT JOIN auditoria.configuracion_auditoria cf ON cf.columna_id = d.columna_id
         WHERE d.esquema = %s AND d.tabla = %s
         GROUP BY d.posicion, d.columna, d.tipo_dato, d.admite_nulos, d.valor_defecto, d.comentario,
                  d.es_pk, d.es_fk, d.columna_id, d.auditada
         ORDER BY d.posicion""", (esquema, tabla))
    if not cols:
        raise HTTPException(404, f"La tabla {esquema}.{tabla} no existe en el diccionario")
    llaves = s.consultar("SELECT restriccion, tipo, columnas, tabla_referenciada, definicion "
                         "FROM auditoria.v_dic_llaves WHERE esquema = %s AND tabla = %s", (esquema, tabla))
    triggers = s.consultar("SELECT trigger_nombre, funcion, habilitado, es_autoaudit, definicion "
                           "FROM auditoria.v_dic_triggers WHERE esquema = %s AND tabla = %s", (esquema, tabla))
    estado = s.uno("SELECT * FROM auditoria.v_estado_auditoria WHERE esquema = %s AND tabla = %s "
                   "AND estado <> 'HUERFANA'", (esquema, tabla))
    return responder({"columnas": cols, "llaves": llaves, "triggers": triggers, "estado": estado})


# ---------------------------------------------------------------------------
# Configuración de auditoría
# ---------------------------------------------------------------------------
@app.get("/api/configuracion")
def configuracion(s: Sesion = Depends(requiere_consulta)):
    return responder(s.consultar("SELECT * FROM auditoria.v_estado_auditoria ORDER BY esquema, tabla"))


class ColumnaCfg(BaseModel):
    columna: str
    insert: bool = False
    update: bool = False
    delete: bool = False


class TablaCfg(BaseModel):
    descripcion: Optional[str] = None
    columnas: list[ColumnaCfg]
    aplicar: bool = True


@app.post("/api/configuracion/{esquema}/{tabla}")
def guardar_configuracion(esquema: str, tabla: str, body: TablaCfg, s: Sesion = Depends(solo_admin)):
    marcadas = {c.columna: c for c in body.columnas}
    with s.db() as con, con.cursor() as cur:
        cur.execute("SELECT auditoria.fn_registrar_tabla(%s, %s, %s) AS id", (esquema, tabla, body.descripcion))
        tabla_id = cur.fetchone()["id"]
        # columnas existentes en el diccionario + las ya configuradas
        cur.execute("SELECT columna, columna_id FROM auditoria.v_dic_columnas "
                    "WHERE esquema = %s AND tabla = %s", (esquema, tabla))
        existentes = cur.fetchall()
        for c in body.columnas:
            if c.columna not in {e["columna"] for e in existentes}:
                raise HTTPException(400, f"La columna {c.columna} no existe en {esquema}.{tabla}")
        for e in existentes:
            c = marcadas.get(e["columna"])
            if c is None and e["columna_id"] is None:
                continue  # nunca configurada y sigue sin marcar
            cur.execute("SELECT auditoria.fn_configurar_columna(%s,%s,%s,%s,%s,%s)",
                        (esquema, tabla, e["columna"],
                         bool(c and c.insert), bool(c and c.update), bool(c and c.delete)))
        resultado = {"exito": True, "mensaje": "Configuración guardada", "tabla_id": tabla_id}
        if body.aplicar:
            cur.execute("SELECT activa FROM auditoria.tabla_auditada WHERE tabla_id = %s", (tabla_id,))
            if not cur.fetchone()["activa"]:
                cur.execute("SELECT auditoria.fn_activar_tabla(%s, true) AS r", (tabla_id,))
            else:
                cur.execute("SELECT auditoria.fn_generar_trigger(%s) AS r", (tabla_id,))
            resultado = {**cur.fetchone()["r"], "tabla_id": tabla_id}
    return responder(resultado)


@app.get("/api/configuracion/{tabla_id}/sql")
def vista_previa_sql(tabla_id: int, s: Sesion = Depends(requiere_consulta)):
    validacion = s.consultar("SELECT * FROM auditoria.fn_validar_configuracion(%s)", (tabla_id,))
    try:
        codigo = s.uno("SELECT auditoria.fn_construir_sql_trigger(%s) AS sql", (tabla_id,))["sql"]
    except HTTPException as e:
        codigo = f"-- No se puede generar el código: {e.detail}"
    actual = s.uno("SELECT sql_generado, fecha_generacion FROM auditoria.tabla_auditada WHERE tabla_id = %s",
                   (tabla_id,))
    return responder({"validacion": validacion, "sql": codigo, "aplicado": actual})


class Activar(BaseModel):
    activa: bool


@app.post("/api/configuracion/{tabla_id}/activar")
def activar(tabla_id: int, body: Activar, s: Sesion = Depends(solo_admin)):
    return responder(s.uno("SELECT auditoria.fn_activar_tabla(%s, %s) AS r", (tabla_id, body.activa))["r"])


@app.post("/api/configuracion/{tabla_id}/regenerar")
def regenerar(tabla_id: int, s: Sesion = Depends(solo_admin)):
    return responder(s.uno("SELECT auditoria.fn_generar_trigger(%s) AS r", (tabla_id,))["r"])


@app.post("/api/configuracion/regenerar-todos")
def regenerar_todos(s: Sesion = Depends(solo_admin)):
    return responder(s.consultar("SELECT * FROM auditoria.fn_regenerar_todos()"))


@app.delete("/api/configuracion/{tabla_id}")
def eliminar_configuracion(tabla_id: int, s: Sesion = Depends(solo_admin)):
    return responder(s.uno("SELECT auditoria.fn_eliminar_configuracion(%s) AS r", (tabla_id,))["r"])


# ---------------------------------------------------------------------------
# Bitácora y consultas históricas
# ---------------------------------------------------------------------------
def _filtros(request: Request) -> dict:
    q = request.query_params
    def v(k):
        val = q.get(k)
        return val if val not in (None, "", "todos") else None
    lim = v("limite")
    return {"usuario": v("usuario"), "esquema": v("esquema"), "tabla": v("tabla"),
            "columna": v("columna"), "operacion": v("operacion"),
            "desde": v("desde"), "hasta": v("hasta"),
            "limite": min(int(lim), 50000) if lim else 500}


def _consulta_bitacora(s: Sesion, f: dict) -> list[dict]:
    hasta = f["hasta"]
    if hasta and len(hasta) == 10:              # fecha sin hora => incluir el día completo
        hasta = f"{hasta} 23:59:59.999999"
    return s.consultar("""
        SELECT encabezado_id, detalle_id, fecha_hora, operacion, esquema, tabla, columna,
               valor_anterior, valor_nuevo, llave_registro, usuario, usuario_aplicacion,
               direccion_ip, equipo, aplicacion, transaccion_id
          FROM auditoria.fn_consultar_bitacora(
                 p_usuario => %(usuario)s, p_esquema => %(esquema)s, p_tabla => %(tabla)s,
                 p_columna => %(columna)s, p_operacion => %(operacion)s,
                 p_desde => %(desde)s::timestamptz, p_hasta => %(hasta)s::timestamptz,
                 p_limite => %(limite)s)""", {**f, "hasta": hasta})


@app.get("/api/bitacora")
def bitacora(request: Request, s: Sesion = Depends(requiere_consulta)):
    return responder(_consulta_bitacora(s, _filtros(request)))


@app.get("/api/bitacora/operacion/{encabezado_id}")
def detalle_operacion(encabezado_id: int, s: Sesion = Depends(requiere_consulta)):
    enc = s.uno("""
        SELECT e.encabezado_id, e.fecha_hora, ev.codigo AS operacion, t.esquema, t.tabla,
               e.llave_registro, e.datos_anteriores, e.datos_nuevos, e.transaccion_id,
               u.nombre_usuario AS usuario, e.usuario_aplicacion,
               s.direccion_ip, s.equipo, s.aplicacion
          FROM auditoria.bitacora_encabezado e
          JOIN auditoria.evento ev USING (evento_id)
          JOIN auditoria.tabla_auditada t USING (tabla_id)
          JOIN auditoria.usuario_auditado u USING (usuario_id)
          JOIN auditoria.estacion_trabajo s USING (estacion_id)
         WHERE e.encabezado_id = %s""", (encabezado_id,))
    if not enc:
        raise HTTPException(404, "Operación no encontrada")
    enc["detalle"] = s.consultar("""
        SELECT columna, valor_anterior, valor_nuevo, configuracion_id
          FROM auditoria.v_bitacora WHERE encabezado_id = %s ORDER BY detalle_id""", (encabezado_id,))
    enc["historial_registro"] = s.consultar("""
        SELECT encabezado_id, fecha_hora, operacion, usuario,
               string_agg(columna || ': ' || COALESCE(valor_anterior, '∅') || ' → ' || COALESCE(valor_nuevo, '∅'),
                          E'\\n' ORDER BY detalle_id) AS cambios
          FROM auditoria.fn_historial_registro(%s, %s, %s)
         GROUP BY encabezado_id, fecha_hora, operacion, usuario
         ORDER BY fecha_hora""", (enc["esquema"], enc["tabla"], json.dumps(enc["llave_registro"])))  \
        if enc["llave_registro"] else []
    return responder(enc)


@app.get("/api/historial/usuario/{usuario}")
def historial_usuario(usuario: str, desde: Optional[str] = None, hasta: Optional[str] = None,
                      s: Sesion = Depends(requiere_consulta)):
    return responder(s.consultar(
        "SELECT * FROM auditoria.fn_historial_usuario(%s, %s::timestamptz, %s::timestamptz) "
        "ORDER BY fecha_hora DESC, detalle_id DESC",
        (usuario, desde or None, hasta or None)))


@app.get("/api/historial/columna/{esquema}/{tabla}/{columna}")
def historial_columna(esquema: str, tabla: str, columna: str, desde: Optional[str] = None,
                      hasta: Optional[str] = None, s: Sesion = Depends(requiere_consulta)):
    return responder(s.consultar(
        "SELECT * FROM auditoria.fn_historial_columna(%s, %s, %s, %s::timestamptz, %s::timestamptz) "
        "ORDER BY fecha_hora DESC, detalle_id DESC",
        (esquema, tabla, columna, desde or None, hasta or None)))


@app.get("/api/catalogos")
def catalogos(s: Sesion = Depends(requiere_consulta)):
    """Listas para los filtros de la interfaz."""
    return responder({
        "usuarios": s.consultar("SELECT u.nombre_usuario AS usuario, r.operaciones, r.inserciones, "
                                "r.actualizaciones, r.eliminaciones, r.primera_actividad, r.ultima_actividad "
                                "FROM auditoria.usuario_auditado u "
                                "LEFT JOIN auditoria.v_resumen_usuarios r USING (usuario_id) "
                                "ORDER BY u.nombre_usuario"),
        "columnas": s.consultar("SELECT DISTINCT t.esquema, t.tabla, c.columna "
                                "FROM auditoria.columna_auditada c JOIN auditoria.tabla_auditada t USING (tabla_id) "
                                "ORDER BY 1, 2, 3"),
        "estaciones": s.consultar("SELECT st.*, (SELECT count(*) FROM auditoria.bitacora_encabezado e "
                                  "WHERE e.estacion_id = st.estacion_id) AS operaciones "
                                  "FROM auditoria.estacion_trabajo st ORDER BY estacion_id"),
    })


# ---------------------------------------------------------------------------
# Exportación de reportes (CSV, Excel, PDF)
# ---------------------------------------------------------------------------
COLS_REPORTE = [("fecha_hora", "Fecha/hora"), ("operacion", "Operación"), ("esquema", "Esquema"),
                ("tabla", "Tabla"), ("columna", "Columna"), ("valor_anterior", "Valor anterior"),
                ("valor_nuevo", "Valor nuevo"), ("llave_registro", "Llave"), ("usuario", "Usuario"),
                ("direccion_ip", "IP"), ("equipo", "Equipo"), ("aplicacion", "Aplicación")]


def _valor(v):
    if v is None:
        return ""
    if isinstance(v, datetime):
        return v.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False)
    return str(v)


@app.get("/api/bitacora/exportar")
def exportar(request: Request, formato: str = "csv", s: Sesion = Depends(requiere_consulta)):
    f = _filtros(request)
    if not request.query_params.get("limite"):
        f["limite"] = 50000
    filas = _consulta_bitacora(s, f)
    marca = datetime.now().strftime("%Y%m%d_%H%M%S")
    nombre = f"bitacora_autoaudit_{marca}"
    filtros_txt = ", ".join(f"{k}={v}" for k, v in f.items() if v and k != "limite") or "sin filtros"

    if formato == "csv":
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow([t for _, t in COLS_REPORTE])
        for r in filas:
            w.writerow([_valor(r[k]) for k, _ in COLS_REPORTE])
        datos = ("﻿" + buf.getvalue()).encode("utf-8")   # BOM para que Excel lea acentos
        return Response(datos, media_type="text/csv",
                        headers={"Content-Disposition": f'attachment; filename="{nombre}.csv"'})

    if formato == "xlsx":
        from openpyxl import Workbook
        from openpyxl.styles import Font, PatternFill, Alignment
        wb = Workbook()
        ws = wb.active
        ws.title = "Bitácora"
        ws.append(["AutoAudit - Reporte de bitácora"])
        ws["A1"].font = Font(bold=True, size=14)
        ws.append([f"Generado: {datetime.now():%Y-%m-%d %H:%M} por {s.usuario}  |  Filtros: {filtros_txt}"])
        ws.append([])
        ws.append([t for _, t in COLS_REPORTE])
        for c in ws[4]:
            c.font = Font(bold=True, color="FFFFFF")
            c.fill = PatternFill("solid", fgColor="1F3A5F")
            c.alignment = Alignment(horizontal="center")
        for r in filas:
            ws.append([r[k] if isinstance(r[k], datetime) and not r[k].tzinfo else _valor(r[k])
                       for k, _ in COLS_REPORTE])
        anchos = [20, 10, 10, 14, 16, 24, 24, 18, 14, 15, 18, 18]
        for i, a in enumerate(anchos):
            ws.column_dimensions[chr(65 + i)].width = a
        ws.freeze_panes = "A5"
        ws.auto_filter.ref = f"A4:{chr(64 + len(COLS_REPORTE))}{4 + len(filas)}"
        buf = io.BytesIO()
        wb.save(buf)
        return Response(buf.getvalue(),
                        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                        headers={"Content-Disposition": f'attachment; filename="{nombre}.xlsx"'})

    if formato == "pdf":
        from reportlab.lib import colors
        from reportlab.lib.pagesizes import landscape, letter
        from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
        from reportlab.lib.units import cm
        from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

        buf = io.BytesIO()
        doc = SimpleDocTemplate(buf, pagesize=landscape(letter), leftMargin=1 * cm, rightMargin=1 * cm,
                                topMargin=1 * cm, bottomMargin=1 * cm, title="Reporte AutoAudit")
        est = getSampleStyleSheet()
        celda = ParagraphStyle("c", parent=est["Normal"], fontSize=7, leading=8.5)
        cols = [("fecha_hora", "Fecha/hora", 3.0), ("operacion", "Op.", 1.4), ("tabla", "Tabla", 2.6),
                ("columna", "Columna", 2.6), ("valor_anterior", "Anterior", 4.2),
                ("valor_nuevo", "Nuevo", 4.2), ("llave_registro", "Llave", 2.6),
                ("usuario", "Usuario", 2.2), ("direccion_ip", "IP / Equipo", 3.0)]
        datos = [[Paragraph(f"<b>{t}</b>", celda) for _, t, _ in cols]]
        for r in filas[:5000]:
            fila = []
            for k, _, _ in cols:
                v = _valor(r[k])
                if k == "tabla":
                    v = f"{r['esquema']}.{r['tabla']}"
                if k == "direccion_ip":
                    v = f"{r['direccion_ip']}<br/>{_valor(r['equipo'])}"
                else:
                    v = v.replace("&", "&amp;").replace("<", "&lt;")[:200]
                fila.append(Paragraph(v, celda))
            datos.append(fila)
        t = Table(datos, colWidths=[w * cm for _, _, w in cols], repeatRows=1)
        t.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1F3A5F")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#F1F4F8")]),
            ("GRID", (0, 0), (-1, -1), 0.25, colors.HexColor("#C9D1DB")),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ]))
        partes = [Paragraph("AutoAudit — Reporte de bitácora", est["Title"]),
                  Paragraph(f"Generado el {datetime.now():%Y-%m-%d %H:%M} por <b>{s.usuario}</b>. "
                            f"Filtros: {filtros_txt}. Registros: {len(filas)}"
                            + (" (se muestran los primeros 5000)" if len(filas) > 5000 else ""),
                            est["Normal"]),
                  Spacer(1, 0.4 * cm), t]
        doc.build(partes)
        return Response(buf.getvalue(), media_type="application/pdf",
                        headers={"Content-Disposition": f'attachment; filename="{nombre}.pdf"'})

    raise HTTPException(400, "Formato no soportado (use csv, xlsx o pdf)")


# ---------------------------------------------------------------------------
# Registro del generador y parámetros
# ---------------------------------------------------------------------------
@app.get("/api/log")
def log_generacion(limite: int = 200, s: Sesion = Depends(requiere_consulta)):
    return responder(s.consultar("""
        SELECT l.log_id, l.fecha_hora, l.accion, l.exito, l.mensaje, l.usuario, l.objeto,
               l.sql_ejecutado, t.esquema, t.tabla
          FROM auditoria.log_generacion l
          LEFT JOIN auditoria.tabla_auditada t USING (tabla_id)
         ORDER BY l.log_id DESC LIMIT %s""", (limite,)))


@app.get("/api/parametros")
def parametros(s: Sesion = Depends(requiere_consulta)):
    return responder(s.consultar("SELECT * FROM auditoria.parametro ORDER BY clave"))


class Parametro(BaseModel):
    valor: str


@app.put("/api/parametros/{clave}")
def guardar_parametro(clave: str, body: Parametro, s: Sesion = Depends(solo_admin)):
    s.consultar("SELECT auditoria.fn_set_parametro(%s, %s)", (clave, body.valor))
    return {"ok": True}


# ---------------------------------------------------------------------------
# Módulo de datos (simulador): CRUD genérico sobre tablas de negocio.
# Se ejecuta con los permisos del usuario conectado => PostgreSQL decide.
# ---------------------------------------------------------------------------
def _validar_tabla(s: Sesion, esquema: str, tabla: str) -> list[dict]:
    if esquema in ("auditoria", "pg_catalog", "information_schema"):
        raise HTTPException(403, "No se permite modificar tablas del sistema")
    cols = s.consultar("""
        SELECT a.attname AS columna, format_type(a.atttypid, a.atttypmod) AS tipo,
               a.attnotnull AS requerido, pg_get_expr(d.adbin, d.adrelid) AS defecto,
               COALESCE(a.attnum = ANY (k.conkey), false) AS es_pk, a.attidentity <> '' AS identidad
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
          LEFT JOIN pg_constraint k ON k.conrelid = c.oid AND k.contype = 'p'
         WHERE n.nspname = %s AND c.relname = %s AND a.attnum > 0 AND NOT a.attisdropped
         ORDER BY a.attnum""", (esquema, tabla))
    if not cols:
        raise HTTPException(404, "Tabla no encontrada")
    return cols


@app.get("/api/datos/tablas")
def datos_tablas(s: Sesion = Depends(sesion_actual)):
    return responder(s.consultar("""
        SELECT n.nspname AS esquema, c.relname AS tabla,
               has_table_privilege(c.oid, 'INSERT') AS puede_insertar,
               has_table_privilege(c.oid, 'UPDATE') AS puede_actualizar,
               has_table_privilege(c.oid, 'DELETE') AS puede_eliminar,
               EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = c.oid AND t.tgname = 'trg_autoaudit') AS auditada
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
           AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'auditoria', 'pg_toast', 'pruebas')
           AND n.nspname NOT LIKE 'pg_temp%%'
           AND has_table_privilege(c.oid, 'SELECT')
         ORDER BY 1, 2"""))


@app.get("/api/datos/{esquema}/{tabla}")
def datos_filas(esquema: str, tabla: str, limite: int = 200, s: Sesion = Depends(sesion_actual)):
    cols = _validar_tabla(s, esquema, tabla)
    pk = [c["columna"] for c in cols if c["es_pk"]] or [cols[0]["columna"]]
    q = sql.SQL("SELECT * FROM {}.{} ORDER BY {} LIMIT %s").format(
        sql.Identifier(esquema), sql.Identifier(tabla), sql.SQL(", ").join(map(sql.Identifier, pk)))
    return responder({"columnas": cols, "filas": s.consultar(q, (min(limite, 2000),))})


class Fila(BaseModel):
    valores: dict[str, Any]
    llave: Optional[dict[str, Any]] = None


def _where_llave(llave: dict[str, Any]):
    if not llave:
        raise HTTPException(400, "Se requiere la llave del registro")
    return sql.SQL(" AND ").join(sql.SQL("{} = %s").format(sql.Identifier(k)) for k in llave)


@app.post("/api/datos/{esquema}/{tabla}")
def datos_insertar(esquema: str, tabla: str, body: Fila, s: Sesion = Depends(sesion_actual)):
    cols = {c["columna"] for c in _validar_tabla(s, esquema, tabla)}
    valores = {k: (None if v == "" else v) for k, v in body.valores.items() if k in cols and v not in ("", None)}
    if not valores:
        raise HTTPException(400, "Ingrese al menos un valor")
    q = sql.SQL("INSERT INTO {}.{} ({}) VALUES ({}) RETURNING *").format(
        sql.Identifier(esquema), sql.Identifier(tabla),
        sql.SQL(", ").join(map(sql.Identifier, valores)),
        sql.SQL(", ").join(sql.Placeholder() * len(valores)))
    return responder(s.uno(q, list(valores.values())))


@app.put("/api/datos/{esquema}/{tabla}")
def datos_actualizar(esquema: str, tabla: str, body: Fila, s: Sesion = Depends(sesion_actual)):
    cols = {c["columna"] for c in _validar_tabla(s, esquema, tabla)}
    valores = {k: (None if v == "" else v) for k, v in body.valores.items() if k in cols}
    if not valores:
        raise HTTPException(400, "No hay cambios")
    q = sql.SQL("UPDATE {}.{} SET {} WHERE {} RETURNING *").format(
        sql.Identifier(esquema), sql.Identifier(tabla),
        sql.SQL(", ").join(sql.SQL("{} = %s").format(sql.Identifier(k)) for k in valores),
        _where_llave(body.llave))
    fila = s.uno(q, list(valores.values()) + list(body.llave.values()))
    if not fila:
        raise HTTPException(404, "El registro no existe")
    return responder(fila)


@app.delete("/api/datos/{esquema}/{tabla}")
def datos_eliminar(esquema: str, tabla: str, body: Fila, s: Sesion = Depends(sesion_actual)):
    _validar_tabla(s, esquema, tabla)
    q = sql.SQL("DELETE FROM {}.{} WHERE {} RETURNING *").format(
        sql.Identifier(esquema), sql.Identifier(tabla), _where_llave(body.llave))
    fila = s.uno(q, list(body.llave.values()))
    if not fila:
        raise HTTPException(404, "El registro no existe")
    return responder(fila)


# ---------------------------------------------------------------------------
# Interfaz web
# ---------------------------------------------------------------------------
@app.exception_handler(HTTPException)
def _http_error(request: Request, exc: HTTPException):
    return JSONResponse({"error": exc.detail}, status_code=exc.status_code)


app.mount("/static", StaticFiles(directory=BASE / "static"), name="static")


@app.get("/")
def inicio():
    return FileResponse(BASE / "static" / "index.html")
