#!/usr/bin/env bash
# =====================================================================
# AutoAudit - instala/actualiza la base de datos (ejecutar con sudo)
#   sudo bash sql/instalar_bd.sh
# Los scripts son idempotentes: puede ejecutarse varias veces.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"
DB=autoaudit_db
PSQL="psql -v ON_ERROR_STOP=1 -q"

# El archivo se pasa por entrada estándar: así el usuario postgres no necesita
# permisos de lectura sobre la carpeta personal donde está el proyecto.
run() { echo "  -> $1"; sudo -u postgres $PSQL "${@:2}" < "$1"; }

echo "== Instalando AutoAudit en PostgreSQL =="
run 00_roles_y_bd.sql        -d postgres
run 01_esquema.sql           -d $DB
run 02_diccionario.sql       -d $DB
run 03_funciones_config.sql  -d $DB
run 04_generador_triggers.sql -d $DB
run 05_consultas.sql         -d $DB
run 06_seguridad.sql         -d $DB
run 07_eventos_ddl.sql       -d $DB
run 08_datos_demo.sql        -d $DB
run 09_comentarios.sql       -d $DB
echo "== Base de datos lista: $DB =="
