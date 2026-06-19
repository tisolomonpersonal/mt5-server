#!/bin/bash
set -u

LOG=/config/logs/startup.log
BRIDGE_LOG=/config/logs/bridge.log
READY_LOG=/config/logs/mt5_ready_check.log
MT5_TERM_LOG=/config/logs/mt5_terminal.log
PIP_LOG=/config/logs/pip.log
BOOTSTRAP_LOG=/config/logs/pip_bootstrap.log
BRIDGE_PORT="${BRIDGE_PORT:-8001}"

mkdir -p /config/wine /config/logs
exec > >(tee -a "$LOG") 2>&1

export WINEPREFIX="${WINEPREFIX:-/config/wine}"
export WINEARCH="${WINEARCH:-win64}"
export DISPLAY=:1
export WINEDLLOVERRIDES="mscoree,mshtml="

echo "=== MT5 Container Starting $(date) ==="
echo "[INFO] WINEPREFIX=$WINEPREFIX"
echo "[INFO] BRIDGE_PORT=$BRIDGE_PORT"

WINE_BIN="$(command -v wine || true)"
if [ -z "$WINE_BIN" ]; then
    WINE_BIN="$(command -v wine64 || true)"
fi

WINESERVER_BIN="$(command -v wineserver || true)"

if [ -z "$WINE_BIN" ]; then
    echo "[ERROR] Neither 'wine' nor 'wine64' was found in PATH."
    exit 1
fi

echo "[INFO] Using Wine binary: $WINE_BIN"
if [ -n "$WINESERVER_BIN" ]; then
    echo "[INFO] Using wineserver binary: $WINESERVER_BIN"
fi

run_wine() {
    local seconds="$1"
    shift
    echo "[DEBUG] Running with timeout ${seconds}s: $*"
    timeout "${seconds}s" "$@"
    local code=$?
    if [ $code -eq 124 ]; then
        echo "[ERROR] Command timed out after ${seconds}s: $*"
    fi
    return $code
}

# ── Virtual display ────────────────────────────────────────────────────────────
if ! pgrep -f "Xvfb :1" >/dev/null 2>&1; then
    Xvfb :1 -screen 0 1280x800x24 &
    sleep 3
fi
echo "[OK] Virtual display started."

# ── Wine prefix init ───────────────────────────────────────────────────────────
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    echo "[INIT] Initializing Wine prefix..."
    run_wine 120 "$WINE_BIN" wineboot --init || true
    if [ -n "$WINESERVER_BIN" ]; then
        "$WINESERVER_BIN" -w || true
    fi
    sleep 10
    echo "[OK] Wine initialized."
else
    echo "[OK] Existing Wine prefix detected."
fi

# ── Windows Python (embeddable) ───────────────────────────────────────────────
WINE_PY_DIR="$WINEPREFIX/drive_c/python311"
WINE_PYTHON="$WINE_PY_DIR/python.exe"

if [ ! -f "$WINE_PYTHON" ]; then
    echo "[INIT] Downloading embeddable Python 3.11..."
    wget -q "https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip" -O /tmp/pyembed.zip
    mkdir -p "$WINE_PY_DIR"
    unzip -o /tmp/pyembed.zip -d "$WINE_PY_DIR" >/dev/null
    echo "[OK] Windows Python unpacked."
else
    echo "[OK] Windows Python already present."
fi

cat > "$WINE_PY_DIR/python311._pth" << 'PTHEOF'
C:\python311\python311.zip
C:\python311
C:\python311\Lib\site-packages
import site
PTHEOF
echo "[OK] _pth configured."

echo "[CHECK] Verifying Windows Python starts..."
run_wine 90 "$WINE_BIN" "$WINE_PYTHON" -V || {
    echo "[ERROR] Windows Python did not start correctly under Wine."
    exit 1
}
echo "[OK] Windows Python responds."

echo "[CHECK] Verifying Windows-side packages..."
if run_wine 90 "$WINE_BIN" "$WINE_PYTHON" -c "import MetaTrader5, mt5linux; print('packages_ok')" >/dev/null 2>&1; then
    echo "[OK] Windows-side packages already present."
else
    echo "[INIT] Installing Windows-side Python packages..."
    wget -q "https://bootstrap.pypa.io/get-pip.py" -O /tmp/get-pip.py

    run_wine 180 "$WINE_BIN" "$WINE_PYTHON" /tmp/get-pip.py --no-warn-script-location \
        2>&1 | tee "$BOOTSTRAP_LOG" || {
        echo "[ERROR] Failed to bootstrap pip."
        exit 1
    }

    run_wine 180 "$WINE_BIN" "$WINE_PYTHON" -m pip install --upgrade pip --no-warn-script-location \
        2>&1 | tee -a "$BOOTSTRAP_LOG" || {
        echo "[ERROR] Failed to upgrade pip."
        exit 1
    }

    run_wine 300 "$WINE_BIN" "$WINE_PYTHON" -m pip install --upgrade MetaTrader5 mt5linux rpyc pywin32 \
        --no-warn-script-location 2>&1 | tee "$PIP_LOG" || {
        echo "[ERROR] Failed to install Windows-side packages."
        exit 1
    }

    echo "[OK] Windows-side packages installed."
fi

# ── MT5 terminal install ──────────────────────────────────────────────────────
MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"

if [ ! -f "$MT5_EXE" ]; then
    echo "[INIT] Downloading MT5 setup..."
    wget -q "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" -O /tmp/mt5setup.exe

    echo "[INIT] Installing MT5..."
    run_wine 300 "$WINE_BIN" /tmp/mt5setup.exe /auto || true
    sleep 90
    echo "[OK] MT5 install command completed."
else
    echo "[OK] MT5 terminal already present."
fi

if [ ! -f "$MT5_EXE" ]; then
    echo "[ERROR] MT5 executable not found at $MT5_EXE"
    exit 1
fi

# ── Launch MT5 terminal ───────────────────────────────────────────────────────
echo "[START] Launching MT5 terminal..."
: > "$MT5_TERM_LOG"
"$WINE_BIN" "$MT5_EXE" >> "$MT5_TERM_LOG" 2>&1 &
sleep 8
echo "[OK] MT5 terminal launch command sent."

TERM_READY=0
for i in $(seq 1 24); do
    if pgrep -a -f "terminal64.exe" >/dev/null 2>&1; then
        TERM_READY=1
        echo "[OK] MT5 terminal process detected."
        break
    fi
    echo "[WAIT] MT5 terminal process not visible yet, retry $i/24 ..."
    sleep 5
done

if [ "$TERM_READY" -ne 1 ]; then
    echo "[ERROR] MT5 terminal process never appeared."
    cat "$MT5_TERM_LOG" || true
    exit 1
fi

# ── Wait for MetaTrader5 Python API readiness ─────────────────────────────────
echo "[WAIT] Waiting for MetaTrader5 Python API to become ready..."
READY=0
: > "$READY_LOG"

for i in $(seq 1 30); do
    run_wine 120 "$WINE_BIN" "$WINE_PYTHON" -c "
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

# ── Start mt5linux bridge ─────────────────────────────────────────────────────
echo "[START] Starting MT5 Python bridge on port ${BRIDGE_PORT}..."
: > "$BRIDGE_LOG"

"$WINE_BIN" "$WINE_PYTHON" -c "
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
