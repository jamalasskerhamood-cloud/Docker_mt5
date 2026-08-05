
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

# =========================================================
# V16.3 - PROFIT-MAX VELOCITY BOT (ULTRA PROFITABILITY)
# =========================================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                          LiquiditySweep_Flow.mq5  |
//|                                      BTC Liquidity Sweep + Order  |
//|                                                      Flow Trader  |
//+------------------------------------------------------------------+
#property copyright "LiquiditySweep EA"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/AccountInfo.mqh>
#include <Trade/SymbolInfo.mqh>

CTrade obj_Trade;
CAccountInfo obj_Account;
CSymbolInfo obj_Symbol;

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
//--- Risk Management ---
input double   RiskPercent      = 1.0;        // Risk per trade (% of balance)
input double   MaxDailyLossPct  = 10.0;       // Max daily loss (%)
input double   MaxDrawdownPct   = 20.0;       // Max account drawdown (%)
input int      MaxPositions     = 2;          // Maximum concurrent positions

//--- Entry Settings ---
input int      LookbackCandles  = 7;          // Candles to scan for liquidity (5-10)
input int      MinVolumeRatio   = 150;        // Min volume ratio to average (%)
input int      MinBodyPercent   = 60;         // Min body % of candle range
input double   MinATR           = 200.0;      // Minimum ATR in points
input int      CooldownBars     = 3;          // Cooldown after exit (bars)

//--- Exit Settings ---
input double   ATRMultiplierSL  = 1.5;        // ATR multiplier for SL
input double   ATRMultiplierTP  = 2.5;        // ATR multiplier for TP
input double   TrailingStart    = 1.0;        // Start trailing at 1R
input double   TrailingStep     = 0.5;        // Trailing step in R
input int      MaxHoldingBars   = 20;         // Max bars to hold before exit

//--- Broker Settings ---
input int      MagicNumber      = 20260803;   // EA Magic Number
input int      OrderRetryCount  = 3;          // Retry attempts for failed orders
input int      SlippagePts      = 50;         // Slippage tolerance

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
//--- Time & Bar Tracking ---
datetime lastBarTime = 0;
datetime lastTradeTime = 0;
int barsSinceLastTrade = 0;

//--- Balance Tracking ---
double dailyStartBalance = 0;
double peakBalance = 0;
double dailyLoss = 0;
double currentDrawdown = 0;

//--- ATR & Volume ---
double currentATR = 0;
double avgVolume = 0;

//--- Order Tracking ---
int totalTradesToday = 0;
int consecutiveLosses = 0;

//--- Broker Detection ---
int minStopLevel = 0;
double lotStep = 0;
double lotMin = 0;
long fillMode = 0;

//--- Performance Stats ---
int totalTrades = 0;
int winningTrades = 0;
int losingTrades = 0;
double totalProfit = 0;

//--- Top 20 Crypto Symbols ---
string Top20CryptoSymbols[20] = {
   "BTCUSD", "ETHUSD", "USDTUSD", "BNBUSD", "SOLUSD", 
   "USDCUSD", "XRPUSD", "ADAUSD", "AVAXUSD", "DOGEUSD", 
   "DOTUSD", "TRXUSD", "LINKUSD", "MATICUSD", "TONUSD", 
   "SHIBUSD", "LTCUSD", "BCHUSD", "UNIUSD", "ATOMUSD"
};

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   Print("═══════════════════════════════════════════════════════════");
   Print("  LIQUIDITY SWEEP + ORDER FLOW EA v1.00");
   Print("  BTCUSD.vx Microstructure Strategy");
   Print("═══════════════════════════════════════════════════════════");
   
   //--- Initialize Objects ---
   obj_Trade.SetExpertMagicNumber(MagicNumber);
   obj_Trade.SetDeviationInPoints(SlippagePts);
   obj_Trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   //--- Get Symbol Info ---
   obj_Symbol.Name(_Symbol);
   obj_Symbol.Refresh();
   
   //--- Detect Broker Settings ---
   DetectBrokerSettings();
   
   //--- Initialize Balance Tracking ---
   dailyStartBalance = obj_Account.Balance();
   peakBalance = dailyStartBalance;
   
   //--- Print Configuration ---
   PrintConfiguration();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Detect Broker Settings Function                                  |
//+------------------------------------------------------------------+
void DetectBrokerSettings() {
   //--- Minimum Stop Level ---
   minStopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if (minStopLevel == 0) {
      minStopLevel = 1000;  // Safe default for BTC
      Print("[WARNING] Broker stop level not reported, using default: ", minStopLevel);
   }
   
   //--- Lot Step ---
   lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if (lotStep == 0) lotStep = 0.01;
   
   //--- Lot Min ---
   lotMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if (lotMin == 0) lotMin = 0.01;
   
   //--- Fill Mode ---
   fillMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if (fillMode == 0) {
      fillMode = ORDER_FILLING_FOK;
      Print("[WARNING] Fill mode not detected, using FOK");
   }
   
   //--- Set Trade Fill Mode ---
   obj_Trade.SetTypeFilling((ENUM_ORDER_TYPE_FILLING)fillMode);
   
   Print("[INFO] Broker Settings Detected:");
   Print("  Min Stop Level: ", minStopLevel, " points");
   Print("  Lot Step: ", lotStep);
   Print("  Lot Min: ", lotMin);
   Print("  Fill Mode: ", fillMode);
}

//+------------------------------------------------------------------+
//| Print Configuration                                              |
//+------------------------------------------------------------------+
void PrintConfiguration() {
   Print("═══════════════════════════════════════════════════════════");
   Print("  CONFIGURATION");
   Print("───────────────────────────────────────────────────────────");
   Print("  Risk Per Trade   : ", RiskPercent, "%");
   Print("  Max Daily Loss   : ", MaxDailyLossPct, "%");
   Print("  Max Drawdown     : ", MaxDrawdownPct, "%");
   Print("  Max Positions    : ", MaxPositions);
   Print("  Lookback Candles : ", LookbackCandles);
   Print("  Min Volume Ratio : ", MinVolumeRatio, "%");
   Print("  Min Body %       : ", MinBodyPercent, "%");
   Print("  Min ATR          : ", MinATR);
   Print("  ATR Multiplier SL: ", ATRMultiplierSL);
   Print("  ATR Multiplier TP: ", ATRMultiplierTP);
   Print("  Cooldown Bars    : ", CooldownBars);
   Print("  Max Holding Bars : ", MaxHoldingBars);
   Print("═══════════════════════════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   PrintPerformance();
   Print("═══════════════════════════════════════════════════════════");
   Print("  EA Stopped - Reason: ", reason);
   Print("═══════════════════════════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   //--- Update Symbol Info ---
   obj_Symbol.Refresh();
   
   //--- Check for New Bar ---
   if (!IsNewBar()) return;
   
   //--- Update Tracking ---
   UpdateTracking();
   
   //--- Risk Checks ---
   if (!PassesRiskChecks()) return;
   
   //--- Update Indicators ---
   UpdateIndicators();
   
   //--- Check Existing Positions ---
   int posCount = CountPositions();
   
   if (posCount > 0) {
      ManagePositions();
      return;
   }
   
   //--- Cooldown Check ---
   if (barsSinceLastTrade < CooldownBars) {
      return;
   }
   
   //--- Look for Entry ---
   if (posCount < MaxPositions) {
      CheckForEntry();
   }
}

//+------------------------------------------------------------------+
//| Check if New Bar                                                 |
//+------------------------------------------------------------------+
bool IsNewBar() {
   datetime currentBarTime = iTime(_Symbol, PERIOD_M1, 0);
   if (currentBarTime == lastBarTime) return false;
   lastBarTime = currentBarTime;
   barsSinceLastTrade++;
   return true;
}

//+------------------------------------------------------------------+
//| Update Tracking Variables                                        |
//+------------------------------------------------------------------+
void UpdateTracking() {
   double currentBalance = obj_Account.Balance();
   double currentEquity = obj_Account.Equity();
   
   //--- Update Peak Balance ---
   if (currentEquity > peakBalance) {
      peakBalance = currentEquity;
   }
   
   //--- Calculate Daily Loss ---
   dailyLoss = dailyStartBalance - currentEquity;
   
   //--- Calculate Current Drawdown ---
   currentDrawdown = ((peakBalance - currentEquity) / peakBalance) * 100;
}

//+------------------------------------------------------------------+
//| Pass Risk Checks                                                 |
//+------------------------------------------------------------------+
bool PassesRiskChecks() {
   //--- Daily Loss Check ---
   if ((dailyLoss / dailyStartBalance) * 100 >= MaxDailyLossPct) {
      return false;
   }
   
   //--- Drawdown Check ---
   if (currentDrawdown >= MaxDrawdownPct) {
      return false;
   }
   
   //--- Spread Check ---
   int spread = GetSpreadPoints();
   if (spread > 5000) {
      Print("Spread too high: ", spread, " points - skipping");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Update Indicators                                                |
//+------------------------------------------------------------------+
void UpdateIndicators() {
   //--- ATR ---
   currentATR = CalculateATR(14);
   
   //--- Average Volume ---
   avgVolume = CalculateAverageVolume(20);
}

//+------------------------------------------------------------------+
//| Calculate ATR                                                    |
//+------------------------------------------------------------------+
double CalculateATR(int period) {
   double atrArray[];
   int atrHandle = iATR(_Symbol, PERIOD_M1, period);
   CopyBuffer(atrHandle, 0, 0, 1, atrArray);
   IndicatorRelease(atrHandle);
   return (atrArray[0] > 0) ? atrArray[0] : 500;
}

//+------------------------------------------------------------------+
//| Calculate Average Volume                                         |
//+------------------------------------------------------------------+
double CalculateAverageVolume(int period) {
   long volumeArray[];
   double total = 0;
   CopyTickVolume(_Symbol, PERIOD_M1, 1, period, volumeArray);
   for (int i = 0; i < period; i++) {
      total += volumeArray[i];
   }
   return (total / period);
}

//+------------------------------------------------------------------+
//| Count Open Positions                                             |
//+------------------------------------------------------------------+
int CountPositions() {
   int count = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionSelectByTicket(PositionGetTicket(i))) {
         if (PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Get Spread in Points                                             |
//+------------------------------------------------------------------+
int GetSpreadPoints() {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (int)((ask - bid) / _Point);
}

//+------------------------------------------------------------------+
//| Check For Entry                                                  |
//+------------------------------------------------------------------+
void CheckForEntry() {
   //--- Volatility Check ---
   if (currentATR < MinATR) {
      return;
   }
   
   //--- Look for Liquidity Sweep ---
   int direction = DetectLiquiditySweep();
   if (direction == 0) return;
   
   //--- Enter Trade ---
   EnterTrade(direction);
}

//+------------------------------------------------------------------+
//| Detect Liquidity Sweep                                           |
//+------------------------------------------------------------------+
int DetectLiquiditySweep() {
   int direction = 0;
   
   //--- Get High/Low of Last N Candles ---
   double highBuffer[];
   double lowBuffer[];
   double closeBuffer[];
   double openBuffer[];
   long volumeBuffer[];
   
   int lookback = LookbackCandles;
   ArraySetAsSeries(highBuffer, true);
   ArraySetAsSeries(lowBuffer, true);
   ArraySetAsSeries(closeBuffer, true);
   ArraySetAsSeries(openBuffer, true);
   ArraySetAsSeries(volumeBuffer, true);
   
   // Shift lookup +2 to analyze index 1 (completed bar) instead of index 0 (empty new bar)
   CopyHigh(_Symbol, PERIOD_M1, 0, lookback + 2, highBuffer);
   CopyLow(_Symbol, PERIOD_M1, 0, lookback + 2, lowBuffer);
   CopyClose(_Symbol, PERIOD_M1, 0, lookback + 2, closeBuffer);
   CopyOpen(_Symbol, PERIOD_M1, 0, lookback + 2, openBuffer);
   CopyTickVolume(_Symbol, PERIOD_M1, 0, lookback + 2, volumeBuffer);
   
   //--- Find Swing High/Low from older bars (starting from index 2) ---
   double swingHigh = highBuffer[ArrayMaximum(highBuffer, 2, lookback)];
   double swingLow = lowBuffer[ArrayMinimum(lowBuffer, 2, lookback)];
   
   //--- Current Signal Candle (The one that just fully closed - Index 1) ---
   double currentHigh = highBuffer[1];
   double currentLow = lowBuffer[1];
   double currentClose = closeBuffer[1];
   double currentOpen = openBuffer[1];
   long currentVolume = volumeBuffer[1];
   
   //--- Check Liquidity Sweep UP ---
   if (currentHigh > swingHigh) {
      //--- Check Rejection (close back below swing high) ---
      if (currentClose < swingHigh) {
         //--- Check Body % ---
         double bodyPercent = GetBodyPercent(currentOpen, currentClose, currentHigh, currentLow);
         if (bodyPercent >= MinBodyPercent) {
            //--- Check Volume Expansion ---
            if ((double)currentVolume > (avgVolume * MinVolumeRatio / 100)) {
               direction = 1;  // SELL (rejection after liquidity sweep up)
            }
         }
      }
   }
   
   //--- Check Liquidity Sweep DOWN ---
   if (currentLow < swingLow) {
      //--- Check Rejection (close back above swing low) ---
      if (currentClose > swingLow) {
         //--- Check Body % ---
         double bodyPercent = GetBodyPercent(currentOpen, currentClose, currentHigh, currentLow);
         if (bodyPercent >= MinBodyPercent) {
            //--- Check Volume Expansion ---
            if ((double)currentVolume > (avgVolume * MinVolumeRatio / 100)) {
               direction = -1;  // BUY (rejection after liquidity sweep down)
            }
         }
      }
   }
   
   return direction;
}

//+------------------------------------------------------------------+
//| Get Body Percent of Candle                                       |
//+------------------------------------------------------------------+
double GetBodyPercent(double open, double close, double high, double low) {
   double range = high - low;
   if (range == 0) return 0;
   double body = MathAbs(open - close);
   return (body / range) * 100;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize() {
   double balance = obj_Account.Balance();
   double riskAmount = balance * (RiskPercent / 100);
   double stopLossPoints = currentATR * ATRMultiplierSL;
   
   // Fix: Protect against division by zero if broker tick returns invalid values
   double tickValue = obj_Symbol.TickValue();
   if (tickValue <= 0) tickValue = 1.0;
   if (stopLossPoints <= 0) stopLossPoints = 1.0;
   
   double lotSize = riskAmount / (stopLossPoints * tickValue);
   
   //--- Normalize Lot Size ---
   lotSize = MathRound(lotSize / lotStep) * lotStep;
   if (lotSize < lotMin) lotSize = lotMin;
   if (lotSize > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)) {
      lotSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   }
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Enter Trade                                                      |
//+------------------------------------------------------------------+
void EnterTrade(int direction) {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lotSize = CalculateLotSize();
   
   //--- Calculate SL/TP ---
   double slPoints = currentATR * ATRMultiplierSL;
   double tpPoints = currentATR * ATRMultiplierTP;
   
   //--- Ensure Minimum Stop Distance ---
   if (slPoints < minStopLevel) slPoints = minStopLevel;
   if (tpPoints < minStopLevel * 2) tpPoints = minStopLevel * 2;
   
   //--- Place Order with Retry ---
   bool success = false;
   string comment = "";
   
   for (int retry = 0; retry < OrderRetryCount; retry++) {
      if (direction == 1) {  // SELL (rejection after sweep up)
         double sl = bid + slPoints * _Point;
         double tp = bid - tpPoints * _Point;
         comment = "Sweep_Up_Rej";
         success = obj_Trade.Sell(lotSize, _Symbol, bid, sl, tp, comment);
      } else if (direction == -1) {  // BUY (rejection after sweep down)
         double sl = ask - slPoints * _Point;
         double tp = ask + tpPoints * _Point;
         comment = "Sweep_Down_Rej";
         success = obj_Trade.Buy(lotSize, _Symbol, ask, sl, tp, comment);
      }
      
      if (success) break;
      
      //--- Retry with adjusted settings ---
      Sleep(100);
      obj_Symbol.Refresh();
      ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      
      if (retry == OrderRetryCount - 1) {
         Print("[ERROR] Failed to place order after ", OrderRetryCount, " attempts");
         return;
      }
   }
   
   if (success) {
      totalTradesToday++;
      barsSinceLastTrade = 0;
      Print("[✓] ORDER EXECUTED: ", comment, " | Lot: ", lotSize, " | SL: ", slPoints, " | TP: ", tpPoints);
   }
}

//+------------------------------------------------------------------+
//| Manage Positions                                                 |
//+------------------------------------------------------------------+
void ManagePositions() {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if (PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      ulong ticket = PositionGetTicket(i);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) 
                           ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                           : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      //--- Calculate R (Risk Units) ---
      double slPoints = currentATR * ATRMultiplierSL;
      double rUnits = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                     ? (currentPrice - openPrice) / (slPoints * _Point)
                     : (openPrice - currentPrice) / (slPoints * _Point);
      
      //--- Check Time Exit ---
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      datetime currentTime = TimeCurrent();
      int barsHeld = (int)((currentTime - openTime) / PeriodSeconds(PERIOD_M1));
      
      if (barsHeld >= MaxHoldingBars) {
         ClosePosition(ticket, "Time Exit");
         continue;
      }
      
      //--- Trailing Stop ---
      if (rUnits >= TrailingStart) {
         double trailStep = TrailingStep * slPoints * _Point;
         double newSL = 0;
         
         if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
            newSL = currentPrice - trailStep;
            if (newSL > PositionGetDouble(POSITION_SL)) {
               obj_Trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         } else {
            newSL = currentPrice + trailStep;
            if (newSL < PositionGetDouble(POSITION_SL) || PositionGetDouble(POSITION_SL) == 0) {
               obj_Trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close Position                                                   |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason) {
   if (obj_Trade.PositionClose(ticket)) {
      double profit = PositionGetDouble(POSITION_PROFIT);
      if (profit > 0) {
         winningTrades++;
         consecutiveLosses = 0;
      } else {
         losingTrades++;
         consecutiveLosses++;
      }
      totalProfit += profit;
      Print("[X] CLOSED: ", reason, " | Profit: $", profit);
   }
}

//+------------------------------------------------------------------+
//| Print Performance                                                |
//+------------------------------------------------------------------+
void PrintPerformance() {
   double winRate = (totalTrades > 0) ? (double)winningTrades / totalTrades * 100 : 0;
   Print("═══════════════════════════════════════════════════════════");
   Print("  PERFORMANCE SUMMARY");
   Print("───────────────────────────────────────────────────────────");
   Print("  Total Trades    : ", totalTrades);
   Print("  Winning Trades  : ", winningTrades);
   Print("  Losing Trades   : ", losingTrades);
   Print("  Win Rate        : ", winRate, "%");
   Print("  Total Profit    : $", totalProfit);
   Print("  Current Balance : $", obj_Account.Balance());
   Print("  Daily Loss      : $", dailyLoss);
   Print("  Drawdown        : ", currentDrawdown, "%");
   Print("═══════════════════════════════════════════════════════════");
}
//+------------------------------------------------------------------+

EOF

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
cp /root/VALETAX_TICK_BOT_V16.mq5 "$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5" /log:"/root/compile.log"

python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
