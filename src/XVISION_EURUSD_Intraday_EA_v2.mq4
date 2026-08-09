//+------------------------------------------------------------------+
//| XVISION_EURUSD_Intraday_EA_v2.mq4                                  |
//|                                                                    |
//| MANDATE: EURUSD, at least one trade per day, adaptive, cost-aware. |
//|                                                                    |
//| WHAT IS AND IS NOT CLAIMED HERE — read this before deploying.      |
//|   The two engines below are chosen for STRUCTURAL reasons, not     |
//|   because they were curve-fitted to a sample. Neither has been     |
//|   backtested by the author of this file. The EA ships in           |
//|   SignalOnly mode and journals every decision, gross and net of    |
//|   cost, so that YOU generate the evidence on YOUR broker's fills   |
//|   before any money is at risk. Frequency is engineered. Profit is  |
//|   measured, not promised.                                          |
//|                                                                    |
//| WHY THESE TWO ENGINES                                              |
//|   A  LONDON BREAKOUT. The 00:00-07:00 GMT window is the thinnest   |
//|      liquidity of the EURUSD day; 07:00 GMT is when European bank  |
//|      flow arrives. A range that closed TIGHT relative to recent    |
//|      daily range is a coiled spring meeting a participation shift. |
//|      This is a structural argument about market microstructure,    |
//|      not a pattern found by searching. Trades ~1x/day.             |
//|   B  ASIAN FADE. The same thin book that makes the London break    |
//|      work makes intra-Asian extensions mean-revert: there is no    |
//|      size behind them. Fades stretch beyond a band, targets the    |
//|      mean, exits at session end. Trades ~0-2x/day.                 |
//|      A and B are deliberately opposed (breakout vs fade) and trade |
//|      different hours, so they should not fail simultaneously.      |
//|                                                                    |
//| COST IS THE WHOLE QUESTION AT THIS FREQUENCY                       |
//|   ~250 trades/yr at ~1.0 pip round turn is ~250 pips/yr of drag.   |
//|   Every R in this EA is therefore NET: live results use actual     |
//|   fills plus real commission and swap; shadow results use mid      |
//|   prices minus CostPips. Gross and net are journalled separately   |
//|   so you can see exactly what the broker is taking.                |
//|                                                                    |
//| WHAT IS FIXED FROM v1 (all 24 audit findings)                      |
//|   * No stale-signal fire on attach (bar clock seeded in OnInit).   |
//|   * Full order validation: stop level, freeze level, wrong-side    |
//|     stops, RefreshRates, retry with backoff, ECN SL/TP fallback.   |
//|   * State is FILE-backed, per account, not terminal global vars.   |
//|   * Any live failure falls through to a shadow trade, so the       |
//|     adaptive sample is never silently biased.                      |
//|   * Live and shadow expectancy tracked SEPARATELY, never pooled.   |
//|   * Identical exit rules on live and shadow paths.                 |
//|   * One slot PER ENGINE, so engines never cannibalise each other.  |
//|   * Shadow trades and bars-held survive restart.                   |
//|   * Hard risk breaker: daily loss, consecutive losses, equity DD.  |
//|   * Journal records entry regime, lots, spread, commission, swap.  |
//+------------------------------------------------------------------+
#property strict
#property description "EURUSD intraday adaptive EA - London breakout + Asian fade"
#property description "Ships in SignalOnly. Read the journal before going live."

//==================== EXECUTION =====================================
input bool   SignalOnly            = true;    // TRUE = journal + alerts only, no orders
input double BaseRiskPercent       = 0.75;    // risk per trade at full size
input double MaxSpreadPips         = 1.5;     // skip entries above this spread
input double CostPips              = 1.0;     // effective round-turn cost, shadow accounting
input double CommissionPerLotRT    = 7.0;     // account ccy per 1.0 lot round turn (live)
input int    SlippagePoints        = 15;
input int    MagicBase             = 270901;  // engine N uses MagicBase + N
input int    OrderRetries          = 3;
//==================== SESSIONS (all GMT, non-wrapping) ==============
input int    ServerGmtOffsetHours  = 99;      // 99 = auto-detect, else set manually
input int    AsianStartHour        = 0;       // range window opens
input int    AsianEndHour          = 7;       // range window closes / London begins
input int    BreakoutEndHour       = 11;      // no new breakout entries after this
input int    FlatByHour            = 16;      // all positions closed by this hour
input int    MinAsianBars          = 20;      // of 28 expected M15 bars; guards gaps/holidays
//==================== ENGINE A - LONDON BREAKOUT ====================
input bool   UseBreakout           = true;
input double MaxRangeToAdr         = 0.55;    // range must be TIGHT vs 14d ADR (load-bearing)
input double MinRangeToAdr         = 0.12;    // ...but not degenerate
input double BreakBufferAtr        = 0.25;    // entry buffer beyond the range edge
input double BreakRewardRisk       = 1.5;
input double BreakStopAtrCap       = 2.0;     // cap risk at N x M15 ATR
//==================== ENGINE B - ASIAN FADE =========================
input bool   UseFade               = true;
input int    FadeMidPeriod         = 50;      // M15 SMA = the mean
input double FadeBandAtr           = 2.2;     // fade beyond mid +/- N x ATR
input double FadeStopAtr           = 1.2;     // stop beyond the signal extreme
input double FadeMaxAdrUsed        = 0.60;    // skip if the day already ran; no fading trends
//==================== ADAPTIVE SELF-MONITOR =========================
input bool   UseAdaptiveSizing     = true;
input double EwmaAlpha             = 0.05;    // ~40 trade memory, ~2 months at 1/day
input double HalfSizeBelow         = 0.00;
input double StandDownBelow        = -0.25;
input double ReEnableAbove         = -0.10;
input int    MinTradesBeforeAdapt  = 30;
//==================== HARD RISK BREAKER =============================
input double DailyLossLimitPct     = 3.0;     // stop trading for the day
input int    MaxConsecLosses       = 5;       // stop trading for the day
input double MaxDrawdownPct        = 12.0;    // halt entirely until reset
input bool   ResetBreaker          = false;   // set TRUE once to clear a halt
//==================== MISC ==========================================
input int    MaxTradesPerDay       = 4;       // hard cap, both engines combined
input bool   PopupAlerts           = false;   // off by default at this frequency
input bool   PushAlerts            = false;
input bool   WriteJournal          = true;
input bool   ResetAdaptiveState    = false;

#define ENG_BREAK   0
#define ENG_FADE    1
#define NENG        2
#define TF          PERIOD_M15
#define STATE_KEYS  160

string JOURNAL   = "XVISION_EURUSD_v2_Journal.csv";
string STATEFILE = "XVISION_EURUSD_v2_State.csv";

//--- bar clock
datetime g_lastBar = 0;
datetime g_lastSelectWarn = 0;
int      g_offsetSec = 0;
double   g_pip = 0.0001;

//--- per-engine live slot
int      g_ticket[NENG];
double   g_entry[NENG], g_risk[NENG], g_stop[NENG], g_target[NENG];
datetime g_opened[NENG];
int      g_dir[NENG];

//--- per-engine shadow slot
bool     s_on[NENG];
int      s_dir[NENG];
double   s_entry[NENG], s_stop[NENG], s_target[NENG], s_risk[NENG];
datetime s_opened[NENG];

//--- simple key/value state store, file backed
string   k_key[STATE_KEYS];
double   k_val[STATE_KEYS];
int      k_n = 0;
bool     k_dirty = false;

//--- session cache, recomputed once per day
datetime g_sessDay   = 0;
double   g_rangeHi   = 0, g_rangeLo = 0, g_adr = 0;
bool     g_rangeOk   = false;

//+------------------------------------------------------------------+
//|                        STATE PERSISTENCE                         |
//| Terminal global variables were the wrong store in v1: shared      |
//| across accounts, expire after four weeks, lost on unclean exit.   |
//+------------------------------------------------------------------+
int StateIndex(string key)
{
   for(int i=0; i<k_n; i++) if(k_key[i]==key) return(i);
   if(k_n >= STATE_KEYS) return(-1);
   k_key[k_n] = key; k_val[k_n] = 0.0; k_n++;
   return(k_n-1);
}

double SGet(string key, double def=0.0)
{
   int i = StateIndex(key);
   if(i < 0) return(def);
   return(k_val[i]);
}

void SSet(string key, double v)
{
   int i = StateIndex(key);
   if(i < 0) return;
   if(k_val[i] == v) return;
   k_val[i] = v; k_dirty = true;
}

string StateFileName()
{
   return(StringConcatenate("XVISION_EURUSD_v2_State_",
          IntegerToString(AccountNumber()), "_", Symbol(), ".csv"));
}

void StateLoad()
{
   k_n = 0;
   string fn = StateFileName();
   if(!FileIsExist(fn)) return;
   int fh = FileOpen(fn, FILE_CSV|FILE_READ|FILE_SHARE_READ, ',');
   if(fh == INVALID_HANDLE) { Print("v2: could not read state file, starting clean."); return; }
   while(!FileIsEnding(fh) && k_n < STATE_KEYS)
   {
      string key = FileReadString(fh);
      if(FileIsEnding(fh) && StringLen(key)==0) break;
      double v = StringToDouble(FileReadString(fh));
      if(StringLen(key) > 0) { k_key[k_n] = key; k_val[k_n] = v; k_n++; }
   }
   FileClose(fh);
   Print("v2: state loaded, ", k_n, " keys.");
}

void StateFlush()
{
   if(!k_dirty) return;
   string fn = StateFileName();
   int fh = FileOpen(fn, FILE_CSV|FILE_WRITE|FILE_SHARE_READ, ',');
   if(fh == INVALID_HANDLE) { Print("v2: WARNING state file not writable, adaptive memory at risk."); return; }
   for(int i=0; i<k_n; i++) FileWrite(fh, k_key[i], DoubleToString(k_val[i], 8));
   FileClose(fh);
   k_dirty = false;
}

//+------------------------------------------------------------------+
//|                        TIME / SESSIONS                           |
//+------------------------------------------------------------------+
void DetectOffset()
{
   if(ServerGmtOffsetHours != 99) { g_offsetSec = ServerGmtOffsetHours*3600; return; }
   if(IsTesting() || IsOptimization())
   {
      g_offsetSec = 0;
      Print("v2: WARNING TimeGMT() is unreliable in the tester. ",
            "Assuming server = GMT. Set ServerGmtOffsetHours explicitly for a valid test.");
      return;
   }
   int diff = (int)(TimeCurrent() - TimeGMT());
   g_offsetSec = (int)(MathRound(diff/3600.0)*3600);
   Print("v2: detected server-GMT offset ", g_offsetSec/3600, "h. ",
         "Sessions are defined in GMT; verify this looks right for your broker.");
}

datetime ToGmt(datetime srv)    { return((datetime)(srv - g_offsetSec)); }
datetime ToServer(datetime gmt) { return((datetime)(gmt + g_offsetSec)); }
datetime GmtDay(datetime gmt)   { return((datetime)(gmt - (gmt % 86400))); }
int      GmtHour()              { return(TimeHour(ToGmt(TimeCurrent()))); }

//| Asian range for the CURRENT GMT day. Returns false until the      |
//| window has actually closed, and on days with too few bars.        |
bool BuildSession()
{
   datetime gNow = ToGmt(TimeCurrent());
   datetime day0 = GmtDay(gNow);

   if(g_sessDay == day0) return(g_rangeOk);   // already computed for today

   datetime aStart = day0 + AsianStartHour*3600;
   datetime aEnd   = day0 + AsianEndHour*3600;
   if(gNow < aEnd) return(false);             // window still open, nothing to measure

   g_sessDay = day0;
   g_rangeOk = false;

   int iEnd   = iBarShift(NULL, TF, ToServer(aEnd) - 1, false);
   int iStart = iBarShift(NULL, TF, ToServer(aStart), false);
   if(iEnd < 0 || iStart < 0 || iStart < iEnd) return(false);

   int count = iStart - iEnd + 1;
   if(count < MinAsianBars)
   {
      Print("v2: only ", count, " M15 bars in today's Asian window (need ",
            MinAsianBars, ") - standing aside for the day.");
      return(false);
   }

   g_rangeHi = iHigh(NULL, TF, iHighest(NULL, TF, MODE_HIGH, count, iEnd));
   g_rangeLo = iLow (NULL, TF, iLowest (NULL, TF, MODE_LOW,  count, iEnd));
   g_adr     = iATR(NULL, PERIOD_D1, 14, 1);

   if(g_adr <= 0 || g_rangeHi <= g_rangeLo) return(false);
   g_rangeOk = true;
   return(true);
}

double RangePips() { return((g_rangeHi - g_rangeLo)/g_pip); }
double AdrPips()   { return(g_adr/g_pip); }

//+------------------------------------------------------------------+
//|                          LIFECYCLE                               |
//+------------------------------------------------------------------+
int OnInit()
{
   string sym = Symbol(); StringToUpper(sym);
   if(StringFind(sym, "EURUSD") < 0)
   {
      Alert("v2: engines are reasoned for EURUSD only. Refusing to load on ", Symbol());
      return(INIT_FAILED);
   }

   g_pip = (Digits==5 || Digits==3) ? Point*10 : Point;

   DetectOffset();
   StateLoad();
   if(ResetAdaptiveState) ResetState();
   if(ResetBreaker)
   {
      SSet("HALTED", 0); SSet("PEAK_EQUITY", AccountEquity());
      Print("v2: risk breaker cleared, equity peak re-anchored.");
   }

   for(int e=0; e<NENG; e++)
   {
      g_ticket[e] = -1; s_on[e] = false;
      g_entry[e]=0; g_risk[e]=0; g_stop[e]=0; g_target[e]=0; g_dir[e]=0; g_opened[e]=0;
   }
   RecoverPositions();
   RecoverShadows();

   if(SGet("PEAK_EQUITY", 0) <= 0) SSet("PEAK_EQUITY", AccountEquity());

   // B1 fix: seed the bar clock so loading does NOT look like a new bar
   g_lastBar = iTime(NULL, TF, 0);

   if(WriteJournal && !FileIsExist(JOURNAL))
   {
      int fh = FileOpen(JOURNAL, FILE_CSV|FILE_WRITE|FILE_SHARE_READ, ',');
      if(fh != INVALID_HANDLE)
      {
         FileWrite(fh, "closed_gmt","engine","mode","dir","lots","entry","exit",
                       "entry_gmt","entry_hour","spread_pips","commission","swap",
                       "gross_R","net_R","ewma_live","ewma_shadow","range_pips",
                       "adr_pips","range_to_adr","exit_reason");
         FileClose(fh);
      }
   }

   StateFlush();
   EventSetTimer(10);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); StateFlush(); Comment(""); }
void OnTimer() { Engine(); }
void OnTick()  { Engine(); }

void Engine()
{
   ManagePositions();

   datetime b = iTime(NULL, TF, 0);
   if(b != g_lastBar) { g_lastBar = b; OnNewBar(); }

   Panel();
   StateFlush();
}

//+------------------------------------------------------------------+
//| Decided once per closed M15 bar                                  |
//+------------------------------------------------------------------+
void OnNewBar()
{
   if(iBars(NULL,TF) < FadeMidPeriod + 120) return;

   RollDay();
   UpdateShadows();
   UpdateEquityPeak();

   if(Halted()) return;
   if(!BuildSession()) return;

   int hour = GmtHour();

   if(UseBreakout && hour >= AsianEndHour && hour < BreakoutEndHour)
   {
      int d = BreakoutSignal();
      if(d != 0) HandleSignal(ENG_BREAK, d);
   }
   if(UseFade && hour >= AsianStartHour && hour < AsianEndHour)
   {
      int d = FadeSignal();
      if(d != 0) HandleSignal(ENG_FADE, d);
   }
}

//| Reset per-day counters when the GMT date changes.                 |
void RollDay()
{
   double today = (double)GmtDay(ToGmt(TimeCurrent()));
   if(SGet("DAY_STAMP", 0) == today) return;
   SSet("DAY_STAMP", today);
   SSet("DAY_TRADES", 0);
   SSet("DAY_PNL", 0);
   SSet("DAY_BLOCKED", 0);
   SSet("DAY_START_EQUITY", AccountEquity());
   SSet("CONSEC_LOSS", 0);
   for(int e=0; e<NENG; e++) SSet("DAY_DONE_"+IntegerToString(e), 0);
}

//+------------------------------------------------------------------+
//|              ENGINE A - LONDON BREAKOUT                          |
//| Tight Asian range + participation shift at the European open.    |
//+------------------------------------------------------------------+
int BreakoutSignal()
{
   if(SGet("DAY_DONE_"+IntegerToString(ENG_BREAK), 0) > 0.5) return(0);  // M5 fix: one per day
   if(g_ticket[ENG_BREAK] >= 0 || s_on[ENG_BREAK]) return(0);

   double ratio = RangePips()/AdrPips();
   if(ratio > MaxRangeToAdr || ratio < MinRangeToAdr) return(0);

   double atr = iATR(NULL, TF, 14, 1);
   if(atr <= 0) return(0);
   double buf = BreakBufferAtr*atr;

   double c = iClose(NULL, TF, 1);
   if(c > g_rangeHi + buf) return(1);
   if(c < g_rangeLo - buf) return(-1);
   return(0);
}

//+------------------------------------------------------------------+
//|              ENGINE B - ASIAN FADE                               |
//| Thin book, no size behind the extension. Fade back to the mean.  |
//+------------------------------------------------------------------+
int FadeSignal()
{
   if(g_ticket[ENG_FADE] >= 0 || s_on[ENG_FADE]) return(0);

   double atr = iATR(NULL, TF, 14, 1);
   double mid = iMA(NULL, TF, FadeMidPeriod, 0, MODE_SMA, PRICE_CLOSE, 1);
   double adr = iATR(NULL, PERIOD_D1, 14, 1);
   if(atr <= 0 || adr <= 0) return(0);

   // do not fade a day that is already trending hard
   double usedToday = (iHigh(NULL,PERIOD_D1,0) - iLow(NULL,PERIOD_D1,0))/adr;
   if(usedToday > FadeMaxAdrUsed) return(0);

   double c  = iClose(NULL, TF, 1);
   double cp = iClose(NULL, TF, 2);
   double midp = iMA(NULL, TF, FadeMidPeriod, 0, MODE_SMA, PRICE_CLOSE, 2);
   double atrp = iATR(NULL, TF, 14, 2);

   // one signal per excursion: previous bar must have been inside the band
   bool wasInside = (cp < midp + FadeBandAtr*atrp && cp > midp - FadeBandAtr*atrp);
   if(!wasInside) return(0);

   if(c > mid + FadeBandAtr*atr) return(-1);
   if(c < mid - FadeBandAtr*atr) return(1);
   return(0);
}

//+------------------------------------------------------------------+
//|                      SIGNAL ROUTING                              |
//+------------------------------------------------------------------+
void BuildLevels(int eng, int dir, double &entry, double &stop, double &target)
{
   double atr = iATR(NULL, TF, 14, 1);
   entry = Mid();

   if(eng == ENG_BREAK)
   {
      double opp = (dir>0) ? g_rangeLo : g_rangeHi;
      double cap = BreakStopAtrCap*atr;
      if(MathAbs(entry - opp) > cap) opp = entry - dir*cap;      // cap the risk
      stop   = opp;
      target = entry + dir*BreakRewardRisk*MathAbs(entry-stop);
   }
   else
   {
      double ext = (dir>0) ? iLow(NULL,TF,1) : iHigh(NULL,TF,1);
      stop   = ext - dir*FadeStopAtr*atr;
      target = iMA(NULL, TF, FadeMidPeriod, 0, MODE_SMA, PRICE_CLOSE, 1);
   }
}

//| B3 fix: refuse anything geometrically nonsensical before it       |
//| reaches the broker.                                               |
bool LevelsSane(int dir, double entry, double stop, double target)
{
   if(dir > 0 && !(stop < entry && target > entry)) return(false);
   if(dir < 0 && !(stop > entry && target < entry)) return(false);
   double riskPips = MathAbs(entry-stop)/g_pip;
   if(riskPips < 2.0*CostPips) return(false);   // edge cannot survive its own cost
   if(riskPips > 200.0)        return(false);
   return(true);
}

void HandleSignal(int eng, int dir)
{
   double entry, stop, target;
   BuildLevels(eng, dir, entry, stop, target);
   if(!LevelsSane(dir, entry, stop, target)) return;

   double risk = MathAbs(entry - stop);
   int    st   = EngineState(eng);
   double mult = (st==0) ? 1.0 : ((st==1) ? 0.5 : 0.0);

   string why = "";
   bool goLive = true;
   if(SignalOnly)                                  { goLive=false; why="SignalOnly"; }
   else if(st == 2)                                { goLive=false; why="engine stood down"; }
   else if(g_ticket[eng] >= 0)                     { goLive=false; why="engine slot busy"; }
   else if(SpreadPips() > MaxSpreadPips)           { goLive=false; why="spread "+DoubleToString(SpreadPips(),2); }
   else if(SGet("DAY_TRADES",0) >= MaxTradesPerDay){ goLive=false; why="daily trade cap"; }
   else if(DayBlocked())                           { goLive=false; why="risk breaker (day)"; }
   else if(!IsTradeAllowed())                      { goLive=false; why="trading not allowed"; }

   if(eng == ENG_BREAK) SSet("DAY_DONE_"+IntegerToString(ENG_BREAK), 1);

   // B4 fix: a live attempt that fails ALWAYS falls through to shadow,
   // so the adaptive sample never silently loses its hardest trades.
   if(goLive && OpenLive(eng, dir, stop, target, risk, mult)) return;
   if(goLive) why = "live order failed";

   OpenShadow(eng, dir, entry, stop, target, risk);
   Say(StringConcatenate("v2 ", EngName(eng), " ", (dir>0?"BUY":"SELL"),
       " SHADOW (", why, ")  entry ", DoubleToString(entry,Digits),
       " stop ", DoubleToString(stop,Digits), " target ", DoubleToString(target,Digits)));
}

//+------------------------------------------------------------------+
//|                     ORDER EXECUTION                              |
//| B3 fix in full: stop level, freeze level, retries, RefreshRates,  |
//| ECN fallback, free margin, explicit error reporting.              |
//+------------------------------------------------------------------+
bool OpenLive(int eng, int dir, double stop, double target, double risk, double mult)
{
   double lots = LotsForRisk(risk, mult);
   if(lots <= 0) { Print("v2: lots resolved to 0 for ", EngName(eng)); return(false); }

   int    type  = (dir>0) ? OP_BUY : OP_SELL;
   int    magic = MagicBase + eng;
   double stopLvl = MarketInfo(Symbol(), MODE_STOPLEVEL)*Point;
   double freeze  = MarketInfo(Symbol(), MODE_FREEZELEVEL)*Point;
   double minDist = MathMax(stopLvl, freeze);

   for(int attempt=0; attempt<OrderRetries; attempt++)
   {
      if(!IsTradeAllowed()) { Sleep(500); continue; }
      RefreshRates();

      double px = (dir>0) ? Ask : Bid;
      double sl = NormalizeDouble(stop,   Digits);
      double tp = NormalizeDouble(target, Digits);

      // broker minimum distance
      if(MathAbs(px - sl) < minDist || MathAbs(px - tp) < minDist)
      {
         Print("v2: ", EngName(eng), " levels inside broker stop level (",
               DoubleToString(minDist/g_pip,2), " pips) - skipping.");
         return(false);
      }
      // price may have moved through our own stop while we computed
      if((dir>0 && px <= sl) || (dir<0 && px >= sl))
      {
         Print("v2: ", EngName(eng), " price moved through stop before entry - skipping.");
         return(false);
      }
      if(AccountFreeMarginCheck(Symbol(), type, lots) <= 0)
      {
         Print("v2: insufficient free margin for ", DoubleToString(lots,2), " lots.");
         return(false);
      }

      int t = OrderSend(Symbol(), type, lots, px, SlippagePoints, sl, tp,
                        "XV2_"+IntegerToString(eng), magic, 0,
                        (dir>0)?clrDodgerBlue:clrTomato);
      if(t >= 0) { RegisterLive(eng, t, dir, px, sl, tp, risk); return(true); }

      int err = GetLastError();

      // ECN brokers reject SL/TP on the opening order - send bare, then modify
      if(err == 130 || err == 132 || err == 145)
      {
         RefreshRates();
         px = (dir>0) ? Ask : Bid;
         t = OrderSend(Symbol(), type, lots, px, SlippagePoints, 0, 0,
                       "XV2_"+IntegerToString(eng), magic, 0,
                       (dir>0)?clrDodgerBlue:clrTomato);
         if(t >= 0)
         {
            if(OrderSelect(t, SELECT_BY_TICKET) &&
               !OrderModify(t, OrderOpenPrice(), sl, tp, 0, clrNONE))
               Print("v2: WARNING opened ticket ", t, " but SL/TP not set, error ", GetLastError());
            RegisterLive(eng, t, dir, px, sl, tp, risk);
            return(true);
         }
         err = GetLastError();
      }

      Print("v2: OrderSend attempt ", attempt+1, " failed, error ", err);
      if(err==146 || err==136 || err==138 || err==135 || err==137)
         { Sleep(300*(attempt+1)); continue; }   // transient, back off and retry
      break;                                     // anything else will not fix itself
   }
   return(false);
}

void RegisterLive(int eng, int ticket, int dir, double px, double sl, double tp, double risk)
{
   // risk is measured from the fill we actually got, not the mid-price estimate
   // used for pre-flight sizing, so every R is denominated in real risk.
   if(OrderSelect(ticket, SELECT_BY_TICKET)) px = OrderOpenPrice();
   risk = MathAbs(px - sl);

   g_ticket[eng]=ticket; g_dir[eng]=dir; g_entry[eng]=px;
   g_stop[eng]=sl; g_target[eng]=tp; g_risk[eng]=risk; g_opened[eng]=TimeCurrent();

   string p = "LIVE_"+IntegerToString(eng)+"_";
   SSet(p+"TICKET", ticket); SSet(p+"DIR", dir);   SSet(p+"ENTRY", px);
   SSet(p+"STOP", sl);       SSet(p+"TARGET", tp); SSet(p+"RISK", risk);
   SSet(p+"OPENED", (double)TimeCurrent());
   SSet("DAY_TRADES", SGet("DAY_TRADES",0) + 1);
   SSet("SPREAD_AT_ENTRY_"+IntegerToString(eng), SpreadPips());
   StateFlush();

   Say(StringConcatenate("v2 ", EngName(eng), " ", (dir>0?"BUY":"SELL"), " LIVE ticket ", ticket,
       "  entry ", DoubleToString(px,Digits), "  stop ", DoubleToString(sl,Digits),
       "  target ", DoubleToString(tp,Digits),
       "  risk ", DoubleToString(MathAbs(px-sl)/g_pip,1), " pips"));
}

//+------------------------------------------------------------------+
//|                   POSITION MANAGEMENT                            |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int e=0; e<NENG; e++)
   {
      if(g_ticket[e] < 0) continue;
      if(!OrderSelect(g_ticket[e], SELECT_BY_TICKET))
      {
         // H7 fix: do NOT silently drop the result - but do not flood the log either
         if(TimeCurrent() - g_lastSelectWarn > 60)
         {
            g_lastSelectWarn = TimeCurrent();
            Print("v2: WARNING OrderSelect failed for ticket ", g_ticket[e], ", retrying.");
         }
         continue;
      }
      if(OrderCloseTime() == 0)
      {
         if(GmtHour() >= EngineFlatHour(e)) CloseLive(e, "session flat");
         continue;
      }
      BookLive(e);
   }
}

void CloseLive(int eng, string reason)
{
   if(!OrderSelect(g_ticket[eng], SELECT_BY_TICKET)) return;
   for(int attempt=0; attempt<OrderRetries; attempt++)
   {
      RefreshRates();
      double px = (OrderType()==OP_BUY) ? Bid : Ask;
      if(OrderClose(g_ticket[eng], OrderLots(), NormalizeDouble(px,Digits),
                    SlippagePoints, clrGray))
      { SSet("EXIT_REASON_"+IntegerToString(eng), 1); return; }
      int err = GetLastError();
      Print("v2: OrderClose attempt ", attempt+1, " failed, error ", err);
      if(err==146 || err==136 || err==138) { Sleep(300*(attempt+1)); continue; }
      break;
   }
}

//| Book a closed live trade NET of real commission and swap.         |
void BookLive(int eng)
{
   int    dir   = (OrderType()==OP_BUY) ? 1 : -1;
   double entry = OrderOpenPrice();
   double exit  = OrderClosePrice();
   double lots  = OrderLots();
   double comm  = OrderCommission();
   double swap  = OrderSwap();
   double risk  = g_risk[eng];

   if(risk <= 0)
   {
      // B5 fix: never fabricate R=0. Log it, exclude it from the EWMA.
      Print("v2: ERROR risk unknown for ticket ", g_ticket[eng],
            " - result EXCLUDED from adaptive stats.");
      JournalRow(eng, "LIVE-UNSCORED", dir, lots, entry, exit, comm, swap, 0, 0, "unknown risk");
      ClearLive(eng);
      return;
   }

   double grossR = (exit - entry)*dir / risk;
   double costCcy = -(comm + swap);          // both are charges (negative) in MT4
   double riskCcy = RiskMoney(risk, lots);
   double netR    = (riskCcy > 0) ? grossR - (costCcy/riskCcy) : grossR;

   RecordResult(eng, netR, true);
   SSet("DAY_PNL", SGet("DAY_PNL",0) + OrderProfit() + comm + swap);

   string reason = (SGet("EXIT_REASON_"+IntegerToString(eng),0) > 0.5) ? "session flat"
                 : (MathAbs(exit - g_target[eng]) < MathAbs(exit - g_stop[eng]) ? "target" : "stop");
   JournalRow(eng, "LIVE", dir, lots, entry, exit, comm, swap, grossR, netR, reason);
   ClearLive(eng);
}

void ClearLive(int eng)
{
   g_ticket[eng]=-1; g_risk[eng]=0; g_entry[eng]=0; g_dir[eng]=0; g_opened[eng]=0;
   string p = "LIVE_"+IntegerToString(eng)+"_";
   SSet(p+"TICKET", -1);
   SSet("EXIT_REASON_"+IntegerToString(eng), 0);
   StateFlush();
}

void RecoverPositions()
{
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol()) continue;
      int eng = OrderMagicNumber() - MagicBase;
      if(eng < 0 || eng >= NENG) continue;

      string p = "LIVE_"+IntegerToString(eng)+"_";
      g_ticket[eng] = OrderTicket();
      g_dir[eng]    = (OrderType()==OP_BUY) ? 1 : -1;
      g_entry[eng]  = OrderOpenPrice();
      g_stop[eng]   = OrderStopLoss();
      g_target[eng] = OrderTakeProfit();
      g_risk[eng]   = SGet(p+"RISK", 0);
      g_opened[eng] = (datetime)SGet(p+"OPENED", 0);

      // B6 fix: risk is recoverable from the live SL if state was lost
      if(g_risk[eng] <= 0 && OrderStopLoss() > 0)
      {
         g_risk[eng] = MathAbs(OrderOpenPrice() - OrderStopLoss());
         SSet(p+"RISK", g_risk[eng]);
         Print("v2: risk for ticket ", g_ticket[eng], " rebuilt from live stop loss.");
      }
      Print("v2: recovered ", EngName(eng), " ticket ", g_ticket[eng]);
   }
}

//+------------------------------------------------------------------+
//|                      SHADOW TRADES                               |
//| M2 fix: identical exit rules to the live path.                   |
//| M4 fix: persisted, so a restart does not discard them.           |
//+------------------------------------------------------------------+
void OpenShadow(int eng, int dir, double entry, double stop, double target, double risk)
{
   if(s_on[eng]) return;
   s_on[eng]=true; s_dir[eng]=dir; s_entry[eng]=entry;
   s_stop[eng]=stop; s_target[eng]=target; s_risk[eng]=risk; s_opened[eng]=TimeCurrent();

   string p = "SHDW_"+IntegerToString(eng)+"_";
   SSet(p+"ON",1); SSet(p+"DIR",dir); SSet(p+"ENTRY",entry);
   SSet(p+"STOP",stop); SSet(p+"TARGET",target); SSet(p+"RISK",risk);
   SSet(p+"OPENED",(double)TimeCurrent());
   StateFlush();
}

void RecoverShadows()
{
   for(int e=0; e<NENG; e++)
   {
      string p = "SHDW_"+IntegerToString(e)+"_";
      if(SGet(p+"ON",0) < 0.5) continue;
      s_on[e]=true;
      s_dir[e]    = (int)SGet(p+"DIR",0);
      s_entry[e]  = SGet(p+"ENTRY",0);
      s_stop[e]   = SGet(p+"STOP",0);
      s_target[e] = SGet(p+"TARGET",0);
      s_risk[e]   = SGet(p+"RISK",0);
      s_opened[e] = (datetime)SGet(p+"OPENED",0);
      if(s_risk[e] <= 0) { s_on[e]=false; SSet(p+"ON",0); continue; }
      Print("v2: recovered shadow trade for ", EngName(e));
   }
}

void UpdateShadows()
{
   double hi = iHigh(NULL,TF,1), lo = iLow(NULL,TF,1), cl = iClose(NULL,TF,1);

   for(int e=0; e<NENG; e++)
   {
      if(!s_on[e]) continue;
      int d = s_dir[e];

      bool hitStop = (d>0) ? (lo <= s_stop[e])   : (hi >= s_stop[e]);
      bool hitTgt  = (d>0) ? (hi >= s_target[e]) : (lo <= s_target[e]);
      bool flat    = (GmtHour() >= EngineFlatHour(e));  // identical to the live rule

      double exitPx; string reason;
      if(hitStop)     { exitPx = s_stop[e];   reason = "stop"; }
      else if(hitTgt) { exitPx = s_target[e]; reason = "target"; }
      else if(flat)   { exitPx = cl;          reason = "session flat"; }
      else continue;

      double grossR = (exitPx - s_entry[e])*d / s_risk[e];
      double netR   = grossR - (CostPips*g_pip)/s_risk[e];   // cost, explicitly

      RecordResult(e, netR, false);
      JournalRow(e, "SHADOW", d, 0, s_entry[e], exitPx, 0, 0, grossR, netR, reason);

      s_on[e] = false;
      SSet("SHDW_"+IntegerToString(e)+"_ON", 0);
   }
}

//+------------------------------------------------------------------+
//|                     THE ADAPTIVE CORE                            |
//| M1 fix: live and shadow expectancy are tracked SEPARATELY and    |
//| never pooled. Sizing follows live once live has enough data.     |
//+------------------------------------------------------------------+
void RecordResult(int eng, double netR, bool isLive)
{
   string tag = isLive ? "L" : "S";
   string kE  = "EWMA_"+tag+"_"+IntegerToString(eng);
   string kC  = "CNT_"+tag+"_"+IntegerToString(eng);
   string kS  = "SUM_"+tag+"_"+IntegerToString(eng);
   string kW  = "WIN_"+tag+"_"+IntegerToString(eng);

   double cnt  = SGet(kC, 0);
   double ewma = SGet(kE, 0);
   ewma = (cnt <= 0) ? netR : EwmaAlpha*netR + (1.0-EwmaAlpha)*ewma;

   SSet(kE, ewma);
   SSet(kC, cnt + 1);
   SSet(kS, SGet(kS,0) + netR);
   if(netR > 0) SSet(kW, SGet(kW,0) + 1);

   if(isLive)
   {
      if(netR < 0) SSet("CONSEC_LOSS", SGet("CONSEC_LOSS",0) + 1);
      else         SSet("CONSEC_LOSS", 0);
   }
   StateFlush();

   Print("v2 ", EngName(eng), " ", (isLive?"LIVE":"SHADOW"),
         " closed netR=", DoubleToString(netR,3),
         "  rolling ", DoubleToString(ewma,3),
         " over ", DoubleToString(cnt+1,0), "  state ", StateName(EngineState(eng)));
}

//| 0 full, 1 half, 2 stood down.                                     |
//| H1 fix: PURE. It reads state and never writes, alerts, or         |
//| notifies, so it is safe to call from the panel on every tick.     |
int EngineState(int eng)
{
   if(!UseAdaptiveSizing) return(0);

   string idx = IntegerToString(eng);
   double cntL = SGet("CNT_L_"+idx, 0);
   double cntS = SGet("CNT_S_"+idx, 0);

   // prefer live evidence; fall back to shadow while live is still thin
   bool   useLive = (cntL >= MinTradesBeforeAdapt);
   double cnt     = useLive ? cntL : cntS;
   double ewma    = useLive ? SGet("EWMA_L_"+idx,0) : SGet("EWMA_S_"+idx,0);

   if(cnt < MinTradesBeforeAdapt) return(0);

   bool down = (SGet("DOWN_"+idx, 0) > 0.5);
   if(down)  return(ewma > ReEnableAbove ? 1 : 2);
   if(ewma < StandDownBelow) return(2);
   if(ewma < HalfSizeBelow)  return(1);
   return(0);
}

//| Latch stand-down / re-enable transitions once per bar, where      |
//| writing state and alerting is appropriate.                        |
void UpdateEngineLatches()
{
   for(int e=0; e<NENG; e++)
   {
      string idx = IntegerToString(e);
      int    st  = EngineState(e);
      bool   was = (SGet("DOWN_"+idx,0) > 0.5);

      if(st == 2 && !was)
      { SSet("DOWN_"+idx, 1); Say("v2: "+EngName(e)+" STOOD DOWN - shadow trading only."); }
      else if(st != 2 && was)
      { SSet("DOWN_"+idx, 0); Say("v2: "+EngName(e)+" RE-ENABLED at half size."); }
   }
}

void ResetState()
{
   for(int e=0; e<NENG; e++)
   {
      string idx = IntegerToString(e);
      SSet("EWMA_L_"+idx,0); SSet("CNT_L_"+idx,0); SSet("SUM_L_"+idx,0); SSet("WIN_L_"+idx,0);
      SSet("EWMA_S_"+idx,0); SSet("CNT_S_"+idx,0); SSet("SUM_S_"+idx,0); SSet("WIN_S_"+idx,0);
      SSet("DOWN_"+idx,0);
   }
   Print("v2: adaptive state reset.");
}

//+------------------------------------------------------------------+
//|                    HARD RISK BREAKER                             |
//| The control the EWMA cannot be: it acts on equity, immediately.  |
//+------------------------------------------------------------------+
void UpdateEquityPeak()
{
   double eq = AccountEquity();
   if(eq > SGet("PEAK_EQUITY", 0)) SSet("PEAK_EQUITY", eq);

   double peak = SGet("PEAK_EQUITY", 0);
   if(peak > 0)
   {
      double dd = 100.0*(peak - eq)/peak;
      if(dd >= MaxDrawdownPct && SGet("HALTED",0) < 0.5)
      {
         SSet("HALTED", 1);
         Say(StringConcatenate("v2: HALTED - drawdown ", DoubleToString(dd,2),
             "% from peak equity. No further trading until ResetBreaker is set."));
      }
   }
   UpdateEngineLatches();
}

bool Halted() { return(SGet("HALTED",0) > 0.5); }

bool DayBlocked()
{
   if(SGet("DAY_BLOCKED",0) > 0.5) return(true);

   double startEq = SGet("DAY_START_EQUITY", 0);
   if(startEq > 0)
   {
      double lossPct = 100.0*(startEq - AccountEquity())/startEq;
      if(lossPct >= DailyLossLimitPct)
      {
         SSet("DAY_BLOCKED", 1);
         Say(StringConcatenate("v2: daily loss limit hit (", DoubleToString(lossPct,2),
             "%) - no further entries today."));
         return(true);
      }
   }
   if(SGet("CONSEC_LOSS",0) >= MaxConsecLosses)
   {
      SSet("DAY_BLOCKED", 1);
      Say("v2: "+DoubleToString(SGet("CONSEC_LOSS",0),0)+" consecutive losses - stopping for the day.");
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//|                        SIZING                                    |
//+------------------------------------------------------------------+
double RiskMoney(double slDist, double lots)
{
   double tv = MarketInfo(Symbol(), MODE_TICKVALUE);
   double ts = MarketInfo(Symbol(), MODE_TICKSIZE);
   if(tv<=0 || ts<=0) return(0);
   return(slDist/ts*tv*lots);
}

double LotsForRisk(double slDist, double mult)
{
   if(mult <= 0 || slDist <= 0) return(0);
   double tv = MarketInfo(Symbol(), MODE_TICKVALUE);
   double ts = MarketInfo(Symbol(), MODE_TICKSIZE);
   if(tv<=0 || ts<=0) return(0);

   double money  = AccountBalance()*BaseRiskPercent*mult/100.0;
   double perLot = slDist/ts*tv;
   if(perLot <= 0) return(0);

   // charge commission against the risk budget so 1% means 1%
   double commPerLot = MathAbs(CommissionPerLotRT);
   double lots = money/(perLot + commPerLot);

   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   double minL = MarketInfo(Symbol(), MODE_MINLOT);
   double maxL = MarketInfo(Symbol(), MODE_MAXLOT);
   if(step <= 0) step = 0.01;

   lots = MathFloor(lots/step)*step;
   if(lots < minL) return(0);
   if(lots > maxL) lots = maxL;

   return(NormalizeDouble(lots, LotDigits(step)));   // H5 fix: honour the real step
}

int LotDigits(double step)
{
   if(step >= 1.0)   return(0);
   if(step >= 0.1)   return(1);
   if(step >= 0.01)  return(2);
   return(3);
}

//| The fade thesis is "the Asian book is thin". Once London opens that
//| is no longer true, so the fade flattens at the session edge while the
//| breakout runs to FlatByHour.
int EngineFlatHour(int eng) { return(eng==ENG_FADE ? AsianEndHour : FlatByHour); }

double Mid()        { return((Ask + Bid)/2.0); }
double SpreadPips() { return((Ask - Bid)/g_pip); }

//+------------------------------------------------------------------+
//|                         JOURNAL                                  |
//| M8 fix: everything needed to reconcile against a backtest.       |
//+------------------------------------------------------------------+
void JournalRow(int eng, string mode, int dir, double lots, double entry, double exit,
                double comm, double swap, double grossR, double netR, string reason)
{
   if(!WriteJournal) return;
   int fh = FileOpen(JOURNAL, FILE_CSV|FILE_READ|FILE_WRITE|FILE_SHARE_READ, ',');
   if(fh == INVALID_HANDLE)
   { Print("v2: WARNING journal not writable (is the CSV open elsewhere?) - row lost."); return; }

   FileSeek(fh, 0, SEEK_END);
   datetime entryGmt = (mode == "SHADOW") ? ToGmt(s_opened[eng]) : ToGmt(g_opened[eng]);
   string idx = IntegerToString(eng);

   FileWrite(fh,
      TimeToString(ToGmt(TimeCurrent()), TIME_DATE|TIME_SECONDS),
      EngName(eng), mode, (dir>0?"BUY":"SELL"),
      DoubleToString(lots,2),
      DoubleToString(entry,Digits), DoubleToString(exit,Digits),
      TimeToString(entryGmt, TIME_DATE|TIME_SECONDS),
      IntegerToString(TimeHour(entryGmt)),
      DoubleToString(SGet("SPREAD_AT_ENTRY_"+idx, SpreadPips()), 2),
      DoubleToString(comm,2), DoubleToString(swap,2),
      DoubleToString(grossR,3), DoubleToString(netR,3),
      DoubleToString(SGet("EWMA_L_"+idx,0),3),
      DoubleToString(SGet("EWMA_S_"+idx,0),3),
      DoubleToString(RangePips(),1), DoubleToString(AdrPips(),1),
      DoubleToString(AdrPips()>0 ? RangePips()/AdrPips() : 0, 3),
      reason);
   FileClose(fh);
}

//+------------------------------------------------------------------+
//|                        REPORTING                                 |
//+------------------------------------------------------------------+
void Say(string msg)
{
   Print(msg);
   if(IsTesting() || IsOptimization()) return;    // H3 fix
   if(PopupAlerts) Alert(msg);
   if(PushAlerts)  SendNotification(StringSubstr(msg, 0, 250));
}

string EngName(int e)  { return(e==ENG_BREAK ? "LONDON-BREAKOUT" : "ASIAN-FADE"); }
string StateName(int s){ return(s==0 ? "FULL" : (s==1 ? "HALF" : "STOOD DOWN")); }

void Panel()
{
   if(IsOptimization()) return;

   double tot  = SGet("CNT_L_0",0)+SGet("CNT_L_1",0)+SGet("CNT_S_0",0)+SGet("CNT_S_1",0);

   string t = "XVISION EURUSD INTRADAY v2   " + (SignalOnly?"[SIGNAL-ONLY]":"[LIVE]");
   if(Halted()) t += "   *** HALTED ***";
   t += "\n";
   t += StringConcatenate("GMT ", IntegerToString(GmtHour()), ":00   spread ",
        DoubleToString(SpreadPips(),2), " pips   offset ", IntegerToString(g_offsetSec/3600), "h\n");

   if(g_rangeOk)
      t += StringConcatenate("Asian range ", DoubleToString(RangePips(),1),
           " pips = ", DoubleToString(AdrPips()>0?RangePips()/AdrPips():0,2),
           " x ADR   ", (AdrPips()>0 && RangePips()/AdrPips() <= MaxRangeToAdr ? "TIGHT - armed" : "too wide - no breakout"), "\n");
   else
      t += "Asian range: not yet complete\n";

   for(int e=0; e<NENG; e++)
   {
      string idx = IntegerToString(e);
      double cl=SGet("CNT_L_"+idx,0), cs=SGet("CNT_S_"+idx,0);
      t += StringConcatenate(EngName(e), ": ", StateName(EngineState(e)),
           "  live ", DoubleToString(cl,0), " @ ", DoubleToString(SGet("EWMA_L_"+idx,0),3), "R",
           "  shadow ", DoubleToString(cs,0), " @ ", DoubleToString(SGet("EWMA_S_"+idx,0),3), "R",
           "  net ", DoubleToString(SGet("SUM_L_"+idx,0),2), "R",
           (g_ticket[e]>=0 ? "  [OPEN #"+IntegerToString(g_ticket[e])+"]" : ""), "\n");
   }

   t += StringConcatenate("Today: ", DoubleToString(SGet("DAY_TRADES",0),0), "/",
        IntegerToString(MaxTradesPerDay), " trades   consec losses ",
        DoubleToString(SGet("CONSEC_LOSS",0),0), "/", IntegerToString(MaxConsecLosses),
        (DayBlockedQuiet() ? "   DAY BLOCKED" : ""), "\n");
   t += StringConcatenate("Signals recorded: ", DoubleToString(tot,0),
        "   (target >= 1/day - check this before trusting the frequency claim)\n");
   t += "All R values are NET of cost. Gross is in the journal.\n";
   Comment(t);
}

//| Panel-safe read: never mutates or alerts.                         |
bool DayBlockedQuiet() { return(SGet("DAY_BLOCKED",0) > 0.5); }
//+------------------------------------------------------------------+
