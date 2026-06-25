#!/bin/bash
set -euo pipefail

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export DISPLAY="${DISPLAY:-:99}"
export WINEDEBUG="${WINEDEBUG:--all}"

MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
BRIDGE_PORT="${BRIDGE_PORT:-${PORT:-8001}}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 1. Virtual display ──────────────────────────────────────────────────────
Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp &
sleep 2
log "Virtual display $DISPLAY ready"

# ── 2. Wine prefix (only slow on very first boot, persists via /config volume) ──
if [ ! -f "$WINEPREFIX/system.reg" ]; then
  log "First boot — initializing Wine prefix (takes 3-8 min, never again after this)..."
  mkdir -p "$WINEPREFIX"
  timeout 600 wine wineboot --init 2>/dev/null || true
  wineserver -w 2>/dev/null || true
  log "Wine prefix ready"
else
  log "Wine prefix already exists — skipping init"
fi

# ── 3. Install MetaTrader 5 (only if not already installed) ────────────────
if [ ! -f "$MT5_EXE" ]; then
  log "Installing MetaTrader 5 (one-time)..."
  cp /opt/mt5setup.exe "$WINEPREFIX/drive_c/mt5setup.exe"
  wine "$WINEPREFIX/drive_c/mt5setup.exe" /auto &
  wait $!
  sleep 15
  rm -f "$WINEPREFIX/drive_c/mt5setup.exe"
  if [ ! -f "$MT5_EXE" ]; then
    log "ERROR: MT5 install failed — terminal64.exe not found"
    exit 1
  fi
  log "MT5 installed successfully"
else
  log "MT5 already installed — skipping"
fi

# ── 4. Launch MT5 terminal ──────────────────────────────────────────────────
MT5_ARGS=""
if [ -n "${MT5_LOGIN:-}" ]; then
  MT5_ARGS="/login:${MT5_LOGIN} /password:${MT5_PASSWORD:-} /server:${MT5_SERVER:-}"
  log "Starting MT5 with auto-login (account ${MT5_LOGIN})..."
else
  log "Starting MT5 (no auto-login — set MT5_LOGIN, MT5_PASSWORD, MT5_SERVER to enable)..."
fi
wine "$MT5_EXE" $MT5_ARGS &

sleep 5
log "MT5 terminal launched"

# ── 5. mt5linux RPyC bridge ────────────────────────────────────────────────
log "Starting mt5linux bridge on port $BRIDGE_PORT..."
exec python3 -m mt5linux --host 0.0.0.0 -p "$BRIDGE_PORT"
