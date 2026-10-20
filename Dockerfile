FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all
ENV PYTHONUNBUFFERED=1

# =========================================================
# SYSTEM DEPENDENCIES AND WINE
# =========================================================

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        curl \
        procps \
        cabextract \
        unzip \
        dos2unix \
        xdotool \
        xvfb \
        fluxbox \
        x11vnc \
        novnc \
        websockify \
        net-tools \
        psmisc \
        fonts-liberation \
        fonts-dejavu-core \
        libgl1 \
        libglib2.0-0 \
        libnss3 \
        libx11-6 \
        libxext6 \
        libxrender1 \
        libxtst6 \
        libxi6 \
        libxrandr2 \
        libxcursor1 \
        libxcomposite1 \
        libasound2 \
        libfontconfig1 \
        libfreetype6 \
        libvulkan1 \
        gpg \
        gnupg \
    && mkdir -p /etc/apt/keyrings \
    && wget -q \
        https://dl.winehq.org/wine-builds/winehq.key \
        -O /etc/apt/keyrings/winehq-archive.key \
    && wget -q \
        https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
        -O /etc/apt/sources.list.d/winehq-bookworm.sources \
    && apt-get update \
    && apt-get install -y --install-recommends winehq-stable \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# =========================================================
# PYTHON BRIDGE
# =========================================================

RUN pip install --no-cache-dir mt5linux rpyc

# =========================================================
# DIRECTORY SETUP
# =========================================================

RUN mkdir -p \
    /root/.wine \
    /root/mt5 \
    /var/log/mt5 \
    /tmp/.X11-unix

# =========================================================
# ENTRYPOINT
# =========================================================

RUN cat > /entrypoint.sh <<'EOF'
#!/bin/bash

set -Eeuo pipefail

export DISPLAY=:1
export WINEPREFIX=/root/.wine
export WINEARCH=win64
export WINEDEBUG=-all
export PYTHONUNBUFFERED=1

LOG=/var/log/mt5/startup.log

mkdir -p /var/log/mt5 /root/.wine

exec > >(tee -a "$LOG") 2>&1

echo "=================================================="
echo "Railway MT5 Desktop Starting"
echo "Date: $(date)"
echo "=================================================="

# ---------------------------------------------------------
# Process cleanup
# ---------------------------------------------------------

echo "[1/8] Cleaning up stale processes..."

pkill -x x11vnc 2>/dev/null || true
pkill -x websockify 2>/dev/null || true
pkill -x fluxbox 2>/dev/null || true

# Do not delete X11 lock files indiscriminately.
# Do not kill Wine processes before every startup.

# ---------------------------------------------------------
# Start virtual display
# ---------------------------------------------------------

echo "[2/8] Starting Xvfb..."

if ! pgrep -x Xvfb >/dev/null 2>&1; then
    Xvfb :1 -screen 0 1280x1024x24 -ac \
        -nolisten tcp &
fi

for i in $(seq 1 30); do
    if xdpyinfo -display :1 >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! xdpyinfo -display :1 >/dev/null 2>&1; then
    echo "ERROR: Xvfb failed to start."
    exit 1
fi

# ---------------------------------------------------------
# Start window manager
# ---------------------------------------------------------

echo "[3/8] Starting Fluxbox..."

fluxbox >/var/log/mt5/fluxbox.log 2>&1 &

sleep 2

# ---------------------------------------------------------
# Start VNC and noVNC
# ---------------------------------------------------------

echo "[4/8] Starting VNC services..."

x11vnc \
    -display :1 \
    -forever \
    -shared \
    -nopw \
    -listen 0.0.0.0 \
    -rfbport 5900 \
    >/var/log/mt5/x11vnc.log 2>&1 &

sleep 2

websockify \
    --web=/usr/share/novnc \
    0.0.0.0:8080 \
    127.0.0.1:5900 \
    >/var/log/mt5/websockify.log 2>&1 &

# ---------------------------------------------------------
# Initialize Wine
# ---------------------------------------------------------

echo "[5/8] Initializing Wine..."

if [ ! -f "$WINEPREFIX/system.reg" ]; then
    echo "Creating a new Wine prefix..."

    wineboot -i

    for i in $(seq 1 60); do
        if [ -f "$WINEPREFIX/system.reg" ]; then
            break
        fi
        sleep 1
    done
fi

if [ ! -f "$WINEPREFIX/system.reg" ]; then
    echo "ERROR: Wine prefix initialization failed."
    exit 1
fi

# Allow Wine services to initialize.
wineboot -u || true
sleep 5

# ---------------------------------------------------------
# Configure Wine crash dialog behavior
# ---------------------------------------------------------

echo "[6/8] Configuring Wine..."

wine reg add \
    "HKCU\\Software\\Wine\\WineDbg" \
    /v ShowCrashDialog \
    /t REG_DWORD \
    /d 0 \
    /f || true

# ---------------------------------------------------------
# Find or install MetaTrader 5
# ---------------------------------------------------------

echo "[7/8] Checking MetaTrader 5 installation..."

MT5_EXE=""

# Search known installation locations first.
for candidate in \
    "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" \
    "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal.exe" \
    "/root/.wine/drive_c/Program Files (x86)/MetaTrader 5/terminal64.exe" \
    "/root/.wine/drive_c/Program Files (x86)/MetaTrader 5/terminal.exe" \
    "/root/mt5/terminal64.exe"
do
    if [ -f "$candidate" ]; then
        MT5_EXE="$candidate"
        break
    fi
done

# Search the prefix if MT5 is installed elsewhere.
if [ -z "$MT5_EXE" ]; then
    MT5_EXE=$(find "$WINEPREFIX/drive_c" \
        -type f \
        \( -iname "terminal64.exe" -o -iname "terminal.exe" \) \
        -print -quit 2>/dev/null || true)
fi

if [ -z "$MT5_EXE" ]; then
    echo "MetaTrader 5 is not installed."

    INSTALLER=/root/mt5setup.exe

    if [ ! -s "$INSTALLER" ]; then
        echo "Downloading the official MetaTrader 5 installer..."

        wget \
            --timeout=30 \
            --tries=3 \
            --retry-connrefused \
            -O "$INSTALLER.tmp" \
            "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

        mv "$INSTALLER.tmp" "$INSTALLER"
    fi

    echo "Installer details:"
    ls -lh "$INSTALLER"
    file "$INSTALLER" 2>/dev/null || true

    echo "Starting MetaTrader 5 installer..."

    # Do not hide installation errors with '|| true'.
    # Keep the installer attached to the visible desktop.
    set +e
    timeout 300s wine "$INSTALLER"
    INSTALL_STATUS=$?
    set -e

    echo "Installer exit status: $INSTALL_STATUS"

    echo "Waiting for installation to finish..."

    for i in $(seq 1 60); do
        MT5_EXE=$(find "$WINEPREFIX/drive_c" \
            -type f \
            \( -iname "terminal64.exe" -o -iname "terminal.exe" \) \
            -print -quit 2>/dev/null || true)

        if [ -n "$MT5_EXE" ]; then
            break
        fi

        sleep 2
    done
fi

# ---------------------------------------------------------
# Verify installation
# ---------------------------------------------------------

if [ -z "$MT5_EXE" ] || [ ! -f "$MT5_EXE" ]; then
    echo "=================================================="
    echo "ERROR: MetaTrader 5 installation was not detected."
    echo "The installer may have failed or shown an error dialog."
    echo "Connect to the desktop using noVNC and inspect it."
    echo "Startup log: /var/log/mt5/startup.log"
    echo "=================================================="

    # Keep the desktop alive so the error can be inspected.
    while true; do
        sleep 60
    done
fi

echo "MetaTrader executable found:"
echo "$MT5_EXE"

# ---------------------------------------------------------
# Launch terminal
# ---------------------------------------------------------

echo "Launching MetaTrader 5..."

cd "$(dirname "$MT5_EXE")"

wine "$MT5_EXE" >/var/log/mt5/terminal.log 2>&1 &

# Give the terminal time to initialize.
sleep 15

echo "Checking terminal processes..."
pgrep -af 'terminal64.exe|terminal.exe' || true

# ---------------------------------------------------------
# Start Python bridge
# ---------------------------------------------------------

echo "[8/8] Starting mt5linux bridge..."

python3 -m mt5linux \
    --host 0.0.0.0 \
    --port 8001 \
    >/var/log/mt5/bridge.log 2>&1 &

BRIDGE_PID=$!

sleep 3

if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "WARNING: The mt5linux bridge exited."
    echo "Check /var/log/mt5/bridge.log"
else
    echo "mt5linux bridge started with PID $BRIDGE_PID"
fi

echo "=================================================="
echo "Startup sequence completed."
echo "noVNC port: 8080"
echo "MT5 bridge port: 8001"
echo "=================================================="

# Keep the container alive and preserve child processes.
while true; do
    sleep 60
done
EOF

RUN chmod +x /entrypoint.sh \
    && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
