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
# 3. DIRECTORY STRUCTURE
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

LOG_DIR=/var/log/mt5
mkdir -p "$LOG_DIR" "$WINEPREFIX" /tmp/.X11-unix

exec > >(tee -a "$LOG_DIR/startup.log") 2>&1

echo "=================================================="
echo "Railway MT5 Direct Portable Archive Boot"
echo "Date: $(date)"
echo "Wine Version: $(wine --version)"
echo "=================================================="

# =========================================================
# 1. START DISPLAY & WEB PORT 8080 IMMEDIATELY (Healthcheck)
# =========================================================

echo "[1/4] Starting Xvfb and Fluxbox..."
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

echo "[2/4] Starting VNC on port 5900 & noVNC on port 8080..."
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
# 2. AUTOMATED DIRECT PORTABLE DEPLOYMENT
# =========================================================

xterm -fa 'Monospace' -fs 10 -bg '#1e1e1e' -fg '#00ff00' -title "MT5 Automated Setup" -e "
echo 'Initializing Wine Environment...'
wineboot -i
wine reg add 'HKCU\\Software\\Wine\\WineDbg' /v 'ShowCrashDialog' /t REG_DWORD /d 0 /f || true

MT5_DIR='/root/.wine/drive_c/Program Files/MetaTrader 5'
mkdir -p \"\$MT5_DIR\"

echo 'Checking terminal binary...'
if [ ! -f \"\$MT5_DIR/terminal64.exe\" ]; then
    echo 'Downloading direct portable MetaTrader package...'
    cd /tmp
    # Alternative direct mirror containing packed terminal binaries
    wget -q https://github.com/shahed269/mt5-docker/raw/main/mt5.zip -O mt5.zip || true
    if [ -f \"mt5.zip\" ]; then
        unzip -qo mt5.zip -d /tmp/mt5_unpacked || true
        cp -rf /tmp/mt5_unpacked/* \"\$MT5_DIR/\" || true
    fi
fi

MT5_EXE=\$(find \"/root/.wine/drive_c\" -type f -name \"terminal64.exe\" -print -quit)

if [ -n \"\$MT5_EXE\" ]; then
    echo 'Launching MetaTrader 5 in portable mode...'
    cd \"\$(dirname \"\$MT5_EXE\")\"
    wine \"\$MT5_EXE\" /portable
else
    echo 'WARNING: Portable package not found. You can drop files manually or use shell.'
    bash
fi
" &

# =========================================================
# 3. BACKGROUND PYTHON BRIDGE
# =========================================================

(
    set +e
    for i in $(seq 1 90); do
        [ -f "$WINEPREFIX/system.reg" ] && break
        sleep 1
    done

    echo "[4/4] Starting Python mt5linux bridge on port 8001..."
    python3 -m mt5linux \
        --host 0.0.0.0 \
        --port 8001 \
        >"$LOG_DIR/bridge.log" 2>&1 &

    echo "Background sequence completed."

) >"$LOG_DIR/initialization.log" 2>&1 &

# =========================================================
# 4. KEEP CONTAINER ALIVE
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
