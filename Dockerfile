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
# 2. PYTHON BRIDGE
# =========================================================

RUN pip install --no-cache-dir mt5linux rpyc

# =========================================================
# 3. DIRECTORIES
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

LOG=/var/log/mt5/startup.log

mkdir -p /var/log/mt5 /root/.wine

exec > >(tee -a "$LOG") 2>&1

echo "=================================================="
echo "Railway MT5 Instant Web Bind Startup"
echo "Date: $(date)"
echo "=================================================="

# ---------------------------------------------------------
# 1. START WEB & VNC SERVICES IMMEDIATELY (Passes Healthcheck)
# ---------------------------------------------------------

echo "[1/3] Starting display servers and web port 8080..."

pkill -f 'Xvfb :1' 2>/dev/null || true
pkill -x x11vnc 2>/dev/null || true
pkill -x websockify 2>/dev/null || true
pkill -x fluxbox 2>/dev/null || true

Xvfb :1 -screen 0 1280x1024x24 -ac -nolisten tcp \
    >/var/log/mt5/xvfb.log 2>&1 &
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

# Bind port 8080 instantly so Railway health check succeeds right away
websockify \
    --web=/usr/share/novnc \
    0.0.0.0:8080 \
    127.0.0.1:5900 \
    >/var/log/mt5/novnc.log 2>&1 &

echo "Web bridge active on port 8080."

# ---------------------------------------------------------
# 2. RUN WINE & MT5 INITIALIZATION IN THE BACKGROUND
# ---------------------------------------------------------

(
    set +e

    echo "[2/3] Initializing Wine environment..."

    if [ ! -f "$WINEPREFIX/system.reg" ]; then
        echo "Initializing a fresh Wine prefix..."
        wineboot -i

        for i in $(seq 1 90); do
            [ -f "$WINEPREFIX/system.reg" ] && break
            sleep 1
        done
    else
        echo "Existing Wine prefix detected."
        wineboot -u
    fi

    if [ ! -f "$WINEPREFIX/system.reg" ]; then
        echo "ERROR: Wine prefix initialization failed."
        exit 1
    fi

    sleep 3

    echo "[3/3] Checking MetaTrader 5 terminal..."
    MT5_EXE=""

    for candidate in \
        "/root/mt5/terminal64.exe" \
        "$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe" \
        "$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal.exe" \
        "$WINEPREFIX/drive_c/Program Files (x86)/MetaTrader 5/terminal64.exe"
    do
        if [ -f "$candidate" ]; then
            MT5_EXE="$candidate"
            break
        fi
    done

    if [ -z "$MT5_EXE" ]; then
        MT5_EXE=$(find "$WINEPREFIX/drive_c" \
            -type f \
            \( -iname "terminal64.exe" -o -iname "terminal.exe" \) \
            -print -quit 2>/dev/null || true)
    fi

    if [ -n "$MT5_EXE" ] && [ -f "$MT5_EXE" ]; then
        echo "Found MT5 terminal: $MT5_EXE"
        MT5_DIR=$(dirname "$MT5_EXE")
        cd "$MT5_DIR"

        echo "Launching MT5 in portable mode..."
        wine "$MT5_EXE" /portable >/var/log/mt5/terminal.log 2>&1 &
        MT5_PID=$!
        sleep 10

        if kill -0 "$MT5_PID" 2>/dev/null; then
            echo "MT5 launch process is running."
        else
            echo "WARNING: MT5 process exited. Check /var/log/mt5/terminal.log"
        fi
    else
        echo "WARNING: No installed MT5 terminal found. Use noVNC to install it."
    fi

    echo "Starting the MT5 Python bridge..."
    python3 -m mt5linux \
        --host 0.0.0.0 \
        --port 8001 \
        >/var/log/mt5/bridge.log 2>&1 &

    echo "Background tasks initialized."

) >/var/log/mt5/initialization.log 2>&1 &

# ---------------------------------------------------------
# 3. KEEP CONTAINER ALIVE FOR HEALTH CHECKS
# ---------------------------------------------------------

echo "Container startup sequence completed successfully."
echo "noVNC port: 8080"
echo "Python bridge port: 8001"

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
