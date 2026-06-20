#!/bin/bash

# ── Configuration ─────────────────────────────────────────────────────────────
mt5file='/config/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe'
export WINEPREFIX='/config/.wine'
export WINEDEBUG='-all'
wine_executable="wine"
metatrader_version="5.0.36"

# Bridge port (kept BRIDGE_PORT for backward compatibility with existing config)
mt5server_port="${BRIDGE_PORT:-8001}"

# Extra terminal command-line options. To auto-login, set MT5_CMD_OPTIONS, e.g.
#   MT5_CMD_OPTIONS="/login:12345 /password:secret /server:Broker-Demo"
MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"

mono_url="https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"
python_url="https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe"
mt5setup_url="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

show_message() { echo "$1"; }

check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "$1 is not installed. Please install it to continue."
        exit 1
    fi
}

is_python_package_installed() {
    python3 -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
}

is_wine_python_package_installed() {
    $wine_executable python -c "import pkg_resources; exit(not pkg_resources.require('$1'))" 2>/dev/null
}

check_dependency "curl"
check_dependency "$wine_executable"

# ── [1/7] Wine Mono ───────────────────────────────────────────────────────────
if [ ! -e "/config/.wine/drive_c/windows/mono" ]; then
    show_message "[1/7] Downloading and installing Mono..."
    curl -o /config/.wine/drive_c/mono.msi "$mono_url"
    WINEDLLOVERRIDES=mscoree=d $wine_executable msiexec /i /config/.wine/drive_c/mono.msi /qn
    rm -f /config/.wine/drive_c/mono.msi
    show_message "[1/7] Mono installed."
else
    show_message "[1/7] Mono is already installed."
fi

# ── [2-3/7] MetaTrader 5 terminal ─────────────────────────────────────────────
if [ -e "$mt5file" ]; then
    show_message "[2/7] MT5 already installed."
else
    show_message "[2/7] MT5 not installed. Installing..."
    $wine_executable reg add "HKEY_CURRENT_USER\\Software\\Wine" /v Version /t REG_SZ /d "win10" /f
    show_message "[3/7] Downloading MT5 installer..."
    curl -o /config/.wine/drive_c/mt5setup.exe "$mt5setup_url"
    show_message "[3/7] Installing MetaTrader 5..."
    $wine_executable "/config/.wine/drive_c/mt5setup.exe" "/auto" &
    wait
    rm -f /config/.wine/drive_c/mt5setup.exe
fi

# ── [4/7] Launch terminal ─────────────────────────────────────────────────────
if [ -e "$mt5file" ]; then
    show_message "[4/7] Launching MT5 terminal..."
    $wine_executable "$mt5file" $MT5_CMD_OPTIONS &
else
    show_message "[4/7] MT5 executable missing; cannot launch."
fi

# ── [5/7] Windows-side Python ─────────────────────────────────────────────────
if ! $wine_executable python --version 2>/dev/null; then
    show_message "[5/7] Installing Python in Wine..."
    curl -L "$python_url" -o /tmp/python-installer.exe
    $wine_executable /tmp/python-installer.exe /quiet InstallAllUsers=1 PrependPath=1
    rm -f /tmp/python-installer.exe
    show_message "[5/7] Python installed in Wine."
else
    show_message "[5/7] Python already installed in Wine."
fi

# ── [6/7] Python libraries ────────────────────────────────────────────────────
show_message "[6/7] Upgrading pip (Wine)..."
$wine_executable python -m pip install --upgrade --no-cache-dir pip

if ! is_wine_python_package_installed "MetaTrader5==$metatrader_version"; then
    show_message "[6/7] Installing MetaTrader5 (Wine)..."
    $wine_executable python -m pip install --no-cache-dir MetaTrader5==$metatrader_version
fi

if ! is_wine_python_package_installed "mt5linux"; then
    show_message "[6/7] Installing mt5linux (Wine)..."
    $wine_executable python -m pip install --no-cache-dir "mt5linux>=0.1.9"
fi

if ! is_wine_python_package_installed "python-dateutil"; then
    show_message "[6/7] Installing python-dateutil (Wine)..."
    $wine_executable python -m pip install --no-cache-dir python-dateutil
fi

if ! is_python_package_installed "mt5linux"; then
    show_message "[6/7] Installing mt5linux (Linux)..."
    pip install --break-system-packages --no-cache-dir --no-deps mt5linux && \
    pip install --break-system-packages --no-cache-dir rpyc plumbum numpy
fi

if ! is_python_package_installed "pyxdg"; then
    show_message "[6/7] Installing pyxdg (Linux)..."
    pip install --break-system-packages --no-cache-dir pyxdg
fi

# ── [7/7] mt5linux RPyC bridge ────────────────────────────────────────────────
show_message "[7/7] Starting mt5linux server on port ${mt5server_port}..."
python3 -m mt5linux --host 0.0.0.0 -p "$mt5server_port" -w "$wine_executable" python.exe &

sleep 5

if ss -tuln | grep ":$mt5server_port" > /dev/null; then
    show_message "[7/7] mt5linux server is running on port $mt5server_port."
else
    show_message "[7/7] WARNING: mt5linux server did not bind port $mt5server_port yet."
fi
