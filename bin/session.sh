#!/bin/sh
set -eu

# X-Energiesparen aus
xset s off || true
xset s noblank || true
xset -dpms || true

# Cursor ausblenden (optional)
unclutter -idle 0.3 -root &

# Fensterverwaltung (leicht)
openbox-session &

# Immer zuerst lokale Seite laden
URL="http://127.0.0.1:8088/"

# Chromium Kiosk
exec chromium \
  --kiosk \
  --no-first-run \
  --app="$URL" \
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
  --disable-features=Translate,TranslateUI,BackForwardCache,MediaRouter \
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
  --no-default-browser-check \
  --user-data-dir=/home/kiosk/.config/chromium-kiosk \
  --class=golden-plate-kiosk\
  --mute-audio