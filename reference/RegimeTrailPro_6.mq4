//+------------------------------------------------------------------+
//| RegimeTrailPro.mq4  (v3)                                           |
//| Signal-only indicator. NEVER trades. Everything v2 did, plus the   |
//| four upgrades born from live testing in this project:              |
//|                                                                    |
//|  1. BIG-BAR FILTER: no arrow on a bar larger than BigBarAtrMult x  |
//|     ATR. Stops you buying the top of a 67-point monster candle.    |
//|     The arrow can still fire on a later, calmer bar in the window. |
//|  2. HIGHER-TIMEFRAME ALIGNMENT: arrows only in the direction of    |
//|     the H4 (configurable) EMA trend. Trade with the tide.          |
//|  3. VOLATILITY CEILING: no arrows in panic conditions              |
//|     (short/long ATR ratio above VolRatioMax). Floor AND ceiling.   |
//|  4. PULLBACK LEVEL: each arrow also draws a dotted line at a       |
//|     configurable retrace toward the trail line - an optional       |
//|     better-price limit entry. Alert includes both entries.         |
//|                                                                    |
//|  Plus a LIVE STATUS PANEL (top-left): shows trend, ATR, ER,        |
//|  vol ratio, HTF direction and WHICH filter is currently blocking   |
//|  a signal - so a quiet chart is never a mystery again.             |
//|                                                                    |
//| Every filter is toggleable. Test them ON vs OFF - keep only what   |
//| the data supports. Install in MQL4/Indicators, compile (F7).       |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_color1  clrDodgerBlue
#property indicator_color2  clrTomato
#property indicator_color3  clrDodgerBlue
#property indicator_color4  clrTomato
#property indicator_width1  2
#property indicator_width2  2
#property indicator_width3  3
#property indicator_width4  3

//--- core inputs
input int    AtrPeriod        = 24;     // ATR period for the trail line
input double AtrMult          = 2.5;    // line distance = mult * ATR
input int    ErPeriod         = 24;     // efficiency ratio lookback
input double ErThreshold      = 0.25;   // regime gate: ER above this = trending
input double VolRatioMin      = 0.90;   // vol expansion floor
input int    MaxEntryDelay    = 12;     // bars after a flip in which an arrow may fire
//--- v3 filters (each toggleable = each testable)
input bool   UseBigBarFilter  = true;   // 1) skip arrows on oversized bars
input double BigBarAtrMult    = 2.0;    //    "oversized" = range > this x ATR
input bool   UseHTFFilter     = true;   // 2) arrows must align with higher TF trend
input ENUM_TIMEFRAMES HigherTF = PERIOD_H4; //  higher timeframe
input int    HTFEmaFast       = 50;
input int    HTFEmaSlow       = 200;
input bool   UseVolCeiling    = true;   // 3) no arrows in panic volatility
input double VolRatioMax      = 2.50;   //    ceiling on ATR(short)/ATR(long)
input bool   ShowPullbackLine = true;   // 4) draw limit-entry suggestion
input double PullbackFrac     = 0.50;   //    retrace fraction toward trail line
input int    PullbackValidBars= 8;      //    how long the dotted line extends
input bool   UseExhaustAlert  = true;   // 5) prompt to bank profit when overextended
input double ExhaustAtrMult   = 3.5;    //    "overextended" = price this many ATRs from trail line
//--- session / alerts / risk
input bool   UseSessionFilter = false;  // restrict arrows to certain hours (chart time)
input int    SessionStartGMT  = 0;      // 0-24 = round-the-clock (Bitcoin, gold, all pairs)
input int    SessionEndGMT    = 24;
input double RiskPercent      = 1.0;    // for suggested lot size in alerts
input double RewardRisk       = 2.0;    // suggested target = RR * stop distance
input bool   PopupAlerts      = true;
input bool   PushAlerts       = true;
input bool   ShowPanel        = true;

//--- drawn buffers
double UpLine[], DnLine[], BuyArrow[], SellArrow[];
//--- internal state buffers
double TrendState[], LegAge[], LegDone[], ExhaustDone[];
datetime lastAlertBar = 0;
datetime lastExhaustBar = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   IndicatorBuffers(8);
   SetIndexBuffer(0, UpLine);    SetIndexStyle(0, DRAW_LINE);
   SetIndexBuffer(1, DnLine);    SetIndexStyle(1, DRAW_LINE);
   SetIndexBuffer(2, BuyArrow);  SetIndexStyle(2, DRAW_ARROW); SetIndexArrow(2, 233);
   SetIndexBuffer(3, SellArrow); SetIndexStyle(3, DRAW_ARROW); SetIndexArrow(3, 234);
   SetIndexBuffer(4, TrendState);
   SetIndexBuffer(5, LegAge);
   SetIndexBuffer(6, LegDone);
   SetIndexBuffer(7, ExhaustDone);
   SetIndexEmptyValue(0, EMPTY_VALUE); SetIndexEmptyValue(1, EMPTY_VALUE);
   SetIndexEmptyValue(2, EMPTY_VALUE); SetIndexEmptyValue(3, EMPTY_VALUE);
   SetIndexLabel(0, "Trail Up (stop)"); SetIndexLabel(1, "Trail Down (stop)");
   SetIndexLabel(2, "BUY here");        SetIndexLabel(3, "SELL here");
   IndicatorShortName("RegimeTrailPro v3");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   for(int r = 0; r < 8; r++) ObjectDelete(0, "RTP_row" + IntegerToString(r));
   // pullback lines are named per-bar; sweep them
   for(int i = ObjectsTotal() - 1; i >= 0; i--)
   {
      string n = ObjectName(i);
      if(StringFind(n, "RTP_pb_") == 0 || StringFind(n, "RTP_ex_") == 0)
         ObjectDelete(0, n);
   }
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   int minBars = MathMax(AtrPeriod * 10, ErPeriod + 2) + 2;
   if(rates_total < minBars) return(0);

   ArraySetAsSeries(UpLine, true);   ArraySetAsSeries(DnLine, true);
   ArraySetAsSeries(BuyArrow, true); ArraySetAsSeries(SellArrow, true);
   ArraySetAsSeries(TrendState, true);
   ArraySetAsSeries(LegAge, true);   ArraySetAsSeries(LegDone, true);
   ArraySetAsSeries(ExhaustDone, true);

   int start = rates_total - minBars;
   if(prev_calculated > 0)
      start = MathMin(rates_total - prev_calculated + 1, rates_total - minBars);

   for(int i = start; i >= 0; i--)
   {
      double atr = iATR(NULL, 0, AtrPeriod, i);
      double mid = (High[i] + Low[i]) / 2.0;
      double upBand = mid - AtrMult * atr;
      double dnBand = mid + AtrMult * atr;

      double prevUp = (UpLine[i+1] != EMPTY_VALUE) ? UpLine[i+1] : upBand;
      double prevDn = (DnLine[i+1] != EMPTY_VALUE) ? DnLine[i+1] : dnBand;
      int    prevTr = (int)TrendState[i+1];
      if(prevTr != 1 && prevTr != -1)
         prevTr = (Close[i+1] > (High[i+1]+Low[i+1])/2.0) ? 1 : -1;

      if(prevTr == 1  && upBand < prevUp) upBand = prevUp;   // ratchet
      if(prevTr == -1 && dnBand > prevDn) dnBand = prevDn;

      int tr = prevTr;                                       // flip on close
      if(prevTr == 1  && Close[i] < prevUp) tr = -1;
      if(prevTr == -1 && Close[i] > prevDn) tr = 1;
      TrendState[i] = tr;

      if(tr != prevTr) { LegAge[i] = 0; LegDone[i] = 0; ExhaustDone[i] = 0; }
      else             { LegAge[i] = LegAge[i+1] + 1; LegDone[i] = LegDone[i+1];
                         ExhaustDone[i] = ExhaustDone[i+1]; }

      if(tr == 1)
      {
         UpLine[i] = (tr != prevTr) ? mid - AtrMult * atr : upBand;
         DnLine[i] = EMPTY_VALUE;
      }
      else
      {
         DnLine[i] = (tr != prevTr) ? mid + AtrMult * atr : dnBand;
         UpLine[i] = EMPTY_VALUE;
      }

      //--- arrow decision: all gates, once per leg
      BuyArrow[i] = EMPTY_VALUE; SellArrow[i] = EMPTY_VALUE;
      string blocker = "";
      if(SignalOK(i, tr, atr, blocker))
      {
         if(tr == 1)  BuyArrow[i]  = Low[i]  - atr * 0.4;
         else         SellArrow[i] = High[i] + atr * 0.4;
         LegDone[i] = 1;
         if(ShowPullbackLine) DrawPullback(i, tr);
         if(i == 1) MaybeAlert(tr, i);
      }
      if(i <= 1 && ShowPanel) UpdatePanel(tr, atr, blocker);

      //--- exhaustion prompt: price stretched abnormally far from the line.
      //    Only after the entry phase; re-arms when price relaxes back.
      if(UseExhaustAlert && atr > 0)
      {
         double lineNow = (tr == 1) ? UpLine[i] : DnLine[i];
         // measure from the bar's EXTREME: exhaustion is how far price reached
         double stretch = (tr == 1) ? (High[i] - lineNow) : (lineNow - Low[i]);

         if(ExhaustDone[i] == 1 && stretch < ExhaustAtrMult * atr * 0.6)
            ExhaustDone[i] = 0;                       // re-arm after relaxation

         if(ExhaustDone[i] == 0 && LegAge[i] > MaxEntryDelay &&
            stretch > ExhaustAtrMult * atr)
         {
            ExhaustDone[i] = 1;
            DrawExhaust(i);                           // green star at this close
            if(i == 1 && Time[i] != lastExhaustBar)
            {
               lastExhaustBar = Time[i];
               string emsg = StringConcatenate(
                  "OVEREXTENDED: ", Symbol(), " ", TfName(),
                  " is ", DoubleToString(stretch / atr, 1), "x ATR from the trail line (",
                  DoubleToString(lineNow, Digits), ").",
                  "\nIf long from an earlier arrow: consider banking partial profit",
                  " or tightening your stop manually.",
                  "\nThis is NOT a reversal signal. No new position.");
               Print(emsg);
               if(PopupAlerts) Alert(emsg);
               if(PushAlerts)  SendNotification(emsg);
            }
         }
      }
   }
   return(rates_total);
}

//+------------------------------------------------------------------+
//| all entry gates in one place; reports the first blocker           |
bool SignalOK(int i, int tr, double atr, string &blocker)
{
   if(LegDone[i] != 0)                 { blocker = "leg already signalled"; return(false); }
   if(LegAge[i] > MaxEntryDelay)       { blocker = "entry window closed";   return(false); }
   if(!SessionOK(Time[i]))             { blocker = "outside session";       return(false); }

   // regime: efficiency
   double net = MathAbs(Close[i] - Close[i + ErPeriod]);
   double path = 0;
   for(int k = 0; k < ErPeriod; k++)
      path += MathAbs(Close[i + k] - Close[i + k + 1]);
   double er = (path > 0) ? net / path : 0;
   if(er <= ErThreshold)               { blocker = "chop (ER " + DoubleToString(er,2) + ")"; return(false); }

   // regime: volatility floor and ceiling
   double atrL = iATR(NULL, 0, AtrPeriod * 10, i);
   double vr = (atrL > 0) ? atr / atrL : 0;
   if(vr <= VolRatioMin)               { blocker = "vol too low (" + DoubleToString(vr,2) + ")"; return(false); }
   if(UseVolCeiling && vr >= VolRatioMax) { blocker = "PANIC vol (" + DoubleToString(vr,2) + ")"; return(false); }

   // big-bar filter
   if(UseBigBarFilter && (High[i] - Low[i]) > BigBarAtrMult * atr)
                                       { blocker = "oversized signal bar"; return(false); }

   // higher-timeframe alignment
   if(UseHTFFilter)
   {
      double f = iMA(NULL, HigherTF, HTFEmaFast, 0, MODE_EMA, PRICE_CLOSE, 1);
      double s = iMA(NULL, HigherTF, HTFEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 1);
      if(f > 0 && s > 0)               // if HTF history missing, filter passes
      {
         int htfDir = (f > s) ? 1 : -1;
         if(htfDir != tr)              { blocker = "against higher TF"; return(false); }
      }
   }
   blocker = "";
   return(true);
}

//+------------------------------------------------------------------+
bool SessionOK(datetime t)
{
   if(!UseSessionFilter) return(true);
   int h = TimeHour(t);
   return(h >= SessionStartGMT && h < SessionEndGMT);
}

//+------------------------------------------------------------------+
void DrawPullback(int i, int dir)
{
   double line  = (dir > 0) ? UpLine[i] : DnLine[i];
   double entry = Close[i];
   double pb = entry - PullbackFrac * (entry - line);   // works for both directions
   string name = "RTP_pb_" + TimeToString(Time[i], TIME_DATE|TIME_MINUTES);
   datetime tEnd = Time[i] + PullbackValidBars * PeriodSeconds();
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, Time[i], pb, tEnd, pb);
   ObjectSetInteger(0, name, OBJPROP_COLOR, dir > 0 ? clrDodgerBlue : clrTomato);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_RAY, false);
}

//+------------------------------------------------------------------+
//| green STAR at the exact close that triggered the exhaustion       |
//| prompt - marks the "bank profit / tighten stop" point on chart    |
void DrawExhaust(int i)
{
   string name = "RTP_ex_" + TimeToString(Time[i], TIME_DATE|TIME_MINUTES);
   if(ObjectFind(0, name) >= 0) return;
   int tr = (int)TrendState[i];
   double px = (tr == 1) ? High[i] : Low[i];
   ObjectCreate(0, name, OBJ_ARROW, 0, Time[i], px);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 171);   // wingdings star
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrLimeGreen);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetString(0, name, OBJPROP_TEXT, "exhaustion: bank profit / tighten stop");
}

//+------------------------------------------------------------------+
void MaybeAlert(int dir, int i)
{
   if(Time[i] == lastAlertBar) return;
   lastAlertBar = Time[i];

   double line   = (dir > 0) ? UpLine[i] : DnLine[i];
   double entry  = Close[i];
   double pb     = entry - PullbackFrac * (entry - line);
   double slDist = MathAbs(entry - line);
   double tp     = (dir > 0) ? entry + slDist * RewardRisk
                             : entry - slDist * RewardRisk;
   double lots   = LotsForRisk(slDist);

   string msg = StringConcatenate(
      (dir > 0 ? "BUY" : "SELL"), " signal  ", Symbol(), " ", TfName(),
      "\nMarket entry ~ ", DoubleToString(entry, Digits),
      "\nOr limit at:     ", DoubleToString(pb, Digits), " (pullback, valid ~",
                            IntegerToString(PullbackValidBars), " bars)",
      "\nStop:    ", DoubleToString(line, Digits), " (the trail line)",
      "\nTarget: ", DoubleToString(tp, Digits),
      "\nSize:    ", DoubleToString(lots, 2), " lots (", DoubleToString(RiskPercent, 1), "% risk at market entry)",
      "\nYour call - nothing was placed.");

   Print(msg);
   if(PopupAlerts) Alert(msg);
   if(PushAlerts)  SendNotification(msg);
}

//+------------------------------------------------------------------+
double LotsForRisk(double slDist)
{
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
   if(tickValue <= 0 || tickSize <= 0 || slDist <= 0) return(0);
   double riskMoney  = AccountBalance() * RiskPercent / 100.0;
   double lossPerLot = slDist / tickSize * tickValue;
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   double lots = MathFloor((riskMoney / lossPerLot) / step) * step;
   return(NormalizeDouble(MathMax(lots, 0), 2));
}

//+------------------------------------------------------------------+
void UpdatePanel(int tr, double atr, string blocker)
{
   double atrL = iATR(NULL, 0, AtrPeriod * 10, 1);
   double vr   = (atrL > 0) ? iATR(NULL, 0, AtrPeriod, 1) / atrL : 0;
   double net = MathAbs(Close[1] - Close[1 + ErPeriod]);
   double path = 0;
   for(int k = 1; k <= ErPeriod; k++) path += MathAbs(Close[k] - Close[k + 1]);
   double er = (path > 0) ? net / path : 0;
   string htf = "off";
   if(UseHTFFilter)
   {
      double f = iMA(NULL, HigherTF, HTFEmaFast, 0, MODE_EMA, PRICE_CLOSE, 1);
      double s = iMA(NULL, HigherTF, HTFEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 1);
      htf = (f > s) ? "UP" : "DOWN";
   }
   double line = (tr > 0) ? UpLine[1] : DnLine[1];

   PanelRow(0, "RegimeTrailPro v3  " + Symbol() + " " + TfName(),
            clrWhite);
   PanelRow(1, "Trend: " + (tr > 0 ? "UP" : "DOWN") + "   HTF: " + htf,
            tr > 0 ? clrDodgerBlue : clrTomato);
   PanelRow(2, "Stop line: " + DoubleToString(line, Digits) +
               "   ATR: " + DoubleToString(atr, Digits), clrSilver);
   PanelRow(3, "ER: " + DoubleToString(er, 2) + " (need >" + DoubleToString(ErThreshold,2) +
               ")   VolRatio: " + DoubleToString(vr, 2), clrSilver);
   PanelRow(4, (blocker == "" ? "Status: armed - watching for setup"
                              : "Blocked by: " + blocker),
            blocker == "" ? clrLimeGreen : clrOrange);
}

//+------------------------------------------------------------------+
void PanelRow(int row, string text, color clr)
{
   string name = "RTP_row" + IntegerToString(row);
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 8);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 16 + row * 15);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
string TfName()
{
   switch(Period())
   {
      case PERIOD_M15: return("M15");
      case PERIOD_M30: return("M30");
      case PERIOD_H1:  return("H1");
      case PERIOD_H4:  return("H4");
      case PERIOD_D1:  return("D1");
   }
   return(IntegerToString(Period()) + "min");
}
//+------------------------------------------------------------------+
