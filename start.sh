#!/bin/bash
set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEARCH="${WINEARCH:-win64}"
export WINEDEBUG="${WINEDEBUG:--all}"
export DISPLAY="${DISPLAY:-:99}"

wine_executable="wine"
metatrader_version="5.0.36"
mt5server_port="${BRIDGE_PORT:-8001}"
mt5file="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"

# Auto-login: set MT5_CMD_OPTIONS in Zeabur, e.g.
#   MT5_CMD_OPTIONS=/login:12345 /password:yourpass /server:Broker-Demo
# If unset, build it from individual MT5_LOGIN / MT5_PASSWORD / MT5_SERVER vars.
MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"
if [ -z "$MT5_CMD_OPTIONS" ] && [ -n "${MT5_LOGIN:-}" ]; then
    MT5_CMD_OPTIONS="/login:${MT5_LOGIN} /password:${MT5_PASSWORD:-} /server:${MT5_SERVER:-}"
fi

mono_url="https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"
python_url="https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe"
mt5setup_url="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

is_python_package_installed() {
    python3 -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
}
is_wine_python_package_installed() {
    $wine_executable python -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
}

mkdir -p /config

# ── Virtual display (headless, no VNC) ────────────────────────────────────────
if ! pgrep -f "Xvfb $DISPLAY" >/dev/null 2>&1; then
    Xvfb "$DISPLAY" -screen 0 1280x800x24 &
    sleep 3
fi
log "[OK] Virtual display $DISPLAY started."

# ── [0/7] Initialize Wine prefix ──────────────────────────────────────────────
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    log "[0/7] Initializing Wine prefix..."
    $wine_executable wineboot --init
    wineserver -w 2>/dev/null || true
fi
log "[0/7] Wine prefix ready."

# ── [1/7] Wine Mono ───────────────────────────────────────────────────────────
if [ ! -e "$WINEPREFIX/drive_c/windows/mono" ]; then
    log "[1/7] Installing Wine Mono..."
    curl -L -o /tmp/mono.msi "$mono_url"
    WINEDLLOVERRIDES=mscoree=d $wine_executable msiexec /i /tmp/mono.msi /qn
    rm -f /tmp/mono.msi
else
    log "[1/7] Wine Mono already present."
fi

# ── [2-3/7] MetaTrader 5 terminal ─────────────────────────────────────────────
if [ -e "$mt5file" ]; then
    log "[2/7] MT5 already installed."
else
    log "[2/7] Installing MetaTrader 5..."
    $wine_executable reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d "win10" /f
    log "[3/7] Downloading MT5 installer..."
    curl -L -o "$WINEPREFIX/drive_c/mt5setup.exe" "$mt5setup_url"
    log "[3/7] Running MT5 installer..."
    $wine_executable "$WINEPREFIX/drive_c/mt5setup.exe" "/auto" &
    wait
    rm -f "$WINEPREFIX/drive_c/mt5setup.exe"
fi

# ── [4/7] Launch terminal (with auto-login if provided) ───────────────────────
if [ -e "$mt5file" ]; then
    log "[4/7] Launching MT5 terminal..."
    [ -n "$MT5_CMD_OPTIONS" ] && log "[4/7] Using auto-login options." || log "[4/7] No MT5_CMD_OPTIONS set; terminal will need manual credentials."
    $wine_executable "$mt5file" $MT5_CMD_OPTIONS &
else
    log "[4/7] ERROR: MT5 executable missing; cannot launch."
fi

# ── [5/7] Windows-side Python ─────────────────────────────────────────────────
if ! $wine_executable python --version 2>/dev/null; then
    log "[5/7] Installing Python in Wine..."
    curl -L "$python_url" -o /tmp/python-installer.exe
    $wine_executable /tmp/python-installer.exe /quiet InstallAllUsers=1 PrependPath=1
    rm -f /tmp/python-installer.exe
else
    log "[5/7] Python already installed in Wine."
fi

# ── [6/7] Python libraries ────────────────────────────────────────────────────
log "[6/7] Ensuring Python libraries..."
$wine_executable python -m pip install --upgrade --no-cache-dir pip

if ! is_wine_python_package_installed "MetaTrader5==$metatrader_version"; then
    $wine_executable python -m pip install --no-cache-dir "MetaTrader5==$metatrader_version"
fi
if ! is_wine_python_package_installed "mt5linux"; then
    $wine_executable python -m pip install --no-cache-dir "mt5linux>=0.1.9"
fi
if ! is_wine_python_package_installed "python-dateutil"; then
    $wine_executable python -m pip install --no-cache-dir python-dateutil
fi
if ! is_python_package_installed "mt5linux"; then
    pip install --break-system-packages --no-cache-dir --no-deps mt5linux && \
    pip install --break-system-packages --no-cache-dir rpyc plumbum numpy
fi

# ── [7/7] mt5linux RPyC bridge (foreground — keeps container alive) ───────────
log "[7/7] Starting mt5linux server on port ${mt5server_port}..."
python3 -m mt5linux --host 0.0.0.0 -p "$mt5server_port" -w "$wine_executable" python.exe &
BRIDGE_PID=$!

sleep 5
if ss -tuln | grep ":$mt5server_port" >/dev/null; then
    log "[7/7] mt5linux server is listening on port $mt5server_port."
else
    log "[7/7] WARNING: bridge not bound yet on $mt5server_port (may still be starting)."
fi

# Keep the container in the foreground on the bridge process.
wait "$BRIDGE_PID"
