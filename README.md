# golden-plate
Kiosk Controller for Banana Pi: Search for a Website in a LAN-Network (Healthcheck + Discovery)
=======
# kiosk-controller

Kiosk Controller für Banana Pi: findet einen AIDA64 RemoteSensor im LAN (Healthcheck + Discovery) und steuert Firefox im Kiosk-Modus auf einer X11-Session.

## Installation (Banana Pi)

git clone git@github.com:PhiWag97/golden-plate.git
cd golden-plate
sudo ./scripts/install.sh

## Update

cd /opt/golden-plate
sudo git pull
sudo /opt/golden-plate/venv/bin/pip install -e /opt/golden-plate
sudo systemctl restart kiosk-controller.service