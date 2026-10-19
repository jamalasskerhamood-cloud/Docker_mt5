FROM python:3.11-slim-bookworm

USER root
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# Install Wine and necessary utilities
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# INSTALLATION & ENTRYPOINT
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

# Clean up stale locks/processes
rm -rf /tmp/.X*
rm -rf /root/.wine/.lock

Xvfb :1 -screen 0 1280x1024x24 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &

wineboot --init
sleep 5

# Download and extract MetaTrader 5 directly if not already present
MT5_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5"
MT5_EXE="$MT5_DIR/terminal64.exe"

if [ ! -f "$MT5_EXE" ]; then
    echo "Downloading MetaTrader 5..."
    mkdir -p /tmp/mt5 && cd /tmp/mt5
    wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt55setup.exe -O mt5setup.exe
    # Extract using unzip/cabextract if it's an archive, or use silent installer flags
    wine mt5setup.exe /auto || true
    sleep 30
fi

# Fallback: if standard path differs, find terminal64.exe dynamically
if [ ! -f "$MT5_EXE" ]; then
    FOUND_EXE=$(find /root/.wine -name "terminal64.exe" | head -n 1)
    if [ ! -z "$FOUND_EXE" ]; then
        MT5_EXE="$FOUND_EXE"
    fi
fi

echo "Starting MetaTrader 5..."
wine "$MT5_EXE" &
sleep 20

# Start mt5linux bridge server
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
