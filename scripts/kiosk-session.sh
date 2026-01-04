#!/usr/bin/env bash
set -euo pipefail

# Minimaler X/Openbox Kiosk-Start:
# - DBUS (für manche Desktop-Komponenten/Firefox stabiler)
# - Openbox
# - kiosk-controller im Vordergrund (damit systemd Restart sauber funktioniert)

if command -v dbus-launch >/dev/null 2>&1; then
  eval "$(dbus-launch --sh-syntax)"
fi

# Openbox starten (im Hintergrund)
openbox-session &

# kiosk-controller starten (im Vordergrund)
exec /opt/golden-plate/venv/bin/kiosk-controller --config /etc/kiosk-controller.json