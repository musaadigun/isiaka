//+------------------------------------------------------------------+
//|                                                     IsiakaEMA.mq4 |
//|                                                                   |
//|  Exponential moving average with a free period input.             |
//|                                                                   |
//|  EMA[i] = Price[i] * a + EMA[i+1] * (1 - a),   a = 2 / (N + 1)    |
//|                                                                   |
//|  This is the same recursion MT4's own Moving Average.mq4 uses for |
//|  MODE_EMA, so the line sits exactly on top of the built-in EMA.   |
//|  Leave InpSelfCheck on and the indicator will prove that to you   |
//|  in the Experts log: it re-computes every bar with the built-in   |
//|  iMA() and prints the largest disagreement it found.              |
//|                                                                   |
//|  Nothing here is tied to a timeframe or a symbol -- attach it to  |
//|  GOLD M1 through MN, or to anything else.                         |
//+------------------------------------------------------------------+
#property copyright "Isiaka"
#property version   "1.00"
#property strict

#property indicator_chart_window
#property indicator_buffers 1
#property indicator_color1  clrRed
#property indicator_width1  2

//--- Core ------------------------------------------------------------
input int               InpPeriod       = 50;            // EMA period
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE;  // Applied price
input int               InpShift        = 0;             // Horizontal shift (bars)

//--- Optional higher timeframe ---------------------------------------
input ENUM_TIMEFRAMES   InpTimeframe    = PERIOD_CURRENT; // Compute on this timeframe

//--- Appearance -------------------------------------------------------
input color             InpColor        = clrRed;        // Line colour
input int               InpWidth        = 2;             // Line width

//--- Diagnostics ------------------------------------------------------
input bool              InpSelfCheck    = true;          // Verify against MT4 built-in EMA
input bool              InpShowStats    = false;         // Show cross count on chart

double          ExtEMA[];
double          g_alpha;
ENUM_TIMEFRAMES g_tf;
bool            g_mtf;
bool            g_checked = false;
string          g_name;
string          g_label   = "IsiakaEMA_stats";

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPeriod < 1)
   {
      Print("IsiakaEMA: period must be 1 or greater");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_alpha = 2.0 / (InpPeriod + 1.0);
   g_tf    = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : InpTimeframe;
   g_mtf   = (g_tf != (ENUM_TIMEFRAMES)Period());

   SetIndexBuffer(0, ExtEMA);
   SetIndexStyle(0, DRAW_LINE, STYLE_SOLID, InpWidth, InpColor);
   SetIndexShift(0, InpShift);
   SetIndexDrawBegin(0, InpPeriod);
   SetIndexEmptyValue(0, EMPTY_VALUE);

   g_name = StringFormat("EMA(%d)", InpPeriod);
   if(g_mtf)
      g_name += " " + TimeframeName(g_tf);

   IndicatorShortName(g_name);
   SetIndexLabel(0, g_name);
   IndicatorDigits(Digits);

   g_checked = false;
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectDelete(0, g_label);
   Comment("");
}

//+------------------------------------------------------------------+
string TimeframeName(const ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";
   }
   return "TF" + IntegerToString((int)tf);
}

//+------------------------------------------------------------------+
//| The applied price for one bar. Series indexing: 0 = current bar. |
//+------------------------------------------------------------------+
double Price(const int i,
             const double &open[],
             const double &high[],
             const double &low[],
             const double &close[])
{
   switch(InpAppliedPrice)
   {
      case PRICE_OPEN:     return open[i];
      case PRICE_HIGH:     return high[i];
      case PRICE_LOW:      return low[i];
      case PRICE_MEDIAN:   return (high[i] + low[i]) / 2.0;
      case PRICE_TYPICAL:  return (high[i] + low[i] + close[i]) / 3.0;
      case PRICE_WEIGHTED: return (high[i] + low[i] + 2.0 * close[i]) / 4.0;
   }
   return close[i];
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total < 2)
      return 0;

   //--- Force series indexing so bar 0 is always the current bar.
   ArraySetAsSeries(time,  true);
   ArraySetAsSeries(open,  true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);

   int limit;
   if(prev_calculated <= 0)
   {
      //--- Seed with the raw price on the oldest bar, exactly as MT4 does.
      //--- Any seed converges within ~200 bars; this one matches the terminal.
      limit = rates_total - 2;
      ExtEMA[rates_total - 1] = Price(rates_total - 1, open, high, low, close);
   }
   else
   {
      limit = rates_total - prev_calculated;
      if(limit > rates_total - 2)
         limit = rates_total - 2;
   }

   if(g_mtf)
   {
      //--- Read the higher timeframe's own EMA and map it onto these bars.
      for(int i = limit; i >= 0; i--)
      {
         int sh = iBarShift(_Symbol, g_tf, time[i], false);
         if(sh < 0)
         {
            ExtEMA[i] = EMPTY_VALUE;
            continue;
         }
         ExtEMA[i] = iMA(_Symbol, g_tf, InpPeriod, 0, MODE_EMA, InpAppliedPrice, sh);
      }
   }
   else
   {
      for(int i = limit; i >= 0; i--)
         ExtEMA[i] = g_alpha * Price(i, open, high, low, close)
                   + (1.0 - g_alpha) * ExtEMA[i + 1];
   }

   if(InpSelfCheck && !g_checked && !g_mtf && rates_total > InpPeriod + 300)
      SelfCheck(rates_total);

   if(InpShowStats)
      ShowStats(rates_total, time, open, high, low, close);

   return rates_total;
}

//+------------------------------------------------------------------+
//| Compare every bar against MT4's own EMA and report the worst gap. |
//+------------------------------------------------------------------+
void SelfCheck(const int rates_total)
{
   g_checked = true;

   int    count = MathMin(rates_total - InpPeriod - 5, 5000);
   double worst = 0.0;
   int    worst_bar = -1;

   for(int i = 1; i <= count; i++)
   {
      double builtin = iMA(_Symbol, 0, InpPeriod, 0, MODE_EMA, InpAppliedPrice, i);
      if(builtin == 0.0)
         continue;
      double diff = MathAbs(builtin - ExtEMA[i]);
      if(diff > worst)
      {
         worst = diff;
         worst_bar = i;
      }
   }

   PrintFormat("IsiakaEMA self-check: %s on %s -- max deviation from MT4 built-in "
               "EMA(%d) across %d bars = %.10f (worst at bar %d). "
               "Anything below 0.0000001 is floating-point noise, not a difference.",
               g_name, _Symbol, InpPeriod, count, worst, worst_bar);
}

//+------------------------------------------------------------------+
//| Count how often the applied price closes on the other side of    |
//| the EMA. This is what an EA would actually fire on -- it is       |
//| normally far more often than the eye picks up at chart zoom.      |
//+------------------------------------------------------------------+
void ShowStats(const int rates_total,
               const datetime &time[],
               const double &open[],
               const double &high[],
               const double &low[],
               const double &close[])
{
   int first = MathMin(rates_total - 2, 5000);   // skip EMA warm-up
   if(first < InpPeriod + 200)
      return;
   first = MathMin(first, rates_total - InpPeriod - 200);
   if(first < 2)
      return;

   int crosses = 0, crosses_today = 0, days = 1;
   datetime day_start = iTime(_Symbol, PERIOD_D1, 0);

   bool prev_above = (Price(first, open, high, low, close) > ExtEMA[first]);

   for(int i = first - 1; i >= 0; i--)
   {
      if(ExtEMA[i] == EMPTY_VALUE)
         continue;

      bool above = (Price(i, open, high, low, close) > ExtEMA[i]);
      if(above != prev_above)
      {
         crosses++;
         if(time[i] >= day_start)
            crosses_today++;
      }
      prev_above = above;

      //--- new calendar day boundary
      if(i > 0 && TimeDay(time[i]) != TimeDay(time[i + 1]))
         days++;
   }

   string text = StringFormat("%s  |  %d crosses over %d bars (%d days)  |  "
                              "%.1f per day  |  today: %d",
                              g_name, crosses, first, days,
                              days > 0 ? (double)crosses / days : 0.0,
                              crosses_today);

   if(ObjectFind(0, g_label) < 0)
   {
      ObjectCreate(0, g_label, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, g_label, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, g_label, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, g_label, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, g_label, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, g_label, OBJPROP_FONTSIZE, 9);
   }
   ObjectSetString(0, g_label, OBJPROP_TEXT, text);
   ObjectSetInteger(0, g_label, OBJPROP_COLOR, InpColor);
}
//+------------------------------------------------------------------+
