#!/usr/bin/env bash
# =====================================================================
# AutoAudit - Ejecuta todas las pruebas de validación
#   sudo bash pruebas/ejecutar_pruebas.sh           (todas)
#   sudo bash pruebas/ejecutar_pruebas.sh --rapido  (sin rendimiento)
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"
DB=autoaudit_db
PSQL="sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 -d $DB"

ARCHIVOS=(00_preparar.sql 01_prueba_insert.sql 02_prueba_update.sql 03_prueba_delete.sql 04_prueba_seguridad.sql)
[[ "${1:-}" != "--rapido" ]] && ARCHIVOS+=(05_prueba_rendimiento.sql)

for f in "${ARCHIVOS[@]}"; do
    # psql muestra los WARNING como "psql:archivo:linea: WARNING:"; se limpian para leer mejor
    $PSQL < "$f" 2>&1 | sed -E 's/^psql:[^ ]+ WARNING: +//'
done

echo
echo "================ RESUMEN ================"
$PSQL -P footer=off -c "
SELECT count(*) FILTER (WHERE exito)     AS pasaron,
       count(*) FILTER (WHERE NOT exito) AS fallaron,
       count(*)                          AS total
  FROM pruebas.resultado;"
FALLAS=$($PSQL -t -A -c "SELECT count(*) FROM pruebas.resultado WHERE NOT exito")
if [[ "$FALLAS" == "0" ]]; then
    echo "TODAS LAS PRUEBAS PASARON"
else
    echo "HAY $FALLAS PRUEBA(S) FALLIDA(S):"
    $PSQL -c "SELECT prueba, detalle FROM pruebas.resultado WHERE NOT exito"
    exit 1
fi
