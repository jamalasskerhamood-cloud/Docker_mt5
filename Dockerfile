FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all
ENV PYTHONUNBUFFERED=1

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
        xterm \
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
        xauth \
    && mkdir -p /etc/apt/keyrings \
    && wget -q \
        https://dl.winehq.org/wine-builds/winehq.key \
        -O /etc/apt/keyrings/winehq-archive.key \
    && wget -q \
        https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
        -O /etc/apt/sources.list.d/winehq-bookworm.sources \
    && apt-get update \
    && apt-get install -y --install-recommends winehq-staging \
    && wine --version \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# =========================================================
# 2. PYTHON MT5 BRIDGE
# =========================================================

RUN pip install --no-cache-dir mt5linux rpyc

# =========================================================
# 3. DIRECTORY STRUCTURE
# =========================================================

RUN mkdir -p \
    /root/.wine \
    /root/mt5 \
    /var/log/mt5 \
    /tmp/.X11-unix

# =========================================================
# 4. ENTRYPOINT
# =========================================================

RUN cat > /entrypoint.sh <<'EOF'
#!/bin/bash

set -Eeuo pipefail

export DISPLAY=:1
export WINEPREFIX=/root/.wine
export WINEARCH=win64
export WINEDEBUG=-all
export PYTHONUNBUFFERED=1

LOG_DIR=/var/log/mt5
mkdir -p "$LOG_DIR" "$WINEPREFIX" /tmp/.X11-unix

exec > >(tee -a "$LOG_DIR/startup.log") 2>&1

echo "=================================================="
echo "Railway MT5 Desktop Terminal Ready"
echo "Date: $(date)"
echo "=================================================="

# =========================================================
# 1. START DISPLAY & WEB PORT IMMEDIATELY (Passes Healthcheck)
# =========================================================

echo "[1/5] Starting Xvfb..."
Xvfb :1 \
    -screen 0 1280x1024x24 \
    -ac \
    -nolisten tcp \
    >"$LOG_DIR/xvfb.log" 2>&1 &

sleep 2

echo "[2/5] Starting Fluxbox..."
fluxbox >"$LOG_DIR/fluxbox.log" 2>&1 &

echo "[3/5] Starting VNC and noVNC on port 8080..."
x11vnc \
    -display :1 \
    -forever \
    -shared \
    -nopw \
    -listen 0.0.0.0 \
    -rfbport 5900 \
    >"$LOG_DIR/x11vnc.log" 2>&1 &

websockify \
    --web=/usr/share/novnc \
    0.0.0.0:8080 \
    127.0.0.1:5900 \
    >"$LOG_DIR/novnc.log" 2>&1 &

# =========================================================
# 2. WINE INITIALIZATION & ENVIRONMENT SETUP
# =========================================================

(
    set +e

    echo "[4/5] Initializing Wine prefix..."

    if [ ! -f "$WINEPREFIX/system.reg" ]; then
        wineboot -i >"$LOG_DIR/wineboot.log" 2>&1
        for i in $(seq 1 90); do
            [ -f "$WINEPREFIX/system.reg" ] && break
            sleep 1
        done
    else
        wineboot -u >"$LOG_DIR/wineboot.log" 2>&1
    fi

    # Neutralize debugger detection registries
    wine reg delete "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug" /f || true
    wine reg add "HKCU\\Software\\Wine\\WineDbg" /v "ShowCrashDialog" /t REG_DWORD /d 0 /f || true

    MT5_DIR="$WINEPREFIX/drive_c/Program Files/MetaTrader 5"
    MT5_EXE="$MT5_DIR/terminal64.exe"

    if [ ! -f "$MT5_EXE" ]; then
        echo "Attempting package retrieval..."
        mkdir -p "$MT5_DIR" /tmp/mt5_dl
        cd /tmp/mt5_dl
        
        wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O mt5setup.exe || true
        cabextract -d /tmp/extracted mt5setup.exe || true
        
        if [ -d "/tmp/extracted" ]; then
            cp -rf /tmp/extracted/* "$MT5_DIR/" || true
        fi
    fi

    # Broad search across drive_c for terminal executable
    if [ ! -f "$MT5_EXE" ]; then
        FOUND_EXE=$(find "$WINEPREFIX/drive_c" -type f \( -iname "terminal64.exe" -o -iname "terminal.exe" \) -print -quit 2>/dev/null || true)
        if [ -n "$FOUND_EXE" ]; then
            MT5_EXE="$FOUND_EXE"
        fi
    fi

    if [ -n "$MT5_EXE" ] && [ -f "$MT5_EXE" ]; then
        echo "Launching MetaTrader 5 terminal: $MT5_EXE"
        cd "$(dirname "$MT5_EXE")"
        wine "$MT5_EXE" /portable >"$LOG_DIR/terminal.log" 2>&1 &
        sleep 10
    else
        echo "NOTICE: MetaTrader binary not found automatically."
        echo "You can open an xterm terminal via noVNC to install or drop files manually."
    fi

    # =========================================================
# 3. START PYTHON BRIDGE
# =========================================================

    echo "[5/5] Starting Python mt5linux bridge on port 8001..."
    python3 -m mt5linux \
        --host 0.0.0.0 \
        --port 8001 \
        >"$LOG_DIR/bridge.log" 2>&1 &

    echo "Background tasks initialized."

) >"$LOG_DIR/initialization.log" 2>&1 &

# =========================================================
# 4. KEEP CONTAINER ALIVE
# =========================================================

echo "Container startup sequence completed successfully."

while true; do
    if ! pgrep -f 'websockify.*8080' >/dev/null 2>&1; then
        echo "WARNING: noVNC web service stopped."
    fi
    sleep 30
done
EOF

RUN chmod +x /entrypoint.sh \
    && dos2unix /entrypoint.sh

EXPOSE 8080 8001 5900

CMD ["/bin/bash", "/entrypoint.sh"]
