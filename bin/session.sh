#!/bin/sh
set -eu

# X-Energiesparen aus
xset s off
xset s noblank
xset -dpms

# Cursor ausblenden (optional)
unclutter -idle 0.3 -root &

# Fensterverwaltung (leicht)
openbox-session &

# Immer zuerst lokale Seite laden
URL="http://127.0.0.1:8088/"

# Chromium Kiosk
exec chromium \
  --kiosk \
  --app="$URL" \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --overscroll-history-navigation=0 \
  --incognito \
  --disk-cache-dir=/tmp/chromium-cache \
  --disable-features=Translate,BackForwardCache,MediaRouter \
  --disable-breakpad \
  --disable-sync \
  --disable-background-networking \
  --disable-default-apps \
  --disable-component-update \
  --disable-domain-reliability \
  --disable-prompt-on-repost \
  --disable-hang-monitor \
  --disable-client-side-phishing-detection \
  --metrics-recording-only \
  --mute-audio