#!/bin/bash
set -euo pipefail

LOCK="/run/kiosk-monitor.lock"

DISPLAY_NUM=":0"
LOCAL_URL="http://127.0.0.1:8088/"
X_TIMEOUT="2"
HTTP_TIMEOUT="2"

log() { echo "kiosk-monitor: $*"; }

exec 9>"$LOCK"
if ! flock -n 9; then
  exit 0
fi

# Wenn kiosk.service gerade startet, nicht reinfunken (Race vermeiden)
if systemctl is-activating --quiet kiosk.service; then
  log "kiosk.service startet gerade -> skip"
  exit 0
fi

# Wenn kiosk.service gerade erst gestartet ist, 5s warten (Chromium Spawn)
sleep 5

# 1) Chromium vorhanden? (robust: auf das Kiosk-Flag prüfen)
if ! pgrep -u kiosk -fa '/usr/lib/chromium/chromium' | grep -q -- '--kiosk'; then
  log "Chromium-Kiosk-Prozess nicht gefunden -> restart kiosk.service"
  systemctl restart kiosk.service
  exit 0
fi

# 2) X antwortet?
if ! timeout "${X_TIMEOUT}"s env DISPLAY="${DISPLAY_NUM}" xset q >/dev/null 2>&1; then
  log "X-Server antwortet nicht -> restart kiosk.service"
  systemctl restart kiosk.service
  exit 0
fi

# 3) Lokale Seite erreichbar?
if ! curl -fsS --max-time "${HTTP_TIMEOUT}" "${LOCAL_URL}" >/dev/null 2>&1; then
  log "localhost-Seite nicht erreichbar -> restart kiosk-web.service + kiosk.service"
  systemctl restart kiosk-web.service
  systemctl restart kiosk.service
  exit 0
fi

exit 0