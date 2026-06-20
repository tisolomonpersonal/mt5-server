#!/bin/bash
set -euo pipefail

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
export WINEDEBUG="${WINEDEBUG:--all}"

PYTHON_EMBED_VERSION="${PYTHON_EMBED_VERSION:-3.9.13}"
PYTHON_MM="$(echo "$PYTHON_EMBED_VERSION" | awk -F. '{print $1 $2}')"
PYTHON_SERIES="$(echo "$PYTHON_EMBED_VERSION" | awk -F. '{print $1 "." $2}')"
WINE_PY_DIR="$WINEPREFIX/drive_c/python${PYTHON_MM}"
WINE_PYTHON="$WINE_PY_DIR/python.exe"
WINE_PTH="$WINE_PY_DIR/python${PYTHON_MM}._pth"
PYTHON_VERSION_MARKER="$WINE_PY_DIR/.solo_python_version"
WINETRICKS_BIN="$(command -v winetricks || true)"

echo "=== MT5 Container Starting $(date) ==="
echo "[INFO] WINEPREFIX=$WINEPREFIX"
echo "[INFO] BRIDGE_PORT=$BRIDGE_PORT"
echo "[INFO] PYTHON_EMBED_VERSION=$PYTHON_EMBED_VERSION"

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

clean_windows_python_packages() {
    echo "[INIT] Cleaning Windows-side package remnants..."
    rm -rf \
        "$WINE_PY_DIR/Lib/site-packages/MetaTrader5" \
        "$WINE_PY_DIR/Lib/site-packages/MetaTrader5-"*".dist-info" \
        "$WINE_PY_DIR/Lib/site-packages/mt5linux" \
        "$WINE_PY_DIR/Lib/site-packages/mt5linux-"*".dist-info" \
        "$WINE_PY_DIR/Lib/site-packages/rpyc" \
        "$WINE_PY_DIR/Lib/site-packages/rpyc-"*".dist-info" \
        "$WINE_PY_DIR/Lib/site-packages/win32" \
        "$WINE_PY_DIR/Lib/site-packages/win32com" \
        "$WINE_PY_DIR/Lib/site-packages/pythonwin" \
        "$WINE_PY_DIR/Lib/site-packages/pywin32-"*".dist-info" \
        "$WINE_PY_DIR/Lib/site-packages/pywin32_system32" \
        "$WINE_PY_DIR/Lib/site-packages/pywintypes"* \
        "$WINE_PY_DIR/Lib/site-packages/pythoncom"* \
        "$WINE_PY_DIR/Lib/site-packages/pip" \
        "$WINE_PY_DIR/Lib/site-packages/pip-"*".dist-info" \
        "$WINE_PY_DIR/Lib/site-packages/setuptools" \
        "$WINE_PY_DIR/Lib/site-packages/setuptools-"*".dist-info" \
        "$WINE_PY_DIR/Lib/site-packages/wheel" \
        "$WINE_PY_DIR/Lib/site-packages/wheel-"*".dist-info" \
        >/dev/null 2>&1 || true
}

install_vcruntime() {
    if [ -z "$WINETRICKS_BIN" ]; then
        echo "[WARN] winetricks not found; skipping vcrun installation."
        return 0
    fi

    if [ -f "$WINEPREFIX/.vcrun2019_installed" ]; then
        echo "[OK] Native VC runtime already present."
        return 0
    fi

    echo "[INIT] Installing native VC runtime with winetricks..."
    run_wine 600 "$WINETRICKS_BIN" -q vcrun2019 || {
        echo "[ERROR] winetricks vcrun2019 installation failed."
        exit 1
    }
    touch "$WINEPREFIX/.vcrun2019_installed"
    echo "[OK] Native VC runtime installed."
}

# ── Virtual display ────────────────────────────────────────────────────────────
if ! pgrep -f "Xvfb :1" >/dev/null 2>&1; then
    Xvfb :1 -screen 0 1280x800x24 &
    sleep 3
fi
echo "[OK] Virtual display started."

# ── VNC server ────────────────────────────────────────────────────────────────
if ! pgrep -f "x11vnc" >/dev/null 2>&1; then
    x11vnc -display :1 -nopw -listen 0.0.0.0 -port 5900 -forever -shared -bg -o /config/logs/vnc.log
    echo "[OK] VNC server started on port 5900."
fi

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

install_vcruntime

# ── Windows Python (embeddable) ───────────────────────────────────────────────
if [ ! -f "$WINE_PYTHON" ] || [ ! -f "$PYTHON_VERSION_MARKER" ] || ! grep -qx "$PYTHON_EMBED_VERSION" "$PYTHON_VERSION_MARKER" 2>/dev/null; then
    echo "[INIT] Downloading embeddable Python ${PYTHON_EMBED_VERSION}..."
    rm -rf "$WINE_PY_DIR"
    mkdir -p "$WINE_PY_DIR"
    wget -q "https://www.python.org/ftp/python/${PYTHON_EMBED_VERSION}/python-${PYTHON_EMBED_VERSION}-embed-amd64.zip" -O /tmp/pyembed.zip
    unzip -o /tmp/pyembed.zip -d "$WINE_PY_DIR" >/dev/null
    printf '%s\n' "$PYTHON_EMBED_VERSION" > "$PYTHON_VERSION_MARKER"
    echo "[OK] Windows Python unpacked."
else
    echo "[OK] Windows Python already present."
fi

mkdir -p "$WINE_PY_DIR/Lib/site-packages"
cat > "$WINE_PTH" << PTHEOF
C:\python${PYTHON_MM}\python${PYTHON_MM}.zip
C:\python${PYTHON_MM}
C:\python${PYTHON_MM}\Lib\site-packages
import site
PTHEOF
echo "[OK] _pth configured."

echo "[CHECK] Verifying Windows Python starts..."
run_wine 90 "$WINE_BIN" "$WINE_PYTHON" -V || {
    echo "[ERROR] Windows Python did not start correctly under Wine."
    exit 1
}
echo "[OK] Windows Python responds."

# ── Package verification / installation ───────────────────────────────────────
echo "[CHECK] Verifying Windows-side packages..."
if run_wine 120 "$WINE_BIN" "$WINE_PYTHON" -c "
import importlib
mods = ['MetaTrader5', 'mt5linux', 'rpyc', 'win32api']
for name in mods:
    importlib.import_module(name)
print('packages_ok')
"; then
    echo "[OK] Windows-side packages already present."
else
    echo "[INIT] Installing Windows-side Python packages..."

    clean_windows_python_packages

    if ! run_wine 90 "$WINE_BIN" "$WINE_PYTHON" -m pip --version >/dev/null 2>&1; then
        echo "[INIT] Bootstrapping pip..."
        wget -q "https://bootstrap.pypa.io/pip/${PYTHON_SERIES}/get-pip.py" -O /tmp/get-pip.py
        run_wine 180 "$WINE_BIN" "$WINE_PYTHON" /tmp/get-pip.py --no-warn-script-location \
            2>&1 | tee "$BOOTSTRAP_LOG" || {
            echo "[ERROR] Failed to bootstrap pip."
            exit 1
        }
    else
        echo "[OK] pip already present."
    fi

    run_wine 180 "$WINE_BIN" "$WINE_PYTHON" -m pip install --upgrade \
        pip \
        setuptools \
        wheel \
        --no-warn-script-location \
        --no-cache-dir \
        2>&1 | tee -a "$PIP_LOG" >/dev/null

    run_wine 300 "$WINE_BIN" "$WINE_PYTHON" -m pip install \
        MetaTrader5==5.0.5735 \
        mt5linux==1.0.3 \
        rpyc==5.2.3 \
        pywin32==312 \
        --no-warn-script-location \
        --no-cache-dir \
        2>&1 | tee "$PIP_LOG" || {
        echo "[ERROR] Failed to install Windows-side packages."
        exit 1
    }

    echo "[CHECK] Re-verifying Windows-side packages..."
    run_wine 120 "$WINE_BIN" "$WINE_PYTHON" -c "
import importlib
mods = ['MetaTrader5', 'mt5linux', 'rpyc', 'win32api']
for name in mods:
    importlib.import_module(name)
print('packages_ok')
" || {
        echo "[ERROR] Package verification still failed after install."
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

echo "[INFO] MT5_LOGIN=${MT5_LOGIN:-unset}" >> "$READY_LOG"
echo "[INFO] MT5_SERVER=${MT5_SERVER:-unset}" >> "$READY_LOG"
echo "[INFO] MT5_PASSWORD_SET=$([ -n "${MT5_PASSWORD:-}" ] && echo yes || echo no)" >> "$READY_LOG"

for i in $(seq 1 30); do
    if run_wine 45 "$WINE_BIN" "$WINE_PYTHON" -c "
import sys, os
import MetaTrader5 as mt5

kwargs = {}
login = os.environ.get('MT5_LOGIN')
password = os.environ.get('MT5_PASSWORD')
server = os.environ.get('MT5_SERVER')
if login:
    kwargs['login'] = int(login)
if password:
    kwargs['password'] = password
if server:
    kwargs['server'] = server

ok = mt5.initialize(**kwargs)
print('initialize=', ok, 'kwargs_keys=', list(kwargs.keys()))

if ok:
    print('terminal_info=', mt5.terminal_info())
    print('version=', mt5.version())
    mt5.shutdown()
    sys.exit(0)

print('last_error=', mt5.last_error())
sys.exit(1)
" >> "$READY_LOG" 2>&1
    then
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
