//+------------------------------------------------------------------+
//| Xvision_consolidated_scraper_v2.mq4                              |
//| Complete GoldScalper M1/M5 v11 and SuperScalper v5 engines.      |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "XVISION Consolidated Scraper V2: complete Version 11 and SuperScalper v5 engines."

enum XvisionConsolidatedEngine
  {
   XVISION_GOLDSCALPER_V11=0,
   XVISION_SUPERSCALPER_V5=1
  };

input XvisionConsolidatedEngine ActiveEngine=XVISION_GOLDSCALPER_V11;

// ================= GoldScalper M1/M5 Version 11 =================
//+------------------------------------------------------------------+
//| GoldScalperM1M5_Version11.mq4                                      |
//| M1/M5 gold entry engine. It decides WHEN to enter; the user owns   |
//| the trade once it is open.                                         |
//|                                                                    |
//| EXITS ARE YOURS. The EA closes nothing on its own: no time stop,   |
//| no fast cut, no confirm-or-scratch, no reversal exit. A position   |
//| ends on your stop loss, your take profit, your profit lock or      |
//| your trailing stop - or when you close it by hand.                 |
//|                                                                    |
//| The Inputs tab carries your trade management plus the three entry  |
//| limits you asked to control: spread ceiling, daily trade cap and   |
//| the consecutive-loss pause. The signal engine and regime router    |
//| remain frozen constants below.                                     |
//|                                                                    |
//| All *_PriceUSD values are absolute Gold price movements            |
//| (2.50 means $2.50 of XAUUSD price).                                |
//|                                                                    |
//| Lineage (see /reference in the repo): execution layer from         |
//| XVISION Gold Velocity V7; five-mode regime engine and CUSUM burst  |
//| detector from GoldSeekAdaptiveEA v3; big-bar veto and blocker      |
//| panel from RegimeTrailPro; ER gate and fade template from          |
//| KeltnerFade. Decisions use CLOSED M1 bars with CLOSED M5 context   |
//| only.                                                              |
//|                                                                    |
//| Arming: the EA trades whenever MT4's AutoTrading is on and the     |
//| chart's "Allow live trading" box is ticked. Attach with            |
//| AutoTrading OFF to observe signals without trading.                |
//+------------------------------------------------------------------+
// Version numbering: the file name and #property version step up on
// every change. Version 11 = this build.
//
// v11.00: Audit fixes. Trades the EA closes itself now reach the trade
//         dataset instead of only the event ledger; excursion
//         persistence writes two keys instead of nineteen; peak/dip
//         keep updating while a stop repair is failing; the spread
//         recorded at entry is the one actually paid after an ECN
//         re-quote; stale header text describing removed exits fixed.
// v10.00: Audit fixes for v9. The bar-history requirement now covers
//         the trend EMA, so an armed filter can no longer sit silently
//         blocked on a short chart; the adverse excursion is carried
//         across a ticket change explicitly instead of by accident;
//         the panel shows ATR M5 and expansion again alongside the
//         trend; and the slope input documents what 0 actually does.
// v9.00: M5 trend filter. A slow EMA on M5 (50 by default) gives the
//        directional bias the engine never had: the EMA20/30 ribbon it
//        already carried is far too fast to hold a bias through a
//        multi-hour trend. Three modes - off, block trades against the
//        trend, or additionally require price to be near the line
//        (pullback entries only). Recorded in the trade dataset so its
//        effect can be measured after the fact.
// v8.00: Instrumentation only - no trading behaviour changed. Each
//        trade now records its maximum favourable and adverse
//        excursion plus the fifteen engine readings that were live at
//        entry, written to a per-trade dataset CSV on close. That
//        answers the question the event ledger could not: were the
//        losers wrong calls, or right calls stopped out by noise?
// v7.00: Audit fixes. The orphan sweep no longer deletes the persisted
//        cooldown; a ticket change (partial close) journals the old
//        ticket and carries the high-water mark forward so the lock and
//        trail keep their reference; a failed send is journalled;
//        coherence is computed once; dead signal state removed.
// v6.00: GSV11_MaxShockExhaustion now uses 0 = off, matching every other
//        gate. No other behaviour changed.
// v5.00: The entry engine is no longer mine. Every gate that can block
//        an entry is an input with a documented off switch, and the
//        defaults are permissive - the gates that contradicted each
//        other (move maturity, big-bar veto, shock ceiling, impulse
//        floor, M5 alignment) ship OFF. The panel names every failing
//        gate instead of only the first, and GSV11_LogGateDiagnostics writes
//        one row per blocked bar so the stack is tuned from counts
//        rather than opinion.
// v4.00: Defect fixes only, no change to the trading rules -
//        broker-side exits are now journalled to the ledger; the
//        broker's minimum stop distance is honoured when placing SL/TP
//        instead of letting the order be rejected; the entry cooldown
//        survives a restart; the loss streak counts trades instead of
//        partial-close legs; the fade target is no longer lost on the
//        ECN fallback; benign modify results no longer count toward the
//        stop-repair limit.
// v3.00: Removed at the user's instruction - no-chase limit, daily
//        loss brake, manual-position block, session filter, Friday
//        cutoff, fast cut, failure-to-launch, opposite-signal exit.
//        Promoted to inputs - spread ceiling, daily trade cap,
//        consecutive-loss pause. Retained as frozen rules - cooldown,
//        one position at a time, regime/signal gates, news blackout
//        (inactive by default), close-if-unprotected, gold-only.
// v2.00: Inputs reduced to user trade management (GoldSeek-style);
//        MaxHold time stop removed; partial banking removed; trailing
//        is now a manual fixed distance. Day-cache scratch buffers are
//        file-scope so the build is warning-free (MQL4 cannot prove a
//        loop initialised a local array).
// v1.01: audit fixes (daily-cap double count, manual-position guard,
//        fast-cut debounce, panel throttle, orphan sweep).

// ------------------------ USER INPUTS -------------------------------
input double GSV11_LotSize                   = 0.01;
input double GSV11_StopLoss_PriceUSD         = 2.50;   // broker-side stop; 0 = no stop
input double GSV11_TakeProfit_PriceUSD       = 0.00;   // 0 = no fixed TP (lock/trail manage the win)
input double GSV11_LockTrigger_PriceUSD      = 0.60;   // at this favorable movement, lock profit; 0 = off
input double GSV11_LockedProfit_PriceUSD     = 0.10;   // SL moves to entry +/- this once triggered
input double GSV11_TrailingStart_PriceUSD    = 0.90;   // trailing activates from this favorable movement; 0 = off
input double GSV11_TrailingDistance_PriceUSD = 0.60;   // trailing gap behind price; 0 = off
input double GSV11_MaxSpread_PriceUSD        = 0.35;   // no entry above this spread; 0 = no ceiling
input int    GSV11_MaxTradesPerDay           = 15;     // 0 = uncapped
input int    GSV11_MaxConsecutiveLosses      = 3;      // pause after this many losses in a row; 0 = off
input int    GSV11_LossPauseMinutes          = 90;     // length of that pause; 0 = stand down for the rest of the day

// ------------------------ ENTRY ENGINE (YOURS TO TUNE) --------------
// Each line below can block an entry. Every one has an off switch and
// ships permissive: the EA should trade first, and you tighten from
// evidence. The panel's "Blocked by" line now names every gate that
// failed, not just the first. Values in brackets are what v4 froze.
input bool   GSV11_UseMomentumModule         = true;
input double GSV11_CusumTrigger              = 2.00;  // evidence needed to call a burst [3.00]
input double GSV11_CusumAllowance            = 0.18;  // per-bar noise deadband
input double GSV11_CusumDecay                = 0.94;  // how fast old evidence fades; higher = more patient
input int    GSV11_CusumFreshBars            = 5;     // enter within N bars of the crossing; 0 = off [3]
input double GSV11_MinEfficiencyRatio        = 0.10;  // path directness 0..1; 0 = off [0.30]
input double GSV11_MinM1Strength             = 0.05;  // M1 velocity in ATRs; 0 = off [0.10]
input double GSV11_MinM1Coherence            = 0.50;  // fraction of M1 windows agreeing; 0 = off [0.75]
input bool   GSV11_RequireBarBodyAligned     = true;  // trigger bar must close in the signal direction
input double GSV11_MaxBarSizeATR             = 0.00;  // reject bars over N x ATR; 0 = off [2.00]
input double GSV11_MaxMoveMaturityATR        = 0.00;  // reject moves N x M5 ATR old; 0 = off [1.50]
input bool   GSV11_RequireM5Alignment        = false; // M5 velocity and EMA ribbon must agree [true]
input double GSV11_MaxShockExhaustion        = 0.00;  // stand down above this shock+exhaustion; 0 = off [0.45]
input double GSV11_MinImpulseDrift           = 0.00;  // require this much impulse+drift; 0 = off [0.35]
input int    GSV11_CooldownSeconds           = 120;   // minimum seconds between entries; 0 = off
input bool   GSV11_LogGateDiagnostics        = false; // write one ledger row per blocked bar

// ------------------------ M5 TREND FILTER ---------------------------
// The bias the 50 EMA on M5 expresses: below a falling line is the
// short side, above a rising line is the long side. Mode 0 is off, so
// nothing changes until you switch it on.
input int    GSV11_TrendFilterMode           = 0;    // 0 = off, 1 = block against trend, 2 = also require a pullback
input int    GSV11_M5TrendEMAPeriod          = 50;   // EMA period on M5
input double GSV11_TrendSlopeMinATR          = 0.00; // minimum EMA slope per bar in M5 ATRs. 0 = side-of-line only,
                                               // so a flat EMA still gives a side. Raise it to make chop report none.
input double GSV11_TrendMaxDistanceATR       = 1.50; // mode 2: entry must be within this many M5 ATRs of the line

// ------------------------ FROZEN SYSTEM RULES -----------------------
// Exit behaviour: the position is owned by the user inputs above
// (SL / TP / lock / trail). The EA adds no exits of its own.
const double GSV11_TRAIL_STEP_USD        = 0.05;   // stop-modify hysteresis
// Entry rails
const string GSV11_NEWS_BLACKOUTS        = "";     // "HH:MM,HH:MM" broker time; empty disables
const int    GSV11_BLACKOUT_MIN_BEFORE   = 15;
const int    GSV11_BLACKOUT_MIN_AFTER    = 10;
const bool   GSV11_ALLOW_LONGS           = true;
const bool   GSV11_ALLOW_SHORTS          = true;
// Fade module (OFF: fading gold failed H4 stability tests; it earns
// its place in the tick backtest or stays off)
const bool   GSV11_USE_FADE              = false;
const int    GSV11_FADE_MA_PERIOD        = 50;
const int    GSV11_FADE_ATR_PERIOD       = 24;
const double GSV11_FADE_BAND_ATR         = 2.5;
const double GSV11_FADE_MAX_ER           = 0.15;
const double GSV11_FADE_MAX_EXPANSION    = 2.0;
// Regime router (GSV11_ER_PERIOD is structural: it sizes the lookback)
const int    GSV11_ER_PERIOD             = 20;
const double GSV11_MIN_FADE_NOISE        = 0.40;
// Execution / display
const double GSV11_MAX_SLIPPAGE_USD      = 0.30;
const int    GSV11_MAGIC_NUMBER          = 26082601;
const bool   GSV11_ECN_FALLBACK          = true;
const bool   GSV11_SHOW_PANEL            = true;
const bool   GSV11_WRITE_LEDGER          = true;
const bool   GSV11_WRITE_DATASET         = true;   // per-trade CSV with MFE/MAE + entry conditions
const bool   GSV11_PUSH_ALERTS           = false;

// ------------------------ internal constants ------------------------
#define GSV11_GS_CLOSE_RETRY_ATTEMPTS      3
#define GSV11_GS_STOP_REPAIR_LIMIT         5
#define GSV11_GS_MAX_WINDOWS               8
#define GSV11_GS_PANEL_PREFIX              "GSP_"

// ------------------------ per-trade feature store -------------------
// One row per completed trade, written on close. MFE/MAE answer
// whether a loser ever went our way; the engine readings are the
// conditions that produced the entry, so outcomes can be bucketed by
// them later.
#define GSV11_F_MFE    0
#define GSV11_F_MAE    1
#define GSV11_F_ER     2
#define GSV11_F_CUSUP  3
#define GSV11_F_CUSDN  4
#define GSV11_F_M1STR  5
#define GSV11_F_COHER  6
#define GSV11_F_MATUR  7
#define GSV11_F_ATRM1  8
#define GSV11_F_ATRM5  9
#define GSV11_F_EXPAN 10
#define GSV11_F_SPRED 11
#define GSV11_F_NOISE 12
#define GSV11_F_DRIFT 13
#define GSV11_F_IMPUL 14
#define GSV11_F_EXHST 15
#define GSV11_F_SHOCK 16
#define GSV11_F_TRDIR 17
#define GSV11_F_TRDST 18
#define GSV11_GS_FEAT_COUNT 19

// ------------------------ panel geometry / palette ------------------
const int   GSV11_PANEL_LEFT     = 10;
const int   GSV11_PANEL_TOP      = 14;
const int   GSV11_PANEL_WIDTH    = 430;
const int   GSV11_PANEL_HEIGHT   = 486;
const int   GSV11_PANEL_LABEL_X  = 26;
const int   GSV11_PANEL_VALUE_X  = 424;   // GSV11_PANEL_LEFT + GSV11_PANEL_WIDTH - 16
const color GSV11_PANEL_BG       = C'13,16,23';
const color GSV11_PANEL_BORDER   = C'55,64,80';
const color GSV11_PANEL_DIVIDER  = C'65,77,96';
const color GSV11_PANEL_TITLE    = C'255,218,0';
const color GSV11_PANEL_SECTION  = C'55,169,255';
const color GSV11_PANEL_LABEL    = C'174,184,201';
const color GSV11_PANEL_VALUE    = C'225,230,240';
const color GSV11_PANEL_MUTED    = C'128,151,190';
const color GSV11_PANEL_GREEN    = C'0,230,96';
const color GSV11_PANEL_AMBER    = C'255,168,32';
const color GSV11_PANEL_RED      = C'255,80,80';
const color GSV11_PANEL_MAGENTA  = C'255,0,220';

// Row baselines shared by GSV11_CreatePanel and GSV11_UpdatePanel so a value can
// never be drawn at a different height from its label.
const int GSV11_ROW_STATUS = 85;
const int GSV11_ROW_SIG    = 107;
const int GSV11_ROW_BLK    = 124;
const int GSV11_ROW_POS    = 141;
const int GSV11_ROW_LOT    = 181;
const int GSV11_ROW_STP    = 198;
const int GSV11_ROW_LCK    = 215;
const int GSV11_ROW_TRL    = 232;
const int GSV11_ROW_SCR    = 249;
const int GSV11_ROW_OWN    = 266;
const int GSV11_ROW_REG    = 306;
const int GSV11_ROW_CUS    = 323;
const int GSV11_ROW_ATR    = 340;
const int GSV11_ROW_TIM    = 380;
const int GSV11_ROW_PRC    = 397;
const int GSV11_ROW_SPR    = 414;
const int GSV11_ROW_SES    = 431;
const int GSV11_ROW_TODAY  = 459;
const int GSV11_ROW_FOOTER = 479;

// ------------------------ regime / signal state ---------------------
double   GSV11_g_cusumUp=0.0, GSV11_g_cusumDown=0.0;
datetime GSV11_g_cusumUpCross=0, GSV11_g_cusumDownCross=0;
double   GSV11_g_modeNoise=0.2, GSV11_g_modeDrift=0.2, GSV11_g_modeImpulse=0.2;
double   GSV11_g_modeExhaustion=0.2, GSV11_g_modeShock=0.2;
double   GSV11_g_m1Comp=0.0, GSV11_g_m1CompPrev=0.0, GSV11_g_m5Comp=0.0;
double   GSV11_g_er=0.0, GSV11_g_expansion=1.0;
double   GSV11_g_atrM1=0.0, GSV11_g_atrM5=0.0;
double   GSV11_g_lastCoherence=0.0, GSV11_g_lastMaturity=0.0;   // recorded every bar for the dataset
double   GSV11_g_trendEma=0.0;        // M5 slow EMA, the directional anchor
int      GSV11_g_trendDir=0;          // +1 above and rising, -1 below and falling, 0 undecided
double   GSV11_g_trendDistATR=0.0;    // how far price sits from the line, in M5 ATRs
double   GSV11_g_feat[GSV11_GS_FEAT_COUNT];
string   GSV11_g_featKey[GSV11_GS_FEAT_COUNT]={"MF","MA","ER","CU","CD","MS","CH","MT",
                                   "A1","A5","EX","SP","RN","RD","RI","RX","RS",
                                   "TD","TS"};
int      GSV11_g_fadeArmed=1;
datetime GSV11_g_lastM1Bar=0;
int      GSV11_g_signalDir=0;
int      GSV11_g_signalModule=0;              // 1=momentum 2=fade
double   GSV11_g_signalRef=0.0;
string   GSV11_g_blocker="initialising";
string   GSV11_g_lastAction="attached";

// ------------------------ position state ----------------------------
int      GSV11_g_posTicket=-1;
double   GSV11_g_posMaxFav=0.0;
double   GSV11_g_posMaxAdv=0.0;
bool     GSV11_g_pendingClose=false;
string   GSV11_g_pendingCloseReason="";
int      GSV11_g_stopRepairTicket=-1;
int      GSV11_g_stopRepairFailures=0;
datetime GSV11_g_lastEntryTime=0;
uint     GSV11_g_lastPanelMs=0;

// ------------------------ day cache ---------------------------------
datetime GSV11_g_dayStart=0;
int      GSV11_g_cacheHistoryTotal=-1, GSV11_g_cacheOpenTotal=-1;
int      GSV11_g_tradesToday=0, GSV11_g_consecLosses=0;
double   GSV11_g_closedPnLToday=0.0;
datetime GSV11_g_lastLossClose=0;
// Scratch buffers for GSV11_RefreshDayCache. File scope, not local: MQL4
// statically zero-initialises globals, while its flow analysis cannot
// prove a loop initialised a local array ("possible use of
// uninitialized variable"). Both are refilled from index 0 on every
// refresh, so no stale value is ever read.
datetime GSV11_g_dcCloseTimes[200];
double   GSV11_g_dcProfits[200];
datetime GSV11_g_dcOpenOf[200];      // open time of each closed row, for grouping
datetime GSV11_g_dcOpens[400];

// ------------------------ parsed schedules --------------------------
int      GSV11_g_newsMinute[GSV11_GS_MAX_WINDOWS];
int      GSV11_g_newsCount=0;

//+------------------------------------------------------------------+
//| small utilities                                                   |
//+------------------------------------------------------------------+
double GSV11_Clamp(const double v,const double lo,const double hi)
{
   return(MathMax(lo,MathMin(hi,v)));
}

bool GSV11_IsGoldSymbol()
{
   string s=Symbol();
   StringToUpper(s);
   return(StringFind(s,"XAU")>=0 || StringFind(s,"GOLD")>=0);
}

int GSV11_LotDigits(const double step)
{
   if(step>=1.0) return(0);
   if(step>=0.1) return(1);
   if(step>=0.01) return(2);
   if(step>=0.001) return(3);
   return(4);
}

// Floors to the broker lot step; refuses (returns 0) below the broker
// minimum instead of silently rounding risk upward.
double GSV11_NormaliseLots(const double requested)
{
   double minimum=MarketInfo(Symbol(),MODE_MINLOT);
   double maximum=MarketInfo(Symbol(),MODE_MAXLOT);
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(step<=0.0) step=0.01;
   if(requested<minimum-1e-10) return(0.0);
   double lots=MathFloor((requested+1e-10)/step)*step;
   lots=MathMin(maximum,lots);
   if(lots<minimum-1e-10) return(0.0);
   return(NormalizeDouble(lots,GSV11_LotDigits(step)));
}

int GSV11_SlippagePoints()
{
   if(GSV11_MAX_SLIPPAGE_USD<=0.0 || Point<=0.0) return(0);
   return((int)MathRound(GSV11_MAX_SLIPPAGE_USD/Point));
}

double GSV11_BrokerModifyDistance()
{
   double stopDist=MarketInfo(Symbol(),MODE_STOPLEVEL)*Point;
   double freeze=MarketInfo(Symbol(),MODE_FREEZELEVEL)*Point;
   return(MathMax(stopDist,freeze));
}

//+------------------------------------------------------------------+
//| schedule parsing ("HH:MM-HH:MM,..." and "HH:MM,...")              |
//+------------------------------------------------------------------+
int GSV11_MinuteOfString(string hhmm)
{
   StringTrimLeft(hhmm); StringTrimRight(hhmm);
   int colon=StringFind(hhmm,":");
   if(colon<0) return(-1);
   int h=(int)StringToInteger(StringSubstr(hhmm,0,colon));
   int m=(int)StringToInteger(StringSubstr(hhmm,colon+1));
   if(h<0 || h>23 || m<0 || m>59) return(-1);
   return(h*60+m);
}

bool GSV11_ParseSchedules()
{
   GSV11_g_newsCount=0;
   if(StringLen(GSV11_NEWS_BLACKOUTS)>0)
   {
      string times[];
      int k=StringSplit(GSV11_NEWS_BLACKOUTS,',',times);
      for(int j=0;j<k && GSV11_g_newsCount<GSV11_GS_MAX_WINDOWS;j++)
      {
         string t=times[j];
         StringTrimLeft(t); StringTrimRight(t);
         if(StringLen(t)==0) continue;
         int mm=GSV11_MinuteOfString(t);
         if(mm<0) return(false);
         GSV11_g_newsMinute[GSV11_g_newsCount]=mm;
         GSV11_g_newsCount++;
      }
   }
   return(true);
}

bool GSV11_BlackoutActive(const datetime t)
{
   if(GSV11_g_newsCount==0) return(false);
   int m=TimeHour(t)*60+TimeMinute(t);
   for(int i=0;i<GSV11_g_newsCount;i++)
   {
      int diff=m-GSV11_g_newsMinute[i];
      if(diff>=-GSV11_BLACKOUT_MIN_BEFORE && diff<=GSV11_BLACKOUT_MIN_AFTER) return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| market measurements (closed bars only)                            |
//+------------------------------------------------------------------+
// ATR-normalised multi-window velocity composite. Windows sized for
// scalp cadence; sqrt scaling keeps windows comparable.
double GSV11_M1Composite(const int shift)
{
   double atr=iATR(Symbol(),PERIOD_M1,14,shift);
   if(atr<=0.0) return(0.0);
   int    w[4]={1,3,5,15};
   double wt[4]={0.35,0.30,0.20,0.15};
   double c=0.0;
   for(int i=0;i<4;i++)
      c+=wt[i]*(iClose(Symbol(),PERIOD_M1,shift)-iOpen(Symbol(),PERIOD_M1,shift+w[i]-1))/
         (atr*MathSqrt(w[i]));
   return(c);
}

double GSV11_M5Composite(const int shift)
{
   double atr=iATR(Symbol(),PERIOD_M5,12,shift);
   if(atr<=0.0) return(0.0);
   int    w[4]={1,3,6,12};
   double wt[4]={0.30,0.30,0.25,0.15};
   double c=0.0;
   for(int i=0;i<4;i++)
      c+=wt[i]*(iClose(Symbol(),PERIOD_M5,shift)-iOpen(Symbol(),PERIOD_M5,shift+w[i]-1))/
         (atr*MathSqrt(w[i]));
   return(c);
}

double GSV11_M1Coherence(const int shift,const int dir)
{
   double atr=iATR(Symbol(),PERIOD_M1,14,shift);
   if(atr<=0.0 || dir==0) return(0.0);
   int w[4]={1,3,5,15};
   int aligned=0;
   for(int i=0;i<4;i++)
   {
      double v=iClose(Symbol(),PERIOD_M1,shift)-iOpen(Symbol(),PERIOD_M1,shift+w[i]-1);
      if(dir*v>0.0) aligned++;
   }
   return(aligned/4.0);
}

// Signed efficiency ratio: |ER| near 1 = clean directional path.
double GSV11_EfficiencyRatio(const int shift)
{
   double net=iClose(Symbol(),PERIOD_M1,shift)-iClose(Symbol(),PERIOD_M1,shift+GSV11_ER_PERIOD);
   double path=0.0;
   for(int k=0;k<GSV11_ER_PERIOD;k++)
      path+=MathAbs(iClose(Symbol(),PERIOD_M1,shift+k)-iClose(Symbol(),PERIOD_M1,shift+k+1));
   if(path<=0.0) return(0.0);
   return(net/path);
}

double GSV11_ReturnSigmaM1(const int shift)
{
   double variance=0.0;
   bool seeded=false;
   for(int s=shift+48;s>=shift;s--)
   {
      double c=iClose(Symbol(),PERIOD_M1,s);
      double p=iClose(Symbol(),PERIOD_M1,s+1);
      if(c<=0.0 || p<=0.0) continue;
      double r=c-p;
      if(!seeded) { variance=r*r; seeded=true; }
      else variance=0.90*variance+0.10*r*r;
   }
   return(MathMax(MathSqrt(MathMax(variance,0.0)),Point));
}

void GSV11_UpdateCusum(const datetime barTime)
{
   double c=iClose(Symbol(),PERIOD_M1,1);
   double p=iClose(Symbol(),PERIOD_M1,2);
   if(c<=0.0 || p<=0.0) return;
   double z=(c-p)/GSV11_ReturnSigmaM1(1);
   double prevUp=GSV11_g_cusumUp, prevDown=GSV11_g_cusumDown;
   GSV11_g_cusumUp=GSV11_Clamp(MathMax(0.0,GSV11_CusumDecay*GSV11_g_cusumUp+z-GSV11_CusumAllowance),0.0,12.0);
   GSV11_g_cusumDown=GSV11_Clamp(MathMax(0.0,GSV11_CusumDecay*GSV11_g_cusumDown-z-GSV11_CusumAllowance),0.0,12.0);
   if(prevUp<GSV11_CusumTrigger && GSV11_g_cusumUp>=GSV11_CusumTrigger)     GSV11_g_cusumUpCross=barTime;
   if(prevDown<GSV11_CusumTrigger && GSV11_g_cusumDown>=GSV11_CusumTrigger) GSV11_g_cusumDownCross=barTime;
}

// Five-mode regime posterior (noise/drift/impulse/exhaustion/shock)
// with an IMM-style sticky prior. Feature scales follow GoldSeek v3.
void GSV11_UpdateModes()
{
   double speed=0.40*MathAbs(GSV11_g_m1Comp)+0.60*MathAbs(GSV11_g_m5Comp);
   double accel=MathAbs(GSV11_g_m1Comp-GSV11_g_m1CompPrev);
   double eff=MathAbs(GSV11_g_er);
   double agree=((GSV11_g_m1Comp*GSV11_g_m5Comp)>0.0 ? 1.0 : -1.0)*
                MathMin(MathAbs(GSV11_g_m1Comp),MathAbs(GSV11_g_m5Comp));
   double lastRet=iClose(Symbol(),PERIOD_M1,1)-iClose(Symbol(),PERIOD_M1,2);
   double lastZ=lastRet/GSV11_ReturnSigmaM1(1);

   double ll[5];
   ArrayInitialize(ll,0.0);
   ll[0]=1.35*(1.0-eff)-0.45*speed-0.25*MathAbs(GSV11_g_expansion-1.0);
   ll[1]=1.20*eff+0.45*speed+0.35*MathMax(agree,0.0)-0.35*accel;
   ll[2]=0.90*eff+0.75*speed+0.70*MathMax(accel,0.0)+0.35*MathMax(GSV11_g_expansion-1.0,0.0);
   ll[3]=0.65*speed+0.90*MathMax(-agree,0.0)+0.65*(1.0-eff)+0.30*accel;
   ll[4]=1.15*MathMax(GSV11_g_expansion-1.65,0.0)+0.55*MathMax(MathAbs(lastZ)-2.0,0.0);

   double mx=ll[0];
   for(int i=1;i<5;i++) mx=MathMax(mx,ll[i]);
   double like[5];
   ArrayInitialize(like,0.0);
   double total=0.0;
   for(int j=0;j<5;j++)
   {
      like[j]=MathExp(GSV11_Clamp(ll[j]-mx,-50.0,50.0));
      total+=like[j];
   }
   if(total<=0.0) total=1.0;

   double prev[5];
   ArrayInitialize(prev,0.0);
   prev[0]=GSV11_g_modeNoise; prev[1]=GSV11_g_modeDrift; prev[2]=GSV11_g_modeImpulse;
   prev[3]=GSV11_g_modeExhaustion; prev[4]=GSV11_g_modeShock;
   double upd[5];
   ArrayInitialize(upd,0.0);
   double updTotal=0.0;
   for(int m=0;m<5;m++)
   {
      double prior=0.72*prev[m]+0.28*(1.0-prev[m])/4.0;
      upd[m]=prior*(like[m]/total);
      updTotal+=upd[m];
   }
   if(updTotal<=0.0) updTotal=1.0;
   GSV11_g_modeNoise=upd[0]/updTotal;
   GSV11_g_modeDrift=upd[1]/updTotal;
   GSV11_g_modeImpulse=upd[2]/updTotal;
   GSV11_g_modeExhaustion=upd[3]/updTotal;
   GSV11_g_modeShock=upd[4]/updTotal;
}

// The M5 trend anchor. Direction needs price on the correct side of
// the line AND the line itself leaning that way, so a flat EMA in chop
// reports 0 (no side) rather than flipping on every touch.
void GSV11_UpdateTrend()
{
   GSV11_g_trendEma=0.0;
   GSV11_g_trendDir=0;
   GSV11_g_trendDistATR=0.0;
   if(GSV11_M5TrendEMAPeriod<2) return;

   double ema=iMA(Symbol(),PERIOD_M5,GSV11_M5TrendEMAPeriod,0,MODE_EMA,PRICE_CLOSE,1);
   double emaPrev=iMA(Symbol(),PERIOD_M5,GSV11_M5TrendEMAPeriod,0,MODE_EMA,PRICE_CLOSE,2);
   if(ema<=0.0 || emaPrev<=0.0) return;
   GSV11_g_trendEma=ema;

   double close5=iClose(Symbol(),PERIOD_M5,1);
   if(GSV11_g_atrM5>0.0) GSV11_g_trendDistATR=(close5-ema)/GSV11_g_atrM5;

   double slopeATR=(GSV11_g_atrM5>0.0 ? (ema-emaPrev)/GSV11_g_atrM5 : 0.0);
   bool aboveRising=(close5>ema && slopeATR>=GSV11_TrendSlopeMinATR);
   bool belowFalling=(close5<ema && -slopeATR>=GSV11_TrendSlopeMinATR);
   if(aboveRising)       GSV11_g_trendDir=1;
   else if(belowFalling) GSV11_g_trendDir=-1;
}

void GSV11_UpdateRegime(const datetime barTime)
{
   GSV11_g_m1CompPrev=GSV11_g_m1Comp;
   GSV11_g_m1Comp=GSV11_M1Composite(1);
   GSV11_g_m5Comp=GSV11_M5Composite(1);
   GSV11_g_er=GSV11_EfficiencyRatio(1);
   GSV11_g_atrM1=iATR(Symbol(),PERIOD_M1,14,1);
   GSV11_g_atrM5=iATR(Symbol(),PERIOD_M5,12,1);
   double atrSlow=iATR(Symbol(),PERIOD_M1,48,1);
   GSV11_g_expansion=(atrSlow>0.0 ? GSV11_Clamp(iATR(Symbol(),PERIOD_M1,6,1)/atrSlow,0.25,4.0) : 1.0);
   GSV11_UpdateCusum(barTime);
   GSV11_UpdateModes();
   GSV11_UpdateTrend();
}

//+------------------------------------------------------------------+
//| signal modules (evaluated once per closed M1 bar)                 |
//+------------------------------------------------------------------+
// Append a failed-gate token to the running list. Every gate is
// evaluated on every bar so the panel and the diagnostics log show the
// whole wall, not just the first brick.
void GSV11_AddGateFailure(string &list,const string token)
{
   if(StringLen(list)>0) list=list+", ";
   list=list+token;
}

int GSV11_EvaluateMomentum(string &blocker)
{
   if(!GSV11_UseMomentumModule) { blocker="momentum module off"; return(0); }

   // Direction comes from whichever CUSUM accumulator has crossed. When
   // neither has, fall back to the M1 composite so the remaining gates
   // can still be reported. Note that in that case the reported tokens
   // are measured against a PRESUMED direction - no entry is possible
   // on such a bar anyway, because the burst gate has already failed.
   int dir=0;
   datetime cross=0;
   bool burst=false;
   if(GSV11_g_cusumUp>=GSV11_CusumTrigger && GSV11_g_cusumUp-GSV11_g_cusumDown>=GSV11_CusumTrigger*0.5)
      { dir=1; cross=GSV11_g_cusumUpCross; burst=true; }
   else if(GSV11_g_cusumDown>=GSV11_CusumTrigger && GSV11_g_cusumDown-GSV11_g_cusumUp>=GSV11_CusumTrigger*0.5)
      { dir=-1; cross=GSV11_g_cusumDownCross; burst=true; }
   if(dir==0) dir=(GSV11_g_m1Comp>=0.0 ? 1 : -1);

   // Measured on every bar regardless of whether their gates are armed:
   // the dataset needs them for trades that were taken with the gate off.
   GSV11_g_lastCoherence=GSV11_M1Coherence(1,dir);
   GSV11_g_lastMaturity=0.0;
   if(GSV11_g_atrM5>0.0)
   {
      double mlo=iLow(Symbol(),PERIOD_M1,1), mhi=iHigh(Symbol(),PERIOD_M1,1);
      for(int mk=2;mk<=31;mk++)
      {
         mlo=MathMin(mlo,iLow(Symbol(),PERIOD_M1,mk));
         mhi=MathMax(mhi,iHigh(Symbol(),PERIOD_M1,mk));
      }
      double mclose=iClose(Symbol(),PERIOD_M1,1);
      GSV11_g_lastMaturity=(dir>0 ? mclose-mlo : mhi-mclose)/GSV11_g_atrM5;
   }

   string fails="";

   if(!burst)
      GSV11_AddGateFailure(fails,StringFormat("burst %.1f/%.1f",
                     MathMax(GSV11_g_cusumUp,GSV11_g_cusumDown),GSV11_CusumTrigger));
   else if(GSV11_CusumFreshBars>0 &&
           (cross==0 || (iTime(Symbol(),PERIOD_M1,1)-cross)>GSV11_CusumFreshBars*60))
      GSV11_AddGateFailure(fails,"stale");

   if(GSV11_MaxShockExhaustion>0.0 && GSV11_g_modeShock+GSV11_g_modeExhaustion>GSV11_MaxShockExhaustion)
      GSV11_AddGateFailure(fails,StringFormat("shock/exh %.2f",GSV11_g_modeShock+GSV11_g_modeExhaustion));

   if(GSV11_MinImpulseDrift>0.0 && GSV11_g_modeImpulse+GSV11_g_modeDrift<GSV11_MinImpulseDrift)
      GSV11_AddGateFailure(fails,StringFormat("imp+drift %.2f",GSV11_g_modeImpulse+GSV11_g_modeDrift));

   if(GSV11_MinEfficiencyRatio>0.0 && (dir*GSV11_g_er<=0.0 || MathAbs(GSV11_g_er)<GSV11_MinEfficiencyRatio))
      GSV11_AddGateFailure(fails,StringFormat("ER %+.2f",GSV11_g_er));

   if(GSV11_MinM1Strength>0.0 && dir*GSV11_g_m1Comp<GSV11_MinM1Strength)
      GSV11_AddGateFailure(fails,StringFormat("M1str %.2f",dir*GSV11_g_m1Comp));

   if(GSV11_MinM1Coherence>0.0 && GSV11_g_lastCoherence<GSV11_MinM1Coherence)
      GSV11_AddGateFailure(fails,StringFormat("coher %.2f",GSV11_g_lastCoherence));

   if(GSV11_RequireBarBodyAligned)
   {
      double body=iClose(Symbol(),PERIOD_M1,1)-iOpen(Symbol(),PERIOD_M1,1);
      if(dir*body<=0.0) GSV11_AddGateFailure(fails,"body");
   }

   if(GSV11_MaxBarSizeATR>0.0 && GSV11_g_atrM1>0.0)
   {
      double tr=iHigh(Symbol(),PERIOD_M1,1)-iLow(Symbol(),PERIOD_M1,1);
      if(tr>GSV11_MaxBarSizeATR*GSV11_g_atrM1)
         GSV11_AddGateFailure(fails,StringFormat("bigbar %.1fx",tr/GSV11_g_atrM1));
   }

   if(GSV11_MaxMoveMaturityATR>0.0 && GSV11_g_atrM5>0.0 && GSV11_g_lastMaturity>GSV11_MaxMoveMaturityATR)
      GSV11_AddGateFailure(fails,StringFormat("mature %.1fx",GSV11_g_lastMaturity));

   if(GSV11_TrendFilterMode>0)
   {
      if(GSV11_g_trendDir==0)
         GSV11_AddGateFailure(fails,"no M5 trend");
      else if(GSV11_g_trendDir!=dir)
         GSV11_AddGateFailure(fails,StringFormat("vs M5 trend (%s)",GSV11_g_trendDir>0?"up":"down"));
      else if(GSV11_TrendFilterMode>=2 && GSV11_TrendMaxDistanceATR>0.0 &&
              MathAbs(GSV11_g_trendDistATR)>GSV11_TrendMaxDistanceATR)
         GSV11_AddGateFailure(fails,StringFormat("far from EMA %.1fx",MathAbs(GSV11_g_trendDistATR)));
   }

   if(GSV11_RequireM5Alignment)
   {
      if(dir*GSV11_g_m5Comp<=0.0) GSV11_AddGateFailure(fails,"M5vel");
      double e20=iMA(Symbol(),PERIOD_M5,20,0,MODE_EMA,PRICE_CLOSE,1);
      double e30=iMA(Symbol(),PERIOD_M5,30,0,MODE_EMA,PRICE_CLOSE,1);
      if(GSV11_g_atrM5>0.0 && dir*(e20-e30)/GSV11_g_atrM5<-0.05) GSV11_AddGateFailure(fails,"M5ribbon");
   }

   blocker=fails;
   if(StringLen(fails)>0) return(0);
   return(dir);
}

int GSV11_EvaluateFade(string &blocker,double &target)
{
   target=0.0;
   if(!GSV11_USE_FADE) { blocker="fade module off"; return(0); }
   if(GSV11_MaxShockExhaustion>0.0 && GSV11_g_modeShock+GSV11_g_modeExhaustion>GSV11_MaxShockExhaustion)
      { blocker="shock/exhaust"; return(0); }
   if(GSV11_g_modeNoise<GSV11_MIN_FADE_NOISE)
      { blocker=StringFormat("noise %.2f",GSV11_g_modeNoise); return(0); }
   if(MathAbs(GSV11_g_er)>GSV11_FADE_MAX_ER) { blocker="trending - no fade"; return(0); }
   if(GSV11_g_expansion>GSV11_FADE_MAX_EXPANSION) { blocker="vol expanding - no fade"; return(0); }

   double mid=iMA(Symbol(),PERIOD_M1,GSV11_FADE_MA_PERIOD,0,MODE_SMA,PRICE_CLOSE,1);
   double atr=iATR(Symbol(),PERIOD_M1,GSV11_FADE_ATR_PERIOD,1);
   if(mid<=0.0 || atr<=0.0) { blocker="fade data"; return(0); }
   double up=mid+GSV11_FADE_BAND_ATR*atr;
   double dn=mid-GSV11_FADE_BAND_ATR*atr;
   double close1=iClose(Symbol(),PERIOD_M1,1);

   // re-arm only after price returns inside the bands: one fade per excursion
   if(close1<up && close1>dn) { GSV11_g_fadeArmed=1; blocker="inside bands"; return(0); }
   if(GSV11_g_fadeArmed==0) { blocker="excursion already faded"; return(0); }

   int dir=0;
   if(close1>up) dir=-1;
   if(close1<dn) dir=1;
   if(dir==0) { blocker="no band break"; return(0); }
   GSV11_g_fadeArmed=0;
   target=mid;
   blocker="";
   return(dir);
}

//+------------------------------------------------------------------+
//| day cache: trades, closed PnL, consecutive-loss streak            |
//+------------------------------------------------------------------+
datetime GSV11_BrokerDayStart()
{
   datetime d=iTime(Symbol(),PERIOD_D1,0);
   if(d<=0) d=StrToTime(TimeToString(TimeCurrent(),TIME_DATE));
   return(d);
}

void GSV11_InvalidateDayCache()
{
   GSV11_g_cacheHistoryTotal=-1;
   GSV11_g_cacheOpenTotal=-1;
}

void GSV11_RefreshDayCache()
{
   datetime start=GSV11_BrokerDayStart();
   int historyTotal=OrdersHistoryTotal();
   int openTotal=OrdersTotal();
   if(start==GSV11_g_dayStart && historyTotal==GSV11_g_cacheHistoryTotal && openTotal==GSV11_g_cacheOpenTotal)
      return;

   int    n=0;
   int    oc=0;
   double pnl=0.0;

   for(int h=OrdersHistoryTotal()-1;h>=0;h--)
   {
      if(!OrderSelect(h,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=GSV11_MAGIC_NUMBER) continue;
      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) continue;
      if(OrderOpenTime()>=start && oc<400) GSV11_g_dcOpens[oc++]=OrderOpenTime();
      if(OrderCloseTime()>=start && n<200)
      {
         double p=OrderProfit()+OrderSwap()+OrderCommission();
         pnl+=p;
         GSV11_g_dcCloseTimes[n]=OrderCloseTime();
         GSV11_g_dcProfits[n]=p;
         GSV11_g_dcOpenOf[n]=OrderOpenTime();
         n++;
      }
   }
   for(int t=OrdersTotal()-1;t>=0;t--)
   {
      if(!OrderSelect(t,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=GSV11_MAGIC_NUMBER) continue;
      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) continue;
      if(OrderOpenTime()>=start && oc<400) GSV11_g_dcOpens[oc++]=OrderOpenTime();
   }

   // Tickets split by partial/manual partial closes share an open time:
   // count unique open times, not tickets, so the daily cap counts
   // true entries.
   int trades=0;
   if(oc>0)
   {
      ArraySort(GSV11_g_dcOpens,oc,0,MODE_ASCEND);
      trades=1;
      for(int u=1;u<oc;u++)
         if(GSV11_g_dcOpens[u]!=GSV11_g_dcOpens[u-1]) trades++;
   }

   // Collapse partial-close legs into whole trades before measuring the
   // streak: legs of one entry share an open time, so a net-positive
   // trade that was part-closed must not contribute a "loss".
   for(int g=0;g<n;g++)
   {
      if(GSV11_g_dcOpenOf[g]==0) continue;                 // already merged away
      for(int h=g+1;h<n;h++)
      {
         if(GSV11_g_dcOpenOf[h]!=GSV11_g_dcOpenOf[g]) continue;
         GSV11_g_dcProfits[g]+=GSV11_g_dcProfits[h];
         if(GSV11_g_dcCloseTimes[h]>GSV11_g_dcCloseTimes[g])
            GSV11_g_dcCloseTimes[g]=GSV11_g_dcCloseTimes[h];     // trade ends with its last leg
         GSV11_g_dcOpenOf[h]=0;
         GSV11_g_dcProfits[h]=0.0;
         GSV11_g_dcCloseTimes[h]=0;
      }
   }
   int m=0;
   for(int c=0;c<n;c++)
   {
      if(GSV11_g_dcOpenOf[c]==0 && GSV11_g_dcCloseTimes[c]==0) continue;
      GSV11_g_dcCloseTimes[m]=GSV11_g_dcCloseTimes[c];
      GSV11_g_dcProfits[m]=GSV11_g_dcProfits[c];
      m++;
   }

   // sort whole trades by close time (insertion sort, m is small)
   for(int i=1;i<m;i++)
   {
      datetime ct=GSV11_g_dcCloseTimes[i];
      double pf=GSV11_g_dcProfits[i];
      int j=i-1;
      while(j>=0 && GSV11_g_dcCloseTimes[j]>ct)
      {
         GSV11_g_dcCloseTimes[j+1]=GSV11_g_dcCloseTimes[j];
         GSV11_g_dcProfits[j+1]=GSV11_g_dcProfits[j];
         j--;
      }
      GSV11_g_dcCloseTimes[j+1]=ct;
      GSV11_g_dcProfits[j+1]=pf;
   }
   int streak=0;
   datetime lastLoss=0;
   for(int s=m-1;s>=0;s--)
   {
      if(GSV11_g_dcProfits[s]<0.0)
      {
         streak++;
         if(lastLoss==0) lastLoss=GSV11_g_dcCloseTimes[s];
      }
      else break;
   }

   GSV11_g_dayStart=start;
   GSV11_g_cacheHistoryTotal=historyTotal;
   GSV11_g_cacheOpenTotal=openTotal;
   GSV11_g_tradesToday=trades;
   GSV11_g_closedPnLToday=pnl;
   GSV11_g_consecLosses=streak;
   GSV11_g_lastLossClose=lastLoss;
}

//+------------------------------------------------------------------+
//| ledger                                                            |
//+------------------------------------------------------------------+
void LedgerWrite(const string eventName,const int dir,const double lots,
                 const double price,const double profit,const string reason)
{
   if(!GSV11_WRITE_LEDGER) return;
   string file=StringFormat("GoldScalper_%s_%d.csv",Symbol(),AccountNumber());
   int h=FileOpen(file,FILE_CSV|FILE_READ|FILE_WRITE,';');
   if(h==INVALID_HANDLE) return;
   if(FileSize(h)==0)
      FileWrite(h,"time","event","dir","lots","price","profit_usd","reason",
                "spread","er","noise","drift","impulse","exhaust","shock");
   FileSeek(h,0,SEEK_END);
   RefreshRates();
   FileWrite(h,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),eventName,
             (dir>0?"BUY":(dir<0?"SELL":"-")),DoubleToString(lots,2),
             DoubleToString(price,Digits),DoubleToString(profit,2),reason,
             DoubleToString(Ask-Bid,Digits),DoubleToString(GSV11_g_er,2),
             DoubleToString(GSV11_g_modeNoise,2),DoubleToString(GSV11_g_modeDrift,2),
             DoubleToString(GSV11_g_modeImpulse,2),DoubleToString(GSV11_g_modeExhaustion,2),
             DoubleToString(GSV11_g_modeShock,2));
   FileClose(h);
}

//+------------------------------------------------------------------+
//| journal a position that closed away from the EA                   |
//+------------------------------------------------------------------+
// Every ordinary exit (stop loss, take profit, trailed stop, or a
// manual close) happens at the broker, so the EA only learns about it
// when the ticket disappears. Recover it from history and write the
// EXIT row, or the ledger records entries with no outcomes.
string GSV11_InferredCloseReason()
{
   string comment=OrderComment();
   StringToLower(comment);
   if(StringFind(comment,"[sl]")>=0) return("stop loss / trail hit");
   if(StringFind(comment,"[tp]")>=0) return("take profit hit");

   double closePrice=OrderClosePrice();
   double sl=OrderStopLoss();
   double tp=OrderTakeProfit();
   double tolerance=MathMax(Point*10.0,0.05);
   if(sl>0.0 && MathAbs(closePrice-sl)<=tolerance) return("stop loss / trail hit");
   if(tp>0.0 && MathAbs(closePrice-tp)<=tolerance) return("take profit hit");
   return("closed manually or by broker");
}

// One row per completed trade: the outcome next to the excursions and
// the conditions that produced the entry. This is the file to analyse.
void GSV11_DatasetWrite(const double profit,const string reason)
{
   if(!GSV11_WRITE_DATASET) return;
   string file=StringFormat("GoldScalperTrades_%s_%d.csv",Symbol(),AccountNumber());
   int h=FileOpen(file,FILE_CSV|FILE_READ|FILE_WRITE,',');
   if(h==INVALID_HANDLE) return;
   if(FileSize(h)==0)
      FileWrite(h,"ticket","dir","module","lots","entry_time","entry_price",
                "exit_time","exit_price","profit","reason","hold_seconds","hour",
                "mfe","mae","er","cusum_up","cusum_dn","m1_strength","coherence",
                "maturity_m5atr","atr_m1","atr_m5","expansion","spread_at_entry",
                "noise","drift","impulse","exhaustion","shock",
                "trend_dir","trend_dist_atr");
   FileSeek(h,0,SEEK_END);

   string comment=OrderComment();
   string module=(StringFind(comment,"GSF_")>=0 ? "fade" : "momentum");
   int hold=(int)(OrderCloseTime()-OrderOpenTime());

   FileWrite(h,
      IntegerToString(OrderTicket()),
      (OrderType()==OP_BUY?"BUY":"SELL"),
      module,
      DoubleToString(OrderLots(),2),
      TimeToString(OrderOpenTime(),TIME_DATE|TIME_SECONDS),
      DoubleToString(OrderOpenPrice(),Digits),
      TimeToString(OrderCloseTime(),TIME_DATE|TIME_SECONDS),
      DoubleToString(OrderClosePrice(),Digits),
      DoubleToString(profit,2),
      reason,
      IntegerToString(hold),
      IntegerToString(TimeHour(OrderOpenTime())),
      DoubleToString(GSV11_g_feat[GSV11_F_MFE],2),
      DoubleToString(GSV11_g_feat[GSV11_F_MAE],2),
      DoubleToString(GSV11_g_feat[GSV11_F_ER],3),
      DoubleToString(GSV11_g_feat[GSV11_F_CUSUP],2),
      DoubleToString(GSV11_g_feat[GSV11_F_CUSDN],2),
      DoubleToString(GSV11_g_feat[GSV11_F_M1STR],3),
      DoubleToString(GSV11_g_feat[GSV11_F_COHER],2),
      DoubleToString(GSV11_g_feat[GSV11_F_MATUR],2),
      DoubleToString(GSV11_g_feat[GSV11_F_ATRM1],3),
      DoubleToString(GSV11_g_feat[GSV11_F_ATRM5],3),
      DoubleToString(GSV11_g_feat[GSV11_F_EXPAN],2),
      DoubleToString(GSV11_g_feat[GSV11_F_SPRED],3),
      DoubleToString(GSV11_g_feat[GSV11_F_NOISE],2),
      DoubleToString(GSV11_g_feat[GSV11_F_DRIFT],2),
      DoubleToString(GSV11_g_feat[GSV11_F_IMPUL],2),
      DoubleToString(GSV11_g_feat[GSV11_F_EXHST],2),
      DoubleToString(GSV11_g_feat[GSV11_F_SHOCK],2),
      DoubleToString(GSV11_g_feat[GSV11_F_TRDIR],0),
      DoubleToString(GSV11_g_feat[GSV11_F_TRDST],2));
   FileClose(h);
}

void GSV11_JournalClosedTicket(const int ticket)
{
   if(ticket<0) return;
   if(!OrderSelect(ticket,SELECT_BY_TICKET,MODE_HISTORY)) return;
   if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=GSV11_MAGIC_NUMBER) return;
   if(OrderCloseTime()<=0) return;
   if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) return;
   double profit=OrderProfit()+OrderSwap()+OrderCommission();
   string reason=GSV11_InferredCloseReason();
   // MFE/MAE live in GSV11_g_feat only after GSV11_PersistTicketState has synced
   // them; do it here so a close that happens between syncs is exact.
   GSV11_g_feat[GSV11_F_MFE]=GSV11_g_posMaxFav;
   GSV11_g_feat[GSV11_F_MAE]=GSV11_g_posMaxAdv;
   LedgerWrite("EXIT",(OrderType()==OP_BUY?1:-1),OrderLots(),OrderClosePrice(),
               profit,reason);
   GSV11_DatasetWrite(profit,reason);
   GSV11_g_lastAction=StringFormat("CLOSED %+.2f (peak %+.2f dip %.2f): %s",
                             profit,GSV11_g_posMaxFav,GSV11_g_posMaxAdv,reason);
   if(GSV11_PUSH_ALERTS)
      SendNotification(StringFormat("GoldScalper position closed %+.2f (%s)",profit,reason));
}

//+------------------------------------------------------------------+
//| position discovery + per-ticket scalp state                       |
//+------------------------------------------------------------------+
int GSV11_FindManagedTicket()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=GSV11_MAGIC_NUMBER) continue;
      if(OrderType()==OP_BUY || OrderType()==OP_SELL) return(OrderTicket());
   }
   return(-1);
}

double GSV11_ProfitMovementSelected()
{
   RefreshRates();
   if(OrderType()==OP_BUY) return(Bid-OrderOpenPrice());
   if(OrderType()==OP_SELL) return(OrderOpenPrice()-Ask);
   return(0.0);
}

string GSV11_AccountKey(const string suffix)
{
   return(StringFormat("GS1.%d.%d.%s",AccountNumber(),GSV11_MAGIC_NUMBER,suffix));
}

string GSV11_TicketKey(const int ticket,const string suffix)
{
   return(StringFormat("GS1.%d.%d.%d.%s",AccountNumber(),GSV11_MAGIC_NUMBER,ticket,suffix));
}

void GSV11_SnapshotEntryFeatures(const double spreadAtEntry)
{
   GSV11_g_feat[GSV11_F_MFE]=0.0;
   GSV11_g_feat[GSV11_F_MAE]=0.0;
   GSV11_g_feat[GSV11_F_ER]=GSV11_g_er;
   GSV11_g_feat[GSV11_F_CUSUP]=GSV11_g_cusumUp;
   GSV11_g_feat[GSV11_F_CUSDN]=GSV11_g_cusumDown;
   GSV11_g_feat[GSV11_F_M1STR]=GSV11_g_m1Comp;
   GSV11_g_feat[GSV11_F_COHER]=GSV11_g_lastCoherence;
   GSV11_g_feat[GSV11_F_MATUR]=GSV11_g_lastMaturity;
   GSV11_g_feat[GSV11_F_ATRM1]=GSV11_g_atrM1;
   GSV11_g_feat[GSV11_F_ATRM5]=GSV11_g_atrM5;
   GSV11_g_feat[GSV11_F_EXPAN]=GSV11_g_expansion;
   GSV11_g_feat[GSV11_F_SPRED]=spreadAtEntry;
   GSV11_g_feat[GSV11_F_NOISE]=GSV11_g_modeNoise;
   GSV11_g_feat[GSV11_F_DRIFT]=GSV11_g_modeDrift;
   GSV11_g_feat[GSV11_F_IMPUL]=GSV11_g_modeImpulse;
   GSV11_g_feat[GSV11_F_EXHST]=GSV11_g_modeExhaustion;
   GSV11_g_feat[GSV11_F_SHOCK]=GSV11_g_modeShock;
   GSV11_g_feat[GSV11_F_TRDIR]=(double)GSV11_g_trendDir;
   GSV11_g_feat[GSV11_F_TRDST]=GSV11_g_trendDistATR;
}

// Full write: entry conditions plus excursions. Used once per adoption.
void GSV11_PersistTicketState(const int ticket)
{
   if(IsTesting() || ticket<0) return;
   GSV11_g_feat[GSV11_F_MFE]=GSV11_g_posMaxFav;
   GSV11_g_feat[GSV11_F_MAE]=GSV11_g_posMaxAdv;
   for(int i=0;i<GSV11_GS_FEAT_COUNT;i++)
      GlobalVariableSet(GSV11_TicketKey(ticket,GSV11_g_featKey[i]),GSV11_g_feat[i]);
}

// Hot path: only the two values that can change after entry. The other
// seventeen are entry-time constants, and rewriting them on every
// five-cent excursion move was thousands of pointless terminal writes
// an hour on a fast tape.
void GSV11_PersistExcursions(const int ticket)
{
   if(IsTesting() || ticket<0) return;
   GSV11_g_feat[GSV11_F_MFE]=GSV11_g_posMaxFav;
   GSV11_g_feat[GSV11_F_MAE]=GSV11_g_posMaxAdv;
   GlobalVariableSet(GSV11_TicketKey(ticket,GSV11_g_featKey[GSV11_F_MFE]),GSV11_g_feat[GSV11_F_MFE]);
   GlobalVariableSet(GSV11_TicketKey(ticket,GSV11_g_featKey[GSV11_F_MAE]),GSV11_g_feat[GSV11_F_MAE]);
}

void GSV11_DropTicketState(const int ticket)
{
   if(IsTesting() || ticket<0) return;
   for(int i=0;i<GSV11_GS_FEAT_COUNT;i++)
      GlobalVariableDel(GSV11_TicketKey(ticket,GSV11_g_featKey[i]));
}

// Adopt a position found in the terminal (fresh entry or restart).
// The caller must have selected this ticket: the opening excursion is
// read from the currently selected order.
void GSV11_AdoptTicket(const int ticket)
{
   GSV11_g_posTicket=ticket;
   double move=GSV11_ProfitMovementSelected();
   GSV11_g_posMaxFav=MathMax(0.0,move);
   GSV11_g_posMaxAdv=MathMin(0.0,move);
   if(!IsTesting())
   {
      // A ticket already known to us restores its excursions and the
      // conditions it was opened in; a brand new one keeps the snapshot
      // GSV11_SendEntry just took.
      for(int i=0;i<GSV11_GS_FEAT_COUNT;i++)
      {
         string key=GSV11_TicketKey(ticket,GSV11_g_featKey[i]);
         if(GlobalVariableCheck(key)) GSV11_g_feat[i]=GlobalVariableGet(key);
      }
      GSV11_g_posMaxFav=MathMax(GSV11_g_posMaxFav,GSV11_g_feat[GSV11_F_MFE]);
      GSV11_g_posMaxAdv=MathMin(GSV11_g_posMaxAdv,GSV11_g_feat[GSV11_F_MAE]);
      GSV11_PersistTicketState(ticket);
   }
}

void GSV11_ForgetPosition()
{
   GSV11_DropTicketState(GSV11_g_posTicket);
   GSV11_g_posTicket=-1;
   GSV11_g_posMaxFav=0.0;
   GSV11_g_posMaxAdv=0.0;
   GSV11_g_pendingClose=false;
   GSV11_g_pendingCloseReason="";
   GSV11_g_stopRepairTicket=-1;
   GSV11_g_stopRepairFailures=0;
}

//+------------------------------------------------------------------+
//| close / entry execution                                           |
//+------------------------------------------------------------------+
bool GSV11_IsRetryableTradeError(const int error)
{
   return(error==4 || error==6 || error==128 || error==135 || error==136 ||
          error==137 || error==138 || error==146);
}

bool GSV11_CloseSelectedOrder(const string reason)
{
   int ticket=OrderTicket();
   double lots=OrderLots();
   int type=OrderType();
   int finalError=0;
   for(int attempt=1;attempt<=GSV11_GS_CLOSE_RETRY_ATTEMPTS;attempt++)
   {
      if(!OrderSelect(ticket,SELECT_BY_TICKET)) { finalError=GetLastError(); break; }
      RefreshRates();
      double price=(type==OP_BUY ? Bid : Ask);
      ResetLastError();
      if(OrderClose(ticket,lots,price,GSV11_SlippagePoints(),clrSilver))
      {
         double profit=0.0;
         bool haveHistory=OrderSelect(ticket,SELECT_BY_TICKET,MODE_HISTORY);
         if(haveHistory)
            profit=OrderProfit()+OrderSwap()+OrderCommission();
         LedgerWrite("EXIT",(type==OP_BUY?1:-1),lots,price,profit,reason);
         // The dataset is the file we tune from. A close the EA performs
         // itself must land there too, or exactly the pathological
         // trades go unrecorded. GSV11_ForgetPosition() below zeroes the
         // excursions, so this has to happen first.
         if(haveHistory)
         {
            GSV11_g_feat[GSV11_F_MFE]=GSV11_g_posMaxFav;
            GSV11_g_feat[GSV11_F_MAE]=GSV11_g_posMaxAdv;
            GSV11_DatasetWrite(profit,reason);
         }
         if(GSV11_PUSH_ALERTS)
            SendNotification(StringFormat("GoldScalper closed %.2f lot: %s (%.2f)",lots,reason,profit));
         GSV11_g_lastAction="CLOSED: "+reason;
         GSV11_ForgetPosition();
         GSV11_InvalidateDayCache();
         Print("GoldScalper: closed ticket ",ticket,": ",reason);
         return(true);
      }
      finalError=GetLastError();
      if(!GSV11_IsRetryableTradeError(finalError)) break;
      RefreshRates();
      if(!IsTesting()) Sleep(100);
   }
   GSV11_g_pendingClose=true;
   GSV11_g_pendingCloseReason=reason;
   GSV11_g_lastAction=StringFormat("CLOSE RETRY PENDING %d",finalError);
   Print("GoldScalper: close pending, ticket ",ticket,", error ",finalError,", reason ",reason);
   return(false);
}

bool GSV11_SendEntry(const int dir,const int module,const double fadeTarget)
{
   RefreshRates();
   double ask=Ask, bid=Bid;
   if(ask<=0.0 || bid<=0.0 || ask<bid)
      { GSV11_g_lastAction="ENTRY BLOCKED: NO QUOTE"; return(false); }
   double spread=ask-bid;
   if(GSV11_MaxSpread_PriceUSD>0.0 && spread>GSV11_MaxSpread_PriceUSD)
      { GSV11_g_lastAction="ENTRY BLOCKED: SPREAD"; return(false); }
   double entry=(dir>0 ? ask : bid);

   double lots=GSV11_NormaliseLots(GSV11_LotSize);
   if(lots<=0.0) { GSV11_g_lastAction="ENTRY BLOCKED: LOT INVALID"; return(false); }
   int type=(dir>0 ? OP_BUY : OP_SELL);
   if(AccountFreeMarginCheck(Symbol(),type,lots)<=0.0)
      { GSV11_g_lastAction="ENTRY BLOCKED: MARGIN"; return(false); }

   // The broker rejects stops closer than its own minimum. Honour that
   // minimum here rather than letting OrderSend fail, fall back to a
   // naked order and then close the position it just opened.
   double minDist=GSV11_BrokerModifyDistance();
   double slDist=GSV11_StopLoss_PriceUSD;
   double tpDist=GSV11_TakeProfit_PriceUSD;
   if(slDist>0.0 && minDist>0.0 && slDist<minDist)
   {
      Print("GoldScalper: GSV11_StopLoss_PriceUSD ",DoubleToString(GSV11_StopLoss_PriceUSD,2),
            " is inside the broker minimum ",DoubleToString(minDist,2),
            "; the stop is placed at the broker minimum.");
      slDist=minDist;
   }
   if(tpDist>0.0 && minDist>0.0 && tpDist<minDist)
   {
      Print("GoldScalper: GSV11_TakeProfit_PriceUSD ",DoubleToString(GSV11_TakeProfit_PriceUSD,2),
            " is inside the broker minimum ",DoubleToString(minDist,2),
            "; the target is placed at the broker minimum.");
      tpDist=minDist;
   }

   double sl=(slDist>0.0 ? (dir>0 ? entry-slDist : entry+slDist) : 0.0);
   double tp=0.0;
   if(tpDist>0.0)
      tp=(dir>0 ? entry+tpDist : entry-tpDist);
   else if(module==2 && fadeTarget>0.0 &&
           MathAbs(fadeTarget-entry)>minDist && dir*(fadeTarget-entry)>0.0)
      tp=fadeTarget;
   sl=(sl>0.0 ? NormalizeDouble(sl,Digits) : 0.0);
   tp=(tp>0.0 ? NormalizeDouble(tp,Digits) : 0.0);
   double intendedTP=tp;   // survives the ECN fallback

   string comment=StringFormat(module==2 ? "GSF_%d" : "GSM_%d",(int)TimeCurrent());
   ResetLastError();
   int ticket=OrderSend(Symbol(),type,lots,entry,GSV11_SlippagePoints(),sl,tp,comment,GSV11_MAGIC_NUMBER,0,
                        (dir>0 ? clrLime : clrTomato));
   int firstError=GetLastError();
   bool usedFallback=false;
   if(ticket<0 && GSV11_ECN_FALLBACK && firstError==ERR_INVALID_STOPS)
   {
      RefreshRates();
      entry=(dir>0 ? Ask : Bid);
      spread=Ask-Bid;          // the fallback re-quotes: record what we pay
      if(GSV11_MaxSpread_PriceUSD>0.0 && spread>GSV11_MaxSpread_PriceUSD)
         { GSV11_g_lastAction="ENTRY ABORTED: SPREAD"; return(false); }
      ResetLastError();
      ticket=OrderSend(Symbol(),type,lots,entry,GSV11_SlippagePoints(),0.0,0.0,comment,GSV11_MAGIC_NUMBER,0,
                       (dir>0 ? clrLime : clrTomato));
      usedFallback=(ticket>=0);
      firstError=GetLastError();
   }
   if(ticket<0)
   {
      GSV11_g_lastAction=StringFormat("ENTRY FAILED %d",firstError);
      Print("GoldScalper: OrderSend failed, error ",firstError);
      return(false);
   }

   GSV11_g_lastEntryTime=TimeCurrent();
   if(!IsTesting()) GlobalVariableSet(GSV11_AccountKey("LASTENTRY"),(double)GSV11_g_lastEntryTime);
   GSV11_InvalidateDayCache();

   if(OrderSelect(ticket,SELECT_BY_TICKET))
   {
      double open=OrderOpenPrice();
      double exactSL=(slDist>0.0 ? (dir>0 ? open-slDist : open+slDist) : 0.0);
      // re-anchor a fixed target to the real fill; a fade target is an
      // absolute price and must be carried through the fallback intact
      double exactTP=(tpDist>0.0 ? (dir>0 ? open+tpDist : open-tpDist) : intendedTP);
      exactSL=(exactSL>0.0 ? NormalizeDouble(exactSL,Digits) : 0.0);
      exactTP=(exactTP>0.0 ? NormalizeDouble(exactTP,Digits) : 0.0);
      if(usedFallback || MathAbs(OrderStopLoss()-exactSL)>Point || MathAbs(OrderTakeProfit()-exactTP)>Point)
      {
         ResetLastError();
         if(!OrderModify(ticket,open,exactSL,exactTP,0,clrNONE) && slDist>0.0)
         {
            // refuse to run unprotected: close rather than hold a naked position
            Print("GoldScalper: stop anchoring failed, error ",GetLastError());
            GSV11_g_pendingClose=true;
            GSV11_g_pendingCloseReason="PROTECTIVE STOP COULD NOT BE SET";
            if(OrderSelect(ticket,SELECT_BY_TICKET) && GSV11_CloseSelectedOrder(GSV11_g_pendingCloseReason))
            {
               GSV11_g_lastAction="ENTRY OPENED THEN CLOSED: STOP FAILED";
               return(false);
            }
            GSV11_g_lastAction="UNPROTECTED ENTRY: CLOSE PENDING";
            GSV11_SnapshotEntryFeatures(spread);
            GSV11_AdoptTicket(ticket);
            return(true);
         }
      }
      GSV11_SnapshotEntryFeatures(spread);
      GSV11_AdoptTicket(ticket);
   }
   else
   {
      GSV11_SnapshotEntryFeatures(spread);
      GSV11_g_posTicket=ticket;
   }

   GSV11_g_lastAction=StringFormat("OPENED %s %.2f LOT (%s)",dir>0?"BUY":"SELL",lots,
                             module==2?"FADE":"MOMENTUM");
   LedgerWrite("ENTRY",dir,lots,entry,0.0,module==2?"fade":"momentum");
   if(GSV11_PUSH_ALERTS)
      SendNotification(StringFormat("GoldScalper opened %s %.2f lot (%s)",
                       dir>0?"BUY":"SELL",lots,module==2?"fade":"momentum"));
   return(true);
}

//+------------------------------------------------------------------+
//| stop protection + scalp management (every tick)                   |
//+------------------------------------------------------------------+
bool GSV11_EnsureStopProtection()
{
   if(GSV11_StopLoss_PriceUSD<=0.0) return(true);
   int ticket=OrderTicket();
   if(OrderStopLoss()>0.0)
   {
      GSV11_g_stopRepairTicket=ticket;
      GSV11_g_stopRepairFailures=0;
      return(true);
   }
   if(GSV11_g_stopRepairTicket!=ticket)
   {
      GSV11_g_stopRepairTicket=ticket;
      GSV11_g_stopRepairFailures=0;
   }
   RefreshRates();
   bool isBuy=(OrderType()==OP_BUY);
   double minDist=GSV11_BrokerModifyDistance();
   double repairDist=MathMax(GSV11_StopLoss_PriceUSD,minDist);
   double repair=(isBuy ? OrderOpenPrice()-repairDist : OrderOpenPrice()+repairDist);
   if(isBuy) repair=MathMin(repair,Bid-minDist);
   else      repair=MathMax(repair,Ask+minDist);
   repair=NormalizeDouble(repair,Digits);
   ResetLastError();
   if(OrderModify(ticket,OrderOpenPrice(),repair,OrderTakeProfit(),0,clrNONE))
   {
      GSV11_g_stopRepairFailures=0;
      GSV11_g_lastAction="PROTECTIVE STOP REPAIRED";
      return(true);
   }
   int repairError=GetLastError();
   if(repairError==ERR_NO_RESULT)
   {
      // "no changes" is not a failure: the stop is already where we want it
      GSV11_g_stopRepairFailures=0;
      return(true);
   }
   GSV11_g_stopRepairFailures++;
   Print("GoldScalper: stop repair failed, attempt ",GSV11_g_stopRepairFailures,
         ", error ",repairError);
   if(GSV11_g_stopRepairFailures>=GSV11_GS_STOP_REPAIR_LIMIT)
      GSV11_CloseSelectedOrder("UNPROTECTED POSITION");
   return(false);
}

void GSV11_ApplyStopManagement()
{
   RefreshRates();
   bool isBuy=(OrderType()==OP_BUY);
   double desired=OrderStopLoss();
   bool haveDesired=(desired>0.0);

   // profit lock: once movement reached the trigger, the stop holds at
   // least entry +/- LockedProfit for the rest of the trade
   if(GSV11_LockTrigger_PriceUSD>0.0 && GSV11_g_posMaxFav>=GSV11_LockTrigger_PriceUSD)
   {
      double lock=(isBuy ? OrderOpenPrice()+GSV11_LockedProfit_PriceUSD
                         : OrderOpenPrice()-GSV11_LockedProfit_PriceUSD);
      if(!haveDesired || (isBuy && lock>desired) || (!isBuy && lock<desired))
         { desired=lock; haveDesired=true; }
   }
   // manual trailing stop: fixed distance behind price once started
   if(GSV11_TrailingStart_PriceUSD>0.0 && GSV11_TrailingDistance_PriceUSD>0.0 &&
      GSV11_g_posMaxFav>=GSV11_TrailingStart_PriceUSD)
   {
      double trail=(isBuy ? Bid-GSV11_TrailingDistance_PriceUSD : Ask+GSV11_TrailingDistance_PriceUSD);
      if(!haveDesired || (isBuy && trail>desired) || (!isBuy && trail<desired))
         { desired=trail; haveDesired=true; }
   }
   if(!haveDesired) return;

   double minDist=GSV11_BrokerModifyDistance();
   if(isBuy) desired=MathMin(desired,Bid-minDist);
   else      desired=MathMax(desired,Ask+minDist);
   desired=NormalizeDouble(desired,Digits);

   double oldStop=OrderStopLoss();
   bool improves=(oldStop<=0.0 || (isBuy && desired>oldStop) || (!isBuy && desired<oldStop));
   if(!improves) return;
   if(oldStop>0.0 && MathAbs(desired-oldStop)<MathMax(GSV11_TRAIL_STEP_USD,Point)) return;

   ResetLastError();
   if(!OrderModify(OrderTicket(),OrderOpenPrice(),desired,OrderTakeProfit(),0,clrDodgerBlue))
   {
      int error=GetLastError();
      if(error!=ERR_NO_RESULT)
         Print("GoldScalper: stop modify failed, error ",error);
   }
}

void GSV11_ManagePosition()
{
   int ticket=GSV11_FindManagedTicket();
   if(ticket<0)
   {
      if(GSV11_g_posTicket>=0)
      {
         GSV11_JournalClosedTicket(GSV11_g_posTicket);
         GSV11_ForgetPosition();
         GSV11_InvalidateDayCache();
      }
      return;
   }
   if(!OrderSelect(ticket,SELECT_BY_TICKET)) return;
   if(ticket!=GSV11_g_posTicket)
   {
      // A partial close re-tickets the remainder. Journal the leg that
      // closed, then carry the high-water mark across: the profit lock
      // and the trailing stop both measure from it, and restarting it
      // at the current excursion would stall them.
      int previous=GSV11_g_posTicket;
      double carriedFav=GSV11_g_posMaxFav;
      double carriedAdv=GSV11_g_posMaxAdv;
      if(previous>=0)
      {
         GSV11_JournalClosedTicket(previous);          // selects the history order
         GSV11_DropTicketState(previous);
         if(!OrderSelect(ticket,SELECT_BY_TICKET)) return;   // re-select the live one
      }
      GSV11_AdoptTicket(ticket);
      if(previous>=0)
      {
         // Both excursions must cross explicitly. The adverse one only
         // survived before because the feature array happened to still
         // hold the old value - accident, not design.
         bool carriedSomething=false;
         if(carriedFav>GSV11_g_posMaxFav) { GSV11_g_posMaxFav=carriedFav; carriedSomething=true; }
         if(carriedAdv<GSV11_g_posMaxAdv) { GSV11_g_posMaxAdv=carriedAdv; carriedSomething=true; }
         if(carriedSomething) GSV11_PersistTicketState(ticket);
      }
   }

   // Excursions are recorded before anything can return early. The lock
   // and the trailing stop measure from the favourable one, and both
   // feed the dataset - a stop repair failing must not blind them.
   double movement=GSV11_ProfitMovementSelected();
   if(movement>GSV11_g_posMaxFav)
   {
      bool persist=(movement-GSV11_g_posMaxFav>0.05);
      GSV11_g_posMaxFav=movement;
      if(persist) GSV11_PersistExcursions(ticket);
   }
   if(movement<GSV11_g_posMaxAdv)
   {
      bool persistAdv=(GSV11_g_posMaxAdv-movement>0.05);
      GSV11_g_posMaxAdv=movement;
      if(persistAdv) GSV11_PersistExcursions(ticket);
   }

   if(GSV11_g_pendingClose) { GSV11_CloseSelectedOrder(GSV11_g_pendingCloseReason); return; }
   if(!GSV11_EnsureStopProtection()) return;

   GSV11_ApplyStopManagement();
}

//+------------------------------------------------------------------+
//| entry gating                                                      |
//+------------------------------------------------------------------+
bool GSV11_EntryAllowed(const int dir,string &blocker)
{
   if(dir>0 && !GSV11_ALLOW_LONGS)  { blocker="longs disabled"; return(false); }
   if(dir<0 && !GSV11_ALLOW_SHORTS) { blocker="shorts disabled"; return(false); }
   if(!IsTesting() && !IsTradeAllowed()) { blocker="AutoTrading off"; return(false); }
   if(GSV11_FindManagedTicket()>=0) { blocker="position open"; return(false); }

   datetime now=TimeCurrent();
   if(GSV11_BlackoutActive(now)) { blocker="news blackout"; return(false); }
   if(GSV11_CooldownSeconds>0 && GSV11_g_lastEntryTime>0 && now-GSV11_g_lastEntryTime<GSV11_CooldownSeconds)
      { blocker="cooldown"; return(false); }

   GSV11_RefreshDayCache();
   if(GSV11_MaxTradesPerDay>0 && GSV11_g_tradesToday>=GSV11_MaxTradesPerDay)
      { blocker="daily trade cap"; return(false); }
   if(GSV11_MaxConsecutiveLosses>0 && GSV11_g_consecLosses>=GSV11_MaxConsecutiveLosses)
   {
      if(GSV11_LossPauseMinutes<=0) { blocker="loss streak - down for the day"; return(false); }
      if(GSV11_g_lastLossClose>0 && now-GSV11_g_lastLossClose<GSV11_LossPauseMinutes*60)
         { blocker="loss streak pause"; return(false); }
   }
   blocker="";
   return(true);
}

//+------------------------------------------------------------------+
//| panel: opaque sectioned status board                              |
//+------------------------------------------------------------------+
void PanelBox(const string suffix,const int x,const int y,const int width,
              const int height,const color background,const color border,
              const int zOrder=0)
{
   string name=GSV11_GS_PANEL_PREFIX+suffix;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,background);
   ObjectSetInteger(0,name,OBJPROP_COLOR,border);
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);   // false = painted over the candles: opaque
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,zOrder);
}

void PanelText(const string suffix,const string text,const int x,const int y,
               const color textColor,const int fontSize=9,
               const int anchor=ANCHOR_LEFT_UPPER,const string fontName="Arial")
{
   string name=GSV11_GS_PANEL_PREFIX+suffix;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,anchor);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,textColor);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontSize);
   ObjectSetString(0,name,OBJPROP_FONT,fontName);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,1);
}

void GSV11_PanelDivider(const string suffix,const int y)
{
   PanelBox(suffix,GSV11_PANEL_LABEL_X,y,GSV11_PANEL_WIDTH-36,1,GSV11_PANEL_DIVIDER,GSV11_PANEL_DIVIDER,1);
}

void GSV11_PanelSection(const string suffix,const string title,const int titleY,const int lineY)
{
   PanelText(suffix+"Title",title,GSV11_PANEL_LABEL_X,titleY,GSV11_PANEL_SECTION,9);
   GSV11_PanelDivider(suffix+"Line",lineY);
}

void GSV11_PanelPair(const string suffix,const string label,const int y)
{
   PanelText(suffix+"L",label,GSV11_PANEL_LABEL_X,y,GSV11_PANEL_LABEL,9);
   PanelText(suffix+"V","--",GSV11_PANEL_VALUE_X,y,GSV11_PANEL_VALUE,9,ANCHOR_RIGHT_UPPER);
}

void GSV11_PanelValue(const string suffix,const int y,const string text,const color clr)
{
   PanelText(suffix+"V",text,GSV11_PANEL_VALUE_X,y,clr,9,ANCHOR_RIGHT_UPPER);
}

// Right-anchored values overrun the label if they get long; keep them
// inside the panel by trimming with a visible ellipsis.
string GSV11_PanelFit(const string s,const int maxChars)
{
   if(StringLen(s)<=maxChars) return(s);
   return(StringSubstr(s,0,maxChars-1)+"~");
}

string GSV11_PanelPrice(const double v)
{
   return(v>0.0 ? "$"+DoubleToString(v,2) : "off");
}

void GSV11_CreatePanel()
{
   if(!GSV11_SHOW_PANEL) return;
   Comment("");
   PanelBox("BG",GSV11_PANEL_LEFT,GSV11_PANEL_TOP,GSV11_PANEL_WIDTH,GSV11_PANEL_HEIGHT,
            GSV11_PANEL_BG,GSV11_PANEL_BORDER,0);
   PanelText("Title","XVISION  |  CONSOLIDATED SCRAPER V2",GSV11_PANEL_LABEL_X,22,
             GSV11_PANEL_TITLE,13);
   PanelText("Subtitle","M1 TRIGGER  |  M5 CONTEXT  |  YOUR EXITS",GSV11_PANEL_LABEL_X,42,
             GSV11_PANEL_MUTED,9);
   GSV11_PanelDivider("HeaderLine",58);

   GSV11_PanelSection("St","STATUS",64,78);
   PanelText("StatusMessage","INITIALISING",GSV11_PANEL_LABEL_X,GSV11_ROW_STATUS,GSV11_PANEL_VALUE,11);
   GSV11_PanelPair("Sig","Signal / module",GSV11_ROW_SIG);
   GSV11_PanelPair("Blk","Gates failing",GSV11_ROW_BLK);
   GSV11_PanelPair("Pos","Position",GSV11_ROW_POS);

   GSV11_PanelSection("Mg","TRADE MANAGEMENT",160,174);
   GSV11_PanelPair("Lot","Requested / executable lot",GSV11_ROW_LOT);
   GSV11_PanelPair("Stp","Stop loss / take profit",GSV11_ROW_STP);
   GSV11_PanelPair("Lck","Lock trigger / locked profit",GSV11_ROW_LCK);
   GSV11_PanelPair("Trl","Trailing start / distance",GSV11_ROW_TRL);
   GSV11_PanelPair("Scr","Spread ceiling / daily cap",GSV11_ROW_SCR);
   GSV11_PanelPair("Own","Exit ownership",GSV11_ROW_OWN);

   GSV11_PanelSection("En","ENGINE",285,299);
   GSV11_PanelPair("Reg","Regime  N / D / I / X / S",GSV11_ROW_REG);
   GSV11_PanelPair("Cus","ER / CUSUM up / dn",GSV11_ROW_CUS);
   GSV11_PanelPair("Atr","Trend / ATR M1 / M5 / exp",GSV11_ROW_ATR);

   GSV11_PanelSection("Lv","LIVE",359,373);
   GSV11_PanelPair("Tim","Broker time",GSV11_ROW_TIM);
   GSV11_PanelPair("Prc","Live Bid / Ask",GSV11_ROW_PRC);
   GSV11_PanelPair("Spr","Spread / permission",GSV11_ROW_SPR);
   GSV11_PanelPair("Ses","News blackout / loss pause",GSV11_ROW_SES);

   GSV11_PanelDivider("FooterLine",452);
   PanelText("Today","--",GSV11_PANEL_LABEL_X,GSV11_ROW_TODAY,GSV11_PANEL_VALUE,9);
   PanelText("Footer","ONE POSITION  |  EXITS OWNED BY YOUR INPUTS",
             GSV11_PANEL_LABEL_X,GSV11_ROW_FOOTER,GSV11_PANEL_MUTED,8);
}

void GSV11_DeletePanel()
{
   ObjectsDeleteAll(0,GSV11_GS_PANEL_PREFIX);
   GSV11_g_lastPanelMs=0;
}

void GSV11_UpdatePanel(const bool force=false)
{
   if(!GSV11_SHOW_PANEL) return;
   uint nowMs=GetTickCount();
   if(!force && nowMs-GSV11_g_lastPanelMs<300) return;   // gold ticks fast; don't repaint every tick
   GSV11_g_lastPanelMs=nowMs;
   if(ObjectFind(0,GSV11_GS_PANEL_PREFIX+"BG")<0) GSV11_CreatePanel();

   RefreshRates();
   GSV11_RefreshDayCache();
   bool armed=(IsTesting() || IsTradeAllowed());
   int ticket=GSV11_FindManagedTicket();
   bool havePos=(ticket>=0 && OrderSelect(ticket,SELECT_BY_TICKET));
   bool capHit=(GSV11_MaxTradesPerDay>0 && GSV11_g_tradesToday>=GSV11_MaxTradesPerDay);
   bool streakHit=(GSV11_MaxConsecutiveLosses>0 && GSV11_g_consecLosses>=GSV11_MaxConsecutiveLosses &&
                   (GSV11_LossPauseMinutes<=0 ||
                    (GSV11_g_lastLossClose>0 && TimeCurrent()-GSV11_g_lastLossClose<GSV11_LossPauseMinutes*60)));

   //--- headline state
   string state; color stateClr;
   if(!armed)                      { state="STANDBY - AUTOTRADING IS OFF";   stateClr=GSV11_PANEL_AMBER; }
   else if(havePos)                { state="MANAGING LIVE POSITION";         stateClr=GSV11_PANEL_GREEN; }
   else if(capHit)                 { state="DAILY TRADE CAP REACHED";        stateClr=GSV11_PANEL_AMBER; }
   else if(streakHit)              { state="LOSS STREAK - PAUSED";           stateClr=GSV11_PANEL_RED;   }
   else if(GSV11_BlackoutActive(TimeCurrent())) { state="NEWS BLACKOUT";           stateClr=GSV11_PANEL_AMBER; }
   else if(GSV11_g_signalDir!=0)         { state="QUALIFIED SIGNAL";               stateClr=GSV11_PANEL_GREEN; }
   else                            { state="SCANNING FOR A QUALIFIED BURST"; stateClr=GSV11_PANEL_VALUE; }
   PanelText("StatusMessage",state,GSV11_PANEL_LABEL_X,GSV11_ROW_STATUS,stateClr,11);

   //--- status block
   string sigTxt="NONE";
   color  sigClr=GSV11_PANEL_VALUE;
   if(GSV11_g_signalDir>0) { sigTxt="BUY";  sigClr=GSV11_PANEL_GREEN; }
   if(GSV11_g_signalDir<0) { sigTxt="SELL"; sigClr=GSV11_PANEL_MAGENTA; }
   if(GSV11_g_signalDir!=0) sigTxt=sigTxt+(GSV11_g_signalModule==2?"  (FADE)":"  (MOMENTUM)");
   GSV11_PanelValue("Sig",GSV11_ROW_SIG,sigTxt,sigClr);

   GSV11_PanelValue("Blk",GSV11_ROW_BLK,StringLen(GSV11_g_blocker)==0 ? "clear" : GSV11_PanelFit(GSV11_g_blocker,46),
              StringLen(GSV11_g_blocker)==0 ? GSV11_PANEL_GREEN : GSV11_PANEL_AMBER);

   if(havePos)
   {
      double move=GSV11_ProfitMovementSelected();
      GSV11_PanelValue("Pos",GSV11_ROW_POS,StringFormat("%s %.2f  %+.2f   peak %+.2f  dip %.2f",
                 OrderType()==OP_BUY?"BUY":"SELL",OrderLots(),move,
                 GSV11_g_posMaxFav,GSV11_g_posMaxAdv),
                 move>=0.0?GSV11_PANEL_GREEN:GSV11_PANEL_RED);
   }
   else
      GSV11_PanelValue("Pos",GSV11_ROW_POS,"NONE",GSV11_PANEL_MUTED);

   //--- trade management (mirrors the Inputs tab)
   double executable=GSV11_NormaliseLots(GSV11_LotSize);
   GSV11_PanelValue("Lot",GSV11_ROW_LOT,StringFormat("%.2f / %.2f",GSV11_LotSize,executable),
              executable>0.0?GSV11_PANEL_VALUE:GSV11_PANEL_RED);
   GSV11_PanelValue("Stp",GSV11_ROW_STP,GSV11_PanelPrice(GSV11_StopLoss_PriceUSD)+" / "+GSV11_PanelPrice(GSV11_TakeProfit_PriceUSD),
              GSV11_PANEL_VALUE);
   GSV11_PanelValue("Lck",GSV11_ROW_LCK,GSV11_PanelPrice(GSV11_LockTrigger_PriceUSD)+" / "+GSV11_PanelPrice(GSV11_LockedProfit_PriceUSD),
              GSV11_LockTrigger_PriceUSD>0.0?GSV11_PANEL_GREEN:GSV11_PANEL_MUTED);
   GSV11_PanelValue("Trl",GSV11_ROW_TRL,GSV11_PanelPrice(GSV11_TrailingStart_PriceUSD)+" / "+GSV11_PanelPrice(GSV11_TrailingDistance_PriceUSD),
              (GSV11_TrailingStart_PriceUSD>0.0&&GSV11_TrailingDistance_PriceUSD>0.0)?GSV11_PANEL_GREEN:GSV11_PANEL_MUTED);
   GSV11_PanelValue("Scr",GSV11_ROW_SCR,StringFormat("%s / %s",
              GSV11_MaxSpread_PriceUSD>0.0?"$"+DoubleToString(GSV11_MaxSpread_PriceUSD,2):"off",
              GSV11_MaxTradesPerDay>0?IntegerToString(GSV11_MaxTradesPerDay):"uncapped"),
              capHit?GSV11_PANEL_AMBER:GSV11_PANEL_VALUE);
   string ownership="";
   if(GSV11_StopLoss_PriceUSD>0.0)   ownership="EA SL";
   if(GSV11_TakeProfit_PriceUSD>0.0) ownership=(StringLen(ownership)>0?ownership+" + EA TP":"EA TP");
   if(GSV11_TrailingStart_PriceUSD>0.0 && GSV11_TrailingDistance_PriceUSD>0.0)
      ownership=(StringLen(ownership)>0?ownership+" + trail":"trail");
   if(StringLen(ownership)==0) ownership="MANUAL - no EA exit";
   GSV11_PanelValue("Own",GSV11_ROW_OWN,ownership,
              GSV11_StopLoss_PriceUSD<=0.0 ? GSV11_PANEL_AMBER : GSV11_PANEL_VALUE);

   //--- engine
   GSV11_PanelValue("Reg",GSV11_ROW_REG,StringFormat("%.2f  %.2f  %.2f  %.2f  %.2f",
              GSV11_g_modeNoise,GSV11_g_modeDrift,GSV11_g_modeImpulse,GSV11_g_modeExhaustion,GSV11_g_modeShock),
              (GSV11_MaxShockExhaustion>0.0 &&
               GSV11_g_modeShock+GSV11_g_modeExhaustion>GSV11_MaxShockExhaustion)?GSV11_PANEL_AMBER:GSV11_PANEL_VALUE);
   GSV11_PanelValue("Cus",GSV11_ROW_CUS,StringFormat("%+.2f  /  %.1f / %.1f  (need %.1f)",
              GSV11_g_er,GSV11_g_cusumUp,GSV11_g_cusumDown,GSV11_CusumTrigger),
              (MathMax(GSV11_g_cusumUp,GSV11_g_cusumDown)>=GSV11_CusumTrigger)?GSV11_PANEL_GREEN:GSV11_PANEL_VALUE);
   string trendTxt=(GSV11_TrendFilterMode<=0 ? "off" :
                    (GSV11_g_trendDir>0 ? "UP" : (GSV11_g_trendDir<0 ? "DOWN" : "flat")));
   GSV11_PanelValue("Atr",GSV11_ROW_ATR,StringFormat("%s %+.2f / %.2f / %.2f / %.2fx",
              trendTxt,GSV11_g_trendDistATR,GSV11_g_atrM1,GSV11_g_atrM5,GSV11_g_expansion),
              (GSV11_TrendFilterMode>0 && GSV11_g_trendDir>0) ? GSV11_PANEL_GREEN :
              ((GSV11_TrendFilterMode>0 && GSV11_g_trendDir<0) ? GSV11_PANEL_MAGENTA : GSV11_PANEL_VALUE));

   //--- live
   GSV11_PanelValue("Tim",GSV11_ROW_TIM,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),GSV11_PANEL_AMBER);
   GSV11_PanelValue("Prc",GSV11_ROW_PRC,DoubleToString(Bid,Digits)+" / "+DoubleToString(Ask,Digits),GSV11_PANEL_VALUE);
   double spread=Ask-Bid;
   bool spreadOK=(GSV11_MaxSpread_PriceUSD<=0.0 || spread<=GSV11_MaxSpread_PriceUSD);
   GSV11_PanelValue("Spr",GSV11_ROW_SPR,StringFormat("%.2f (max %.2f) / %s",spread,GSV11_MaxSpread_PriceUSD,
              armed?"ENABLED":"DISABLED"),
              (spreadOK&&armed)?GSV11_PANEL_GREEN:GSV11_PANEL_AMBER);
   GSV11_PanelValue("Ses",GSV11_ROW_SES,StringFormat("%s / %s",
              GSV11_BlackoutActive(TimeCurrent())?"ACTIVE":"clear",
              streakHit?"PAUSED":"clear"),
              (GSV11_BlackoutActive(TimeCurrent())||streakHit)?GSV11_PANEL_AMBER:GSV11_PANEL_GREEN);

   //--- today
   string today=StringFormat("TODAY   trades %d/%s   PnL %+.2f   streak %d/%s",
      GSV11_g_tradesToday,GSV11_MaxTradesPerDay>0?IntegerToString(GSV11_MaxTradesPerDay):"unc",
      GSV11_g_closedPnLToday,GSV11_g_consecLosses,
      GSV11_MaxConsecutiveLosses>0?IntegerToString(GSV11_MaxConsecutiveLosses):"-");
   PanelText("Today",today,GSV11_PANEL_LABEL_X,GSV11_ROW_TODAY,
             streakHit?GSV11_PANEL_RED:(GSV11_g_closedPnLToday>0.0?GSV11_PANEL_GREEN:GSV11_PANEL_VALUE),9);
   PanelText("Footer",GSV11_PanelFit("LAST: "+GSV11_g_lastAction,62),GSV11_PANEL_LABEL_X,GSV11_ROW_FOOTER,GSV11_PANEL_MUTED,8);
}

//+------------------------------------------------------------------+
//| input validation + orphan sweep                                   |
//+------------------------------------------------------------------+
bool GSV11_ValidateInputs()
{
   if(GSV11_LotSize<=0.0)
   {
      Print("GoldScalper: GSV11_LotSize must be positive.");
      return(false);
   }
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(step>0.0 && GSV11_NormaliseLots(GSV11_LotSize)<=0.0)
   {
      Print("GoldScalper: GSV11_LotSize ",DoubleToString(GSV11_LotSize,2),
            " is below the broker minimum ",
            DoubleToString(MarketInfo(Symbol(),MODE_MINLOT),GSV11_LotDigits(step)),".");
      return(false);
   }
   if(GSV11_StopLoss_PriceUSD<0.0 || GSV11_TakeProfit_PriceUSD<0.0 ||
      GSV11_LockTrigger_PriceUSD<0.0 || GSV11_LockedProfit_PriceUSD<0.0 ||
      GSV11_TrailingStart_PriceUSD<0.0 || GSV11_TrailingDistance_PriceUSD<0.0)
   {
      Print("GoldScalper: price movement inputs cannot be negative.");
      return(false);
   }
   if(GSV11_LockedProfit_PriceUSD>0.0 && GSV11_LockTrigger_PriceUSD<=0.0)
   {
      Print("GoldScalper: GSV11_LockedProfit_PriceUSD requires a positive GSV11_LockTrigger_PriceUSD.");
      return(false);
   }
   if(GSV11_LockTrigger_PriceUSD>0.0 && GSV11_LockedProfit_PriceUSD>=GSV11_LockTrigger_PriceUSD)
   {
      Print("GoldScalper: GSV11_LockedProfit_PriceUSD must be smaller than GSV11_LockTrigger_PriceUSD.");
      return(false);
   }
   bool trailStart=(GSV11_TrailingStart_PriceUSD>0.0);
   bool trailDist=(GSV11_TrailingDistance_PriceUSD>0.0);
   if(trailStart!=trailDist)
   {
      Print("GoldScalper: GSV11_TrailingStart_PriceUSD and GSV11_TrailingDistance_PriceUSD must both be zero or both be positive.");
      return(false);
   }
   if(GSV11_CusumTrigger<=0.0 || GSV11_CusumAllowance<0.0 || GSV11_CusumDecay<=0.0 || GSV11_CusumDecay>=1.0)
   {
      Print("GoldScalper: GSV11_CusumTrigger must be positive, GSV11_CusumAllowance non-negative, ",
            "and GSV11_CusumDecay strictly between 0 and 1.");
      return(false);
   }
   if(GSV11_MinM1Coherence<0.0 || GSV11_MinM1Coherence>1.0 ||
      GSV11_MinEfficiencyRatio<0.0 || GSV11_MinEfficiencyRatio>1.0 ||
      GSV11_MaxShockExhaustion<0.0 || GSV11_MaxShockExhaustion>1.0 ||
      GSV11_MinImpulseDrift<0.0 || GSV11_MinImpulseDrift>1.0)
   {
      Print("GoldScalper: GSV11_MinM1Coherence, GSV11_MinEfficiencyRatio, GSV11_MaxShockExhaustion ",
            "and GSV11_MinImpulseDrift are fractions and must be between 0 and 1.");
      return(false);
   }
   if(GSV11_TrendFilterMode<0 || GSV11_TrendFilterMode>2)
   {
      Print("GoldScalper: GSV11_TrendFilterMode must be 0 (off), 1 (block against) or 2 (pullback only).");
      return(false);
   }
   if(GSV11_TrendFilterMode>0 && GSV11_M5TrendEMAPeriod<2)
   {
      Print("GoldScalper: GSV11_M5TrendEMAPeriod must be 2 or more when the trend filter is on.");
      return(false);
   }
   if(GSV11_TrendSlopeMinATR<0.0 || GSV11_TrendMaxDistanceATR<0.0)
   {
      Print("GoldScalper: trend slope and distance limits cannot be negative.");
      return(false);
   }
   if(GSV11_MinM1Strength<0.0 || GSV11_MaxBarSizeATR<0.0 || GSV11_MaxMoveMaturityATR<0.0 ||
      GSV11_CusumFreshBars<0 || GSV11_CooldownSeconds<0)
   {
      Print("GoldScalper: entry-engine limits cannot be negative.");
      return(false);
   }
   if(GSV11_MaxSpread_PriceUSD<0.0 || GSV11_MaxTradesPerDay<0 || GSV11_MaxConsecutiveLosses<0 ||
      GSV11_LossPauseMinutes<0)
   {
      Print("GoldScalper: MaxSpread/GSV11_MaxTradesPerDay/GSV11_MaxConsecutiveLosses/GSV11_LossPauseMinutes cannot be negative.");
      return(false);
   }
   if(GSV11_StopLoss_PriceUSD<=0.0 && GSV11_TakeProfit_PriceUSD<=0.0 &&
      (GSV11_TrailingStart_PriceUSD<=0.0 || GSV11_TrailingDistance_PriceUSD<=0.0))
      Print("GoldScalper: note - no SL, no TP and no trailing stop are set. ",
            "Open positions will be closed only by you.");
   return(true);
}

// Sweep per-ticket GlobalVariables left behind by tickets that no
// longer exist or are already closed (EA removed mid-trade, manual
// closes). Runs once at init; the adopted open ticket survives.
void GSV11_CleanOrphanedTicketState()
{
   if(IsTesting()) return;
   string prefix=StringFormat("GS1.%d.%d.",AccountNumber(),GSV11_MAGIC_NUMBER);
   for(int i=GlobalVariablesTotal()-1;i>=0;i--)
   {
      string name=GlobalVariableName(i);
      if(StringFind(name,prefix)!=0) continue;
      string rest=StringSubstr(name,StringLen(prefix));
      int dot=StringFind(rest,".");
      // Account-level keys (GSV11_AccountKey, e.g. "...LASTENTRY") carry no
      // ticket segment. They are not orphans - leave them alone.
      if(dot<0) continue;
      int ticket=(int)StringToInteger(StringSubstr(rest,0,dot));
      if(ticket<=0) continue;
      if(!OrderSelect(ticket,SELECT_BY_TICKET) || OrderCloseTime()>0)
         GlobalVariableDel(name);
   }
}

//+------------------------------------------------------------------+
//| lifecycle                                                         |
//+------------------------------------------------------------------+
int GSV11_OnInit()
{
   if(!GSV11_IsGoldSymbol())
   {
      Print("GoldScalper: attach only to a Gold/XAU symbol. Current: ",Symbol());
      return(INIT_FAILED);
   }
   if(Period()!=PERIOD_M1)
      Print("GoldScalper: designed to run on the M1 chart. Current: ",Period()," min.");
   if(!GSV11_ParseSchedules())
   {
      Print("GoldScalper: could not parse the frozen session/blackout schedule.");
      return(INIT_FAILED);
   }
   if(!GSV11_ValidateInputs()) return(INIT_FAILED);

   Print("GoldScalper: entry gates active - burst>=",DoubleToString(GSV11_CusumTrigger,2),
         (GSV11_CusumFreshBars>0?StringFormat(" within %d bars",GSV11_CusumFreshBars):""),
         (GSV11_MinEfficiencyRatio>0.0?", ER>="+DoubleToString(GSV11_MinEfficiencyRatio,2):""),
         (GSV11_MinM1Strength>0.0?", M1str>="+DoubleToString(GSV11_MinM1Strength,2):""),
         (GSV11_MinM1Coherence>0.0?", coher>="+DoubleToString(GSV11_MinM1Coherence,2):""),
         (GSV11_RequireBarBodyAligned?", body":""),
         (GSV11_MaxBarSizeATR>0.0?", bar<="+DoubleToString(GSV11_MaxBarSizeATR,2)+"xATR":""),
         (GSV11_MaxMoveMaturityATR>0.0?", maturity<="+DoubleToString(GSV11_MaxMoveMaturityATR,2):""),
         (GSV11_RequireM5Alignment?", M5 aligned":""),
         (GSV11_MaxShockExhaustion>0.0?", shock+exh<="+DoubleToString(GSV11_MaxShockExhaustion,2):""),
         (GSV11_MinImpulseDrift>0.0?", imp+drift>="+DoubleToString(GSV11_MinImpulseDrift,2):""),
         (GSV11_TrendFilterMode>0?StringFormat(", M5 EMA%d trend filter mode %d",
                                         GSV11_M5TrendEMAPeriod,GSV11_TrendFilterMode):""),
         ".");

   double minDist=GSV11_BrokerModifyDistance();
   Print("GoldScalper: broker minimum stop/freeze distance is ",
         DoubleToString(minDist,2)," of price.");
   if(minDist>0.0)
   {
      if(GSV11_StopLoss_PriceUSD>0.0 && GSV11_StopLoss_PriceUSD<minDist)
         Print("GoldScalper: WARNING - GSV11_StopLoss_PriceUSD ",
               DoubleToString(GSV11_StopLoss_PriceUSD,2),
               " is inside that minimum; stops will be placed at ",
               DoubleToString(minDist,2)," instead.");
      if(GSV11_TakeProfit_PriceUSD>0.0 && GSV11_TakeProfit_PriceUSD<minDist)
         Print("GoldScalper: WARNING - GSV11_TakeProfit_PriceUSD ",
               DoubleToString(GSV11_TakeProfit_PriceUSD,2),
               " is inside that minimum; targets will be placed at ",
               DoubleToString(minDist,2)," instead.");
   }

   if(!IsTesting() && GlobalVariableCheck(GSV11_AccountKey("LASTENTRY")))
      GSV11_g_lastEntryTime=(datetime)GlobalVariableGet(GSV11_AccountKey("LASTENTRY"));

   int ticket=GSV11_FindManagedTicket();
   if(ticket>=0 && OrderSelect(ticket,SELECT_BY_TICKET))
   {
      GSV11_AdoptTicket(ticket);
      Print("GoldScalper: adopted open ticket ",ticket," after restart.");
   }
   GSV11_CleanOrphanedTicketState();
   EventSetTimer(1);
   GSV11_g_blocker="waiting for M1/M5 history";
   GSV11_g_lastAction="attached";
   GSV11_CreatePanel();
   GSV11_UpdatePanel(true);
   return(INIT_SUCCEEDED);
}

void GSV11_OnDeinit(const int reason)
{
   EventKillTimer();
   GSV11_DeletePanel();
}

void GSV11_OnTick()
{
   GSV11_ManagePosition();

   datetime bar=iTime(Symbol(),PERIOD_M1,0);
   if(bar>0 && bar!=GSV11_g_lastM1Bar)
   {
      GSV11_g_lastM1Bar=bar;
      // The trend EMA needs its own period of M5 bars before iMA
      // returns anything. Without this the filter reports "no M5
      // trend" and blocks every entry with no hint as to why.
      int neededM5=40;
      if(GSV11_TrendFilterMode>0) neededM5=MathMax(neededM5,GSV11_M5TrendEMAPeriod+5);
      int haveM1=iBars(Symbol(),PERIOD_M1);
      int haveM5=iBars(Symbol(),PERIOD_M5);
      if(haveM1>GSV11_ER_PERIOD+60 && haveM5>neededM5)
      {
         GSV11_UpdateRegime(iTime(Symbol(),PERIOD_M1,1));

         string momBlocker="", fadeBlocker="";
         double fadeTarget=0.0;
         int dir=GSV11_EvaluateMomentum(momBlocker);
         int module=1;
         if(dir==0)
         {
            int fdir=GSV11_EvaluateFade(fadeBlocker,fadeTarget);
            if(fdir!=0) { dir=fdir; module=2; }
         }
         GSV11_g_signalDir=dir;
         GSV11_g_signalModule=(dir!=0?module:0);
         GSV11_g_signalRef=iClose(Symbol(),PERIOD_M1,1);

         if(dir!=0)
         {
            string railBlocker="";
            if(GSV11_EntryAllowed(dir,railBlocker))
            {
               LedgerWrite("SIGNAL",dir,0.0,GSV11_g_signalRef,0.0,module==2?"fade":"momentum");
               if(GSV11_SendEntry(dir,module,fadeTarget))
                  GSV11_g_blocker="";
               else
               {
                  GSV11_g_blocker=GSV11_g_lastAction;
                  if(GSV11_LogGateDiagnostics)
                     LedgerWrite("BLOCKED",dir,0.0,GSV11_g_signalRef,0.0,"send: "+GSV11_g_lastAction);
               }
            }
            else
            {
               GSV11_g_blocker=railBlocker;
               if(GSV11_LogGateDiagnostics)
                  LedgerWrite("BLOCKED",dir,0.0,GSV11_g_signalRef,0.0,"rail: "+railBlocker);
            }
         }
         else
         {
            // every gate that failed this bar, not just the first
            if(GSV11_UseMomentumModule && GSV11_USE_FADE)
               GSV11_g_blocker="mom: "+momBlocker+" | fade: "+fadeBlocker;
            else if(GSV11_UseMomentumModule)
               GSV11_g_blocker=momBlocker;
            else if(GSV11_USE_FADE)
               GSV11_g_blocker=fadeBlocker;
            else
               GSV11_g_blocker="all modules off";
            if(GSV11_LogGateDiagnostics)
               LedgerWrite("BLOCKED",0,0.0,GSV11_g_signalRef,0.0,
                           StringLen(GSV11_g_blocker)>0 ? GSV11_g_blocker : "no failure recorded");
         }
      }
      else
         GSV11_g_blocker=StringFormat("history M1 %d/%d, M5 %d/%d",
                                haveM1,GSV11_ER_PERIOD+61,haveM5,neededM5+1);
   }
   GSV11_UpdatePanel();
}

void GSV11_OnTimer()
{
   // quiet-market safety net: retries and panel still run without ticks
   if(GSV11_g_pendingClose)
   {
      int ticket=GSV11_FindManagedTicket();
      if(ticket>=0 && OrderSelect(ticket,SELECT_BY_TICKET))
         GSV11_CloseSelectedOrder(GSV11_g_pendingCloseReason);
      else
         { GSV11_g_pendingClose=false; GSV11_g_pendingCloseReason=""; }
   }
   GSV11_UpdatePanel(true);
}
//+------------------------------------------------------------------+

// ================= XVISION Gold SuperScalper v5 =================
//+------------------------------------------------------------------+
//|                          XVISION_Gold_SuperScalper_v5.mq4        |
//|  Adaptive M1/M5 XAUUSD scalper for MetaTrader 4                  |
//+------------------------------------------------------------------+

// Entry and exposure controls.
input double SSV5_FixedLotSize                = 0.01;
input int    SSV5_MinimumMinutesBetweenEntries= 5;
input int    SSV5_MaximumTradesPerBrokerDay   = 6;    // Maximum trades per broker day (0 = disabled)
input double SSV5_MaximumDailyLossCurrency    = 0.0;  // Maximum daily loss in account currency (0 = disabled)

// Frozen operating policy: automatic two-sided entries, including a valid
// current signal when the EA is attached, with fixed-lot sizing only.
const bool SSV5_AUTOMATIC_ENTRIES_ENABLED      = true;
const bool SSV5_BUY_SIGNALS_ENABLED            = true;
const bool SSV5_SELL_SIGNALS_ENABLED           = true;
const bool SSV5_TRADE_CURRENT_SIGNAL_ON_ATTACH = true;

// Optional broker-side full-position exits.  A zero value disables the
// corresponding initial stop or target; no stop loss is mandatory.
input double SSV5_StopLoss_PriceUSD          = 0.00;
input double SSV5_TakeProfit_PriceUSD        = 0.00;
input double SSV5_LockTrigger_PriceUSD       = 0.00;
input double SSV5_LockedProfit_PriceUSD      = 0.00;
input double SSV5_TrailingStart_PriceUSD     = 0.00;
input double SSV5_TrailingDistance_PriceUSD  = 0.00;

// Clean execution controls, expressed as absolute XAU price movement.
input double SSV5_MaximumSpreadMovement       = 0.80;  // Maximum spread price movement (0 = disabled)
input double SSV5_MaximumEntryDeviationMovement= 2.00; // Maximum entry deviation movement (0 = disabled)
input double SSV5_MaximumSlippageMovement     = 0.50;  // Maximum slippage movement (0 = exact requested price)

// Closed-M5 velocity context and closed-M1 timing.
input double SSV5_MinimumM5PathEfficiencyPct  = 15.0;
input double SSV5_MinimumM5VelocityStrength   = 0.10;
input double SSV5_MaximumM5VelocityStrength   = 2.50;
input double SSV5_MinimumM5CoherencePct       = 66.7;
input double SSV5_MaximumM5ShockRatio         = 2.50;
input double SSV5_MaximumM5PullbackATR        = 1.50;
input double SSV5_MinimumM1TriggerStrength    = 0.05;
input double SSV5_MinimumM1AccelerationATR    = 0.00;
input double SSV5_MinimumM1CoherencePct       = 75.0;
input double SSV5_MaximumM1ShockRatio         = 2.50;
input double SSV5_MaximumM1ChaseM5ATR         = 1.00;
input bool   SSV5_RequireM1PullbackOrBreakout = true;

// Elite adaptive opportunities may enter without a positive M1 trigger, but
// M1 must not be hostile and M5 direction must agree.
input double SSV5_EliteStructuralScore        = 1.10;
input double SSV5_EliteOpportunityScore       = 0.55;
input double SSV5_EliteMaximumExhaustionRisk  = 0.55;

enum SSV5_TrackerState
  {
   SSV5_STATE_SEARCH=0,
   SSV5_STATE_CANDIDATE=1,
   SSV5_STATE_ACQUIRED=2,
   SSV5_STATE_ACTIVE=3,
   SSV5_STATE_EXITING=4
  };

enum SSV5_ProtectionState
  {
   SSV5_PROTECTION_OFF=0,
   SSV5_PROTECTION_PENDING=1,
   SSV5_PROTECTION_SYNCED=2,
   SSV5_PROTECTION_MANUAL=3,
   SSV5_PROTECTION_FAILED=4
  };

enum SSV5_ResearchSource
  {
   SSV5_RESEARCH_NONE=0,
   SSV5_RESEARCH_REJECTED=1,
   SSV5_RESEARCH_QUALIFIED=2
  };

enum SSV5_ResearchBlock
  {
   SSV5_RESEARCH_BLOCK_NONE=0,
   SSV5_RESEARCH_BLOCK_STRUCTURE=1,
   SSV5_RESEARCH_BLOCK_REMAINING=2,
   SSV5_RESEARCH_BLOCK_OPPORTUNITY=3,
   SSV5_RESEARCH_BLOCK_CONTRADICTION=4,
   SSV5_RESEARCH_BLOCK_EXHAUSTION=5,
   SSV5_RESEARCH_BLOCK_SHOCK=6,
   SSV5_RESEARCH_BLOCK_VELOCITY=7
  };

struct SSV5_MarketSnapshot
  {
   double velocityM1;
   double velocityM5;
   double accelerationM1;
   double accelerationM5;
   double sigmaM1;
   double sigmaM5;
   double efficiencyM1;
   double efficiencyM5;
   double rangeExpansion;
   double atrM5;
   double atrExpansionM5;
   double atrAccelerationM5;
   double ema20M5;
   double ema30M5;
   double gap20ATR;
   double structureM5;
   double velocity3M5ATR;
   double ribbon20_30ATR;
   double ribbonVelocity3;
   double structuralScore;
   int    structuralDirection;
   int    structuralDataContinuous;
   double environmentFactor;
   double horizonMinutes;
   double directionalLogit;
   double probability30Up;
   double probability30Down;
   double modeNoise;
   double modeDrift;
   double modeImpulse;
   double modeExhaustion;
   double modeShock;
   double pathAlternationM1;
   double wickRejectionM1;
   double accelerationPersistenceM1;
   double structuralNovelty;
   double motionDisagreement;
   double researchDriftScore;
  };

struct SSV5_DirectionTracker
  {
   double evidenceLogOdds;
   double rawP30;
   double calibratedP30;
   double expectedTravel;
   double expectedAdverse;
   double remainingTravel;
   double chaseDistance;
   double exhaustionRisk;
   double opportunityScore;
   double entryDevelopmentATR;
   int    calibrationBin;
   int    supportBars;
   int    contradictionBars;
  };

struct SSV5_ResearchTrack
  {
   bool     active;
   long     signalId;
   int      source;
   int      direction;
   int      blockCode;
   datetime startTime;
   double   entryPrice;
   double   horizonMinutes;
   double   maxFavorable;
   double   maxAdverse;
   double   entryP30;
   double   opportunityScore;
   double   remainingTravel;
   double   exhaustionRisk;
   double   developmentATR;
   double   pathAlternation;
   double   wickRejection;
   double   accelerationPersistence;
   double   structuralNovelty;
   double   driftScore;
  };

enum SSV5_SuperScalperEntryMode
  {
   SSV5_SS_ENTRY_NONE=0,
   SSV5_SS_ENTRY_ELITE=1,
   SSV5_SS_ENTRY_CONFIRMED=2
  };

struct SSV5_VelocitySnapshot
  {
   bool     valid;
   bool     m5Ready;
   bool     m1Ready;
   bool     qualified;
   bool     m1NonHostile;
   int      direction;
   datetime signalTime;
   double   referenceEntry;
   double   atrM1;
   double   atrM5;
   double   m5Strength;
   double   m5Efficiency;
   double   m5Coherence;
   double   m5Shock;
   double   m1Strength;
   double   m1Acceleration;
   double   m1Coherence;
   double   m1Shock;
   double   m1ChaseM5ATR;
   bool     pullbackSeen;
   bool     breakoutSeen;
  };

// Frozen system rules. These are deliberately not optimization inputs.
const int    SSV5_EA_MAGIC                         = 26081410;
const int    SSV5_MIN_CANDIDATE_BARS               = 1;
const int    SSV5_MAX_CANDIDATE_BARS               = 12;
const int    SSV5_OPERATION_RETRY_SECONDS           = 2;
const int    SSV5_ENTRY_BLOCK_RETRY_SECONDS         = 5;
const int    SSV5_MAX_ACQUIRED_SIGNAL_AGE_SECONDS   = 120;
const uint   SSV5_FINALIZE_HISTORY_RETRY_MS         = 1000;
const int    SSV5_MAX_FINALIZE_HISTORY_FAILURES     = 30;
const int    SSV5_MAX_EXIT_SYNC_FAILURES            = 5;
const int    SSV5_FAILED_EXIT_SYNC_RETRY_SECONDS    = 30;
const int    SSV5_INSTANCE_LEASE_TTL_SECONDS        = 30;
const int    SSV5_INSTANCE_HEARTBEAT_SECONDS        = 5;
const double SSV5_CUSUM_ALLOWANCE                  = 0.18;
const double SSV5_CUSUM_DECAY                      = 0.94;
const double SSV5_STRUCTURAL_SCORE_THRESHOLD       = 0.7629589434;
const double SSV5_MIN_M5_ATR_EXPANSION             = 0.90;
const double SSV5_MIN_STRUCTURAL_ONSET_SCORE        = 0.62;
const double SSV5_MIN_REMAINING_TRAVEL_USD         = 7.50;
const double SSV5_MIN_OPPORTUNITY_SCORE            = 0.30;
const double SSV5_MAX_ENTRY_EXHAUSTION_RISK         = 0.78;
const int    SSV5_MIN_THESIS_INVALID_BARS          = 3;
const int    SSV5_FAILURE_TO_LAUNCH_MINUTES        = 10;
const double SSV5_FAILURE_TO_LAUNCH_PROGRESS_USD   = 5.0;
const double SSV5_CALIBRATION_TARGET_USD           = 30.0;
const double SSV5_CALIBRATION_ADVERSE_USD          = 15.0;
const double SSV5_CALIBRATION_DECAY                = 0.99;
const int    SSV5_CALIBRATION_SCHEMA               = 2;
const int    SSV5_THESIS_SCHEMA                    = 2;
const int    SSV5_MAX_ENTRIES_PER_THESIS           = 2;
const int    SSV5_THESIS_RESET_CLOSED_BARS         = 2;
const double SSV5_CONTINUATION_EXTENSION_M5_ATR    = 0.25;
const double SSV5_CONTINUATION_OPPORTUNITY_TOLERANCE = 0.02;
const double SSV5_MAX_CONTINUATION_RESEARCH_DRIFT  = 0.75;
#define SSV5_RESEARCH_TRACK_SLOTS 4
const double SSV5_EPSILON                          = 0.0000001;

// Fixed presentation settings. They do not appear in the Inputs tab.
const string SSV5_PANEL_PREFIX                     = "GSA_PANEL_";
const int    SSV5_PANEL_LEFT                       = 10;
const int    SSV5_PANEL_TOP                        = 18;
const int    SSV5_PANEL_WIDTH                      = 414;
const int    SSV5_PANEL_HEIGHT                     = 390;
const int    SSV5_PANEL_LABEL_X                    = 26;
const int    SSV5_PANEL_VALUE_X                    = 408;

SSV5_TrackerState  SSV5_g_state=SSV5_STATE_SEARCH;
SSV5_MarketSnapshot SSV5_g_market;
SSV5_DirectionTracker SSV5_g_trackerUp;
SSV5_DirectionTracker SSV5_g_trackerDown;
SSV5_ResearchTrack SSV5_g_researchTracks[SSV5_RESEARCH_TRACK_SLOTS];
SSV5_VelocitySnapshot SSV5_g_velocity;

datetime SSV5_g_lastClosedM1=0;
datetime SSV5_g_nextOrderAttempt=0;
datetime SSV5_g_acquiredSignalBar=0;
datetime SSV5_g_nextExitSyncAttempt=0;
datetime SSV5_g_nextCloseAttempt=0;
datetime SSV5_g_activeEntryTime=0;
datetime SSV5_g_lastLeaseHeartbeat=0;
datetime SSV5_g_lastResearchPersist=0;
uint   SSV5_g_lastFinalizeAttemptMs=0;

int    SSV5_g_candidateDirection=0;
int    SSV5_g_candidateBars=0;
int    SSV5_g_activeTicket=-1;
int    SSV5_g_activeDirection=0;
int    SSV5_g_invalidBars=0;
int    SSV5_g_exitSyncFailures=0;
int    SSV5_g_activeCalibrationBin=-1;
int    SSV5_g_activeProtectionState=SSV5_PROTECTION_OFF;
int    SSV5_g_entriesTodayCached=-1;
int    SSV5_g_entriesTodayDay=0;
int    SSV5_g_lastHistoryTotal=-1;
int    SSV5_g_lastOpenOrdersTotal=-1;
int    SSV5_g_thesisDirection=0;
int    SSV5_g_thesisEntries=0;
int    SSV5_g_thesisResetBars=0;
int    SSV5_g_acquiredEntryMode=SSV5_SS_ENTRY_NONE;
int    SSV5_g_finalizeHistoryFailures=0;

double SSV5_g_candidateAnchor=0.0;
double SSV5_g_cusumUp=0.0;
double SSV5_g_cusumDown=0.0;
double SSV5_g_trackLogOdds=0.0;
double SSV5_g_favorableExtreme=0.0;
double SSV5_g_expectedSL=0.0;
double SSV5_g_expectedTP=0.0;
double SSV5_g_activeEntryP30=0.0;
double SSV5_g_activeEntryExpectedTravel=0.0;
double SSV5_g_activeEntryRemainingTravel=0.0;
double SSV5_g_activeEntryOpportunity=0.0;
double SSV5_g_activeRequestedPrice=0.0;
double SSV5_g_activeFillPrice=0.0;
double SSV5_g_activeEntrySpread=0.0;
double SSV5_g_activeEntryDeviation=0.0;
double SSV5_g_activeEntryDevelopmentATR=0.0;
double SSV5_g_activeEntryPathAlternation=0.0;
double SSV5_g_activeEntryWickRejection=0.0;
double SSV5_g_activeEntryAccelerationPersistence=0.0;
double SSV5_g_activeEntryStructuralNovelty=0.0;
double SSV5_g_activeEntryResearchDrift=0.0;
double SSV5_g_activeMaxFavorable=0.0;
double SSV5_g_activeMaxAdverse=0.0;
double SSV5_g_activeHorizonMinutes=0.0;
double SSV5_g_calibrationHits[5];
double SSV5_g_calibrationMisses[5];
double SSV5_g_researchPredictionErrorEWMA=0.0;
double SSV5_g_continuationReference=0.0;
double SSV5_g_continuationOpportunityFloor=0.0;
int    SSV5_g_researchResolvedProduction=0;

bool   SSV5_g_manualSLOverride=false;
bool   SSV5_g_manualTPOverride=false;
bool   SSV5_g_needExitSync=false;
bool   SSV5_g_modelExitRequested=false;
bool   SSV5_g_reconfiguredInputs=false;
bool   SSV5_g_activeCalibrationResolved=false;
bool   SSV5_g_activeCalibrationSuccess=false;
bool   SSV5_g_instanceLeaseHeld=false;
bool   SSV5_g_thesisLocked=false;
bool   SSV5_g_continuationPending=false;
bool   SSV5_g_continuationAuthorized=false;
bool   SSV5_g_thesisMigrationBootstrap=false;
string SSV5_g_modelExitReason="";
string SSV5_g_thesisBlockReason="";
datetime SSV5_g_thesisStartBar=0;
double SSV5_g_instanceToken=0.0;
uint   SSV5_g_lastPanelRenderMs=0;

//+------------------------------------------------------------------+
//| Utility functions                                                |
//+------------------------------------------------------------------+
double SSV5_Clamp(const double value,const double lower,const double upper)
  {
   return(MathMax(lower,MathMin(upper,value)));
  }

int SSV5_SignOf(const double value)
  {
   if(value>0.0) return(1);
   if(value<0.0) return(-1);
   return(0);
  }

bool SSV5_SamePrice(const double left,const double right)
  {
   return(MathAbs(left-right)<=MathMax(Point*0.75,SSV5_EPSILON));
  }

double SSV5_Logistic(const double value)
  {
   double bounded=SSV5_Clamp(value,-50.0,50.0);
   return(1.0/(1.0+MathExp(-bounded)));
  }

double SSV5_NormalCDF(const double value)
  {
   // Abramowitz-Stegun approximation; deterministic in old MT4 builds.
   double x=MathAbs(value);
   double t=1.0/(1.0+0.2316419*x);
   double density=0.3989422804014327*MathExp(-0.5*x*x);
   double polynomial=t*(0.319381530+t*(-0.356563782+t*(1.781477937+t*(-1.821255978+t*1.330274429))));
   double cdf=1.0-density*polynomial;
   if(value<0.0) cdf=1.0-cdf;
   return(SSV5_Clamp(cdf,0.0,1.0));
  }

double SSV5_CurrentMidPrice()
  {
   return((Bid+Ask)*0.5);
  }

string SSV5_DirectionName(const int direction)
  {
   if(direction>0) return("BUY");
   if(direction<0) return("SELL");
   return("NONE");
  }

string SSV5_ProtectionStateName(const int state)
  {
   if(state==SSV5_PROTECTION_PENDING) return("PENDING");
   if(state==SSV5_PROTECTION_SYNCED)  return("SYNCED");
   if(state==SSV5_PROTECTION_MANUAL)  return("MANUAL_OVERRIDE");
   if(state==SSV5_PROTECTION_FAILED)  return("FAILED");
   return("OFF");
  }

string SSV5_ResearchSourceName(const int source)
  {
   if(source==SSV5_RESEARCH_REJECTED)  return("REJECTED");
   if(source==SSV5_RESEARCH_QUALIFIED) return("QUALIFIED");
   return("NONE");
  }

string SSV5_ResearchBlockName(const int blockCode)
  {
   if(blockCode==SSV5_RESEARCH_BLOCK_STRUCTURE)     return("STRUCTURE_BELOW_ENTRY");
   if(blockCode==SSV5_RESEARCH_BLOCK_REMAINING)     return("REMAINING_TRAVEL");
   if(blockCode==SSV5_RESEARCH_BLOCK_OPPORTUNITY)   return("OPPORTUNITY_SCORE");
   if(blockCode==SSV5_RESEARCH_BLOCK_CONTRADICTION) return("LIVE_CONTRADICTION");
   if(blockCode==SSV5_RESEARCH_BLOCK_EXHAUSTION)    return("EXHAUSTION_RISK");
   if(blockCode==SSV5_RESEARCH_BLOCK_SHOCK)         return("SHOCK_RISK");
   if(blockCode==SSV5_RESEARCH_BLOCK_VELOCITY)      return("M1_M5_VELOCITY");
   return("NONE");
  }

string SSV5_EntryDevelopmentName(const double developmentATR)
  {
   if(developmentATR<=0.25) return("FRESH");
   if(developmentATR<=0.75) return("DEVELOPED");
   if(developmentATR<=1.25) return("EXTENDED");
   return("EXHAUSTED");
  }

string SSV5_ResearchDriftName(const double score)
  {
   if(score>=0.75) return("DEGRADED");
   if(score>=0.55) return("SUSPECTED");
   if(score>=0.35) return("WATCH");
   return("NORMAL");
  }

bool SSV5_IsConfiguredProfitExitReason(const string reason)
  {
   return(reason=="configured take-profit level already crossed");
  }

string SSV5_PersistenceKey(const string suffix)
  {
   string symbolKey=Symbol();
   if(StringLen(symbolKey)>20)
     {
      long hash=0;
      for(int index=0;index<StringLen(symbolKey);index++)
         hash=(hash*131+StringGetCharacter(symbolKey,index))%2147483647;
      symbolKey=StringSubstr(symbolKey,0,8)+"_"+IntegerToString((int)hash);
     }
   string prefix=(IsTesting() ? "XVS1T." : "XVS1.");
   return(prefix+IntegerToString(AccountNumber())+"."+symbolKey+"."+suffix);
  }

double SSV5_ReadPersistent(const string suffix,const double fallback)
  {
   string key=SSV5_PersistenceKey(suffix);
   if(!GlobalVariableCheck(key)) return(fallback);
   return(GlobalVariableGet(key));
  }

void SSV5_WritePersistent(const string suffix,const double value)
  {
   GlobalVariableSet(SSV5_PersistenceKey(suffix),value);
  }

void SSV5_DeletePersistent(const string suffix)
  {
   string key=SSV5_PersistenceKey(suffix);
   if(GlobalVariableCheck(key)) GlobalVariableDel(key);
  }

bool SSV5_AcquireInstanceLease()
  {
   // MT4 tester runs are already single-EA contexts.  Terminal global-variable
   // timestamps can outlive an interrupted historical run and use a different
   // clock, so a live-style lease would incorrectly block later backtests.
   if(IsTesting())
     {
      SSV5_g_instanceToken=-1.0;
      SSV5_g_instanceLeaseHeld=true;
      SSV5_g_lastLeaseHeartbeat=TimeLocal();
      return(true);
     }
   string key=SSV5_PersistenceKey("InstanceLease");
   SSV5_g_instanceToken=MathAbs((double)ChartID());
   if(SSV5_g_instanceToken<1.0)
      SSV5_g_instanceToken=(double)TimeLocal()+1.0+(double)(GetTickCount()%100000)/100000.0;

   if(!GlobalVariableCheck(key)) GlobalVariableSet(key,0.0);
   double owner=GlobalVariableGet(key);
   datetime modified=GlobalVariableTime(key);
   datetime now=TimeLocal();

   if(owner==SSV5_g_instanceToken)
     {
      GlobalVariableSet(key,SSV5_g_instanceToken);
      SSV5_g_instanceLeaseHeld=true;
      SSV5_g_lastLeaseHeartbeat=now;
      return(true);
     }

   bool stale=(owner==0.0 || modified<=0 || now-modified>SSV5_INSTANCE_LEASE_TTL_SECONDS);
   if(!stale) return(false);
   if(!GlobalVariableSetOnCondition(key,SSV5_g_instanceToken,owner)) return(false);
   SSV5_g_instanceLeaseHeld=true;
   SSV5_g_lastLeaseHeartbeat=now;
   return(true);
  }

void SSV5_HeartbeatInstanceLease()
  {
   if(!SSV5_g_instanceLeaseHeld) return;
   if(IsTesting()) return;
   datetime now=TimeLocal();
   if(SSV5_g_lastLeaseHeartbeat>0 && now-SSV5_g_lastLeaseHeartbeat<SSV5_INSTANCE_HEARTBEAT_SECONDS) return;
   string key=SSV5_PersistenceKey("InstanceLease");
   if(!GlobalVariableCheck(key) || GlobalVariableGet(key)!=SSV5_g_instanceToken)
     {
      SSV5_g_instanceLeaseHeld=false;
      Print("XVISION SuperScalper: instance lease was lost; this chart will no longer trade or manage positions.");
      return;
     }
   GlobalVariableSet(key,SSV5_g_instanceToken);
   SSV5_g_lastLeaseHeartbeat=now;
  }

void SSV5_ReleaseInstanceLease()
  {
   if(!SSV5_g_instanceLeaseHeld) return;
   if(IsTesting())
     {
      SSV5_g_instanceLeaseHeld=false;
      return;
     }
   string key=SSV5_PersistenceKey("InstanceLease");
   if(GlobalVariableCheck(key)) GlobalVariableSetOnCondition(key,0.0,SSV5_g_instanceToken);
   SSV5_g_instanceLeaseHeld=false;
  }

int SSV5_BrokerDayKey(const datetime stamp)
  {
   return(TimeYear(stamp)*10000+TimeMonth(stamp)*100+TimeDay(stamp));
  }

bool SSV5_IsMarketOrderType(const int orderType)
  {
   return(orderType==OP_BUY || orderType==OP_SELL);
  }

bool SSV5_IsStrategyFamilyMagic(const int magic)
  {
   return(magic==SSV5_EA_MAGIC);
  }

bool SSV5_HasSufficientData()
  {
   if(iBars(Symbol(),PERIOD_M1)<220)  return(false);
   if(iBars(Symbol(),PERIOD_M5)<220)  return(false);
   if(iBars(Symbol(),PERIOD_M30)<40)  return(false);
   if(iClose(Symbol(),PERIOD_M1,1)<=0.0) return(false);
   return(true);
  }

bool SSV5_HasContinuousClosedBars(const int timeframe,const int intervals,const int newestShift)
  {
   int expectedSeconds=timeframe*60;
   if(expectedSeconds<=0) return(false);
   for(int shift=newestShift;shift<newestShift+intervals;shift++)
     {
      datetime newer=iTime(Symbol(),timeframe,shift);
      datetime older=iTime(Symbol(),timeframe,shift+1);
      if(newer<=0 || older<=0 || newer-older!=expectedSeconds) return(false);
     }
   return(true);
  }

void SSV5_ResetVelocitySnapshot()
  {
   SSV5_g_velocity.valid=false;
   SSV5_g_velocity.m5Ready=false;
   SSV5_g_velocity.m1Ready=false;
   SSV5_g_velocity.qualified=false;
   SSV5_g_velocity.m1NonHostile=false;
   SSV5_g_velocity.direction=0;
   SSV5_g_velocity.signalTime=0;
   SSV5_g_velocity.referenceEntry=0.0;
   SSV5_g_velocity.atrM1=0.0;
   SSV5_g_velocity.atrM5=0.0;
   SSV5_g_velocity.m5Strength=0.0;
   SSV5_g_velocity.m5Efficiency=0.0;
   SSV5_g_velocity.m5Coherence=0.0;
   SSV5_g_velocity.m5Shock=0.0;
   SSV5_g_velocity.m1Strength=0.0;
   SSV5_g_velocity.m1Acceleration=0.0;
   SSV5_g_velocity.m1Coherence=0.0;
   SSV5_g_velocity.m1Shock=0.0;
   SSV5_g_velocity.m1ChaseM5ATR=0.0;
   SSV5_g_velocity.pullbackSeen=false;
   SSV5_g_velocity.breakoutSeen=false;
  }

double SSV5_SSTrueRange(const int timeframe,const int shift)
  {
   double high=iHigh(Symbol(),timeframe,shift);
   double low=iLow(Symbol(),timeframe,shift);
   double previous=iClose(Symbol(),timeframe,shift+1);
   if(high<=0.0 || low<=0.0 || previous<=0.0) return(0.0);
   return(MathMax(high-low,MathMax(MathAbs(high-previous),MathAbs(low-previous))));
  }

double SSV5_SSATR(const int timeframe,const int period,const int shift)
  {
   double total=0.0;
   for(int index=0;index<period;index++)
     {
      double observation=SSV5_SSTrueRange(timeframe,shift+index);
      if(observation<=0.0) return(0.0);
      total+=observation;
     }
   return(total/period);
  }

double SSV5_SSNet(const int timeframe,const int window,const int shift)
  {
   return(iClose(Symbol(),timeframe,shift)-iOpen(Symbol(),timeframe,shift+window-1));
  }

double SSV5_SSM5CompositeAtShift(const int shift)
  {
   double atr=SSV5_SSATR(PERIOD_M5,12,shift);
   if(atr<=0.0) return(0.0);
   int windows[6]={1,3,6,12,24,48};
   double weights[6]={0.25,0.25,0.20,0.15,0.10,0.05};
   double composite=0.0;
   for(int index=0;index<6;index++)
      composite+=weights[index]*SSV5_SSNet(PERIOD_M5,windows[index],shift)/
                 (atr*MathSqrt(windows[index]));
   return(composite);
  }

int SSLastFullyClosedShift(const int timeframe,const datetime decisionTime,
                           const int requiredOlderBars,const int maximumAgeSeconds)
  {
   int containing=iBarShift(Symbol(),timeframe,decisionTime,false);
   if(containing<0) return(-1);
   int closedShift=containing+1;
   if(closedShift+requiredOlderBars>=iBars(Symbol(),timeframe)) return(-1);
   datetime barOpen=iTime(Symbol(),timeframe,closedShift);
   if(barOpen<=0) return(-1);
   datetime barClose=barOpen+timeframe*60;
   if(barClose>decisionTime) return(-1);
   if(maximumAgeSeconds>0 && decisionTime-barClose>maximumAgeSeconds) return(-1);
   return(closedShift);
  }

bool SSV5_ComputeVelocitySnapshot(const int m1Shift)
  {
   SSV5_ResetVelocitySnapshot();
   if(m1Shift<1 || iBars(Symbol(),PERIOD_M1)<m1Shift+80 || iBars(Symbol(),PERIOD_M5)<80)
      return(false);

   datetime signalOpen=iTime(Symbol(),PERIOD_M1,m1Shift);
   if(signalOpen<=0) return(false);
   datetime decisionTime=signalOpen+60;
   int closedM5=SSLastFullyClosedShift(PERIOD_M5,decisionTime,79,15*60);
   if(closedM5<1) return(false);

   double atrM5=SSV5_SSATR(PERIOD_M5,12,closedM5);
   double atrM1=SSV5_SSATR(PERIOD_M1,14,m1Shift);
   if(atrM5<=0.0 || atrM1<=0.0) return(false);

   int m5Windows[6]={1,3,6,12,24,48};
   double m5Velocity[6];
   ArrayInitialize(m5Velocity,0.0);
   double m5Composite=0.0;
   double m5Weights[6]={0.25,0.25,0.20,0.15,0.10,0.05};
   for(int m5Index=0;m5Index<6;m5Index++)
     {
      m5Velocity[m5Index]=SSV5_SSNet(PERIOD_M5,m5Windows[m5Index],closedM5)/
                          (atrM5*MathSqrt(m5Windows[m5Index]));
      m5Composite+=m5Weights[m5Index]*m5Velocity[m5Index];
     }
   int direction=(m5Composite>=0.0 ? 1 : -1);
   double m5Strength=MathAbs(m5Composite);
   int alignedM5=0;
   for(int aligned5=0;aligned5<6;aligned5++)
      if(direction*m5Velocity[aligned5]>0.0) alignedM5++;
   double m5Coherence=alignedM5/6.0;
   double range12=0.0;
   double high12=-DBL_MAX;
   double low12=DBL_MAX;
   for(int bar5=0;bar5<12;bar5++)
     {
      range12+=SSV5_SSTrueRange(PERIOD_M5,closedM5+bar5);
      high12=MathMax(high12,iHigh(Symbol(),PERIOD_M5,closedM5+bar5));
      low12=MathMin(low12,iLow(Symbol(),PERIOD_M5,closedM5+bar5));
     }
   double m5Efficiency=MathAbs(SSV5_SSNet(PERIOD_M5,12,closedM5))/MathMax(range12,Point);
   double m5Shock=SSV5_SSTrueRange(PERIOD_M5,closedM5)/atrM5;
   double m5Close=iClose(Symbol(),PERIOD_M5,closedM5);
   double m5Pullback=(direction>0 ? (m5Close-high12)/atrM5 : (low12-m5Close)/atrM5);
   bool m5Ready=(m5Efficiency>=SSV5_MinimumM5PathEfficiencyPct/100.0 &&
                 m5Strength>=SSV5_MinimumM5VelocityStrength &&
                 m5Strength<=SSV5_MaximumM5VelocityStrength &&
                 m5Coherence>=SSV5_MinimumM5CoherencePct/100.0 &&
                 m5Shock<=SSV5_MaximumM5ShockRatio &&
                 m5Pullback>=-SSV5_MaximumM5PullbackATR);

   int m1Windows[4]={1,3,5,15};
   double m1Velocity[4];
   ArrayInitialize(m1Velocity,0.0);
   double m1Weights[4]={0.35,0.30,0.20,0.15};
   double m1Composite=0.0;
   for(int m1Index=0;m1Index<4;m1Index++)
     {
      m1Velocity[m1Index]=SSV5_SSNet(PERIOD_M1,m1Windows[m1Index],m1Shift)/
                          (atrM1*MathSqrt(m1Windows[m1Index]));
      m1Composite+=m1Weights[m1Index]*m1Velocity[m1Index];
     }
   double m1Strength=direction*m1Composite;
   int alignedM1=0;
   for(int aligned1=0;aligned1<4;aligned1++)
      if(direction*m1Velocity[aligned1]>0.0) alignedM1++;
   double m1Coherence=alignedM1/4.0;
   double recentM1=SSV5_SSNet(PERIOD_M1,3,m1Shift)/3.0;
   double priorM1=(iClose(Symbol(),PERIOD_M1,m1Shift+3)-
                   iOpen(Symbol(),PERIOD_M1,m1Shift+14))/12.0;
   double m1Acceleration=direction*(recentM1-priorM1)/atrM1;
   double m1Shock=SSV5_SSTrueRange(PERIOD_M1,m1Shift)/atrM1;
   double m1Close=iClose(Symbol(),PERIOD_M1,m1Shift);
   double m1Body=m1Close-iOpen(Symbol(),PERIOD_M1,m1Shift);
   bool alignedBody=(direction*m1Body>0.0);
   bool pullbackSeen=false;
   double previousHigh=-DBL_MAX;
   double previousLow=DBL_MAX;
   for(int prior=1;prior<=3;prior++)
     {
      double priorBody=iClose(Symbol(),PERIOD_M1,m1Shift+prior)-
                       iOpen(Symbol(),PERIOD_M1,m1Shift+prior);
      if(direction*priorBody<0.0) pullbackSeen=true;
      previousHigh=MathMax(previousHigh,iHigh(Symbol(),PERIOD_M1,m1Shift+prior));
      previousLow=MathMin(previousLow,iLow(Symbol(),PERIOD_M1,m1Shift+prior));
     }
   bool breakoutSeen=(direction>0 ? m1Close>previousHigh : m1Close<previousLow);
   bool patternReady=(!SSV5_RequireM1PullbackOrBreakout || pullbackSeen || breakoutSeen);
   double m1ChaseM5ATR=MathAbs(m1Close-m5Close)/atrM5;
   bool m1Ready=(m1Strength>=SSV5_MinimumM1TriggerStrength &&
                 m1Acceleration>=SSV5_MinimumM1AccelerationATR &&
                 m1Coherence>=SSV5_MinimumM1CoherencePct/100.0 &&
                 m1Shock<=SSV5_MaximumM1ShockRatio &&
                 m1ChaseM5ATR<=SSV5_MaximumM1ChaseM5ATR && alignedBody && patternReady);

   SSV5_g_velocity.valid=true;
   SSV5_g_velocity.m5Ready=m5Ready;
   SSV5_g_velocity.m1Ready=m1Ready;
   SSV5_g_velocity.qualified=(m5Ready && m1Ready);
   SSV5_g_velocity.m1NonHostile=(m1Strength>=-0.10 && m1Acceleration>=-0.35 &&
                            m1Shock<=SSV5_MaximumM1ShockRatio);
   SSV5_g_velocity.direction=direction;
   SSV5_g_velocity.signalTime=signalOpen;
   SSV5_g_velocity.referenceEntry=m1Close;
   SSV5_g_velocity.atrM1=atrM1;
   SSV5_g_velocity.atrM5=atrM5;
   SSV5_g_velocity.m5Strength=m5Strength;
   SSV5_g_velocity.m5Efficiency=m5Efficiency;
   SSV5_g_velocity.m5Coherence=m5Coherence;
   SSV5_g_velocity.m5Shock=m5Shock;
   SSV5_g_velocity.m1Strength=m1Strength;
   SSV5_g_velocity.m1Acceleration=m1Acceleration;
   SSV5_g_velocity.m1Coherence=m1Coherence;
   SSV5_g_velocity.m1Shock=m1Shock;
   SSV5_g_velocity.m1ChaseM5ATR=m1ChaseM5ATR;
   SSV5_g_velocity.pullbackSeen=pullbackSeen;
   SSV5_g_velocity.breakoutSeen=breakoutSeen;
   return(true);
  }

//+------------------------------------------------------------------+
//| Causal market measurements                                       |
//+------------------------------------------------------------------+
double SSV5_LinearVelocity(const int timeframe,const int bars)
  {
   if(iBars(Symbol(),timeframe)<bars+3) return(0.0);
   double sumX=0.0,sumY=0.0,sumXX=0.0,sumXY=0.0;
   double minutes=(double)timeframe;
   if(minutes<=0.0) minutes=1.0;

   for(int index=0; index<bars; index++)
     {
      int shift=bars-index;
      double x=(double)index*minutes;
      double y=iClose(Symbol(),timeframe,shift);
      if(y<=0.0) return(0.0);
      sumX+=x;
      sumY+=y;
      sumXX+=x*x;
      sumXY+=x*y;
     }

   double denominator=bars*sumXX-sumX*sumX;
   if(MathAbs(denominator)<SSV5_EPSILON) return(0.0);
   return((bars*sumXY-sumX*sumY)/denominator);
  }

double SSV5_ReturnSigma(const int timeframe,const int bars,const double alpha)
  {
   if(iBars(Symbol(),timeframe)<bars+3) return(Point);
   double variance=0.0;
   bool seeded=false;
   for(int shift=bars; shift>=1; shift--)
     {
      double current=iClose(Symbol(),timeframe,shift);
      double previous=iClose(Symbol(),timeframe,shift+1);
      if(current<=0.0 || previous<=0.0) continue;
      double movement=current-previous;
      if(!seeded)
        {
         variance=movement*movement;
         seeded=true;
        }
      else
         variance=(1.0-alpha)*variance+alpha*movement*movement;
     }
   return(MathMax(MathSqrt(MathMax(variance,0.0)),Point));
  }

double SSV5_DirectionalEfficiency(const int timeframe,const int bars)
  {
   if(iBars(Symbol(),timeframe)<bars+3) return(0.0);
   double newest=iClose(Symbol(),timeframe,1);
   double oldest=iClose(Symbol(),timeframe,bars+1);
   double path=0.0;
   for(int shift=1; shift<=bars; shift++)
      path+=MathAbs(iClose(Symbol(),timeframe,shift)-iClose(Symbol(),timeframe,shift+1));
   if(path<SSV5_EPSILON) return(0.0);
   return(SSV5_Clamp((newest-oldest)/path,-1.0,1.0));
  }

double SSV5_AverageBarPressure(const int timeframe,const int bars)
  {
   if(iBars(Symbol(),timeframe)<bars+3) return(0.0);
   double pressure=0.0;
   int valid=0;
   for(int shift=1; shift<=bars; shift++)
     {
      double high=iHigh(Symbol(),timeframe,shift);
      double low=iLow(Symbol(),timeframe,shift);
      double close=iClose(Symbol(),timeframe,shift);
      double range=high-low;
      if(range<=Point) continue;
      pressure+=((close-low)-(high-close))/range;
      valid++;
     }
   if(valid<=0) return(0.0);
   return(SSV5_Clamp(pressure/valid,-1.0,1.0));
  }

double SSV5_CandleAlternationRate(const int timeframe,const int bars)
  {
   if(bars<2 || iBars(Symbol(),timeframe)<bars+3) return(0.0);
   int previousSign=0;
   int comparisons=0;
   int alternations=0;
   for(int shift=bars;shift>=1;shift--)
     {
      double body=iClose(Symbol(),timeframe,shift)-iOpen(Symbol(),timeframe,shift);
      int sign=SSV5_SignOf(body);
      if(sign==0) continue;
      if(previousSign!=0)
        {
         comparisons++;
         if(sign!=previousSign) alternations++;
        }
      previousSign=sign;
     }
   if(comparisons<=0) return(0.0);
   return(SSV5_Clamp((double)alternations/comparisons,0.0,1.0));
  }

double SSV5_WickRejectionBalance(const int timeframe,const int bars)
  {
   if(bars<1 || iBars(Symbol(),timeframe)<bars+3) return(0.0);
   double balance=0.0;
   int valid=0;
   for(int shift=1;shift<=bars;shift++)
     {
      double openPrice=iOpen(Symbol(),timeframe,shift);
      double closePrice=iClose(Symbol(),timeframe,shift);
      double highPrice=iHigh(Symbol(),timeframe,shift);
      double lowPrice=iLow(Symbol(),timeframe,shift);
      double range=highPrice-lowPrice;
      if(range<=Point) continue;
      double upperWick=highPrice-MathMax(openPrice,closePrice);
      double lowerWick=MathMin(openPrice,closePrice)-lowPrice;
      balance+=(lowerWick-upperWick)/range;
      valid++;
     }
   if(valid<=0) return(0.0);
   return(SSV5_Clamp(balance/valid,-1.0,1.0));
  }

double SSV5_AccelerationPersistenceM1(const double sigmaM1)
  {
   if(iBars(Symbol(),PERIOD_M1)<14) return(0.0);
   double total=0.0;
   int valid=0;
   for(int shift=1;shift<=3;shift++)
     {
      double newest=iClose(Symbol(),PERIOD_M1,shift);
      double recentPast=iClose(Symbol(),PERIOD_M1,shift+3);
      double olderPast=iClose(Symbol(),PERIOD_M1,shift+6);
      if(newest<=0.0 || recentPast<=0.0 || olderPast<=0.0) continue;
      double recentVelocity=(newest-recentPast)/3.0;
      double priorVelocity=(recentPast-olderPast)/3.0;
      total+=SSV5_Clamp((recentVelocity-priorVelocity)/MathMax(sigmaM1,Point),-1.0,1.0);
      valid++;
     }
   if(valid<=0) return(0.0);
   return(SSV5_Clamp(total/valid,-1.0,1.0));
  }

double SSV5_SafeATR(const int timeframe,const int period)
  {
   double result=iATR(Symbol(),timeframe,period,1);
   if(result<=Point) result=Point;
   return(result);
  }

double SSV5_EMAOfATR(const int timeframe,const int atrPeriod,const int emaPeriod,const int targetShift)
  {
   int oldest=targetShift+MathMax(emaPeriod*4,emaPeriod+2);
   double value=iATR(Symbol(),timeframe,atrPeriod,oldest);
   if(value<=Point) value=Point;
   double alpha=2.0/(emaPeriod+1.0);
   for(int shift=oldest-1;shift>=targetShift;shift--)
     {
      double observation=iATR(Symbol(),timeframe,atrPeriod,shift);
      if(observation<=Point) observation=value;
      value=alpha*observation+(1.0-alpha)*value;
     }
   return(MathMax(value,Point));
  }

double SSV5_StructuralLocation(const int timeframe,const int bars,const int closeShift)
  {
   double closePrice=iClose(Symbol(),timeframe,closeShift);
   double priorHigh=iHigh(Symbol(),timeframe,closeShift+1);
   double priorLow=iLow(Symbol(),timeframe,closeShift+1);
   if(closePrice<=0.0 || priorHigh<=0.0 || priorLow<=0.0) return(0.0);
   for(int shift=closeShift+2;shift<=closeShift+bars;shift++)
     {
      priorHigh=MathMax(priorHigh,iHigh(Symbol(),timeframe,shift));
      priorLow=MathMin(priorLow,iLow(Symbol(),timeframe,shift));
     }
   double width=priorHigh-priorLow;
   if(width<=Point) return(0.0);
   return(SSV5_Clamp((2.0*closePrice-priorHigh-priorLow)/width,-3.0,3.0));
  }

double SSV5_M5RibbonATRAtShift(const int shift)
  {
   double atr=iATR(Symbol(),PERIOD_M5,14,shift);
   if(atr<=Point) atr=Point;
   double ema20=iMA(Symbol(),PERIOD_M5,20,0,MODE_EMA,PRICE_CLOSE,shift);
   double ema30=iMA(Symbol(),PERIOD_M5,30,0,MODE_EMA,PRICE_CLOSE,shift);
   return((ema20-ema30)/atr);
  }

void SSV5_ComputeM5StructuralFeatures()
  {
   // The research pipeline suppressed features until 30 uninterrupted M5 bars
   // had formed after a data/session gap.
   SSV5_g_market.structuralDataContinuous=(SSV5_HasContinuousClosedBars(PERIOD_M5,30,1) ? 1 : 0);
   SSV5_g_market.atrM5=MathMax(iATR(Symbol(),PERIOD_M5,14,1),Point);
   double atrBase=SSV5_EMAOfATR(PERIOD_M5,14,20,1);
   double atrThreeBarsAgo=MathMax(iATR(Symbol(),PERIOD_M5,14,4),Point);
   SSV5_g_market.atrExpansionM5=SSV5_Clamp(SSV5_g_market.atrM5/atrBase,0.25,4.0);
   SSV5_g_market.atrAccelerationM5=SSV5_Clamp((SSV5_g_market.atrM5-atrThreeBarsAgo)/SSV5_g_market.atrM5,-2.0,2.0);
   SSV5_g_market.ema20M5=iMA(Symbol(),PERIOD_M5,20,0,MODE_EMA,PRICE_CLOSE,1);
   SSV5_g_market.ema30M5=iMA(Symbol(),PERIOD_M5,30,0,MODE_EMA,PRICE_CLOSE,1);
   double closeM5=iClose(Symbol(),PERIOD_M5,1);
   SSV5_g_market.gap20ATR=(closeM5-SSV5_g_market.ema20M5)/SSV5_g_market.atrM5;
   SSV5_g_market.structureM5=SSV5_StructuralLocation(PERIOD_M5,12,1);
   SSV5_g_market.velocity3M5ATR=(closeM5-iClose(Symbol(),PERIOD_M5,4))/(3.0*SSV5_g_market.atrM5);
   SSV5_g_market.ribbon20_30ATR=(SSV5_g_market.ema20M5-SSV5_g_market.ema30M5)/SSV5_g_market.atrM5;
   SSV5_g_market.ribbonVelocity3=(SSV5_g_market.ribbon20_30ATR-SSV5_M5RibbonATRAtShift(4))/3.0;

   // Frozen train-only standardization from the supplied GOLD M5 data.
   // Each input is winsorized at its training 1st/99th percentiles.
   double zGap=(SSV5_Clamp(SSV5_g_market.gap20ATR,-3.130203,3.406464)+0.068448)/1.275260;
   double zStructure=(SSV5_Clamp(SSV5_g_market.structureM5,-1.571429,1.684980)+0.025718)/0.701767;
   double zRibbon=(SSV5_Clamp(SSV5_g_market.ribbonVelocity3,-0.076647,0.084752)+0.000728)/0.032197;
   double zVelocity=(SSV5_Clamp(SSV5_g_market.velocity3M5ATR,-0.869676,0.944521)+0.010149)/0.349549;
   SSV5_g_market.structuralNovelty=MathSqrt((zGap*zGap+zStructure*zStructure+
                                       zRibbon*zRibbon+zVelocity*zVelocity)/4.0);
   SSV5_g_market.structuralScore=(zGap+zStructure+zRibbon+zVelocity)/4.0;
   SSV5_g_market.structuralDirection=SSV5_SignOf(SSV5_g_market.structuralScore);
  }

bool SSV5_M5EnergyReady()
  {
   return(SSV5_g_market.atrExpansionM5>=SSV5_MIN_M5_ATR_EXPANSION && SSV5_g_market.atrAccelerationM5>0.0);
  }

bool SSV5_M5MotionAligned(const int direction)
  {
   if(direction==0) return(false);
   if(direction*SSV5_g_market.gap20ATR<=0.0) return(false);
   if(direction*SSV5_g_market.ribbonVelocity3<=0.0) return(false);
   if(direction*SSV5_g_market.velocity3M5ATR<=0.0) return(false);
   return(true);
  }

bool SSV5_M5StructuralReady(const int direction,const double minimumScore)
  {
   if(SSV5_g_market.structuralDataContinuous==0) return(false);
   if(direction==0 || direction!=SSV5_g_market.structuralDirection) return(false);
   if(direction*SSV5_g_market.structuralScore<minimumScore) return(false);
   if(!SSV5_M5EnergyReady()) return(false);
   return(SSV5_M5MotionAligned(direction));
  }

void SSV5_ResetModeProbabilities()
  {
   SSV5_g_market.modeNoise=0.20;
   SSV5_g_market.modeDrift=0.20;
   SSV5_g_market.modeImpulse=0.20;
   SSV5_g_market.modeExhaustion=0.20;
   SSV5_g_market.modeShock=0.20;
  }

void UpdateModeProbabilities(const double speed,const double acceleration,
                             const double efficiency,const double agreement,
                             const double expansion,const double lastReturnZ)
  {
   double logLikelihood[5];
   logLikelihood[0]=1.35*(1.0-efficiency)-0.45*speed-0.25*MathAbs(expansion-1.0);
   logLikelihood[1]=1.20*efficiency+0.45*speed+0.35*MathMax(agreement,0.0)-0.35*acceleration;
   logLikelihood[2]=0.90*efficiency+0.75*speed+0.70*MathMax(acceleration,0.0)+0.35*MathMax(expansion-1.0,0.0);
   logLikelihood[3]=0.65*speed+0.90*MathMax(-agreement,0.0)+0.65*(1.0-efficiency)+0.30*acceleration;
   logLikelihood[4]=1.15*MathMax(expansion-1.65,0.0)+0.55*MathMax(MathAbs(lastReturnZ)-2.0,0.0);

   double maximum=logLikelihood[0];
   for(int i=1;i<5;i++) maximum=MathMax(maximum,logLikelihood[i]);
   double likelihood[5];
   ArrayInitialize(likelihood,0.0);
   double total=0.0;
   for(int j=0;j<5;j++)
     {
      likelihood[j]=MathExp(SSV5_Clamp(logLikelihood[j]-maximum,-50.0,50.0));
      total+=likelihood[j];
     }
   if(total<SSV5_EPSILON) total=1.0;

   double previous[5];
   previous[0]=SSV5_g_market.modeNoise;
   previous[1]=SSV5_g_market.modeDrift;
   previous[2]=SSV5_g_market.modeImpulse;
   previous[3]=SSV5_g_market.modeExhaustion;
   previous[4]=SSV5_g_market.modeShock;
   double previousTotal=0.0;
   for(int k=0;k<5;k++) previousTotal+=previous[k];
   if(previousTotal<SSV5_EPSILON)
      for(int seed=0;seed<5;seed++) previous[seed]=0.20;

   double updated[5];
   ArrayInitialize(updated,0.0);
   double updatedTotal=0.0;
   for(int mode=0;mode<5;mode++)
     {
      // Persistence approximates an interacting-multiple-model transition prior.
      double mixedPrior=0.72*previous[mode]+0.28*(1.0-previous[mode])/4.0;
      updated[mode]=mixedPrior*(likelihood[mode]/total);
      updatedTotal+=updated[mode];
     }
   if(updatedTotal<SSV5_EPSILON) updatedTotal=1.0;
   SSV5_g_market.modeNoise=updated[0]/updatedTotal;
   SSV5_g_market.modeDrift=updated[1]/updatedTotal;
   SSV5_g_market.modeImpulse=updated[2]/updatedTotal;
   SSV5_g_market.modeExhaustion=updated[3]/updatedTotal;
   SSV5_g_market.modeShock=updated[4]/updatedTotal;
  }

double BarrierBeforeAdverseProbability(const double drift,const double sigma,
                                       const double target,const double adverse)
  {
   double variance=MathMax(sigma*sigma,Point*Point);
   if(MathAbs(drift)<0.000001)
      return(SSV5_Clamp(adverse/(target+adverse),0.0,1.0));
   double exponent=-2.0*drift/variance;
   double numerator=1.0-MathExp(SSV5_Clamp(exponent*adverse,-50.0,50.0));
   double denominator=1.0-MathExp(SSV5_Clamp(exponent*(target+adverse),-50.0,50.0));
   if(MathAbs(denominator)<SSV5_EPSILON)
      return(SSV5_Clamp(adverse/(target+adverse),0.0,1.0));
   return(SSV5_Clamp(numerator/denominator,0.0,1.0));
  }

double HitByHorizonProbability(const double drift,const double sigma,
                               const double target,const double horizonMinutes)
  {
   double safeSigma=MathMax(sigma,Point);
   double rootTime=MathSqrt(MathMax(horizonMinutes,1.0));
   double z1=(drift*horizonMinutes-target)/(safeSigma*rootTime);
   double z2=(-drift*horizonMinutes-target)/(safeSigma*rootTime);
   double multiplier=MathExp(SSV5_Clamp(2.0*drift*target/(safeSigma*safeSigma),-50.0,50.0));
   return(SSV5_Clamp(SSV5_NormalCDF(z1)+multiplier*SSV5_NormalCDF(z2),0.0,1.0));
  }

double SSV5_ContinuationProbability(const int direction)
  {
   double directionalEvidence=direction*SSV5_g_market.directionalLogit;
   double regimeSupport=SSV5_g_market.modeDrift+SSV5_g_market.modeImpulse;
   double regimeRisk=SSV5_g_market.modeNoise+SSV5_g_market.modeExhaustion+0.7*SSV5_g_market.modeShock;
   return(SSV5_Logistic(0.95*directionalEvidence+0.85*regimeSupport-0.55*regimeRisk-0.35));
  }

double SSV5_DestinationProbability(const int direction,const double target)
  {
   // SSV5_LinearVelocity is already expressed per minute on both timeframes.
   double fusedDrift=0.18*SSV5_g_market.velocityM1+0.82*SSV5_g_market.velocityM5;
   double directedDrift=direction*fusedDrift;
   double sigmaPerMinute=MathMax(SSV5_g_market.sigmaM1,SSV5_g_market.sigmaM5/MathSqrt(5.0));
   double adverse=SSV5_Clamp(2.4*sigmaPerMinute*MathSqrt(8.0),5.0,15.0);
   double barrier=BarrierBeforeAdverseProbability(directedDrift,sigmaPerMinute,target,adverse);
   double timed=HitByHorizonProbability(directedDrift,sigmaPerMinute,target,SSV5_g_market.horizonMinutes);
   double continuation=SSV5_ContinuationProbability(direction);
   double combined=(0.48*barrier+0.52*timed)*(0.58+0.42*continuation);
   return(SSV5_Clamp(combined,0.0,1.0));
  }

double SSV5_DirectionRawProbability(const int direction)
  {
   return(direction>0 ? SSV5_g_market.probability30Up : SSV5_g_market.probability30Down);
  }

double SSV5_CalibrationPriorRate(const int bin)
  {
   if(bin<=0) return(0.08);
   if(bin==1) return(0.11);
   if(bin==2) return(0.14);
   if(bin==3) return(0.17);
   return(0.21);
  }

int SSV5_CalibrationBin(const double probability)
  {
   if(probability<0.12) return(0);
   if(probability<0.16) return(1);
   if(probability<0.20) return(2);
   if(probability<0.25) return(3);
   return(4);
  }

void SSV5_InitializeCalibration()
  {
   int storedSchema=(int)SSV5_ReadPersistent("V4CalSchema",0.0);
   if(storedSchema!=SSV5_CALIBRATION_SCHEMA)
     {
      // V3 outcomes cannot be migrated safely because reads and writes could
      // use different bins.  Reset those counters exactly once for V4.
      for(int staleBin=0;staleBin<5;staleBin++)
        {
         SSV5_DeletePersistent("V4CalHits"+IntegerToString(staleBin));
         SSV5_DeletePersistent("V4CalMisses"+IntegerToString(staleBin));
        }
      SSV5_WritePersistent("V4CalSchema",SSV5_CALIBRATION_SCHEMA);
      GlobalVariablesFlush();
     }
   for(int bin=0;bin<5;bin++)
     {
      SSV5_g_calibrationHits[bin]=MathMax(0.0,SSV5_ReadPersistent("V4CalHits"+IntegerToString(bin),0.0));
      SSV5_g_calibrationMisses[bin]=MathMax(0.0,SSV5_ReadPersistent("V4CalMisses"+IntegerToString(bin),0.0));
     }
  }

double SSV5_ApplyOnlineCalibration(const double offlineProbability,const int sourceBin)
  {
   int bin=MathMax(0,MathMin(4,sourceBin));
   double observations=SSV5_g_calibrationHits[bin]+SSV5_g_calibrationMisses[bin];
   double priorStrength=20.0;
   double posterior=(priorStrength*SSV5_CalibrationPriorRate(bin)+SSV5_g_calibrationHits[bin])/
                    (priorStrength+observations);
   double learnedWeight=SSV5_Clamp(observations/60.0,0.0,0.65);
   return(SSV5_Clamp((1.0-learnedWeight)*offlineProbability+learnedWeight*posterior,0.02,0.60));
  }

void SSV5_RecordCalibrationOutcome(const int bin,const bool success)
  {
   if(bin<0 || bin>4) return;
   // A bounded effective history lets the live calibration follow regime
   // changes instead of allowing early outcomes to dominate forever.
   for(int decayBin=0;decayBin<5;decayBin++)
     {
      SSV5_g_calibrationHits[decayBin]*=SSV5_CALIBRATION_DECAY;
      SSV5_g_calibrationMisses[decayBin]*=SSV5_CALIBRATION_DECAY;
     }
   if(success) SSV5_g_calibrationHits[bin]++;
   else SSV5_g_calibrationMisses[bin]++;
   for(int persistBin=0;persistBin<5;persistBin++)
     {
      SSV5_WritePersistent("V4CalHits"+IntegerToString(persistBin),SSV5_g_calibrationHits[persistBin]);
      SSV5_WritePersistent("V4CalMisses"+IntegerToString(persistBin),SSV5_g_calibrationMisses[persistBin]);
     }
   GlobalVariablesFlush();
  }

double SSV5_OfflineCalibratedP30(const int direction,const double chaseDistance,int &sourceBin)
  {
   double sigma1=MathMax(SSV5_g_market.sigmaM1,Point);
   double rawP30=SSV5_DirectionRawProbability(direction);
   double structuralQuality=SSV5_Clamp((direction*SSV5_g_market.structuralScore-0.55)/1.75,0.0,1.0);
   double energyQuality=0.55*SSV5_Clamp((SSV5_g_market.atrExpansionM5-0.90)/0.35,0.0,1.0)+
                        0.45*SSV5_Clamp(SSV5_g_market.atrAccelerationM5/0.12,0.0,1.0);
   double m1Tracking=SSV5_Clamp(direction*SSV5_g_market.velocityM1/(sigma1+Point),-1.0,1.0);
   double chaseRisk=SSV5_Clamp(chaseDistance/MathMax(5.0,2.5*SSV5_g_market.atrM5),0.0,1.0);

   // This is deliberately conservative.  The supplied holdout did not justify
   // treating a $30 excursion as a high-probability event.  Online calibration
   // may move the estimate only after resolved live outcomes accumulate.
   double offline=0.055+0.050*structuralQuality+0.025*energyQuality+
                   0.012*SSV5_Clamp(rawP30,0.0,1.0)+0.008*MathMax(0.0,m1Tracking)-
                   0.020*chaseRisk;
   double boundedOffline=SSV5_Clamp(offline,0.03,0.20);
   sourceBin=SSV5_CalibrationBin(boundedOffline);
   return(SSV5_ApplyOnlineCalibration(boundedOffline,sourceBin));
  }

void SSV5_ClearDirectionTracker(SSV5_DirectionTracker &tracker)
  {
   tracker.evidenceLogOdds=0.0;
   tracker.rawP30=0.0;
   tracker.calibratedP30=0.0;
   tracker.expectedTravel=0.0;
   tracker.expectedAdverse=0.0;
   tracker.remainingTravel=0.0;
   tracker.chaseDistance=0.0;
   tracker.exhaustionRisk=0.0;
   tracker.opportunityScore=0.0;
   tracker.entryDevelopmentATR=0.0;
   tracker.calibrationBin=-1;
   tracker.supportBars=0;
   tracker.contradictionBars=0;
  }

void SSV5_UpdateDirectionTracker(const int direction,SSV5_DirectionTracker &tracker,const bool accumulateEvidence)
  {
   double current=SSV5_CurrentMidPrice();
   double anchor=SSV5_RecentMovementAnchor(direction,12);
   double chase=MathMax(0.0,direction*(current-anchor));
   double sigma=MathMax(SSV5_g_market.sigmaM1,Point);
   double directedLogit=direction*SSV5_g_market.directionalLogit;
   double cusumEdge=SSV5_DirectionalCUSUM(direction)-SSV5_OpposingCUSUM(direction);
   double structuralSupport=direction*SSV5_g_market.structuralScore;
   double directedEfficiency=direction*SSV5_g_market.efficiencyM5;
   double m1Tracking=direction*SSV5_g_market.velocityM1/(sigma+Point);
   double energySupport=0.55*SSV5_Clamp((SSV5_g_market.atrExpansionM5-0.90)/0.35,0.0,1.0)+
                        0.45*SSV5_Clamp(SSV5_g_market.atrAccelerationM5/0.12,0.0,1.0);
   double regimeSupport=SSV5_g_market.modeDrift+SSV5_g_market.modeImpulse;
   double contradiction=MathMax(0.0,-m1Tracking)+MathMax(0.0,-cusumEdge)*0.12;
   double instantEvidence=0.46*structuralSupport+0.22*directedLogit+
                           0.16*direction*SSV5_g_market.velocity3M5ATR+
                           0.10*directedEfficiency+0.12*energySupport+
                           0.07*SSV5_Clamp(cusumEdge,-3.0,5.0)+0.06*m1Tracking+
                           0.12*regimeSupport-0.30*SSV5_g_market.modeExhaustion-
                           0.25*SSV5_g_market.modeShock;
   if(accumulateEvidence)
     {
      tracker.evidenceLogOdds=SSV5_Clamp(0.72*tracker.evidenceLogOdds+0.46*instantEvidence,-8.0,8.0);
      if(instantEvidence>0.55)
        {
         tracker.supportBars=MathMin(tracker.supportBars+1,30);
         tracker.contradictionBars=MathMax(0,tracker.contradictionBars-1);
        }
      else if(instantEvidence<-0.20)
        {
         tracker.contradictionBars=MathMin(tracker.contradictionBars+1,30);
         tracker.supportBars=MathMax(0,tracker.supportBars-1);
        }
     }

   tracker.rawP30=SSV5_DirectionRawProbability(direction);
   tracker.calibratedP30=SSV5_OfflineCalibratedP30(direction,chase,tracker.calibrationBin);
   double directedDrift=MathMax(0.0,direction*(0.18*SSV5_g_market.velocityM1+0.82*SSV5_g_market.velocityM5));
   double diffusionCapacity=1.35*sigma*MathSqrt(MathMax(SSV5_g_market.horizonMinutes,1.0));
   double driftCapacity=0.65*directedDrift*SSV5_g_market.horizonMinutes;
   double environmentCapacity=0.75*SSV5_SafeATR(PERIOD_M30,14)+2.0*SSV5_g_market.atrM5;
   tracker.expectedTravel=SSV5_Clamp(0.34*diffusionCapacity+0.31*driftCapacity+
                                 0.35*environmentCapacity+16.0*tracker.calibratedP30,6.0,60.0);
   tracker.expectedAdverse=SSV5_Clamp(2.4*sigma*MathSqrt(8.0),5.0,15.0);
   tracker.chaseDistance=chase;
   tracker.entryDevelopmentATR=chase/MathMax(SSV5_g_market.atrM5,Point);
   tracker.remainingTravel=MathMax(0.0,tracker.expectedTravel-0.72*chase);
   double chaseRisk=SSV5_Clamp(chase/MathMax(tracker.expectedTravel,1.0),0.0,1.5);
   double disagreement=(!SSV5_M5MotionAligned(direction) ? 1.0 : 0.0);
   tracker.exhaustionRisk=SSV5_Clamp(0.42*SSV5_g_market.modeExhaustion+0.22*SSV5_g_market.modeShock+
                                0.24*chaseRisk+0.08*contradiction+0.12*disagreement,0.0,1.0);

   double structuralQuality=SSV5_Clamp((structuralSupport-SSV5_MIN_STRUCTURAL_ONSET_SCORE)/1.60,0.0,1.0);
   double motionQuality=(SSV5_M5MotionAligned(direction) ? 1.0 : 0.0);
   double probabilityQuality=SSV5_Clamp((tracker.calibratedP30-0.04)/0.13,0.0,1.0);
   double remainingQuality=SSV5_Clamp(tracker.remainingTravel/30.0,0.0,1.0);
   double persistenceQuality=SSV5_Clamp(tracker.evidenceLogOdds/2.5,0.0,1.0);
   tracker.opportunityScore=SSV5_Clamp(0.28*structuralQuality+0.17*energySupport+
                                   0.14*motionQuality+0.12*probabilityQuality+
                                   0.14*remainingQuality+0.08*persistenceQuality+
                                   0.07*(1.0-tracker.exhaustionRisk),0.0,1.0);
  }

void SSV5_UpdateDirectionalTrackers(const bool accumulateEvidence)
  {
   SSV5_UpdateDirectionTracker(1,SSV5_g_trackerUp,accumulateEvidence);
   SSV5_UpdateDirectionTracker(-1,SSV5_g_trackerDown,accumulateEvidence);
  }

void SSV5_ComputeMarketSnapshot(const bool updateModes,const double suppliedSigmaM1=0.0)
  {
   double velocityFastM1=SSV5_LinearVelocity(PERIOD_M1,4);
   double velocitySlowM1=SSV5_LinearVelocity(PERIOD_M1,12);
   double velocityFastM5=SSV5_LinearVelocity(PERIOD_M5,3);
   double velocitySlowM5=SSV5_LinearVelocity(PERIOD_M5,8);

   SSV5_g_market.velocityM1=0.68*velocityFastM1+0.32*velocitySlowM1;
   SSV5_g_market.velocityM5=0.62*velocityFastM5+0.38*velocitySlowM5;
   SSV5_g_market.accelerationM1=(velocityFastM1-velocitySlowM1)/4.0;
   SSV5_g_market.accelerationM5=(velocityFastM5-velocitySlowM5)/15.0;
   SSV5_g_market.sigmaM1=(suppliedSigmaM1>0.0 ? suppliedSigmaM1 : SSV5_ReturnSigma(PERIOD_M1,48,0.10));
   SSV5_g_market.sigmaM5=SSV5_ReturnSigma(PERIOD_M5,36,0.12);
   SSV5_g_market.efficiencyM1=SSV5_DirectionalEfficiency(PERIOD_M1,10);
   SSV5_g_market.efficiencyM5=SSV5_DirectionalEfficiency(PERIOD_M5,6);
   SSV5_g_market.pathAlternationM1=SSV5_CandleAlternationRate(PERIOD_M1,6);
   SSV5_g_market.wickRejectionM1=SSV5_WickRejectionBalance(PERIOD_M1,4);
   SSV5_g_market.accelerationPersistenceM1=SSV5_AccelerationPersistenceM1(SSV5_g_market.sigmaM1);
   SSV5_ComputeM5StructuralFeatures();

   SSV5_g_market.rangeExpansion=SSV5_g_market.atrExpansionM5;

   // M30 is strictly unsigned: it sizes the horizon but cannot impose direction.
   double environment30=SSV5_SafeATR(PERIOD_M30,4)/SSV5_SafeATR(PERIOD_M30,16);
   SSV5_g_market.environmentFactor=SSV5_Clamp(MathSqrt(MathMax(SSV5_g_market.atrExpansionM5*environment30,0.01)),0.65,1.65);
   SSV5_g_market.horizonMinutes=SSV5_Clamp(120.0/SSV5_g_market.environmentFactor,60.0,180.0);

   double sigmaVelocityM1=MathMax(SSV5_g_market.sigmaM1,Point);
   double sigmaVelocityM5=MathMax(SSV5_g_market.sigmaM5/5.0,Point);
   double zVelocityM1=SSV5_Clamp(SSV5_g_market.velocityM1/sigmaVelocityM1,-4.0,4.0);
   double zVelocityM5=SSV5_Clamp(SSV5_g_market.velocityM5/sigmaVelocityM5,-4.0,4.0);
   double zAccelerationM1=SSV5_Clamp(SSV5_g_market.accelerationM1/(sigmaVelocityM1/4.0+Point),-4.0,4.0);
   double zAccelerationM5=SSV5_Clamp(SSV5_g_market.accelerationM5/(sigmaVelocityM5/3.0+Point),-4.0,4.0);
   double pressure=0.20*SSV5_AverageBarPressure(PERIOD_M1,4)+0.80*SSV5_AverageBarPressure(PERIOD_M5,2);
   double speed=0.20*MathAbs(zVelocityM1)+0.80*MathAbs(zVelocityM5);
   double acceleration=MathAbs(0.20*zAccelerationM1+0.80*zAccelerationM5);
   double efficiency=0.20*MathAbs(SSV5_g_market.efficiencyM1)+0.80*MathAbs(SSV5_g_market.efficiencyM5);
   double agreement=SSV5_SignOf(zVelocityM1*zVelocityM5)*MathMin(MathAbs(zVelocityM1),MathAbs(zVelocityM5));
   double latestReturn=iClose(Symbol(),PERIOD_M1,1)-iClose(Symbol(),PERIOD_M1,2);
   double latestReturnZ=latestReturn/MathMax(SSV5_g_market.sigmaM1,Point);
   SSV5_g_market.motionDisagreement=(zVelocityM1*zVelocityM5<0.0 ?
                                SSV5_Clamp(MathMin(MathAbs(zVelocityM1),MathAbs(zVelocityM5))/2.0,0.0,1.0) : 0.0);

   if(updateModes)
      UpdateModeProbabilities(speed,acceleration,efficiency,agreement,SSV5_g_market.rangeExpansion,latestReturnZ);

   double accelerationWeight=0.10+0.08*SSV5_g_market.modeImpulse-0.05*SSV5_g_market.modeExhaustion;
   double cusumEvidence=0.05*(SSV5_g_cusumUp-SSV5_g_cusumDown);

   SSV5_g_market.directionalLogit=
      0.88*SSV5_g_market.structuralScore+
      (0.22+0.10*SSV5_g_market.modeDrift)*zVelocityM5+
      accelerationWeight*(0.15*zAccelerationM1+0.85*zAccelerationM5)+
      0.16*SSV5_g_market.efficiencyM5+
      0.08*zVelocityM1+
      0.10*pressure+
      cusumEvidence;

   // Exhaustion and shock reduce magnitude symmetrically; they never choose direction.
   double magnitudeDamping=SSV5_Clamp(1.0-0.30*SSV5_g_market.modeExhaustion-0.22*SSV5_g_market.modeShock,0.45,1.0);
   SSV5_g_market.directionalLogit*=magnitudeDamping;
   SSV5_g_market.probability30Up=SSV5_DestinationProbability(1,30.0);
   SSV5_g_market.probability30Down=SSV5_DestinationProbability(-1,30.0);

   // Research health is descriptive only.  It never enters an acquisition,
   // order, or exit condition.
   double noveltyComponent=SSV5_Clamp((SSV5_g_market.structuralNovelty-0.75)/2.25,0.0,1.0);
   double pathInstability=SSV5_Clamp(0.65*SSV5_g_market.pathAlternationM1+
                                0.35*(1.0-MathAbs(SSV5_g_market.efficiencyM1)),0.0,1.0);
   double predictionStress=(SSV5_g_researchResolvedProduction>0 ?
                            SSV5_Clamp(SSV5_g_researchPredictionErrorEWMA/0.50,0.0,1.0) : 0.0);
   SSV5_g_market.researchDriftScore=SSV5_Clamp(0.45*noveltyComponent+
                                     0.25*SSV5_g_market.motionDisagreement+
                                     0.15*pathInstability+
                                     0.15*predictionStress,0.0,1.0);
  }

void SSV5_UpdateCUSUM(const double sigmaM1)
  {
   double newest=iClose(Symbol(),PERIOD_M1,1);
   double previous=iClose(Symbol(),PERIOD_M1,2);
   if(newest<=0.0 || previous<=0.0) return;
   double standardized=(newest-previous)/MathMax(sigmaM1,Point);
   SSV5_g_cusumUp=MathMax(0.0,SSV5_CUSUM_DECAY*SSV5_g_cusumUp+standardized-SSV5_CUSUM_ALLOWANCE);
   SSV5_g_cusumDown=MathMax(0.0,SSV5_CUSUM_DECAY*SSV5_g_cusumDown-standardized-SSV5_CUSUM_ALLOWANCE);
   SSV5_g_cusumUp=SSV5_Clamp(SSV5_g_cusumUp,0.0,12.0);
   SSV5_g_cusumDown=SSV5_Clamp(SSV5_g_cusumDown,0.0,12.0);
  }

//+------------------------------------------------------------------+
//| Daily entry accounting                                           |
//+------------------------------------------------------------------+
int SSV5_CountFilledEntriesFromTerminal(const int dayKey)
  {
   datetime openTimes[];
   int count=0;
   for(int openIndex=OrdersTotal()-1; openIndex>=0; openIndex--)
     {
      if(!OrderSelect(openIndex,SELECT_BY_POS,MODE_TRADES)) continue;
       if(!SSV5_IsStrategyFamilyMagic(OrderMagicNumber()) || OrderSymbol()!=Symbol()) continue;
      if(!SSV5_IsMarketOrderType(OrderType())) continue;
      if(SSV5_BrokerDayKey(OrderOpenTime())==dayKey)
        {
         ArrayResize(openTimes,count+1);
         openTimes[count++]=OrderOpenTime();
        }
     }
   for(int historyIndex=OrdersHistoryTotal()-1; historyIndex>=0; historyIndex--)
     {
      if(!OrderSelect(historyIndex,SELECT_BY_POS,MODE_HISTORY)) continue;
       if(!SSV5_IsStrategyFamilyMagic(OrderMagicNumber()) || OrderSymbol()!=Symbol()) continue;
      if(!SSV5_IsMarketOrderType(OrderType())) continue;
      if(SSV5_BrokerDayKey(OrderOpenTime())==dayKey)
        {
         ArrayResize(openTimes,count+1);
         openTimes[count++]=OrderOpenTime();
        }
     }
   if(count<=1) return(count);
   ArraySort(openTimes,WHOLE_ARRAY,0,MODE_ASCEND);
   int uniqueCount=1;
   for(int index=1;index<count;index++)
      if(openTimes[index]!=openTimes[index-1]) uniqueCount++;
   return(uniqueCount);
  }

int SSV5_EntriesToday()
  {
   int today=SSV5_BrokerDayKey(TimeCurrent());
   int storedDay=(int)SSV5_ReadPersistent("Day",0.0);
   int storedCount=(int)SSV5_ReadPersistent("Entries",-1.0);
   int historyTotal=OrdersHistoryTotal();
   int openOrdersTotal=OrdersTotal();
   bool dayReset=(storedDay!=today || storedCount<0);
   bool cacheMissing=(SSV5_g_entriesTodayDay!=today || SSV5_g_entriesTodayCached<0);
   bool terminalChanged=(historyTotal!=SSV5_g_lastHistoryTotal || openOrdersTotal!=SSV5_g_lastOpenOrdersTotal);
   if(!dayReset && !cacheMissing && !terminalChanged) return(SSV5_g_entriesTodayCached);

   int terminalCount=SSV5_CountFilledEntriesFromTerminal(today);
   SSV5_g_entriesTodayDay=today;
   SSV5_g_entriesTodayCached=terminalCount;
   SSV5_g_lastHistoryTotal=historyTotal;
   SSV5_g_lastOpenOrdersTotal=openOrdersTotal;
   if(dayReset || terminalCount!=storedCount)
     {
       storedCount=terminalCount;
       SSV5_WritePersistent("Day",today);
       SSV5_WritePersistent("Entries",storedCount);
       GlobalVariablesFlush();
     }
   return(SSV5_g_entriesTodayCached);
  }

void SSV5_IncrementEntriesToday()
  {
   int today=SSV5_BrokerDayKey(TimeCurrent());
   int storedDay=(int)SSV5_ReadPersistent("Day",0.0);
   int storedCount=(int)SSV5_ReadPersistent("Entries",0.0);
   int count=0;
   if(storedDay!=today || storedCount<0 || SSV5_g_entriesTodayDay!=today || SSV5_g_entriesTodayCached<0)
      count=SSV5_CountFilledEntriesFromTerminal(today);
   else
      count=(int)MathMax(storedCount+1,SSV5_g_entriesTodayCached+1);
   SSV5_WritePersistent("Day",today);
   SSV5_WritePersistent("Entries",count);
   SSV5_g_entriesTodayDay=today;
   SSV5_g_entriesTodayCached=count;
   SSV5_g_lastHistoryTotal=OrdersHistoryTotal();
   SSV5_g_lastOpenOrdersTotal=OrdersTotal();
   GlobalVariablesFlush();
  }

double SSV5_ClosedStrategyPnLToday()
  {
   int today=SSV5_BrokerDayKey(TimeCurrent());
   double result=0.0;
   for(int index=OrdersHistoryTotal()-1;index>=0;index--)
     {
      if(!OrderSelect(index,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderSymbol()!=Symbol() || !SSV5_IsStrategyFamilyMagic(OrderMagicNumber())) continue;
      if(!SSV5_IsMarketOrderType(OrderType()) || SSV5_BrokerDayKey(OrderCloseTime())!=today) continue;
      result+=OrderProfit()+OrderSwap()+OrderCommission();
     }
   return(result);
  }

datetime SSV5_LatestStrategyEntryTime()
  {
   datetime latest=0;
   for(int historyIndex=OrdersHistoryTotal()-1;historyIndex>=0;historyIndex--)
     {
      if(!OrderSelect(historyIndex,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderSymbol()!=Symbol() || !SSV5_IsStrategyFamilyMagic(OrderMagicNumber())) continue;
      if(SSV5_IsMarketOrderType(OrderType())) latest=MathMax(latest,OrderOpenTime());
     }
   for(int openIndex=OrdersTotal()-1;openIndex>=0;openIndex--)
     {
      if(!OrderSelect(openIndex,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || !SSV5_IsStrategyFamilyMagic(OrderMagicNumber())) continue;
      if(SSV5_IsMarketOrderType(OrderType())) latest=MathMax(latest,OrderOpenTime());
     }
   return(latest);
  }

bool SSV5_OperationalEntryAllowed(const int direction,string &reason)
  {
   reason="";
   if(!SSV5_AUTOMATIC_ENTRIES_ENABLED) { reason="AUTOMATIC ENTRIES DISABLED"; return(false); }
   if(direction>0 && !SSV5_BUY_SIGNALS_ENABLED) { reason="BUY ENTRIES DISABLED"; return(false); }
   if(direction<0 && !SSV5_SELL_SIGNALS_ENABLED) { reason="SELL ENTRIES DISABLED"; return(false); }
   if(SSV5_MaximumTradesPerBrokerDay>0 && SSV5_EntriesToday()>=SSV5_MaximumTradesPerBrokerDay)
     { reason="DAILY TRADE LIMIT"; return(false); }
   if(SSV5_MaximumDailyLossCurrency>0.0 && SSV5_ClosedStrategyPnLToday()<=-SSV5_MaximumDailyLossCurrency)
     { reason="DAILY LOSS LIMIT"; return(false); }
   datetime latest=SSV5_LatestStrategyEntryTime();
   if(SSV5_MinimumMinutesBetweenEntries>0 && latest>0 &&
      TimeCurrent()-latest<SSV5_MinimumMinutesBetweenEntries*60)
     { reason="ENTRY COOLDOWN"; return(false); }
   return(true);
  }

//+------------------------------------------------------------------+
//| Order discovery and persistence                                  |
//+------------------------------------------------------------------+
int SSV5_FindOpenEAOrder()
  {
   for(int index=OrdersTotal()-1; index>=0; index--)
     {
      if(!OrderSelect(index,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderMagicNumber()!=SSV5_EA_MAGIC || OrderSymbol()!=Symbol()) continue;
      if(!SSV5_IsMarketOrderType(OrderType())) continue;
      return(OrderTicket());
     }
   return(-1);
  }

bool SSV5_HasOpenStrategyPositionOnSymbol()
  {
   for(int index=OrdersTotal()-1; index>=0; index--)
     {
      if(!OrderSelect(index,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=SSV5_EA_MAGIC) continue;
      if(SSV5_IsMarketOrderType(OrderType())) return(true);
     }
   return(false);
  }

void SSV5_PersistActiveTrade()
  {
   if(!SSV5_g_instanceLeaseHeld) return;
   if(SSV5_g_activeTicket<=0) return;
   SSV5_WritePersistent("Ticket",SSV5_g_activeTicket);
   SSV5_WritePersistent("ExpectedSL",SSV5_g_expectedSL);
   SSV5_WritePersistent("ExpectedTP",SSV5_g_expectedTP);
   SSV5_WritePersistent("NeedExitSync",SSV5_g_needExitSync ? 1.0 : 0.0);
   SSV5_WritePersistent("ManualSL",SSV5_g_manualSLOverride ? 1.0 : 0.0);
   SSV5_WritePersistent("ManualTP",SSV5_g_manualTPOverride ? 1.0 : 0.0);
   SSV5_WritePersistent("Peak",SSV5_g_favorableExtreme);
   SSV5_WritePersistent("TrackLogOdds",SSV5_g_trackLogOdds);
   SSV5_WritePersistent("InvalidBars",SSV5_g_invalidBars);
   SSV5_WritePersistent("EntryTime",SSV5_g_activeEntryTime);
   SSV5_WritePersistent("EntryP30",SSV5_g_activeEntryP30);
   SSV5_WritePersistent("EntryExpected",SSV5_g_activeEntryExpectedTravel);
   SSV5_WritePersistent("EntryRemaining",SSV5_g_activeEntryRemainingTravel);
   SSV5_WritePersistent("EntryOpportunity",SSV5_g_activeEntryOpportunity);
   SSV5_WritePersistent("EntryRequested",SSV5_g_activeRequestedPrice);
   SSV5_WritePersistent("EntryFill",SSV5_g_activeFillPrice);
   SSV5_WritePersistent("EntrySpread",SSV5_g_activeEntrySpread);
   SSV5_WritePersistent("EntryDeviation",SSV5_g_activeEntryDeviation);
   SSV5_WritePersistent("V41EntryDevATR",SSV5_g_activeEntryDevelopmentATR);
   SSV5_WritePersistent("V41EntryAlt",SSV5_g_activeEntryPathAlternation);
   SSV5_WritePersistent("V41EntryWick",SSV5_g_activeEntryWickRejection);
   SSV5_WritePersistent("V41EntryAcc",SSV5_g_activeEntryAccelerationPersistence);
   SSV5_WritePersistent("V41EntryNovel",SSV5_g_activeEntryStructuralNovelty);
   SSV5_WritePersistent("V41EntryDrift",SSV5_g_activeEntryResearchDrift);
   SSV5_WritePersistent("SSV5_ProtectionState",SSV5_g_activeProtectionState);
   SSV5_WritePersistent("SSV5_CalibrationBin",SSV5_g_activeCalibrationBin);
   SSV5_WritePersistent("CalibrationSourceSchema",SSV5_CALIBRATION_SCHEMA);
   SSV5_WritePersistent("CalibrationResolved",SSV5_g_activeCalibrationResolved ? 1.0 : 0.0);
   SSV5_WritePersistent("CalibrationSuccess",SSV5_g_activeCalibrationSuccess ? 1.0 : 0.0);
   SSV5_WritePersistent("MaxFavorable",SSV5_g_activeMaxFavorable);
   SSV5_WritePersistent("MaxAdverse",SSV5_g_activeMaxAdverse);
   SSV5_WritePersistent("EntryHorizon",SSV5_g_activeHorizonMinutes);
   SSV5_WritePersistent("CusumUp",SSV5_g_cusumUp);
   SSV5_WritePersistent("CusumDown",SSV5_g_cusumDown);
   SSV5_WritePersistent("ModeNoise",SSV5_g_market.modeNoise);
   SSV5_WritePersistent("ModeDrift",SSV5_g_market.modeDrift);
   SSV5_WritePersistent("ModeImpulse",SSV5_g_market.modeImpulse);
   SSV5_WritePersistent("ModeExhaustion",SSV5_g_market.modeExhaustion);
   SSV5_WritePersistent("ModeShock",SSV5_g_market.modeShock);
   GlobalVariablesFlush();
  }

void SSV5_ClearActiveTradePersistence()
  {
   if(!SSV5_g_instanceLeaseHeld) return;
   SSV5_DeletePersistent("Ticket");
   SSV5_DeletePersistent("ExpectedSL");
   SSV5_DeletePersistent("ExpectedTP");
   SSV5_DeletePersistent("NeedExitSync");
   SSV5_DeletePersistent("ManualSL");
   SSV5_DeletePersistent("ManualTP");
   SSV5_DeletePersistent("Peak");
   SSV5_DeletePersistent("TrackLogOdds");
   SSV5_DeletePersistent("InvalidBars");
   SSV5_DeletePersistent("EntryTime");
   SSV5_DeletePersistent("EntryP30");
   SSV5_DeletePersistent("EntryExpected");
   SSV5_DeletePersistent("EntryRemaining");
   SSV5_DeletePersistent("EntryOpportunity");
   SSV5_DeletePersistent("EntryRequested");
   SSV5_DeletePersistent("EntryFill");
   SSV5_DeletePersistent("EntrySpread");
   SSV5_DeletePersistent("EntryDeviation");
   SSV5_DeletePersistent("V41EntryDevATR");
   SSV5_DeletePersistent("V41EntryAlt");
   SSV5_DeletePersistent("V41EntryWick");
   SSV5_DeletePersistent("V41EntryAcc");
   SSV5_DeletePersistent("V41EntryNovel");
   SSV5_DeletePersistent("V41EntryDrift");
   SSV5_DeletePersistent("SSV5_ProtectionState");
   SSV5_DeletePersistent("SSV5_CalibrationBin");
   SSV5_DeletePersistent("CalibrationSourceSchema");
   SSV5_DeletePersistent("CalibrationResolved");
   SSV5_DeletePersistent("CalibrationSuccess");
   SSV5_DeletePersistent("MaxFavorable");
   SSV5_DeletePersistent("MaxAdverse");
   SSV5_DeletePersistent("EntryHorizon");
   SSV5_DeletePersistent("CusumUp");
   SSV5_DeletePersistent("CusumDown");
   SSV5_DeletePersistent("ModeNoise");
   SSV5_DeletePersistent("ModeDrift");
   SSV5_DeletePersistent("ModeImpulse");
   SSV5_DeletePersistent("ModeExhaustion");
   SSV5_DeletePersistent("ModeShock");
   GlobalVariablesFlush();
  }

string SSV5_ResearchSlotKey(const int slot,const string field)
  {
   return("V41R"+IntegerToString(slot)+field);
  }

void SSV5_ClearResearchTrack(SSV5_ResearchTrack &track)
  {
   track.active=false;
   track.signalId=0;
   track.source=SSV5_RESEARCH_NONE;
   track.direction=0;
   track.blockCode=SSV5_RESEARCH_BLOCK_NONE;
   track.startTime=0;
   track.entryPrice=0.0;
   track.horizonMinutes=0.0;
   track.maxFavorable=0.0;
   track.maxAdverse=0.0;
   track.entryP30=0.0;
   track.opportunityScore=0.0;
   track.remainingTravel=0.0;
   track.exhaustionRisk=0.0;
   track.developmentATR=0.0;
   track.pathAlternation=0.0;
   track.wickRejection=0.0;
   track.accelerationPersistence=0.0;
   track.structuralNovelty=0.0;
   track.driftScore=0.0;
  }

void SSV5_DeleteResearchTrackPersistence(const int slot)
  {
   string fields[19]={"A","ID","S","D","B","T","E","H","MF","MA","P","O","R","X","V","PA","W","AP","N"};
   for(int index=0;index<19;index++) SSV5_DeletePersistent(SSV5_ResearchSlotKey(slot,fields[index]));
   SSV5_DeletePersistent(SSV5_ResearchSlotKey(slot,"DR"));
  }

void SSV5_PersistResearchTrack(const int slot)
  {
   if(!SSV5_g_instanceLeaseHeld || slot<0 || slot>=SSV5_RESEARCH_TRACK_SLOTS) return;
   SSV5_ResearchTrack track=SSV5_g_researchTracks[slot];
   if(!track.active)
     {
      SSV5_DeleteResearchTrackPersistence(slot);
      return;
     }
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"A"),1.0);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"ID"),(double)track.signalId);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"S"),track.source);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"D"),track.direction);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"B"),track.blockCode);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"T"),(double)track.startTime);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"E"),track.entryPrice);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"H"),track.horizonMinutes);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"MF"),track.maxFavorable);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"MA"),track.maxAdverse);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"P"),track.entryP30);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"O"),track.opportunityScore);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"R"),track.remainingTravel);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"X"),track.exhaustionRisk);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"V"),track.developmentATR);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"PA"),track.pathAlternation);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"W"),track.wickRejection);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"AP"),track.accelerationPersistence);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"N"),track.structuralNovelty);
   SSV5_WritePersistent(SSV5_ResearchSlotKey(slot,"DR"),track.driftScore);
  }

void SSV5_PersistResearchLayer()
  {
   if(!SSV5_g_instanceLeaseHeld) return;
   for(int slot=0;slot<SSV5_RESEARCH_TRACK_SLOTS;slot++) SSV5_PersistResearchTrack(slot);
   SSV5_WritePersistent("V41PredError",SSV5_g_researchPredictionErrorEWMA);
   SSV5_WritePersistent("V41Resolved",SSV5_g_researchResolvedProduction);
   GlobalVariablesFlush();
   SSV5_g_lastResearchPersist=TimeCurrent();
  }

void SSV5_InitializeResearchLayer()
  {
   SSV5_g_researchPredictionErrorEWMA=SSV5_Clamp(SSV5_ReadPersistent("V41PredError",0.0),0.0,1.0);
   SSV5_g_researchResolvedProduction=MathMax(0,(int)SSV5_ReadPersistent("V41Resolved",0.0));
   for(int slot=0;slot<SSV5_RESEARCH_TRACK_SLOTS;slot++)
     {
      SSV5_ClearResearchTrack(SSV5_g_researchTracks[slot]);
      if(SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"A"),0.0)<=0.5) continue;
      SSV5_ResearchTrack track;
      SSV5_ClearResearchTrack(track);
      track.active=true;
      track.signalId=(long)SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"ID"),0.0);
      track.source=(int)SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"S"),SSV5_RESEARCH_NONE);
      track.direction=(int)SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"D"),0.0);
      track.blockCode=(int)SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"B"),SSV5_RESEARCH_BLOCK_NONE);
      track.startTime=(datetime)SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"T"),0.0);
      track.entryPrice=SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"E"),0.0);
      track.horizonMinutes=SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"H"),120.0);
      track.maxFavorable=MathMax(0.0,SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"MF"),0.0));
      track.maxAdverse=MathMax(0.0,SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"MA"),0.0));
      track.entryP30=SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"P"),0.0);
      track.opportunityScore=SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"O"),0.0);
      track.remainingTravel=SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"R"),0.0);
      track.exhaustionRisk=SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"X"),0.0);
      track.developmentATR=SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"V"),0.0);
      track.pathAlternation=SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"PA"),0.0);
      track.wickRejection=SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"W"),0.0);
      track.accelerationPersistence=SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"AP"),0.0);
      track.structuralNovelty=SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"N"),0.0);
      track.driftScore=SSV5_ReadPersistent(SSV5_ResearchSlotKey(slot,"DR"),0.0);
      bool valid=(track.source>=SSV5_RESEARCH_REJECTED && track.source<=SSV5_RESEARCH_QUALIFIED &&
                  MathAbs(track.direction)==1 && track.startTime>0 && track.entryPrice>0.0);
      if(valid) SSV5_g_researchTracks[slot]=track;
      else SSV5_DeleteResearchTrackPersistence(slot);
     }
   GlobalVariablesFlush();
  }

void SSV5_ResetTesterPersistence()
  {
   if(!IsTesting() || !SSV5_g_instanceLeaseHeld) return;
   SSV5_ClearActiveTradePersistence();
   SSV5_DeletePersistent("Day");
   SSV5_DeletePersistent("Entries");
   SSV5_DeletePersistent("Reconfigure");
   SSV5_DeletePersistent("V4CalSchema");
   for(int bin=0;bin<5;bin++)
     {
      SSV5_DeletePersistent("V4CalHits"+IntegerToString(bin));
      SSV5_DeletePersistent("V4CalMisses"+IntegerToString(bin));
     }
   for(int researchSlot=0;researchSlot<SSV5_RESEARCH_TRACK_SLOTS;researchSlot++)
     {
      SSV5_DeleteResearchTrackPersistence(researchSlot);
      SSV5_ClearResearchTrack(SSV5_g_researchTracks[researchSlot]);
     }
   SSV5_DeletePersistent("V41PredError");
   SSV5_DeletePersistent("V41Resolved");
   SSV5_DeleteThesisPersistence();
   SSV5_g_thesisDirection=0;
   SSV5_g_thesisEntries=0;
   SSV5_g_thesisResetBars=0;
   SSV5_g_thesisStartBar=0;
   SSV5_g_thesisLocked=false;
   SSV5_g_continuationPending=false;
   SSV5_g_continuationAuthorized=false;
   SSV5_g_thesisMigrationBootstrap=false;
   SSV5_g_continuationReference=0.0;
   SSV5_g_continuationOpportunityFloor=0.0;
   SSV5_g_thesisBlockReason="";
   SSV5_g_researchPredictionErrorEWMA=0.0;
   SSV5_g_researchResolvedProduction=0;
   SSV5_g_lastResearchPersist=0;
   SSV5_g_entriesTodayCached=-1;
   SSV5_g_entriesTodayDay=0;
   SSV5_g_lastHistoryTotal=-1;
   SSV5_g_lastOpenOrdersTotal=-1;
   GlobalVariablesFlush();
  }

int SSV5_LotDigitsFromStep(const double step)
  {
   double scaled=MathAbs(step);
   for(int digits=0;digits<=8;digits++)
     {
      if(MathAbs(scaled-MathRound(scaled))<=0.00000001) return(digits);
      scaled*=10.0;
     }
   return(8);
  }

bool SSV5_ValidateRequestedLots(const double requested,string &reason)
  {
   double minimum=MarketInfo(Symbol(),MODE_MINLOT);
   double maximum=MarketInfo(Symbol(),MODE_MAXLOT);
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(minimum<=0.0 || maximum<=0.0 || step<=0.0)
     {
      reason="broker lot specification is unavailable";
      return(false);
     }

   int lotDigits=MathMax(SSV5_LotDigitsFromStep(step),SSV5_LotDigitsFromStep(minimum));
   double tolerance=MathMax(0.00000001,step*0.000001);
   if(requested<minimum-tolerance)
     {
      reason="LotSize "+DoubleToString(requested,lotDigits)+" is below broker minimum "+DoubleToString(minimum,lotDigits);
      return(false);
     }
   if(requested>maximum+tolerance)
     {
      reason="LotSize "+DoubleToString(requested,lotDigits)+" exceeds broker maximum "+DoubleToString(maximum,lotDigits);
      return(false);
     }

   double nearest=minimum+MathRound((requested-minimum)/step)*step;
   if(MathAbs(requested-nearest)>tolerance)
     {
      reason="LotSize "+DoubleToString(requested,lotDigits)+" is not aligned to broker step "+DoubleToString(step,lotDigits);
      return(false);
     }
   return(true);
  }

bool SSV5_ValidateUserInputs(string &reason)
  {
   string upperSymbol=Symbol();
   StringToUpper(upperSymbol);
   if(StringFind(upperSymbol,"XAU")<0 && StringFind(upperSymbol,"GOLD")<0)
     {
      reason="attach the EA only to a Gold/XAU symbol";
      return(false);
     }
   if(SSV5_StopLoss_PriceUSD<0.0 || SSV5_TakeProfit_PriceUSD<0.0 ||
       SSV5_LockTrigger_PriceUSD<0.0 || SSV5_LockedProfit_PriceUSD<0.0 ||
       SSV5_TrailingStart_PriceUSD<0.0 || SSV5_TrailingDistance_PriceUSD<0.0 ||
       SSV5_MaximumSpreadMovement<0.0 || SSV5_MaximumEntryDeviationMovement<0.0 ||
       SSV5_MaximumSlippageMovement<0.0 || SSV5_MinimumMinutesBetweenEntries<0 ||
       SSV5_MaximumTradesPerBrokerDay<0 || SSV5_MaximumDailyLossCurrency<0.0)
     {
      reason="entry, exposure, execution, and exit-management values are invalid";
      return(false);
     }
   if(SSV5_FixedLotSize<=0.0)
     {
      reason="fixed-lot sizing requires a positive lot size";
      return(false);
     }
   if(!SSV5_ValidateRequestedLots(SSV5_FixedLotSize,reason)) return(false);
   if(SSV5_MinimumM5PathEfficiencyPct<0.0 || SSV5_MinimumM5PathEfficiencyPct>100.0 ||
      SSV5_MinimumM5CoherencePct<0.0 || SSV5_MinimumM5CoherencePct>100.0 ||
      SSV5_MinimumM1CoherencePct<0.0 || SSV5_MinimumM1CoherencePct>100.0 ||
      SSV5_MinimumM5VelocityStrength<0.0 ||
      SSV5_MaximumM5VelocityStrength<=SSV5_MinimumM5VelocityStrength ||
      SSV5_MaximumM5ShockRatio<=0.0 || SSV5_MaximumM5PullbackATR<=0.0 ||
      SSV5_MinimumM1TriggerStrength<0.0 || SSV5_MinimumM1AccelerationATR<-10.0 ||
      SSV5_MinimumM1AccelerationATR>10.0 || SSV5_MaximumM1ShockRatio<=0.0 ||
      SSV5_MaximumM1ChaseM5ATR<=0.0 || SSV5_EliteStructuralScore<=0.0 ||
      SSV5_EliteOpportunityScore<0.0 || SSV5_EliteOpportunityScore>1.0 ||
      SSV5_EliteMaximumExhaustionRisk<0.0 || SSV5_EliteMaximumExhaustionRisk>1.0)
     {
      reason="M1/M5 velocity or elite-entry thresholds are invalid";
      return(false);
     }
   if(SSV5_LockTrigger_PriceUSD<=0.0 && SSV5_LockedProfit_PriceUSD>0.0)
     {
      reason="SSV5_LockedProfit_PriceUSD requires a positive SSV5_LockTrigger_PriceUSD";
      return(false);
     }
   if(SSV5_LockTrigger_PriceUSD>0.0 && SSV5_LockedProfit_PriceUSD>=SSV5_LockTrigger_PriceUSD)
     {
      reason="SSV5_LockedProfit_PriceUSD must be smaller than SSV5_LockTrigger_PriceUSD";
      return(false);
     }
   bool trailingStartEnabled=(SSV5_TrailingStart_PriceUSD>0.0);
   bool trailingDistanceEnabled=(SSV5_TrailingDistance_PriceUSD>0.0);
   if(trailingStartEnabled!=trailingDistanceEnabled)
     {
      reason="SSV5_TrailingStart_PriceUSD and SSV5_TrailingDistance_PriceUSD must both be zero or both be positive";
      return(false);
     }
   return(true);
  }

double SSV5_NormalizeLots(const double requested)
  {
   double minimum=MarketInfo(Symbol(),MODE_MINLOT);
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   string reason="";
   if(!SSV5_ValidateRequestedLots(requested,reason)) return(0.0);
   double normalized=minimum+MathRound((requested-minimum)/step)*step;
   int lotDigits=MathMax(SSV5_LotDigitsFromStep(step),SSV5_LotDigitsFromStep(minimum));
   return(NormalizeDouble(normalized,lotDigits));
  }

double SSV5_CalculateEntryLots()
  {
   return(SSV5_NormalizeLots(SSV5_FixedLotSize));
  }

int SSV5_SlippagePointsForBroker()
  {
   if(SSV5_MaximumSlippageMovement<=0.0 || Point<=0.0) return(0);
   return((int)MathMax(0.0,MathRound(SSV5_MaximumSlippageMovement/Point)));
  }

void SSV5_CalculateInputStops(const int type,const double openPrice,double &stopLoss,double &takeProfit)
  {
   // An input SL is optional.  Existing manual or profit-protection stops are
   // preserved, and an active stop is never widened by an input change.
   stopLoss=OrderStopLoss();
   takeProfit=0.0;

   if(type==OP_BUY)
     {
      if(!SSV5_g_manualSLOverride)
        {
         if(SSV5_StopLoss_PriceUSD>0.0)
           {
            double configuredSL=openPrice-SSV5_StopLoss_PriceUSD;
            if(configuredSL>0.0 && (stopLoss<=0.0 || configuredSL>stopLoss)) stopLoss=configuredSL;
           }
         else if(stopLoss>0.0 && stopLoss<openPrice-Point) stopLoss=0.0;
        }
      if(SSV5_TakeProfit_PriceUSD>0.0)
         takeProfit=openPrice+SSV5_TakeProfit_PriceUSD;
     }
   else if(type==OP_SELL)
     {
      if(!SSV5_g_manualSLOverride)
        {
         if(SSV5_StopLoss_PriceUSD>0.0)
           {
            double configuredSL=openPrice+SSV5_StopLoss_PriceUSD;
            if(stopLoss<=0.0 || configuredSL<stopLoss) stopLoss=configuredSL;
           }
         else if(stopLoss>openPrice+Point) stopLoss=0.0;
        }
      if(SSV5_TakeProfit_PriceUSD>0.0)
         takeProfit=openPrice-SSV5_TakeProfit_PriceUSD;
     }

   if(stopLoss>0.0) stopLoss=NormalizeDouble(stopLoss,Digits);
   if(takeProfit>0.0) takeProfit=NormalizeDouble(takeProfit,Digits);
  }

bool SSV5_ModifyActiveStops(const double requestedSL,const double requestedTP,const string source)
  {
   if(!SSV5_g_instanceLeaseHeld) return(false);
   if(SSV5_g_activeTicket<=0) return(false);
   if(!OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return(false);
   if(SSV5_SamePrice(OrderStopLoss(),requestedSL) && SSV5_SamePrice(OrderTakeProfit(),requestedTP))
     {
      SSV5_g_expectedSL=OrderStopLoss();
      SSV5_g_expectedTP=OrderTakeProfit();
      return(true);
     }

   ResetLastError();
   bool modified=OrderModify(OrderTicket(),OrderOpenPrice(),requestedSL,requestedTP,0,clrNONE);
   if(!modified)
     {
      int error=GetLastError();
      if(error==ERR_NO_RESULT)
        {
         if(OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET,MODE_TRADES))
           {
            SSV5_g_expectedSL=OrderStopLoss();
            SSV5_g_expectedTP=OrderTakeProfit();
           }
         SSV5_PersistActiveTrade();
         return(true);
        }
      Print("XVISION SuperScalper: OrderModify failed source=",source," ticket=",SSV5_g_activeTicket," error=",error,
            " sl=",DoubleToString(requestedSL,Digits)," tp=",DoubleToString(requestedTP,Digits));
      return(false);
     }

   if(OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET,MODE_TRADES))
     {
      SSV5_g_expectedSL=OrderStopLoss();
      SSV5_g_expectedTP=OrderTakeProfit();
     }
   SSV5_PersistActiveTrade();
   return(true);
  }

bool SSV5_InputExitAlreadyReached(string &reason)
  {
   if(SSV5_g_activeTicket<=0 || !OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return(false);
   RefreshRates();
   int type=OrderType();
   double openPrice=OrderOpenPrice();
   bool enforceConfiguredSL=!SSV5_g_manualSLOverride;
   bool enforceConfiguredTP=!SSV5_g_manualTPOverride;
   if(SSV5_g_needExitSync && OrderStopLoss()>0.0 && SSV5_StopLoss_PriceUSD>0.0)
     {
      double configuredSL=(type==OP_BUY ? openPrice-SSV5_StopLoss_PriceUSD :
                           openPrice+SSV5_StopLoss_PriceUSD);
      configuredSL=NormalizeDouble(configuredSL,Digits);
      if(!SSV5_SamePrice(OrderStopLoss(),configuredSL) &&
         !SSV5_SamePrice(OrderStopLoss(),SSV5_g_expectedSL)) enforceConfiguredSL=false;
     }
   if(SSV5_g_needExitSync && OrderTakeProfit()>0.0)
     {
      double configuredTP=(type==OP_BUY ? openPrice+SSV5_TakeProfit_PriceUSD :
                           openPrice-SSV5_TakeProfit_PriceUSD);
      configuredTP=(SSV5_TakeProfit_PriceUSD>0.0 ? NormalizeDouble(configuredTP,Digits) : 0.0);
      if(!SSV5_SamePrice(OrderTakeProfit(),configuredTP) &&
         !SSV5_SamePrice(OrderTakeProfit(),SSV5_g_expectedTP)) enforceConfiguredTP=false;
     }
   if(type==OP_BUY)
     {
      if(enforceConfiguredSL && SSV5_StopLoss_PriceUSD>0.0 && Bid<=openPrice-SSV5_StopLoss_PriceUSD)
        {
         reason="configured stop-loss level already crossed";
         return(true);
        }
      if(enforceConfiguredTP && SSV5_TakeProfit_PriceUSD>0.0 && Bid>=openPrice+SSV5_TakeProfit_PriceUSD)
        {
         reason="configured take-profit level already crossed";
         return(true);
        }
     }
   else if(type==OP_SELL)
     {
      if(enforceConfiguredSL && SSV5_StopLoss_PriceUSD>0.0 && Ask>=openPrice+SSV5_StopLoss_PriceUSD)
        {
         reason="configured stop-loss level already crossed";
         return(true);
        }
      if(enforceConfiguredTP && SSV5_TakeProfit_PriceUSD>0.0 && Ask<=openPrice-SSV5_TakeProfit_PriceUSD)
        {
         reason="configured take-profit level already crossed";
         return(true);
        }
     }
   return(false);
  }

void SSV5_ApplyInputExits()
  {
   if(SSV5_g_activeTicket<=0) return;
   if(!OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return;
   RefreshRates();
   string reachedReason="";
   if(SSV5_InputExitAlreadyReached(reachedReason))
     {
       Print("XVISION SuperScalper: ",reachedReason,"; requesting full market exit ticket=",SSV5_g_activeTicket);
       SSV5_g_needExitSync=false;
       SSV5_g_activeProtectionState=SSV5_PROTECTION_FAILED;
       SSV5_g_modelExitRequested=true;
       SSV5_g_modelExitReason=reachedReason;
      SSV5_g_state=SSV5_STATE_EXITING;
      return;
     }
   if(TimeCurrent()<SSV5_g_nextExitSyncAttempt) return;
   double stopLoss=0.0,takeProfit=0.0;
   SSV5_CalculateInputStops(OrderType(),OrderOpenPrice(),stopLoss,takeProfit);
   if(!SSV5_SamePrice(OrderStopLoss(),SSV5_g_expectedSL))
     {
      SSV5_g_manualSLOverride=true;
      SSV5_g_expectedSL=OrderStopLoss();
      stopLoss=OrderStopLoss();
      Print("XVISION SuperScalper: manual SL detected while exit synchronization was pending.");
     }
   if(!SSV5_SamePrice(OrderTakeProfit(),SSV5_g_expectedTP) && OrderTakeProfit()>0.0 &&
      !SSV5_SamePrice(OrderTakeProfit(),takeProfit))
     {
      SSV5_g_manualTPOverride=true;
      SSV5_g_expectedTP=OrderTakeProfit();
      SSV5_g_needExitSync=false;
      SSV5_g_activeProtectionState=SSV5_PROTECTION_MANUAL;
      Print("XVISION SuperScalper: manual TP detected; configured exit synchronization cancelled.");
      SSV5_PersistActiveTrade();
      return;
     }
   if(SSV5_ModifyActiveStops(stopLoss,takeProfit,"input-sync"))
     {
      SSV5_g_needExitSync=false;
      SSV5_g_exitSyncFailures=0;
      SSV5_g_nextExitSyncAttempt=0;
      SSV5_g_activeProtectionState=((SSV5_g_manualSLOverride || SSV5_g_manualTPOverride) ? SSV5_PROTECTION_MANUAL :
                               ((SSV5_StopLoss_PriceUSD>0.0 || SSV5_TakeProfit_PriceUSD>0.0) ? SSV5_PROTECTION_SYNCED : SSV5_PROTECTION_OFF));
      SSV5_PersistActiveTrade();
     }
   else
     {
      SSV5_g_exitSyncFailures++;
      SSV5_g_activeProtectionState=SSV5_PROTECTION_PENDING;
      SSV5_g_nextExitSyncAttempt=TimeCurrent()+SSV5_OPERATION_RETRY_SECONDS;
       if(SSV5_g_exitSyncFailures>=SSV5_MAX_EXIT_SYNC_FAILURES)
         {
          if(SSV5_g_exitSyncFailures==SSV5_MAX_EXIT_SYNC_FAILURES)
             Print("XVISION SuperScalper: broker SL/TP update could not be synchronized after ",SSV5_g_exitSyncFailures,
                   " attempts; virtual management remains active and broker sync will retry for ticket=",SSV5_g_activeTicket);
           SSV5_g_exitSyncFailures=SSV5_MAX_EXIT_SYNC_FAILURES;
           SSV5_g_needExitSync=true;
           SSV5_g_activeProtectionState=SSV5_PROTECTION_FAILED;
           if(OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET,MODE_TRADES))
             {
              SSV5_g_expectedSL=OrderStopLoss();
              SSV5_g_expectedTP=OrderTakeProfit();
             }
           SSV5_g_nextExitSyncAttempt=TimeCurrent()+SSV5_FAILED_EXIT_SYNC_RETRY_SECONDS;
         }
      SSV5_PersistActiveTrade();
     }
  }

void SSV5_RecoverActiveTrade(const int ticket)
  {
   if(ticket<=0 || !OrderSelect(ticket,SELECT_BY_TICKET,MODE_TRADES)) return;
   bool matchingPersistence=((int)SSV5_ReadPersistent("Ticket",-1.0)==ticket);
   SSV5_g_activeTicket=ticket;
   SSV5_g_activeDirection=(OrderType()==OP_BUY ? 1 : -1);
   SSV5_g_state=SSV5_STATE_ACTIVE;
   SSV5_g_modelExitRequested=false;
   SSV5_g_invalidBars=(matchingPersistence ? (int)SSV5_ReadPersistent("InvalidBars",0.0) : 0);
   SSV5_g_cusumUp=(matchingPersistence ? SSV5_Clamp(SSV5_ReadPersistent("CusumUp",0.0),0.0,12.0) : 0.0);
   SSV5_g_cusumDown=(matchingPersistence ? SSV5_Clamp(SSV5_ReadPersistent("CusumDown",0.0),0.0,12.0) : 0.0);

   if(matchingPersistence)
     {
      SSV5_g_market.modeNoise=MathMax(0.0,SSV5_ReadPersistent("ModeNoise",SSV5_g_market.modeNoise));
      SSV5_g_market.modeDrift=MathMax(0.0,SSV5_ReadPersistent("ModeDrift",SSV5_g_market.modeDrift));
      SSV5_g_market.modeImpulse=MathMax(0.0,SSV5_ReadPersistent("ModeImpulse",SSV5_g_market.modeImpulse));
      SSV5_g_market.modeExhaustion=MathMax(0.0,SSV5_ReadPersistent("ModeExhaustion",SSV5_g_market.modeExhaustion));
      SSV5_g_market.modeShock=MathMax(0.0,SSV5_ReadPersistent("ModeShock",SSV5_g_market.modeShock));
      double modeTotal=SSV5_g_market.modeNoise+SSV5_g_market.modeDrift+SSV5_g_market.modeImpulse+
                       SSV5_g_market.modeExhaustion+SSV5_g_market.modeShock;
      if(modeTotal>SSV5_EPSILON)
        {
         SSV5_g_market.modeNoise/=modeTotal;
         SSV5_g_market.modeDrift/=modeTotal;
         SSV5_g_market.modeImpulse/=modeTotal;
         SSV5_g_market.modeExhaustion/=modeTotal;
         SSV5_g_market.modeShock/=modeTotal;
        }
      else
        {
         SSV5_g_market.modeNoise=0.20;
         SSV5_g_market.modeDrift=0.20;
         SSV5_g_market.modeImpulse=0.20;
         SSV5_g_market.modeExhaustion=0.20;
         SSV5_g_market.modeShock=0.20;
        }
     }
   if(SSV5_HasSufficientData())
     {
      SSV5_ComputeMarketSnapshot(false);
      SSV5_ComputeVelocitySnapshot(1);
     }
   double directedFallback=SSV5_Clamp(SSV5_g_activeDirection*SSV5_g_market.directionalLogit,-8.0,8.0);
   SSV5_g_trackLogOdds=(matchingPersistence ? SSV5_ReadPersistent("TrackLogOdds",directedFallback) : directedFallback);
   SSV5_g_activeEntryTime=(datetime)(matchingPersistence ? SSV5_ReadPersistent("EntryTime",OrderOpenTime()) : OrderOpenTime());
   SSV5_g_activeEntryP30=(matchingPersistence ? SSV5_ReadPersistent("EntryP30",0.0) : 0.0);
   SSV5_g_activeEntryExpectedTravel=(matchingPersistence ? SSV5_ReadPersistent("EntryExpected",0.0) : 0.0);
   SSV5_g_activeEntryRemainingTravel=(matchingPersistence ? SSV5_ReadPersistent("EntryRemaining",0.0) : 0.0);
   SSV5_g_activeEntryOpportunity=(matchingPersistence ? SSV5_ReadPersistent("EntryOpportunity",0.0) : 0.0);
   SSV5_g_activeRequestedPrice=(matchingPersistence ? SSV5_ReadPersistent("EntryRequested",OrderOpenPrice()) : OrderOpenPrice());
   SSV5_g_activeFillPrice=(matchingPersistence ? SSV5_ReadPersistent("EntryFill",OrderOpenPrice()) : OrderOpenPrice());
   SSV5_g_activeEntrySpread=(matchingPersistence ? MathMax(0.0,SSV5_ReadPersistent("EntrySpread",0.0)) : 0.0);
   SSV5_g_activeEntryDeviation=(matchingPersistence ? MathMax(0.0,SSV5_ReadPersistent("EntryDeviation",
                                                                          MathAbs(OrderOpenPrice()-SSV5_g_activeRequestedPrice))) : 0.0);
   double recoveryDevelopment=(SSV5_g_activeDirection>0 ? SSV5_g_trackerUp.entryDevelopmentATR : SSV5_g_trackerDown.entryDevelopmentATR);
   SSV5_g_activeEntryDevelopmentATR=(matchingPersistence ? SSV5_ReadPersistent("V41EntryDevATR",recoveryDevelopment) :
                               recoveryDevelopment);
   SSV5_g_activeEntryPathAlternation=(matchingPersistence ? SSV5_ReadPersistent("V41EntryAlt",SSV5_g_market.pathAlternationM1) :
                                SSV5_g_market.pathAlternationM1);
   SSV5_g_activeEntryWickRejection=(matchingPersistence ? SSV5_ReadPersistent("V41EntryWick",SSV5_g_market.wickRejectionM1) :
                             SSV5_g_market.wickRejectionM1);
   SSV5_g_activeEntryAccelerationPersistence=(matchingPersistence ? SSV5_ReadPersistent("V41EntryAcc",SSV5_g_market.accelerationPersistenceM1) :
                                      SSV5_g_market.accelerationPersistenceM1);
   SSV5_g_activeEntryStructuralNovelty=(matchingPersistence ? SSV5_ReadPersistent("V41EntryNovel",SSV5_g_market.structuralNovelty) :
                                  SSV5_g_market.structuralNovelty);
   SSV5_g_activeEntryResearchDrift=(matchingPersistence ? SSV5_ReadPersistent("V41EntryDrift",SSV5_g_market.researchDriftScore) :
                              SSV5_g_market.researchDriftScore);
   int defaultProtection=((OrderStopLoss()>0.0 || OrderTakeProfit()>0.0) ? SSV5_PROTECTION_SYNCED : SSV5_PROTECTION_OFF);
   SSV5_g_activeProtectionState=(matchingPersistence ? (int)SSV5_ReadPersistent("SSV5_ProtectionState",defaultProtection) : defaultProtection);
   int activeCalibrationSchema=(matchingPersistence ? (int)SSV5_ReadPersistent("CalibrationSourceSchema",0.0) : 0);
   SSV5_g_activeCalibrationBin=(matchingPersistence && activeCalibrationSchema==SSV5_CALIBRATION_SCHEMA ?
                           (int)SSV5_ReadPersistent("SSV5_CalibrationBin",-1.0) : -1);
   SSV5_g_activeMaxFavorable=(matchingPersistence ? MathMax(0.0,SSV5_ReadPersistent("MaxFavorable",0.0)) : 0.0);
   SSV5_g_activeMaxAdverse=(matchingPersistence ? MathMax(0.0,SSV5_ReadPersistent("MaxAdverse",0.0)) : 0.0);
   SSV5_g_activeCalibrationResolved=(matchingPersistence && SSV5_ReadPersistent("CalibrationResolved",0.0)>0.5);
   SSV5_g_activeCalibrationSuccess=(SSV5_g_activeCalibrationResolved && SSV5_ReadPersistent("CalibrationSuccess",0.0)>0.5);
   // Migration fallback for a trade opened by a legacy build before first-passage state
   // was persisted.  If both extremes were reached, ordering is unknowable and
   // the outcome remains censored rather than teaching a false label.
   if(matchingPersistence && !SSV5_g_activeCalibrationResolved)
     {
      bool legacyHit=(SSV5_g_activeMaxFavorable>=SSV5_CALIBRATION_TARGET_USD);
      bool legacyAdverse=(SSV5_g_activeMaxAdverse>=SSV5_CALIBRATION_ADVERSE_USD);
      if(legacyHit!=legacyAdverse)
        {
         SSV5_g_activeCalibrationResolved=true;
         SSV5_g_activeCalibrationSuccess=legacyHit;
        }
     }
   SSV5_g_activeHorizonMinutes=(matchingPersistence ? SSV5_ReadPersistent("EntryHorizon",SSV5_g_market.horizonMinutes) : SSV5_g_market.horizonMinutes);
   SSV5_g_modelExitReason="";
   double persistedPeak=(matchingPersistence ? SSV5_ReadPersistent("Peak",OrderOpenPrice()) : OrderOpenPrice());
   if(SSV5_g_activeDirection>0) SSV5_g_favorableExtreme=MathMax(OrderOpenPrice(),MathMax(persistedPeak,Bid));
   else SSV5_g_favorableExtreme=MathMin(OrderOpenPrice(),MathMin(persistedPeak,Ask));
   SSV5_g_exitSyncFailures=0;
   SSV5_g_nextExitSyncAttempt=0;
   SSV5_g_nextCloseAttempt=0;

   if(SSV5_g_reconfiguredInputs)
     {
      SSV5_g_manualSLOverride=false;
      SSV5_g_manualTPOverride=false;
      SSV5_g_expectedSL=OrderStopLoss();
      SSV5_g_expectedTP=OrderTakeProfit();
      SSV5_g_needExitSync=true;
     }
   else
     {
      SSV5_g_expectedSL=(matchingPersistence ? SSV5_ReadPersistent("ExpectedSL",OrderStopLoss()) : OrderStopLoss());
      SSV5_g_expectedTP=(matchingPersistence ? SSV5_ReadPersistent("ExpectedTP",OrderTakeProfit()) : OrderTakeProfit());
      SSV5_g_manualSLOverride=(matchingPersistence ? SSV5_ReadPersistent("ManualSL",0.0)>0.5 :
                          OrderStopLoss()>0.0);
      SSV5_g_manualTPOverride=(matchingPersistence ? SSV5_ReadPersistent("ManualTP",0.0)>0.5 :
                          OrderTakeProfit()>0.0);
      SSV5_g_needExitSync=(matchingPersistence && SSV5_ReadPersistent("NeedExitSync",0.0)>0.5);
     }
   double desiredSL=0.0,desiredTP=0.0;
   SSV5_CalculateInputStops(OrderType(),OrderOpenPrice(),desiredSL,desiredTP);
   if(!SSV5_g_manualSLOverride && !SSV5_SamePrice(OrderStopLoss(),desiredSL)) SSV5_g_needExitSync=true;
   if(!SSV5_g_manualTPOverride && !SSV5_SamePrice(OrderTakeProfit(),desiredTP)) SSV5_g_needExitSync=true;
   if(SSV5_g_manualSLOverride || SSV5_g_manualTPOverride)
      SSV5_g_activeProtectionState=SSV5_PROTECTION_MANUAL;
   SSV5_AdoptRecoveredTradeIntoThesis(SSV5_g_activeDirection);
   SSV5_PersistActiveTrade();
  }

void SSV5_AppendTelemetry(const string eventName,const string reason,const string resolvedCalibrationStatus="")
  {
   string fileName="XVISION_Gold_SuperScalper_v5_telemetry.csv";
   int handle=FileOpen(fileName,FILE_CSV|FILE_READ|FILE_WRITE|FILE_SHARE_READ,',');
   if(handle==INVALID_HANDLE)
     {
      Print("XVISION SuperScalper V5.00: telemetry open failed error=",GetLastError());
      return;
     }
   if(FileSize(handle)==0)
      FileWrite(handle,"event_time","event","ticket","direction","reason","entry_time","entry_price",
                "entry_spread_price","requested_price","fill_price","entry_deviation_price","protection_status",
                "calibration_bin","calibration_status",
                "entry_development_atr","entry_development_state","entry_path_alternation",
                "entry_wick_rejection","entry_acceleration_persistence","entry_structural_novelty",
                "entry_research_drift","entry_research_health","current_research_drift",
                "current_research_health","prediction_error_ewma","resolved_production_samples",
                "entry_p30","expected_travel","remaining_travel","opportunity_score","max_favorable",
                "max_adverse","track_log_odds","invalid_bars","entries_today","thesis_direction",
                "thesis_entries","thesis_phase","thesis_start_bar","continuation_reference",
                "continuation_opportunity_floor");
   FileSeek(handle,0,SEEK_END);
   double entryPrice=0.0;
   if(SSV5_g_activeTicket>0 && OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET)) entryPrice=OrderOpenPrice();
   string calibrationStatus=resolvedCalibrationStatus;
   if(calibrationStatus=="")
      calibrationStatus=(eventName=="ENTRY" ? "PENDING" :
                         (SSV5_g_activeCalibrationResolved ? (SSV5_g_activeCalibrationSuccess ? "HIT30" : "MISS15") : "CENSORED"));
   FileWrite(handle,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),eventName,SSV5_g_activeTicket,
              SSV5_DirectionName(SSV5_g_activeDirection),reason,TimeToString(SSV5_g_activeEntryTime,TIME_DATE|TIME_SECONDS),
              DoubleToString(entryPrice,Digits),DoubleToString(SSV5_g_activeEntrySpread,Digits),
              DoubleToString(SSV5_g_activeRequestedPrice,Digits),DoubleToString(SSV5_g_activeFillPrice,Digits),
              DoubleToString(SSV5_g_activeEntryDeviation,Digits),SSV5_ProtectionStateName(SSV5_g_activeProtectionState),
              SSV5_g_activeCalibrationBin,calibrationStatus,
              DoubleToString(SSV5_g_activeEntryDevelopmentATR,6),SSV5_EntryDevelopmentName(SSV5_g_activeEntryDevelopmentATR),
              DoubleToString(SSV5_g_activeEntryPathAlternation,6),DoubleToString(SSV5_g_activeEntryWickRejection,6),
              DoubleToString(SSV5_g_activeEntryAccelerationPersistence,6),DoubleToString(SSV5_g_activeEntryStructuralNovelty,6),
              DoubleToString(SSV5_g_activeEntryResearchDrift,6),SSV5_ResearchDriftName(SSV5_g_activeEntryResearchDrift),
              DoubleToString(SSV5_g_market.researchDriftScore,6),SSV5_ResearchDriftName(SSV5_g_market.researchDriftScore),
              DoubleToString(SSV5_g_researchPredictionErrorEWMA,6),SSV5_g_researchResolvedProduction,
              DoubleToString(SSV5_g_activeEntryP30,4),
             DoubleToString(SSV5_g_activeEntryExpectedTravel,2),DoubleToString(SSV5_g_activeEntryRemainingTravel,2),
             DoubleToString(SSV5_g_activeEntryOpportunity,4),DoubleToString(SSV5_g_activeMaxFavorable,2),
             DoubleToString(SSV5_g_activeMaxAdverse,2),DoubleToString(SSV5_g_trackLogOdds,4),SSV5_g_invalidBars,SSV5_EntriesToday(),
             SSV5_DirectionName(SSV5_g_thesisDirection),SSV5_g_thesisEntries,SSV5_ThesisPhaseName(),
             TimeToString(SSV5_g_thesisStartBar,TIME_DATE|TIME_MINUTES),
             DoubleToString(SSV5_g_continuationReference,Digits),
             DoubleToString(SSV5_g_continuationOpportunityFloor,6));
   FileClose(handle);
  }

void AppendResearchEvent(const string eventName,const SSV5_ResearchTrack &track,
                         const string outcome,const double exitPrice)
  {
   string fileName="XVISION_Gold_SuperScalper_v5_research.csv";
   int handle=FileOpen(fileName,FILE_CSV|FILE_READ|FILE_WRITE|FILE_SHARE_READ,',');
   if(handle==INVALID_HANDLE)
     {
      Print("XVISION SuperScalper V5.00: research ledger open failed error=",GetLastError());
      return;
     }
   if(FileSize(handle)==0)
      FileWrite(handle,"event_time","event","signal_id","source","direction","block_reason",
                "start_time","entry_price","exit_price","outcome","age_minutes","horizon_minutes",
                "max_favorable","max_adverse","entry_p30","opportunity_score","remaining_travel",
                "exhaustion_risk","development_atr","development_state","path_alternation",
                "wick_rejection","acceleration_persistence","structural_novelty","research_drift",
                "research_health","prediction_error_ewma","resolved_production_samples");
   FileSeek(handle,0,SEEK_END);
   double ageMinutes=(track.startTime>0 ? MathMax(0.0,(TimeCurrent()-track.startTime)/60.0) : 0.0);
   FileWrite(handle,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),eventName,
             DoubleToString((double)track.signalId,0),SSV5_ResearchSourceName(track.source),
             SSV5_DirectionName(track.direction),SSV5_ResearchBlockName(track.blockCode),
             TimeToString(track.startTime,TIME_DATE|TIME_SECONDS),DoubleToString(track.entryPrice,Digits),
             DoubleToString(exitPrice,Digits),outcome,DoubleToString(ageMinutes,2),
             DoubleToString(track.horizonMinutes,2),DoubleToString(track.maxFavorable,2),
             DoubleToString(track.maxAdverse,2),DoubleToString(track.entryP30,6),
             DoubleToString(track.opportunityScore,6),DoubleToString(track.remainingTravel,2),
             DoubleToString(track.exhaustionRisk,6),DoubleToString(track.developmentATR,6),
             SSV5_EntryDevelopmentName(track.developmentATR),DoubleToString(track.pathAlternation,6),
             DoubleToString(track.wickRejection,6),DoubleToString(track.accelerationPersistence,6),
             DoubleToString(track.structuralNovelty,6),DoubleToString(track.driftScore,6),
             SSV5_ResearchDriftName(track.driftScore),DoubleToString(SSV5_g_researchPredictionErrorEWMA,6),
             SSV5_g_researchResolvedProduction);
   FileClose(handle);
  }

int SSV5_ResearchSlotFor(const int source,const int direction)
  {
   if(source==SSV5_RESEARCH_QUALIFIED) return(direction>0 ? 0 : 1);
   if(source==SSV5_RESEARCH_REJECTED)  return(direction>0 ? 2 : 3);
   return(-1);
  }

bool StartResearchTrack(const int source,const int direction,const int blockCode,
                        const double entryPrice,const long signalId)
  {
   int slot=SSV5_ResearchSlotFor(source,direction);
   if(slot<0 || slot>=SSV5_RESEARCH_TRACK_SLOTS || entryPrice<=0.0) return(false);
   if(SSV5_g_researchTracks[slot].active) return(false);
   SSV5_ResearchTrack track;
   SSV5_ClearResearchTrack(track);
   track.active=true;
   track.signalId=signalId;
   track.source=source;
   track.direction=direction;
   track.blockCode=blockCode;
   track.startTime=TimeCurrent();
   track.entryPrice=entryPrice;
   track.horizonMinutes=SSV5_Clamp(SSV5_g_market.horizonMinutes,60.0,180.0);
   track.entryP30=SSV5_Probability30(direction);
   track.opportunityScore=SSV5_OpportunityScore(direction);
   track.remainingTravel=SSV5_RemainingTravel(direction);
   track.exhaustionRisk=(direction>0 ? SSV5_g_trackerUp.exhaustionRisk : SSV5_g_trackerDown.exhaustionRisk);
   track.developmentATR=(direction>0 ? SSV5_g_trackerUp.entryDevelopmentATR : SSV5_g_trackerDown.entryDevelopmentATR);
   track.pathAlternation=SSV5_g_market.pathAlternationM1;
   track.wickRejection=SSV5_g_market.wickRejectionM1;
   track.accelerationPersistence=SSV5_g_market.accelerationPersistenceM1;
   track.structuralNovelty=SSV5_g_market.structuralNovelty;
   track.driftScore=SSV5_g_market.researchDriftScore;
   SSV5_g_researchTracks[slot]=track;
   AppendResearchEvent("OPEN",SSV5_g_researchTracks[slot],"ACTIVE",0.0);
   SSV5_PersistResearchLayer();
   return(true);
  }

void SSV5_StartQualifiedResearchTrack(const int ticket,const int direction,const double entryPrice)
  {
   StartResearchTrack(SSV5_RESEARCH_QUALIFIED,direction,SSV5_RESEARCH_BLOCK_NONE,
                      entryPrice,(long)ticket);
  }

void SSV5_CloseResearchTrack(const int slot,const string outcome,const double exitPrice)
  {
   if(slot<0 || slot>=SSV5_RESEARCH_TRACK_SLOTS || !SSV5_g_researchTracks[slot].active) return;
   AppendResearchEvent("CLOSE",SSV5_g_researchTracks[slot],outcome,exitPrice);
   SSV5_ClearResearchTrack(SSV5_g_researchTracks[slot]);
   SSV5_DeleteResearchTrackPersistence(slot);
   GlobalVariablesFlush();
  }

void CloseQualifiedResearchTrackForTicket(const int ticket,const string outcome,
                                          const double exitPrice)
  {
   if(ticket<=0) return;
   for(int slot=0;slot<SSV5_RESEARCH_TRACK_SLOTS;slot++)
     {
      if(!SSV5_g_researchTracks[slot].active) continue;
      if(SSV5_g_researchTracks[slot].source!=SSV5_RESEARCH_QUALIFIED) continue;
      if(SSV5_g_researchTracks[slot].signalId!=(long)ticket) continue;
      SSV5_CloseResearchTrack(slot,outcome,exitPrice);
      return;
     }
  }

void SSV5_ReconcileRecoveredQualifiedResearch()
  {
   for(int slot=0;slot<SSV5_RESEARCH_TRACK_SLOTS;slot++)
     {
      if(!SSV5_g_researchTracks[slot].active) continue;
      if(SSV5_g_researchTracks[slot].source!=SSV5_RESEARCH_QUALIFIED) continue;
      int ticket=(int)SSV5_g_researchTracks[slot].signalId;
      if(ticket<=0 || !OrderSelect(ticket,SELECT_BY_TICKET)) continue;
      if(OrderCloseTime()<=0) continue;
      SSV5_CloseResearchTrack(slot,"CENSORED_RESTART_CLOSE",OrderClosePrice());
     }
  }

void SSV5_UpdateResearchLayer()
  {
   bool hasActive=false;
   for(int slot=0;slot<SSV5_RESEARCH_TRACK_SLOTS;slot++)
     {
      if(!SSV5_g_researchTracks[slot].active) continue;
      hasActive=true;
      int direction=SSV5_g_researchTracks[slot].direction;
      double executable=(direction>0 ? Bid : Ask);
      if(executable<=0.0) continue;
      double favorable=direction*(executable-SSV5_g_researchTracks[slot].entryPrice);
      double adverse=-favorable;
      SSV5_g_researchTracks[slot].maxFavorable=MathMax(SSV5_g_researchTracks[slot].maxFavorable,
                                                  MathMax(0.0,favorable));
      SSV5_g_researchTracks[slot].maxAdverse=MathMax(SSV5_g_researchTracks[slot].maxAdverse,
                                                MathMax(0.0,adverse));
      if(favorable>=SSV5_CALIBRATION_TARGET_USD)
        {
         double boundary=SSV5_g_researchTracks[slot].entryPrice+direction*SSV5_CALIBRATION_TARGET_USD;
         SSV5_CloseResearchTrack(slot,"HIT30",boundary);
         continue;
        }
      if(adverse>=SSV5_CALIBRATION_ADVERSE_USD)
        {
         double boundary=SSV5_g_researchTracks[slot].entryPrice-direction*SSV5_CALIBRATION_ADVERSE_USD;
         SSV5_CloseResearchTrack(slot,"MISS15",boundary);
         continue;
        }
      double ageMinutes=MathMax(0.0,(TimeCurrent()-SSV5_g_researchTracks[slot].startTime)/60.0);
      if(ageMinutes>=SSV5_g_researchTracks[slot].horizonMinutes)
        {
         SSV5_CloseResearchTrack(slot,"CENSORED",executable);
         continue;
        }
     }
   if(hasActive && (SSV5_g_lastResearchPersist<=0 || TimeCurrent()-SSV5_g_lastResearchPersist>=30))
      SSV5_PersistResearchLayer();
  }

void SSV5_UpdateResearchPredictionError(const bool success,const double predictedP30)
  {
   double realized=(success ? 1.0 : 0.0);
   double error=MathAbs(realized-SSV5_Clamp(predictedP30,0.0,1.0));
   if(SSV5_g_researchResolvedProduction<=0) SSV5_g_researchPredictionErrorEWMA=error;
   else SSV5_g_researchPredictionErrorEWMA=0.90*SSV5_g_researchPredictionErrorEWMA+0.10*error;
   SSV5_g_researchResolvedProduction++;
   SSV5_WritePersistent("V41PredError",SSV5_g_researchPredictionErrorEWMA);
   SSV5_WritePersistent("V41Resolved",SSV5_g_researchResolvedProduction);
   GlobalVariablesFlush();
  }

//+------------------------------------------------------------------+
//| Acquisition state machine                                        |
//+------------------------------------------------------------------+
double SSV5_RecentMovementAnchor(const int direction,const int bars)
  {
   if(direction>0)
     {
      double lowest=iLow(Symbol(),PERIOD_M1,1);
      for(int shift=2;shift<=bars;shift++) lowest=MathMin(lowest,iLow(Symbol(),PERIOD_M1,shift));
      return(lowest);
     }
   double highest=iHigh(Symbol(),PERIOD_M1,1);
   for(int index=2;index<=bars;index++) highest=MathMax(highest,iHigh(Symbol(),PERIOD_M1,index));
   return(highest);
  }

double SSV5_DirectionalCUSUM(const int direction)
  {
   return(direction>0 ? SSV5_g_cusumUp : SSV5_g_cusumDown);
  }

double SSV5_OpposingCUSUM(const int direction)
  {
   return(direction>0 ? SSV5_g_cusumDown : SSV5_g_cusumUp);
  }

double SSV5_Probability30(const int direction)
  {
   return(direction>0 ? SSV5_g_trackerUp.calibratedP30 : SSV5_g_trackerDown.calibratedP30);
  }

double SSV5_RemainingTravel(const int direction)
  {
   return(direction>0 ? SSV5_g_trackerUp.remainingTravel : SSV5_g_trackerDown.remainingTravel);
  }

double SSV5_ExpectedTravel(const int direction)
  {
   return(direction>0 ? SSV5_g_trackerUp.expectedTravel : SSV5_g_trackerDown.expectedTravel);
  }

double SSV5_OpportunityScore(const int direction)
  {
   return(direction>0 ? SSV5_g_trackerUp.opportunityScore : SSV5_g_trackerDown.opportunityScore);
  }

double SSV5_TrackerEvidence(const int direction)
  {
   return(direction>0 ? SSV5_g_trackerUp.evidenceLogOdds : SSV5_g_trackerDown.evidenceLogOdds);
  }

string SSV5_ThesisPhaseName()
  {
   if(SSV5_g_thesisDirection==0) return("DISARMED");
   if(SSV5_g_thesisLocked || SSV5_g_thesisEntries>=SSV5_MAX_ENTRIES_PER_THESIS) return("RESET_REQUIRED");
   if(SSV5_g_continuationAuthorized) return("CONTINUATION_ARMED");
   if(SSV5_g_continuationPending) return("EXTENSION_REQUIRED");
   if(SSV5_g_thesisEntries<=0) return("INITIAL_ENTRY");
   return("ACTIVE_ENTRY");
  }

void SSV5_DeleteThesisPersistence()
  {
   SSV5_DeletePersistent("V42ThesisSchema");
   SSV5_DeletePersistent("V42ThesisDirection");
   SSV5_DeletePersistent("V42ThesisEntries");
   SSV5_DeletePersistent("V42ThesisResetBars");
   SSV5_DeletePersistent("V42ThesisStartBar");
   SSV5_DeletePersistent("V42ThesisLocked");
   SSV5_DeletePersistent("V42ContinuationPending");
   SSV5_DeletePersistent("V42ContinuationAuthorized");
   SSV5_DeletePersistent("V42ContinuationReference");
   SSV5_DeletePersistent("V42ContinuationOpportunity");
  }

void SSV5_PersistThesisState()
  {
   if(!SSV5_g_instanceLeaseHeld) return;
   SSV5_WritePersistent("V42ThesisSchema",SSV5_THESIS_SCHEMA);
   SSV5_WritePersistent("V42ThesisDirection",SSV5_g_thesisDirection);
   SSV5_WritePersistent("V42ThesisEntries",SSV5_g_thesisEntries);
   SSV5_WritePersistent("V42ThesisResetBars",SSV5_g_thesisResetBars);
   SSV5_WritePersistent("V42ThesisStartBar",(double)SSV5_g_thesisStartBar);
   SSV5_WritePersistent("V42ThesisLocked",SSV5_g_thesisLocked ? 1.0 : 0.0);
   SSV5_WritePersistent("V42ContinuationPending",SSV5_g_continuationPending ? 1.0 : 0.0);
   SSV5_WritePersistent("V42ContinuationAuthorized",SSV5_g_continuationAuthorized ? 1.0 : 0.0);
   SSV5_WritePersistent("V42ContinuationReference",SSV5_g_continuationReference);
   SSV5_WritePersistent("V42ContinuationOpportunity",SSV5_g_continuationOpportunityFloor);
   GlobalVariablesFlush();
  }

void SSV5_ClearThesisState()
  {
   SSV5_g_thesisDirection=0;
   SSV5_g_thesisEntries=0;
   SSV5_g_thesisResetBars=0;
   SSV5_g_thesisStartBar=0;
   SSV5_g_thesisLocked=false;
   SSV5_g_continuationPending=false;
   SSV5_g_continuationAuthorized=false;
   SSV5_g_thesisMigrationBootstrap=false;
   SSV5_g_continuationReference=0.0;
   SSV5_g_continuationOpportunityFloor=0.0;
   SSV5_g_thesisBlockReason="";
   SSV5_PersistThesisState();
  }

void SSV5_BeginNewThesis(const int direction)
  {
   if(MathAbs(direction)!=1) return;
   SSV5_g_thesisDirection=direction;
   SSV5_g_thesisEntries=0;
   SSV5_g_thesisResetBars=0;
   SSV5_g_thesisStartBar=iTime(Symbol(),PERIOD_M1,1);
   SSV5_g_thesisLocked=false;
   SSV5_g_continuationPending=false;
   SSV5_g_continuationAuthorized=false;
   SSV5_g_thesisMigrationBootstrap=false;
   SSV5_g_continuationReference=0.0;
   SSV5_g_continuationOpportunityFloor=0.0;
   SSV5_g_thesisBlockReason="";
   SSV5_PersistThesisState();
   Print("XVISION SuperScalper V5.00: new structural thesis direction=",SSV5_DirectionName(direction),
         " startBar=",TimeToString(SSV5_g_thesisStartBar,TIME_DATE|TIME_MINUTES));
  }

void SSV5_InitializeThesisState()
  {
   int storedSchema=(int)SSV5_ReadPersistent("V42ThesisSchema",0.0);
   if(storedSchema!=SSV5_THESIS_SCHEMA)
     {
      // This EA has its own persistence namespace.  A missing or older schema
      // is a fresh SuperScalper installation, not a GoldSeek migration.  Start
      // disarmed so SSV5_UpdateThesisRearmState() can adopt the current valid setup.
      SSV5_DeleteThesisPersistence();
      SSV5_ClearThesisState();
      return;
     }
   SSV5_g_thesisMigrationBootstrap=false;
   SSV5_g_thesisDirection=(int)SSV5_ReadPersistent("V42ThesisDirection",0.0);
   SSV5_g_thesisEntries=(int)SSV5_ReadPersistent("V42ThesisEntries",0.0);
   SSV5_g_thesisResetBars=(int)SSV5_ReadPersistent("V42ThesisResetBars",0.0);
   SSV5_g_thesisStartBar=(datetime)SSV5_ReadPersistent("V42ThesisStartBar",0.0);
   SSV5_g_thesisLocked=(SSV5_ReadPersistent("V42ThesisLocked",0.0)>0.5);
   SSV5_g_continuationPending=(SSV5_ReadPersistent("V42ContinuationPending",0.0)>0.5);
   SSV5_g_continuationAuthorized=(SSV5_ReadPersistent("V42ContinuationAuthorized",0.0)>0.5);
   SSV5_g_continuationReference=SSV5_ReadPersistent("V42ContinuationReference",0.0);
   SSV5_g_continuationOpportunityFloor=SSV5_ReadPersistent("V42ContinuationOpportunity",0.0);
   bool valid=(MathAbs(SSV5_g_thesisDirection)==1 && SSV5_g_thesisEntries>=0 &&
               SSV5_g_thesisEntries<=SSV5_MAX_ENTRIES_PER_THESIS && SSV5_g_thesisStartBar>0);
   if(!valid) SSV5_ClearThesisState();
  }

void SSV5_AdoptRecoveredTradeIntoThesis(const int direction)
  {
   if(MathAbs(direction)!=1) return;
   if(SSV5_g_thesisMigrationBootstrap || SSV5_g_thesisDirection!=direction)
     {
      SSV5_BeginNewThesis(direction);
      SSV5_g_thesisMigrationBootstrap=false;
     }
   SSV5_g_thesisEntries=MathMax(1,SSV5_g_thesisEntries);
   SSV5_g_continuationPending=false;
   SSV5_g_continuationAuthorized=false;
   SSV5_PersistThesisState();
  }

bool SSV5_ThesisEntryPermitted(const int direction,string &blocker)
  {
   blocker="";
   if(MathAbs(direction)!=1) { blocker="NO STRUCTURAL THESIS"; return(false); }
   if(SSV5_g_thesisDirection!=direction)
     {
      blocker="WAITING FOR NEW THESIS";
      return(false);
     }
   if(SSV5_g_thesisEntries<=0) return(true);
   if(SSV5_g_thesisLocked || SSV5_g_thesisEntries>=SSV5_MAX_ENTRIES_PER_THESIS)
     {
      blocker="THESIS MUST RESET";
      return(false);
     }
   if(SSV5_g_continuationAuthorized) return(true);
   blocker=(SSV5_g_continuationPending ? "CONTINUATION MUST EXTEND" :
                                      "CONTINUATION NOT ARMED");
   return(false);
  }

void SSV5_RecordThesisEntry(const int direction)
  {
   if(SSV5_g_thesisDirection!=direction) SSV5_BeginNewThesis(direction);
   SSV5_g_thesisEntries=MathMin(SSV5_MAX_ENTRIES_PER_THESIS,SSV5_g_thesisEntries+1);
   SSV5_g_thesisResetBars=0;
   SSV5_g_continuationPending=false;
   SSV5_g_continuationAuthorized=false;
   SSV5_g_thesisLocked=(SSV5_g_thesisEntries>=SSV5_MAX_ENTRIES_PER_THESIS);
   SSV5_PersistThesisState();
  }

void RegisterThesisClose(const int direction,const double grossCapture,
                         const double closePrice,const string modelReason)
  {
   if(SSV5_g_thesisDirection!=direction)
     {
      SSV5_BeginNewThesis(direction);
      SSV5_g_thesisEntries=1;
     }
   bool failed=(grossCapture<=0.0 ||
                (modelReason!="" && !SSV5_IsConfiguredProfitExitReason(modelReason)));
   SSV5_g_continuationAuthorized=false;
   SSV5_g_thesisResetBars=0;
   if(failed || SSV5_g_thesisEntries>=SSV5_MAX_ENTRIES_PER_THESIS)
     {
      SSV5_g_thesisLocked=true;
      SSV5_g_continuationPending=false;
      SSV5_g_continuationReference=0.0;
      SSV5_g_continuationOpportunityFloor=0.0;
     }
   else
     {
      SSV5_g_thesisLocked=false;
      SSV5_g_continuationPending=true;
      SSV5_g_continuationReference=closePrice;
      SSV5_g_continuationOpportunityFloor=MathMax(SSV5_MIN_OPPORTUNITY_SCORE,
                                              SSV5_OpportunityScore(direction));
     }
   SSV5_PersistThesisState();
   Print("XVISION SuperScalper V5.00: thesis close direction=",SSV5_DirectionName(direction),
         " entry=",SSV5_g_thesisEntries,"/",SSV5_MAX_ENTRIES_PER_THESIS,
         " capture=",DoubleToString(grossCapture,2)," phase=",SSV5_ThesisPhaseName());
  }

void SSV5_UpdateThesisRearmState()
  {
   if(SSV5_g_state==SSV5_STATE_ACTIVE || SSV5_g_state==SSV5_STATE_EXITING) return;
   int currentDirection=SSV5_g_market.structuralDirection;
   bool currentReady=SSV5_M5StructuralReady(currentDirection,SSV5_MIN_STRUCTURAL_ONSET_SCORE);

   if(SSV5_g_thesisDirection==0)
     {
      if(currentReady) SSV5_BeginNewThesis(currentDirection);
      return;
     }

   bool oppositeReady=(currentReady && currentDirection!=SSV5_g_thesisDirection);
   if(oppositeReady)
     {
      SSV5_BeginNewThesis(currentDirection);
      if(SSV5_g_state==SSV5_STATE_CANDIDATE || SSV5_g_state==SSV5_STATE_ACQUIRED) SSV5_ReturnToSearch();
      return;
     }

   bool originalReady=SSV5_M5StructuralReady(SSV5_g_thesisDirection,SSV5_MIN_STRUCTURAL_ONSET_SCORE);
   if(!originalReady)
     {
      SSV5_g_thesisResetBars++;
      if(SSV5_g_thesisResetBars>=SSV5_THESIS_RESET_CLOSED_BARS)
        {
         Print("XVISION SuperScalper V5.00: prior thesis structurally disarmed direction=",
               SSV5_DirectionName(SSV5_g_thesisDirection));
         SSV5_ClearThesisState();
         if(SSV5_g_state==SSV5_STATE_CANDIDATE || SSV5_g_state==SSV5_STATE_ACQUIRED) SSV5_ReturnToSearch();
        }
      else SSV5_PersistThesisState();
      return;
     }

   if(SSV5_g_thesisResetBars!=0)
     {
      SSV5_g_thesisResetBars=0;
      SSV5_PersistThesisState();
     }

   if(!SSV5_g_continuationPending || SSV5_g_thesisLocked ||
      SSV5_g_thesisEntries>=SSV5_MAX_ENTRIES_PER_THESIS) return;
   double closedPrice=iClose(Symbol(),PERIOD_M1,1);
   double requiredExtension=SSV5_CONTINUATION_EXTENSION_M5_ATR*MathMax(SSV5_g_market.atrM5,Point);
   double extension=SSV5_g_thesisDirection*(closedPrice-SSV5_g_continuationReference);
   double currentOpportunity=SSV5_OpportunityScore(SSV5_g_thesisDirection);
   bool opportunityHeld=(currentOpportunity+SSV5_CONTINUATION_OPPORTUNITY_TOLERANCE>=
                         SSV5_g_continuationOpportunityFloor);
   bool liveEvidenceHeld=(SSV5_TrackerEvidence(SSV5_g_thesisDirection)>=-0.05);
   bool healthHeld=(SSV5_g_market.researchDriftScore<SSV5_MAX_CONTINUATION_RESEARCH_DRIFT);
   if(extension>=requiredExtension && opportunityHeld && liveEvidenceHeld && healthHeld)
     {
      SSV5_g_continuationAuthorized=true;
      SSV5_g_continuationPending=false;
      SSV5_PersistThesisState();
      Print("XVISION SuperScalper V5.00: continuation armed direction=",SSV5_DirectionName(SSV5_g_thesisDirection),
            " extension=",DoubleToString(extension,2),
            " required=",DoubleToString(requiredExtension,2),
            " opportunity=",DoubleToString(currentOpportunity,3));
     }
  }

void SSV5_ReturnToSearch()
  {
   // V4.2 preserves market evidence but separately requires thesis rearming.
   SSV5_g_state=SSV5_STATE_SEARCH;
   SSV5_g_candidateDirection=0;
   SSV5_g_candidateBars=0;
   SSV5_g_candidateAnchor=0.0;
   SSV5_g_acquiredSignalBar=0;
   SSV5_g_acquiredEntryMode=SSV5_SS_ENTRY_NONE;
   SSV5_g_nextOrderAttempt=0;
  }

int SSV5_VelocityEntryMode(const int direction)
  {
   if(!SSV5_g_velocity.valid || SSV5_g_velocity.direction!=direction || !SSV5_g_velocity.m5Ready)
      return(SSV5_SS_ENTRY_NONE);
   if(SSV5_g_velocity.qualified) return(SSV5_SS_ENTRY_CONFIRMED);
   double exhaustion=(direction>0 ? SSV5_g_trackerUp.exhaustionRisk : SSV5_g_trackerDown.exhaustionRisk);
   bool elite=(direction*SSV5_g_market.structuralScore>=SSV5_EliteStructuralScore &&
               SSV5_OpportunityScore(direction)>=SSV5_EliteOpportunityScore &&
               exhaustion<=SSV5_EliteMaximumExhaustionRisk &&
               SSV5_g_velocity.m1NonHostile);
   return(elite ? SSV5_SS_ENTRY_ELITE : SSV5_SS_ENTRY_NONE);
  }

string SSV5_EntryModeName(const int mode)
  {
   if(mode==SSV5_SS_ENTRY_ELITE) return("ELITE");
   if(mode==SSV5_SS_ENTRY_CONFIRMED) return("CONFIRMED");
   return("NONE");
  }

bool SSV5_AcquisitionEvidenceReady(const int direction)
  {
   if(!SSV5_M5StructuralReady(direction,SSV5_STRUCTURAL_SCORE_THRESHOLD)) return(false);
   if(SSV5_RemainingTravel(direction)<SSV5_MIN_REMAINING_TRAVEL_USD) return(false);
   if(SSV5_OpportunityScore(direction)<SSV5_MIN_OPPORTUNITY_SCORE) return(false);
   // Strong live contradiction vetoes an immediate re-entry after a model
   // invalidation.  Positive M1 confirmation is never required.
   if(SSV5_TrackerEvidence(direction)<-0.35) return(false);
   if((direction>0 ? SSV5_g_trackerUp.exhaustionRisk : SSV5_g_trackerDown.exhaustionRisk)>SSV5_MAX_ENTRY_EXHAUSTION_RISK) return(false);
   if(SSV5_g_market.modeShock>0.70 && direction*SSV5_g_market.structuralScore<SSV5_STRUCTURAL_SCORE_THRESHOLD+0.45) return(false);
   if(SSV5_VelocityEntryMode(direction)==SSV5_SS_ENTRY_NONE) return(false);
   string thesisBlocker="";
   if(!SSV5_ThesisEntryPermitted(direction,thesisBlocker))
     {
      SSV5_g_thesisBlockReason=thesisBlocker;
      return(false);
     }
   SSV5_g_thesisBlockReason="";
   return(true);
  }

int SSV5_ResearchAcquisitionBlockCode(const int direction)
  {
   // This mirrors the production gates for attribution only.  Production
   // continues to call SSV5_AcquisitionEvidenceReady() exactly as in V4.
   if(!SSV5_M5StructuralReady(direction,SSV5_STRUCTURAL_SCORE_THRESHOLD)) return(SSV5_RESEARCH_BLOCK_STRUCTURE);
   if(SSV5_RemainingTravel(direction)<SSV5_MIN_REMAINING_TRAVEL_USD) return(SSV5_RESEARCH_BLOCK_REMAINING);
   if(SSV5_OpportunityScore(direction)<SSV5_MIN_OPPORTUNITY_SCORE) return(SSV5_RESEARCH_BLOCK_OPPORTUNITY);
   if(SSV5_TrackerEvidence(direction)<-0.35) return(SSV5_RESEARCH_BLOCK_CONTRADICTION);
   if((direction>0 ? SSV5_g_trackerUp.exhaustionRisk : SSV5_g_trackerDown.exhaustionRisk)>
      SSV5_MAX_ENTRY_EXHAUSTION_RISK) return(SSV5_RESEARCH_BLOCK_EXHAUSTION);
   if(SSV5_g_market.modeShock>0.70 &&
      direction*SSV5_g_market.structuralScore<SSV5_STRUCTURAL_SCORE_THRESHOLD+0.45)
      return(SSV5_RESEARCH_BLOCK_SHOCK);
   if(SSV5_VelocityEntryMode(direction)==SSV5_SS_ENTRY_NONE) return(SSV5_RESEARCH_BLOCK_VELOCITY);
   return(SSV5_RESEARCH_BLOCK_NONE);
  }

void SSV5_ObserveRejectedResearchOpportunity()
  {
   if(SSV5_g_state==SSV5_STATE_ACTIVE || SSV5_g_state==SSV5_STATE_EXITING || SSV5_g_activeTicket>0) return;
   if(SSV5_HasOpenStrategyPositionOnSymbol()) return;
   int direction=SSV5_g_market.structuralDirection;
   if(!SSV5_M5StructuralReady(direction,SSV5_MIN_STRUCTURAL_ONSET_SCORE)) return;
   int blockCode=SSV5_ResearchAcquisitionBlockCode(direction);
   if(blockCode==SSV5_RESEARCH_BLOCK_NONE) return;
   double entryPrice=(direction>0 ? Ask : Bid);
   datetime closedBar=iTime(Symbol(),PERIOD_M1,1);
   long signalId=(long)closedBar*10+(direction>0 ? 1 : 2);
   StartResearchTrack(SSV5_RESEARCH_REJECTED,direction,blockCode,entryPrice,signalId);
  }

void SSV5_AdvanceAcquisitionState()
  {
   if(SSV5_g_state==SSV5_STATE_ACTIVE || SSV5_g_state==SSV5_STATE_EXITING) return;
   if(SSV5_HasOpenStrategyPositionOnSymbol()) return;

   // M5 structure chooses the current buy or sell direction symmetrically.
   // The former score fallback could never pass the structural gate below.
   int direction=SSV5_g_market.structuralDirection;

   if(SSV5_g_state==SSV5_STATE_SEARCH)
     {
       if(!SSV5_M5StructuralReady(direction,SSV5_MIN_STRUCTURAL_ONSET_SCORE)) return;
       SSV5_g_candidateDirection=direction;
       SSV5_g_candidateAnchor=SSV5_RecentMovementAnchor(direction,12);
       SSV5_g_candidateBars=0;
       SSV5_g_state=SSV5_STATE_CANDIDATE;
        if(SSV5_AcquisitionEvidenceReady(direction))
          {
           SSV5_g_acquiredEntryMode=SSV5_VelocityEntryMode(direction);
           SSV5_g_state=SSV5_STATE_ACQUIRED;
          SSV5_g_acquiredSignalBar=iTime(Symbol(),PERIOD_M1,1);
          SSV5_g_nextOrderAttempt=0;
         }
       return;
      }

   if(SSV5_g_state!=SSV5_STATE_CANDIDATE) return;
   SSV5_g_candidateBars++;

   int competingDirection=SSV5_g_market.structuralDirection;
   if(competingDirection!=0 && competingDirection!=SSV5_g_candidateDirection &&
      SSV5_M5StructuralReady(competingDirection,SSV5_MIN_STRUCTURAL_ONSET_SCORE))
     {
      SSV5_ReturnToSearch();
      return;
     }

   double newAnchor=SSV5_RecentMovementAnchor(SSV5_g_candidateDirection,12);
   if(SSV5_g_candidateDirection>0 && newAnchor<SSV5_g_candidateAnchor)
     {
      SSV5_g_candidateAnchor=newAnchor;
      SSV5_g_candidateBars=0;
     }
   else if(SSV5_g_candidateDirection<0 && newAnchor>SSV5_g_candidateAnchor)
     {
      SSV5_g_candidateAnchor=newAnchor;
      SSV5_g_candidateBars=0;
     }

   if(!SSV5_M5StructuralReady(SSV5_g_candidateDirection,SSV5_MIN_STRUCTURAL_ONSET_SCORE))
     {
      SSV5_ReturnToSearch();
      return;
     }

   if(SSV5_g_candidateBars>SSV5_MAX_CANDIDATE_BARS)
     {
      SSV5_ReturnToSearch();
      return;
     }

   if(SSV5_g_candidateBars>=SSV5_MIN_CANDIDATE_BARS && SSV5_AcquisitionEvidenceReady(SSV5_g_candidateDirection))
     {
      SSV5_g_acquiredEntryMode=SSV5_VelocityEntryMode(SSV5_g_candidateDirection);
      SSV5_g_state=SSV5_STATE_ACQUIRED;
      SSV5_g_acquiredSignalBar=iTime(Symbol(),PERIOD_M1,1);
      SSV5_g_nextOrderAttempt=0;
     }
  }

//+------------------------------------------------------------------+
//| Trading and full-position exit management                        |
//+------------------------------------------------------------------+
bool SSV5_TryOpenAcquiredTrack()
  {
   if(!SSV5_g_instanceLeaseHeld) return(false);
   if(SSV5_g_state!=SSV5_STATE_ACQUIRED || SSV5_g_candidateDirection==0) return(false);
   if(TimeCurrent()<SSV5_g_nextOrderAttempt) return(false);
   datetime latestClosedBar=iTime(Symbol(),PERIOD_M1,1);
   bool signalTooOld=(SSV5_g_acquiredSignalBar>0 &&
                      TimeCurrent()-(SSV5_g_acquiredSignalBar+60)>SSV5_MAX_ACQUIRED_SIGNAL_AGE_SECONDS);
   if(SSV5_g_acquiredSignalBar<=0 || latestClosedBar!=SSV5_g_acquiredSignalBar || signalTooOld)
     {
      Print("XVISION SuperScalper: acquired signal expired before fill direction=",SSV5_DirectionName(SSV5_g_candidateDirection));
      SSV5_ReturnToSearch();
      return(false);
     }
   if(!SSV5_AcquisitionEvidenceReady(SSV5_g_candidateDirection))
     {
      Print("XVISION SuperScalper: acquired structural signal no longer valid before fill direction=",
            SSV5_DirectionName(SSV5_g_candidateDirection));
      SSV5_ReturnToSearch();
      return(false);
     }
   if(SSV5_HasOpenStrategyPositionOnSymbol())
     {
      SSV5_g_nextOrderAttempt=TimeCurrent()+SSV5_ENTRY_BLOCK_RETRY_SECONDS;
      return(false);
     }
   if(!IsTradeAllowed())
     {
      SSV5_g_nextOrderAttempt=TimeCurrent()+SSV5_ENTRY_BLOCK_RETRY_SECONDS;
      return(false);
     }

   string operationalBlock="";
   if(!SSV5_OperationalEntryAllowed(SSV5_g_candidateDirection,operationalBlock))
     {
      Print("XVISION SuperScalper: entry blocked - ",operationalBlock);
      SSV5_g_nextOrderAttempt=TimeCurrent()+SSV5_ENTRY_BLOCK_RETRY_SECONDS;
      return(false);
     }

   RefreshRates();
   int command=(SSV5_g_candidateDirection>0 ? OP_BUY : OP_SELL);
   double price=(command==OP_BUY ? Ask : Bid);
   if(Bid<=0.0 || Ask<=0.0 || price<=0.0)
     {
      SSV5_g_nextOrderAttempt=TimeCurrent()+SSV5_OPERATION_RETRY_SECONDS;
      return(false);
     }
   double liveSpread=MathMax(0.0,Ask-Bid);
   double signalReference=(SSV5_g_velocity.referenceEntry>0.0 ? SSV5_g_velocity.referenceEntry : price);
   double entryDeviation=MathAbs(price-signalReference);
   if(SSV5_MaximumSpreadMovement>0.0 && liveSpread>SSV5_MaximumSpreadMovement)
     {
      Print("XVISION SuperScalper: entry blocked - spread ",DoubleToString(liveSpread,Digits),
            " exceeds ",DoubleToString(SSV5_MaximumSpreadMovement,Digits));
      SSV5_g_nextOrderAttempt=TimeCurrent()+SSV5_ENTRY_BLOCK_RETRY_SECONDS;
      return(false);
     }
   if(SSV5_MaximumEntryDeviationMovement>0.0 && entryDeviation>SSV5_MaximumEntryDeviationMovement)
     {
      Print("XVISION SuperScalper: entry blocked - closed-M1 deviation ",
            DoubleToString(entryDeviation,Digits)," exceeds ",
            DoubleToString(SSV5_MaximumEntryDeviationMovement,Digits));
      SSV5_ReturnToSearch();
      return(false);
     }

   double lots=SSV5_CalculateEntryLots();
   if(lots<=0.0)
     {
      Print("XVISION SuperScalper: entry cancelled because lot calculation is invalid for the broker contract.");
      SSV5_ReturnToSearch();
      return(false);
     }
   if(AccountFreeMarginCheck(Symbol(),command,lots)<=0.0)
     {
      Print("XVISION SuperScalper: entry blocked - insufficient free margin.");
      SSV5_ReturnToSearch();
      return(false);
     }

   double decisionP30=SSV5_Probability30(SSV5_g_candidateDirection);
   double decisionExpected=SSV5_ExpectedTravel(SSV5_g_candidateDirection);
   double decisionRemaining=SSV5_RemainingTravel(SSV5_g_candidateDirection);
   double decisionOpportunity=SSV5_OpportunityScore(SSV5_g_candidateDirection);
   double decisionEvidence=SSV5_TrackerEvidence(SSV5_g_candidateDirection);
   double decisionHorizon=SSV5_g_market.horizonMinutes;
   int decisionCalibrationBin=(SSV5_g_candidateDirection>0 ? SSV5_g_trackerUp.calibrationBin : SSV5_g_trackerDown.calibrationBin);
   double decisionDevelopmentATR=(SSV5_g_candidateDirection>0 ? SSV5_g_trackerUp.entryDevelopmentATR :
                                                           SSV5_g_trackerDown.entryDevelopmentATR);
   double decisionPathAlternation=SSV5_g_market.pathAlternationM1;
   double decisionWickRejection=SSV5_g_market.wickRejectionM1;
   double decisionAccelerationPersistence=SSV5_g_market.accelerationPersistenceM1;
   double decisionStructuralNovelty=SSV5_g_market.structuralNovelty;
   double decisionResearchDrift=SSV5_g_market.researchDriftScore;
   double decisionRequestedPrice=NormalizeDouble(price,Digits);
   double decisionEntrySpread=liveSpread;
   int decisionEntryMode=SSV5_VelocityEntryMode(SSV5_g_candidateDirection);
   if(decisionEntryMode==SSV5_SS_ENTRY_NONE)
     {
      SSV5_ReturnToSearch();
      return(false);
     }

   ResetLastError();
   int ticket=OrderSend(Symbol(),command,lots,decisionRequestedPrice,
                         SSV5_SlippagePointsForBroker(),0.0,0.0,
                         (decisionEntryMode==SSV5_SS_ENTRY_ELITE ? "XVS1_ELITE" : "XVS1_CONFIRMED"),SSV5_EA_MAGIC,0,
                         (command==OP_BUY ? clrDodgerBlue : clrTomato));
   if(ticket<0)
     {
      int error=GetLastError();
      Print("XVISION SuperScalper: OrderSend failed direction=",SSV5_DirectionName(SSV5_g_candidateDirection)," error=",error);
      SSV5_g_nextOrderAttempt=TimeCurrent()+SSV5_OPERATION_RETRY_SECONDS;
      return(false);
     }

   SSV5_IncrementEntriesToday();
   SSV5_RecordThesisEntry(SSV5_g_candidateDirection);
   if(!OrderSelect(ticket,SELECT_BY_TICKET,MODE_TRADES))
     {
      Print("XVISION SuperScalper: filled ticket is temporarily unavailable for selection ticket=",ticket,
            "; protection sync will retry.");
      SSV5_g_activeTicket=ticket;
      SSV5_g_activeDirection=(command==OP_BUY ? 1 : -1);
       SSV5_g_state=SSV5_STATE_ACTIVE;
       SSV5_g_modelExitRequested=false;
       SSV5_g_modelExitReason="";
       SSV5_g_invalidBars=0;
       SSV5_g_trackLogOdds=decisionEvidence;
       SSV5_g_favorableExtreme=price;
       SSV5_g_activeEntryTime=TimeCurrent();
       SSV5_g_activeEntryP30=decisionP30;
       SSV5_g_activeEntryExpectedTravel=decisionExpected;
        SSV5_g_activeEntryRemainingTravel=decisionRemaining;
        SSV5_g_activeEntryOpportunity=decisionOpportunity;
        SSV5_g_activeRequestedPrice=decisionRequestedPrice;
        SSV5_g_activeFillPrice=0.0;
        SSV5_g_activeEntrySpread=decisionEntrySpread;
        SSV5_g_activeEntryDeviation=0.0;
        SSV5_g_activeEntryDevelopmentATR=decisionDevelopmentATR;
        SSV5_g_activeEntryPathAlternation=decisionPathAlternation;
        SSV5_g_activeEntryWickRejection=decisionWickRejection;
        SSV5_g_activeEntryAccelerationPersistence=decisionAccelerationPersistence;
        SSV5_g_activeEntryStructuralNovelty=decisionStructuralNovelty;
        SSV5_g_activeEntryResearchDrift=decisionResearchDrift;
         SSV5_g_activeProtectionState=((SSV5_StopLoss_PriceUSD>0.0 || SSV5_TakeProfit_PriceUSD>0.0) ?
                                  SSV5_PROTECTION_PENDING : SSV5_PROTECTION_OFF);
        SSV5_g_activeCalibrationBin=decisionCalibrationBin;
       SSV5_g_activeCalibrationResolved=false;
       SSV5_g_activeCalibrationSuccess=false;
       SSV5_g_activeMaxFavorable=0.0;
       SSV5_g_activeMaxAdverse=0.0;
       SSV5_g_activeHorizonMinutes=decisionHorizon;
      SSV5_g_expectedSL=0.0;
      SSV5_g_expectedTP=0.0;
      SSV5_g_manualSLOverride=false;
      SSV5_g_manualTPOverride=false;
       SSV5_g_needExitSync=(SSV5_StopLoss_PriceUSD>0.0 || SSV5_TakeProfit_PriceUSD>0.0);
      SSV5_g_exitSyncFailures=0;
      SSV5_g_nextExitSyncAttempt=0;
       SSV5_g_acquiredSignalBar=0;
       SSV5_g_acquiredEntryMode=SSV5_SS_ENTRY_NONE;
       SSV5_PersistActiveTrade();
       SSV5_AppendTelemetry("ENTRY",SSV5_EntryModeName(decisionEntryMode)+"-selection-pending");
       return(true);
     }

   SSV5_g_activeTicket=ticket;
   SSV5_g_activeDirection=(OrderType()==OP_BUY ? 1 : -1);
   SSV5_g_state=SSV5_STATE_ACTIVE;
   SSV5_g_modelExitRequested=false;
   SSV5_g_modelExitReason="";
   SSV5_g_invalidBars=0;
   SSV5_g_trackLogOdds=decisionEvidence;
   SSV5_g_favorableExtreme=OrderOpenPrice();
   SSV5_g_activeEntryTime=OrderOpenTime();
   SSV5_g_activeEntryP30=decisionP30;
   SSV5_g_activeEntryExpectedTravel=decisionExpected;
   SSV5_g_activeEntryRemainingTravel=decisionRemaining;
   SSV5_g_activeEntryOpportunity=decisionOpportunity;
   SSV5_g_activeRequestedPrice=decisionRequestedPrice;
   SSV5_g_activeFillPrice=OrderOpenPrice();
   SSV5_g_activeEntrySpread=decisionEntrySpread;
   SSV5_g_activeEntryDeviation=MathAbs(SSV5_g_activeFillPrice-SSV5_g_activeRequestedPrice);
   SSV5_g_activeEntryDevelopmentATR=decisionDevelopmentATR;
   SSV5_g_activeEntryPathAlternation=decisionPathAlternation;
   SSV5_g_activeEntryWickRejection=decisionWickRejection;
   SSV5_g_activeEntryAccelerationPersistence=decisionAccelerationPersistence;
   SSV5_g_activeEntryStructuralNovelty=decisionStructuralNovelty;
   SSV5_g_activeEntryResearchDrift=decisionResearchDrift;
   SSV5_g_activeProtectionState=((SSV5_StopLoss_PriceUSD>0.0 || SSV5_TakeProfit_PriceUSD>0.0) ?
                             SSV5_PROTECTION_PENDING : SSV5_PROTECTION_OFF);
   SSV5_g_activeCalibrationBin=decisionCalibrationBin;
   SSV5_g_activeCalibrationResolved=false;
   SSV5_g_activeCalibrationSuccess=false;
   SSV5_g_activeMaxFavorable=0.0;
   SSV5_g_activeMaxAdverse=0.0;
   SSV5_g_activeHorizonMinutes=decisionHorizon;
   SSV5_g_expectedSL=OrderStopLoss();
   SSV5_g_expectedTP=OrderTakeProfit();
   SSV5_g_manualSLOverride=false;
   SSV5_g_manualTPOverride=false;
   SSV5_g_needExitSync=(SSV5_StopLoss_PriceUSD>0.0 || SSV5_TakeProfit_PriceUSD>0.0);
   SSV5_g_exitSyncFailures=0;
   SSV5_g_nextExitSyncAttempt=0;
   SSV5_g_acquiredSignalBar=0;
   SSV5_g_acquiredEntryMode=SSV5_SS_ENTRY_NONE;
   SSV5_PersistActiveTrade();
   if(SSV5_g_needExitSync) SSV5_ApplyInputExits();
   SSV5_StartQualifiedResearchTrack(ticket,SSV5_g_activeDirection,SSV5_g_activeFillPrice);
   SSV5_AppendTelemetry("ENTRY",SSV5_EntryModeName(decisionEntryMode));

   Print("XVISION SuperScalper V5.00: entry filled ticket=",ticket," direction=",SSV5_DirectionName(SSV5_g_activeDirection),
          " mode=",SSV5_EntryModeName(decisionEntryMode),
          " price=",DoubleToString(OrderOpenPrice(),Digits)," p30=",DoubleToString(SSV5_Probability30(SSV5_g_activeDirection),3),
          " remaining=",DoubleToString(decisionRemaining,2),
          " opportunity=",DoubleToString(decisionOpportunity,3)," entriesToday=",SSV5_EntriesToday(),
          " thesisEntry=",SSV5_g_thesisEntries,"/",SSV5_MAX_ENTRIES_PER_THESIS);
   return(true);
  }

void SSV5_DetectManualExitChanges()
  {
   if(SSV5_g_activeTicket<=0 || SSV5_g_needExitSync) return;
   if(!OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return;
   bool changed=false;

   if(!SSV5_SamePrice(OrderStopLoss(),SSV5_g_expectedSL))
     {
      SSV5_g_manualSLOverride=true;
      SSV5_g_activeProtectionState=SSV5_PROTECTION_MANUAL;
      SSV5_g_expectedSL=OrderStopLoss();
      changed=true;
      Print("XVISION SuperScalper: manual SL override detected ticket=",SSV5_g_activeTicket,
            "; profit-lock and trailing adjustments suspended for this trade.");
     }
   if(!SSV5_SamePrice(OrderTakeProfit(),SSV5_g_expectedTP))
     {
      SSV5_g_manualTPOverride=true;
      SSV5_g_activeProtectionState=SSV5_PROTECTION_MANUAL;
      SSV5_g_expectedTP=OrderTakeProfit();
      changed=true;
      Print("XVISION SuperScalper: manual TP override detected ticket=",SSV5_g_activeTicket);
     }
   if(changed) SSV5_PersistActiveTrade();
  }

void SSV5_ManageProfitProtection()
  {
   if(SSV5_g_activeTicket<=0 || SSV5_g_manualSLOverride || SSV5_g_needExitSync) return;
   if(TimeCurrent()<SSV5_g_nextExitSyncAttempt) return;
   if(!OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return;
   int type=OrderType();
   double openPrice=OrderOpenPrice();
   double currentSL=OrderStopLoss();
   double currentTP=OrderTakeProfit();
   double desiredSL=currentSL;
   double stopDistance=MarketInfo(Symbol(),MODE_STOPLEVEL)*Point;
   double freezeDistance=MarketInfo(Symbol(),MODE_FREEZELEVEL)*Point;
   // One extra point prevents NormalizeDouble() from rounding a stop back
   // inside the broker's stop/freeze boundary.
   double minimumDistance=MathMax(MathMax(stopDistance,freezeDistance),Point)+Point;

   if(type==OP_BUY)
     {
      SSV5_g_favorableExtreme=MathMax(SSV5_g_favorableExtreme,Bid);
      double gain=SSV5_g_favorableExtreme-openPrice;
      if(SSV5_LockTrigger_PriceUSD>0.0 && gain>=SSV5_LockTrigger_PriceUSD)
        {
         double lockLevel=openPrice+MathMax(SSV5_LockedProfit_PriceUSD,0.0);
         if(desiredSL<=0.0 || lockLevel>desiredSL) desiredSL=lockLevel;
        }
      if(SSV5_TrailingStart_PriceUSD>0.0 && SSV5_TrailingDistance_PriceUSD>0.0 && gain>=SSV5_TrailingStart_PriceUSD)
        {
         double trailingLevel=SSV5_g_favorableExtreme-SSV5_TrailingDistance_PriceUSD;
         if(desiredSL<=0.0 || trailingLevel>desiredSL) desiredSL=trailingLevel;
        }
      if(desiredSL>0.0) desiredSL=MathMin(desiredSL,Bid-minimumDistance);
      if(currentSL>0.0 && desiredSL<currentSL) desiredSL=currentSL;
     }
   else if(type==OP_SELL)
     {
      if(SSV5_g_favorableExtreme<=0.0) SSV5_g_favorableExtreme=openPrice;
      SSV5_g_favorableExtreme=MathMin(SSV5_g_favorableExtreme,Ask);
      double gain=openPrice-SSV5_g_favorableExtreme;
      if(SSV5_LockTrigger_PriceUSD>0.0 && gain>=SSV5_LockTrigger_PriceUSD)
        {
         double lockLevel=openPrice-MathMax(SSV5_LockedProfit_PriceUSD,0.0);
         if(desiredSL<=0.0 || lockLevel<desiredSL) desiredSL=lockLevel;
        }
      if(SSV5_TrailingStart_PriceUSD>0.0 && SSV5_TrailingDistance_PriceUSD>0.0 && gain>=SSV5_TrailingStart_PriceUSD)
        {
         double trailingLevel=SSV5_g_favorableExtreme+SSV5_TrailingDistance_PriceUSD;
         if(desiredSL<=0.0 || trailingLevel<desiredSL) desiredSL=trailingLevel;
        }
      if(desiredSL>0.0) desiredSL=MathMax(desiredSL,Ask+minimumDistance);
      if(currentSL>0.0 && desiredSL>currentSL) desiredSL=currentSL;
     }

   if(desiredSL>0.0) desiredSL=NormalizeDouble(desiredSL,Digits);
   if(!SSV5_SamePrice(desiredSL,currentSL))
     {
      if(SSV5_ModifyActiveStops(desiredSL,currentTP,"profit-protection"))
         SSV5_g_nextExitSyncAttempt=0;
      else
         SSV5_g_nextExitSyncAttempt=TimeCurrent()+SSV5_OPERATION_RETRY_SECONDS;
     }
  }

void SSV5_UpdateActiveExcursions()
  {
   if(SSV5_g_activeTicket<=0) return;
   if(!OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return;
   double currentExecutable=(SSV5_g_activeDirection>0 ? Bid : Ask);
   double favorable=SSV5_g_activeDirection*(currentExecutable-OrderOpenPrice());
   double adverse=-favorable;
   bool calibrationJustResolved=false;
   SSV5_g_activeMaxFavorable=MathMax(SSV5_g_activeMaxFavorable,MathMax(0.0,favorable));
   SSV5_g_activeMaxAdverse=MathMax(SSV5_g_activeMaxAdverse,MathMax(0.0,adverse));
   if(!SSV5_g_activeCalibrationResolved)
     {
      if(favorable>=SSV5_CALIBRATION_TARGET_USD)
        {
         SSV5_g_activeCalibrationResolved=true;
         SSV5_g_activeCalibrationSuccess=true;
         calibrationJustResolved=true;
        }
      else if(adverse>=SSV5_CALIBRATION_ADVERSE_USD)
        {
         SSV5_g_activeCalibrationResolved=true;
         SSV5_g_activeCalibrationSuccess=false;
         calibrationJustResolved=true;
        }
     }
   if(SSV5_g_activeDirection>0) SSV5_g_favorableExtreme=MathMax(SSV5_g_favorableExtreme,currentExecutable);
   else SSV5_g_favorableExtreme=MathMin(SSV5_g_favorableExtreme,currentExecutable);
   if(calibrationJustResolved) SSV5_PersistActiveTrade();
  }

void SSV5_UpdateThesisAndMaybeInvalidate()
  {
   if(SSV5_g_activeTicket<=0 || SSV5_g_state!=SSV5_STATE_ACTIVE) return;
   if(!OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return;

   double directedEvidence=SSV5_g_activeDirection*SSV5_g_market.directionalLogit;
   double regimeSupport=SSV5_g_market.modeDrift+SSV5_g_market.modeImpulse;
   double regimeRisk=SSV5_g_market.modeExhaustion+0.75*SSV5_g_market.modeShock;
   double cusumEdge=SSV5_DirectionalCUSUM(SSV5_g_activeDirection)-SSV5_OpposingCUSUM(SSV5_g_activeDirection);
   double trackerEvidence=SSV5_TrackerEvidence(SSV5_g_activeDirection);
   double evidenceInnovation=0.52*directedEvidence+0.18*SSV5_Clamp(cusumEdge,-4.0,5.0)+
                             0.22*trackerEvidence+0.18*regimeSupport-0.34*regimeRisk;
   SSV5_g_trackLogOdds=SSV5_Clamp(0.86*SSV5_g_trackLogOdds+0.34*evidenceInnovation,-8.0,8.0);

   if(evidenceInnovation<-0.25 || SSV5_OpposingCUSUM(SSV5_g_activeDirection)>SSV5_DirectionalCUSUM(SSV5_g_activeDirection)+0.65)
      SSV5_g_invalidBars++;
   else if(evidenceInnovation>0.30 && SSV5_g_invalidBars>0)
      SSV5_g_invalidBars=MathMax(0,SSV5_g_invalidBars-1);

   double currentExecutable=(SSV5_g_activeDirection>0 ? Bid : Ask);
   SSV5_UpdateActiveExcursions();
   double giveback=SSV5_g_activeDirection*(SSV5_g_favorableExtreme-currentExecutable);
   double adverseFromEntry=-SSV5_g_activeDirection*(currentExecutable-OrderOpenPrice());
   double adaptiveReversal=SSV5_Clamp(2.7*SSV5_g_market.sigmaM1*MathSqrt(5.0),5.0,10.0);
   double hardAdverse=SSV5_Clamp(3.8*SSV5_g_market.sigmaM1*MathSqrt(5.0),8.0,20.0);
   double lastMove=iClose(Symbol(),PERIOD_M1,1)-iClose(Symbol(),PERIOD_M1,2);
   double oppositeShock=-SSV5_g_activeDirection*lastMove/MathMax(SSV5_g_market.sigmaM1,Point);

   bool invalid=false;
   string reason="";
   double ageMinutes=MathMax(0.0,(TimeCurrent()-SSV5_g_activeEntryTime)/60.0);
   double launchThreshold=MathMax(SSV5_FAILURE_TO_LAUNCH_PROGRESS_USD,
                                  1.80*SSV5_g_market.sigmaM1*MathSqrt(5.0));
   if(SSV5_g_invalidBars>=SSV5_MIN_THESIS_INVALID_BARS && SSV5_g_trackLogOdds<-0.15)
     {
      invalid=true;
      reason="persistent evidence failure";
     }
   else if(SSV5_g_velocity.valid && SSV5_g_velocity.qualified &&
           SSV5_g_velocity.direction==-SSV5_g_activeDirection && SSV5_g_trackLogOdds<0.50)
     {
      invalid=true;
      reason="opposite confirmed M1/M5 velocity";
     }
   else if(ageMinutes>=SSV5_FAILURE_TO_LAUNCH_MINUTES &&
           SSV5_g_activeMaxFavorable<launchThreshold &&
           SSV5_g_invalidBars>=SSV5_MIN_THESIS_INVALID_BARS && SSV5_g_trackLogOdds<0.25)
     {
      invalid=true;
      reason="failure to launch";
     }
   else if(giveback>=adaptiveReversal && SSV5_g_invalidBars>=2 && SSV5_g_trackLogOdds<0.0)
      {
       invalid=true;
       reason="persistent adaptive reversal";
      }
   else if(adverseFromEntry>=hardAdverse && (SSV5_g_invalidBars>=2 || SSV5_g_trackLogOdds<0.0))
      {
       invalid=true;
       reason="adverse thesis boundary";
      }
   else if(oppositeShock>=3.0 && SSV5_g_invalidBars>=2 && SSV5_g_trackLogOdds<0.0)
      {
       invalid=true;
       reason="confirmed opposite shock";
      }
   if(invalid)
     {
       SSV5_g_modelExitRequested=true;
       SSV5_g_modelExitReason=reason;
       SSV5_g_state=SSV5_STATE_EXITING;
       Print("XVISION SuperScalper V5.00: thesis invalidated ticket=",SSV5_g_activeTicket," reason=",reason,
             " trackLogOdds=",DoubleToString(SSV5_g_trackLogOdds,3)," invalidBars=",SSV5_g_invalidBars,
             " giveback=",DoubleToString(giveback,2)," MFE=",DoubleToString(SSV5_g_activeMaxFavorable,2));
      }
   SSV5_PersistActiveTrade();
  }

bool SSV5_CloseFullActivePosition()
  {
   if(!SSV5_g_instanceLeaseHeld) return(false);
   if(SSV5_g_activeTicket<=0) return(false);
   if(TimeCurrent()<SSV5_g_nextCloseAttempt) return(false);
   if(!IsTradeAllowed()) return(false);
   if(!OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return(false);
   RefreshRates();
   int type=OrderType();
   double price=(type==OP_BUY ? Bid : Ask);
   double lots=OrderLots();
   ResetLastError();
   bool closed=OrderClose(SSV5_g_activeTicket,lots,NormalizeDouble(price,Digits),
                           SSV5_SlippagePointsForBroker(),clrGold);
   if(!closed)
     {
      int error=GetLastError();
      Print("XVISION SuperScalper: full-position close failed ticket=",SSV5_g_activeTicket," error=",error);
      SSV5_g_nextCloseAttempt=TimeCurrent()+SSV5_OPERATION_RETRY_SECONDS;
      return(false);
     }
   SSV5_g_nextCloseAttempt=0;
   return(true);
  }

double SSV5_MoneyPerPriceUnitPerLot()
  {
   double tickValue=MarketInfo(Symbol(),MODE_TICKVALUE);
   double tickSize=MarketInfo(Symbol(),MODE_TICKSIZE);
   if(tickSize<=0.0 || tickValue<=0.0) return(0.0);
   return(tickValue/tickSize);
  }

void SSV5_ResetForFreshCycle()
  {
   SSV5_g_activeTicket=-1;
   SSV5_g_activeDirection=0;
   SSV5_g_modelExitRequested=false;
   SSV5_g_manualSLOverride=false;
   SSV5_g_manualTPOverride=false;
   SSV5_g_needExitSync=false;
   SSV5_g_expectedSL=0.0;
   SSV5_g_expectedTP=0.0;
   SSV5_g_favorableExtreme=0.0;
   SSV5_g_trackLogOdds=0.0;
   SSV5_g_invalidBars=0;
   SSV5_g_activeEntryTime=0;
   SSV5_g_activeEntryP30=0.0;
   SSV5_g_activeEntryExpectedTravel=0.0;
   SSV5_g_activeEntryRemainingTravel=0.0;
   SSV5_g_activeEntryOpportunity=0.0;
   SSV5_g_activeRequestedPrice=0.0;
   SSV5_g_activeFillPrice=0.0;
   SSV5_g_activeEntrySpread=0.0;
   SSV5_g_activeEntryDeviation=0.0;
   SSV5_g_activeEntryDevelopmentATR=0.0;
   SSV5_g_activeEntryPathAlternation=0.0;
   SSV5_g_activeEntryWickRejection=0.0;
   SSV5_g_activeEntryAccelerationPersistence=0.0;
   SSV5_g_activeEntryStructuralNovelty=0.0;
   SSV5_g_activeEntryResearchDrift=0.0;
   SSV5_g_activeProtectionState=SSV5_PROTECTION_OFF;
   SSV5_g_activeCalibrationBin=-1;
   SSV5_g_activeCalibrationResolved=false;
   SSV5_g_activeCalibrationSuccess=false;
   SSV5_g_activeMaxFavorable=0.0;
   SSV5_g_activeMaxAdverse=0.0;
   SSV5_g_activeHorizonMinutes=0.0;
   SSV5_g_modelExitReason="";
   SSV5_g_exitSyncFailures=0;
   SSV5_g_acquiredSignalBar=0;
   SSV5_g_nextOrderAttempt=0;
   SSV5_g_nextExitSyncAttempt=0;
   SSV5_g_nextCloseAttempt=0;
   SSV5_g_lastFinalizeAttemptMs=0;
   SSV5_g_finalizeHistoryFailures=0;
   SSV5_ReturnToSearch();
   SSV5_ClearActiveTradePersistence();

   // Preserve the live structural thesis, CUSUM and tracker memory across the
   // close.  The next cycle reassesses current evidence immediately and may
   // take a same-direction continuation if it still independently qualifies.
   if(SSV5_HasSufficientData())
     {
      SSV5_ComputeMarketSnapshot(false);
      SSV5_ComputeVelocitySnapshot(1);
      SSV5_UpdateDirectionalTrackers(false);
      if(SSV5_TRADE_CURRENT_SIGNAL_ON_ATTACH) SSV5_AdvanceAcquisitionState();
     }
  }

void SSV5_FinalizeClosedTrade()
  {
   int closedTicket=SSV5_g_activeTicket;
   datetime closeTime=TimeCurrent();
   uint finalizeNow=GetTickCount();
   if(SSV5_g_lastFinalizeAttemptMs>0 && finalizeNow-SSV5_g_lastFinalizeAttemptMs<SSV5_FINALIZE_HISTORY_RETRY_MS) return;
   SSV5_g_lastFinalizeAttemptMs=finalizeNow;
   bool closedSelected=(closedTicket>0 && OrderSelect(closedTicket,SELECT_BY_TICKET,MODE_HISTORY) &&
                        OrderCloseTime()>0);
   if(closedTicket>0 && !closedSelected)
     {
      SSV5_g_finalizeHistoryFailures++;
      if(SSV5_g_finalizeHistoryFailures<SSV5_MAX_FINALIZE_HISTORY_FAILURES) return;
      Print("XVISION SuperScalper: closed ticket did not appear in account history after ",
            SSV5_g_finalizeHistoryFailures," checks; clearing stale local state ticket=",closedTicket);
      CloseQualifiedResearchTrackForTicket(closedTicket,"CENSORED_HISTORY_UNAVAILABLE",SSV5_CurrentMidPrice());
      SSV5_ResetForFreshCycle();
      return;
     }
   SSV5_g_finalizeHistoryFailures=0;
   SSV5_g_lastFinalizeAttemptMs=0;
   if(closedTicket>0 && closedSelected)
     {
      closeTime=OrderCloseTime();
      int direction=(OrderType()==OP_BUY ? 1 : -1);
      double grossCapture=direction*(OrderClosePrice()-OrderOpenPrice());
      SSV5_g_activeMaxFavorable=MathMax(SSV5_g_activeMaxFavorable,MathMax(0.0,grossCapture));
      SSV5_g_activeMaxAdverse=MathMax(SSV5_g_activeMaxAdverse,MathMax(0.0,-grossCapture));
      if(!SSV5_g_activeCalibrationResolved)
        {
         if(grossCapture>=SSV5_CALIBRATION_TARGET_USD)
           {
            SSV5_g_activeCalibrationResolved=true;
            SSV5_g_activeCalibrationSuccess=true;
           }
         else if(-grossCapture>=SSV5_CALIBRATION_ADVERSE_USD)
           {
            SSV5_g_activeCalibrationResolved=true;
            SSV5_g_activeCalibrationSuccess=false;
           }
        }
      double netCapture=grossCapture;
      double moneyPerPrice=SSV5_MoneyPerPriceUnitPerLot();
      if(moneyPerPrice>0.0 && OrderLots()>0.0)
         netCapture+=(OrderCommission()+OrderSwap())/(moneyPerPrice*OrderLots());
       string closeReason=(SSV5_g_modelExitReason!="" ? SSV5_g_modelExitReason : "manual-or-input-close");
       bool calibrationSuccess=(SSV5_g_activeCalibrationResolved && SSV5_g_activeCalibrationSuccess);
       double activeAgeMinutes=MathMax(0.0,(closeTime-SSV5_g_activeEntryTime)/60.0);
       bool calibrationFailure=(SSV5_g_activeCalibrationResolved && !SSV5_g_activeCalibrationSuccess);
        if(!SSV5_g_activeCalibrationResolved &&
           ((SSV5_g_modelExitReason!="" && !SSV5_IsConfiguredProfitExitReason(SSV5_g_modelExitReason)) ||
            activeAgeMinutes>=MathMax(60.0,SSV5_g_activeHorizonMinutes)))
          calibrationFailure=true;
       if(SSV5_g_activeCalibrationResolved)
          SSV5_UpdateResearchPredictionError(SSV5_g_activeCalibrationSuccess,SSV5_g_activeEntryP30);
       string qualifiedOutcome=(SSV5_g_activeCalibrationResolved ?
                                (SSV5_g_activeCalibrationSuccess ? "HIT30" : "MISS15") :
                                "CENSORED_TRADE_CLOSE");
       CloseQualifiedResearchTrackForTicket(closedTicket,qualifiedOutcome,OrderClosePrice());
       RegisterThesisClose(direction,grossCapture,OrderClosePrice(),SSV5_g_modelExitReason);
       if(calibrationSuccess || calibrationFailure)
          SSV5_RecordCalibrationOutcome(SSV5_g_activeCalibrationBin,calibrationSuccess);
       string calibrationStatus=(calibrationSuccess ? "HIT30" : (calibrationFailure ? "MISS15" : "CENSORED"));
       SSV5_AppendTelemetry("EXIT",closeReason,calibrationStatus);
      Print("XVISION SuperScalper V5.00: cycle closed ticket=",closedTicket,
             " grossCapture=",DoubleToString(grossCapture,2),
             " netCapture=",DoubleToString(netCapture,2),
             " MFE=",DoubleToString(SSV5_g_activeMaxFavorable,2),
             " MAE=",DoubleToString(SSV5_g_activeMaxAdverse,2),
              " calibration=",calibrationStatus,
             " closeTime=",TimeToString(closeTime,TIME_DATE|TIME_MINUTES));
     }
   else
      Print("XVISION SuperScalper: active ticket disappeared; starting a fresh acquisition cycle ticket=",closedTicket);
   SSV5_ResetForFreshCycle();
  }

void SSV5_SuperviseActiveLifecycle()
  {
   int discovered=SSV5_FindOpenEAOrder();
   if(SSV5_g_activeTicket<=0 && discovered>0)
     {
      SSV5_RecoverActiveTrade(discovered);
      return;
     }
   if(SSV5_g_activeTicket>0 && discovered<=0)
     {
      SSV5_FinalizeClosedTrade();
      return;
     }
   if(SSV5_g_activeTicket<=0) return;

   if(!OrderSelect(SSV5_g_activeTicket,SELECT_BY_TICKET,MODE_TRADES) || OrderCloseTime()>0)
     {
      SSV5_FinalizeClosedTrade();
      return;
     }

   if(SSV5_g_activeFillPrice<=0.0)
     {
      SSV5_g_activeDirection=(OrderType()==OP_BUY ? 1 : -1);
      SSV5_g_activeFillPrice=OrderOpenPrice();
      SSV5_g_activeEntryTime=OrderOpenTime();
      if(SSV5_g_activeRequestedPrice<=0.0) SSV5_g_activeRequestedPrice=SSV5_g_activeFillPrice;
      SSV5_g_activeEntryDeviation=MathAbs(SSV5_g_activeFillPrice-SSV5_g_activeRequestedPrice);
      SSV5_g_expectedSL=OrderStopLoss();
      SSV5_g_expectedTP=OrderTakeProfit();
      if(SSV5_g_activeDirection>0)
         SSV5_g_favorableExtreme=MathMax(SSV5_g_activeFillPrice,Bid);
      else
         SSV5_g_favorableExtreme=MathMin(SSV5_g_activeFillPrice,Ask);
      SSV5_StartQualifiedResearchTrack(SSV5_g_activeTicket,SSV5_g_activeDirection,SSV5_g_activeFillPrice);
      SSV5_PersistActiveTrade();
     }

   SSV5_UpdateActiveExcursions();

   if(!SSV5_g_needExitSync) SSV5_DetectManualExitChanges();

   if(SSV5_g_state!=SSV5_STATE_EXITING && !SSV5_g_modelExitRequested)
     {
      string reachedReason="";
      if(SSV5_InputExitAlreadyReached(reachedReason))
        {
         SSV5_g_modelExitRequested=true;
         SSV5_g_modelExitReason=reachedReason;
         SSV5_g_state=SSV5_STATE_EXITING;
        }
     }

   if(SSV5_g_state==SSV5_STATE_EXITING || SSV5_g_modelExitRequested)
     {
      if(SSV5_CloseFullActivePosition()) SSV5_FinalizeClosedTrade();
      return;
     }

   if(SSV5_g_needExitSync) SSV5_ApplyInputExits();

   if(SSV5_g_state==SSV5_STATE_EXITING || SSV5_g_modelExitRequested)
     {
      if(SSV5_CloseFullActivePosition()) SSV5_FinalizeClosedTrade();
      return;
     }
   SSV5_ManageProfitProtection();
  }

//+------------------------------------------------------------------+
//| Bar processing and display                                       |
//+------------------------------------------------------------------+
void SSV5_ProcessNewClosedM1Bar()
  {
   datetime closedBar=iTime(Symbol(),PERIOD_M1,1);
   if(closedBar<=0 || closedBar==SSV5_g_lastClosedM1) return;

   datetime currentBar=iTime(Symbol(),PERIOD_M1,0);
   if(currentBar>0 && currentBar-closedBar>180)
     {
      // Do not act on the final stale bar from a closed-session gap.
      SSV5_g_lastClosedM1=closedBar;
       SSV5_g_cusumUp=0.0;
       SSV5_g_cusumDown=0.0;
       SSV5_ResetModeProbabilities();
       SSV5_ResetVelocitySnapshot();
      SSV5_ClearDirectionTracker(SSV5_g_trackerUp);
      SSV5_ClearDirectionTracker(SSV5_g_trackerDown);
      if(SSV5_g_state==SSV5_STATE_CANDIDATE || SSV5_g_state==SSV5_STATE_ACQUIRED) SSV5_ReturnToSearch();
      if(SSV5_g_state!=SSV5_STATE_ACTIVE && SSV5_g_state!=SSV5_STATE_EXITING) SSV5_ClearThesisState();
      SSV5_PersistActiveTrade();
      return;
     }

   if(SSV5_g_lastClosedM1>0 && closedBar-SSV5_g_lastClosedM1>180)
     {
      // The first completed bar after a session/data gap must not inject the
      // cross-gap price jump into CUSUM or thesis evidence.
      SSV5_g_lastClosedM1=closedBar;
       SSV5_g_cusumUp=0.0;
       SSV5_g_cusumDown=0.0;
       SSV5_ResetModeProbabilities();
       SSV5_ResetVelocitySnapshot();
      SSV5_ClearDirectionTracker(SSV5_g_trackerUp);
      SSV5_ClearDirectionTracker(SSV5_g_trackerDown);
      if(SSV5_g_state==SSV5_STATE_CANDIDATE || SSV5_g_state==SSV5_STATE_ACQUIRED) SSV5_ReturnToSearch();
      if(SSV5_g_state!=SSV5_STATE_ACTIVE && SSV5_g_state!=SSV5_STATE_EXITING) SSV5_ClearThesisState();
      SSV5_PersistActiveTrade();
      return;
     }

   SSV5_g_lastClosedM1=closedBar;
   double sigmaM1=SSV5_ReturnSigma(PERIOD_M1,48,0.10);
   SSV5_UpdateCUSUM(sigmaM1);
   SSV5_ComputeMarketSnapshot(true,sigmaM1);
   SSV5_ComputeVelocitySnapshot(1);
   SSV5_UpdateDirectionalTrackers(true);
   SSV5_UpdateThesisRearmState();
   SSV5_ObserveRejectedResearchOpportunity();
   if(SSV5_g_state==SSV5_STATE_ACTIVE)
      SSV5_UpdateThesisAndMaybeInvalidate();
   else if(SSV5_g_state!=SSV5_STATE_EXITING)
     {
      SSV5_AdvanceAcquisitionState();
      if(SSV5_g_state==SSV5_STATE_ACQUIRED) SSV5_TryOpenAcquiredTrack();
     }
  }

void PanelSetBox(const string suffix,const int x,const int y,const int width,const int height,
                 const color background,const color border,const int zOrder=0)
  {
   string name=SSV5_PANEL_PREFIX+suffix;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,background);
   ObjectSetInteger(0,name,OBJPROP_COLOR,border);
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,zOrder);
  }

void PanelSetText(const string suffix,const string text,const int x,const int y,
                  const color textColor,const int fontSize=9,
                  const int anchor=ANCHOR_LEFT_UPPER,const string fontName="Arial")
  {
   string name=SSV5_PANEL_PREFIX+suffix;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,anchor);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,textColor);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontSize);
   ObjectSetString(0,name,OBJPROP_FONT,fontName);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,1);
  }

void SSV5_PanelSetDivider(const string suffix,const int y)
  {
   PanelSetBox(suffix,SSV5_PANEL_LABEL_X,y,SSV5_PANEL_WIDTH-36,1,C'65,77,96',C'65,77,96',1);
  }

void SSV5_PanelSection(const string suffix,const string title,const int titleY,const int lineY)
  {
   PanelSetText(suffix+"Title",title,SSV5_PANEL_LABEL_X,titleY,C'55,169,255',9);
   SSV5_PanelSetDivider(suffix+"Line",lineY);
  }

void SSV5_CreateStatusPanel()
  {
   Comment("");
   PanelSetBox("Background",SSV5_PANEL_LEFT,SSV5_PANEL_TOP,SSV5_PANEL_WIDTH,SSV5_PANEL_HEIGHT,C'13,16,23',C'55,64,80',0);
   PanelSetText("Title","XVISION  |  CONSOLIDATED SCRAPER V2",SSV5_PANEL_LABEL_X,24,C'255,218,0',13);
   PanelSetText("Subtitle","M1/M5 SIGNAL  |  M30 VOLATILITY  |  FULL POSITION",SSV5_PANEL_LABEL_X,44,C'128,151,190',9);
   SSV5_PanelSetDivider("HeaderLine",62);

   SSV5_PanelSection("Status","STATUS",70,85);
   PanelSetText("StatusMessage","INITIALIZING",SSV5_PANEL_LABEL_X,92,C'225,230,240',11);
   PanelSetText("DirectionLabel","Tracking direction",SSV5_PANEL_LABEL_X,117,C'174,184,201',9);
   PanelSetText("DirectionValue","NONE",SSV5_PANEL_VALUE_X,117,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("EntriesLabel","Entries today",SSV5_PANEL_LABEL_X,137,C'174,184,201',9);
   PanelSetText("EntriesValue","0",SSV5_PANEL_VALUE_X,137,C'225,230,240',9,ANCHOR_RIGHT_UPPER);

   SSV5_PanelSection("Management","TRADE MANAGEMENT",155,170);
   PanelSetText("LotsLabel","Sizing mode / next lot",SSV5_PANEL_LABEL_X,177,C'174,184,201',9);
   PanelSetText("LotsValue","--",SSV5_PANEL_VALUE_X,177,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("StopsLabel","Stop loss / take profit",SSV5_PANEL_LABEL_X,195,C'174,184,201',9);
   PanelSetText("StopsValue","--",SSV5_PANEL_VALUE_X,195,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("LockLabel","Lock trigger / locked profit",SSV5_PANEL_LABEL_X,213,C'174,184,201',9);
   PanelSetText("LockValue","--",SSV5_PANEL_VALUE_X,213,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("TrailLabel","Trailing start / distance",SSV5_PANEL_LABEL_X,231,C'174,184,201',9);
   PanelSetText("TrailValue","--",SSV5_PANEL_VALUE_X,231,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("OwnershipLabel","Exit ownership",SSV5_PANEL_LABEL_X,249,C'174,184,201',9);
   PanelSetText("OwnershipValue","MODEL EXIT + OPTIONAL TP",SSV5_PANEL_VALUE_X,249,C'225,230,240',9,ANCHOR_RIGHT_UPPER);

   SSV5_PanelSection("Live","LIVE",271,286);
   PanelSetText("TimeLabel","Broker time",SSV5_PANEL_LABEL_X,293,C'174,184,201',9);
   PanelSetText("TimeValue","--",SSV5_PANEL_VALUE_X,293,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("PriceLabel","Live Bid / Ask",SSV5_PANEL_LABEL_X,311,C'174,184,201',9);
   PanelSetText("PriceValue","-- / --",SSV5_PANEL_VALUE_X,311,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("SpreadLabel","Spread / trading permission",SSV5_PANEL_LABEL_X,329,C'174,184,201',9);
   PanelSetText("SpreadValue","--",SSV5_PANEL_VALUE_X,329,C'225,230,240',9,ANCHOR_RIGHT_UPPER);

   PanelSetText("Benchmark","THESIS  INITIALIZING  |  RESEARCH HEALTH WAITING",SSV5_PANEL_LABEL_X,358,C'255,168,32',8);
   PanelSetText("Footer","ADAPTIVE EXIT  |  CLEAN EXECUTION  |  OPTIONAL SL",SSV5_PANEL_LABEL_X,381,C'128,151,190',8);
  }

void SSV5_DeleteStatusPanel()
  {
   ObjectsDeleteAll(0,SSV5_PANEL_PREFIX);
   SSV5_g_lastPanelRenderMs=0;
  }

string SSV5_SymbolPositionBlockMessage()
  {
   if(SSV5_g_state==SSV5_STATE_ACTIVE || SSV5_g_state==SSV5_STATE_EXITING) return("");
   for(int index=OrdersTotal()-1;index>=0;index--)
     {
      if(!OrderSelect(index,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=SSV5_EA_MAGIC ||
         !SSV5_IsMarketOrderType(OrderType())) continue;
      return("WAITING - EA POSITION RECOVERY");
     }
   return("");
  }

string SSV5_PanelStateMessage()
  {
   if(SSV5_g_finalizeHistoryFailures>0) return("FINALIZING CLOSED TRADE HISTORY");
   string positionBlock=SSV5_SymbolPositionBlockMessage();
   if(positionBlock!="") return(positionBlock);
   if(SSV5_g_state!=SSV5_STATE_ACTIVE && SSV5_g_state!=SSV5_STATE_EXITING)
     {
      int direction=(SSV5_g_candidateDirection!=0 ? SSV5_g_candidateDirection : SSV5_g_market.structuralDirection);
      string thesisBlocker="";
      if(direction!=0 && !SSV5_ThesisEntryPermitted(direction,thesisBlocker) && thesisBlocker!="")
         return("WAITING - "+thesisBlocker);
     }
   if(SSV5_g_state==SSV5_STATE_SEARCH)    return("SCANNING FOR A DEVELOPING MOVE");
   if(SSV5_g_state==SSV5_STATE_CANDIDATE) return("MOVEMENT CANDIDATE DETECTED");
   if(SSV5_g_state==SSV5_STATE_ACQUIRED) return("TARGET ACQUIRED - SEEKING ENTRY");
   if(SSV5_g_state==SSV5_STATE_ACTIVE)   return("TRACKING LIVE PRICE MOVEMENT");
   if(SSV5_g_state==SSV5_STATE_EXITING)  return("THESIS INVALID - EXITING POSITION");
   return("INITIALIZING");
  }

color SSV5_PanelStateColor()
  {
   if(SSV5_g_finalizeHistoryFailures>0) return(C'255,218,0');
   if(SSV5_SymbolPositionBlockMessage()!="") return(C'255,218,0');
   if(SSV5_g_state!=SSV5_STATE_ACTIVE && SSV5_g_state!=SSV5_STATE_EXITING)
     {
      int direction=(SSV5_g_candidateDirection!=0 ? SSV5_g_candidateDirection : SSV5_g_market.structuralDirection);
      string thesisBlocker="";
      if(direction!=0 && !SSV5_ThesisEntryPermitted(direction,thesisBlocker) && thesisBlocker!="")
         return(C'255,168,32');
     }
   if(SSV5_g_state==SSV5_STATE_SEARCH)    return(C'225,230,240');
   if(SSV5_g_state==SSV5_STATE_CANDIDATE) return(C'255,218,0');
   if(SSV5_g_state==SSV5_STATE_ACQUIRED) return(C'55,190,255');
   if(SSV5_g_state==SSV5_STATE_ACTIVE)   return(C'0,230,96');
   if(SSV5_g_state==SSV5_STATE_EXITING)  return(C'255,168,32');
   return(C'225,230,240');
  }

color SSV5_PanelDirectionColor(const int direction)
  {
   if(direction>0) return(C'0,230,96');
   if(direction<0) return(C'255,0,220');
   return(C'225,230,240');
  }

string SSV5_PanelSettingPrice(const double value)
  {
   if(value<=0.0) return("OFF");
   return("$"+DoubleToString(value,2));
  }

string SSV5_PanelExitOwnership()
  {
   string stopOwner=(SSV5_g_manualSLOverride ? "MANUAL SL" :
                       (SSV5_StopLoss_PriceUSD>0.0 ? "EA SL" :
                        ((SSV5_LockTrigger_PriceUSD>0.0 || SSV5_TrailingStart_PriceUSD>0.0) ?
                         "PROFIT SL" : "SL OFF")));
   string targetOwner=(SSV5_g_manualTPOverride ? "MANUAL TP" :
                       (SSV5_TakeProfit_PriceUSD>0.0 ? "EA TP" : "TP OFF"));
   return(stopOwner+" + "+targetOwner);
  }

void SSV5_ShowWaitingStatus()
  {
   if(ObjectFind(0,SSV5_PANEL_PREFIX+"Background")<0) SSV5_CreateStatusPanel();
   PanelSetText("StatusMessage","WAITING FOR M1/M5/M30 HISTORY",SSV5_PANEL_LABEL_X,92,C'255,218,0',11);
   PanelSetText("DirectionValue","NONE",SSV5_PANEL_VALUE_X,117,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   string entryLimit=(SSV5_MaximumTradesPerBrokerDay>0 ? IntegerToString(SSV5_MaximumTradesPerBrokerDay) : "UNCAPPED");
   PanelSetText("EntriesValue",IntegerToString(SSV5_EntriesToday())+" / "+entryLimit,
                SSV5_PANEL_VALUE_X,137,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("TimeValue",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),SSV5_PANEL_VALUE_X,293,C'255,218,0',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("PriceValue",DoubleToString(Bid,Digits)+" / "+DoubleToString(Ask,Digits),
                SSV5_PANEL_VALUE_X,311,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("Benchmark","THESIS  DISARMED  |  RESEARCH HEALTH WAITING",SSV5_PANEL_LABEL_X,358,C'255,168,32',8);
   ChartRedraw(0);
  }

void SSV5_ShowStatus(const bool force=false)
  {
   uint now=GetTickCount();
   if(!force && SSV5_g_lastPanelRenderMs>0 && now-SSV5_g_lastPanelRenderMs<250) return;
   SSV5_g_lastPanelRenderMs=now;
   if(ObjectFind(0,SSV5_PANEL_PREFIX+"Background")<0) SSV5_CreateStatusPanel();

   int displayDirection=(SSV5_g_state==SSV5_STATE_ACTIVE || SSV5_g_state==SSV5_STATE_EXITING ? SSV5_g_activeDirection : SSV5_g_candidateDirection);
   color directionColor=SSV5_PanelDirectionColor(displayDirection);

   PanelSetText("StatusMessage",SSV5_PanelStateMessage(),SSV5_PANEL_LABEL_X,92,SSV5_PanelStateColor(),11);
   PanelSetText("DirectionValue",SSV5_DirectionName(displayDirection),SSV5_PANEL_VALUE_X,117,directionColor,9,ANCHOR_RIGHT_UPPER);
   string entryLimit=(SSV5_MaximumTradesPerBrokerDay>0 ? IntegerToString(SSV5_MaximumTradesPerBrokerDay) : "UNCAPPED");
   PanelSetText("EntriesValue",IntegerToString(SSV5_EntriesToday())+" / "+entryLimit,
                SSV5_PANEL_VALUE_X,137,C'225,230,240',9,ANCHOR_RIGHT_UPPER);

   PanelSetText("LotsValue","FIXED / "+DoubleToString(SSV5_CalculateEntryLots(),2),
                 SSV5_PANEL_VALUE_X,177,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("StopsValue",SSV5_PanelSettingPrice(SSV5_StopLoss_PriceUSD)+" / "+SSV5_PanelSettingPrice(SSV5_TakeProfit_PriceUSD),
                SSV5_PANEL_VALUE_X,195,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("LockValue",SSV5_PanelSettingPrice(SSV5_LockTrigger_PriceUSD)+" / "+SSV5_PanelSettingPrice(SSV5_LockedProfit_PriceUSD),
                SSV5_PANEL_VALUE_X,213,(SSV5_LockTrigger_PriceUSD>0.0 ? C'0,230,96' : C'225,230,240'),9,ANCHOR_RIGHT_UPPER);
   PanelSetText("TrailValue",SSV5_PanelSettingPrice(SSV5_TrailingStart_PriceUSD)+" / "+SSV5_PanelSettingPrice(SSV5_TrailingDistance_PriceUSD),
                SSV5_PANEL_VALUE_X,231,(SSV5_TrailingStart_PriceUSD>0.0 && SSV5_TrailingDistance_PriceUSD>0.0 ? C'0,230,96' : C'225,230,240'),9,ANCHOR_RIGHT_UPPER);
   PanelSetText("OwnershipValue",SSV5_PanelExitOwnership(),SSV5_PANEL_VALUE_X,249,
                (SSV5_g_manualSLOverride || SSV5_g_manualTPOverride ? C'255,218,0' : C'225,230,240'),9,ANCHOR_RIGHT_UPPER);

   string tradingPermission=(IsTradeAllowed() ? "ENABLED" : "DISABLED");
   color permissionColor=(IsTradeAllowed() ? C'0,230,96' : C'255,168,32');
   double spreadPrice=MathMax(0.0,Ask-Bid);
   double spreadPoints=(Point>0.0 ? spreadPrice/Point : 0.0);
   PanelSetText("TimeValue",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),SSV5_PANEL_VALUE_X,293,C'255,218,0',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("PriceValue",DoubleToString(Bid,Digits)+" / "+DoubleToString(Ask,Digits),
                SSV5_PANEL_VALUE_X,311,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("SpreadValue","$"+DoubleToString(spreadPrice,Digits)+" ("+DoubleToString(spreadPoints,0)+" pts) / "+tradingPermission,
                SSV5_PANEL_VALUE_X,329,permissionColor,8,ANCHOR_RIGHT_UPPER);
   string researchHealth=SSV5_ResearchDriftName(SSV5_g_market.researchDriftScore);
   color researchColor=(researchHealth=="DEGRADED" ? C'255,0,220' :
                        (researchHealth=="SUSPECTED" ? C'255,168,32' :
                         (researchHealth=="WATCH" ? C'255,218,0' : C'0,230,96')));
   string thesisSummary="THESIS "+SSV5_DirectionName(SSV5_g_thesisDirection)+" "+
                        IntegerToString(SSV5_g_thesisEntries)+"/"+
                        IntegerToString(SSV5_MAX_ENTRIES_PER_THESIS)+" "+SSV5_ThesisPhaseName();
   color thesisColor=(SSV5_g_thesisLocked ? C'255,168,32' : researchColor);
   PanelSetText("Benchmark",thesisSummary+"  |  HEALTH "+researchHealth,
                SSV5_PANEL_LABEL_X,358,thesisColor,8);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| MT4 event handlers                                                |
//+------------------------------------------------------------------+
int SSV5_OnInit()
  {
   string inputError="";
   if(!SSV5_ValidateUserInputs(inputError))
     {
       Print("XVISION SuperScalper: invalid input configuration - ",inputError);
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(!SSV5_AcquireInstanceLease())
     {
       Print("XVISION SuperScalper: another instance already owns account=",AccountNumber(),
            " symbol=",Symbol(),". Only one instance per account and symbol is permitted.");
      return(INIT_FAILED);
     }

   SSV5_ResetTesterPersistence();
   SSV5_InitializeResearchLayer();
   SSV5_InitializeCalibration();
   SSV5_ClearDirectionTracker(SSV5_g_trackerUp);
   SSV5_ClearDirectionTracker(SSV5_g_trackerDown);
   SSV5_ResetModeProbabilities();
   SSV5_ResetVelocitySnapshot();
   SSV5_g_lastClosedM1=iTime(Symbol(),PERIOD_M1,1);
   SSV5_g_reconfiguredInputs=(SSV5_ReadPersistent("Reconfigure",0.0)>0.5);
   SSV5_DeletePersistent("Reconfigure");

   if(SSV5_HasSufficientData())
     {
      SSV5_ComputeMarketSnapshot(false);
      SSV5_ComputeVelocitySnapshot(1);
     }
   SSV5_InitializeThesisState();
   int ticket=SSV5_FindOpenEAOrder();
   if(ticket>0)
     {
      SSV5_RecoverActiveTrade(ticket);
     }
   else
     {
      if(SSV5_HasSufficientData())
        {
         SSV5_UpdateDirectionalTrackers(false);
         SSV5_UpdateThesisRearmState();
        }
      SSV5_ResetForFreshCycle();
     }
   SSV5_ReconcileRecoveredQualifiedResearch();
   if(SSV5_g_reconfiguredInputs && SSV5_g_activeTicket>0) SSV5_ApplyInputExits();

   SSV5_EntriesToday();
   SSV5_CreateStatusPanel();
   if(SSV5_HasSufficientData()) SSV5_ShowStatus(true);
   else SSV5_ShowWaitingStatus();
   if(!EventSetTimer(1))
      Print("XVISION SuperScalper: one-second timer could not be started; tick events remain active.");
   Print("XVISION Gold SuperScalper V5.00 initialized symbol=",Symbol(),
         " M1/M5 signals with M30 volatility scaling; optional broker SL; clean execution active.");
   return(INIT_SUCCEEDED);
  }

void SSV5_OnDeinit(const int reason)
  {
   if(SSV5_g_instanceLeaseHeld && reason==REASON_PARAMETERS)
     {
      SSV5_WritePersistent("Reconfigure",1.0);
      GlobalVariablesFlush();
     }
   if(SSV5_g_instanceLeaseHeld)
     {
      SSV5_PersistActiveTrade();
      SSV5_PersistResearchLayer();
      SSV5_PersistThesisState();
     }
   SSV5_ReleaseInstanceLease();
   EventKillTimer();
   SSV5_DeleteStatusPanel();
   Comment("");
  }

void SSV5_OnTick()
  {
   SSV5_HeartbeatInstanceLease();
   if(!SSV5_g_instanceLeaseHeld) return;
   SSV5_SuperviseActiveLifecycle();
   if(SSV5_g_finalizeHistoryFailures>0)
     {
      SSV5_ShowStatus();
      return;
     }
   SSV5_UpdateResearchLayer();
   if(!SSV5_HasSufficientData())
     {
      SSV5_ShowWaitingStatus();
      return;
     }
   SSV5_ProcessNewClosedM1Bar();
   if(SSV5_g_state==SSV5_STATE_ACQUIRED) SSV5_TryOpenAcquiredTrack();
   SSV5_ShowStatus();
  }

void SSV5_OnTimer()
  {
   SSV5_HeartbeatInstanceLease();
   if(!SSV5_g_instanceLeaseHeld) return;
   RefreshRates();
   SSV5_SuperviseActiveLifecycle();
   if(SSV5_g_finalizeHistoryFailures>0)
     {
      SSV5_ShowStatus();
      return;
     }
   SSV5_UpdateResearchLayer();
   if(!SSV5_HasSufficientData())
     {
      SSV5_ShowWaitingStatus();
      return;
     }
   if(SSV5_g_state==SSV5_STATE_ACQUIRED) SSV5_TryOpenAcquiredTrack();
   SSV5_ShowStatus();
  }

//+------------------------------------------------------------------+
//| Consolidated event router                                        |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(ActiveEngine==XVISION_SUPERSCALPER_V5) return(SSV5_OnInit());
   return(GSV11_OnInit());
  }
void OnDeinit(const int reason)
  {
   if(ActiveEngine==XVISION_SUPERSCALPER_V5) SSV5_OnDeinit(reason);
   else GSV11_OnDeinit(reason);
  }
void OnTick()
  {
   if(ActiveEngine==XVISION_SUPERSCALPER_V5) SSV5_OnTick();
   else GSV11_OnTick();
  }
void OnTimer()
  {
   if(ActiveEngine==XVISION_SUPERSCALPER_V5) SSV5_OnTimer();
   else GSV11_OnTimer();
  }
//+------------------------------------------------------------------+