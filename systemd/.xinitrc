#!/usr/bin/env bash
set -e

# DBus (stabiler für Firefox)
if command -v dbus-launch >/dev/null 2>&1; then
  eval "$(dbus-launch --sh-syntax)"
fi

openbox-session &

exec /opt/golden-plate/venv/bin/kiosk-controller --config /etc/kiosk-controller.json
