//+------------------------------------------------------------------+
//| KeltnerFade.mq4                                                    |
//| MEAN-REVERSION signal indicator. NEVER trades. Born from a full    |
//| research cycle: designed, backtested on 16 combined years of       |
//| FxPro data, and configured to the ONE setup that was profitable    |
//| in BOTH halves of the test:                                        |
//|      EURUSD H4, bands 2.5 x ATR, ER < 0.15   (~10 trades/year,     |
//|      avg ~ +0.3R after spread, tested 2020-2026)                   |
//|                                                                    |
//| LOGIC (completed bars only):                                       |
//|   Mean  : SMA(50) - the green line price gets pulled back to       |
//|   Bands : mean +/- K x ATR(24) (Keltner channel)                   |
//|   Signal: close beyond a band  AND  market is RANGING              |
//|           (efficiency ratio < threshold)  AND  vol not in panic    |
//|           -> fade back toward the mean                             |
//|   Trade plan in alert: entry, stop (1 ATR beyond the extreme),     |
//|   target (the mean), lot size, and a TIME STOP: if neither stop    |
//|   nor target is hit within 48 bars, exit - reversion that hasn't   |
//|   happened isn't happening.                                        |
//|                                                                    |
//| WARNINGS FROM THE DATA (not opinions - measured):                  |
//|   * GOLD: this strategy FAILED stability tests on gold. Do not     |
//|     fade gold. Gold is for the trend indicator (H4 arrows).        |
//|   * Fading when ER is HIGH (trending) was the single worst         |
//|     strategy tested (-0.18R/trade). The ER gate is load-bearing.   |
//|                                                                    |
//| Install in MQL4/Indicators, compile (F7), attach to EURUSD H4.     |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property indicator_buffers 5
#property indicator_color1  clrLime             // mean (target) - bold
#property indicator_color2  clrTomato           // upper band = fade-short zone
#property indicator_color3  clrDodgerBlue       // lower band = fade-long zone
#property indicator_color4  clrDodgerBlue       // fade-long arrow
#property indicator_color5  clrTomato           // fade-short arrow
#property indicator_width1  3
#property indicator_width2  2
#property indicator_width3  2
#property indicator_width4  3
#property indicator_width5  3

//--- tested configuration (EURUSD H4). Change only with new evidence.
input int    MidPeriod        = 50;     // SMA period = the mean
input int    AtrPeriod        = 24;     // ATR period
input double BandMult         = 2.5;    // band distance = mult * ATR (tested: 2.5)
input int    ErPeriod         = 24;     // efficiency ratio lookback
input double ErMax            = 0.15;   // fade ONLY when ER below this (tested: 0.15)
input double VolRatioMax      = 2.50;   // no fades in panic volatility
input double StopAtrMult      = 1.0;    // stop = this many ATR beyond signal extreme
input int    TimeStopBars     = 48;     // exit if neither stop/target hit by then
input double RiskPercent      = 1.0;    // for suggested lot size
input bool   PopupAlerts      = true;
input bool   PushAlerts       = true;
input bool   ShowPanel        = true;

//--- buffers
double MidLine[], UpBand[], DnBand[], FadeLong[], FadeShort[];
double Armed[];                          // internal: re-arm state
datetime lastAlertBar = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   IndicatorBuffers(6);
   SetIndexBuffer(0, MidLine);   SetIndexStyle(0, DRAW_LINE);
   SetIndexBuffer(1, UpBand);    SetIndexStyle(1, DRAW_LINE);
   SetIndexBuffer(2, DnBand);    SetIndexStyle(2, DRAW_LINE);
   SetIndexBuffer(3, FadeLong);  SetIndexStyle(3, DRAW_ARROW); SetIndexArrow(3, 233);
   SetIndexBuffer(4, FadeShort); SetIndexStyle(4, DRAW_ARROW); SetIndexArrow(4, 234);
   SetIndexBuffer(5, Armed);
   SetIndexEmptyValue(3, EMPTY_VALUE); SetIndexEmptyValue(4, EMPTY_VALUE);
   SetIndexLabel(0, "Mean (target)"); SetIndexLabel(1, "Upper band");
   SetIndexLabel(2, "Lower band");
   SetIndexLabel(3, "FADE LONG");     SetIndexLabel(4, "FADE SHORT");
   IndicatorShortName("KeltnerFade(" + IntegerToString(MidPeriod) + "," +
                      DoubleToString(BandMult,1) + ")");
   if(Symbol() != "EURUSD" || Period() != PERIOD_H4)
      Print("KeltnerFade: validated ONLY on EURUSD H4. On ", Symbol(), " ",
            IntegerToString(Period()), "min it is an UNTESTED hypothesis.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   for(int r = 0; r < 6; r++) ObjectDelete(0, "KF_row" + IntegerToString(r));
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   int minBars = MathMax(AtrPeriod * 10, MathMax(MidPeriod, ErPeriod)) + 2;
   if(rates_total < minBars) return(0);

   ArraySetAsSeries(MidLine, true); ArraySetAsSeries(UpBand, true);
   ArraySetAsSeries(DnBand, true);  ArraySetAsSeries(FadeLong, true);
   ArraySetAsSeries(FadeShort, true); ArraySetAsSeries(Armed, true);

   int start = rates_total - minBars;
   if(prev_calculated > 0)
      start = MathMin(rates_total - prev_calculated + 1, rates_total - minBars);

   for(int i = start; i >= 0; i--)
   {
      double atr = iATR(NULL, 0, AtrPeriod, i);
      double mid = iMA(NULL, 0, MidPeriod, 0, MODE_SMA, PRICE_CLOSE, i);
      MidLine[i] = mid;
      UpBand[i]  = mid + BandMult * atr;
      DnBand[i]  = mid - BandMult * atr;
      FadeLong[i] = EMPTY_VALUE; FadeShort[i] = EMPTY_VALUE;

      // re-arm when price is back inside the bands
      double prevArmed = (i+1 < rates_total) ? Armed[i+1] : 1;
      Armed[i] = (Close[i] < UpBand[i] && Close[i] > DnBand[i]) ? 1 : prevArmed;

      int sig = 0;
      if(Close[i] > UpBand[i]) sig = -1;      // stretched above -> fade short
      if(Close[i] < DnBand[i]) sig = +1;      // stretched below -> fade long

      string blocker = "";
      if(sig != 0 && prevArmed == 1 && GatesOK(i, blocker))
      {
         if(sig > 0) FadeLong[i]  = Low[i]  - atr * 0.4;
         else        FadeShort[i] = High[i] + atr * 0.4;
         Armed[i] = 0;                        // one arrow per excursion
         if(i == 1) MaybeAlert(sig, i, atr, mid);
      }
      if(i <= 1 && ShowPanel) UpdatePanel(i, sig, atr, blocker);
   }
   return(rates_total);
}

//+------------------------------------------------------------------+
//| the load-bearing gates: ranging regime, no panic vol              |
bool GatesOK(int i, string &blocker)
{
   double net = MathAbs(Close[i] - Close[i + ErPeriod]);
   double path = 0;
   for(int k = 0; k < ErPeriod; k++)
      path += MathAbs(Close[i + k] - Close[i + k + 1]);
   double er = (path > 0) ? net / path : 1;
   if(er >= ErMax) { blocker = "market trending (ER " + DoubleToString(er,2) + ")"; return(false); }

   double atrS = iATR(NULL, 0, AtrPeriod, i);
   double atrL = iATR(NULL, 0, AtrPeriod * 10, i);
   double vr = (atrL > 0) ? atrS / atrL : 99;
   if(vr >= VolRatioMax) { blocker = "PANIC vol (" + DoubleToString(vr,2) + ")"; return(false); }

   blocker = "";
   return(true);
}

//+------------------------------------------------------------------+
void MaybeAlert(int dir, int i, double atr, double mid)
{
   if(Time[i] == lastAlertBar) return;
   lastAlertBar = Time[i];

   double entry  = Close[i];
   double ext    = (dir > 0) ? Low[i] : High[i];
   double stop   = (dir > 0) ? ext - StopAtrMult * atr : ext + StopAtrMult * atr;
   double risk   = MathAbs(entry - stop);
   double lots   = LotsForRisk(risk);
   double rr     = (risk > 0) ? MathAbs(mid - entry) / risk : 0;

   string msg = StringConcatenate(
      "FADE ", (dir > 0 ? "LONG" : "SHORT"), "  ", Symbol(), " ", TfName(),
      " (mean reversion)",
      "\nEntry ~ ", DoubleToString(entry, Digits),
      "\nStop:    ", DoubleToString(stop, Digits), " (", DoubleToString(StopAtrMult,1), " ATR beyond extreme)",
      "\nTarget: ", DoubleToString(mid, Digits), " (the mean, ~", DoubleToString(rr,1), "R)",
      "\nSize:    ", DoubleToString(lots, 2), " lots (", DoubleToString(RiskPercent,1), "% risk)",
      "\nTIME STOP: exit after ", IntegerToString(TimeStopBars),
      " bars if neither is hit.",
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
void UpdatePanel(int i, int sig, double atr, string blocker)
{
   double net = MathAbs(Close[1] - Close[1 + ErPeriod]);
   double path = 0;
   for(int k = 1; k <= ErPeriod; k++) path += MathAbs(Close[k] - Close[k + 1]);
   double er = (path > 0) ? net / path : 1;
   double atrL = iATR(NULL, 0, AtrPeriod * 10, 1);
   double vr = (atrL > 0) ? iATR(NULL, 0, AtrPeriod, 1) / atrL : 0;

   PanelRow(0, "KeltnerFade  " + Symbol() + " " + TfName() +
               "  [validated: EURUSD H4 only]", clrWhite);
   PanelRow(1, "Regime: " + (er < ErMax ? "RANGING - fades armed" : "TRENDING - stand aside"),
            er < ErMax ? clrLimeGreen : clrOrange);
   PanelRow(2, "ER: " + DoubleToString(er, 2) + " (need <" + DoubleToString(ErMax,2) +
               ")   VolRatio: " + DoubleToString(vr, 2), clrSilver);
   PanelRow(3, "Mean: " + DoubleToString(MidLine[1], Digits) +
               "   Bands: +/-" + DoubleToString(BandMult,1) + " ATR", clrSilver);
   PanelRow(4, (blocker == "" ? "Status: watching band edges"
                              : "Blocked by: " + blocker),
            blocker == "" ? clrSilver : clrOrange);
}

//+------------------------------------------------------------------+
void PanelRow(int row, string text, color clr)
{
   string name = "KF_row" + IntegerToString(row);
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
