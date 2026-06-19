#!/bin/bash
set -u

LOG=/config/logs/startup.log
BRIDGE_LOG=/config/logs/bridge.log
READY_LOG=/config/logs/mt5_ready_check.log
BRIDGE_PORT="${BRIDGE_PORT:-8001}"

mkdir -p /config/wine /config/logs
exec > >(tee -a "$LOG") 2>&1

export WINEPREFIX="${WINEPREFIX:-/config/wine}"
export WINEARCH="${WINEARCH:-win64}"
export DISPLAY=:1

echo "=== MT5 Container Starting $(date) ==="
echo "[INFO] WINEPREFIX=$WINEPREFIX"
echo "[INFO] BRIDGE_PORT=$BRIDGE_PORT"

if ! pgrep -f "Xvfb :1" >/dev/null 2>&1; then
    Xvfb :1 -screen 0 1280x800x24 &
    sleep 3
fi
echo "[OK] Virtual display started."

if [ ! -f "$WINEPREFIX/system.reg" ]; then
    echo "[INIT] Initializing Wine prefix..."
    wineboot --init || true
    sleep 25
    echo "[OK] Wine initialized."
fi

WINE_PY_DIR="$WINEPREFIX/drive_c/python311"
WINE_PYTHON="$WINE_PY_DIR/python.exe"

if [ ! -f "$WINE_PYTHON" ]; then
    echo "[INIT] Downloading embeddable Python 3.11..."
    wget "https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip" -O /tmp/pyembed.zip
    mkdir -p "$WINE_PY_DIR"
    unzip -o /tmp/pyembed.zip -d "$WINE_PY_DIR"
    echo "[OK] Windows Python unpacked."
fi

cat > "$WINE_PY_DIR/python311._pth" << 'PTHEOF'
C:\python311\python311.zip
C:\python311
C:\python311\Lib\site-packages
import site
PTHEOF
echo "[OK] _pth configured."

if ! wine "$WINE_PYTHON" -c "import MetaTrader5, mt5linux" >/dev/null 2>&1; then
    echo "[INIT] Installing Windows-side Python packages..."
    wget -q "https://bootstrap.pypa.io/get-pip.py" -O /tmp/get-pip.py
    wine "$WINE_PYTHON" /tmp/get-pip.py --no-warn-script-location \
        2>&1 | tee /config/logs/pip_bootstrap.log || true

    wine "$WINE_PYTHON" -m pip install --upgrade pip --no-warn-script-location \
        2>&1 | tee /config/logs/pip_upgrade.log || true

    wine "$WINE_PYTHON" -m pip install --upgrade MetaTrader5 mt5linux rpyc pywin32 \
        --no-warn-script-location 2>&1 | tee /config/logs/pip.log
    echo "[OK] Windows-side packages installed."
else
    echo "[OK] Windows-side packages already present."
fi

MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    echo "[INIT] Downloading MT5 setup..."
    wget -q "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" -O /tmp/mt5setup.exe
    echo "[INIT] Installing MT5..."
    wine /tmp/mt5setup.exe /auto || true
    sleep 90
    echo "[OK] MT5 installed."
fi

if ! pgrep -f "x11vnc .*5900" >/dev/null 2>&1; then
    x11vnc -display :1 -forever -nopw -rfbport 5900 -bg -quiet || true
fi

if ! pgrep -f "websockify .*6080" >/dev/null 2>&1; then
    websockify --web /usr/share/novnc/ 6080 localhost:5900 &
fi
echo "[OK] noVNC ready on port 6080."

echo "[START] Launching MT5 terminal..."
wine "$MT5_EXE" >/config/logs/mt5_terminal.log 2>&1 &
sleep 5
echo "[OK] MT5 terminal launch command sent."

TERM_READY=0
for i in $(seq 1 18); do
    if pgrep -a -f "terminal64.exe" >/dev/null 2>&1; then
        TERM_READY=1
        echo "[OK] MT5 terminal process detected."
        break
    fi
    echo "[WAIT] MT5 terminal process not visible yet, retry $i/18 ..."
    sleep 5
done

if [ "$TERM_READY" -ne 1 ]; then
    echo "[ERROR] MT5 terminal process never appeared."
    cat /config/logs/mt5_terminal.log || true
    exit 1
fi

echo "[WAIT] Waiting for MetaTrader5 Python API to become ready..."
READY=0
: > "$READY_LOG"

for i in $(seq 1 30); do
    wine "$WINE_PYTHON" -c "
import sys
import MetaTrader5 as mt5

ok = mt5.initialize()
print('initialize=', ok)

if ok:
    print('terminal_info=', mt5.terminal_info())
    print('version=', mt5.version())
    mt5.shutdown()
    sys.exit(0)

print('last_error=', mt5.last_error())
sys.exit(1)
" >> "$READY_LOG" 2>&1

    if [ $? -eq 0 ]; then
        READY=1
        echo "[OK] MetaTrader5 Python API is ready."
        break
    fi

    echo "[WAIT] MT5 API not ready yet, retry $i/30 ..."
    sleep 10
done

if [ "$READY" -ne 1 ]; then
    echo "[ERROR] MetaTrader5 never became ready."
    cat "$READY_LOG" || true
    exit 1
fi

echo "[START] Starting MT5 Python bridge on port ${BRIDGE_PORT}..."
: > "$BRIDGE_LOG"

wine "$WINE_PYTHON" -c "
import os
from mt5linux import MetaTrader5

port = int(os.environ.get('BRIDGE_PORT', '8001'))
mt5 = MetaTrader5()
mt5.run_server(host='0.0.0.0', port=port)
" 2>&1 | tee -a "$BRIDGE_LOG"

BRIDGE_EXIT=$?
echo "[ERROR] Bridge exited unexpectedly with code $BRIDGE_EXIT"
cat "$BRIDGE_LOG" || true
exit $BRIDGE_EXIT
