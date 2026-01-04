#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/golden-plate"
VENV_DIR="${APP_DIR}/venv"
SERVICE_NAME="golden-plate.service"

CFG_DST="/etc/kiosk-controller.json"
ENV_DST="/etc/default/kiosk-controller"

# Der User, der X/Firefox nutzen soll:
# Standard: der Nutzer, der sudo ausführt (SSH-User). Fallback: "user".
KIOSK_USER="${SUDO_USER:-user}"
KIOSK_HOME="$(getent passwd "${KIOSK_USER}" | cut -d: -f6 || true)"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit sudo ausführen."
  exit 1
fi

if [[ -z "${KIOSK_HOME}" ]]; then
  echo "ERROR: KIOSK_USER '${KIOSK_USER}' existiert nicht. Lege den User an oder führe als korrekter User via sudo aus."
  exit 2
fi

echo "[1/10] Pakete installieren (Xorg + Openbox + Tools + Fonts)…"
apt-get update
apt-get install -y \
  git ca-certificates rsync \
  python3 python3-venv \
  iproute2 \
  xorg xinit openbox x11-xserver-utils xserver-xorg-legacy dbus-x11 \
  wmctrl xdotool \
  fonts-dejavu fonts-noto fonts-roboto fonts-noto-color-emoji \
  firefox-esr || true

# Firefox fallback, falls firefox-esr nicht verfügbar
if ! command -v firefox-esr >/dev/null 2>&1 && ! command -v firefox >/dev/null 2>&1; then
  apt-get install -y firefox || true
fi

echo "[2/10] Xorg non-root erlauben (Xwrapper)…"
mkdir -p /etc/X11
cat >/etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=no
EOF

echo "[3/10] App nach ${APP_DIR} kopieren…"
mkdir -p "${APP_DIR}"
rsync -a --delete ./ "${APP_DIR}/"

echo "[4/10] Virtualenv erstellen…"
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip
"${VENV_DIR}/bin/pip" install -e "${APP_DIR}"

echo "[5/10] Konfiguration nach ${CFG_DST} (falls nicht vorhanden)…"
if [[ ! -f "${CFG_DST}" ]]; then
  install -m 0644 "${APP_DIR}/config/kiosk-controller.sample.json" "${CFG_DST}"
  # Pfade & XAUTHORITY auf echten User umbiegen (falls Sample "user" enthält, bleibt es konsistent)
  sed -i \
    -e "s|/home/user/|${KIOSK_HOME}/|g" \
    "${CFG_DST}" || true
  echo "  -> ${CFG_DST} angelegt."
else
  echo "  -> ${CFG_DST} existiert bereits, wird nicht überschrieben."
fi

echo "[6/10] Env-Override-Datei nach ${ENV_DST} (falls nicht vorhanden)…"
if [[ ! -f "${ENV_DST}" ]]; then
  cat >"${ENV_DST}" <<EOF
# Optionale Env-Overrides für kiosk-controller
# Beispiele:
# KIOSK_DISCOVERY_WORKERS=32
# KIOSK_AIDA_PORT=1111
# KIOSK_DISPLAY=:0
# KIOSK_XAUTHORITY=${KIOSK_HOME}/.Xauthority
EOF
  chmod 0644 "${ENV_DST}"
  echo "  -> ${ENV_DST} angelegt."
else
  echo "  -> ${ENV_DST} existiert bereits, wird nicht überschrieben."
fi

echo "[7/10] Splash-Datei mit Font-Stack sicherstellen…"
SPLASH_DIR="${KIOSK_HOME}/.cache/aida64"
SPLASH_FILE="${SPLASH_DIR}/loading.html"
mkdir -p "${SPLASH_DIR}"
cat >"${SPLASH_FILE}" <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="30">
  <title>Loading…</title>
  <style>
    html,body {
      height:100%;
      margin:0;
      background:#000;
      color:#fff;
      font-family: "Roboto","Noto Sans","DejaVu Sans",sans-serif;
    }
    .wrap { height:100%; display:flex; align-items:center; justify-content:center; flex-direction:column; gap:14px; }
    .spinner {
      width: 48px; height: 48px; border: 4px solid rgba(255,255,255,0.25);
      border-top-color: rgba(255,255,255,0.9); border-radius: 50%;
      animation: spin 1s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    .small { opacity: 0.8; font-size: 14px; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="spinner"></div>
    <div>Panel wird verbunden…</div>
    <div class="small">Bitte warten</div>
  </div>
</body>
</html>
EOF
chown -R "${KIOSK_USER}:${KIOSK_USER}" "${SPLASH_DIR}"
chmod 0644 "${SPLASH_FILE}"

echo "[8/10] Kiosk X-Session Script ausführbar machen…"
chmod +x "${APP_DIR}/scripts/kiosk-session.sh"
# ebenfalls sicherstellen, dass die Repo-Skripte ausführbar sind
chmod +x "${APP_DIR}/scripts/install.sh" "${APP_DIR}/scripts/uninstall.sh" || true

echo "[9/10] systemd Service installieren (golden-plate)…"
# Service dynamisch mit korrektem User/Home schreiben
cat >"/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=Golden Plate Kiosk (Xorg + Openbox + kiosk-controller)
Wants=network-online.target
After=network-online.target systemd-user-sessions.service

[Service]
Type=simple
User=${KIOSK_USER}
WorkingDirectory=${APP_DIR}
Environment=DISPLAY=:0
Environment=XAUTHORITY=${KIOSK_HOME}/.Xauthority
EnvironmentFile=-/etc/default/kiosk-controller

TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes

ExecStart=/usr/bin/startx ${APP_DIR}/scripts/kiosk-session.sh -- :0 -nolisten tcp vt1
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "/etc/systemd/system/${SERVICE_NAME}"

# .xinitrc aus dem Repo deployt
echo "[X] .xinitrc für ${KIOSK_USER} installieren…"
install -m 0755 -o "${KIOSK_USER}" -g "${KIOSK_USER}" \
  "${APP_DIR}/systemd/.xinitrc" \
  "${KIOSK_HOME}/.xinitrc"

# Falls alte Service-Variante existiert, deaktivieren (best effort)
if systemctl list-unit-files 2>/dev/null | grep -q '^kiosk-controller\.service'; then
  systemctl disable --now kiosk-controller.service || true
fi

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo "[10/10] Status…"
systemctl --no-pager status "${SERVICE_NAME}" || true

echo "Fertig."
echo "Service: ${SERVICE_NAME}"
echo "Install-Dir: ${APP_DIR}"
echo "Config: ${CFG_DST}"
echo "Logs: journalctl -u ${SERVICE_NAME} -f"