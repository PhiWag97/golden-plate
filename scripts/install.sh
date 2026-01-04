#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/golden-plate"
VENV_DIR="${APP_DIR}/venv"
SERVICE_NAME="kiosk-controller.service"
CFG_DST="/etc/kiosk-controller.json"
ENV_DST="/etc/default/kiosk-controller"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit sudo ausführen."
  exit 1
fi

echo "[1/8] Pakete installieren…"
apt-get update
apt-get install -y \
  python3 python3-venv \
  iproute2 \
  wmctrl xdotool \
  rsync \
  firefox-esr || true

if ! command -v firefox-esr >/dev/null 2>&1 && ! command -v firefox >/dev/null 2>&1; then
  apt-get install -y firefox || true
fi

echo "[2/8] App nach ${APP_DIR} kopieren…"
mkdir -p "${APP_DIR}"
rsync -a --delete ./ "${APP_DIR}/"

echo "[3/8] Virtualenv erstellen…"
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip
"${VENV_DIR}/bin/pip" install -e "${APP_DIR}"

echo "[4/8] Sample-Config nach ${CFG_DST} (falls nicht vorhanden)…"
if [[ ! -f "${CFG_DST}" ]]; then
  install -m 0644 "${APP_DIR}/config/kiosk-controller.sample.json" "${CFG_DST}"
  echo "  -> ${CFG_DST} angelegt (bitte bei Bedarf anpassen)."
else
  echo "  -> ${CFG_DST} existiert bereits, wird nicht überschrieben."
fi

echo "[5/8] Env-Override-Datei nach ${ENV_DST} (falls nicht vorhanden)…"
if [[ ! -f "${ENV_DST}" ]]; then
  cat >"${ENV_DST}" <<'ENV'
# Optionale Env-Overrides für kiosk-controller
# Beispiele:
# KIOSK_DISCOVERY_WORKERS=32
# KIOSK_AIDA_PORT=1111
# KIOSK_DISPLAY=:0
# KIOSK_XAUTHORITY=/home/user/.Xauthority
ENV
  chmod 0644 "${ENV_DST}"
  echo "  -> ${ENV_DST} angelegt."
else
  echo "  -> ${ENV_DST} existiert bereits, wird nicht überschrieben."
fi

echo "[6/8] systemd Service installieren…"
install -m 0644 "${APP_DIR}/systemd/${SERVICE_NAME}" "/etc/systemd/system/${SERVICE_NAME}"

echo "[7/8] systemd reload + enable…"
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo "[8/8] Status…"
systemctl --no-pager status "${SERVICE_NAME}" || true

echo "Fertig."
echo "Install-Dir: ${APP_DIR}"
echo "Logs: journalctl -u ${SERVICE_NAME} -f"
echo "Config: ${CFG_DST}"
echo "Env:    ${ENV_DST}"