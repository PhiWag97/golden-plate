#!/usr/bin/env bash
set -euo pipefail

GOLDEN_ROOT="/opt/golden-plate"
SYSTEMD_DIR="${GOLDEN_ROOT}/systemd"
ETC_DIR="${GOLDEN_ROOT}/etc"
SITE_DIR="${GOLDEN_ROOT}/site"

KIOSK_USER="kiosk"

# === Defaults (können per Env überschrieben werden oder interaktiv gesetzt werden) ===
: "${REMOTE_URL:=http://127.0.0.1:8088}"
: "${LOCAL_HOST:=127.0.0.1}"
: "${LOCAL_PORT:=8088}"
: "${CHECK_INTERVAL_MS:=2000}"
: "${TIMEOUT_MS:=5000}"
: "${DISABLE_GPU:=false}"
: "${NEW_HOSTNAME:=}"           # leer = nicht ändern
# ================================================================================

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Bitte als root ausführen: sudo $0" >&2
    exit 1
  fi
}

log() { echo "[golden-plate] $*"; }

require_repo_files() {
  local missing=0

  for f in kiosk.service kiosk-web.service kiosk-monitor.service kiosk-monitor.timer; do
    if [[ ! -f "${SYSTEMD_DIR}/${f}" ]]; then
      echo "Fehlt: ${SYSTEMD_DIR}/${f}" >&2
      missing=1
    fi
  done

  if [[ ! -f "${GOLDEN_ROOT}/bin/session.sh" ]]; then
    echo "Fehlt: ${GOLDEN_ROOT}/bin/session.sh" >&2
    missing=1
  fi
  if [[ ! -f "${GOLDEN_ROOT}/bin/kiosk-monitor.sh" ]]; then
    echo "Fehlt: ${GOLDEN_ROOT}/bin/kiosk-monitor.sh" >&2
    missing=1
  fi
  if [[ ! -f "${SITE_DIR}/index.html" ]]; then
    echo "Fehlt: ${SITE_DIR}/index.html" >&2
    missing=1
  fi

  if [[ "${missing}" -ne 0 ]]; then
    echo "Repo ist nicht vollständig. Bitte Struktur/Dateien anlegen und erneut ausführen." >&2
    exit 2
  fi
}

prompt_config() {
  # Nur interaktiv fragen, wenn stdin ein Terminal ist
  if [[ -t 0 ]]; then
    echo "=== Golden Plate Setup ==="
    echo "Bitte Remote URL eingeben (Enter = Default):"
    echo

    read -rp "Remote URL [${REMOTE_URL}]: " input
	if [[ -z "${REMOTE_URL}" ]]; then
	  echo "Remote URL darf nicht leer sein." >&2
	  exit 3
	fi
	if [[ ! "${REMOTE_URL}" =~ ^https?:// ]]; then
	  echo "Remote URL muss mit http:// oder https:// beginnen." >&2
	  exit 3
	fi

    REMOTE_URL="${input:-$REMOTE_URL}"

    echo
  fi
}



install_packages() {
  log "Installiere Pakete …"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y

  # Chromium Paketname variiert je nach Distribution (Debian/Ubuntu).
  # Wir versuchen zuerst 'chromium', dann fallback 'chromium-browser'.
  local chromium_pkg="chromium"
  if ! apt-cache show chromium >/dev/null 2>&1; then
    chromium_pkg="chromium-browser"
  fi

  apt-get install -y --no-install-recommends \
    ca-certificates curl python3 \
    xserver-xorg xinit openbox x11-xserver-utils dbus-x11 \
    unclutter \
    "${chromium_pkg}" \
    procps coreutils util-linux
}

ensure_user() {
  if id -u "${KIOSK_USER}" >/dev/null 2>&1; then
    log "User '${KIOSK_USER}' existiert bereits."
  else
    log "Lege User '${KIOSK_USER}' an …"
    adduser --disabled-password --gecos "" "${KIOSK_USER}"
  fi
  usermod -aG video,audio,input,render "${KIOSK_USER}" || true
}

ensure_perms() {
  log "Setze Ownership/Permissions …"

  # Struktur
  mkdir -p "${ETC_DIR}" "${SITE_DIR}" "${GOLDEN_ROOT}/bin" "${GOLDEN_ROOT}/systemd"

  # Systembestandteile: root-owned (Hardening)
  chown -R root:root "${GOLDEN_ROOT}/bin" "${GOLDEN_ROOT}/systemd"
  chmod 0755 "${GOLDEN_ROOT}/bin" "${GOLDEN_ROOT}/systemd"
  chmod 0755 "${GOLDEN_ROOT}/bin/session.sh" "${GOLDEN_ROOT}/bin/kiosk-monitor.sh" || true
  chmod 0644 "${GOLDEN_ROOT}/systemd/"*.service "${GOLDEN_ROOT}/systemd/"*.timer 2>/dev/null || true

  # Laufzeit-/Konfig-Daten: kiosk-owned
  chown -R "${KIOSK_USER}:${KIOSK_USER}" "${ETC_DIR}" "${SITE_DIR}"
  chmod 0755 "${ETC_DIR}" "${SITE_DIR}"
}

configure_xwrapper() {
  log "Konfiguriere /etc/X11/Xwrapper.config …"
  mkdir -p /etc/X11
  cat >/etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF
}

write_env() {
  log "Schreibe ${ETC_DIR}/golden-plate.env …"
  cat >"${ETC_DIR}/golden-plate.env" <<EOF
# Golden Plate runtime env
LOCAL_HOST=${LOCAL_HOST}
LOCAL_PORT=${LOCAL_PORT}
DISABLE_GPU=${DISABLE_GPU}
REMOTE_URL=${REMOTE_URL}
CHECK_INTERVAL_MS=${CHECK_INTERVAL_MS}
TIMEOUT_MS=${TIMEOUT_MS}
EOF
  chown "${KIOSK_USER}:${KIOSK_USER}" "${ETC_DIR}/golden-plate.env"
  chmod 0644 "${ETC_DIR}/golden-plate.env"
}

write_config_json() {
  log "Schreibe ${SITE_DIR}/config.json …"
  cat >"${SITE_DIR}/config.json" <<EOF
{
  "remote_url": "${REMOTE_URL}",
  "check_interval_ms": ${CHECK_INTERVAL_MS},
  "timeout_ms": ${TIMEOUT_MS}
}
EOF
  chown "${KIOSK_USER}:${KIOSK_USER}" "${SITE_DIR}/config.json"
  chmod 0644 "${SITE_DIR}/config.json"
}

install_units_via_symlinks() {
  log "Installiere systemd Units via Symlink nach /etc/systemd/system/ …"
  ln -sf "${SYSTEMD_DIR}/kiosk-web.service" /etc/systemd/system/kiosk-web.service
  ln -sf "${SYSTEMD_DIR}/kiosk.service" /etc/systemd/system/kiosk.service
  ln -sf "${SYSTEMD_DIR}/kiosk-monitor.service" /etc/systemd/system/kiosk-monitor.service
  ln -sf "${SYSTEMD_DIR}/kiosk-monitor.timer" /etc/systemd/system/kiosk-monitor.timer
}

enable_services() {
  log "Aktiviere/Starte Services …"
  systemctl daemon-reload
  systemctl enable --now kiosk-web.service
  systemctl enable --now kiosk.service
  systemctl enable --now kiosk-monitor.timer
}

main() {
  need_root
  require_repo_files
  prompt_config
  install_packages
  ensure_user
  ensure_perms
  configure_xwrapper
  write_env
  write_config_json
  install_units_via_symlinks
  enable_services

  log "Fertig."
  log "Status: systemctl status kiosk-web.service kiosk.service kiosk-monitor.timer"
  log "Logs:   journalctl -u kiosk.service -n 200 --no-pager"
}

main "$@"
