#!/bin/sh
set -eu

# DBUS Guard
[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || { echo "ERROR: DBUS_SESSION_BUS_ADDRESS empty" >&2; exit 1; }
echo "LAUNCH: passing DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}" >&2

# X-Energiesparen aus
xset s off || true
xset s noblank || true
xset -dpms || true

# Cursor ausblenden (optional)
unclutter -idle 0.3 -root &

# Fensterverwaltung (leicht)
openbox-session &
sleep 0.2

# Immer zuerst lokale Seite laden
URL="http://127.0.0.1:8088/"

# Chromium Kiosk
exec /usr/bin/env -i \
  DISPLAY="$DISPLAY" \
  HOME="$HOME" \
  USER="$USER" \
  LOGNAME="$LOGNAME" \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
  DBUS_SESSION_BUS_PID="${DBUS_SESSION_BUS_PID:-}" \
  /usr/lib/chromium/chromium \
  --kiosk "$URL" \
  --no-first-run \
  --noerrdialogs \
  --disable-translate \
  --lang=de-DE \
  --accept-lang=de-DE,de,en-US,en \
  --disable-infobars \
  --hide-scrollbars \
  --disable-session-crashed-bubble \
  --overscroll-history-navigation=0 \
  --incognito \
  --disk-cache-dir=/tmp/chromium-cache \
  --disable-features=Translate,TranslateUI,BackForwardCache,MediaRouter,PushMessaging,BackgroundFetch,PeriodicBackgroundSync \
  --disable-breakpad \
  --disable-sync \
  --disable-background-networking \
  --disable-default-apps \
  --disable-component-update \
  --disable-domain-reliability \
  --disable-prompt-on-repost \
  --disable-client-side-phishing-detection \
  --metrics-recording-only \
  --no-default-browser-check \
  --user-data-dir=/home/kiosk/.config/chromium-kiosk \
  --class=golden-plate-kiosk \
  --mute-audio