FROM python:3.11-slim-bookworm

USER root
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# Add i386 architecture and install baseline dependencies
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wget curl procps cabextract unzip dos2unix xdotool gpg software-properties-common \
    xvfb fluxbox x11vnc novnc websockify \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Add WineHQ repository and install a stable Wine 10 version package to avoid the debugger trap
RUN mkdir -p /etc/apt/keyrings \
    && wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
    && wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
    && apt-get update \
    && apt-get install -y --install-recommends wine-stable-amd64=10.0* wine-stable-i386=10.0* wine-stable=10.0* || apt-get install -y winehq-stable || true

RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# INSTALLATION & ENTRYPOINT
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

# Clean up stale locks and processes
rm -rf /tmp/.X*
rm -rf /root/.wine/.lock
pkill -9 wineserver || true
pkill -9 terminal64 || true

Xvfb :1 -screen 0 1280x1024x24 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &

wineboot --init
sleep 5

MT5_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5"
MT5_EXE="$MT5_DIR/terminal64.exe"

if [ ! -f "$MT5_EXE" ]; then
    echo "Downloading MetaTrader 5 setup..."
    wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe
    
    # Disable wine crash dialogs
    wine reg add "HKEY_CURRENT_USER\Software\Wine\WineDbg" /v "ShowCrashDialog" /t REG_DWORD /d 0 /f || true
    
    wine /root/mt5setup.exe /auto || true
    sleep 45
fi

# Fallback path search if standard path differs
if [ ! -f "$MT5_EXE" ]; then
    FOUND_EXE=$(find /root/.wine -name "terminal64.exe" | head -n 1)
    [ ! -z "$FOUND_EXE" ] && MT5_EXE="$FOUND_EXE"
fi

echo "Starting MetaTrader 5 terminal..."
wine "$MT5_EXE" &
sleep 25

# Start mt5linux bridge server
echo "Starting mt5linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
