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

# Pre-cached installers baked into the Docker image — no internet needed at runtime
CACHED_MONO="/opt/installers/mono.msi"
CACHED_PYTHON="/opt/installers/python-installer.exe"
CACHED_MT5="/opt/installers/mt5setup.exe"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

die() {
  log "ERROR: $1"
  exit 1
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

# ── Start winbindd ─────────────────────────────────────────────────────────────
winbindd --no-process-group 2>/dev/null &
sleep 2
log "[PRE] Winbind daemon started."

log "[DIAG] Wine: $($wine_executable --version 2>&1 || echo FAILED)"
log "[DIAG] WINEPREFIX: $WINEPREFIX"
log "[DIAG] Cached installers: $(ls -lh /opt/installers/ 2>/dev/null | tail -4 || echo NONE)"

# ── [0/7] Initialize Wine prefix ──────────────────────────────────────────────
# The WINEPREFIX lives in /config (persistent volume). On the very first boot
# it will take 3-8 minutes to initialize. Every subsequent restart is instant.
wine_ok=false
if [ -f "$WINEPREFIX/system.reg" ]; then
  log "[0/7] Testing existing Wine prefix..."
  if timeout 15 $wine_executable cmd /c "echo wine_test_ok" 2>/dev/null | grep -q "wine_test_ok"; then
    wine_ok=true
    log "[0/7] Wine prefix is healthy — skipping initialization."
  else
    log "[0/7] Wine prefix is broken — removing and reinitializing..."
    rm -rf "$WINEPREFIX"
  fi
fi

if [ "$wine_ok" = "false" ]; then
  log "[0/7] Initializing Wine prefix (first boot only — takes 3-8 min)..."
  wineserver -f &
  WSERVER_PID=$!
  sleep 2
  log "[0/7] Wineserver started (PID: $WSERVER_PID)"
  WINEDEBUG=fixme-all timeout 600 $wine_executable wineboot --init 2>/dev/null || true
  log "[0/7] Wineboot returned."
  wineserver -w 2>/dev/null || true
  sleep 3
  if [ -f "$WINEPREFIX/system.reg" ]; then
    log "[0/7] Wine prefix created successfully."
  else
    log "[0/7] WARNING: Wine prefix may not be fully initialized — continuing anyway."
  fi
fi
log "[0/7] Wine prefix ready."

# ── [1/7] Wine Mono — use pre-cached file, no download ────────────────────────
if [ ! -e "$WINEPREFIX/drive_c/windows/mono" ]; then
  log "[1/7] Installing Wine Mono from cached image file..."
  if [ -f "$CACHED_MONO" ]; then
    WINEDLLOVERRIDES=mscoree=d $wine_executable msiexec /i "$CACHED_MONO" /qn 2>&1 | tail -5 || true
  else
    log "[1/7] Cache miss — downloading Wine Mono..."
    curl -fL -o "$TMPDIR/mono.msi" "https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"
    WINEDLLOVERRIDES=mscoree=d $wine_executable msiexec /i "$TMPDIR/mono.msi" /qn 2>&1 | tail -5 || true
    rm -f "$TMPDIR/mono.msi"
  fi
  wineserver -w 2>/dev/null || true
else
  log "[1/7] Wine Mono already present."
fi

# ── [2-3/7] MetaTrader 5 terminal — use pre-cached installer ──────────────────
if [ -e "$mt5file" ]; then
  log "[2/7] MT5 already installed."
else
  log "[2/7] Installing MetaTrader 5 from cached image file..."
  $wine_executable reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d "win10" /f 2>/dev/null || true

  if [ -f "$CACHED_MT5" ]; then
    cp "$CACHED_MT5" "$WINEPREFIX/drive_c/mt5setup.exe"
  else
    log "[3/7] Cache miss — downloading MT5 installer..."
    curl -fL -o "$WINEPREFIX/drive_c/mt5setup.exe" \
      "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
  fi

  log "[3/7] Running MT5 installer (silent)..."
  $wine_executable "$WINEPREFIX/drive_c/mt5setup.exe" "/auto" &
  wait
  sleep 10
  rm -f "$WINEPREFIX/drive_c/mt5setup.exe"
  [ -e "$mt5file" ] || die "MT5 installer finished but terminal64.exe was not created."
fi
log "[2/7] MT5 installed."

# ── [4/7] Launch MT5 terminal ─────────────────────────────────────────────────
if [ -e "$mt5file" ]; then
  log "[4/7] Launching MT5 terminal..."
  [ -n "$MT5_CMD_OPTIONS" ] \
    && log "[4/7] Auto-login options set." \
    || log "[4/7] No MT5_CMD_OPTIONS — terminal will start without auto-login."
  $wine_executable "$mt5file" $MT5_CMD_OPTIONS &
else
  log "[4/7] ERROR: MT5 executable missing; cannot launch."
fi

# ── [5/7] Windows-side Python — use pre-cached installer ──────────────────────
if ! $wine_executable python --version 2>/dev/null; then
  log "[5/7] Installing Python 3.9 in Wine from cached image file..."
  if [ -f "$CACHED_PYTHON" ]; then
    $wine_executable "$CACHED_PYTHON" /quiet InstallAllUsers=1 PrependPath=1 2>/dev/null || true
  else
    log "[5/7] Cache miss — downloading Python installer..."
    curl -fL -o "$TMPDIR/python-installer.exe" \
      "https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe"
    $wine_executable "$TMPDIR/python-installer.exe" /quiet InstallAllUsers=1 PrependPath=1 2>/dev/null || true
    rm -f "$TMPDIR/python-installer.exe"
  fi
  wineserver -w 2>/dev/null || true
else
  log "[5/7] Python already installed in Wine."
fi

# ── [6/7] Windows Python libraries ────────────────────────────────────────────
log "[6/7] Ensuring Windows Python libraries..."
$wine_executable python -m pip install --upgrade --quiet --no-cache-dir pip 2>/dev/null || true

if ! is_wine_python_package_installed "MetaTrader5==$metatrader_version" 2>/dev/null; then
  $wine_executable python -m pip install --quiet --no-cache-dir "MetaTrader5==$metatrader_version" || true
fi
if ! is_wine_python_package_installed "mt5linux" 2>/dev/null; then
  $wine_executable python -m pip install --quiet --no-cache-dir "mt5linux>=0.1.9" || true
fi
if ! is_wine_python_package_installed "python-dateutil" 2>/dev/null; then
  $wine_executable python -m pip install --quiet --no-cache-dir python-dateutil || true
fi
log "[6/7] Windows Python libraries ready."

# ── [7/7] mt5linux RPyC bridge ─────────────────────────────────────────────────
log "[7/7] Starting mt5linux bridge on port ${mt5server_port}..."
python3 -m mt5linux --host 0.0.0.0 -p "$mt5server_port" -w "$wine_executable" python.exe &
BRIDGE_PID=$!

sleep 5
if ss -tuln | grep ":${mt5server_port}" >/dev/null 2>&1; then
  log "[7/7] mt5linux bridge is listening on :${mt5server_port} ✓"
else
  log "[7/7] WARNING: bridge not bound yet on :${mt5server_port} (may still be starting)."
fi

log "===== Startup complete. MT5 bridge running on port ${mt5server_port} ====="
wait "$BRIDGE_PID"
