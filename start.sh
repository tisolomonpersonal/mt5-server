#!/bin/bash
# No set -e — we handle errors manually so the container never crashes

LOG=/config/logs/startup.log
mkdir -p /config/wine /config/logs
exec > >(tee -a "$LOG") 2>&1

echo "=== MT5 Container Starting $(date) ==="

# ── Virtual display ────────────────────────────────────────────────────────────
Xvfb :1 -screen 0 1280x800x24 &
export DISPLAY=:1
sleep 3
echo "[OK] Virtual display started."

# ── Wine prefix init (first run only) ─────────────────────────────────────────
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    echo "[INIT] Initializing Wine prefix (~2 min)..."
    wineboot --init 2>/dev/null || true
    sleep 25
    echo "[OK] Wine initialized."
fi

# ── Windows Python (embeddable — no installer, just unzip) ────────────────────
WINE_PY_DIR="$WINEPREFIX/drive_c/python311"
WINE_PYTHON="$WINE_PY_DIR/python.exe"

if [ ! -f "$WINE_PYTHON" ]; then
    echo "[INIT] Downloading embeddable Python 3.11..."
    wget "https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip" \
         -O /tmp/pyembed.zip 2>&1 || echo "[ERROR] Python download failed"
    mkdir -p "$WINE_PY_DIR"
    unzip /tmp/pyembed.zip -d "$WINE_PY_DIR" 2>&1 || echo "[ERROR] unzip failed"
    echo "[DEBUG] python311 dir contents:"
    ls "$WINE_PY_DIR/" 2>/dev/null || echo "(empty)"

    # Bootstrap pip
    wget -q "https://bootstrap.pypa.io/get-pip.py" -O /tmp/get-pip.py
    wine "$WINE_PYTHON" /tmp/get-pip.py --no-warn-script-location 2>&1 \
        | tee /config/logs/pip_bootstrap.log || true
    echo "[OK] Windows Python ready."
fi

# Always rewrite _pth with absolute Windows paths (fixes 'no module encodings' under Wine)
# Must run every startup in case the volume already has python311 from a previous run
cat > "$WINE_PY_DIR/python311._pth" << 'PTHEOF'
C:\python311\python311.zip
C:\python311
C:\python311\Lib\site-packages
import site
PTHEOF
echo "[OK] _pth configured with absolute paths."

# ── Install MetaTrader5 + mt5linux (skip if already installed) ────────────────
if ! wine "$WINE_PYTHON" -c "import mt5linux" 2>/dev/null; then
    echo "[INIT] Installing MetaTrader5 + mt5linux..."
    wine "$WINE_PYTHON" -m pip install MetaTrader5 mt5linux \
         --no-warn-script-location 2>&1 | tee /config/logs/pip.log || true
    echo "[OK] Packages installed."
fi

# ── MetaTrader 5 terminal ──────────────────────────────────────────────────────
MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    echo "[INIT] Downloading MT5 setup..."
    wget -q "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" \
         -O /tmp/mt5setup.exe
    echo "[INIT] Installing MT5 (~2 min)..."
    wine /tmp/mt5setup.exe /auto 2>/dev/null || true
    sleep 90
    echo "[OK] MT5 installed."
fi

# ── VNC + noVNC ───────────────────────────────────────────────────────────────
x11vnc -display :1 -forever -nopw -rfbport 5900 -bg -quiet 2>/dev/null || true
websockify --web /usr/share/novnc/ 6080 localhost:5900 &
echo "[OK] noVNC ready on port 6080."

# ── Launch MT5 terminal ───────────────────────────────────────────────────────
if [ -f "$MT5_EXE" ]; then
    wine "$MT5_EXE" &
    echo "[OK] MT5 terminal launched."
    sleep 15
else
    echo "[WARN] MT5 exe not found — skipping terminal launch."
fi

# ── Start mt5linux bridge ─────────────────────────────────────────────────────
echo "[START] Starting MT5 Python bridge on port 8001..."
wine "$WINE_PYTHON" -c "
from mt5linux import MetaTrader5
mt5 = MetaTrader5()
mt5.run_server(host='0.0.0.0', port=8001)
" 2>&1 | tee /config/logs/bridge.log || true

# ── Fallback: keep container alive so you can debug via VNC ──────────────────
echo "[WARN] Bridge exited — container staying alive for debugging."
tail -f /config/logs/startup.log
