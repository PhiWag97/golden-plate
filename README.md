# GOLDEN PLATE
A simple Kiosk Service for Banana Pi (ARMBIAN CLI bookworm) with Chromium
=======

## Installation (Banana Pi)

git clone git@github.com:PhiWag97/golden-plate.git
cd golden-plate
sudo ./scripts/install.sh

## Update

cd /opt/golden-plate
sudo git pull
sudo /opt/golden-plate/venv/bin/pip install -e /opt/golden-plate
sudo systemctl reload-daemon
sudo systemctl restart kiosk.service