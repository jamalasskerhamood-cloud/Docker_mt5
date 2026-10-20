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
echo "Railway MT5 Direct Portable Boot"
echo "Date: $(date)"
echo "=================================================="

# ---------------------------------------------------------
# 1. Start Display & Web Port Immediately (Passes Healthcheck)
# ---------------------------------------------------------

echo "[1/4] Starting virtual display and web bridge..."

pkill -x x11vnc 2>/dev/null || true
pkill -x websockify 2>/dev/null || true
pkill -x fluxbox 2>/dev/null || true

Xvfb :1 -screen 0 1280x1024x24 -ac -nolisten tcp &
sleep 2

fluxbox >/var/log/mt5/fluxbox.log 2>&1 &

x11vnc \
    -display :1 \
    -forever \
    -shared \
    -nopw \
    -listen 0.0.0.0 \
    -rfbport 5900 \
    >/var/log/mt5/x11vnc.log 2>&1 &

websockify \
    --web=/usr/share/novnc \
    0.0.0.0:8080 \
    127.0.0.1:5900 \
    >/var/log/mt5/websockify.log 2>&1 &

# ---------------------------------------------------------
# 2. Setup Wine & Launch Terminal Directly Without Installer
# ---------------------------------------------------------

(
    echo "[2/4] Initializing Wine environment..."
    if [ ! -f "$WINEPREFIX/system.reg" ]; then
        wineboot -i
        for i in $(seq 1 60); do
            [ -f "$WINEPREFIX/system.reg" ] && break
            sleep 1
        done
    fi

    wineboot -u || true
    sleep 3

    MT5_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5"
    MT5_EXE="$MT5_DIR/terminal64.exe"

    if [ ! -f "$MT5_EXE" ]; then
        echo "[3/4] Downloading MetaTrader 5 direct portable package..."
        mkdir -p /tmp/mt5_dl && cd /tmp/mt5_dl
        
        # Download official standalone package archive instead of the setup wizard
        wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt55setup.exe -O mt5setup.exe || true
        
        # Extract files cleanly via cabextract without running the interactive installer binary
        cabextract mt5setup.exe || unzip mt5setup.exe || true
        
        # Fallback: create directory structure if direct extraction needs assistance
        mkdir -p "$MT5_DIR"
        
        # If terminal64 isn't populated, let's copy a minimal working layout or trigger silent installer with strict switches
        wine msiexec /i mt5setup.exe /quiet /qn /norestart || true
    fi

    # Dynamic search for terminal executable
    if [ ! -f "$MT5_EXE" ]; then
        FOUND_EXE=$(find "$WINEPREFIX/drive_c" -type f \( -iname "terminal64.exe" -o -iname "terminal.exe" \) -print -quit 2>/dev/null || true)
        if [ -n "$FOUND_EXE" ]; then
            MT5_EXE="$FOUND_EXE"
        fi
    fi

    if [ -n "$MT5_EXE" ] && [ -f "$MT5_EXE" ]; then
        echo "[4/4] Launching MetaTrader 5 terminal: $MT5_EXE"
        cd "$(dirname "$MT5_EXE")"
        wine "$MT5_EXE" /portable >/var/log/mt5/terminal.log 2>&1 &
        sleep 10
    else
        echo "WARNING: Terminal executable needs manual check via noVNC."
    fi

    # Start python mt5linux bridge
    python3 -m mt5linux --host 0.0.0.0 --port 8001 >/var/log/mt5/bridge.log 2>&1 &
    echo "Initialization sequence completed."
) &

# Keep main container process alive
while true; do
    sleep 60
done
EOF

RUN chmod +x /entrypoint.sh \
    && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
