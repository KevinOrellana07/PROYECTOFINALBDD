#!/usr/bin/env bash
# AutoAudit - inicia la aplicación web en http://localhost:8000
#   bash run.sh            (solo en este equipo)
#   bash run.sh --red      (accesible desde otros equipos de la red)
set -euo pipefail
cd "$(dirname "$0")/app"
if [[ ! -x .venv/bin/uvicorn ]]; then
    echo "Primero ejecute: sudo bash install.sh"; exit 1
fi
HOST=127.0.0.1; [[ "${1:-}" == "--red" ]] && HOST=0.0.0.0
PUERTO="${PUERTO:-8000}"
echo "AutoAudit en http://localhost:$PUERTO   (Ctrl+C para detener)"
( sleep 2; command -v xdg-open >/dev/null && xdg-open "http://localhost:$PUERTO" >/dev/null 2>&1 || true ) &
exec .venv/bin/uvicorn main:app --host "$HOST" --port "$PUERTO"
