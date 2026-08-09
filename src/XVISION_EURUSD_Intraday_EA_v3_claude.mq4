//+------------------------------------------------------------------+
//| XVISION_EURUSD_Intraday_EA_v3_claude.mq4                           |
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
//|                                                                    |
//| FIXED IN THIS REVISION - all found by auditing v2 against itself   |
//|   * SGet ignored its own default: StateIndex created any missing   |
//|     key at 0.0, so the default never surfaced, reads mutated the   |
//|     store and consumed slots. Now a pure lookup.                   |
//|   * Flat-out compared GmtHour() >= N. Offline across the flat      |
//|     window, the hour wraps to a SMALLER number after midnight and  |
//|     the position leaks into the next session. Now an absolute      |
//|     stored deadline, on both the live and shadow paths.            |
//|   * The consecutive-loss breaker was unreachable: 4 live trades a  |
//|     day against a limit of 5, with the counter zeroed nightly. It  |
//|     now runs across days, and firing consumes it so the next day   |
//|     starts clean rather than livelocking permanently blocked.      |
//|   * A transient history gap at attach cached a dead session and    |
//|     killed the whole trading day. Only definitive verdicts cache.  |
//|   * Shadow trades never recorded their entry spread.               |
//|   * A second order sharing an engine magic was silently orphaned.  |
//|   * Per-trade state was left stale on the slot after a close.      |
//|   * ENGINE B WAS UNREACHABLE. OnNewBar gated the whole dispatch on |
//|     BuildSession(), which is false for the entire fade window by   |
//|     construction, so the fade fired on 0 of its 28 daily bars and  |
//|     the EA was a one-engine system. The range is an input to the   |
//|     breakout alone and now gates only that. A late-session entry   |
//|     guard came with it - a fade opening at 06:50 previously had a  |
//|     ten-minute leash before its own deadline.                      |
//|                                                                    |
//| EXPECTED FREQUENCY - estimated from structure, NOT measured        |
//|   Breakout needs range/ADR inside [0.12, 0.55] AND a break during  |
//|   07:00-11:00. Fade needs a 2.2 ATR excursion off the SMA on a day |
//|   that has not already run. Together I estimate roughly two days   |
//|   in three, NOT every day. The journal's date column is the only   |
//|   thing that will actually tell you - check it before trusting     |
//|   any frequency claim, including this one.                         |
//+------------------------------------------------------------------+
#property strict
#property description "EURUSD intraday adaptive EA - London breakout + Asian fade"
#property description "Ships in SignalOnly. Read the journal before going live."

enum LotSizingMode
{
   LOT_RISK_PERCENT,                          // Risk % of balance (auto)
   LOT_FIXED                                  // Fixed lots (manual)
};

//==================== EXECUTION =====================================
input bool   SignalOnly            = true;    // TRUE = journal + alerts only, no orders
//--- sizing: pick ONE mode. The adaptive multiplier applies to both, so a
//--- stood-down engine still trades nothing and a halved engine still halves.
input LotSizingMode LotMode        = LOT_RISK_PERCENT;
input double BaseRiskPercent       = 0.75;    // LOT_RISK_PERCENT: risk per trade
input double FixedLots             = 0.10;    // LOT_FIXED: lots per trade
//--- stops: 0 = let the engine derive it (recommended - the breakout stop IS
//--- the Asian range, which is the whole thesis). A number overrides it.
input double StopLossPips          = 0;       // 0 = engine, else fixed pips
input double TakeProfitPips        = 0;       // 0 = engine, else fixed pips
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
input int    MinMinutesBeforeFlat  = 60;      // refuse entries with no room left to work
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

string JOURNAL   = "XVISION_EURUSD_v3_claude_Journal.csv";

//--- bar clock
datetime g_lastBar = 0;
datetime g_lastSelectWarn = 0;
string   g_exitReason[NENG];
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

//| PURE lookup. Deliberately does NOT create the key: a read must never
//| mutate the store, must never consume a slot, and must actually return
//| the caller's default when the key is absent.
double SGet(string key, double def=0.0)
{
   for(int i=0; i<k_n; i++) if(k_key[i]==key) return(k_val[i]);
   return(def);
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
   return(StringConcatenate("XVISION_EURUSD_v3_claude_State_",
          IntegerToString(AccountNumber()), "_", Symbol(), ".csv"));
}

void StateLoad()
{
   k_n = 0;
   string fn = StateFileName();
   if(!FileIsExist(fn)) return;
   int fh = FileOpen(fn, FILE_CSV|FILE_READ|FILE_SHARE_READ, ',');
   if(fh == INVALID_HANDLE) { Print("claude-v3: could not read state file, starting clean."); return; }
   while(!FileIsEnding(fh) && k_n < STATE_KEYS)
   {
      string key = FileReadString(fh);
      if(FileIsEnding(fh) && StringLen(key)==0) break;
      double v = StringToDouble(FileReadString(fh));
      if(StringLen(key) > 0) { k_key[k_n] = key; k_val[k_n] = v; k_n++; }
   }
   FileClose(fh);
   Print("claude-v3: state loaded, ", k_n, " keys.");
}

void StateFlush()
{
   if(!k_dirty) return;
   string fn = StateFileName();
   int fh = FileOpen(fn, FILE_CSV|FILE_WRITE|FILE_SHARE_READ, ',');
   if(fh == INVALID_HANDLE) { Print("claude-v3: WARNING state file not writable, adaptive memory at risk."); return; }
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
      Print("claude-v3: WARNING TimeGMT() is unreliable in the tester. ",
            "Assuming server = GMT. Set ServerGmtOffsetHours explicitly for a valid test.");
      return;
   }
   int diff = (int)(TimeCurrent() - TimeGMT());
   g_offsetSec = (int)(MathRound(diff/3600.0)*3600);
   Print("claude-v3: detected server-GMT offset ", g_offsetSec/3600, "h. ",
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

   // Do NOT stamp g_sessDay yet. History may still be downloading right
   // after attach; caching a failure here would mark the day dead and never
   // retry it. Only a definitive verdict gets cached.
   int iEnd   = iBarShift(NULL, TF, ToServer(aEnd) - 1, false);
   int iStart = iBarShift(NULL, TF, ToServer(aStart), false);
   if(iEnd < 0 || iStart < 0 || iStart < iEnd) return(false);   // transient, retry next bar

   g_sessDay = day0;
   g_rangeOk = false;

   int count = iStart - iEnd + 1;
   if(count < MinAsianBars)
   {
      Print("claude-v3: only ", count, " M15 bars in today's Asian window (need ",
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

//| True only when the cached range belongs to the CURRENT GMT day.
bool   SessionFresh() { return(g_rangeOk && g_sessDay == GmtDay(ToGmt(TimeCurrent()))); }
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
      Alert("claude-v3: engines are reasoned for EURUSD only. Refusing to load on ", Symbol());
      return(INIT_FAILED);
   }

   g_pip = (Digits==5 || Digits==3) ? Point*10 : Point;

   DetectOffset();
   StateLoad();
   if(ResetAdaptiveState) ResetState();
   if(ResetBreaker)
   {
      SSet("HALTED", 0); SSet("PEAK_EQUITY", AccountEquity());
      Print("claude-v3: risk breaker cleared, equity peak re-anchored.");
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

void OnDeinit(const int reason) { EventKillTimer(); StateFlush(); PanelDestroy(); Comment(""); }
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

   int hour = GmtHour();

   // Refresh the cached range every bar, not only inside the breakout
   // window - otherwise the panel reports "not yet complete" all afternoon.
   // Cached per day, so this is one cheap call after the first success.
   BuildSession();

   // The fade runs DURING the Asian window and needs no range - it is
   // banded off an SMA. It must not be gated on BuildSession(), which is
   // false for that whole window by construction.
   if(UseFade && hour >= AsianStartHour && hour < AsianEndHour)
   {
      int d = FadeSignal();
      if(d != 0) HandleSignal(ENG_FADE, d);
   }
   // The breakout needs the completed range, so it alone is gated on it.
   if(UseBreakout && hour >= AsianEndHour && hour < BreakoutEndHour && SessionFresh())
   {
      int d = BreakoutSignal();
      if(d != 0) HandleSignal(ENG_BREAK, d);
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

   // manual overrides, applied after the engine has spoken. R accounting stays
   // correct either way because R is measured from the stop actually used.
   if(StopLossPips   > 0) stop   = entry - dir*StopLossPips*g_pip;
   if(TakeProfitPips > 0) target = entry + dir*TakeProfitPips*g_pip;
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
   // a trade needs room to work: refuse one its own session deadline
   // would flatten almost immediately
   if(FlatDeadline(eng, TimeCurrent()) - TimeCurrent() < MinMinutesBeforeFlat*60) return;

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
   Say(StringConcatenate("claude-v3 ", EngName(eng), " ", (dir>0?"BUY":"SELL"),
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
   if(lots <= 0) { Print("claude-v3: lots resolved to 0 for ", EngName(eng)); return(false); }

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
         Print("claude-v3: ", EngName(eng), " levels inside broker stop level (",
               DoubleToString(minDist/g_pip,2), " pips) - skipping.");
         return(false);
      }
      // price may have moved through our own stop while we computed
      if((dir>0 && px <= sl) || (dir<0 && px >= sl))
      {
         Print("claude-v3: ", EngName(eng), " price moved through stop before entry - skipping.");
         return(false);
      }
      if(AccountFreeMarginCheck(Symbol(), type, lots) <= 0)
      {
         Print("claude-v3: insufficient free margin for ", DoubleToString(lots,2), " lots.");
         return(false);
      }

      int t = OrderSend(Symbol(), type, lots, px, SlippagePoints, sl, tp,
                        "XV3claude_"+IntegerToString(eng), magic, 0,
                        (dir>0)?clrDodgerBlue:clrTomato);
      if(t >= 0) { RegisterLive(eng, t, dir, px, sl, tp, risk); return(true); }

      int err = GetLastError();

      // ECN brokers reject SL/TP on the opening order - send bare, then modify
      if(err == 130 || err == 132 || err == 145)
      {
         RefreshRates();
         px = (dir>0) ? Ask : Bid;
         t = OrderSend(Symbol(), type, lots, px, SlippagePoints, 0, 0,
                       "XV3claude_"+IntegerToString(eng), magic, 0,
                       (dir>0)?clrDodgerBlue:clrTomato);
         if(t >= 0)
         {
            if(OrderSelect(t, SELECT_BY_TICKET) &&
               !OrderModify(t, OrderOpenPrice(), sl, tp, 0, clrNONE))
               Print("claude-v3: WARNING opened ticket ", t, " but SL/TP not set, error ", GetLastError());
            RegisterLive(eng, t, dir, px, sl, tp, risk);
            return(true);
         }
         err = GetLastError();
      }

      Print("claude-v3: OrderSend attempt ", attempt+1, " failed, error ", err);
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
   SSet(p+"DEADLINE", (double)FlatDeadline(eng, TimeCurrent()));
   SSet(p+"SPREAD", SpreadPips());
   SSet("DAY_TRADES", SGet("DAY_TRADES",0) + 1);
   StateFlush();

   Say(StringConcatenate("claude-v3 ", EngName(eng), " ", (dir>0?"BUY":"SELL"), " LIVE ticket ", ticket,
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
            Print("claude-v3: WARNING OrderSelect failed for ticket ", g_ticket[e], ", retrying.");
         }
         continue;
      }
      if(OrderCloseTime() == 0)
      {
         double dl = SGet("LIVE_"+IntegerToString(e)+"_DEADLINE", 0);
         if(dl > 0 && TimeCurrent() >= (datetime)dl) CloseLive(e, "session flat");
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
      { g_exitReason[eng] = reason; SSet("EXIT_REASON_"+IntegerToString(eng), 1); return; }
      int err = GetLastError();
      Print("claude-v3: OrderClose attempt ", attempt+1, " failed, error ", err);
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
      Print("claude-v3: ERROR risk unknown for ticket ", g_ticket[eng],
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

   string reason;
   if(SGet("EXIT_REASON_"+IntegerToString(eng),0) > 0.5)
      reason = (StringLen(g_exitReason[eng]) > 0 ? g_exitReason[eng] : "session flat");
   else if(g_target[eng] <= 0 || g_stop[eng] <= 0)
      reason = "closed, levels unknown";          // do not guess from absent levels
   else
      reason = (MathAbs(exit - g_target[eng]) < MathAbs(exit - g_stop[eng]) ? "target" : "stop");
   JournalRow(eng, "LIVE", dir, lots, entry, exit, comm, swap, grossR, netR, reason);
   ClearLive(eng);
}

void ClearLive(int eng)
{
   g_ticket[eng]=-1; g_risk[eng]=0; g_entry[eng]=0; g_dir[eng]=0; g_opened[eng]=0;
   string p = "LIVE_"+IntegerToString(eng)+"_";
   SSet(p+"TICKET", -1);   SSet(p+"RISK", 0);     SSet(p+"ENTRY", 0);
   SSet(p+"STOP", 0);      SSet(p+"TARGET", 0);   SSet(p+"DEADLINE", 0);
   SSet("EXIT_REASON_"+IntegerToString(eng), 0);
   g_exitReason[eng] = "";
   g_stop[eng] = 0; g_target[eng] = 0;
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

      // two orders on one engine magic: the slot can only hold one, and
      // silently overwriting it would orphan the other from all management.
      if(g_ticket[eng] >= 0)
      {
         Print("claude-v3: WARNING ", EngName(eng), " has more than one open order (",
               g_ticket[eng], " and ", OrderTicket(), "). Slot keeps ", g_ticket[eng],
               "; close the extra manually - it is NOT being managed.");
         continue;
      }

      string p = "LIVE_"+IntegerToString(eng)+"_";
      g_ticket[eng] = OrderTicket();
      g_dir[eng]    = (OrderType()==OP_BUY) ? 1 : -1;
      g_entry[eng]  = OrderOpenPrice();
      g_stop[eng]   = OrderStopLoss();
      g_target[eng] = OrderTakeProfit();
      g_risk[eng]   = SGet(p+"RISK", 0);
      g_opened[eng] = (datetime)SGet(p+"OPENED", 0);

      if(SGet(p+"DEADLINE",0) <= 0)
         SSet(p+"DEADLINE", (double)FlatDeadline(eng,
              g_opened[eng] > 0 ? g_opened[eng] : TimeCurrent()));

      // B6 fix: risk is recoverable from the live SL if state was lost
      if(g_risk[eng] <= 0 && OrderStopLoss() > 0)
      {
         g_risk[eng] = MathAbs(OrderOpenPrice() - OrderStopLoss());
         SSet(p+"RISK", g_risk[eng]);
         Print("claude-v3: risk for ticket ", g_ticket[eng], " rebuilt from live stop loss.");
      }
      Print("claude-v3: recovered ", EngName(eng), " ticket ", g_ticket[eng]);
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
   SSet(p+"DEADLINE",(double)FlatDeadline(eng, TimeCurrent()));
   SSet(p+"SPREAD", SpreadPips());
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
      if(SGet(p+"DEADLINE",0) <= 0)
         SSet(p+"DEADLINE", (double)FlatDeadline(e,
              s_opened[e] > 0 ? s_opened[e] : TimeCurrent()));
      Print("claude-v3: recovered shadow trade for ", EngName(e));
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
      double dlS   = SGet("SHDW_"+IntegerToString(e)+"_DEADLINE", 0);
      bool flat    = (dlS > 0 && TimeCurrent() >= (datetime)dlS);  // identical to live

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
      SSet("SHDW_"+IntegerToString(e)+"_DEADLINE", 0);
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

   Print("claude-v3 ", EngName(eng), " ", (isLive?"LIVE":"SHADOW"),
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
      { SSet("DOWN_"+idx, 1); Say("claude-v3: "+EngName(e)+" STOOD DOWN - shadow trading only."); }
      else if(st != 2 && was)
      { SSet("DOWN_"+idx, 0); Say("claude-v3: "+EngName(e)+" RE-ENABLED at half size."); }
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
   Print("claude-v3: adaptive state reset.");
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
         Say(StringConcatenate("claude-v3: HALTED - drawdown ", DoubleToString(dd,2),
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
         Say(StringConcatenate("claude-v3: daily loss limit hit (", DoubleToString(lossPct,2),
             "%) - no further entries today."));
         return(true);
      }
   }
   // NOT reset by RollDay: at <=4 live trades/day a nightly reset made this
   // limit mathematically unreachable. It now runs across days, and the
   // block consumes it so tomorrow starts clean instead of livelocking.
   if(SGet("CONSEC_LOSS",0) >= MaxConsecLosses)
   {
      SSet("DAY_BLOCKED", 1);
      Say("claude-v3: "+DoubleToString(SGet("CONSEC_LOSS",0),0)+" consecutive losses - stopping for the day.");
      SSet("CONSEC_LOSS", 0);
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
   if(mult <= 0) return(0);

   double lots;
   if(LotMode == LOT_FIXED)
   {
      // adaptive de-risking still applies in manual mode: half means half
      lots = FixedLots*mult;
   }
   else
   {
      if(slDist <= 0) return(0);
      double tv = MarketInfo(Symbol(), MODE_TICKVALUE);
      double ts = MarketInfo(Symbol(), MODE_TICKSIZE);
      if(tv<=0 || ts<=0) return(0);

      double money  = AccountBalance()*BaseRiskPercent*mult/100.0;
      double perLot = slDist/ts*tv;
      if(perLot <= 0) return(0);

      // charge commission against the risk budget so 1% means 1%
      lots = money/(perLot + MathAbs(CommissionPerLotRT));
   }

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

//| Absolute flat-out instant for a trade opened at openedSrv. Comparing
//| against a stored timestamp instead of "GmtHour() >= N" is what stops a
//| position surviving its own flat window by being offline across it and
//| then reading a SMALLER hour number after midnight.
datetime FlatDeadline(int eng, datetime openedSrv)
{
   datetime gOpen = ToGmt(openedSrv);
   datetime dl    = GmtDay(gOpen) + EngineFlatHour(eng)*3600;
   if(dl <= gOpen) dl += 86400;
   return(ToServer(dl));
}

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
   { Print("claude-v3: WARNING journal not writable (is the CSV open elsewhere?) - row lost."); return; }

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
      DoubleToString(SGet((mode=="SHADOW"?"SHDW_":"LIVE_")+idx+"_SPREAD", SpreadPips()), 2),
      DoubleToString(comm,2), DoubleToString(swap,2),
      DoubleToString(grossR,3), DoubleToString(netR,3),
      DoubleToString(SGet("EWMA_L_"+idx,0),3),
      DoubleToString(SGet("EWMA_S_"+idx,0),3),
      SessionFresh() ? DoubleToString(RangePips(),1) : "0",
      DoubleToString(AdrPips(),1),
      SessionFresh() && AdrPips()>0 ? DoubleToString(RangePips()/AdrPips(),3) : "0",
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

//+------------------------------------------------------------------+
//|                     ON-CHART PANEL                               |
//| Comment() paints transparent text that fights the candles for    |
//| legibility. This builds the panel from chart objects instead: an |
//| opaque filled rectangle with labels on top, so it stays readable |
//| whatever the price action does underneath it.                    |
//+------------------------------------------------------------------+
#define PFX      "xv3c_"
#define PAN_X    8
#define PAN_Y    18
#define PAN_W    352
#define ROW_H    13
#define TITLE_H  21
#define NROWS    16

#define C_BG     C'22,26,34'
#define C_TITLE  C'33,41,56'
#define C_BORDER C'62,72,90'
#define C_HEAD   C'236,241,248'
#define C_DIM    C'130,142,162'
#define C_VAL    C'220,227,238'
#define C_GOOD   C'86,200,130'
#define C_BAD    C'232,96,96'
#define C_WARN   C'233,176,72'
#define C_LIVE   C'96,170,255'

void PBox(string id, int x, int y, int w, int h, color bg, color brd)
{
   string nm = PFX+id;
   if(ObjectFind(0, nm) < 0)
   {
      ObjectCreate(0, nm, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_BACK,        false);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN,      true);
      ObjectSetInteger(0, nm, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   }
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, nm, OBJPROP_XSIZE,     w);
   ObjectSetInteger(0, nm, OBJPROP_YSIZE,     h);
   ObjectSetInteger(0, nm, OBJPROP_BGCOLOR,   bg);
   ObjectSetInteger(0, nm, OBJPROP_COLOR,     brd);
}

void PTxt(string id, int x, int y, string txt, color c, int size=8)
{
   string nm = PFX+id;
   if(ObjectFind(0, nm) < 0)
   {
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_BACK,       false);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN,     true);
      ObjectSetString (0, nm, OBJPROP_FONT,       "Consolas");
   }
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE,  size);
   ObjectSetInteger(0, nm, OBJPROP_COLOR,     c);
   ObjectSetString (0, nm, OBJPROP_TEXT,      txt);
}

void PRow(int row, string left, string right, color c)
{
   int y = PAN_Y + TITLE_H + 5 + row*ROW_H;
   PTxt("l"+IntegerToString(row), PAN_X+10,  y, left,  C_DIM);
   PTxt("v"+IntegerToString(row), PAN_X+112, y, right, c);
}

void PanelDestroy()
{
   for(int i=ObjectsTotal(0,-1,-1)-1; i>=0; i--)
   {
      string nm = ObjectName(0, i);
      if(StringFind(nm, PFX) == 0) ObjectDelete(0, nm);
   }
   ChartRedraw();
}

string Pad2(int v) { return(v<10 ? "0"+IntegerToString(v) : IntegerToString(v)); }

void Panel()
{
   if(IsOptimization()) return;

   PBox("bg",    PAN_X, PAN_Y, PAN_W, TITLE_H + NROWS*ROW_H + 12, C_BG, C_BORDER);
   PBox("title", PAN_X, PAN_Y, PAN_W, TITLE_H, C_TITLE, C_BORDER);

   string st  = Halted() ? "HALTED" : (SignalOnly ? "SIGNAL-ONLY" : "LIVE");
   color  stc = Halted() ? C_BAD    : (SignalOnly ? C_WARN        : C_LIVE);
   PTxt("t1", PAN_X+10,     PAN_Y+4, "XVISION EURUSD  v3 (claude)", C_HEAD, 9);
   PTxt("t2", PAN_X+PAN_W-92, PAN_Y+4, st, stc, 9);

   int r = 0;
   PRow(r++, "Session", StringConcatenate("GMT ", Pad2(GmtHour()), ":00    offset ",
             (g_offsetSec>=0?"+":""), IntegerToString(g_offsetSec/3600), "h"), C_VAL);

   double sp = SpreadPips();
   PRow(r++, "Spread", StringConcatenate(DoubleToString(sp,2), " pips    cap ",
             DoubleToString(MaxSpreadPips,2)), sp > MaxSpreadPips ? C_BAD : C_VAL);

   string rng; color rc;
   if(SessionFresh())
   {
      double ratio = (AdrPips()>0) ? RangePips()/AdrPips() : 0;
      bool armed = (ratio <= MaxRangeToAdr && ratio >= MinRangeToAdr);
      rng = StringConcatenate(DoubleToString(RangePips(),1), "p = ",
            DoubleToString(ratio,2), " ADR   ", armed ? "ARMED" : "no setup");
      rc  = armed ? C_GOOD : C_DIM;
   }
   else if(GmtHour() < AsianEndHour)
   { rng = StringConcatenate("forming, closes ", Pad2(AsianEndHour), ":00 GMT"); rc = C_DIM; }
   else
   { rng = "unavailable - too few bars today"; rc = C_WARN; }
   PRow(r++, "Asian range", rng, rc);

   PRow(r++, "", "", C_DIM);

   for(int e=0; e<NENG; e++)
   {
      string idx = IntegerToString(e);
      int    es  = EngineState(e);
      color  ec  = (es==0) ? C_GOOD : (es==1 ? C_WARN : C_BAD);
      string tag = (g_ticket[e]>=0) ? "   OPEN #"+IntegerToString(g_ticket[e])
                                    : (s_on[e] ? "   shadow open" : "");
      PRow(r++, EngName(e), StateName(es)+tag, ec);

      double nl = SGet("SUM_L_"+idx,0), ns = SGet("SUM_S_"+idx,0);
      PRow(r++, "  live", StringConcatenate(DoubleToString(SGet("CNT_L_"+idx,0),0),
                " tr   ewma ", DoubleToString(SGet("EWMA_L_"+idx,0),3),
                "   net ", DoubleToString(nl,2), "R"),
                nl>0 ? C_GOOD : (nl<0 ? C_BAD : C_VAL));
      PRow(r++, "  shadow", StringConcatenate(DoubleToString(SGet("CNT_S_"+idx,0),0),
                " tr   ewma ", DoubleToString(SGet("EWMA_S_"+idx,0),3),
                "   net ", DoubleToString(ns,2), "R"),
                ns>0 ? C_GOOD : (ns<0 ? C_BAD : C_VAL));
   }

   PRow(r++, "", "", C_DIM);

   bool blocked = DayBlockedQuiet();
   PRow(r++, "Today", StringConcatenate(DoubleToString(SGet("DAY_TRADES",0),0), "/",
             IntegerToString(MaxTradesPerDay), " trades    consec ",
             DoubleToString(SGet("CONSEC_LOSS",0),0), "/", IntegerToString(MaxConsecLosses),
             blocked ? "    BLOCKED" : ""), blocked ? C_BAD : C_VAL);

   PRow(r++, "Sizing", (LotMode==LOT_FIXED)
             ? StringConcatenate("fixed ", DoubleToString(FixedLots,2), " lots")
             : StringConcatenate("risk ", DoubleToString(BaseRiskPercent,2), "% of balance"),
             C_VAL);

   bool manual = (StopLossPips > 0 || TakeProfitPips > 0);
   PRow(r++, "Stops", StringConcatenate(
             StopLossPips   > 0 ? "SL "+DoubleToString(StopLossPips,1)+"p" : "SL engine",
             "    ",
             TakeProfitPips > 0 ? "TP "+DoubleToString(TakeProfitPips,1)+"p" : "TP engine"),
             manual ? C_WARN : C_VAL);

   double tot = SGet("CNT_L_0",0)+SGet("CNT_L_1",0)+SGet("CNT_S_0",0)+SGet("CNT_S_1",0);
   PRow(r++, "Signals", StringConcatenate(DoubleToString(tot,0),
             " recorded    target >= 1/day"), C_VAL);

   PRow(r++, "", "all R is NET of cost - gross is in the journal", C_DIM);

   ChartRedraw();
}

//| Panel-safe read: never mutates or alerts.                         |
bool DayBlockedQuiet() { return(SGet("DAY_BLOCKED",0) > 0.5); }
//+------------------------------------------------------------------+
