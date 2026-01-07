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
LOCAL_URL_NO_SLASH="${LOCAL_URL%/}"

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

# Sleep only if kiosk.service became active very recently (Chromium spawn grace period)
# ActiveEnterTimestampMonotonic is microseconds since boot when unit entered active state.
enter_us="$(systemctl show -p ActiveEnterTimestampMonotonic --value kiosk.service 2>/dev/null || echo 0)"
now_us="$(awk '{print int($1*1000000)}' /proc/uptime 2>/dev/null || echo 0)"

if [[ "$enter_us" =~ ^[0-9]+$ ]] && [[ "$now_us" =~ ^[0-9]+$ ]] && (( enter_us > 0 && now_us > enter_us )); then
  age_sec=$(( (now_us - enter_us) / 1000000 ))
  if (( age_sec < START_GRACE_SEC )); then
    log "kiosk.service ist frisch (${age_sec}s) -> sleep ${POST_START_SLEEP}s"
    sleep "${POST_START_SLEEP}"
  fi
else
  # Fallback: keep a small grace period if monotonic timing isn't available
  sleep 2
fi

# 1) Chromium vorhanden? (konkret auf unser App-Flag)
# Achtung: Argument kann je nach Chromium-Version minimal anders gequotet sein; wir matchen den URL-Teil.
if ! pgrep -u kiosk -f -- "--app=${LOCAL_URL}" >/dev/null 2>&1 \
   && ! pgrep -u kiosk -f -- "--app=${LOCAL_URL_NO_SLASH}" >/dev/null 2>&1
then
  log "Chromium-Prozess nicht gefunden (erwartet --app=${LOCAL_URL} or ${LOCAL_URL_NO_SLASH}) -> restart kiosk.service"
  systemctl restart kiosk.service
  exit 0
fi

# 2) X antwortet? (als kiosk, damit XAUTH passt)
# NEW: explicitly provide XAUTHORITY (with a small fallback if the default path doesn't exist)
if [[ ! -r "$XAUTHORITY_PATH" ]]; then
  for p in "/run/user/1000/gdm/Xauthority" "/run/user/1000/.Xauthority" "/home/kiosk/.Xauthority"; do
    if [[ -r "$p" ]]; then
      XAUTHORITY_PATH="$p"
      break
    fi
  done
fi

if ! timeout "${X_TIMEOUT}"s \
  runuser -u kiosk -- env DISPLAY="${DISPLAY_NUM}" XAUTHORITY="${XAUTHORITY_PATH}" xset q >/dev/null 2>&1
then
  log "X-Server antwortet nicht (DISPLAY=${DISPLAY_NUM}, XAUTHORITY=${XAUTHORITY_PATH}) -> restart kiosk.service"
  systemctl restart kiosk.service
  exit 0
fi

# 3) Lokale Seite erreichbar?
if ! curl -fsS \
  --connect-timeout 1 \
  --max-time "${HTTP_TIMEOUT}" \
  --retry 2 --retry-delay 0 --retry-connrefused \
  "${LOCAL_URL}" >/dev/null 2>&1
then
  log "localhost-Seite (${LOCAL_URL}) nicht erreichbar -> restart kiosk-web.service; recheck; then kiosk.service"
  systemctl restart kiosk-web.service
  sleep 2
  if ! curl -fsS --connect-timeout 1 --max-time "${HTTP_TIMEOUT}" "${LOCAL_URL}" >/dev/null 2>&1; then
    systemctl restart kiosk.service
  fi
  exit 0
fi


exit 0
