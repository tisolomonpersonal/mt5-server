#!/bin/bash
set -e

echo "=== MT5 Container Starting ==="

# Create config dirs on persistent volume
mkdir -p /config/wine
mkdir -p /config/logs

# Start virtual display
Xvfb :1 -screen 0 1280x800x24 &
export DISPLAY=:1
sleep 3
echo "Virtual display started."

# Initialize Wine prefix if first run
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    echo "Initializing Wine (first run, takes ~2 min)..."
    wineboot --init 2>/dev/null
    sleep 20
    echo "Wine initialized."
fi

# Download and install MT5 if not already installed
MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    echo "Downloading MetaTrader 5..."
    wget -q "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" \
         -O /tmp/mt5setup.exe
    echo "Installing MT5 (takes ~2 min)..."
    wine /tmp/mt5setup.exe /auto 2>/dev/null || true
    sleep 90
    echo "MT5 install done."
fi

# Start VNC server (no password — Zeabur auth protects the public URL)
x11vnc -display :1 -forever -nopw -rfbport 5900 -bg -quiet 2>/dev/null
echo "VNC server started on port 5900."

# Start noVNC browser interface on port 6080
websockify --web /usr/share/novnc/ 6080 localhost:5900 &
echo "noVNC ready — open port 6080 in your browser."

# Launch MT5 terminal
if [ -f "$MT5_EXE" ]; then
    wine "$MT5_EXE" &
    echo "MT5 terminal launched."
    sleep 15
fi

# Start mt5linux Python RPC bridge on port 8001
# The trading bot on the other Zeabur service connects here
echo "Starting MT5 Python bridge on port 8001..."
python3 -c "
from mt5linux import MetaTrader5
mt5 = MetaTrader5()
mt5.run_server(host='0.0.0.0', port=8001)
" 2>&1 | tee /config/logs/bridge.log
