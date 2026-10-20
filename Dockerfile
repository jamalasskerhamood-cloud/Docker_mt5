FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    WINEPREFIX=/root/.wine \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    PYTHONUNBUFFERED=1

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
        unzip \
        dos2unix \
        xvfb \
        x11-utils \
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
echo "Railway MT5 Desktop"
echo "Date: $(date)"
echo "Wine: $(wine --version 2>/dev/null || echo unavailable)"
echo "=================================================="

# =========================================================
# 1. START THE GRAPHICAL DISPLAY
# =========================================================

echo "[1/6] Starting Xvfb..."

Xvfb :1 \
    -screen 0 1280x1024x24 \
    -ac \
    -nolisten tcp \
    >"$LOG_DIR/xvfb.log" 2>&1 &

XVFB_PID=$!

for i in $(seq 1 30); do
    if xdpyinfo -display :1 >/dev/null 2>&1; then
        echo "Xvfb is ready."
        break
    fi

    if ! kill -0 "$XVFB_PID" 2>/dev/null; then
        echo "ERROR: Xvfb exited."
        cat "$LOG_DIR/xvfb.log" || true
        exit 1
    fi

    sleep 1
done

if ! xdpyinfo -display :1 >/dev/null 2>&1; then
    echo "ERROR: Display :1 is unavailable."
    exit 1
fi

# =========================================================
# 2. START FLUXBOX
# =========================================================

echo "[2/6] Starting Fluxbox..."

fluxbox >"$LOG_DIR/fluxbox.log" 2>&1 &

# =========================================================
# 3. START VNC
# =========================================================

echo "[3/6] Starting VNC..."

x11vnc \
    -display :1 \
    -forever \
    -shared \
    -nopw \
    -listen 0.0.0.0 \
    -rfbport 5900 \
    >"$LOG_DIR/x11vnc.log" 2>&1 &

VNC_PID=$!

# =========================================================
# 4. START WEB ACCESS
# =========================================================

echo "[4/6] Starting noVNC on port 8080..."

websockify \
    --web=/usr/share/novnc \
    0.0.0.0:8080 \
    127.0.0.1:5900 \
    >"$LOG_DIR/novnc.log" 2>&1 &

NOVNC_PID=$!

# Confirm that the web service is accepting connections.
PORT_READY=0

for i in $(seq 1 20); do
    if python3 -c \
        "import socket; s=socket.create_connection(('127.0.0.1',8080),1); s.close()" \
        >/dev/null 2>&1; then
        PORT_READY=1
        break
    fi

    if ! kill -0 "$NOVNC_PID" 2>/dev/null; then
        echo "ERROR: websockify exited."
        cat "$LOG_DIR/novnc.log" || true
        break
    fi

    sleep 1
done

if [ "$PORT_READY" -eq 1 ]; then
    echo "noVNC is responding on port 8080."
else
    echo "WARNING: Port 8080 did not respond during startup."
fi

# =========================================================
# 5. INITIALIZE WINE AND FIND MT5 IN BACKGROUND
# =========================================================

(
    set +e

    echo "[5/6] Initializing Wine..."

    if [ ! -f "$WINEPREFIX/system.reg" ]; then
        wineboot -i >"$LOG_DIR/wineboot.log" 2>&1

        for i in $(seq 1 90); do
            if [ -f "$WINEPREFIX/system.reg" ]; then
                break
            fi

            sleep 1
        done
    else
        wineboot -u >"$LOG_DIR/wineboot.log" 2>&1
    fi

    if [ ! -f "$WINEPREFIX/system.reg" ]; then
        echo "ERROR: Wine prefix initialization failed."
        exit 1
    fi

    echo "Wine prefix initialized."

    # -----------------------------------------------------
    # Find an existing installation.
    # -----------------------------------------------------

    MT5_EXE=""

    CANDIDATES=(
        "/root/mt5/terminal64.exe"
        "$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
        "$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal.exe"
        "$WINEPREFIX/drive_c/Program Files (x86)/MetaTrader 5/terminal64.exe"
    )

    for candidate in "${CANDIDATES[@]}"; do
        if [ -f "$candidate" ]; then
            MT5_EXE="$candidate"
            break
        fi
    done

    if [ -z "$MT5_EXE" ]; then
        MT5_EXE=$(find "$WINEPREFIX/drive_c" \
            -type f \
            \( -iname "terminal64.exe" -o -iname "terminal.exe" \) \
            -print -quit 2>/dev/null)
    fi

    # -----------------------------------------------------
    # Launch MT5 if installed.
    # -----------------------------------------------------

    if [ -n "$MT5_EXE" ] && [ -f "$MT5_EXE" ]; then
        echo "Found MT5: $MT5_EXE"

        MT5_DIR=$(dirname "$MT5_EXE")
        cd "$MT5_DIR"

        wine "$MT5_EXE" /portable \
            >"$LOG_DIR/terminal.log" 2>&1 &

        echo "MT5 launch requested."
    else
        echo "WARNING: MT5 terminal64.exe was not found."
        echo "The installer has not been downloaded or extracted."
        echo "Install MT5 through the desktop or provide an existing"
        echo "complete terminal installation."
    fi

    # -----------------------------------------------------
    # Start the Python bridge.
    # -----------------------------------------------------

    echo "Starting Python bridge on port 8001..."

    python3 -m mt5linux \
        --host 0.0.0.0 \
        --port 8001 \
        >"$LOG_DIR/bridge.log" 2>&1 &

    echo "Bridge launch requested."

) >"$LOG_DIR/initialization.log" 2>&1 &

INIT_PID=$!

# =========================================================
# 6. KEEP THE CONTAINER ALIVE
# =========================================================

echo "[6/6] Startup sequence launched."
echo "noVNC: 8080"
echo "VNC: 5900"
echo "Python bridge: 8001"

while true; do
    if ! kill -0 "$XVFB_PID" 2>/dev/null; then
        echo "ERROR: Xvfb stopped."
    fi

    if ! kill -0 "$NOVNC_PID" 2>/dev/null; then
        echo "ERROR: noVNC stopped."
    fi

    sleep 30
done
EOF

RUN chmod +x /entrypoint.sh \
    && dos2unix /entrypoint.sh

EXPOSE 8080 8001 5900

CMD ["/bin/bash", "/entrypoint.sh"]
