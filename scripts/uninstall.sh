#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/golden-plate"
SERVICE_NAME="kiosk-controller.service"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit sudo ausführen."
  exit 1
fi

systemctl disable --now "${SERVICE_NAME}" || true
rm -f "/etc/systemd/system/${SERVICE_NAME}"
systemctl daemon-reload

rm -rf "${APP_DIR}"

echo "Deinstalliert."
echo "Hinweis: /etc/kiosk-controller.json und /etc/default/kiosk-controller wurden NICHT gelöscht."