#!/bin/bash
set -euo pipefail

LOCK="/run/kiosk-monitor.lock"
ENV_FILE="/opt/golden-plate/etc/golden-plate.env"

# Defaults
LOCAL_HOST="127.0.0.1"
LOCAL_PORT="8088"
DISPLAY_NUM=":0"
X_TIMEOUT="2"
HTTP_TIMEOUT="2"

log() { echo "kiosk-monitor: $*"; }

# Env laden (wenn vorhanden)
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

LOCAL_HOST="${LOCAL_HOST:-127.0.0.1}"
LOCAL_PORT="${LOCAL_PORT:-8088}"
LOCAL_URL="http://${LOCAL_HOST}:${LOCAL_PORT}/"

exec 9>"$LOCK"
if ! flock -n 9; then
  exit 0
fi

# Wenn kiosk.service absichtlich gestoppt ist: nichts tun
if ! systemctl is-active --quiet kiosk.service; then
  exit 0
fi

# Wenn kiosk.service gerade startet, nicht reinfunken (Race vermeiden)
sub="$(systemctl show -p SubState --value kiosk.service 2>/dev/null || true)"
if [[ "$sub" == "start"* || "$sub" == "auto-restart" ]]; then
  log "kiosk.service startet gerade (SubState=$sub) -> skip"
  exit 0
fi

# Wenn kiosk.service gerade erst gestartet ist, kurz warten (Chromium Spawn)
sleep 5

# 1) Chromium vorhanden? (konkret auf unser App-Flag)
# Achtung: Argument kann je nach Chromium-Version minimal anders gequotet sein; wir matchen den URL-Teil.
if ! pgrep -u kiosk -f " --app=${LOCAL_URL}" >/dev/null 2>&1; then
  log "Chromium-Prozess nicht gefunden (erwartet --app=${LOCAL_URL}) -> restart kiosk.service"
  systemctl restart kiosk.service
  exit 0
fi

# 2) X antwortet? (als kiosk, damit XAUTH passt)
if ! timeout "${X_TIMEOUT}"s \
  runuser -u kiosk -- env DISPLAY="${DISPLAY_NUM}" xset q >/dev/null 2>&1
then
  log "X-Server antwortet nicht -> restart kiosk.service"
  systemctl restart kiosk.service
  exit 0
fi

# 3) Lokale Seite erreichbar?
if ! curl -fsS --max-time "${HTTP_TIMEOUT}" "${LOCAL_URL}" >/dev/null 2>&1; then
  log "localhost-Seite (${LOCAL_URL}) nicht erreichbar -> restart kiosk-web.service + kiosk.service"
  systemctl restart kiosk-web.service
  systemctl restart kiosk.service
  exit 0
fi

exit 0
