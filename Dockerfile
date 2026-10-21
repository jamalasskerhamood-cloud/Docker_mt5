FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all
ENV PYTHONUNBUFFERED=1

# =========================================================
# 1. SYSTEM DEPENDENCIES & STABLE WINE
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
        x11-xserver-utils \
        wine \
        wine64 \
        wine32:i386 \
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
        xauth \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# =========================================================
# 2. PYTHON MT5 BRIDGE
# =========================================================

RUN pip install --no-cache-dir mt5linux rpyc

# =========================================================
# 3. PRE-BUILD WINE ENVIRONMENT & MT5 SETUP
# =========================================================

RUN mkdir -p /root/.wine /var/log/mt5 /tmp/.X11-unix \
    && wineboot -i \
    && mkdir -p "/root/.wine/drive_c/Program Files/MetaTrader 5"

# Download and bake official setup during build to guarantee availability
RUN cd /tmp \
    && wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O mt5setup.exe || true \
    && cabextract mt5setup.exe -d /tmp/extracted || true \
    && if [ -d "/tmp/extracted" ]; then cp -rf /tmp/extracted/* "/root/.wine/drive_c/Program Files/MetaTrader 5/" || true; fi

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

LOG_DIR=/var/log/mt5
mkdir -p "$LOG_DIR" "$WINEPREFIX" /tmp/.X11-unix

exec > >(tee -a "$LOG_DIR/startup.log") 2>&1

echo "=================================================="
echo "Railway Fully Autonomous Pre-built MT5 Boot"
echo "Date: $(date)"
echo "Wine Version: $(wine --version)"
echo "=================================================="

# =========================================================
# 1. START DISPLAY & WEB PORT 8080 IMMEDIATELY (Healthcheck)
# =========================================================

echo "[1/3] Starting Xvfb, Fluxbox, and Web Bridge..."
pkill -f 'Xvfb :1' 2>/dev/null || true
pkill -x x11vnc 2>/dev/null || true
pkill -x websockify 2>/dev/null || true
pkill -x fluxbox 2>/dev/null || true

Xvfb :1 -screen 0 1280x1024x24 -ac -nolisten tcp \
    >"$LOG_DIR/xvfb.log" 2>&1 &
sleep 2

fluxbox >"$LOG_DIR/fluxbox.log" 2>&1 &
sleep 1

xsetroot -solid "#2d2d2d" -display :1 || true

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

echo "Web interface active on port 8080."

# =========================================================
# 2. LAUNCH MT5 AND PYTHON BRIDGE
# =========================================================

(
    set +e
    wine reg add "HKCU\\Software\\Wine\\WineDbg" /v "ShowCrashDialog" /t REG_DWORD /d 0 /f || true

    MT5_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5"
    MT5_EXE="$MT5_DIR/terminal64.exe"

    if [ -f "$MT5_EXE" ]; then
        echo "Launching MetaTrader 5 in portable mode..."
        cd "$(dirname "$MT5_EXE")"
        wine "$MT5_EXE" /portable >"$LOG_DIR/terminal.log" 2>&1 &
        sleep 5
    else
        echo "WARNING: terminal64.exe not found in pre-built path."
    fi

    echo "[3/3] Starting Python mt5linux bridge on port 8001..."
    python3 -m mt5linux \
        --host 0.0.0.0 \
        --port 8001 \
        >"$LOG_DIR/bridge.log" 2>&1 &

    echo "Autonomous startup sequence completed."

) >"$LOG_DIR/initialization.log" 2>&1 &

# =========================================================
# 3. KEEP CONTAINER ALIVE
# =========================================================

echo "Container is running and healthy."

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
