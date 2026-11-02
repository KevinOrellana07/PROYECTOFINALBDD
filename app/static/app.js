/* AutoAudit - lógica de la interfaz (JavaScript sin dependencias) */
"use strict";

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const vista = $("#vista");
let SESION = null;

/* ------------------------------------------------------------------ utilidades */
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const nulo = (v) => (v === null || v === undefined ? '<span class="nulo">null</span>' : esc(typeof v === "object" ? JSON.stringify(v) : v));
const fecha = (iso) => {
  if (!iso) return "";
  const d = new Date(iso);
  return d.toLocaleString("es-GT", { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" });
};
const num = (n) => Number(n || 0).toLocaleString("es-GT");
const llaveTxt = (ll) => (ll ? Object.entries(ll).map(([k, v]) => `${k}=${v}`).join(", ") : "—");
const op = (o) => `<span class="op ${esc(o)}">${esc(o)}</span>`;
const estado = (e) => `<span class="estado ${esc(e)}">${esc(e)}</span>`;

async function api(url, opciones = {}) {
  const cfg = { headers: {}, ...opciones };
  if (cfg.body && typeof cfg.body !== "string") {
    cfg.body = JSON.stringify(cfg.body);
    cfg.headers["Content-Type"] = "application/json";
  }
  const r = await fetch(url, cfg);
  if (r.status === 401 && !url.endsWith("/login")) { mostrarLogin(); throw new Error("Sesión expirada"); }
  const datos = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(datos.error || datos.detail || `Error ${r.status}`);
  return datos;
}

function toast(msg, tipo = "") {
  const t = document.createElement("div");
  t.className = `toast ${tipo}`;
  t.textContent = msg;
  $("#toasts").appendChild(t);
  setTimeout(() => t.remove(), tipo === "error" ? 7000 : 3500);
}

function modal(titulo, html, pie = "") {
  const raiz = $("#modal-raiz");
  raiz.innerHTML = `<div class="modal-fondo"><div class="modal" role="dialog">
      <header><h3>${titulo}</h3><button class="cerrar" aria-label="Cerrar">&times;</button></header>
      <div class="contenido">${html}</div>${pie ? `<footer>${pie}</footer>` : ""}</div></div>`;
  const cerrar = () => (raiz.innerHTML = "");
  $(".cerrar", raiz).onclick = cerrar;
  $(".modal-fondo", raiz).onclick = (e) => { if (e.target.classList.contains("modal-fondo")) cerrar(); };
  return { raiz, cerrar };
}

function resaltarSQL(sql) {
  return esc(sql)
    .replace(/(--[^\n]*)/g, '<span class="c">$1</span>')
    .replace(/('(?:[^'\\]|\\.)*')/g, '<span class="s">$1</span>')
    .replace(/\b(CREATE|OR|REPLACE|FUNCTION|RETURNS|TRIGGER|LANGUAGE|SECURITY|DEFINER|SET|AS|DECLARE|BEGIN|END|IF|THEN|ELSIF|ELSE|RETURN|NULL|INSERT|INTO|VALUES|UPDATE|DELETE|OF|ON|AFTER|FOR|EACH|ROW|EXECUTE|ALTER|OWNER|TO|REVOKE|ALL|FROM|PUBLIC|COMMENT|IS|DISTINCT|COALESCE|DROP|EXISTS)\b/g, '<span class="k">$1</span>');
}

function cabecera(titulo, subtitulo, acciones = "") {
  return `<div class="cabecera"><div><h2>${titulo}</h2><p>${subtitulo}</p></div><div class="acciones">${acciones}</div></div>`;
}

/* ------------------------------------------------------------------ sesión */
function mostrarLogin() {
  SESION = null;
  $("#app").classList.add("oculto");
  $("#login").classList.remove("oculto");
}

$("#form-login").addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = $("#login-error");
  err.classList.add("oculto");
  try {
    await api("/api/login", { method: "POST", body: { usuario: $("#l-usuario").value.trim(), clave: $("#l-clave").value } });
    $("#l-clave").value = "";
    iniciar();
  } catch (ex) {
    err.textContent = ex.message;
    err.classList.remove("oculto");
  }
});
$$(".demo-usuarios button").forEach((b) => (b.onclick = () => { $("#l-usuario").value = b.dataset.u; $("#l-clave").value = b.dataset.c; }));
$("#btn-salir").onclick = async () => { await api("/api/logout", { method: "POST" }).catch(() => {}); location.hash = ""; mostrarLogin(); };

async function iniciar() {
  try { SESION = await api("/api/sesion"); } catch { return mostrarLogin(); }
  $("#login").classList.add("oculto");
  $("#app").classList.remove("oculto");
  $("#u-nombre").textContent = SESION.usuario;
  $("#u-rol").textContent = SESION.es_admin ? "Administrador de auditoría" : SESION.es_consulta ? "Auditor (solo consulta)" : "Usuario operativo";
  $$("#menu a[data-r=consulta]").forEach((a) => a.classList.toggle("oculto", !SESION.es_consulta));
  if (!location.hash || (!SESION.es_consulta && location.hash !== "#datos")) location.hash = SESION.es_consulta ? "#panel" : "#datos";
  else enrutar();
}

/* ------------------------------------------------------------------ rutas */
const RUTAS = { panel: vPanel, configuracion: vConfiguracion, bitacora: vBitacora, usuarios: vUsuarios,
  columnas: vColumnas, datos: vDatos, generador: vGenerador, parametros: vParametros };

function enrutar() {
  if (!SESION) return;
  const [ruta, ...args] = location.hash.slice(1).split("/");
  const fn = RUTAS[ruta] || vPanel;
  $("#modal-raiz").innerHTML = "";
  $$("#menu a").forEach((a) => a.classList.toggle("activo", a.getAttribute("href") === `#${ruta}`));
  vista.innerHTML = '<div class="cargando">Cargando…</div>';
  fn(...args.map(decodeURIComponent)).catch((e) => {
    vista.innerHTML = `<div class="aviso error">${esc(e.message)}</div>`;
  });
}
window.addEventListener("hashchange", enrutar);
document.addEventListener("keydown", (e) => { if (e.key === "Escape") $("#modal-raiz").innerHTML = ""; });

/* ================================================================== PANEL */
async function vPanel() {
  const e = await api("/api/estadisticas?dias=14");
  vista.innerHTML = cabecera("Panel de auditoría", "Resumen de la actividad registrada en la bitácora",
    `<button class="btn" onclick="enrutar()">Actualizar</button>`) + `
    <div class="kpis">
      ${kpi("Tablas auditadas", e.tablas_auditadas, `${e.tablas_config} configuradas`)}
      ${kpi("Columnas auditadas", e.columnas)}
      ${kpi("Operaciones registradas", num(e.operaciones), `${num(e.hoy)} hoy`)}
      ${kpi("Valores de columna", num(e.cambios))}
      ${kpi("Usuarios auditados", e.usuarios)}
      ${kpi("Estaciones de trabajo", e.estaciones)}
    </div>
    <div class="rejilla r-3-1">
      <div class="tarjeta"><h3>Operaciones por día (últimos 14 días)</h3><div class="cuerpo grafica">${graficaDias(e.por_dia)}
        <div class="leyenda"><span><i style="background:var(--ins)"></i>INSERT</span><span><i style="background:var(--upd)"></i>UPDATE</span><span><i style="background:var(--del)"></i>DELETE</span></div></div></div>
      <div class="tarjeta"><h3>Por tabla</h3><div class="cuerpo">${barrasH(e.por_tabla, "tabla")}</div>
        <h3 style="border-top:1px solid var(--borde)">Por usuario</h3><div class="cuerpo">${barrasH(e.por_usuario, "usuario")}</div></div>
    </div>
    <div class="tarjeta" style="margin-top:16px"><h3>Últimas operaciones <a href="#bitacora" style="font-weight:500;font-size:13px">Ver bitácora →</a></h3>
      ${e.recientes.length ? `<div class="tabla-cont"><table class="datos"><thead><tr><th>Fecha/hora</th><th>Operación</th><th>Tabla</th><th>Registro</th><th>Columnas</th><th>Usuario</th></tr></thead><tbody>
      ${e.recientes.map((r) => `<tr class="clic" data-enc="${r.encabezado_id}"><td>${fecha(r.fecha_hora)}</td><td>${op(r.operacion)}</td><td>${esc(r.esquema)}.${esc(r.tabla)}</td><td class="mono">${esc(llaveTxt(r.llave_registro))}</td><td>${esc(r.columnas)}</td><td>${esc(r.usuario)}</td></tr>`).join("")}
      </tbody></table></div>` : `<div class="vacio">Aún no hay operaciones registradas. Configure una tabla y modifique datos en el módulo <a href="#datos">Datos</a>.</div>`}
    </div>`;
  activarFilasOperacion();
}
const kpi = (etq, n, sub = "") => `<div class="tarjeta kpi"><div class="etq">${etq}</div><div class="num">${n}</div><div class="sub">${sub}</div></div>`;

function graficaDias(dias) {
  const W = 640, H = 220, m = { l: 34, r: 8, t: 10, b: 26 };
  const max = Math.max(1, ...dias.map((d) => d.ins + d.upd + d.del));
  const paso = (W - m.l - m.r) / dias.length, ancho = Math.max(4, paso * 0.62);
  const y = (v) => m.t + (H - m.t - m.b) * (1 - v / max);
  let svg = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Operaciones por día">`;
  for (let i = 0; i <= 4; i++) {
    const v = Math.round((max * i) / 4), yy = y(v);
    svg += `<line x1="${m.l}" x2="${W - m.r}" y1="${yy}" y2="${yy}" stroke="#edf0f4"/><text x="${m.l - 6}" y="${yy + 4}" font-size="10" text-anchor="end" fill="#8592a3">${v}</text>`;
  }
  dias.forEach((d, i) => {
    const x = m.l + i * paso + (paso - ancho) / 2;
    let base = 0;
    [["ins", "var(--ins)"], ["upd", "var(--upd)"], ["del", "var(--del)"]].forEach(([k, c]) => {
      if (!d[k]) return;
      const y1 = y(base + d[k]), y0 = y(base);
      svg += `<rect x="${x}" y="${y1}" width="${ancho}" height="${y0 - y1}" fill="${c}" rx="2"><title>${d.dia} ${k.toUpperCase()}: ${d[k]}</title></rect>`;
      base += d[k];
    });
    if (i % 2 === 0 || dias.length <= 8) svg += `<text x="${x + ancho / 2}" y="${H - 8}" font-size="10" text-anchor="middle" fill="#8592a3">${d.dia.slice(8, 10)}/${d.dia.slice(5, 7)}</text>`;
  });
  return svg + "</svg>";
}

function barrasH(lista, campo) {
  if (!lista.length) return '<div class="nulo">Sin datos</div>';
  const max = Math.max(...lista.map((x) => x.n));
  return lista.slice(0, 6).map((x) => `<div class="barra-h"><span title="${esc(x[campo])}" style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(x[campo])}</span>
    <div class="b"><div style="width:${(100 * x.n) / max}%"></div></div><span class="n">${num(x.n)}</span></div>`).join("");
}

/* ================================================================== CONFIGURACIÓN */
let CFG_SEL = null;

async function vConfiguracion(esq, tab) {
  const tablas = await api("/api/diccionario/tablas");
  vista.innerHTML = cabecera("Configuración de auditoría",
    "Seleccione una tabla del diccionario de datos, marque las columnas y los eventos a auditar, y aplique para generar el trigger.",
    SESION.es_admin ? `<button class="btn" id="btn-regen-todos">Regenerar todos los triggers</button>` : "") +
    (SESION.es_admin ? "" : `<div class="aviso info">Su usuario es de solo consulta: puede ver la configuración pero no modificarla.</div>`) + `
    <div class="rejilla r-cfg">
      <div class="tarjeta"><div class="tarjeta-titulo">Diccionario de datos <span class="chip">${tablas.length} tablas</span></div>
        <div class="buscador"><input type="text" id="buscar-tabla" placeholder="Buscar tabla…"></div>
        <div class="lista-tablas" id="lista-tablas">${tablas.map((t) => `
          <div class="item" data-esq="${esc(t.esquema)}" data-tab="${esc(t.tabla)}">
            <div><div class="esq">${esc(t.esquema)}</div><div class="nom">${esc(t.tabla)}</div></div>
            ${t.estado_auditoria === "NO CONFIGURADA" ? '<span class="estado">—</span>' : estado(t.estado_auditoria)}
          </div>`).join("")}</div></div>
      <div id="cfg-detalle"><div class="tarjeta"><div class="vacio">← Seleccione una tabla para configurar su auditoría</div></div></div>
    </div>`;

  $("#buscar-tabla").oninput = (e) => {
    const q = e.target.value.toLowerCase();
    $$("#lista-tablas .item").forEach((it) => it.classList.toggle("oculto", !(`${it.dataset.esq}.${it.dataset.tab}`.toLowerCase().includes(q))));
  };
  $$("#lista-tablas .item").forEach((it) => (it.onclick = () => { location.hash = `#configuracion/${it.dataset.esq}/${it.dataset.tab}`; }));
  const btnTodos = $("#btn-regen-todos");
  if (btnTodos) btnTodos.onclick = async () => {
    try {
      const r = await api("/api/configuracion/regenerar-todos", { method: "POST" });
      const malos = r.filter((x) => !x.exito);
      toast(malos.length ? `${malos.length} tabla(s) con error: ${malos.map((m) => m.tabla).join(", ")}` : `${r.length} trigger(s) regenerados correctamente`, malos.length ? "error" : "ok");
      enrutar();
    } catch (e) { toast(e.message, "error"); }
  };
  if (esq && tab) await cargarDetalleTabla(esq, tab);
}

async function cargarDetalleTabla(esq, tab) {
  $$("#lista-tablas .item").forEach((it) => it.classList.toggle("sel", it.dataset.esq === esq && it.dataset.tab === tab));
  const d = await api(`/api/diccionario/${encodeURIComponent(esq)}/${encodeURIComponent(tab)}/columnas`);
  CFG_SEL = { esq, tab, d };
  const e = d.estado, admin = SESION.es_admin;
  const chk = (on, cls, col, ev) => `<span class="check ${cls} ${on ? "on" : ""} ${admin ? "" : "bloq"}" data-col="${esc(col)}" data-ev="${ev}" role="checkbox" aria-checked="${on}"></span>`;

  $("#cfg-detalle").innerHTML = `
    <div class="tarjeta">
      <div class="tarjeta-titulo"><div>${esc(esq)}.<b>${esc(tab)}</b> ${e ? estado(e.estado) : '<span class="estado">NO CONFIGURADA</span>'}
        ${e && !e.sincronizado ? '<span class="estado ERROR" title="La configuración no coincide con los triggers reales">desincronizado</span>' : ""}</div>
        <div class="acciones">
          ${e ? `<button class="btn chico" id="btn-sql">Ver código SQL</button>` : ""}
          ${admin && e ? `<button class="btn chico" id="btn-activar">${e.activa ? "Desactivar" : "Activar"}</button>` : ""}
          ${admin && e && e.activa ? `<button class="btn chico" id="btn-regen">Regenerar</button>` : ""}
          ${admin && e && !e.registros_bitacora ? `<button class="btn chico peligro" id="btn-eliminar">Eliminar config.</button>` : ""}
        </div></div>
      <div class="cuerpo">
        ${e && e.ultimo_error ? `<div class="aviso error"><b>Último error:</b> ${esc(e.ultimo_error)}</div>` : ""}
        ${e ? `<div class="meta">
          <div><span>Eventos</span>${esc(e.eventos || "—")}</div>
          <div><span>Columnas auditadas</span>${e.columnas_activas}</div>
          <div><span>Función generada</span><code>${esc(e.funcion_trigger || "—")}</code></div>
          <div><span>Generado</span>${fecha(e.fecha_generacion) || "—"}</div>
          <div><span>Registros en bitácora</span>${num(e.registros_bitacora)}</div></div>` : ""}
        <div class="campo"><label>Descripción</label><input type="text" id="cfg-desc" value="${esc(e?.descripcion || "")}" ${admin ? "" : "disabled"} placeholder="Motivo de la auditoría (opcional)"></div>
      </div>
      <div class="tabla-cont"><table class="datos">
        <thead><tr><th>#</th><th>Columna</th><th>Tipo</th><th>Info</th>
          <th class="centro th-ev" data-ev="i" title="Marcar/desmarcar todas">INSERT</th>
          <th class="centro th-ev" data-ev="u" title="Marcar/desmarcar todas">UPDATE</th>
          <th class="centro th-ev" data-ev="d" title="Marcar/desmarcar todas">DELETE</th></tr></thead>
        <tbody>${d.columnas.map((c) => `<tr>
          <td>${c.posicion}</td><td><b>${esc(c.columna)}</b>${c.comentario ? `<div class="nulo">${esc(c.comentario)}</div>` : ""}</td>
          <td class="mono">${esc(c.tipo_dato)}</td>
          <td>${c.es_pk ? '<span class="chip pk">PK</span>' : ""}${c.es_fk ? '<span class="chip fk">FK</span>' : ""}${c.admite_nulos ? "" : '<span class="chip">NOT NULL</span>'}</td>
          <td class="centro">${chk(c.ev_insert, "i", c.columna, "i")}</td>
          <td class="centro">${chk(c.ev_update, "u", c.columna, "u")}</td>
          <td class="centro">${chk(c.ev_delete, "d", c.columna, "d")}</td></tr>`).join("")}</tbody>
      </table></div>
      ${admin ? `<div class="cuerpo" style="display:flex;gap:8px;justify-content:flex-end;border-top:1px solid var(--borde)">
        <button class="btn" id="btn-guardar">Guardar sin aplicar</button>
        <button class="btn primario" id="btn-aplicar">Guardar y generar trigger</button></div>` : ""}
    </div>
    <div class="rejilla r-2" style="margin-top:16px">
      <div class="tarjeta"><h3>Llaves y restricciones</h3><div class="cuerpo">${d.llaves.length ? d.llaves.map((k) => `<div style="margin-bottom:6px"><span class="chip ${k.tipo === "PRIMARY KEY" ? "pk" : k.tipo === "FOREIGN KEY" ? "fk" : ""}">${k.tipo}</span> <code>${esc(k.definicion)}</code></div>`).join("") : '<span class="nulo">Sin llaves</span>'}</div></div>
      <div class="tarjeta"><h3>Triggers en la tabla</h3><div class="cuerpo">${d.triggers.length ? d.triggers.map((t) => `<div style="margin-bottom:8px">${t.es_autoaudit ? '<span class="chip pk">AutoAudit</span>' : '<span class="chip">otro</span>'} <code style="word-break:break-word">${esc(t.definicion)}</code></div>`).join("") : '<span class="nulo">Sin triggers</span>'}</div></div>
    </div>`;

  if (admin) {
    $$("#cfg-detalle .check").forEach((c) => (c.onclick = () => c.classList.toggle("on")));
    $$("#cfg-detalle .th-ev").forEach((th) => (th.onclick = () => {
      const cs = $$(`#cfg-detalle .check[data-ev=${th.dataset.ev}]`);
      const todas = cs.every((c) => c.classList.contains("on"));
      cs.forEach((c) => c.classList.toggle("on", !todas));
    }));
    $("#btn-guardar").onclick = () => guardarConfig(false);
    $("#btn-aplicar").onclick = () => guardarConfig(true);
  }
  const b = (id, fn) => { const el = $(id); if (el) el.onclick = fn; };
  b("#btn-sql", () => verSQL(e.tabla_id));
  b("#btn-activar", async () => accionCfg(`/api/configuracion/${e.tabla_id}/activar`, { activa: !e.activa }));
  b("#btn-regen", async () => accionCfg(`/api/configuracion/${e.tabla_id}/regenerar`));
  b("#btn-eliminar", async () => {
    if (!confirm("¿Eliminar la configuración de esta tabla? Se quitará el trigger.")) return;
    try { await api(`/api/configuracion/${e.tabla_id}`, { method: "DELETE" }); toast("Configuración eliminada", "ok"); vConfiguracion(esq, tab); }
    catch (ex) { toast(ex.message, "error"); }
  });
}

async function accionCfg(url, body) {
  try {
    const r = await api(url, { method: "POST", body: body || {} });
    toast(r.mensaje + (r.avisos ? ` — Avisos: ${r.avisos}` : ""), r.exito ? "ok" : "error");
  } catch (ex) { toast(ex.message, "error"); }
  vConfiguracion(CFG_SEL.esq, CFG_SEL.tab);
}

async function guardarConfig(aplicar) {
  const cols = {};
  $$("#cfg-detalle .check").forEach((c) => {
    const k = c.dataset.col;
    cols[k] = cols[k] || { columna: k, insert: false, update: false, delete: false };
    if (c.classList.contains("on")) cols[k][{ i: "insert", u: "update", d: "delete" }[c.dataset.ev]] = true;
  });
  const lista = Object.values(cols).filter((c) => c.insert || c.update || c.delete);
  if (aplicar && !lista.length) return toast("Marque al menos una columna y un evento", "error");
  try {
    const r = await api(`/api/configuracion/${encodeURIComponent(CFG_SEL.esq)}/${encodeURIComponent(CFG_SEL.tab)}`,
      { method: "POST", body: { descripcion: $("#cfg-desc").value || null, columnas: lista, aplicar } });
    toast(r.mensaje + (r.avisos ? ` — Avisos: ${r.avisos}` : ""), r.exito === false ? "error" : "ok");
    await vConfiguracion(CFG_SEL.esq, CFG_SEL.tab);
    if (aplicar && r.sql) verSQL(r.tabla_id);
  } catch (ex) { toast(ex.message, "error"); }
}

async function verSQL(tablaId) {
  const r = await api(`/api/configuracion/${tablaId}/sql`);
  const val = r.validacion.length ? r.validacion.map((v) => `<div class="aviso ${v.nivel === "ERROR" ? "error" : "warn"}">${v.nivel}: ${esc(v.mensaje)}</div>`).join("") : `<div class="aviso ok">La configuración es válida según el diccionario de datos.</div>`;
  const aplicado = r.aplicado?.sql_generado;
  modal("Código SQL del trigger",
    `${val}<p style="margin-top:0;color:var(--tenue)">${aplicado ? `Código aplicado el ${fecha(r.aplicado.fecha_generacion)}. ` : "Aún no se ha aplicado. "}Esta es la vista previa generada a partir de la configuración actual:</p>
     <pre class="codigo">${resaltarSQL(r.sql)}</pre>`,
    `<button class="btn" id="copiar-sql">Copiar</button>`);
  $("#copiar-sql").onclick = () => navigator.clipboard.writeText(r.sql).then(() => toast("Código copiado", "ok"));
}

/* ================================================================== BITÁCORA */
let CATALOGOS = null;
async function catalogos(forzar = false) {
  if (!CATALOGOS || forzar) CATALOGOS = await api("/api/catalogos");
  return CATALOGOS;
}

async function vBitacora() {
  const cat = await catalogos(true);
  const tablas = [...new Set(cat.columnas.map((c) => `${c.esquema}.${c.tabla}`))];
  vista.innerHTML = cabecera("Bitácora de cambios", "Registro centralizado de todas las modificaciones auditadas",
    `<button class="btn" data-fmt="csv">⇩ CSV</button><button class="btn" data-fmt="xlsx">⇩ Excel</button><button class="btn" data-fmt="pdf">⇩ PDF</button>`) + `
    <div class="tarjeta">
      <form class="filtros" id="filtros">
        <div class="campo"><label>Usuario</label><select name="usuario"><option value="">Todos</option>${cat.usuarios.map((u) => `<option>${esc(u.usuario)}</option>`).join("")}</select></div>
        <div class="campo"><label>Tabla</label><select name="tabla_c"><option value="">Todas</option>${tablas.map((t) => `<option>${esc(t)}</option>`).join("")}</select></div>
        <div class="campo"><label>Columna</label><select name="columna"><option value="">Todas</option></select></div>
        <div class="campo"><label>Operación</label><select name="operacion"><option value="">Todas</option><option>INSERT</option><option>UPDATE</option><option>DELETE</option></select></div>
        <div class="campo"><label>Desde</label><input type="date" name="desde"></div>
        <div class="campo"><label>Hasta</label><input type="date" name="hasta"></div>
        <div class="campo"><label>Máx. filas</label><select name="limite"><option>100</option><option selected>500</option><option>2000</option><option>10000</option></select></div>
        <div class="campo"><button class="btn primario" type="submit">Buscar</button></div>
      </form>
      <div id="resultado-bitacora"></div>
    </div>`;
  const form = $("#filtros");
  const llenarColumnas = () => {
    const t = form.tabla_c.value;
    form.columna.innerHTML = `<option value="">Todas</option>` + cat.columnas.filter((c) => !t || `${c.esquema}.${c.tabla}` === t).map((c) => `<option>${esc(c.columna)}</option>`).join("");
  };
  form.tabla_c.onchange = llenarColumnas;
  llenarColumnas();
  const params = () => {
    const p = new URLSearchParams();
    const fd = new FormData(form);
    for (const [k, v] of fd) {
      if (!v) continue;
      if (k === "tabla_c") { const [e, t] = v.split("."); p.set("esquema", e); p.set("tabla", t); } else p.set(k, v);
    }
    return p;
  };
  const buscar = async () => {
    const cont = $("#resultado-bitacora");
    cont.innerHTML = '<div class="cargando">Consultando…</div>';
    try {
      const filas = await api(`/api/bitacora?${params()}`);
      cont.innerHTML = tablaBitacora(filas);
      activarFilasOperacion();
    } catch (e) { cont.innerHTML = `<div class="aviso error">${esc(e.message)}</div>`; }
  };
  form.onsubmit = (e) => { e.preventDefault(); buscar(); };
  $$("[data-fmt]").forEach((b) => (b.onclick = () => {
    const p = params(); p.set("formato", b.dataset.fmt); p.delete("limite");
    window.location = `/api/bitacora/exportar?${p}`;
  }));
  buscar();
}

function tablaBitacora(filas, { ocultar = [] } = {}) {
  if (!filas.length) return '<div class="vacio">No hay registros con los filtros seleccionados.</div>';
  const col = (k) => !ocultar.includes(k);
  return `<div style="padding:8px 16px;color:var(--tenue);font-size:12.5px">${num(filas.length)} registro(s). Haga clic en una fila para ver la operación completa.</div>
    <div class="tabla-cont"><table class="datos"><thead><tr>
      <th>Fecha/hora</th><th>Op.</th>${col("tabla") ? "<th>Tabla</th>" : ""}<th>Registro</th>${col("columna") ? "<th>Columna</th>" : ""}
      <th>Valor anterior</th><th>Valor nuevo</th>${col("usuario") ? "<th>Usuario</th>" : ""}<th>IP / Equipo</th></tr></thead><tbody>
    ${filas.map((r) => `<tr class="clic" data-enc="${r.encabezado_id}">
      <td style="white-space:nowrap">${fecha(r.fecha_hora)}</td><td>${op(r.operacion)}</td>
      ${col("tabla") ? `<td>${esc(r.esquema)}.${esc(r.tabla)}</td>` : ""}
      <td class="mono">${esc(llaveTxt(r.llave_registro))}</td>
      ${col("columna") ? `<td><b>${esc(r.columna)}</b></td>` : ""}
      <td class="valor anterior">${nulo(r.valor_anterior)}</td><td class="valor nuevo">${nulo(r.valor_nuevo)}</td>
      ${col("usuario") ? `<td>${esc(r.usuario)}${r.usuario_aplicacion && r.usuario_aplicacion !== r.usuario ? `<div class="nulo">app: ${esc(r.usuario_aplicacion)}</div>` : ""}</td>` : ""}
      <td><span class="mono">${esc(r.direccion_ip)}</span><div class="nulo">${esc(r.equipo)}</div></td></tr>`).join("")}
    </tbody></table></div>`;
}

function activarFilasOperacion() {
  $$("tr[data-enc]").forEach((tr) => (tr.onclick = () => verOperacion(tr.dataset.enc)));
}

async function verOperacion(id) {
  const o = await api(`/api/bitacora/operacion/${id}`);
  const ant = o.datos_anteriores || {}, nue = o.datos_nuevos || {};
  const claves = [...new Set([...Object.keys(ant), ...Object.keys(nue)])];
  const auditadas = new Set(o.detalle.map((d) => d.columna));
  const diff = `<table class="diff"><thead><tr><th>Columna</th><th>Antes</th><th>Después</th></tr></thead><tbody>
    ${claves.map((k) => {
      const a = ant[k], n = nue[k], cambio = o.operacion === "UPDATE" && JSON.stringify(a) !== JSON.stringify(n);
      return `<tr class="${cambio ? "cambiado" : ""}"><td>${esc(k)} ${auditadas.has(k) ? '<span class="chip pk">auditada</span>' : ""}</td>
        <td>${o.operacion === "INSERT" ? '<span class="nulo">—</span>' : nulo(a)}</td><td>${o.operacion === "DELETE" ? '<span class="nulo">— eliminado —</span>' : nulo(n)}</td></tr>`;
    }).join("")}</tbody></table>`;
  const historia = o.historial_registro.length ? `<h4 style="margin:22px 0 10px">Historial completo de este registro</h4><div class="linea">${o.historial_registro.map((h) => `
      <div class="hito ${h.operacion}"><div class="cuando">${fecha(h.fecha_hora)} · ${esc(h.usuario)} ${Number(h.encabezado_id) === Number(o.encabezado_id) ? "<b>(esta operación)</b>" : ""}</div>
      <div class="que">${op(h.operacion)} <span class="mono" style="white-space:pre-line;font-size:12px">${esc(h.cambios)}</span></div></div>`).join("")}</div>` : "";
  modal(`Operación #${o.encabezado_id} ${op(o.operacion)}`, `
    <div class="meta">
      <div><span>Tabla</span>${esc(o.esquema)}.${esc(o.tabla)}</div>
      <div><span>Registro (llave)</span><code>${esc(llaveTxt(o.llave_registro))}</code></div>
      <div><span>Fecha y hora</span>${fecha(o.fecha_hora)}</div>
      <div><span>Usuario BD</span>${esc(o.usuario)}</div>
      <div><span>Usuario aplicación</span>${esc(o.usuario_aplicacion || "—")}</div>
      <div><span>IP origen</span><code>${esc(o.direccion_ip)}</code></div>
      <div><span>Equipo</span>${esc(o.equipo)}</div>
      <div><span>Aplicación</span>${esc(o.aplicacion)}</div>
      <div><span>Transacción</span><code>${esc(o.transaccion_id)}</code></div>
    </div>
    <h4 style="margin:0 0 10px">Fila completa ${o.operacion === "DELETE" ? "(preservada tras la eliminación)" : ""}</h4>${diff}${historia}`);
}

/* ================================================================== POR USUARIO */
async function vUsuarios(usuario) {
  const cat = await catalogos(true);
  vista.innerHTML = cabecera("Historial por usuario", "Todas las modificaciones realizadas por un usuario de base de datos") + `
    <div class="usuarios-tarjetas">${cat.usuarios.map((u) => `
      <div class="tarjeta u-tarjeta ${u.usuario === usuario ? "sel" : ""}" data-u="${esc(u.usuario)}">
        <div class="nombre"><span class="avatar">${esc(u.usuario.slice(0, 2))}</span>${esc(u.usuario)}</div>
        <div class="nulo" style="font-style:normal;margin-top:6px">${num(u.operaciones)} operaciones · última ${fecha(u.ultima_actividad) || "—"}</div>
        <div class="mini-ops"><span class="op INSERT">${num(u.inserciones)} INS</span><span class="op UPDATE">${num(u.actualizaciones)} UPD</span><span class="op DELETE">${num(u.eliminaciones)} DEL</span></div>
      </div>`).join("") || '<div class="vacio">Aún no hay usuarios en la bitácora.</div>'}</div>
    <div id="hist-usuario"></div>`;
  $$(".u-tarjeta").forEach((t) => (t.onclick = () => (location.hash = `#usuarios/${encodeURIComponent(t.dataset.u)}`)));
  if (!usuario) return;
  const filas = await api(`/api/historial/usuario/${encodeURIComponent(usuario)}`);
  $("#hist-usuario").innerHTML = `<div class="tarjeta"><div class="tarjeta-titulo"><span>Cambios realizados por <b>${esc(usuario)}</b></span>
    <a class="btn chico" href="/api/bitacora/exportar?formato=xlsx&usuario=${encodeURIComponent(usuario)}">⇩ Excel</a></div>${tablaBitacora(filas, { ocultar: ["usuario"] })}</div>`;
  activarFilasOperacion();
}

/* ================================================================== POR COLUMNA */
async function vColumnas(esq, tab, col) {
  const cat = await catalogos(true);
  const actual = esq ? `${esq}.${tab}.${col}` : "";
  vista.innerHTML = cabecera("Historial por columna", "Evolución cronológica de los valores de una columna específica") + `
    <div class="tarjeta" style="margin-bottom:16px"><div class="filtros">
      <div class="campo" style="grid-column:span 2"><label>Columna auditada</label><select id="sel-col"><option value="">Seleccione…</option>
        ${cat.columnas.map((c) => { const v = `${c.esquema}.${c.tabla}.${c.columna}`; return `<option value="${esc(v)}" ${v === actual ? "selected" : ""}>${esc(v)}</option>`; }).join("")}</select></div>
      <div class="campo"><label>Desde</label><input type="date" id="c-desde"></div>
      <div class="campo"><label>Hasta</label><input type="date" id="c-hasta"></div>
      <div class="campo"><label>Vista</label><select id="c-vista"><option value="linea">Línea de tiempo</option><option value="tabla">Tabla</option></select></div>
    </div></div><div id="hist-columna"></div>`;
  const cargar = async () => {
    const v = $("#sel-col").value;
    if (!v) return ($("#hist-columna").innerHTML = '<div class="tarjeta"><div class="vacio">Seleccione una columna</div></div>');
    const [e, t, c] = v.split(".");
    const p = new URLSearchParams();
    if ($("#c-desde").value) p.set("desde", $("#c-desde").value);
    if ($("#c-hasta").value) p.set("hasta", $("#c-hasta").value + "T23:59:59");
    const filas = await api(`/api/historial/columna/${encodeURIComponent(e)}/${encodeURIComponent(t)}/${encodeURIComponent(c)}?${p}`);
    const cont = $("#hist-columna");
    if ($("#c-vista").value === "tabla") {
      cont.innerHTML = `<div class="tarjeta">${tablaBitacora(filas, { ocultar: ["tabla", "columna"] })}</div>`;
    } else if (!filas.length) {
      cont.innerHTML = '<div class="tarjeta"><div class="vacio">Esta columna no tiene cambios registrados en el período.</div></div>';
    } else {
      cont.innerHTML = `<div class="tarjeta"><div class="tarjeta-titulo"><span>${num(filas.length)} cambio(s) en <code>${esc(v)}</code></span>
        <a class="btn chico" href="/api/bitacora/exportar?formato=pdf&esquema=${encodeURIComponent(e)}&tabla=${encodeURIComponent(t)}&columna=${encodeURIComponent(c)}">⇩ PDF</a></div>
        <div class="cuerpo"><div class="linea">${filas.slice(0, 500).map((r) => `
        <div class="hito ${r.operacion}" data-enc="${r.encabezado_id}" style="cursor:pointer">
          <div class="cuando">${fecha(r.fecha_hora)} · <b>${esc(r.usuario)}</b> desde ${esc(r.direccion_ip)} (${esc(r.equipo)}) · registro <code>${esc(llaveTxt(r.llave_registro))}</code></div>
          <div class="que">${op(r.operacion)} <span class="cambio">${r.operacion !== "INSERT" ? `<span class="a">${nulo(r.valor_anterior)}</span> → ` : ""}${r.operacion !== "DELETE" ? `<span class="n">${nulo(r.valor_nuevo)}</span>` : '<span class="nulo">eliminado</span>'}</span></div>
        </div>`).join("")}</div>${filas.length > 500 ? '<div class="nulo">Se muestran los 500 más recientes; use la vista Tabla o exporte para ver todos.</div>' : ""}</div></div>`;
      $$(".hito[data-enc]").forEach((h) => (h.onclick = () => verOperacion(h.dataset.enc)));
    }
    activarFilasOperacion();
  };
  $("#sel-col").onchange = () => { const v = $("#sel-col").value; if (v) history.replaceState(null, "", `#columnas/${v.split(".").map(encodeURIComponent).join("/")}`); cargar(); };
  ["#c-desde", "#c-hasta", "#c-vista"].forEach((s) => ($(s).onchange = cargar));
  cargar();
}

/* ================================================================== DATOS (SIMULADOR) */
async function vDatos(esq, tab) {
  const tablas = await api("/api/datos/tablas");
  vista.innerHTML = cabecera("Datos (simulador de operaciones)",
    `Modifique datos de negocio como <b>${esc(SESION.usuario)}</b>. Los cambios en tablas auditadas quedan registrados en la bitácora con su usuario e IP.`) + `
    <div class="tarjeta" style="margin-bottom:16px"><div class="filtros">
      <div class="campo"><label>Tabla</label><select id="d-tabla"><option value="">Seleccione…</option>${tablas.map((t) => `<option value="${esc(t.esquema)}.${esc(t.tabla)}" ${t.esquema === esq && t.tabla === tab ? "selected" : ""}>${esc(t.esquema)}.${esc(t.tabla)}${t.auditada ? "  ● auditada" : ""}</option>`).join("")}</select></div>
    </div></div><div id="d-contenido"></div>`;
  $("#d-tabla").onchange = (e) => { if (e.target.value) location.hash = `#datos/${e.target.value.replace(".", "/")}`; };
  if (!esq) return ($("#d-contenido").innerHTML = '<div class="tarjeta"><div class="vacio">Seleccione una tabla para ver y modificar sus datos.</div></div>');

  const info = tablas.find((t) => t.esquema === esq && t.tabla === tab) || {};
  const d = await api(`/api/datos/${encodeURIComponent(esq)}/${encodeURIComponent(tab)}`);
  const pk = d.columnas.filter((c) => c.es_pk).map((c) => c.columna);
  const llaveDe = (f) => Object.fromEntries((pk.length ? pk : [d.columnas[0].columna]).map((k) => [k, f[k]]));
  $("#d-contenido").innerHTML = `<div class="tarjeta">
    <div class="tarjeta-titulo"><div>${esc(esq)}.<b>${esc(tab)}</b> ${info.auditada ? '<span class="estado ACTIVO">auditada</span>' : '<span class="estado">sin auditoría</span>'}
      <span class="nulo" style="font-style:normal;font-weight:400">· permisos: ${["insertar", "actualizar", "eliminar"].filter((p) => info[`puede_${p}`]).join(", ") || "solo lectura"}</span></div>
      ${info.puede_insertar ? '<button class="btn primario chico" id="d-nuevo">+ Nuevo registro</button>' : ""}</div>
    <div class="tabla-cont"><table class="datos compacta"><thead><tr>${d.columnas.map((c) => `<th>${esc(c.columna)}${c.es_pk ? " 🔑" : ""}</th>`).join("")}<th></th></tr></thead>
    <tbody>${d.filas.map((f, i) => `<tr>${d.columnas.map((c) => `<td>${/^\d{4}-\d\d-\d\dT/.test(f[c.columna] || "") ? fecha(f[c.columna]) : nulo(f[c.columna])}</td>`).join("")}
      <td style="white-space:nowrap">${info.puede_actualizar ? `<button class="btn chico" data-edit="${i}">Editar</button>` : ""}
      ${info.puede_eliminar ? `<button class="btn chico peligro" data-del="${i}">Eliminar</button>` : ""}</td></tr>`).join("")}</tbody></table></div></div>`;

  const formulario = (fila) => `<div class="formulario">${d.columnas.map((c) => {
    const auto = !fila && (c.defecto?.startsWith("nextval") || c.identidad);
    const v = fila ? fila[c.columna] : "";
    const ro = (fila && c.es_pk) || auto;
    return `<div class="campo"><label>${esc(c.columna)} <span style="text-transform:none;font-weight:400">(${esc(c.tipo)})</span></label>
      <input type="text" data-c="${esc(c.columna)}" value="${esc(v ?? "")}" ${ro ? "disabled" : ""} placeholder="${auto ? "automático" : c.defecto ? "defecto: " + esc(c.defecto) : c.requerido ? "requerido" : "opcional"}"></div>`;
  }).join("")}</div>`;
  const valores = (raiz, original) => {
    const out = {};
    $$("input[data-c]:not([disabled])", raiz).forEach((i) => {
      const k = i.dataset.c;
      if (!original || String(original[k] ?? "") !== i.value) out[k] = i.value;
    });
    return out;
  };
  const recargar = () => vDatos(esq, tab);
  const nuevo = $("#d-nuevo");
  if (nuevo) nuevo.onclick = () => {
    const m = modal(`Nuevo registro en ${esq}.${tab}`, formulario(null), `<button class="btn primario" id="m-ok">Insertar</button>`);
    $("#m-ok").onclick = async () => {
      try { await api(`/api/datos/${esq}/${tab}`, { method: "POST", body: { valores: valores(m.raiz) } }); m.cerrar(); toast("Registro insertado", "ok"); recargar(); }
      catch (e) { toast(e.message, "error"); }
    };
  };
  $$("[data-edit]").forEach((b) => (b.onclick = () => {
    const fila = d.filas[b.dataset.edit];
    const m = modal(`Editar registro ${esc(llaveTxt(llaveDe(fila)))}`, formulario(fila), `<button class="btn primario" id="m-ok">Guardar cambios</button>`);
    $("#m-ok").onclick = async () => {
      const v = valores(m.raiz, fila);
      if (!Object.keys(v).length) return toast("No hay cambios");
      try { await api(`/api/datos/${esq}/${tab}`, { method: "PUT", body: { valores: v, llave: llaveDe(fila) } }); m.cerrar(); toast("Registro actualizado", "ok"); recargar(); }
      catch (e) { toast(e.message, "error"); }
    };
  }));
  $$("[data-del]").forEach((b) => (b.onclick = async () => {
    const fila = d.filas[b.dataset.del];
    if (!confirm(`¿Eliminar el registro ${llaveTxt(llaveDe(fila))}?`)) return;
    try { await api(`/api/datos/${esq}/${tab}`, { method: "DELETE", body: { valores: {}, llave: llaveDe(fila) } }); toast("Registro eliminado (sus datos quedan preservados en la bitácora)", "ok"); recargar(); }
    catch (e) { toast(e.message, "error"); }
  }));
}

/* ================================================================== GENERADOR */
async function vGenerador() {
  const log = await api("/api/log");
  vista.innerHTML = cabecera("Registro del generador de triggers", "Historial de generación, eliminación, validación y cambios de estructura (DDL) detectados") + `
    <div class="tarjeta">${log.length ? `<div class="tabla-cont"><table class="datos"><thead><tr><th>Fecha/hora</th><th>Acción</th><th>Tabla</th><th>Resultado</th><th>Mensaje</th><th>Usuario</th><th></th></tr></thead><tbody>
    ${log.map((l, i) => `<tr><td style="white-space:nowrap">${fecha(l.fecha_hora)}</td><td><span class="chip">${esc(l.accion)}</span></td>
      <td>${l.tabla ? `${esc(l.esquema)}.${esc(l.tabla)}` : "—"}</td><td>${l.exito ? '<span class="estado ACTIVO">OK</span>' : '<span class="estado ERROR">ERROR</span>'}</td>
      <td style="max-width:420px">${esc(l.mensaje)}</td><td>${esc(l.usuario)}</td>
      <td>${l.sql_ejecutado ? `<button class="btn chico" data-sql="${i}">SQL</button>` : ""}</td></tr>`).join("")}
    </tbody></table></div>` : '<div class="vacio">Sin registros</div>'}</div>`;
  $$("[data-sql]").forEach((b) => (b.onclick = () => modal("SQL ejecutado", `<pre class="codigo">${resaltarSQL(log[b.dataset.sql].sql_ejecutado)}</pre>`)));
}

/* ================================================================== PARÁMETROS */
async function vParametros() {
  const [params, cat] = await Promise.all([api("/api/parametros"), catalogos(true)]);
  const p = Object.fromEntries(params.map((x) => [x.clave, x]));
  const admin = SESION.es_admin;
  vista.innerHTML = cabecera("Parámetros del sistema", "Políticas globales de privacidad y retención") + `
    <div class="rejilla r-2">
      <div class="tarjeta"><h3>Privacidad de la IP de origen</h3><div class="cuerpo">
        <p style="margin-top:0;color:var(--tenue)">${esc(p.ip_modo.descripcion)}</p>
        <div class="campo"><label>Modo</label><select id="p-ip" ${admin ? "" : "disabled"}>
          ${[["completa", "Completa — se guarda la IP exacta"], ["anonimizada", "Anonimizada — IPv4 /24, IPv6 /48"], ["ninguna", "Ninguna — no se registra la IP"]].map(([v, t]) => `<option value="${v}" ${p.ip_modo.valor === v ? "selected" : ""}>${t}</option>`).join("")}</select></div>
        <div class="aviso info">El cambio aplica a los registros nuevos. Las IPs ya registradas no se modifican (la bitácora es inmutable).</div>
      </div></div>
      <div class="tarjeta"><h3>Retención</h3><div class="cuerpo">
        <p style="margin-top:0;color:var(--tenue)">${esc(p.dias_retencion.descripcion)}</p>
        <div class="campo"><label>Días</label><input type="number" min="1" id="p-ret" value="${esc(p.dias_retencion.valor)}" ${admin ? "" : "disabled"}></div>
        <div class="aviso info">La depuración la ejecuta un superusuario con <code>SELECT auditoria.fn_purgar_bitacora();</code></div>
      </div></div>
    </div>
    ${admin ? '<div style="margin:16px 0;text-align:right"><button class="btn primario" id="p-guardar">Guardar parámetros</button></div>' : ""}
    <div class="tarjeta" style="margin-top:16px"><h3>Estaciones de trabajo registradas</h3><div class="tabla-cont"><table class="datos">
      <thead><tr><th>#</th><th>Dirección IP</th><th>Equipo</th><th>Aplicación</th><th>Primera actividad</th><th>Operaciones</th></tr></thead>
      <tbody>${cat.estaciones.map((s) => `<tr><td>${s.estacion_id}</td><td class="mono">${esc(s.direccion_ip)}</td><td>${esc(s.equipo)}</td><td>${esc(s.aplicacion)}</td><td>${fecha(s.primera_actividad)}</td><td>${num(s.operaciones)}</td></tr>`).join("") || '<tr><td colspan="6" class="vacio">Sin estaciones</td></tr>'}</tbody></table></div></div>`;
  if (admin) $("#p-guardar").onclick = async () => {
    try {
      await api("/api/parametros/ip_modo", { method: "PUT", body: { valor: $("#p-ip").value } });
      await api("/api/parametros/dias_retencion", { method: "PUT", body: { valor: $("#p-ret").value } });
      toast("Parámetros guardados", "ok");
    } catch (e) { toast(e.message, "error"); }
  };
}

/* ------------------------------------------------------------------ arranque */
iniciar();
