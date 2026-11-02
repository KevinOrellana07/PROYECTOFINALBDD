# AutoAudit — Sistema de auditoría automatizado

Proyecto del curso · Universidad Mariano Gálvez de Guatemala
PostgreSQL 18 · PL/pgSQL · Python (FastAPI) · Ubuntu 26.04 LTS

AutoAudit permite elegir, desde el **diccionario de datos** de PostgreSQL, qué tablas y columnas auditar y qué
eventos (INSERT, UPDATE, DELETE) registrar. A partir de esa configuración **genera automáticamente los triggers**
que guardan cada cambio en una **bitácora centralizada**, con usuario, fecha/hora, IP y estación de trabajo, y
ofrece consultas históricas por usuario y por columna con exportación a CSV, Excel y PDF.

## Inicio rápido

```bash
cd autoaudit
sudo bash install.sh                    # PostgreSQL + BD + generador + demo + entorno Python
bash run.sh                             # abre http://localhost:8000
sudo bash pruebas/ejecutar_pruebas.sh   # 39 pruebas de validación (+ rendimiento)
```

| Usuario           | Contraseña     | Rol                                   |
|-------------------|----------------|---------------------------------------|
| `admin_auditoria` | `Admin123!`    | Configura la auditoría y consulta     |
| `auditor`         | `Auditor123!`  | Solo consulta la bitácora             |
| `vendedor`        | `Vendedor123!` | Usuario operativo (clientes, pedidos) |
| `bodeguero`       | `Bodega123!`   | Usuario operativo (productos)         |

**En Windows** (PostgreSQL + pgAdmin ya instalados): doble clic en `instalar_windows.bat` y luego en `iniciar_windows.bat`.

La guía detallada está en **[GUIA_PASO_A_PASO.md](GUIA_PASO_A_PASO.md)**.

## Estructura

```
autoaudit/
├── install.sh                 Instalador para Ubuntu 26.04
├── run.sh                     Inicia la aplicación web
├── sql/                       Scripts de la base de datos (en orden)
│   ├── 00_roles_y_bd.sql        roles de seguridad, usuarios demo, BD
│   ├── 01_esquema.sql           tablas del sistema (modelo E-R)
│   ├── 02_diccionario.sql       consultas al diccionario de datos del DBMS
│   ├── 03_funciones_config.sql  módulo de configuración + validaciones
│   ├── 04_generador_triggers.sql generación dinámica de triggers
│   ├── 05_consultas.sql         consultas parametrizadas de historial
│   ├── 06_seguridad.sql         permisos y bitácora inmutable
│   ├── 07_eventos_ddl.sql       dependencias (DROP/ALTER de tablas auditadas)
│   ├── 08_datos_demo.sql        esquema de ejemplo "tienda"
│   ├── 09_comentarios.sql       descripciones del diccionario
│   └── instalar_bd.sh
├── app/                       Servidor (FastAPI) e interfaz web
├── ejemplos/                  Ejemplos de uso (configurar, generar actividad, consultar)
├── pruebas/                   Casos de prueba INSERT/UPDATE/DELETE/seguridad/rendimiento
└── docs/                      Documentación técnica (PDF), diagrama E-R, diccionario
```

## Requisitos del enunciado → dónde están

| Requisito | Implementación |
|---|---|
| Consultas al diccionario de datos | `sql/02_diccionario.sql` (`v_dic_tablas`, `v_dic_columnas`, `v_dic_llaves`, `v_dic_triggers`) |
| Selección de tablas, columnas y eventos | `fn_registrar_tabla`, `fn_configurar_columna`, pantalla **Configuración** |
| Validar existencia antes de activar | `fn_validar_configuracion` (contra `pg_catalog`) |
| Triggers AFTER generados, uno por tabla | `fn_construir_sql_trigger`, `fn_generar_trigger` |
| Gestión de dependencias | `07_eventos_ddl.sql` (event triggers DROP/ALTER) |
| Bitácora centralizada normalizada | `bitacora_encabezado` + `bitacora_detalle` |
| Valores antiguos y nuevos, usuario, fecha, IP | `valor_anterior/valor_nuevo`, `usuario_auditado`, `estacion_trabajo` |
| Preserva datos aunque se elimine el registro | `datos_anteriores` (fila completa en jsonb) |
| Consulta por usuario / por columna | `fn_historial_usuario`, `fn_historial_columna` |
| Exportación de reportes | CSV, Excel y PDF desde la pantalla **Bitácora** |
| Solo admins configuran | rol `autoaudit_admin` + `fn_verificar_admin` |
| Sin escritura directa en bitácora | solo `autoaudit_owner` inserta; trigger de inmutabilidad |
| Privacidad de IP | parámetro `ip_modo` (completa / anonimizada / ninguna) |
| Pruebas y rendimiento | `pruebas/` |
