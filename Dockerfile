FROM python:3.11-slim-bookworm

USER root
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir mt5linux rpyc
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# Copy exact files from the latest screenshots plus smart.ex5
COPY GODZILLA.ex5 /root/
COPY GOLDPOWER.ex5 /root/
COPY Nasdaq.ex5 /root/
COPY Sunv1.5_fix.ex5 /root/
COPY FXCHOPPERSEA.ex5 /root/
COPY HANDSOFGODV3.0EA.ex5 /root/
COPY MA_BreakOutExpertAdvisor.ex5 /root/
COPY Thomas_mt5.ex5 /root/
COPY BlackWolfEA_fix.ex5 /root/
COPY STEPINDEXTRENDSHOTGUN.ex5 /root/
COPY SNIPERGOLDX_by.ex5 /root/
COPY ChefsGold.ex5 /root/
COPY TakePropips.ex5 /root/
COPY Multi_Trades.ex5 /root/
COPY Amberwaves.ex5 /root/
COPY AIBREAKOUTEA.ex5 /root/
COPY HedgeZoneEURUSD_fix.ex5 /root/
COPY Pumbling_fix.ex5 /root/
COPY AllinoneScalper2.0.ex5 /root/
COPY Covid24BoomAndCrashPro.ex5 /root/
COPY smart.ex5 /root/

# ============================================
# 3. INSTALLATION & ENTRYPOINT
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
rm -rf /tmp/.X*
Xvfb :1 -screen 0 1280x1024x24 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &
wineboot --init
sleep 5
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
[ ! -f "$MT5_EXE" ] && wine /root/mt5setup.exe /auto && sleep 90
wine "$MT5_EXE" &
sleep 30

DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
[ -z "$DATA_DIR" ] && DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
mkdir -p "$DATA_DIR/Experts"

cp /root/GODZILLA.ex5 "$DATA_DIR/Experts/"
cp /root/GOLDPOWER.ex5 "$DATA_DIR/Experts/"
cp /root/Nasdaq.ex5 "$DATA_DIR/Experts/"
cp /root/Sunv1.5_fix.ex5 "$DATA_DIR/Experts/"
cp /root/FXCHOPPERSEA.ex5 "$DATA_DIR/Experts/"
cp /root/HANDSOFGODV3.0EA.ex5 "$DATA_DIR/Experts/"
cp /root/MA_BreakOutExpertAdvisor.ex5 "$DATA_DIR/Experts/"
cp /root/Thomas_mt5.ex5 "$DATA_DIR/Experts/"
cp /root/BlackWolfEA_fix.ex5 "$DATA_DIR/Experts/"
cp /root/STEPINDEXTRENDSHOTGUN.ex5 "$DATA_DIR/Experts/"
cp /root/SNIPERGOLDX_by.ex5 "$DATA_DIR/Experts/"
cp /root/ChefsGold.ex5 "$DATA_DIR/Experts/"
cp /root/TakePropips.ex5 "$DATA_DIR/Experts/"
cp /root/Multi_Trades.ex5 "$DATA_DIR/Experts/"
cp /root/Amberwaves.ex5 "$DATA_DIR/Experts/"
cp /root/AIBREAKOUTEA.ex5 "$DATA_DIR/Experts/"
cp /root/HedgeZoneEURUSD_fix.ex5 "$DATA_DIR/Experts/"
cp /root/Pumbling_fix.ex5 "$DATA_DIR/Experts/"
cp /root/AllinoneScalper2.0.ex5 "$DATA_DIR/Experts/"
cp /root/Covid24BoomAndCrashPro.ex5 "$DATA_DIR/Experts/"
cp /root/smart.ex5 "$DATA_DIR/Experts/"

python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
