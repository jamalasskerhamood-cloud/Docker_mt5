FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    WINEPREFIX=/root/.wine \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    PYTHONUNBUFFERED=1 \
    PORT=8080

# =========================================================
# 1. SYSTEM DEPENDENCIES AND WINE
# =========================================================

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        curl \
        procps \
        psmisc \
        cabextract \
        unzip \
        dos2unix \
        xdotool \
        x11-utils \
        xvfb \
        fluxbox \
        x11vnc \
        novnc \
        websockify \
        net-tools \
        fonts-liberation \
        fonts-dejavu-core \
        file \
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
        gnupg \
        gpg \
    && mkdir -p /usr/share/keyrings \
    && wget -q \
        https://dl.winehq.org/wine-builds/winehq.key \
        -O /usr/share/keyrings/winehq-archive.key \
    && wget -q \
        https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
        -O /etc/apt/sources.list.d/winehq-bookworm.sources \
    && apt-get update \
    && apt-get install -y --install-recommends winehq-stable \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# =========================================================
# 2. PYTHON DEPENDENCIES
# =========================================================

RUN pip install --no-cache-dir mt5linux rpyc

# =========================================================
# 3. DIRECTORY SETUP
# =========================================================

RUN mkdir -p \
    /root/.wine \
    /root/mt5 \
    /var/log/mt5 \
    /tmp/.X11-unix

# =========================================================
# 4. ENTRYPOINT SCRIPT
# =========================================================

RUN cat > /entrypoint.sh <<'EOF'
#!/bin/bash

set -Eeuo pipefail

export DISPLAY=:1
export WINEPREFIX=/root/.wine
export WINEARCH=win64
export WINEDEBUG=-all
export PYTHONUNBUFFERED=1

# Railway may supply a different port.
PORT="${PORT:-8080}"

mkdir -p /var/log/mt5 /root/.wine

# Send startup output to Railway logs and a local log file.
exec > >(tee -a /var/log/mt5/startup.log) 2>&1

echo "=================================================="
echo "RAILWAY MT5 CONTAINER"
echo "Date: $(date)"
echo "Web port: ${PORT}"
echo "=================================================="

# ---------------------------------------------------------
# 1. START X SERVER
# ---------------------------------------------------------

echo "[1/7] Starting virtual display..."

Xvfb :1 \
    -screen 0 1280x1024x24 \
    -ac \
    -nolisten tcp \
    >/var/log/mt5/xvfb.log 2>&1 &

XVFB_PID=$!

for i in $(seq 1 30); do
    if xdpyinfo -display :1 >/dev/null 2>&1; then
        break
    fi

    if ! kill -0 "$XVFB_PID" 2>/dev/null; then
        echo "ERROR: Xvfb process exited."
        cat /var/log/mt5/xvfb.log || true
        exit 1
    fi

    sleep 1
done

if ! xdpyinfo -display :1 >/dev/null 2>&1; then
    echo "ERROR: Xvfb failed to initialize."
    cat /var/log/mt5/xvfb.log || true
    exit 1
fi

echo "X display ready."

# ---------------------------------------------------------
# 2. START WINDOW MANAGER
# ---------------------------------------------------------

echo "[2/7] Starting Fluxbox..."

fluxbox >/var/log/mt5/fluxbox.log 2>&1 &

sleep 2

# ---------------------------------------------------------
# 3. START VNC SERVER
# ---------------------------------------------------------

echo "[3/7] Starting VNC server..."

x11vnc \
    -display :1 \
    -forever \
    -shared \
    -nopw \
    -listen 127.0.0.1 \
    -rfbport 5900 \
    >/var/log/mt5/x11vnc.log 2>&1 &

VNC_PID=$!

for i in $(seq 1 20); do
    if ! kill -0 "$VNC_PID" 2>/dev/null; then
        echo "ERROR: x11vnc exited."
        cat /var/log/mt5/x11vnc.log || true
        exit 1
    fi

    if bash -c 'echo > /dev/tcp/127.0.0.1/5900' \
        >/dev/null 2>&1; then
        break
    fi

    sleep 1
done

if ! bash -c 'echo > /dev/tcp/127.0.0.1/5900' \
    >/dev/null 2>&1; then
    echo "ERROR: VNC port 5900 is not listening."
    exit 1
fi

echo "VNC server ready."

# ---------------------------------------------------------
# 4. START PUBLIC WEB INTERFACE
# ---------------------------------------------------------

echo "[4/7] Starting noVNC on port ${PORT}..."

# IMPORTANT:
# The public Railway port is handled by websockify.
# VNC remains private on localhost:5900.

websockify \
    --web=/usr/share/novnc \
    "0.0.0.0:${PORT}" \
    127.0.0.1:5900 \
    >/var/log/mt5/websockify.log 2>&1 &

WEB_PID=$!

sleep 3

if ! kill -0 "$WEB_PID" 2>/dev/null; then
    echo "ERROR: websockify exited."
    cat /var/log/mt5/websockify.log || true
    exit 1
fi

echo "noVNC process started."

# ---------------------------------------------------------
# 5. INITIALIZE WINE
# ---------------------------------------------------------

echo "[5/7] Initializing Wine..."

if [ ! -f "$WINEPREFIX/system.reg" ]; then
    echo "Creating Wine prefix..."

    set +e
    timeout 180s wineboot -i
    WINE_STATUS=$?
    set -e

    echo "Wine initialization status: ${WINE_STATUS}"
fi

if [ ! -f "$WINEPREFIX/system.reg" ]; then
    echo "ERROR: Wine prefix was not created."
    echo "Check the Wine initialization output above."

    # Keep noVNC available for troubleshooting.
    while true; do
        sleep 60
    done
fi

wineboot -u || true

sleep 5

wine reg add \
    "HKCU\\Software\\Wine\\WineDbg" \
    /v ShowCrashDialog \
    /t REG_DWORD \
    /d 0 \
    /f || true

# ---------------------------------------------------------
# 6. FIND OR INSTALL METATRADER 5
# ---------------------------------------------------------

echo "[6/7] Locating MetaTrader 5..."

MT5_EXE=""

# Check common locations.
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

# Search the Wine prefix if necessary.
if [ -z "$MT5_EXE" ]; then
    MT5_EXE="$(find "$WINEPREFIX/drive_c" \
        -type f \
        \( -iname terminal64.exe -o -iname terminal.exe \) \
        -print -quit 2>/dev/null || true)"
fi

if [ -z "$MT5_EXE" ]; then

    INSTALLER="/root/mt5setup.exe"

    echo "MetaTrader 5 is not installed."

    if [ ! -s "$INSTALLER" ]; then
        echo "Downloading the official MT5 installer..."

        wget \
            --timeout=30 \
            --tries=3 \
            --retry-connrefused \
            -O "${INSTALLER}.tmp" \
            "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

        mv "${INSTALLER}.tmp" "$INSTALLER"
    fi

    echo "Installer information:"
    ls -lh "$INSTALLER"
    file "$INSTALLER" || true

    echo "Launching installer on the virtual desktop..."

    # Do not use /auto or silently discard installer failures.
    set +e
    timeout 300s wine "$INSTALLER"
    INSTALL_STATUS=$?
    set -e

    echo "Installer exit status: ${INSTALL_STATUS}"

    # Check whether installation actually succeeded.
    for i in $(seq 1 60); do
        MT5_EXE="$(find "$WINEPREFIX/drive_c" \
            -type f \
            \( -iname terminal64.exe -o -iname terminal.exe \) \
            -print -quit 2>/dev/null || true)"

        if [ -n "$MT5_EXE" ]; then
            break
        fi

        sleep 2
    done
fi

# ---------------------------------------------------------
# 7. LAUNCH MT5 AND PYTHON BRIDGE
# ---------------------------------------------------------

if [ -z "$MT5_EXE" ] || [ ! -f "$MT5_EXE" ]; then

    echo "WARNING: MetaTrader 5 installation was not detected."
    echo "The noVNC web interface will remain available."
    echo "Open the Railway URL and inspect the installer dialog."
    echo "Startup log: /var/log/mt5/startup.log"

else

    echo "MetaTrader executable:"
    echo "$MT5_EXE"

    cd "$(dirname "$MT5_EXE")"

    echo "Starting MetaTrader 5..."

    wine "$MT5_EXE" \
        >/var/log/mt5/terminal.log 2>&1 &

    MT5_PID=$!

    sleep 10

    if kill -0 "$MT5_PID" 2>/dev/null; then
        echo "MT5 launch process is still running."
    else
        echo "WARNING: MT5 launch process exited."
        cat /var/log/mt5/terminal.log || true
    fi

fi

echo "Starting mt5linux bridge..."

python3 -m mt5linux \
    --host 0.0.0.0 \
    --port 8001 \
    >/var/log/mt5/bridge.log 2>&1 &

BRIDGE_PID=$!

sleep 3

if kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "Bridge process started."
else
    echo "WARNING: mt5linux bridge exited."
    cat /var/log/mt5/bridge.log || true
fi

# ---------------------------------------------------------
# KEEP CONTAINER ALIVE AND MONITOR WEB INTERFACE
# ---------------------------------------------------------

echo "=================================================="
echo "STARTUP FINISHED"
echo "noVNC port: ${PORT}"
echo "VNC localhost port: 5900"
echo "MT5 bridge port: 8001"
echo "=================================================="

while true; do

    if ! kill -0 "$WEB_PID" 2>/dev/null; then
        echo "ERROR: noVNC web process stopped."
        cat /var/log/mt5/websockify.log || true
        exit 1
    fi

    sleep 15

done
EOF

RUN chmod +x /entrypoint.sh \
    && dos2unix /entrypoint.sh

# Railway's public web interface uses the PORT environment variable.
EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
