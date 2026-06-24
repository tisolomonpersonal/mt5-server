#!/bin/bash
set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEARCH="${WINEARCH:-win64}"
export WINEDEBUG="${WINEDEBUG:--all}"
export DISPLAY="${DISPLAY:-:99}"

# Try wine64 first, fall back to wine
if [ -x "/opt/wine-stable/bin/wine64" ]; then
  wine_executable="/opt/wine-stable/bin/wine64"
elif [ -x "/opt/wine-stable/bin/wine" ]; then
  wine_executable="/opt/wine-stable/bin/wine"
else
  wine_executable="wine"
fi

metatrader_version="5.0.36"
mt5server_port="${BRIDGE_PORT:-${PORT:-8001}}"
mt5file="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"

MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"
if [ -z "$MT5_CMD_OPTIONS" ] && [ -n "${MT5_LOGIN:-}" ]; then
  MT5_CMD_OPTIONS="/login:${MT5_LOGIN} /password:${MT5_PASSWORD:-} /server:${MT5_SERVER:-}"
fi

mono_url="https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"
python_url="https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe"
mt5setup_url="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

die() {
  log "ERROR: $1"
  exit 1
}

is_python_package_installed() {
  python3 -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
}
is_wine_python_package_installed() {
  $wine_executable python -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
}

mkdir -p /config
export TMPDIR=/config/tmp
export XDG_RUNTIME_DIR=/config/run
mkdir -p "$TMPDIR" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# ── Virtual display ────────────────────────────────────────────────────────────
if ! pgrep -f "Xvfb $DISPLAY" >/dev/null 2>&1; then
  Xvfb "$DISPLAY" -screen 0 1280x800x24 &
  sleep 3
fi
log "[OK] Virtual display $DISPLAY started."

# ── Start winbindd directly ────────────────────────────────────────────────────
log "[PRE] Starting winbindd..."
winbindd --no-process-group 2>/dev/null &
sleep 2
log "[PRE] Winbind daemon started."

# ── Diagnose wine availability ─────────────────────────────────────────────────
log "[DIAG] Using wine executable: $wine_executable"
log "[DIAG] Wine binaries in /opt/wine-stable/bin/: $(ls /opt/wine-stable/bin/wine* 2>/dev/null | tr '\n' ' ' || echo 'NONE')"
log "[DIAG] Wine libs x86_64: $(ls /opt/wine-stable/lib/wine/x86_64-unix/ 2>/dev/null | head -3 || echo 'NONE')"
log "[DIAG] Wine libs i386: $(ls /opt/wine-stable/lib/wine/i386-unix/ 2>/dev/null | head -3 || echo 'NONE')"
log "[DIAG] Wine version: $($wine_executable --version 2>&1 || echo 'FAILED')"

# ── [0/7] Initialize Wine prefix ──────────────────────────────────────────────
wine_ok=false
if [ -f "$WINEPREFIX/system.reg" ]; then
  log "[0/7] Testing existing Wine prefix..."
  if timeout 10 $wine_executable cmd /c "echo wine_test_ok" 2>/dev/null | grep -q "wine_test_ok"; then
    wine_ok=true
    log "[0/7] Existing Wine prefix is healthy."
  else
    log "[0/7] Existing Wine prefix is broken - removing and reinitializing..."
    rm -rf "$WINEPREFIX"
  fi
fi

if [ "$wine_ok" = "false" ]; then
  log "[0/7] Initializing Wine prefix (this may take several minutes)..."
  wineserver -f &
  WSERVER_PID=$!
  sleep 2
  log "[0/7] Wineserver started (PID: $WSERVER_PID)"
  # Fix: removed head -100 pipe that caused hangs; increased timeout to 600s
  WINEDEBUG=fixme-all timeout 600 $wine_executable wineboot --init 2>/dev/null || true
  log "[0/7] Wineboot returned."
  wineserver -w 2>/dev/null || true
  sleep 3
  if [ -f "$WINEPREFIX/system.reg" ]; then
    log "[0/7] Wine prefix created successfully."
  else
    log "[0/7] WARNING: Wine prefix may not be fully initialized."
  fi
fi
log "[0/7] Wine prefix ready."

# ── [1/7] Wine Mono ───────────────────────────────────────────────────────────
if [ ! -e "$WINEPREFIX/drive_c/windows/mono" ]; then
  log "[1/7] Installing Wine Mono..."
  curl -L -o "$TMPDIR/mono.msi" "$mono_url"
  WINEDLLOVERRIDES=mscoree=d $wine_executable msiexec /i "$TMPDIR/mono.msi" /qn 2>&1 | tail -5 || true
  wineserver -w 2>/dev/null || true
  rm -f "$TMPDIR/mono.msi"
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
  sleep 10
  rm -f "$WINEPREFIX/drive_c/mt5setup.exe"
  [ -e "$mt5file" ] || die "MT5 installer finished, but terminal64.exe was not created."
fi
log "[2/7] MT5 installed."

# ── [4/7] Launch terminal ─────────────────────────────────────────────────────
if [ -e "$mt5file" ]; then
  log "[4/7] Launching MT5 terminal..."
  [ -n "$MT5_CMD_OPTIONS" ] && log "[4/7] Using auto-login options." || log "[4/7] No MT5_CMD_OPTIONS set."
  $wine_executable "$mt5file" $MT5_CMD_OPTIONS &
else
  log "[4/7] ERROR: MT5 executable missing; cannot launch."
fi

# ── [5/7] Windows-side Python ─────────────────────────────────────────────────
if ! $wine_executable python --version 2>/dev/null; then
  log "[5/7] Installing Python in Wine..."
  curl -L "$python_url" -o "$TMPDIR/python-installer.exe"
  $wine_executable "$TMPDIR/python-installer.exe" /quiet InstallAllUsers=1 PrependPath=1
  wineserver -w 2>/dev/null || true
  rm -f "$TMPDIR/python-installer.exe"
else
  log "[5/7] Python already installed in Wine."
fi

# ── [6/7] Python libraries ─────────────────────────────────────────────────────
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

# ── [7/7] mt5linux RPyC bridge ─────────────────────────────────────────────────
log "[7/7] Starting mt5linux server on port ${mt5server_port}..."
python3 -m mt5linux --host 0.0.0.0 -p "$mt5server_port" -w "$wine_executable" python.exe &
BRIDGE_PID=$!

sleep 5
if ss -tuln | grep ":${mt5server_port}" >/dev/null; then
  log "[7/7] mt5linux server is listening on port ${mt5server_port}."
else
  log "[7/7] WARNING: bridge not bound yet on ${mt5server_port} (may still be starting)."
fi

wait "$BRIDGE_PID"
