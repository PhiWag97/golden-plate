#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${1:-golden-plate.service}"
CFG="${KIOSK_CONFIG:-/etc/kiosk-controller.json}"

say() { printf "\n== %s ==\n" "$*"; }
kv() { printf "%-24s %s\n" "$1" "${2:-}"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "Basic"
kv "Host" "$(hostname)"
kv "Kernel" "$(uname -a)"
kv "Uptime" "$(uptime -p 2>/dev/null || true)"
kv "Default target" "$(systemctl get-default 2>/dev/null || true)"
kv "Service param" "${SERVICE_NAME}"
kv "Config path" "${CFG}"

say "Service status"
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
  systemctl --no-pager status "${SERVICE_NAME}" || true
else
  echo "Service '${SERVICE_NAME}' not installed."
fi

say "Recent service logs (last 120 lines)"
journalctl -u "${SERVICE_NAME}" -n 120 --no-pager 2>/dev/null || true

say "Processes"
ps -ef | grep -E "Xorg|Xwayland|openbox|firefox|kiosk-controller" | grep -v grep || true

say "X11 / Display"
kv "DISPLAY (env)" "${DISPLAY:-<unset>}"
kv "XAUTHORITY (env)" "${XAUTHORITY:-<unset>}"
kv "/tmp/.X11-unix" "$(ls -l /tmp/.X11-unix 2>/dev/null | wc -l | tr -d ' ') entries"
ls -l /tmp/.X11-unix 2>/dev/null || true

# Versuch: Service-User aus systemd ermitteln (falls vorhanden)
SERVICE_USER=""
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
  SERVICE_USER="$(systemctl show -p User --value "${SERVICE_NAME}" 2>/dev/null || true)"
fi
if [[ -n "${SERVICE_USER}" ]]; then
  HOME_DIR="$(getent passwd "${SERVICE_USER}" | cut -d: -f6 || true)"
  kv "Service User" "${SERVICE_USER}"
  kv "Service Home" "${HOME_DIR}"
  if [[ -n "${HOME_DIR}" ]]; then
    kv ".Xauthority" "${HOME_DIR}/.Xauthority"
    ls -l "${HOME_DIR}/.Xauthority" 2>/dev/null || true
  fi
fi

say "Tools"
for t in ip startx Xorg openbox-session wmctrl xdotool firefox firefox-esr fc-cache fc-list; do
  if have "${t}"; then
    kv "${t}" "$(command -v "${t}")"
  else
    kv "${t}" "MISSING"
  fi
done

say "Fonts quick check"
if have fc-list; then
  echo "Roboto matches:"
  fc-list | grep -i "roboto" | head -n 5 || true
  echo
  echo "Noto Sans matches:"
  fc-list | grep -i "noto sans" | head -n 5 || true
  echo
  echo "DejaVu matches:"
  fc-list | grep -i "dejavu sans" | head -n 5 || true
else
  echo "fc-list not available."
fi

say "Network"
if have ip; then
  kv "Default route" "$(ip route show default 2>/dev/null | head -n 1 || true)"
  echo "IP addresses:"
  ip -br addr 2>/dev/null || true
  echo
  echo "DNS resolv.conf:"
  cat /etc/resolv.conf 2>/dev/null || true
fi
if have ping; then
  echo
  echo "Ping 1.1.1.1:"
  ping -c1 -W1 1.1.1.1 2>/dev/null && echo "OK" || echo "FAIL"
fi

say "Config summary (best effort)"
if [[ -f "${CFG}" ]]; then
  kv "Config exists" "yes"
  # Zeige relevante Keys ohne jq-Abhängigkeit
  egrep -n '"(aida_port|aida_health_path|default_display|default_xauthority|cache_dir|cache_file|profile_dir|splash_file|log_file)"' "${CFG}" || true
else
  kv "Config exists" "NO"
fi

say "Cache / Last known IP (best effort)"
CACHE_FILE=""
if [[ -f "${CFG}" ]]; then
  # naive extraction ohne jq
  CACHE_FILE="$(python3 - <<'PY' 2>/dev/null || true
import json
p="/etc/kiosk-controller.json"
try:
    d=json.load(open(p,"r",encoding="utf-8"))
    print(d.get("cache_file",""))
except Exception:
    pass
PY
)"
fi
if [[ -n "${CACHE_FILE}" && -f "${CACHE_FILE}" ]]; then
  kv "Cache file" "${CACHE_FILE}"
  tail -n 40 "${CACHE_FILE}" || true
else
  kv "Cache file" "${CACHE_FILE:-<unknown/missing>}"
fi

say "Done"