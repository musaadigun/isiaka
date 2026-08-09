//+------------------------------------------------------------------+
//| XVISION_EURUSD_Adaptive_EA_v1.mq4                                 |
//|                                                                    |
//| MANDATE: trade EUR/USD adaptively, stand aside in bad regimes,     |
//| self-monitor, target whatever the data supports. No daily quota.   |
//|                                                                    |
//| WHY THESE ENGINES: they are the only two EURUSD strategies that    |
//| survived walk-forward + split-half testing on 5.9 years of your    |
//| own FxPro H1 data (resampled H4), after spread:                    |
//|   E1 DIVERGENCE CONFLUENCE (H4): MACD/OsMA and Stochastic both     |
//|      diverging in the same direction. +0.40R avg, PF ~1.5,         |
//|      1st half +0.33R / 2nd half +0.46R (improving), ~10 trades/yr. |
//|   E2 KELTNER FADE (H4): close beyond SMA50 +/- 2.5 ATR while the   |
//|      market is RANGING (efficiency ratio < 0.15). Target the mean, |
//|      24-bar time stop. +0.27R / +0.35R by half, ~10 trades/yr.     |
//| Everything on H1 tested NEGATIVE and is deliberately absent.       |
//|                                                                    |
//| THE ADAPTIVE LAYER (the answer to "backtests are backward-looking")|
//|   * Each engine keeps a rolling expectancy (EWMA of realised R).   |
//|   * EWMA >= 0            -> full size                              |
//|   * EWMA in [-0.25, 0)   -> HALF size (degrading)                  |
//|   * EWMA < -0.25         -> STOOD DOWN: no live orders, but the    |
//|                             engine keeps taking SHADOW trades so   |
//|                             it continues to measure itself and can |
//|                             re-enable when it recovers above -0.15.|
//|   * Regime gate + spread gate + panic-volatility gate on top.      |
//|   * Every closed trade (live and shadow) is journalled to CSV in   |
//|     MQL4/Files so live results can be compared to the backtest.    |
//|                                                                    |
//| SAFETY: SignalOnly defaults TRUE - it will NOT place orders until  |
//| you switch it off. Run it that way first and read the journal.     |
//+------------------------------------------------------------------+
#property strict

//--- execution
input bool   SignalOnly            = true;   // TRUE = alerts + journal only, no orders
input double BaseRiskPercent       = 1.0;    // risk per trade at full size
input double MaxSpreadPips         = 2.0;    // skip entries above this spread
input int    SlippagePoints        = 10;
input int    MagicNumber           = 260801;
//--- engine 1: divergence confluence (validated H4)
input bool   UseDivergence         = true;
input int    DivConfluenceBars     = 8;      // both oscillators must diverge within N H4 bars
input double DivRewardRisk         = 2.0;    // validated fixed target
input int    DivSwingBars          = 12;     // stop beyond this swing extreme
input double DivStopAtrCushion     = 0.5;
//--- engine 2: keltner fade (validated H4)
input bool   UseKeltnerFade        = true;
input int    KMidPeriod            = 50;
input double KBandMult             = 2.5;
input double KErMax                = 0.15;   // fade ONLY when ranging (load-bearing)
input double KStopAtr              = 1.0;    // stop beyond the signal extreme
input int    KTimeStopBars         = 24;     // H4 bars
//--- regime gates
input double PanicVolRatio         = 2.50;   // ATR24/ATR240 above this = stand aside
input int    AtrPeriod             = 24;
//--- adaptive self-monitor
input bool   UseAdaptiveSizing     = true;
input double EwmaAlpha             = 0.10;   // ~last 20 trades
input double HalfSizeBelow         = 0.00;   // EWMA below this -> half size
input double StandDownBelow        = -0.25;  // EWMA below this -> shadow only
input double ReEnableAbove         = -0.15;  // shadow recovery threshold
input int    MinTradesBeforeAdapt  = 8;      // don't judge an engine too early
//--- misc
input bool   PopupAlerts           = true;
input bool   PushAlerts            = true;
input bool   WriteJournal          = true;
input bool   ResetAdaptiveState    = false;  // set TRUE once to wipe stored stats

#define ENG_DIV  0
#define ENG_KELT 1
#define TF       PERIOD_H4

string  PREFIX  = "XV_EUA_V1_";
string  JOURNAL = "XVISION_EURUSD_Adaptive_Journal.csv";

datetime g_lastH4      = 0;
datetime g_lastAlert   = 0;
int      g_liveTicket  = -1;
int      g_liveEngine  = -1;
double   g_liveRisk    = 0.0;
double   g_liveEntry   = 0.0;
datetime g_liveOpened  = 0;
int      g_liveBarsHeld= 0;

// one shadow trade per engine
int      s_dir[2];
double   s_entry[2], s_stop[2], s_target[2], s_risk[2];
int      s_bars[2];
bool     s_active[2];

//+------------------------------------------------------------------+
int OnInit()
{
   string s = Symbol(); StringToUpper(s);
   if(StringFind(s,"EURUSD") < 0)
      Alert("Adaptive EA: engines validated on EURUSD only. Current symbol: ", Symbol());

   if(ResetAdaptiveState) ResetState();
   for(int e=0; e<2; e++) s_active[e] = false;

   RecoverLiveTicket();

   if(WriteJournal && !FileIsExist(JOURNAL))
   {
      int fh = FileOpen(JOURNAL, FILE_CSV|FILE_WRITE, ',');
      if(fh != INVALID_HANDLE)
      {
         FileWrite(fh, "closed_gmt","engine","mode","dir","entry","exit","R",
                       "ewma_after","regime");
         FileClose(fh);
      }
   }
   EventSetTimer(5);
   Comment("");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); Comment(""); }
void OnTimer() { Engine(); }
void OnTick()  { Engine(); }

//+------------------------------------------------------------------+
void Engine()
{
   ManageLive();

   datetime h4 = iTime(NULL,TF,0);
   if(h4 != g_lastH4)
   {
      g_lastH4 = h4;
      OnNewH4Bar();
   }
   Panel();
}

//+------------------------------------------------------------------+
//| everything that is decided once per completed H4 bar              |
void OnNewH4Bar()
{
   if(iBars(NULL,TF) < AtrPeriod*11 + 70) return;

   UpdateShadows();
   if(g_liveTicket >= 0) g_liveBarsHeld++;

   int regime = Regime();
   if(regime == 3) return;                    // panic volatility: stand aside entirely

   // --- engine 1: divergence confluence
   if(UseDivergence)
   {
      int d = DivergenceSignal();
      if(d != 0) HandleSignal(ENG_DIV, d, regime);
   }
   // --- engine 2: keltner fade (ranging regime only)
   if(UseKeltnerFade && regime == 1)
   {
      int d = KeltnerSignal();
      if(d != 0) HandleSignal(ENG_KELT, d, regime);
   }
}

//+------------------------------------------------------------------+
//| regime: 0 transitional, 1 ranging, 2 trending, 3 panic            |
int Regime()
{
   double a  = iATR(NULL,TF,AtrPeriod,1);
   double aL = iATR(NULL,TF,AtrPeriod*10,1);
   double vr = (aL > 0) ? a/aL : 1.0;
   if(vr >= PanicVolRatio) return(3);
   double er = EfficiencyRatio(1);
   if(er < KErMax)  return(1);
   if(er > 0.25)    return(2);
   return(0);
}

double EfficiencyRatio(int shift)
{
   double net = MathAbs(iClose(NULL,TF,shift) - iClose(NULL,TF,shift+24));
   double path = 0;
   for(int k=0; k<24; k++)
      path += MathAbs(iClose(NULL,TF,shift+k) - iClose(NULL,TF,shift+k+1));
   return(path > 0 ? net/path : 1.0);
}

//+------------------------------------------------------------------+
//| ENGINE 1 - MACD(OsMA) + Stochastic divergence confluence          |
int DivergenceSignal()
{
   int mb=0, mr=0, sb=0, sr=0;
   ScanDivergence(true,  mb, mr);      // OsMA
   ScanDivergence(false, sb, sr);      // Stochastic
   bool freshB = (mb==1 || sb==1);
   bool freshR = (mr==1 || sr==1);
   if(mb>0 && sb>0 && freshB) return(1);
   if(mr>0 && sr>0 && freshR) return(-1);
   return(0);
}

//| sets bull/bear = 1 if a confirmed divergence sits on bar 1,       |
//| or 2 if one occurred within DivConfluenceBars (still valid).      |
void ScanDivergence(bool useOsMA, int &bull, int &bear)
{
   bull=0; bear=0;
   for(int i=1; i<=DivConfluenceBars; i++)
   {
      int p = i+2;                                   // extreme confirmed 2 bars later
      double op  = Osc(useOsMA, p);
      double op1 = Osc(useOsMA, p+1), op2 = Osc(useOsMA, p+2);
      double om1 = Osc(useOsMA, p-1), om2 = Osc(useOsMA, p-2);
      // peak at p ?
      if(op>op1 && op>op2 && op>=om1 && op>=om2)
         for(int q=p+5; q<=p+60; q++)
         {
            double oq=Osc(useOsMA,q), oq1=Osc(useOsMA,q+1), oq2=Osc(useOsMA,q+2);
            double qm1=Osc(useOsMA,q-1), qm2=Osc(useOsMA,q-2);
            if(oq>oq1 && oq>oq2 && oq>=qm1 && oq>=qm2)
            {
               if(iHigh(NULL,TF,p) > iHigh(NULL,TF,q) && op < oq)
                  bear = (i==1) ? 1 : MathMax(bear,2);
               break;
            }
         }
      // trough at p ?
      if(op<op1 && op<op2 && op<=om1 && op<=om2)
         for(int q2=p+5; q2<=p+60; q2++)
         {
            double oq=Osc(useOsMA,q2), oq1=Osc(useOsMA,q2+1), oq2=Osc(useOsMA,q2+2);
            double qm1=Osc(useOsMA,q2-1), qm2=Osc(useOsMA,q2-2);
            if(oq<oq1 && oq<oq2 && oq<=qm1 && oq<=qm2)
            {
               if(iLow(NULL,TF,p) < iLow(NULL,TF,q2) && op > oq)
                  bull = (i==1) ? 1 : MathMax(bull,2);
               break;
            }
         }
   }
}

double Osc(bool useOsMA, int shift)
{
   if(useOsMA) return(iOsMA(NULL,TF,12,26,9,PRICE_CLOSE,shift));
   return(iStochastic(NULL,TF,14,3,3,MODE_SMA,0,MODE_MAIN,shift));
}

//+------------------------------------------------------------------+
//| ENGINE 2 - Keltner fade, ranging regime only                      |
int KeltnerSignal()
{
   double a   = iATR(NULL,TF,AtrPeriod,1);
   double mid = iMA(NULL,TF,KMidPeriod,0,MODE_SMA,PRICE_CLOSE,1);
   if(a <= 0) return(0);
   double c = iClose(NULL,TF,1);
   // must have been inside the bands on the prior bar (one signal per excursion)
   double midp = iMA(NULL,TF,KMidPeriod,0,MODE_SMA,PRICE_CLOSE,2);
   double ap   = iATR(NULL,TF,AtrPeriod,2);
   double cp   = iClose(NULL,TF,2);
   bool wasInside = (cp < midp + KBandMult*ap && cp > midp - KBandMult*ap);
   if(!wasInside) return(0);
   if(c > mid + KBandMult*a) return(-1);
   if(c < mid - KBandMult*a) return(1);
   return(0);
}

//+------------------------------------------------------------------+
//| route a signal: live trade, shadow trade, or blocked              |
void HandleSignal(int eng, int dir, int regime)
{
   double a = iATR(NULL,TF,AtrPeriod,1);
   if(a <= 0) return;
   double entry, stop, target;
   BuildLevels(eng, dir, a, entry, stop, target);
   double risk = MathAbs(entry - stop);
   if(risk <= 0) return;

   int    st   = EngineState(eng);          // 0 full, 1 half, 2 stood down
   double mult = (st==0) ? 1.0 : ((st==1) ? 0.5 : 0.0);

   string modeTxt;
   bool   goLive = (!SignalOnly && st < 2 && g_liveTicket < 0 &&
                    SpreadPips() <= MaxSpreadPips);

   if(goLive)      modeTxt = (st==1) ? "LIVE-HALF" : "LIVE";
   else if(st==2)  modeTxt = "SHADOW (engine stood down)";
   else if(SignalOnly) modeTxt = "SHADOW (SignalOnly mode)";
   else if(g_liveTicket >= 0) modeTxt = "SHADOW (slot busy)";
   else            modeTxt = "SHADOW (spread " + DoubleToString(SpreadPips(),1) + ")";

   Announce(eng, dir, entry, stop, target, risk, mult, modeTxt, regime);

   if(goLive) OpenLive(eng, dir, entry, stop, target, risk, mult);
   else       OpenShadow(eng, dir, entry, stop, target, risk);
}

void BuildLevels(int eng, int dir, double a, double &entry, double &stop, double &target)
{
   entry = (dir>0) ? Ask : Bid;
   if(eng == ENG_DIV)
   {
      double swing = (dir>0)
         ? iLow (NULL,TF,iLowest (NULL,TF,MODE_LOW ,DivSwingBars,1))
         : iHigh(NULL,TF,iHighest(NULL,TF,MODE_HIGH,DivSwingBars,1));
      stop   = swing - dir*DivStopAtrCushion*a;
      target = entry + dir*DivRewardRisk*MathAbs(entry-stop);
   }
   else
   {
      double ext = (dir>0) ? iLow(NULL,TF,1) : iHigh(NULL,TF,1);
      stop   = ext - dir*KStopAtr*a;
      target = iMA(NULL,TF,KMidPeriod,0,MODE_SMA,PRICE_CLOSE,1);   // the mean
   }
}

//+------------------------------------------------------------------+
void OpenLive(int eng,int dir,double entry,double stop,double target,
              double risk,double mult)
{
   double lots = LotsForRisk(risk, mult);
   if(lots <= 0) { Say("Adaptive EA: lot size resolved to 0 - trade skipped."); return; }
   int type = (dir>0) ? OP_BUY : OP_SELL;
   double px = (dir>0) ? Ask : Bid;
   int t = OrderSend(Symbol(), type, lots, px, SlippagePoints,
                     NormalizeDouble(stop,Digits), NormalizeDouble(target,Digits),
                     "XVEUA_" + IntegerToString(eng), MagicNumber, 0,
                     (dir>0)?clrDodgerBlue:clrTomato);
   if(t < 0) { Say("Adaptive EA: OrderSend failed, error " + IntegerToString(GetLastError())); return; }
   g_liveTicket = t; g_liveEngine = eng; g_liveRisk = risk;
   g_liveEntry = px; g_liveOpened = TimeCurrent(); g_liveBarsHeld = 0;
   GlobalVariableSet(GN("LIVE_TICKET"), t);
   GlobalVariableSet(GN("LIVE_ENGINE"), eng);
   GlobalVariableSet(GN("LIVE_RISK"), risk);
   GlobalVariableSet(GN("LIVE_ENTRY"), px);
}

void OpenShadow(int eng,int dir,double entry,double stop,double target,double risk)
{
   if(s_active[eng]) return;                 // one shadow per engine at a time
   s_active[eng]=true; s_dir[eng]=dir; s_entry[eng]=entry;
   s_stop[eng]=stop; s_target[eng]=target; s_risk[eng]=risk; s_bars[eng]=0;
}

//+------------------------------------------------------------------+
//| shadow trades resolve on H4 bars and feed the same EWMA           |
void UpdateShadows()
{
   for(int e=0; e<2; e++)
   {
      if(!s_active[e]) continue;
      s_bars[e]++;
      double hi = iHigh(NULL,TF,1), lo = iLow(NULL,TF,1), cl = iClose(NULL,TF,1);
      int d = s_dir[e];
      bool hitStop = (d>0) ? (lo <= s_stop[e])   : (hi >= s_stop[e]);
      bool hitTgt  = (d>0) ? (hi >= s_target[e]) : (lo <= s_target[e]);
      double R;
      if(hitStop)      R = -1.0;
      else if(hitTgt)  R = MathAbs(s_target[e]-s_entry[e]) / s_risk[e];
      else if(e==ENG_KELT && s_bars[e] >= KTimeStopBars)
                       R = (cl - s_entry[e]) * d / s_risk[e];
      else if(e==ENG_DIV && s_bars[e] >= 120)
                       R = (cl - s_entry[e]) * d / s_risk[e];
      else continue;
      s_active[e] = false;
      RecordResult(e, R, "SHADOW", d, s_entry[e], (hitStop?s_stop[e]:(hitTgt?s_target[e]:cl)));
   }
}

//+------------------------------------------------------------------+
//| live position management + closure detection                      |
void ManageLive()
{
   if(g_liveTicket < 0) return;
   if(OrderSelect(g_liveTicket, SELECT_BY_TICKET))
   {
      if(OrderCloseTime() == 0)
      {
         // keltner time stop
         if(g_liveEngine == ENG_KELT && g_liveBarsHeld >= KTimeStopBars)
         {
            double px = (OrderType()==OP_BUY) ? Bid : Ask;
            if(OrderClose(g_liveTicket, OrderLots(), NormalizeDouble(px,Digits),
                          SlippagePoints, clrGray))
               Say("Adaptive EA: Keltner time stop reached - position closed.");
         }
         return;
      }
      // closed: compute R and record
      int    d    = (OrderType()==OP_BUY) ? 1 : -1;
      double exit = OrderClosePrice();
      double R    = (g_liveRisk>0) ? (exit - g_liveEntry)*d / g_liveRisk : 0.0;
      RecordResult(g_liveEngine, R, "LIVE", d, g_liveEntry, exit);
      ClearLive();
   }
   else ClearLive();
}

void ClearLive()
{
   g_liveTicket=-1; g_liveEngine=-1; g_liveRisk=0; g_liveEntry=0; g_liveBarsHeld=0;
   GlobalVariableSet(GN("LIVE_TICKET"), -1);
}

void RecoverLiveTicket()
{
   g_liveTicket = -1;
   for(int i=OrdersTotal()-1; i>=0; i--)
      if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES))
         if(OrderMagicNumber()==MagicNumber && OrderSymbol()==Symbol())
         {
            g_liveTicket = OrderTicket();
            g_liveEngine = (int)GlobalVariableGet(GN("LIVE_ENGINE"));
            g_liveRisk   = GlobalVariableGet(GN("LIVE_RISK"));
            g_liveEntry  = GlobalVariableGet(GN("LIVE_ENTRY"));
            break;
         }
}

//+------------------------------------------------------------------+
//| THE ADAPTIVE CORE - rolling expectancy per engine                 |
void RecordResult(int eng, double R, string mode, int dir, double entry, double exit)
{
   double ewma = GlobalVariableGet(GN("EWMA_"+IntegerToString(eng)));
   double cnt  = GlobalVariableGet(GN("CNT_"+IntegerToString(eng)));
   if(cnt <= 0) ewma = R; else ewma = EwmaAlpha*R + (1.0-EwmaAlpha)*ewma;
   cnt += 1;
   GlobalVariableSet(GN("EWMA_"+IntegerToString(eng)), ewma);
   GlobalVariableSet(GN("CNT_"+IntegerToString(eng)), cnt);
   GlobalVariableSet(GN("SUM_"+IntegerToString(eng)),
                     GlobalVariableGet(GN("SUM_"+IntegerToString(eng))) + R);
   if(R > 0) GlobalVariableSet(GN("WIN_"+IntegerToString(eng)),
                     GlobalVariableGet(GN("WIN_"+IntegerToString(eng))) + 1);

   string msg = StringConcatenate("Adaptive EA  ", EngName(eng), "  ", mode,
      " closed  R=", DoubleToString(R,2),
      "  | rolling expectancy now ", DoubleToString(ewma,3),
      " over ", DoubleToString(cnt,0), " results | state: ", StateName(EngineState(eng)));
   Say(msg);

   if(WriteJournal)
   {
      int fh = FileOpen(JOURNAL, FILE_CSV|FILE_READ|FILE_WRITE, ',');
      if(fh != INVALID_HANDLE)
      {
         FileSeek(fh, 0, SEEK_END);
         FileWrite(fh, TimeToString(TimeGMT(),TIME_DATE|TIME_SECONDS), EngName(eng),
                   mode, (dir>0?"BUY":"SELL"),
                   DoubleToString(entry,Digits), DoubleToString(exit,Digits),
                   DoubleToString(R,3), DoubleToString(ewma,3), RegimeName(Regime()));
         FileClose(fh);
      }
   }
}

//| 0 full size, 1 half size, 2 stood down                            |
int EngineState(int eng)
{
   if(!UseAdaptiveSizing) return(0);
   double cnt  = GlobalVariableGet(GN("CNT_"+IntegerToString(eng)));
   if(cnt < MinTradesBeforeAdapt) return(0);
   double ewma = GlobalVariableGet(GN("EWMA_"+IntegerToString(eng)));
   double down = GlobalVariableGet(GN("DOWN_"+IntegerToString(eng)));
   if(down > 0.5)                       // currently stood down: recover?
   {
      if(ewma > ReEnableAbove)
      { GlobalVariableSet(GN("DOWN_"+IntegerToString(eng)), 0);
        Say("Adaptive EA: " + EngName(eng) + " RE-ENABLED (rolling expectancy " +
            DoubleToString(ewma,3) + ")"); return(1); }
      return(2);
   }
   if(ewma < StandDownBelow)
   {
      GlobalVariableSet(GN("DOWN_"+IntegerToString(eng)), 1);
      Say("Adaptive EA: " + EngName(eng) + " STOOD DOWN - rolling expectancy " +
          DoubleToString(ewma,3) + ". Shadow trading only until it recovers.");
      return(2);
   }
   if(ewma < HalfSizeBelow) return(1);
   return(0);
}

//+------------------------------------------------------------------+
void Announce(int eng,int dir,double entry,double stop,double target,
              double risk,double mult,string mode,int regime)
{
   if(iTime(NULL,TF,0) == g_lastAlert) return;
   g_lastAlert = iTime(NULL,TF,0);
   double lots = LotsForRisk(risk, mult);
   double rr   = (risk>0) ? MathAbs(target-entry)/risk : 0;
   Say(StringConcatenate("Adaptive EA  ", EngName(eng), "  ", (dir>0?"BUY":"SELL"),
       "  EURUSD H4  [", mode, "]",
       "\nEntry ~ ", DoubleToString(entry,Digits),
       "   Stop ", DoubleToString(stop,Digits),
       "   Target ", DoubleToString(target,Digits), " (", DoubleToString(rr,1), "R)",
       "\nRisk ", DoubleToString(BaseRiskPercent*mult,2), "%  ->  ",
       DoubleToString(lots,2), " lots",
       "\nRegime: ", RegimeName(regime),
       "   rolling expectancy ", DoubleToString(GlobalVariableGet(GN("EWMA_"+IntegerToString(eng))),3)));
}

//+------------------------------------------------------------------+
double LotsForRisk(double slDist, double mult)
{
   if(mult <= 0) return(0);
   double tv=MarketInfo(Symbol(),MODE_TICKVALUE), ts=MarketInfo(Symbol(),MODE_TICKSIZE);
   if(tv<=0 || ts<=0 || slDist<=0) return(0);
   double money  = AccountBalance()*BaseRiskPercent*mult/100.0;
   double perLot = slDist/ts*tv;
   if(perLot <= 0) return(0);
   double step = MarketInfo(Symbol(),MODE_LOTSTEP);
   double minL = MarketInfo(Symbol(),MODE_MINLOT);
   double maxL = MarketInfo(Symbol(),MODE_MAXLOT);
   double lots = MathFloor((money/perLot)/step)*step;
   if(lots < minL) return(0);
   return(NormalizeDouble(MathMin(lots,maxL),2));
}

double SpreadPips()
{
   double pip = (Digits==5 || Digits==3) ? Point*10 : Point;
   return((Ask-Bid)/pip);
}

string GN(string tag) { return(PREFIX + tag + "_" + Symbol()); }
string EngName(int e) { return(e==ENG_DIV ? "DIVERGENCE" : "KELTNER-FADE"); }
string StateName(int s){ return(s==0 ? "FULL" : (s==1 ? "HALF" : "STOOD DOWN")); }
string RegimeName(int r)
{
   if(r==1) return("RANGING");
   if(r==2) return("TRENDING");
   if(r==3) return("PANIC-VOL");
   return("TRANSITIONAL");
}

void ResetState()
{
   for(int e=0; e<2; e++)
   {
      GlobalVariableSet(GN("EWMA_"+IntegerToString(e)), 0);
      GlobalVariableSet(GN("CNT_"+IntegerToString(e)), 0);
      GlobalVariableSet(GN("SUM_"+IntegerToString(e)), 0);
      GlobalVariableSet(GN("WIN_"+IntegerToString(e)), 0);
      GlobalVariableSet(GN("DOWN_"+IntegerToString(e)), 0);
   }
   Print("Adaptive EA: adaptive state reset.");
}

void Say(string msg)
{
   Print(msg);
   if(PopupAlerts) Alert(msg);
   if(PushAlerts)  SendNotification(msg);
}

//+------------------------------------------------------------------+
void Panel()
{
   string txt = "XVISION EURUSD ADAPTIVE EA v1   " +
                (SignalOnly ? "[SIGNAL-ONLY]" : "[LIVE]") + "\n";
   txt += "Regime: " + RegimeName(Regime()) +
          "   spread " + DoubleToString(SpreadPips(),1) + " pips\n";
   for(int e=0; e<2; e++)
   {
      double ewma=GlobalVariableGet(GN("EWMA_"+IntegerToString(e)));
      double cnt =GlobalVariableGet(GN("CNT_"+IntegerToString(e)));
      double sum =GlobalVariableGet(GN("SUM_"+IntegerToString(e)));
      double win =GlobalVariableGet(GN("WIN_"+IntegerToString(e)));
      txt += StringConcatenate(EngName(e), ": ", StateName(EngineState(e)),
             "  | results ", DoubleToString(cnt,0),
             "  win ", (cnt>0?DoubleToString(100*win/cnt,0):"0"), "%",
             "  total ", DoubleToString(sum,2), "R",
             "  rolling ", DoubleToString(ewma,3), "R\n");
   }
   txt += (g_liveTicket>=0)
          ? "OPEN: " + EngName(g_liveEngine) + " ticket " + IntegerToString(g_liveTicket) +
            "  bars held " + IntegerToString(g_liveBarsHeld) + "\n"
          : "OPEN: none\n";
   txt += "Backtest baseline: DIVERGENCE +0.40R | KELTNER +0.30R\n";
   Comment(txt);
}
//+------------------------------------------------------------------+
