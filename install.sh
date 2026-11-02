#!/usr/bin/env bash
# =====================================================================
# AutoAudit - Instalador completo para Ubuntu 26.04 LTS
#   cd autoaudit
#   sudo bash install.sh            (instala todo + datos de demostración)
#   sudo bash install.sh --sin-demo (sin configuración ni actividad de ejemplo)
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"
RAIZ="$(pwd)"
DEMO=1; [[ "${1:-}" == "--sin-demo" ]] && DEMO=0

verde() { printf "\e[32m%s\e[0m\n" "$*"; }
azul()  { printf "\n\e[1;34m== %s ==\e[0m\n" "$*"; }
rojo()  { printf "\e[31m%s\e[0m\n" "$*"; }

if [[ $EUID -ne 0 ]]; then
    rojo "Ejecute con sudo:  sudo bash install.sh"; exit 1
fi
USUARIO_REAL="${SUDO_USER:-$(id -un)}"

# ---------------------------------------------------------------------
azul "1/5 Paquetes del sistema (PostgreSQL y Python)"
# ---------------------------------------------------------------------
apt-get update -qq
if ! command -v psql >/dev/null; then
    # Ubuntu 26.04 incluye PostgreSQL 18 en sus repositorios oficiales
    apt-get install -y -qq postgresql postgresql-contrib
fi
apt-get install -y -qq python3 python3-venv python3-pip
systemctl enable --now postgresql >/dev/null 2>&1 || service postgresql start

VERSION=$(sudo -u postgres psql -tAc "SHOW server_version_num")
MAYOR=$((VERSION / 10000))
verde "PostgreSQL $MAYOR detectado"
if (( MAYOR < 14 )); then
    rojo "Se requiere PostgreSQL 14 o superior (el proyecto está pensado para PostgreSQL 18)."; exit 1
elif (( MAYOR < 18 )); then
    echo "Aviso: el proyecto especifica PostgreSQL 18; funcionará con $MAYOR pero instale 18 para la entrega."
fi

# ---------------------------------------------------------------------
azul "2/5 Base de datos, esquema de auditoría, generador y seguridad"
# ---------------------------------------------------------------------
bash sql/instalar_bd.sh

# ---------------------------------------------------------------------
if (( DEMO )); then
    azul "3/5 Configuración y actividad de demostración"
    sudo -u postgres psql -q -d autoaudit_db < ejemplos/01_configurar_demo.sql >/dev/null
    sudo -u postgres psql -q -d autoaudit_db < ejemplos/02_generar_actividad.sql >/dev/null
    verde "Tablas tienda.* configuradas y con actividad de ejemplo"
else
    azul "3/5 (omitido: --sin-demo)"
fi

# ---------------------------------------------------------------------
azul "4/5 Entorno Python de la aplicación web"
# ---------------------------------------------------------------------
sudo -u "$USUARIO_REAL" python3 -m venv app/.venv
sudo -u "$USUARIO_REAL" app/.venv/bin/pip install -q --upgrade pip
sudo -u "$USUARIO_REAL" app/.venv/bin/pip install -q -r app/requirements.txt
[[ -f app/.env ]] || sudo -u "$USUARIO_REAL" cp app/.env.example app/.env
verde "Dependencias instaladas en app/.venv"

# ---------------------------------------------------------------------
azul "5/5 Verificación"
# ---------------------------------------------------------------------
sudo -u postgres psql -d autoaudit_db -c "
SELECT esquema || '.' || tabla AS tabla, estado, eventos, sincronizado
  FROM auditoria.v_estado_auditoria WHERE estado <> 'HUERFANA' ORDER BY 1;"

verde "Instalación completada."
echo
echo "  Iniciar la aplicación:   bash run.sh"
echo "  Abrir en el navegador:   http://localhost:8000"
echo "  Ejecutar las pruebas:    sudo bash pruebas/ejecutar_pruebas.sh"
echo
echo "  Usuarios: admin_auditoria / Admin123!   auditor / Auditor123!"
echo "            vendedor / Vendedor123!       bodeguero / Bodega123!"
