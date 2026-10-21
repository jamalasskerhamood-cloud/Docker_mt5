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
# 3. DIRECTORY STRUCTURE & BROKER SETUP DOWNLOAD
# =========================================================

RUN mkdir -p \
    /root/.wine \
    /var/log/mt5 \
    /tmp/.X11-unix \
    && wineboot -i

# Download fbs5setup.exe from your GitHub repository during build
RUN cd /tmp \
    && wget -q "https://raw.githubusercontent.com/jamalasskerhamood-cloud/Docker_mt5/main/fbs5setup.exe" -O fbs5setup.exe \
    && cabextract fbs5setup.exe -d /tmp/extracted \
    && mkdir -p "/root/.wine/drive_c/Program Files/MetaTrader 5" \
    && cp -rf /tmp/extracted/* "/root/.wine/drive_c/Program Files/MetaTrader 5/" || true

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
echo "Container Autonomous Boot"
echo "Date: $(date)"
echo "Wine Version: $(wine --version)"
echo "=================================================="

# Start display and VNC web bridge in the background
pkill -f 'Xvfb :1' 2>/dev/null || true
pkill -x x11vnc 2>/dev/null || true
pkill -x websockify 2>/dev/null || true
pkill -x fluxbox 2>/dev/null || true

Xvfb :1 -screen 0 1280x1024x24 -ac -nolisten tcp >"$LOG_DIR/xvfb.log" 2>&1 &
sleep 2

fluxbox >"$LOG_DIR/fluxbox.log" 2>&1 &
sleep 1

x11vnc -display :1 -forever -shared -nopw -listen 0.0.0.0 -rfbport 5900 >"$LOG_DIR/x11vnc.log" 2>&1 &
websockify --web=/usr/share/novnc 0.0.0.0:8080 127.0.0.1:5900 >"$LOG_DIR/novnc.log" 2>&1 &

# Execute whatever custom command or script is passed to the container
echo "Executing user command: $@"
exec "$@"
EOF

RUN chmod +x /entrypoint.sh \
    && dos2unix /entrypoint.sh

EXPOSE 8080 8001 5900

# Use ENTRYPOINT so arguments passed via CLI or deployment configs are appended to the entrypoint script
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]

# Default command if none is specified
CMD ["python3", "-m", "mt5linux", "--host", "0.0.0.0", "--port", "8001"]
