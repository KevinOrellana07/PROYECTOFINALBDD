"""
AutoAudit - Genera docs/Documentacion_Tecnica.html (y PDF si hay Chrome/Chromium)
a partir del catálogo de la base de datos instalada.

    app/.venv/bin/python docs/generar_documentacion.py --usuario postgres
    (o con un usuario con acceso de consulta: --usuario auditor --clave Auditor123!)
"""
import argparse
import base64
import html
import shutil
import subprocess
from datetime import date
from pathlib import Path

import psycopg
from psycopg.rows import dict_row

DOCS = Path(__file__).resolve().parent
e = lambda v: html.escape("" if v is None else str(v))


def q(cur, sql, *a):
    cur.execute(sql, a)
    return cur.fetchall()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--usuario", default="auditor")
    ap.add_argument("--clave", default="Auditor123!")
    ap.add_argument("--estudiante", default="Nombre del estudiante")
    ap.add_argument("--carne", default="Carné")
    a = ap.parse_args()
    kw = dict(dbname="autoaudit_db", user=a.usuario, row_factory=dict_row)
    if a.usuario != "postgres":
        kw.update(host=a.host, password=a.clave)
    con = psycopg.connect(**kw)
    cur = con.cursor()

    tablas = q(cur, """SELECT c.oid, c.relname AS tabla, obj_description(c.oid,'pg_class') AS d
                         FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                        WHERE n.nspname='auditoria' AND c.relkind='r'
                        ORDER BY array_position(ARRAY['evento','tabla_auditada','columna_auditada',
                          'configuracion_auditoria','usuario_auditado','estacion_trabajo',
                          'bitacora_encabezado','bitacora_detalle','log_generacion','parametro']::name[], c.relname)""")
    dic = []
    for t in tablas:
        cols = q(cur, """
          SELECT a.attname AS col, format_type(a.atttypid,a.atttypmod) AS tipo,
                 CASE WHEN a.attnotnull THEN 'NO' ELSE 'SÍ' END AS nulo,
                 concat_ws(' ', CASE WHEN a.attnum = ANY(pk.conkey) THEN 'PK' END,
                   (SELECT string_agg('FK→'||replace(fk.confrelid::regclass::text,'auditoria.',''),' ')
                      FROM pg_constraint fk WHERE fk.conrelid=a.attrelid AND fk.contype='f' AND a.attnum=ANY(fk.conkey)),
                   CASE WHEN EXISTS(SELECT 1 FROM pg_constraint u WHERE u.conrelid=a.attrelid AND u.contype='u'
                                     AND a.attnum=ANY(u.conkey)) THEN 'UQ' END) AS llave,
                 pg_get_expr(d.adbin,d.adrelid) AS defecto, col_description(a.attrelid,a.attnum) AS descr
            FROM pg_attribute a
            LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
            LEFT JOIN pg_constraint pk ON pk.conrelid=a.attrelid AND pk.contype='p'
           WHERE a.attrelid=%s AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum""", t["oid"])
        chk = q(cur, "SELECT pg_get_constraintdef(oid) AS d FROM pg_constraint WHERE conrelid=%s AND contype='c'", t["oid"])
        idx = q(cur, "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname='auditoria' AND tablename=%s "
                     "AND indexname NOT LIKE '%%pkey'", t["tabla"])
        dic.append((t, cols, chk, idx))

    funciones = q(cur, """SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
                                 pg_get_function_result(p.oid) AS ret, p.prosecdef AS definer,
                                 obj_description(p.oid,'pg_proc') AS d
                            FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                           WHERE n.nspname='auditoria' AND p.proname NOT LIKE 'fn_aud\\_%%'
                           ORDER BY p.proname""")
    vistas = q(cur, """SELECT c.relname, obj_description(c.oid,'pg_class') AS d FROM pg_class c
                        JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='auditoria' AND c.relkind='v'
                        ORDER BY 1""")
    try:
        rend = q(cur, "SELECT * FROM pruebas.resultado_rendimiento ORDER BY registros, operacion")
        cons = q(cur, "SELECT * FROM pruebas.consulta_rendimiento")
        res = q(cur, "SELECT prueba, exito FROM pruebas.resultado ORDER BY id")
    except psycopg.Error:
        con.rollback(); rend, cons, res = [], [], []
    ejemplo = q(cur, "SELECT sql_generado FROM auditoria.tabla_auditada WHERE esquema='tienda' "
                     "AND tabla='productos' AND estado='ACTIVO'")
    version = q(cur, "SHOW server_version")[0]["server_version"]
    con.close()

    er = base64.b64encode((DOCS / "diagrama_er.png").read_bytes()).decode()
    descripcion_funcion = {
        "fn_registrar_tabla": "Valida en el diccionario y registra una tabla para auditoría.",
        "fn_configurar_columna": "Valida la columna y guarda qué eventos (INSERT/UPDATE/DELETE) se auditan.",
        "fn_configurar_tabla": "Atajo: configura varias columnas y genera el trigger.",
        "fn_activar_tabla": "Activa (genera trigger) o desactiva (elimina trigger) una tabla.",
        "fn_eliminar_configuracion": "Elimina la configuración si no tiene bitácora.",
        "fn_validar_configuracion": "Compara la configuración contra el diccionario (ERROR/AVISO).",
        "fn_sincronizar_tabla": "Actualiza nombres por OID/attnum y marca columnas eliminadas.",
        "fn_construir_sql_trigger": "Construye el código del trigger sin ejecutarlo (vista previa).",
        "fn_generar_trigger": "Valida, construye y ejecuta el trigger; registra en log_generacion.",
        "fn_generar_trigger_interno": "Implementación interna (sin verificación de rol); no se otorga a usuarios.",
        "fn_eliminar_trigger": "Elimina el trigger y la función generada.",
        "fn_eliminar_trigger_interno": "Implementación interna; no se otorga a usuarios.",
        "fn_regenerar_todos": "Regenera los triggers de todas las tablas activas.",
        "fn_crear_encabezado": "Inserta el encabezado de bitácora con usuario y estación. Solo autoaudit_owner.",
        "fn_ip_cliente": "IP de origen aplicando la política de privacidad.",
        "fn_consultar_bitacora": "Consulta parametrizada con filtros opcionales.",
        "fn_historial_usuario": "Historial completo de un usuario.",
        "fn_historial_columna": "Todos los cambios de una columna.",
        "fn_historial_registro": "Línea de tiempo de un registro por su llave.",
        "fn_estadisticas": "Indicadores para el panel principal.",
        "fn_purgar_bitacora": "Depura según dias_retencion (solo superusuario).",
        "fn_set_parametro": "Modifica un parámetro global.",
        "fn_proteger_bitacora": "Trigger que impide UPDATE/DELETE/TRUNCATE en la bitácora.",
        "fn_evt_sql_drop": "Event trigger: detecta DROP TABLE / DROP COLUMN.",
        "fn_evt_ddl_end": "Event trigger: tras ALTER TABLE sincroniza y regenera.",
        "fn_es_admin": "Indica si el usuario de sesión es administrador.",
        "fn_verificar_admin": "Lanza error 42501 si el usuario no es administrador.",
        "fn_dic_oid_tabla": "OID de una tabla a partir de esquema y nombre.",
        "fn_dic_llave_primaria": "Columnas de la llave primaria de una tabla.",
    }

    H = []
    w = H.append
    w(f"""<!doctype html><html lang="es"><head><meta charset="utf-8"><title>AutoAudit - Documentación técnica</title>
<style>
@page {{ size: letter; margin: 2cm 1.8cm; }}
body {{ font-family: "Liberation Serif", "Times New Roman", serif; font-size: 11pt; color:#111; line-height:1.4; }}
h1 {{ font-size: 20pt; border-bottom: 2px solid #1F3A5F; padding-bottom:4px; margin-top:0; page-break-before: always; color:#1F3A5F; }}
h2 {{ font-size: 14pt; color:#1F3A5F; margin-top: 18px; }}
h3 {{ font-size: 12pt; margin: 14px 0 6px; }}
table {{ border-collapse: collapse; width:100%; margin: 6px 0 12px; font-size: 9pt; page-break-inside:auto; }}
th, td {{ border:1px solid #b9c3cf; padding:3px 5px; text-align:left; vertical-align:top; }}
th {{ background:#1F3A5F; color:#fff; }}
tr {{ page-break-inside: avoid; }}
code, pre {{ font-family: "DejaVu Sans Mono", monospace; font-size: 8.5pt; }}
pre {{ background:#f3f5f8; border:1px solid #d8dee6; padding:8px; white-space: pre-wrap; page-break-inside: avoid; }}
.portada {{ text-align:center; height: 23cm; display:flex; flex-direction:column; justify-content:space-between; }}
.portada h1 {{ border:0; page-break-before: avoid; font-size: 28pt; }}
.nota {{ background:#eef6ff; border-left:4px solid #3b7dd8; padding:6px 10px; margin:8px 0; }}
.ok {{ color:#1f6e40; font-weight:bold; }} .mal {{ color:#a52a24; font-weight:bold; }}
ol li, ul li {{ margin-bottom: 3px; }}
</style></head><body>
<div class="portada">
 <div><div style="font-size:18pt">Universidad Mariano Gálvez de Guatemala</div>
 <div>Facultad de Ingeniería en Sistemas de Información y Ciencias de la Computación</div></div>
 <div><h1>AutoAudit</h1><div style="font-size:18pt;font-weight:bold">Sistema de auditoría automatizado</div>
 <div style="font-size:14pt;margin-top:8px">Documentación técnica — Proyecto del curso</div></div>
 <div style="text-align:right">{e(a.estudiante)}<br>{e(a.carne)}<br>{date.today().strftime('%d/%m/%Y')}</div>
</div>

<h1>1. Descripción general y arquitectura</h1>
<p>AutoAudit es un sistema de auditoría configurable para PostgreSQL. El administrador selecciona, a partir del
diccionario de datos del DBMS, qué tablas y columnas deben monitorearse y qué eventos (INSERT, UPDATE, DELETE)
registrar en cada columna. A partir de esa configuración el sistema <b>genera automáticamente</b> una función PL/pgSQL
y un trigger <code>AFTER ... FOR EACH ROW</code> exclusivos para cada tabla, que registran cada modificación en una
bitácora centralizada, normalizada e inmutable.</p>
<table><tr><th>Componente</th><th>Tecnología</th><th>Ubicación</th></tr>
<tr><td>Base de datos, generador de triggers, bitácora, consultas</td><td>PostgreSQL {e(version)} (proyecto: PostgreSQL 18) · PL/pgSQL</td><td><code>sql/</code></td></tr>
<tr><td>Servidor de aplicación (API REST)</td><td>Python 3 · FastAPI · psycopg 3</td><td><code>app/main.py</code></td></tr>
<tr><td>Interfaz web</td><td>HTML5, CSS, JavaScript (sin dependencias externas)</td><td><code>app/static/</code></td></tr>
<tr><td>Reportes</td><td>CSV, Excel (openpyxl), PDF (reportlab)</td><td><code>/api/bitacora/exportar</code></td></tr>
<tr><td>Pruebas de validación</td><td>Scripts SQL con aserciones</td><td><code>pruebas/</code></td></tr>
<tr><td>Sistema operativo</td><td>Ubuntu 26.04 LTS</td><td><code>install.sh</code>, <code>run.sh</code></td></tr></table>
<h2>Flujo de funcionamiento</h2>
<ol><li>El administrador consulta el diccionario (<code>v_dic_tablas</code>, <code>v_dic_columnas</code>) y elige tablas, columnas y eventos.</li>
<li>La configuración se guarda en <code>tabla_auditada</code>, <code>columna_auditada</code> y <code>configuracion_auditoria</code>, validando existencia contra <code>pg_catalog</code>.</li>
<li><code>fn_generar_trigger</code> construye el código SQL con las columnas y eventos “compilados” y lo ejecuta.</li>
<li>Cada INSERT/UPDATE/DELETE de los usuarios dispara el trigger, que escribe un encabezado (operación) y un detalle por columna afectada.</li>
<li>Los auditores consultan el historial por usuario, por columna o por registro y exportan reportes.</li></ol>
<p>Si la estructura de una tabla auditada cambia (RENAME, DROP COLUMN … CASCADE, DROP TABLE), dos <i>event triggers</i>
sincronizan la configuración y regeneran el trigger automáticamente.</p>

<h1>2. Diagrama entidad-relación</h1>
<img src="data:image/png;base64,{er}" style="width:100%">
<h2>Relaciones</h2>
<table><tr><th>Relación</th><th>Cardinalidad</th><th>Significado</th></tr>
<tr><td>tabla_auditada → columna_auditada</td><td>1:N</td><td>Una tabla auditada tiene varias columnas seleccionadas.</td></tr>
<tr><td>columna_auditada → configuracion_auditoria ← evento</td><td>N:M resuelta</td><td>La configuración indica qué eventos se registran ante el cambio de cada columna de cada tabla.</td></tr>
<tr><td>tabla_auditada, evento, usuario_auditado, estacion_trabajo → bitacora_encabezado</td><td>1:N</td><td>Cada operación registrada referencia la tabla, el evento, el usuario responsable y la estación de trabajo.</td></tr>
<tr><td>bitacora_encabezado → bitacora_detalle</td><td>1:N</td><td>Una operación afecta una o varias columnas.</td></tr>
<tr><td>configuracion_auditoria → bitacora_detalle</td><td>1:N</td><td>Cada registro de bitácora referencia la configuración específica usada.</td></tr>
<tr><td>tabla_auditada → log_generacion</td><td>1:N</td><td>Historial de generación de triggers y errores.</td></tr></table>
<div class="nota">Las llaves foráneas de la bitácora usan <code>ON DELETE RESTRICT</code>: una configuración con historial no puede
borrarse, solo desactivarse. Si la tabla origen se elimina, la configuración queda en estado <b>HUERFANA</b> y la bitácora
(con la fila completa en <code>datos_anteriores</code>) se conserva.</div>

<h1>3. Diccionario de datos</h1>
<p>Generado automáticamente desde <code>pg_catalog</code> (ver <code>docs/diccionario_datos.sql</code>). Esquema: <code>auditoria</code>.</p>""")
    for t, cols, chk, idx in dic:
        w(f"<h3>{e(t['tabla'])}</h3><p>{e(t['d'])}</p><table><tr><th>Columna</th><th>Tipo</th><th>Nulo</th>"
          f"<th>Llave</th><th>Defecto</th><th>Descripción</th></tr>")
        for c in cols:
            w(f"<tr><td><b>{e(c['col'])}</b></td><td>{e(c['tipo'])}</td><td>{c['nulo']}</td><td>{e(c['llave'])}</td>"
              f"<td><code>{e(c['defecto'])}</code></td><td>{e(c['descr'])}</td></tr>")
        w("</table>")
        if chk:
            w("<p><b>Restricciones CHECK:</b> " + "; ".join(f"<code>{e(x['d'])}</code>" for x in chk) + "</p>")
        if idx:
            w("<p><b>Índices:</b> " + "; ".join(f"<code>{e(x['indexname'])}</code>" for x in idx) + "</p>")
    w("<h2>Vistas</h2><table><tr><th>Vista</th><th>Descripción</th></tr>")
    for v in vistas:
        w(f"<tr><td><code>{e(v['relname'])}</code></td><td>{e(v['d'])}</td></tr>")
    w("</table><h2>Funciones</h2><table><tr><th>Función</th><th>Retorna</th><th>Seguridad</th><th>Descripción</th></tr>")
    for f in funciones:
        w(f"<tr><td><code>{e(f['proname'])}({e(f['args'])})</code></td><td>{e(f['ret'])}</td>"
          f"<td>{'DEFINER' if f['definer'] else 'INVOKER'}</td><td>{e(descripcion_funcion.get(f['proname'], f['d']))}</td></tr>")
    w("</table>")

    w(f"""<h1>4. Manual de configuración y activación de auditoría por tabla</h1>
<p>Solo los miembros del rol <code>autoaudit_admin</code> (usuario de ejemplo <code>admin_auditoria</code>) pueden configurar.</p>
<h2>4.1 Desde la interfaz web</h2>
<ol><li>Iniciar la aplicación (<code>bash run.sh</code>) y abrir <code>http://localhost:8000</code>. Ingresar como <code>admin_auditoria</code>.</li>
<li>Menú <b>Configuración</b>: a la izquierda aparece el diccionario de datos con el estado de cada tabla.</li>
<li>Seleccionar la tabla. Se muestran sus columnas (tipo, PK/FK, NOT NULL) con tres casillas: INSERT, UPDATE y DELETE.
Al hacer clic en el encabezado de un evento se marcan/desmarcan todas las columnas.</li>
<li>Escribir opcionalmente una descripción y pulsar <b>Guardar y generar trigger</b>. El sistema valida, genera el código,
lo ejecuta y muestra la vista previa del SQL. <b>Guardar sin aplicar</b> solo guarda la configuración (estado PENDIENTE).</li>
<li><b>Ver código SQL</b> muestra la validación contra el diccionario y el código que se generará.</li>
<li><b>Desactivar</b> elimina el trigger conservando la configuración y la bitácora; <b>Activar</b> lo vuelve a generar.
<b>Regenerar</b> reconstruye el trigger; <b>Eliminar config.</b> solo aparece si la tabla no tiene bitácora.</li></ol>
<h2>4.2 Desde SQL</h2>
<pre>-- Consultar el diccionario
SELECT * FROM auditoria.v_dic_tablas;
SELECT * FROM auditoria.v_dic_columnas WHERE esquema='tienda' AND tabla='productos';

-- Configuración granular (INSERT, UPDATE, DELETE) y generación
SELECT auditoria.fn_configurar_columna('tienda','productos','precio',     true,  true, true);
SELECT auditoria.fn_configurar_columna('tienda','productos','existencia', false, true, false);
SELECT auditoria.fn_generar_trigger(tabla_id) FROM auditoria.tabla_auditada
 WHERE esquema='tienda' AND tabla='productos' AND estado&lt;&gt;'HUERFANA';

-- Atajo: varias columnas con los mismos eventos y aplicar
SELECT auditoria.fn_configurar_tabla('tienda','clientes', ARRAY['nombre','email'], true, true, true);

-- Activar / desactivar / regenerar / estado
SELECT auditoria.fn_activar_tabla(1, false);
SELECT auditoria.fn_activar_tabla(1, true);
SELECT * FROM auditoria.fn_regenerar_todos();
SELECT * FROM auditoria.v_estado_auditoria;</pre>
<h2>4.3 Estados de una tabla</h2>
<table><tr><th>Estado</th><th>Significado</th></tr>
<tr><td>PENDIENTE</td><td>Configuración guardada o modificada, falta generar el trigger.</td></tr>
<tr><td>ACTIVO</td><td>Trigger generado y vigente.</td></tr>
<tr><td>INACTIVO</td><td>Desactivada: sin trigger, se conserva configuración y bitácora.</td></tr>
<tr><td>ERROR</td><td>La validación o la generación falló; el detalle está en <code>ultimo_error</code> y en <code>log_generacion</code>.</td></tr>
<tr><td>HUERFANA</td><td>La tabla origen fue eliminada; se conserva su historial.</td></tr></table>
<h2>4.4 Ejemplo de código generado</h2>
<pre>{e(ejemplo[0]['sql_generado'] if ejemplo else '(instale la demostración para ver un ejemplo)')}</pre>
<p>Características del código generado: una función por tabla (requisito: cada trigger maneja exclusivamente una tabla
origen), columnas y eventos fijos en el código (sin consultar la configuración por fila), <code>UPDATE OF columnas</code>
para no dispararse con columnas no auditadas, <code>IS DISTINCT FROM</code> para registrar solo cambios reales (incluyendo NULL),
<code>SECURITY DEFINER</code> con dueño <code>autoaudit_owner</code> y <code>search_path</code> fijo.</p>

<h1>5. Procedimiento de instalación y despliegue de triggers</h1>
<h2>5.1 Requisitos</h2>
<ul><li>Ubuntu 26.04 LTS con acceso <code>sudo</code>.</li><li>PostgreSQL 18 (lo instala el script si no existe).</li>
<li>Python 3 con <code>venv</code> (incluido en Ubuntu).</li></ul>
<h2>5.2 Instalación automática</h2>
<pre>cd autoaudit
sudo bash install.sh          # instala todo + datos de demostración
bash run.sh                   # inicia la aplicación en http://localhost:8000
sudo bash pruebas/ejecutar_pruebas.sh   # ejecuta las pruebas de validación</pre>
<h2>5.3 Orden de los scripts de base de datos</h2>
<table><tr><th>Script</th><th>Contenido</th></tr>
<tr><td>00_roles_y_bd.sql</td><td>Roles autoaudit_owner/admin/consulta, usuarios de demostración, base autoaudit_db.</td></tr>
<tr><td>01_esquema.sql</td><td>Tablas del sistema, índices, catálogo de eventos y parámetros.</td></tr>
<tr><td>02_diccionario.sql</td><td>Vistas de consulta al diccionario de datos del DBMS.</td></tr>
<tr><td>03_funciones_config.sql</td><td>Módulo de configuración con validaciones.</td></tr>
<tr><td>04_generador_triggers.sql</td><td>Generador dinámico de triggers y registro en bitácora.</td></tr>
<tr><td>05_consultas.sql</td><td>Consultas parametrizadas de historial y estadísticas.</td></tr>
<tr><td>06_seguridad.sql</td><td>Permisos y protección (inmutabilidad) de la bitácora.</td></tr>
<tr><td>07_eventos_ddl.sql</td><td>Event triggers para dependencias (DROP/ALTER).</td></tr>
<tr><td>08_datos_demo.sql</td><td>Esquema de ejemplo <code>tienda</code>.</td></tr>
<tr><td>09_comentarios.sql</td><td>Descripciones para el diccionario de datos.</td></tr></table>
<h2>5.4 Despliegue de triggers en una tabla propia</h2>
<ol><li>Crear la tabla en cualquier esquema (se recomienda que tenga llave primaria).</li>
<li>Configurarla desde la interfaz o con <code>fn_configurar_columna</code> / <code>fn_configurar_tabla</code>.</li>
<li>Generar con <code>fn_generar_trigger</code>. Verificar con <code>SELECT * FROM auditoria.v_estado_auditoria</code>
(columna <code>sincronizado = true</code>) y en <code>auditoria.v_dic_triggers</code>.</li>
<li>Los errores quedan en <code>auditoria.log_generacion</code>; si la generación falla, el trigger anterior permanece intacto.</li></ol>

<h1>6. Seguridad</h1>
<table><tr><th>Requisito</th><th>Implementación</th></tr>
<tr><td>Solo administradores configuran</td><td>Funciones de configuración verifican <code>pg_has_role(session_user,'autoaudit_admin')</code> (error 42501). Los administradores no tienen INSERT/UPDATE/DELETE directo sobre las tablas de configuración.</td></tr>
<tr><td>Sin escritura directa en bitácora</td><td>Solo <code>autoaudit_owner</code> (rol NOLOGIN dueño de las funciones generadas) tiene INSERT. Un trigger de protección impide UPDATE, DELETE y TRUNCATE incluso al superusuario (salvo depuración explícita).</td></tr>
<tr><td>Privacidad de la IP</td><td>Parámetro <code>ip_modo</code>: completa, anonimizada (IPv4 /24, IPv6 /48) o ninguna. La IP se toma de <code>inet_client_addr()</code> (no la puede falsificar el cliente).</td></tr>
<tr><td>Usuario responsable</td><td>Se usa <code>session_user</code>, que no cambia con <code>SET ROLE</code> ni dentro de funciones SECURITY DEFINER.</td></tr>
<tr><td>Inyección SQL</td><td>El generador usa <code>format()</code> con <code>%I</code>/<code>%L</code>; la API usa parámetros y <code>psycopg.sql.Identifier</code>.</td></tr>
<tr><td>Retención</td><td><code>dias_retencion</code> y <code>fn_purgar_bitacora()</code> (solo superusuario).</td></tr></table>

<h1>7. Pruebas de validación</h1>
<p>Ejecutadas con <code>sudo bash pruebas/ejecutar_pruebas.sh</code>.</p>""")
    if res:
        ok = sum(1 for r in res if r["exito"])
        w(f"<p>Resultado: <span class='ok'>{ok} de {len(res)} pruebas aprobadas</span>.</p>"
          "<table><tr><th>#</th><th>Caso de prueba</th><th>Resultado</th></tr>")
        for i, r in enumerate(res, 1):
            w(f"<tr><td>{i}</td><td>{e(r['prueba'])}</td><td class='{'ok' if r['exito'] else 'mal'}'>"
              f"{'PASA' if r['exito'] else 'FALLA'}</td></tr>")
        w("</table>")
    if rend:
        w("<h2>Rendimiento con volumen creciente</h2><p>Tiempo (ms) de operaciones masivas sobre dos tablas idénticas, "
          "sin y con auditoría de 3 columnas.</p><table><tr><th>Registros</th><th>Operación</th><th>Sin auditoría</th>"
          "<th>Con auditoría</th><th>Sobrecosto por fila (ms)</th></tr>")
        for r in rend:
            w(f"<tr><td>{r['registros']:,}</td><td>{r['operacion']}</td><td>{r['ms_sin_auditoria']}</td>"
              f"<td>{r['ms_con_auditoria']}</td><td>{r['sobrecosto_ms_por_fila']}</td></tr>")
        w("</table><p>El sobrecosto por fila se mantiene constante (≈0,1–0,2 ms) al crecer el volumen: el costo es lineal. "
          "En una operación normal de una sola fila el usuario no percibe la diferencia; en cargas masivas el tiempo "
          "aumenta porque cada fila genera sus registros de bitácora.</p>")
        if cons:
            w("<table><tr><th>Consulta sobre bitácora poblada</th><th>ms</th></tr>" +
              "".join(f"<tr><td>{e(c['consulta'])}</td><td>{c['ms']}</td></tr>" for c in cons) + "</table>")
    w("</body></html>")

    salida = DOCS / "Documentacion_Tecnica.html"
    salida.write_text("".join(H), encoding="utf-8")
    print("HTML:", salida)
    chrome = next((shutil.which(x) for x in ("google-chrome", "chromium", "chromium-browser") if shutil.which(x)), None)
    if chrome:
        pdf = DOCS / "Documentacion_Tecnica.pdf"
        subprocess.run([chrome, "--headless", "--no-sandbox", "--disable-gpu", "--no-pdf-header-footer",
                        f"--print-to-pdf={pdf}", salida.as_uri()], check=True, capture_output=True)
        print("PDF:", pdf)
    else:
        print("Abra el HTML en el navegador y use Imprimir > Guardar como PDF.")


if __name__ == "__main__":
    main()
