//+------------------------------------------------------------------+
//| supergold.mq4                                                    |
//|                                                                  |
//| ONE expert advisor with two signal modules. Both run on every    |
//| tick; neither is an alternative to the other.                    |
//|                                                                  |
//|   Scalper module   M1 trigger with M5 context, five-mode regime  |
//|                    router, CUSUM burst detector, momentum and    |
//|                    fade entries, blackout schedules, daily cap,  |
//|                    consecutive-loss pause, ledger and dataset.   |
//|                    Magic 26082601.                                |
//|                                                                  |
//|   EMA20 module     EMA20 crossing on a configurable signal        |
//|                    timeframe, with instant-cross entry, one-bar  |
//|                    confirmation entry and a first-retest pending  |
//|                    order route. Magic 50503006.                   |
//|                                                                  |
//| EnableScalperModule and EnableEMA20Module switch a module OFF.   |
//| They do not choose between two experts - there is no longer an   |
//| ActiveEngine input and no engine enum.                           |
//|                                                                  |
//| HOW THE TWO COEXIST                                              |
//| Each module keeps its own entry rules, its own trade management, |
//| its own persistence keys and its own magic number, and each      |
//| touches only orders carrying its own magic. Nothing was merged   |
//| away to make them fit: both keep their separate lot sizing, stop |
//| arithmetic, slippage handling and panel, because their stop and  |
//| target semantics genuinely differ - the scalper works in absolute|
//| gold price, the EMA20 module in account currency.                |
//|                                                                  |
//| Two consequences follow, and both are handled explicitly:        |
//|                                                                  |
//|  1. EXPOSURE ADDS UP. With both modules on, both can hold a      |
//|     position at once - two positions in gold, two lots of risk.  |
//|     OnePositionAcrossModules caps the EA at one open position    |
//|     across both. It defaults to OFF, because ON would change     |
//|     each module's behaviour from what it does alone.             |
//|                                                                  |
//|  2. THE PANELS OVERLAP. The scalper panel is 430 wide at (10,14) |
//|     and the EMA20 panel defaults to (12,24). When both modules   |
//|     are live the EMA20 panel is nudged clear of the scalper's,   |
//|     unless DashboardX already places it past that edge.          |
//|                                                                  |
//| LIFECYCLE                                                        |
//| OnInit never returns a non-zero value. A module that fails to    |
//| initialise is marked not-ready and skipped for the session while |
//| the other keeps running; in MT4 a non-zero return removes the    |
//| expert from the chart, and one bad input should not do that.     |
//| Only the scalper installs a timer, so OnTimer drives it alone.   |
//|                                                                  |
//| NO SPEED OR ACCELERATION LOGIC REMAINS                           |
//| SuperScalper v5 was removed entirely: its entry decision WAS its |
//| velocity snapshot, so stripped of motion it could never trade.   |
//| The scalper lost its two velocity filters and the speed/accel    |
//| terms in its regime classifier; its M1/M5 composites stay, being |
//| directional displacement rather than speed readings. The EMA20   |
//| module lost MinimumDirectionalVelocity and its five gate sites,  |
//| having already lost acceleration in v12. Crossings now qualify   |
//| on gradient and range votes alone.                                |
//|                                                                  |
//| Why: over 3,239 EMA20 crossings on two years of M30 gold,        |
//| velocity's top decile scored 41.6% on +$5 before -$5 against a   |
//| 44.0-53.1% random band - below random - and its sign agreed with |
//| the next bar 48.8% of the time.                                  |
//|                                                                  |
//| The EMA20 module is v12: v10 plus three audit fixes (a retest    |
//| engine that could never arm, an instant-cross path that blacked  |
//| itself out for four bars, and a retry interval clampable to zero)|
//| plus the acceleration removal. Its identifiers carry an EMA20_   |
//| prefix and the scalper's a GSV11_ prefix; input NAMES are        |
//| unchanged so existing .set files still load.                     |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "XVISION Consolidated Scraper V2: complete Version 11 and SuperScalper v5 engines."

//--- Modules ---------------------------------------------------------------
// Both modules are part of one EA and both run on every tick. These switches
// turn a module off; they do NOT select between two experts. With both on, the
// scalper works M1/M5 while the EMA20 module works its own signal timeframe,
// and each manages only the orders carrying its own magic number.
input bool   EnableScalperModule        = true;  // GoldScalper M1/M5 signal module
input bool   EnableEMA20Module          = true;  // EMA20 crossing / retest module

// Each module keeps its own exposure rules, so by default they can hold a
// position at the same time - that is two positions in gold, and the risk adds
// up. Turn this on to allow only one open position across the whole EA,
// whichever module gets there first.
input bool   OnePositionAcrossModules   = false; // one position for the whole EA

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
input double GSV11_MinM1Coherence            = 0.50;  // fraction of M1 windows agreeing; 0 = off [0.75]
input bool   GSV11_RequireBarBodyAligned     = true;  // trigger bar must close in the signal direction
input double GSV11_MaxBarSizeATR             = 0.00;  // reject bars over N x ATR; 0 = off [2.00]
input double GSV11_MaxMoveMaturityATR        = 0.00;  // reject moves N x M5 ATR old; 0 = off [1.50]
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
double   GSV11_g_m1Comp=0.0, GSV11_g_m5Comp=0.0;   // m1CompPrev fed the removed accel term
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
   // The speed term (weighted magnitude of the M1/M5 composites) and the accel
   // term (their one-bar change) were removed here. The composites themselves
   // stay: they are ATR-normalised DIRECTIONAL displacement, and 'eff' and
   // 'agree' below read their direction, not their magnitude. Only the two
   // magnitude readings are gone.
   double eff=MathAbs(GSV11_g_er);
   double agree=((GSV11_g_m1Comp*GSV11_g_m5Comp)>0.0 ? 1.0 : -1.0)*
                MathMin(MathAbs(GSV11_g_m1Comp),MathAbs(GSV11_g_m5Comp));
   double lastRet=iClose(Symbol(),PERIOD_M1,1)-iClose(Symbol(),PERIOD_M1,2);
   double lastZ=lastRet/GSV11_ReturnSigmaM1(1);

   double ll[5];
   ArrayInitialize(ll,0.0);
   ll[0]=1.35*(1.0-eff)-0.25*MathAbs(GSV11_g_expansion-1.0);
   ll[1]=1.20*eff+0.35*MathMax(agree,0.0);
   ll[2]=0.90*eff+0.35*MathMax(GSV11_g_expansion-1.0,0.0);
   ll[3]=0.90*MathMax(-agree,0.0)+0.65*(1.0-eff);
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
   if(SG_ForeignModulePositionOpen(GSV11_MAGIC_NUMBER))
      { blocker="EMA20 module holds the position"; return(false); }

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
   if(GSV11_MaxBarSizeATR<0.0 || GSV11_MaxMoveMaturityATR<0.0 ||
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
         (GSV11_MinM1Coherence>0.0?", coher>="+DoubleToString(GSV11_MinM1Coherence,2):""),
         (GSV11_RequireBarBodyAligned?", body":""),
         (GSV11_MaxBarSizeATR>0.0?", bar<="+DoubleToString(GSV11_MaxBarSizeATR,2)+"xATR":""),
         (GSV11_MaxMoveMaturityATR>0.0?", maturity<="+DoubleToString(GSV11_MaxMoveMaturityATR,2):""),
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

// ================= XVISION EMA20 Directional (v12) =================
#define EMA20_RESEARCH_EMA_PERIOD                 20
#define EMA20_RESEARCH_GRADIENT_LOOKBACK_BARS      2

// Trading controls.
input int                MagicNumber                         = 50503006;
input double             FixedLotSize                        = 0.01;
input bool               EnableBuyTrades                     = true;
input bool               EnableSellTrades                    = true;
input bool               RestrictToGoldSymbols               = true;

// Signal construction. All decisions use completed candles.
input ENUM_TIMEFRAMES    SignalTimeframe                     = PERIOD_M30;
input int                ATR_Period                          = 14;

// EMA20 research qualification. Directional values are automatically
// sign-adjusted: BUY=+1 and SELL=-1, so the same positive minima apply both ways.
input double             MinimumDirectionalGradient         = 0.04;
input int                MaximumRangeVotesForContinuation    = 1;

// Range votes: repeated crossings, flat EMA, and inefficient price path.
input int                RangeLookbackBars                   = 8;
input int                RangeCrossingVoteMinimum            = 3;
input double             FlatGradientThreshold               = 0.02;
input double             MinimumDirectionalEfficiency        = 0.25;

// Delayed market entry after a qualified cross. The crossing candle is
// confirmation close #1; one additional completed close is required.
input double             MaximumMarketEntryDistanceATR       = 0.50;

//--- v10: enter on the crossing candle itself -------------------------
// EnableInstantCrossEntry replaces the one-bar confirmation with a live
// intrabar trigger: the moment price crosses the EMA20 while the closed-
// bar gradient / velocity / range-vote filters qualify,
// the order goes in. The confirmation route is bypassed while it is on.
//
// The trade-off is inherent, not a setting: an intrabar cross can be
// given back before the candle closes, so this takes signals the
// confirmation route would have discarded. That is the price of the
// better entry.
input bool               EnableInstantCrossEntry             = true;
input double             InstantCrossMinPenetrationATR       = 0.02; // price must clear the EMA by this; 0 = any touch
input int                InstantCrossRetrySeconds            = 2;    // gap between re-attempts after a blocked send

// First EMA20 retest route. The sequence must be observed live.
input bool               EnableEMARetestEntry                = true;
input int                RetestTrendClosesRequired           = 3;
input double             RetestMinimumMoveAwayATR            = 0.50;
input double             RetestTouchToleranceATR             = 0.10;
input double             RetestMaximumPenetrationATR          = 0.25;
input double             RetestMinimumRecoveryCloseATR       = 0.10;
input double             RetestMinimumCloseLocationPercent   = 65.0;
input bool               RetestRequireDirectionalBody        = true;
input double             RetestEntryBufferATR                = 0.05;
input int                RetestPendingExpiryBars             = 2;
input bool               RequireServerSidePendingExpiry      = true;
input int                MaximumRetestsPerTrendLeg           = 1;

// Crossing-episode control.
input int                QuietBarsRequiredToRearm            = 4;
input bool               TradeCurrentSignalOnAttach          = false;
input bool               UsePersistentEpisodeState           = true;
input bool               ResetPersistentStateOnInit          = false;

// User-controlled entry volume and optional broker-side protection.
// A zero SL or TP disables that initial level.
input double             StopLossMoney                        = 5.00;
input double             TakeProfitMoney                      = 5.00;
input double             MaximumSpreadMovement               = 0.20;
// Gold routinely travels more than $0.50 between a signal candle's close and the
// next tick, so v6's 0.50 silently rejected a large share of qualified signals.
input double             MaximumEntryDeviationMovement       = 2.00; // 0 disables
input double             MaximumSlippageMovement             = 0.50;

// Optional post-entry management in account currency.
input bool               EnableTrailingStop                  = false;
input double             TrailingStartMoney                  = 5.00;
input double             TrailingDistanceMoney               = 2.00;
input double             TrailingStepMoney                   = 0.50;
input bool               EnableProfitLock                    = false;
input double             ProfitLockTriggerMoney              = 5.00;
input double             ProfitLockMoney                     = 1.00;

// Diagnostics and standardized opaque dashboard.
input bool               ShowDashboard                        = true;
input bool               PrintSignalDiagnostics               = true;
input ENUM_BASE_CORNER   DashboardCorner                     = CORNER_LEFT_UPPER;
input int                DashboardX                          = 12;
input int                DashboardY                          = 24;
input int                DashboardWidth                      = 430;
input int                DashboardHeight                     = 472;
input int                DashboardFontSize                   = 10;
input int                DashboardRefreshMs                  = 250; // 0 = every tick
input color              DashboardBackground                = C'8,14,25';
input color              DashboardBorder                    = C'66,82,105';
input color              DashboardText                      = clrWhite;
input color              DashboardHeading                   = C'73,170,255';
input color              DashboardAccent                    = clrGold;

datetime EMA20_g_lastProcessedBar=0;
datetime EMA20_g_lastSignalBar=0;
bool     EMA20_g_episodeLocked=false;
int      EMA20_g_quietBars=0;
string   EMA20_g_lastDecision="Waiting for the first completed signal candle";
double   EMA20_g_lastSlope=0.0;
double   EMA20_g_lastDirectionalGradient=0.0;
double   EMA20_g_lastEfficiency=0.0;
int      EMA20_g_lastRangeVotes=0;
double   EMA20_g_currentSlope=0.0;
double   EMA20_g_currentEfficiency=0.0;
int      EMA20_g_currentRangeVotes=0;
// v6 left the three g_current* values holding the PREVIOUS bar's numbers when
// EMA20_UpdateCurrentDiagnostics() bailed out, and then gated live entries on them.
bool     EMA20_g_diagnosticsValid=false;
// The retest pending order is tracked by ticket. v6 identified it by order
// comment, which brokers rewrite, orphaning the order and allowing a duplicate.
int      EMA20_g_retestTicket=0;
enum EMA20_ENUM_RETEST_STATE
  {
   EMA20_RETEST_IDLE=0,
   EMA20_RETEST_WAIT_MOVE=1,
   EMA20_RETEST_ARMED=2,
   EMA20_RETEST_PENDING=3,
   EMA20_RETEST_USED=4
  };

enum EMA20_ENUM_MARKET_ENTRY_ROUTE
  {
   EMA20_MARKET_ROUTE_NONE=0,
   EMA20_MARKET_ROUTE_RESEARCH=1
  };

int      EMA20_g_retestState=EMA20_RETEST_IDLE;
int      EMA20_g_retestDirection=0;
int      EMA20_g_retestCount=0;
datetime EMA20_g_retestSignalBar=0;
string   EMA20_g_retestStatus="Waiting for a live EMA crossing";
string   EMA20_g_dashboardPrefix="XVE9_PANEL_";
datetime EMA20_g_lastManagementErrorPrint=0;
#define EMA20_PENDING_DELETE_RETRY_SECONDS 5
datetime EMA20_g_lastPendingDeleteAttempt=0;

// Resolved (clamped) dashboard geometry. The inputs themselves are read-only,
// and a cosmetic value must never be able to unload a trading EA, so every
// panel dimension is validated into these instead of rejected.
int      EMA20_g_panelX=12;
int      EMA20_g_panelY=24;
int      EMA20_g_panelWidth=430;
int      EMA20_g_panelHeight=472;
int      EMA20_g_panelFont=10;
double   EMA20_g_panelScale=1.0;      // v6's layout was hand-placed for font size 10
int      EMA20_g_panelRefreshMs=250;
uint     EMA20_g_lastPanelRefresh=0;
bool     EMA20_g_panelBuilt=false;
bool     EMA20_g_panelChanged=false;

// Resolved (clamped) trading inputs. Every tunable value is read from these
// rather than from the input variables directly, so that a value which cannot
// be used is repaired and reported instead of unloading the EA.
int      EMA20_g_magic=50503006;
double   EMA20_g_fixedLot=0.01;
int      EMA20_g_atrPeriod=14;
double   EMA20_g_minDirectionalGradient=0.04;
int      EMA20_g_maxRangeVotes=1;
int      EMA20_g_rangeLookback=8;
int      EMA20_g_rangeCrossVoteMin=3;
double   EMA20_g_flatGradientThreshold=0.02;
double   EMA20_g_minEfficiency=0.25;
double   EMA20_g_maxMarketEntryDistanceATR=0.50;
bool     EMA20_g_enableInstantCross=true;
double   EMA20_g_instantMinPenATR=0.02;
int      EMA20_g_instantRetrySeconds=2;
datetime EMA20_g_instantNextAttempt=0;
bool     EMA20_g_enableRetest=true;
int      EMA20_g_retestTrendCloses=3;
double   EMA20_g_retestMinMoveAwayATR=0.50;
double   EMA20_g_retestTouchTolATR=0.10;
double   EMA20_g_retestMaxPenetrationATR=0.25;
double   EMA20_g_retestMinRecoveryATR=0.10;
double   EMA20_g_retestMinCloseLocPct=65.0;
double   EMA20_g_retestEntryBufferATR=0.05;
int      EMA20_g_retestExpiryBars=2;
int      EMA20_g_maxRetestsPerLeg=1;
int      EMA20_g_quietBarsRequired=4;
double   EMA20_g_stopLossMoney=5.00;
double   EMA20_g_takeProfitMoney=5.00;
double   EMA20_g_maxSpread=0.20;
double   EMA20_g_maxEntryDeviation=2.00;
double   EMA20_g_maxSlippage=0.50;
bool     EMA20_g_enableTrailing=false;
double   EMA20_g_trailStart=5.00;
double   EMA20_g_trailDistance=2.00;
double   EMA20_g_trailStep=0.50;
bool     EMA20_g_enableProfitLock=false;
double   EMA20_g_lockTrigger=5.00;
double   EMA20_g_lockMoney=1.00;

// Set when the EA cannot trade at all but must stay on the chart anyway.
bool     EMA20_g_tradingBlocked=false;
string   EMA20_g_blockReason="";

// One-bar delayed market-entry state. Route: 1=continuation, 2=reversal.
bool     EMA20_g_marketEntryPending=false;
int      EMA20_g_marketEntryDirection=0;
int      EMA20_g_marketEntryRoute=0;
datetime EMA20_g_marketEntrySignalBar=0;

//+------------------------------------------------------------------+
//| Initialization.                                                  |
//+------------------------------------------------------------------+
int EMA20_OnInit()
  {
   // Nothing below may return a non-zero value. See EMA20_ResolveInputs().
   EMA20_ResolveDashboardGeometry();
   EMA20_ResolveInputs();
   EMA20_g_panelBuilt=false;

   EMA20_LoadEpisodeState();
   EMA20_RecoverRetestOrderState();
   if(EMA20_HasActiveRetestPending())
     {
      EMA20_g_marketEntryPending=false;
      EMA20_g_marketEntryDirection=0;
      EMA20_g_marketEntryRoute=EMA20_MARKET_ROUTE_NONE;
      EMA20_g_marketEntrySignalBar=0;
     }
   if(EMA20_HasEAExposure())
      EMA20_g_episodeLocked=true;
   EMA20_SaveEpisodeState();

   EMA20_UpdateDashboard(true);
   Print("XVISION EMA20 V12 initialized on ",Symbol(),
         " timeframe=",EMA20_TimeframeName(SignalTimeframe),
         " magic=",EMA20_g_magic,
         " locked=",EMA20_BoolText(EMA20_g_episodeLocked),
         " quietBars=",EMA20_g_quietBars,
         " trading=",(EMA20_g_tradingBlocked ? "BLOCKED ("+EMA20_g_blockReason+")" : "enabled"));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinitialization.                                                |
//+------------------------------------------------------------------+
void EMA20_OnDeinit(const int reason)
  {
   EMA20_SaveEpisodeState();
   EMA20_DeleteDashboard();
  }

//+------------------------------------------------------------------+
//| Tick handler.                                                    |
//+------------------------------------------------------------------+
void EMA20_OnTick()
  {
   EMA20_ManageRetestOrders();
   EMA20_ManageInputProtection();
   EMA20_ProcessNewSignalBar();      // bar-close work first: refreshes diagnostics
   EMA20_ProcessInstantCrossEntry(); // then the live cross, using those diagnostics
   EMA20_UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Resolve every tunable input into a usable value.                 |
//|                                                                  |
//| THE RULE: EMA20_OnInit() must never return a non-zero value. In MT4    |
//| that removes the expert from the chart, and because EMA20_OnDeinit()   |
//| has already deleted the panel, the EA simply vanishes -- which   |
//| is indistinguishable from a crash.                               |
//|                                                                  |
//| v6 rejected fourteen separate input combinations this way, most  |
//| of them values a reasonable person would type: four range votes, |
//| an efficiency entered as a percentage, two required retest       |
//| closes, a profit lock equal to its trigger. Every one of them is |
//| repairable, so every one of them is now clamped and reported.    |
//|                                                                  |
//| Only two states are genuinely unusable, and neither detaches:    |
//| a non-gold symbol under RestrictToGoldSymbols, and a broken lot  |
//| grid. Both set EMA20_g_tradingBlocked, which stops orders and says so  |
//| on the dashboard instead of unloading the EA.                    |
//+------------------------------------------------------------------+
void EMA20_ClampInt(const string name,const int requested,const int low,
              const int high,int &target)
  {
   target=(int)MathMax(low,MathMin(high,requested));
   if(target!=requested)
      Print("XVISION EMA20 V12: ",name," ",requested," clamped to ",target,".");
  }

void EMA20_ClampDouble(const string name,const double requested,const double low,
                 const double high,double &target)
  {
   target=MathMax(low,MathMin(high,requested));
   if(MathAbs(target-requested)>1.0e-12)
      Print("XVISION EMA20 V12: ",name," ",DoubleToString(requested,4),
            " clamped to ",DoubleToString(target,4),".");
  }

void EMA20_ResolveInputs()
  {
   EMA20_g_tradingBlocked=false;
   EMA20_g_blockReason="";

   EMA20_ClampInt("MagicNumber",MagicNumber,1,2147483647,EMA20_g_magic);
   EMA20_ClampInt("ATR_Period",ATR_Period,2,10000,EMA20_g_atrPeriod);
   EMA20_ClampInt("RangeLookbackBars",RangeLookbackBars,2,10000,EMA20_g_rangeLookback);

   // Coupled: the vote threshold cannot exceed the window it counts within.
   EMA20_ClampInt("RangeCrossingVoteMinimum",RangeCrossingVoteMinimum,1,
            EMA20_g_rangeLookback,EMA20_g_rangeCrossVoteMin);
   EMA20_ClampInt("MaximumRangeVotesForContinuation",MaximumRangeVotesForContinuation,
            0,3,EMA20_g_maxRangeVotes);

   EMA20_ClampDouble("MinimumDirectionalGradient",MinimumDirectionalGradient,
               0.0,1000.0,EMA20_g_minDirectionalGradient);
   EMA20_ClampDouble("FlatGradientThreshold",FlatGradientThreshold,0.0,1000.0,
               EMA20_g_flatGradientThreshold);
   // An efficiency is a ratio; typing it as a percentage is the obvious slip.
   EMA20_ClampDouble("MinimumDirectionalEfficiency",MinimumDirectionalEfficiency,
               0.0,1.0,EMA20_g_minEfficiency);

   EMA20_ClampDouble("MaximumMarketEntryDistanceATR",MaximumMarketEntryDistanceATR,
               0.0,1000.0,EMA20_g_maxMarketEntryDistanceATR);

   EMA20_g_enableInstantCross=EnableInstantCrossEntry;
   EMA20_ClampDouble("InstantCrossMinPenetrationATR",InstantCrossMinPenetrationATR,
               0.0,1000.0,EMA20_g_instantMinPenATR);
   // Minimum 1: at 0 the backoff expires the instant it is set, so a persistently
   // failing send (bad stops, no margin) is retried on EVERY tick.
   EMA20_ClampInt("InstantCrossRetrySeconds",InstantCrossRetrySeconds,
            1,3600,EMA20_g_instantRetrySeconds);

   EMA20_g_enableRetest=EnableEMARetestEntry;
   EMA20_ClampInt("RetestTrendClosesRequired",RetestTrendClosesRequired,2,10000,
            EMA20_g_retestTrendCloses);
   EMA20_ClampDouble("RetestMinimumMoveAwayATR",RetestMinimumMoveAwayATR,0.0,1000.0,
               EMA20_g_retestMinMoveAwayATR);
   EMA20_ClampDouble("RetestTouchToleranceATR",RetestTouchToleranceATR,0.0,1000.0,
               EMA20_g_retestTouchTolATR);
   EMA20_ClampDouble("RetestMaximumPenetrationATR",RetestMaximumPenetrationATR,0.0,1000.0,
               EMA20_g_retestMaxPenetrationATR);
   EMA20_ClampDouble("RetestMinimumRecoveryCloseATR",RetestMinimumRecoveryCloseATR,
               0.0,1000.0,EMA20_g_retestMinRecoveryATR);
   EMA20_ClampDouble("RetestMinimumCloseLocationPercent",RetestMinimumCloseLocationPercent,
               50.0,100.0,EMA20_g_retestMinCloseLocPct);
   EMA20_ClampDouble("RetestEntryBufferATR",RetestEntryBufferATR,0.0,1000.0,
               EMA20_g_retestEntryBufferATR);
   EMA20_ClampInt("RetestPendingExpiryBars",RetestPendingExpiryBars,1,10000,
            EMA20_g_retestExpiryBars);
   EMA20_ClampInt("MaximumRetestsPerTrendLeg",MaximumRetestsPerTrendLeg,1,100,
            EMA20_g_maxRetestsPerLeg);

   EMA20_ClampInt("QuietBarsRequiredToRearm",QuietBarsRequiredToRearm,1,10000,
            EMA20_g_quietBarsRequired);

   EMA20_ClampDouble("StopLossMoney",StopLossMoney,0.0,1.0e9,EMA20_g_stopLossMoney);
   EMA20_ClampDouble("TakeProfitMoney",TakeProfitMoney,0.0,1.0e9,EMA20_g_takeProfitMoney);
   EMA20_ClampDouble("MaximumSpreadMovement",MaximumSpreadMovement,0.0,1.0e9,EMA20_g_maxSpread);
   EMA20_ClampDouble("MaximumEntryDeviationMovement",MaximumEntryDeviationMovement,
               0.0,1.0e9,EMA20_g_maxEntryDeviation);
   EMA20_ClampDouble("MaximumSlippageMovement",MaximumSlippageMovement,0.0,1.0e9,
               EMA20_g_maxSlippage);

   // Trailing with a zero distance would park the stop on the current price and
   // close the trade immediately. There is no safe value to invent, so the
   // feature switches itself off rather than acting on a nonsensical setting.
   EMA20_g_enableTrailing=EnableTrailingStop;
   EMA20_ClampDouble("TrailingStartMoney",TrailingStartMoney,0.0,1.0e9,EMA20_g_trailStart);
   EMA20_ClampDouble("TrailingStepMoney",TrailingStepMoney,0.0,1.0e9,EMA20_g_trailStep);
   EMA20_g_trailDistance=TrailingDistanceMoney;
   if(EMA20_g_enableTrailing && EMA20_g_trailDistance<=0.0)
     {
      EMA20_g_enableTrailing=false;
      Print("XVISION EMA20 V12: TrailingDistanceMoney must be positive; "
            "trailing stop disabled for this session. Trading continues.");
     }

   // Locking at or above the trigger can never fire. Pull the lock under the
   // trigger rather than discarding the user's intent entirely.
   EMA20_g_enableProfitLock=EnableProfitLock;
   EMA20_ClampDouble("ProfitLockTriggerMoney",ProfitLockTriggerMoney,0.0,1.0e9,EMA20_g_lockTrigger);
   EMA20_ClampDouble("ProfitLockMoney",ProfitLockMoney,0.0,1.0e9,EMA20_g_lockMoney);
   if(EMA20_g_enableProfitLock && EMA20_g_lockTrigger<=0.0)
     {
      EMA20_g_enableProfitLock=false;
      Print("XVISION EMA20 V12: ProfitLockTriggerMoney must be positive; "
            "profit lock disabled for this session. Trading continues.");
     }
   else if(EMA20_g_enableProfitLock && EMA20_g_lockMoney>=EMA20_g_lockTrigger)
     {
      double reduced=EMA20_g_lockTrigger*0.5;
      Print("XVISION EMA20 V12: ProfitLockMoney ",DoubleToString(EMA20_g_lockMoney,2),
            " is not below its trigger ",DoubleToString(EMA20_g_lockTrigger,2),
            "; reduced to ",DoubleToString(reduced,2),".");
      EMA20_g_lockMoney=reduced;
     }

   // Lot size is the one number the EA cannot invent on the user's behalf,
   // but an unusable value blocks trading rather than unloading the EA.
   EMA20_g_fixedLot=FixedLotSize;
   double probe=0.0;
   if(EMA20_g_fixedLot<=0.0 || !EMA20_ResolveLotSize(EMA20_g_fixedLot,probe))
     {
      EMA20_g_tradingBlocked=true;
      EMA20_g_blockReason="FixedLotSize "+DoubleToString(FixedLotSize,4)+
                    " is not tradeable on this symbol";
      Print("XVISION EMA20 V12: ",EMA20_g_blockReason,
            " (min ",DoubleToString(MarketInfo(Symbol(),MODE_MINLOT),4),
            ", step ",DoubleToString(MarketInfo(Symbol(),MODE_LOTSTEP),4),
            "). The EA stays attached and will not trade until this is fixed.");
     }

   if(RestrictToGoldSymbols && !EMA20_IsGoldSymbol())
     {
      EMA20_g_tradingBlocked=true;
      EMA20_g_blockReason="RestrictToGoldSymbols is on and "+Symbol()+" is not a GOLD/XAU symbol";
      Print("XVISION EMA20 V12: ",EMA20_g_blockReason,
            ". The EA stays attached and will not trade.");
     }
  }

//+------------------------------------------------------------------+
//| Clamp the cosmetic inputs into usable values and report any      |
//| adjustment. Never fails: a panel setting cannot stop trading.    |
//+------------------------------------------------------------------+
void EMA20_ResolveDashboardGeometry()
  {
   EMA20_g_panelFont  =(int)MathMax(6,MathMin(24,DashboardFontSize));
   EMA20_g_panelScale =EMA20_g_panelFont/10.0;
   EMA20_g_panelX     =(int)MathMax(0,DashboardX);
   EMA20_g_panelY     =(int)MathMax(0,DashboardY);

   // Both modules draw a panel and both default to roughly the same corner:
   // the scalper sits at (10,14) and is 430 wide, this one at (12,24). When
   // both are live, shift this panel clear of it instead of stacking two
   // unreadable overlays. Moving DashboardX past the scalper panel yourself
   // disables the nudge.
   if(EnableScalperModule && EnableEMA20Module)
     {
      int clearOf=GSV11_PANEL_LEFT+GSV11_PANEL_WIDTH+12;
      if(EMA20_g_panelX<clearOf)
        {
         EMA20_g_panelX=clearOf;
         Print("SUPERGOLD: EMA20 panel moved to x=",EMA20_g_panelX,
               " so it does not sit on top of the scalper panel.");
        }
     }

   // The tallest hand-placed row sits at y=431; leave room for it plus padding.
   int requiredHeight=EMA20_PanelRow(431)+EMA20_g_panelFont*2+16;
   int requiredWidth =(int)MathMax(200,EMA20_PanelRow(200));

   EMA20_g_panelWidth =(int)MathMax(requiredWidth,DashboardWidth);
   EMA20_g_panelHeight=(int)MathMax(requiredHeight,DashboardHeight);
   EMA20_g_panelRefreshMs=(int)MathMax(0,MathMin(5000,DashboardRefreshMs));

   if(EMA20_g_panelFont!=DashboardFontSize || EMA20_g_panelX!=DashboardX ||
      EMA20_g_panelY!=DashboardY || EMA20_g_panelWidth!=DashboardWidth ||
      EMA20_g_panelHeight!=DashboardHeight || EMA20_g_panelRefreshMs!=DashboardRefreshMs)
      Print("XVISION EMA20 V12: dashboard settings clamped to x=",EMA20_g_panelX,
            " y=",EMA20_g_panelY," w=",EMA20_g_panelWidth," h=",EMA20_g_panelHeight,
            " font=",EMA20_g_panelFont," refresh=",EMA20_g_panelRefreshMs,"ms",
            " (requested w=",DashboardWidth," h=",DashboardHeight,
            " font=",DashboardFontSize,"). Trading is unaffected.");
  }

//+------------------------------------------------------------------+
//| Scale a row offset from v6's font-10 layout to the chosen font.  |
//+------------------------------------------------------------------+
int EMA20_PanelRow(const int baseY)
  {
   return((int)MathRound(baseY*EMA20_g_panelScale));
  }

//+------------------------------------------------------------------+
//| Process exactly once when a new signal-timeframe candle opens.   |
//+------------------------------------------------------------------+
void EMA20_ProcessNewSignalBar()
  {
   datetime currentBar=iTime(Symbol(),SignalTimeframe,0);
   if(currentBar<=0)
      return;

   if(EMA20_g_lastProcessedBar==0)
     {
      EMA20_g_lastProcessedBar=currentBar;
      EMA20_SaveEpisodeState();
      if(!TradeCurrentSignalOnAttach)
         return;
     }
   else if(currentBar==EMA20_g_lastProcessedBar)
      return;

   int barGap=iBarShift(Symbol(),SignalTimeframe,EMA20_g_lastProcessedBar,false);
   if(barGap>1)
     {
      EMA20_g_lastProcessedBar=currentBar;
      EMA20_g_episodeLocked=EMA20_HasEAExposure();
      EMA20_g_quietBars=0;
      EMA20_g_marketEntryPending=false;
      EMA20_g_marketEntryDirection=0;
      EMA20_g_marketEntryRoute=EMA20_MARKET_ROUTE_NONE;
      EMA20_g_marketEntrySignalBar=0;
      if(!EMA20_HasActiveRetestPending())
        {
         EMA20_g_retestState=EMA20_RETEST_IDLE;
         EMA20_g_retestDirection=0;
         EMA20_g_retestCount=0;
         EMA20_g_retestSignalBar=0;
         EMA20_g_retestStatus="Live-data gap detected; retest sequence reset";
        }
      EMA20_g_lastDecision="Historical bars skipped after a live-data gap";
      EMA20_SaveEpisodeState();
      return;
     }

   EMA20_g_lastProcessedBar=currentBar;

   int maximumShift=(int)MathMax(2+EMA20_RESEARCH_GRADIENT_LOOKBACK_BARS,
                                 EMA20_g_rangeLookback+1);
   if(EMA20_g_enableRetest)
      maximumShift=(int)MathMax(maximumShift,EMA20_g_retestTrendCloses);
   int minimumBars=(int)MathMax(EMA20_RESEARCH_EMA_PERIOD+maximumShift+5,EMA20_g_atrPeriod+maximumShift+5);
   if(iBars(Symbol(),SignalTimeframe)<minimumBars)
     {
      EMA20_g_lastDecision="Waiting for sufficient EMA/ATR history";
      EMA20_SaveEpisodeState();
      return;
     }

   // Bar count being sufficient does not mean iMA() is returning values yet;
   // mid-synchronisation it still hands back 0.0, which is exactly the state a
   // chart is in right after a re-initialization.
   if(!EMA20_EMAReady(maximumShift+1))
     {
      EMA20_g_lastDecision="Waiting for the EMA to finish loading on the signal timeframe";
      EMA20_SaveEpisodeState();
      return;
     }

   EMA20_UpdateCurrentDiagnostics();
   if(!EMA20_g_diagnosticsValid)
     {
      EMA20_g_lastDecision="Waiting for usable EMA/ATR values on the signal timeframe";
      EMA20_SaveEpisodeState();
      return;
     }

   int direction=0;
   bool rawCross=EMA20_ClosedBarCross(direction);

   if(EMA20_g_marketEntryPending)
     {
      EMA20_ProcessPendingMarketEntry();
      EMA20_AdvanceEpisodeLock(rawCross,false);
      EMA20_SaveEpisodeState();
      return;
     }

   bool retestConsumed=EMA20_ProcessRetestState(rawCross,direction);
   if(retestConsumed)
     {
      // v6 returned here without touching the quiet counter, so any bar that
      // consumed a retest never counted toward re-arming and the unlock took
      // longer than EMA20_g_quietBarsRequired implies. The retest message is
      // more informative than the lock message, so keep it.
      EMA20_AdvanceEpisodeLock(rawCross,false);
      EMA20_SaveEpisodeState();
      return;
     }

   if(EMA20_g_episodeLocked)
     {
      EMA20_AdvanceEpisodeLock(rawCross,true);
      EMA20_SaveEpisodeState();
      return;
     }

   if(!rawCross)
     {
      EMA20_g_lastDecision="No completed-candle EMA crossing";
      EMA20_SaveEpisodeState();
      return;
     }

   double atr1=iATR(Symbol(),SignalTimeframe,EMA20_g_atrPeriod,1);
   if(atr1<=0.0)
     {
      EMA20_g_lastDecision="Cross rejected: ATR is unavailable";
      EMA20_SaveEpisodeState();
      return;
     }

   double ema1=EMA20_EMAValue(1);
   double emaPast=EMA20_EMAValue(1+EMA20_RESEARCH_GRADIENT_LOOKBACK_BARS);
   if(ema1<=0.0 || emaPast<=0.0)
     {
      EMA20_g_lastDecision="Cross rejected: EMA history is incomplete";
      EMA20_SaveEpisodeState();
      return;
     }
   double close1=iClose(Symbol(),SignalTimeframe,1);

   EMA20_g_lastSlope=EMA20_g_currentSlope;
   EMA20_g_lastDirectionalGradient=direction*EMA20_g_lastSlope;
   double closeDistanceATR=direction*(close1-ema1)/atr1;
   int crossingCount=EMA20_CountRawCrossings(EMA20_g_rangeLookback);
   EMA20_g_lastEfficiency=EMA20_g_currentEfficiency;
   EMA20_g_lastRangeVotes=EMA20_g_currentRangeVotes;

   bool researchSignal=(EMA20_g_lastDirectionalGradient>=EMA20_g_minDirectionalGradient &&
                        EMA20_g_lastRangeVotes<=EMA20_g_maxRangeVotes);

   string route="";
   if(researchSignal)
      route="EMA20_RESEARCH";

   if(PrintSignalDiagnostics)
     {
       Print("XVISION EMA20 V12 cross ",EMA20_DirectionName(direction),
            " time=",TimeToString(iTime(Symbol(),SignalTimeframe,1),TIME_DATE|TIME_MINUTES),
            " gradient=",DoubleToString(EMA20_g_lastDirectionalGradient,4),
            " gapATR=",DoubleToString(closeDistanceATR,3),
            " crossings=",crossingCount,
            " efficiency=",DoubleToString(EMA20_g_lastEfficiency,3),
            " rangeVotes=",EMA20_g_lastRangeVotes,
            " route=",(route=="" ? "REJECT" : route));
     }

   if(route=="")
     {
      EMA20_g_lastDecision="Cross rejected by EMA20 gradient / range rules";
      EMA20_SaveEpisodeState();
      return;
     }

   if((direction>0 && !EnableBuyTrades) || (direction<0 && !EnableSellTrades))
     {
      EMA20_g_lastDecision=EMA20_DirectionName(direction)+" qualified but that direction is disabled";
      EMA20_SaveEpisodeState();
      return;
     }

   if(EMA20_g_enableRetest)
     {
      EMA20_g_retestDirection=direction;
      EMA20_g_retestState=EMA20_RETEST_WAIT_MOVE;
      EMA20_g_retestCount=0;
      EMA20_g_retestSignalBar=iTime(Symbol(),SignalTimeframe,1);
      EMA20_g_retestStatus="Qualified "+EMA20_DirectionName(direction)+
                     " EMA20 leg; waiting for move-away";
     }

   EMA20_g_lastSignalBar=iTime(Symbol(),SignalTimeframe,1);

   if(EMA20_HasEAExposure())
     {
      // Exposure genuinely consumes the leg: lock so the same crossing cluster
      // cannot stack a second order behind the one already open.
      EMA20_g_episodeLocked=true;
      EMA20_g_quietBars=0;
      EMA20_g_lastDecision=route+" qualified but existing EA exposure blocked entry";
      EMA20_g_retestState=EMA20_RETEST_USED;
      EMA20_g_retestStatus="Existing EA exposure consumed this trend leg";
      EMA20_SaveEpisodeState();
      return;
     }

   if(EMA20_g_enableInstantCross)
     {
      // The instant path owns market entries in this mode, and no order was
      // placed on this close. v10 still locked the episode here, which disabled
      // EMA20_ProcessInstantCrossEntry() (it requires !EMA20_g_episodeLocked) for the next
      // EMA20_g_quietBarsRequired bars -- so one crossing the live path happened to
      // miss also blacked out every LATER crossing in that window.
      //
      // Not locking cannot re-fire THIS crossing: the instant test demands
      // close[1] on the old side of the EMA, and this bar has now closed
      // across. Only a genuinely new crossing can trigger it.
      EMA20_g_lastDecision=route+" "+EMA20_DirectionName(direction)+
                     " qualified on close; instant-cross mode took no late entry";
      EMA20_g_retestStatus="Instant-cross mode: retest owns this leg";
      EMA20_SaveEpisodeState();
      return;
     }

   // The confirmation route is about to hold a live market setup, so the leg
   // is consumed from here even if that entry is later skipped.
   EMA20_g_episodeLocked=true;
   EMA20_g_quietBars=0;
   EMA20_g_marketEntryPending=true;
   EMA20_g_marketEntryDirection=direction;
   EMA20_g_marketEntryRoute=EMA20_MARKET_ROUTE_RESEARCH;
   EMA20_g_marketEntrySignalBar=iTime(Symbol(),SignalTimeframe,1);
   EMA20_g_lastDecision=route+" "+EMA20_DirectionName(direction)+
                  " qualified; waiting for one confirmation close";
   EMA20_g_retestStatus="Market confirmation owns this trend leg";

   EMA20_SaveEpisodeState();
  }

//+------------------------------------------------------------------+
//| v10: enter at the live EMA20 cross, on the crossing candle.      |
//|                                                                  |
//| Runs on every tick. The qualifying filters are still measured on |
//| CLOSED bars - gradient, velocity and range votes are all taken   |
//| all come from EMA20_UpdateCurrentDiagnostics(), refreshed once per bar |
//| - so they cannot flicker tick to tick. Only the crossing test is |
//| live. That keeps the decision stable and the timing immediate.   |
//|                                                                  |
//| The crossing test asks two things: the last CLOSED bar finished  |
//| on the old side of its EMA, and the current price has moved to   |
//| the new side of the live EMA. Once a bar closes across, close[1] |
//| is already on the far side and this can no longer fire - so one  |
//| crossing produces at most one instant entry.                     |
//+------------------------------------------------------------------+
void EMA20_ProcessInstantCrossEntry()
  {
   if(!EMA20_g_enableInstantCross || EMA20_g_tradingBlocked)
      return;
   if(EMA20_g_episodeLocked || EMA20_g_marketEntryPending)
      return;
   if(!EMA20_g_diagnosticsValid)
      return;
   if(EMA20_HasEAExposure() || EMA20_HasActiveRetestPending())
      return;
   if(EMA20_g_instantNextAttempt>0 && TimeCurrent()<EMA20_g_instantNextAttempt)
      return;

   double atr=iATR(Symbol(),SignalTimeframe,EMA20_g_atrPeriod,1);
   if(atr<=0.0)
      return;
   double emaLive=EMA20_EMAValue(0);
   double emaClosed=EMA20_EMAValue(1);
   double closeClosed=iClose(Symbol(),SignalTimeframe,1);
   if(emaLive<=0.0 || emaClosed<=0.0 || closeClosed<=0.0)
      return;

   RefreshRates();
   double price=Bid;                       // the line the chart draws
   if(price<=0.0 || Ask<=0.0)
      return;

   // Which way is price crossing right now?
   int direction=0;
   if(closeClosed<=emaClosed && price>emaLive)
      direction=1;
   else if(closeClosed>=emaClosed && price<emaLive)
      direction=-1;
   if(direction==0)
      return;

   if((direction>0 && !EnableBuyTrades) || (direction<0 && !EnableSellTrades))
      return;

   // Penetration band: far enough past the line to be a real crossing,
   // near enough that we are still entering AT the cross and not chasing.
   double penetrationATR=direction*(price-emaLive)/atr;
   if(penetrationATR<EMA20_g_instantMinPenATR)
      return;
   if(EMA20_g_maxMarketEntryDistanceATR>0.0 && penetrationATR>EMA20_g_maxMarketEntryDistanceATR)
     {
      EMA20_g_lastDecision="Instant cross skipped: price already "+
                     DoubleToString(penetrationATR,3)+" ATR past the EMA20";
      return;
     }

   // Closed-bar quality filters, identical to the confirmation route.
   double gradient=direction*EMA20_g_currentSlope;
   if(gradient<EMA20_g_minDirectionalGradient ||
      EMA20_g_currentRangeVotes>EMA20_g_maxRangeVotes)
     {
      EMA20_g_lastDecision="Instant cross rejected by gradient / range rules";
      return;
     }

   if(PrintSignalDiagnostics)
      Print("XVISION EMA20 V12 instant cross ",EMA20_DirectionName(direction),
            " price=",DoubleToString(price,Digits),
            " ema=",DoubleToString(emaLive,Digits),
            " penetrationATR=",DoubleToString(penetrationATR,4),
            " gradient=",DoubleToString(gradient,4),
            " rangeVotes=",EMA20_g_currentRangeVotes);

   // Pass the live executable price as the reference so the deviation
   // guard measures slippage from here, not from a stale bar close.
   double reference=(direction>0 ? Ask : Bid);
   if(EMA20_OpenDirectionalTrade(direction,"EMA20_INSTANT",reference))
     {
      EMA20_g_episodeLocked=true;
      EMA20_g_quietBars=0;
      EMA20_g_lastSignalBar=iTime(Symbol(),SignalTimeframe,0);
      EMA20_g_retestState=EMA20_RETEST_USED;
      EMA20_g_retestStatus="Instant cross entry consumed this trend leg";
      EMA20_g_lastDecision="EMA20_INSTANT "+EMA20_DirectionName(direction)+
                     " opened at the cross, "+
                     DoubleToString(penetrationATR,3)+" ATR past the EMA20";
      EMA20_g_instantNextAttempt=0;
      EMA20_SaveEpisodeState();
     }
   else
     {
      // A blocked send (spread spike, context busy) must not burn the
      // leg: back off briefly and try again while price is still in the
      // entry band.
      EMA20_g_lastDecision="Instant cross qualified; execution blocked, retrying";
      EMA20_g_instantNextAttempt=TimeCurrent()+EMA20_g_instantRetrySeconds;
     }
  }

//+------------------------------------------------------------------+
//| Resolve the one-bar market setup exactly once.                  |
//+------------------------------------------------------------------+
void EMA20_ProcessPendingMarketEntry()
  {
   int direction=EMA20_g_marketEntryDirection;
   int routeCode=EMA20_g_marketEntryRoute;
   datetime signalBar=EMA20_g_marketEntrySignalBar;

   // Consume first so no execution failure can turn into a late retry.
   EMA20_g_marketEntryPending=false;
   EMA20_g_marketEntryDirection=0;
   EMA20_g_marketEntryRoute=EMA20_MARKET_ROUTE_NONE;
   EMA20_g_marketEntrySignalBar=0;
   EMA20_g_retestState=EMA20_RETEST_USED;
   EMA20_g_retestStatus="Market confirmation consumed this trend leg";

   string route=(routeCode==EMA20_MARKET_ROUTE_RESEARCH ? "EMA20_RESEARCH" : "");
   if((direction!=1 && direction!=-1) || route=="" || signalBar<=0)
     {
      EMA20_g_lastDecision="Market entry skipped: saved confirmation state was invalid";
      return;
     }

   // On the intended next decision bar, the crossing candle is shift 2 and
   // the newly completed confirmation candle is shift 1.
   int signalShift=iBarShift(Symbol(),SignalTimeframe,signalBar,true);
   if(signalShift!=2)
     {
      EMA20_g_lastDecision="Market entry skipped: confirmation was not observed live";
      return;
     }

   double atr=iATR(Symbol(),SignalTimeframe,EMA20_g_atrPeriod,1);
   double ema=EMA20_EMAValue(1);
   double confirmationClose=iClose(Symbol(),SignalTimeframe,1);
   if(atr<=0.0 || ema<=0.0 || confirmationClose<=0.0)
     {
      EMA20_g_lastDecision="Market entry skipped: confirmation EMA/ATR was unavailable";
      return;
     }

   if(direction*(confirmationClose-ema)<=0.0)
     {
      EMA20_g_lastDecision="Market entry skipped: confirmation closed across EMA20";
      return;
     }
   if(direction*EMA20_g_currentSlope<EMA20_g_minDirectionalGradient)
     {
      EMA20_g_lastDecision="Market entry skipped: EMA20 gradient fell below minimum";
      return;
     }
   if(EMA20_g_currentRangeVotes>EMA20_g_maxRangeVotes)
     {
      EMA20_g_lastDecision="Market entry skipped: range votes deteriorated to "+
                     IntegerToString(EMA20_g_currentRangeVotes)+"/3";
      return;
     }
   if((direction>0 && !EnableBuyTrades) || (direction<0 && !EnableSellTrades))
     {
      EMA20_g_lastDecision="Market entry skipped: "+EMA20_DirectionName(direction)+
                     " direction is disabled";
      return;
     }
   if(EMA20_HasEAExposure())
     {
      EMA20_g_lastDecision="Market entry skipped: existing XVISION exposure";
      return;
     }

   RefreshRates();
   double executablePrice=(direction>0 ? Ask : Bid);
   if(executablePrice<=0.0)
     {
      EMA20_g_lastDecision="Market entry skipped: executable quote unavailable";
      return;
     }
   double entryDistanceATR=direction*(executablePrice-ema)/atr;
   if(entryDistanceATR<0.0)
     {
      EMA20_g_lastDecision="Market entry skipped: opening quote moved across EMA20";
      return;
     }
   if(entryDistanceATR>EMA20_g_maxMarketEntryDistanceATR)
     {
      EMA20_g_lastDecision="Market entry skipped: distance "+
                     DoubleToString(entryDistanceATR,3)+" ATR exceeds "+
                     DoubleToString(EMA20_g_maxMarketEntryDistanceATR,3);
      return;
     }

   if(PrintSignalDiagnostics)
      Print("XVISION EMA20 V12 confirmation ",EMA20_DirectionName(direction),
            " time=",TimeToString(iTime(Symbol(),SignalTimeframe,1),TIME_DATE|TIME_MINUTES),
            " distanceATR=",DoubleToString(entryDistanceATR,4),
            " capATR=",DoubleToString(EMA20_g_maxMarketEntryDistanceATR,4),
            " gradient=",DoubleToString(direction*EMA20_g_currentSlope,4),
            " rangeVotes=",EMA20_g_currentRangeVotes);

   if(EMA20_OpenDirectionalTrade(direction,route,confirmationClose))
     {
      EMA20_g_lastDecision=route+" "+EMA20_DirectionName(direction)+
                     " opened after confirmation at "+
                     DoubleToString(entryDistanceATR,3)+" ATR";
      EMA20_g_retestStatus="Confirmed market entry opened; trend leg consumed";
     }
   else
     {
      EMA20_g_lastDecision=route+" confirmation passed; execution blocked or failed";
      EMA20_g_retestStatus="Confirmed market attempt consumed this trend leg";
     }
  }

//+------------------------------------------------------------------+
//| Advance the crossing-episode lock by one completed candle.        |
//|                                                                  |
//| setDecision is false when the caller has already written a more   |
//| specific EMA20_g_lastDecision that should not be overwritten.          |
//+------------------------------------------------------------------+
void EMA20_AdvanceEpisodeLock(const bool rawCross,const bool setDecision)
  {
   if(!EMA20_g_episodeLocked)
      return;

   if(rawCross)
     {
      EMA20_g_quietBars=0;
      if(setDecision)
         EMA20_g_lastDecision="LOCKED: raw crossing restarted the quiet counter";
      return;
     }

   EMA20_g_quietBars++;
   if(EMA20_g_quietBars>=EMA20_g_quietBarsRequired && !EMA20_HasEAExposure())
     {
      EMA20_g_episodeLocked=false;
      EMA20_g_quietBars=0;
      if(setDecision)
         EMA20_g_lastDecision="Episode reset completed; waiting for a new crossing";
     }
   else if(setDecision)
      EMA20_g_lastDecision="LOCKED: waiting for quiet candles and closed exposure";
  }


//+------------------------------------------------------------------+
//| Refresh panel diagnostics on every completed signal candle.      |
//+------------------------------------------------------------------+
void EMA20_UpdateCurrentDiagnostics()
  {
   EMA20_g_diagnosticsValid=false;
   double atr=iATR(Symbol(),SignalTimeframe,EMA20_g_atrPeriod,1);
   if(atr<=0.0)
      return;
   double emaNow=EMA20_EMAValue(1);
   double emaPast=EMA20_EMAValue(1+EMA20_RESEARCH_GRADIENT_LOOKBACK_BARS);
   if(emaNow<=0.0 || emaPast<=0.0)
      return;
   EMA20_g_currentSlope=(emaNow-emaPast)/atr;
   EMA20_g_currentEfficiency=EMA20_DirectionalEfficiency(EMA20_g_rangeLookback);
   int crossings=EMA20_CountRawCrossings(EMA20_g_rangeLookback);
   EMA20_g_currentRangeVotes=EMA20_RangeVotes(crossings,EMA20_g_currentSlope,EMA20_g_currentEfficiency);
   EMA20_g_diagnosticsValid=true;
  }

//+------------------------------------------------------------------+
//| Human-readable state for the dashboard.                          |
//+------------------------------------------------------------------+
string EMA20_RetestStateName()
  {
   if(EMA20_g_retestState==EMA20_RETEST_WAIT_MOVE) return("WAIT MOVE-AWAY");
   if(EMA20_g_retestState==EMA20_RETEST_ARMED)     return("ARMED");
   if(EMA20_g_retestState==EMA20_RETEST_PENDING)   return("PENDING BREAKOUT");
   if(EMA20_g_retestState==EMA20_RETEST_USED)      return("USED / INVALIDATED");
   return("IDLE");
  }

//+------------------------------------------------------------------+
//| Identify an order belonging to this EA instance.                 |
//|                                                                  |
//| v6 also required OrderComment() to start with "XVE6_RET". Order  |
//| comments are not ours to rely on -- brokers append "[sl]"/"[tp]",|
//| and bridges replace them outright. When that happened v6 stopped |
//| recognising its own pending order: it would not cancel it, could |
//| not recover it after a restart, and would place a second one.    |
//| The magic number cannot be rewritten, so it carries the identity.|
//| The comment is still written, for humans reading the terminal.   |
//+------------------------------------------------------------------+
bool EMA20_IsCurrentRetestOrder()
  {
   return(OrderSymbol()==Symbol() && OrderMagicNumber()==EMA20_g_magic);
  }

//+------------------------------------------------------------------+
//| A broker-side pending order takes priority over saved state.     |
//| Prefers the tracked ticket and falls back to a scan, adopting    |
//| whatever it finds so state survives a lost global variable.      |
//+------------------------------------------------------------------+
bool EMA20_HasActiveRetestPending()
  {
   if(EMA20_g_retestTicket>0 &&
      OrderSelect(EMA20_g_retestTicket,SELECT_BY_TICKET,MODE_TRADES) &&
      EMA20_IsCurrentRetestOrder())
     {
      int trackedType=OrderType();
      if(trackedType==OP_BUYSTOP || trackedType==OP_SELLSTOP)
         return(true);
     }

   for(int pos=OrdersTotal()-1; pos>=0; pos--)
     {
      if(!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES) || !EMA20_IsCurrentRetestOrder())
         continue;
      int type=OrderType();
      if(type==OP_BUYSTOP || type==OP_SELLSTOP)
        {
         EMA20_g_retestTicket=OrderTicket();
         return(true);
        }
     }

   if(EMA20_g_retestTicket>0)
      EMA20_g_retestTicket=0;
   return(false);
  }

//+------------------------------------------------------------------+
//| Recover safely if terminal global variables were lost/reset.    |
//+------------------------------------------------------------------+
void EMA20_RecoverRetestOrderState()
  {
   bool marketFound=false;
   int recoveredDirection=0;
   datetime recoveredTime=0;
   bool pendingFound=false;
   int pendingTicket=0;
   int pendingDirection=0;
   datetime pendingTime=0;

   for(int pos=OrdersTotal()-1; pos>=0; pos--)
     {
      if(!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES) || !EMA20_IsCurrentRetestOrder())
         continue;
      int type=OrderType();
      if(type==OP_BUYSTOP || type==OP_SELLSTOP)
        {
         pendingFound=true;
         pendingTicket=OrderTicket();
         pendingDirection=(type==OP_BUYSTOP ? 1 : -1);
         pendingTime=OrderOpenTime();
         continue;      // v6 returned here and never saw an open position
        }
      if(type==OP_BUY || type==OP_SELL)
        {
         marketFound=true;
         recoveredDirection=(type==OP_BUY ? 1 : -1);
         recoveredTime=OrderOpenTime();
        }
     }

   if(pendingFound)
     {
      EMA20_g_retestState=EMA20_RETEST_PENDING;
      EMA20_g_retestTicket=pendingTicket;
      EMA20_g_retestDirection=pendingDirection;
      EMA20_g_retestCount=(int)MathMax(EMA20_g_retestCount,1);
      EMA20_g_retestSignalBar=pendingTime;
      EMA20_g_retestStatus="Recovered pending confirmation #"+IntegerToString(pendingTicket);
      return;
     }

   if(marketFound)
     {
      EMA20_g_retestState=EMA20_RETEST_USED;
      EMA20_g_retestTicket=0;
      EMA20_g_retestDirection=recoveredDirection;
      EMA20_g_retestCount=(int)MathMax(EMA20_g_retestCount,1);
      EMA20_g_retestSignalBar=recoveredTime;
      EMA20_g_retestStatus="Recovered triggered retest position";
     }
  }

//+------------------------------------------------------------------+
//| Verify the required consecutive closes remain on the trend side.|
//+------------------------------------------------------------------+
bool EMA20_HasTrendCloses(const int direction)
  {
   for(int shift=1; shift<=EMA20_g_retestTrendCloses; shift++)
     {
      double closeValue=iClose(Symbol(),SignalTimeframe,shift);
      double emaValue=EMA20_EMAValue(shift);
      if(emaValue<=0.0 || closeValue<=0.0)
         return(false);
      if(direction>0 && closeValue<=emaValue)
         return(false);
      if(direction<0 && closeValue>=emaValue)
         return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| True when the completed candle reaches the ATR band around EMA. |
//+------------------------------------------------------------------+
bool EMA20_RetestTouchesBand(const int direction)
  {
   double atr=iATR(Symbol(),SignalTimeframe,EMA20_g_atrPeriod,1);
   if(atr<=0.0)
      return(false);
   double ema=EMA20_EMAValue(1);
   if(ema<=0.0)
      return(false);
   if(direction>0)
      return(iLow(Symbol(),SignalTimeframe,1)<=ema+EMA20_g_retestTouchTolATR*atr);
   return(iHigh(Symbol(),SignalTimeframe,1)>=ema-EMA20_g_retestTouchTolATR*atr);
  }

//+------------------------------------------------------------------+
//| Apply all rejection-candle requirements to the first EMA touch. |
//+------------------------------------------------------------------+
bool EMA20_RetestCandleQualifies(const int direction,string &reason)
  {
   reason="";
   double atr=iATR(Symbol(),SignalTimeframe,EMA20_g_atrPeriod,1);
   if(atr<=0.0)
     { reason="ATR unavailable"; return(false); }
   if(!EMA20_g_diagnosticsValid)
     { reason="diagnostics are stale"; return(false); }
   if(direction*EMA20_g_currentSlope<EMA20_g_minDirectionalGradient)
     { reason="EMA slope lost direction"; return(false); }
   if(EMA20_g_currentRangeVotes>EMA20_g_maxRangeVotes)
     { reason="too many range votes"; return(false); }
   if(EMA20_g_currentEfficiency<EMA20_g_minEfficiency)
     { reason="directional efficiency too low"; return(false); }

   double openValue=iOpen(Symbol(),SignalTimeframe,1);
   double highValue=iHigh(Symbol(),SignalTimeframe,1);
   double lowValue=iLow(Symbol(),SignalTimeframe,1);
   double closeValue=iClose(Symbol(),SignalTimeframe,1);
   double emaValue=EMA20_EMAValue(1);
   if(emaValue<=0.0)
     { reason="EMA unavailable"; return(false); }
   double candleRange=highValue-lowValue;
   if(candleRange<=0.0)
     { reason="zero candle range"; return(false); }

   double recovery=direction*(closeValue-emaValue)/atr;
   double penetration=(direction>0 ? (emaValue-lowValue)/atr :
                                     (highValue-emaValue)/atr);
   if(penetration>EMA20_g_retestMaxPenetrationATR)
     { reason="EMA penetration was too deep"; return(false); }
   if(recovery<EMA20_g_retestMinRecoveryATR)
     { reason="close did not recover far enough from EMA"; return(false); }
   if(RetestRequireDirectionalBody && direction*(closeValue-openValue)<=0.0)
     { reason="candle body disagreed with trend"; return(false); }

   double closeLocation=(direction>0 ?
                         (closeValue-lowValue)/candleRange*100.0 :
                         (highValue-closeValue)/candleRange*100.0);
   if(closeLocation<EMA20_g_retestMinCloseLocPct)
     { reason="close location was too weak"; return(false); }
   return(true);
  }

//+------------------------------------------------------------------+
//| Normalize stop-entry prices away from the current market.        |
//+------------------------------------------------------------------+
double EMA20_NormalizeRetestEntry(const double price,const int direction)
  {
   double tickSize=MarketInfo(Symbol(),MODE_TICKSIZE);
   if(tickSize<=0.0)
      tickSize=Point;
   if(tickSize<=0.0)
      return(0.0);
   double ticks=price/tickSize;
   double normalized=(direction>0 ? MathCeil(ticks)*tickSize :
                                    MathFloor(ticks)*tickSize);
   return(NormalizeDouble(normalized,Digits));
  }

//+------------------------------------------------------------------+
//| Place the confirmation stop beyond the rejection candle.        |
//+------------------------------------------------------------------+
bool EMA20_PlaceRetestPending(const int direction)
  {
   if(EMA20_g_tradingBlocked)
     { EMA20_g_lastDecision="RETEST suppressed: "+EMA20_g_blockReason; return(false); }

   if(SG_ForeignModulePositionOpen(MagicNumber))
     { EMA20_g_lastDecision="RETEST held: scalper module holds the position"; return(false); }

   if(!IsTradeAllowed() || IsTradeContextBusy() ||
      MarketInfo(Symbol(),MODE_TRADEALLOWED)<0.5)
     { EMA20_g_lastDecision="RETEST rejected: trade context unavailable"; return(false); }
   RefreshRates();
   if(Bid<=0.0 || Ask<=0.0)
     { EMA20_g_lastDecision="RETEST rejected: prices unavailable"; return(false); }

   double spread=MathMax(0.0,Ask-Bid);
   if(EMA20_g_maxSpread>0.0 && spread>EMA20_g_maxSpread)
     { EMA20_g_lastDecision="RETEST rejected: spread too wide"; return(false); }

   double lots=0.0;
   if(!EMA20_ResolveLotSizeForTrade(EMA20_g_fixedLot,lots))
     { EMA20_g_lastDecision="RETEST rejected: volume is not executable"; return(false); }

   double atr=iATR(Symbol(),SignalTimeframe,EMA20_g_atrPeriod,1);
   if(atr<=0.0)
     { EMA20_g_lastDecision="RETEST rejected: ATR unavailable"; return(false); }
   double rawEntry=(direction>0 ? iHigh(Symbol(),SignalTimeframe,1)+EMA20_g_retestEntryBufferATR*atr :
                                  iLow(Symbol(),SignalTimeframe,1)-EMA20_g_retestEntryBufferATR*atr);
   double entry=EMA20_NormalizeRetestEntry(rawEntry,direction);
   if(entry<=0.0)
     { EMA20_g_lastDecision="RETEST rejected: invalid pending price"; return(false); }

   double minimumDistance=MarketInfo(Symbol(),MODE_STOPLEVEL)*Point;
   if((direction>0 && entry<=Ask+minimumDistance) ||
      (direction<0 && entry>=Bid-minimumDistance))
     { EMA20_g_lastDecision="RETEST skipped: breakout already passed or pending too close"; return(false); }

   double stopLoss=0.0;
   double takeProfit=0.0;
   int marketCommand=(direction>0 ? OP_BUY : OP_SELL);
   if(EMA20_g_stopLossMoney>0.0 || EMA20_g_takeProfitMoney>0.0)
     {
      double moneyPerPrice=EMA20_MoneyPerPriceUnitPerLot()*lots;
      if(moneyPerPrice<=0.0)
        { EMA20_g_lastDecision="RETEST rejected: tick value unavailable"; return(false); }
      double stopDistance=(EMA20_g_stopLossMoney>0.0 ? EMA20_g_stopLossMoney/moneyPerPrice : 0.0);
      double targetDistance=(EMA20_g_takeProfitMoney>0.0 ? EMA20_g_takeProfitMoney/moneyPerPrice : 0.0);
      if((stopDistance>0.0 && stopDistance<minimumDistance) ||
         (targetDistance>0.0 && targetDistance<minimumDistance))
        { EMA20_g_lastDecision="RETEST rejected: SL/TP inside broker stop level"; return(false); }
      if(stopDistance>0.0)
         stopLoss=EMA20_NormalizeProtectiveStop(entry-direction*stopDistance,marketCommand);
      if(targetDistance>0.0)
         takeProfit=EMA20_NormalizeTargetPrice(entry+direction*targetDistance,marketCommand);
      if((stopDistance>0.0 && stopLoss<=0.0) ||
         (targetDistance>0.0 && takeProfit<=0.0))
        { EMA20_g_lastDecision="RETEST rejected: protected price normalization failed"; return(false); }
      if((stopLoss>0.0 && MathAbs(entry-stopLoss)+Point*0.1<minimumDistance) ||
         (takeProfit>0.0 && MathAbs(takeProfit-entry)+Point*0.1<minimumDistance))
        { EMA20_g_lastDecision="RETEST rejected: tick rounding breached broker stop level"; return(false); }
     }

   // A pending order consumes no margin until it triggers, and margin at that
   // future moment is what decides the fill. v6 rejected the placement using a
   // MARKET order check, which blocked valid pendings whenever margin was tight.
   // Warn and let the broker enforce margin on trigger instead.
   if(AccountFreeMarginCheck(Symbol(),marketCommand,lots)<=0.0)
     {
      ResetLastError();
      Print("XVISION EMA20 V12: free margin would not support ",
            DoubleToString(lots,EMA20_LotDigits())," lots right now; placing the pending "
            "anyway since margin is only required if it triggers.");
     }

   int pendingCommand=(direction>0 ? OP_BUYSTOP : OP_SELLSTOP);
   string orderComment=(direction>0 ? "XVE9_RET_BUY" : "XVE9_RET_SELL");
   datetime expiration=0;
   if(RequireServerSidePendingExpiry)
     {
      int timeframeSeconds=PeriodSeconds(SignalTimeframe);
      datetime activeBar=iTime(Symbol(),SignalTimeframe,0);
      if(timeframeSeconds<=0 || activeBar<=0)
        { EMA20_g_lastDecision="RETEST rejected: server expiry time unavailable"; return(false); }
      expiration=(datetime)(activeBar+EMA20_g_retestExpiryBars*timeframeSeconds);
      if(expiration<=TimeCurrent())
        { EMA20_g_lastDecision="RETEST rejected: computed server expiry is stale"; return(false); }
     }
   bool serverExpiryRequested=(expiration>0);
   ResetLastError();
   int ticket=OrderSend(Symbol(),pendingCommand,lots,entry,EMA20_SlippagePoints(),
                        stopLoss,takeProfit,orderComment,EMA20_g_magic,expiration,
                        (direction>0 ? clrDodgerBlue : clrTomato));

   // Many brokers -- ECN/STP accounts especially -- refuse pending expiry
   // outright with error 147. v6 treated that as a hard failure and burned the
   // trend leg, so the retest route never worked at all on those accounts.
   // The bar-age cancel in EMA20_ManageRetestOrders() already enforces the same
   // lifetime locally, so falling back is safe rather than a loosening.
   if(ticket<0 && serverExpiryRequested)
     {
      int expiryError=GetLastError();
      if(expiryError==ERR_TRADE_EXPIRATION_DENIED ||
         expiryError==ERR_INVALID_TRADE_PARAMETERS)
        {
         Print("XVISION EMA20 V12: broker refused pending expiry (error=",expiryError,
               "); resending without it and expiring locally after ",
               EMA20_g_retestExpiryBars," ",EMA20_TimeframeName(SignalTimeframe)," bars.");
         serverExpiryRequested=false;
         expiration=0;
         ResetLastError();
         ticket=OrderSend(Symbol(),pendingCommand,lots,entry,EMA20_SlippagePoints(),
                          stopLoss,takeProfit,orderComment,EMA20_g_magic,0,
                          (direction>0 ? clrDodgerBlue : clrTomato));
        }
     }

   if(ticket<0)
     {
      Print("XVISION EMA20 V12: retest pending failed error=",GetLastError(),
            " entry=",DoubleToString(entry,Digits));
      EMA20_g_lastDecision="RETEST qualified; pending order failed";
      return(false);
     }

   bool expiryVerified=true;
   if(serverExpiryRequested)
     {
      expiryVerified=(OrderSelect(ticket,SELECT_BY_TICKET,MODE_TRADES) &&
                      OrderExpiration()>0);
      if(!expiryVerified)
        {
         // The broker accepted the order but dropped the expiry silently, which
         // is different from refusing it up front. Fall back to local expiry
         // rather than deleting a live stop order.
         Print("XVISION EMA20 V12: pending #",ticket," was accepted without the "
               "requested server expiry; it will be expired locally after ",
               EMA20_g_retestExpiryBars," ",EMA20_TimeframeName(SignalTimeframe)," bars.");
        }
     }

   EMA20_g_retestTicket=ticket;
   EMA20_g_retestState=EMA20_RETEST_PENDING;
   EMA20_g_retestCount++;
   EMA20_g_retestSignalBar=iTime(Symbol(),SignalTimeframe,1);
   EMA20_g_lastSignalBar=EMA20_g_retestSignalBar;
   EMA20_g_episodeLocked=true;
   EMA20_g_quietBars=0;
   EMA20_g_retestStatus=EMA20_DirectionName(direction)+" confirmation pending #"+
                  IntegerToString(ticket)+" at "+DoubleToString(entry,Digits)+
                  (expiryVerified ? "" : " (local expiry)");
   EMA20_g_lastDecision="RETEST "+EMA20_DirectionName(direction)+" confirmation pending";
   Print("XVISION EMA20 V12: retest pending ticket=",ticket,
         " direction=",EMA20_DirectionName(direction),
         " entry=",DoubleToString(entry,Digits),
         " expires after ",EMA20_g_retestExpiryBars," ",
         EMA20_TimeframeName(SignalTimeframe)," bars",
         " serverExpiry=",(expiration>0 ?
         TimeToString(expiration,TIME_DATE|TIME_MINUTES) : "manual-only"));
   return(true);
  }

//+------------------------------------------------------------------+
//| Advance the live-only trend -> move-away -> first-retest state.  |
//+------------------------------------------------------------------+
bool EMA20_ProcessRetestState(const bool rawCross,const int crossDirection)
  {
   if(!EMA20_g_enableRetest)
     {
      EMA20_g_retestState=EMA20_RETEST_IDLE;
      EMA20_g_retestStatus="Retest module disabled";
      return(false);
     }

   if(EMA20_HasActiveRetestPending())
     {
      EMA20_g_retestState=EMA20_RETEST_PENDING;
      EMA20_g_retestStatus="Broker retest confirmation remains pending";
      return(false);
     }

   if(rawCross)
     {
      // A raw crossing does not own a retest. EMA20_ProcessNewSignalBar() grants
      // ownership only after all EMA20 research filters qualify the crossing.
      EMA20_g_retestDirection=0;
      EMA20_g_retestState=EMA20_RETEST_IDLE;
      EMA20_g_retestCount=0;
      EMA20_g_retestSignalBar=0;
      EMA20_g_retestStatus="Raw crossing awaiting EMA20 research qualification";
      return(false);
     }

   // v7 paused the retest here whenever the episode was locked, because in v6
   // ANY raw crossing auto-armed a leg and the pause was the only thing keeping
   // an unassessed leg from firing. v9 replaced that with an ownership model:
   // the raw-cross branch above now clears the leg outright, and only a fully
   // qualified crossing in EMA20_ProcessNewSignalBar() grants one.
   //
   // Carrying the pause forward on top of the ownership model killed the route.
   // EMA20_ProcessNewSignalBar() locks the episode in the same breath as it grants the
   // leg, so the sequence was frozen for EMA20_g_quietBarsRequired bars, during which
   // any raw crossing reset it to IDLE and the first EMA touch -- the entire
   // point of the route -- came and went unseen. The retest could effectively
   // never reach ARMED. The pause is removed; ownership does its job.
   if(EMA20_g_retestState==EMA20_RETEST_IDLE || EMA20_g_retestState==EMA20_RETEST_PENDING ||
      EMA20_g_retestState==EMA20_RETEST_USED || EMA20_g_retestDirection==0)
      return(false);

   double atr=iATR(Symbol(),SignalTimeframe,EMA20_g_atrPeriod,1);
   if(atr<=0.0)
      return(false);
   double closeValue=iClose(Symbol(),SignalTimeframe,1);
   double emaValue=EMA20_EMAValue(1);
   if(emaValue<=0.0)
      return(false);
   double directionalDistance=EMA20_g_retestDirection*(closeValue-emaValue)/atr;

   if(directionalDistance<=0.0 || EMA20_g_retestDirection*EMA20_g_currentSlope<=0.0)
     {
      EMA20_g_retestState=EMA20_RETEST_USED;
      EMA20_g_retestStatus="Trend leg invalidated before retest";
      return(false);
     }

   if(EMA20_g_retestState==EMA20_RETEST_WAIT_MOVE)
     {
      if(EMA20_HasTrendCloses(EMA20_g_retestDirection) &&
         directionalDistance>=EMA20_g_retestMinMoveAwayATR &&
         EMA20_g_retestDirection*EMA20_g_currentSlope>=EMA20_g_minDirectionalGradient &&
         EMA20_g_currentRangeVotes<=EMA20_g_maxRangeVotes &&
         EMA20_g_currentEfficiency>=EMA20_g_minEfficiency)
        {
         EMA20_g_retestState=EMA20_RETEST_ARMED;
         EMA20_g_retestStatus=EMA20_DirectionName(EMA20_g_retestDirection)+" retest armed; waiting for first touch";
        }
      if(EMA20_g_retestState!=EMA20_RETEST_ARMED)
         return(false);
     }

   if(EMA20_g_retestState!=EMA20_RETEST_ARMED || !EMA20_RetestTouchesBand(EMA20_g_retestDirection))
      return(false);

   // The first touch consumes the opportunity whether it passes or fails.
   string reason="";
   if(!EMA20_RetestCandleQualifies(EMA20_g_retestDirection,reason))
     {
      EMA20_g_retestState=EMA20_RETEST_USED;
      EMA20_g_retestStatus="First retest rejected: "+reason;
      EMA20_g_lastDecision=EMA20_g_retestStatus;
      return(true);
     }

   if(EMA20_g_retestCount>=EMA20_g_maxRetestsPerLeg)
     {
      EMA20_g_retestState=EMA20_RETEST_USED;
      EMA20_g_retestStatus="Retest limit already reached for this trend leg";
      EMA20_g_lastDecision=EMA20_g_retestStatus;
      return(true);
     }
   if(EMA20_HasEAExposure())
     {
      EMA20_g_retestState=EMA20_RETEST_USED;
      EMA20_g_retestStatus="Qualified retest blocked by existing exposure";
      EMA20_g_lastDecision=EMA20_g_retestStatus;
      return(true);
     }
   if((EMA20_g_retestDirection>0 && !EnableBuyTrades) ||
      (EMA20_g_retestDirection<0 && !EnableSellTrades))
     {
      EMA20_g_retestState=EMA20_RETEST_USED;
      EMA20_g_retestStatus="Qualified retest direction is disabled";
      EMA20_g_lastDecision=EMA20_g_retestStatus;
      return(true);
     }

   bool placed=EMA20_PlaceRetestPending(EMA20_g_retestDirection);
   if(!placed)
     {
      EMA20_g_retestState=EMA20_RETEST_USED;
      EMA20_g_retestStatus=EMA20_g_lastDecision;
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Cancel stale/invalid retest stops and detect confirmed entries.  |
//+------------------------------------------------------------------+
void EMA20_ManageRetestOrders()
  {
   int pendingCount=0;
   bool triggeredPositionFound=false;
   bool stateChanged=false;
   double atr=iATR(Symbol(),SignalTimeframe,EMA20_g_atrPeriod,1);
   double closedSlope=0.0;
   bool   slopeKnown=false;
   double manageEma=EMA20_EMAValue(1);
   double manageEmaPast=EMA20_EMAValue(1+EMA20_RESEARCH_GRADIENT_LOOKBACK_BARS);
   if(atr>0.0 && manageEma>0.0 && manageEmaPast>0.0)
     {
      closedSlope=(manageEma-manageEmaPast)/atr;
      slopeKnown=true;
     }

   for(int pos=OrdersTotal()-1; pos>=0; pos--)
     {
      if(!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES))
         continue;
      if(!EMA20_IsCurrentRetestOrder())
         continue;

      int type=OrderType();
      if(type==OP_BUY || type==OP_SELL)
        {
         triggeredPositionFound=true;
         continue;
        }
      if(type!=OP_BUYSTOP && type!=OP_SELLSTOP)
         continue;

      pendingCount++;
      int direction=(type==OP_BUYSTOP ? 1 : -1);
      int ageBars=iBarShift(Symbol(),SignalTimeframe,OrderOpenTime(),false);
      double closeValue=iClose(Symbol(),SignalTimeframe,1);
      double emaValue=manageEma;
      bool barExpired=(ageBars>=EMA20_g_retestExpiryBars);
      bool serverExpired=(OrderExpiration()>0 && TimeCurrent()>=OrderExpiration());
      bool expired=(barExpired || serverExpired);
      // Never judge the setup against an unavailable EMA -- a zero would read
      // as "invalidated" for sells and cancel a perfectly good pending order.
      bool closeInvalid=(emaValue>0.0 && closeValue>0.0 &&
                         (direction>0 ? closeValue<=emaValue : closeValue>=emaValue));
      bool slopeInvalid=(slopeKnown && direction*closedSlope<=0.0);
      bool cancel=(!EMA20_g_enableRetest || expired || closeInvalid || slopeInvalid);
      if(!cancel || !IsTradeAllowed() || IsTradeContextBusy() ||
         MarketInfo(Symbol(),MODE_TRADEALLOWED)<0.5)
         continue;

      // v6 throttled only the error message, so a pending sitting inside the
      // broker's freeze level was hammered with OrderDelete on every tick.
      if(TimeCurrent()-EMA20_g_lastPendingDeleteAttempt<EMA20_PENDING_DELETE_RETRY_SECONDS)
         continue;
      EMA20_g_lastPendingDeleteAttempt=TimeCurrent();

      int ticket=OrderTicket();
      string cancelReason=(!EMA20_g_enableRetest ? "module disabled" :
                           (expired ? "confirmation expired" :
                            (closeInvalid ? "EMA close invalidated" : "slope invalidated")));
      ResetLastError();
      if(OrderDelete(ticket,clrSilver))
        {
         Print("XVISION EMA20 V12: deleted retest pending #",ticket,
               " reason=",cancelReason);
         pendingCount--;
         if(EMA20_g_retestTicket==ticket)
            EMA20_g_retestTicket=0;
         EMA20_g_retestState=(EMA20_g_retestCount>=EMA20_g_maxRetestsPerLeg ?
                        EMA20_RETEST_USED : EMA20_RETEST_WAIT_MOVE);
         EMA20_g_retestStatus="Pending cancelled: "+cancelReason;
         EMA20_g_lastDecision=EMA20_g_retestStatus;
         stateChanged=true;
        }
      else if(TimeCurrent()-EMA20_g_lastManagementErrorPrint>=30)
        {
         Print("XVISION EMA20 V12: pending deletion failed #",ticket,
               " error=",GetLastError());
         EMA20_g_lastManagementErrorPrint=TimeCurrent();
        }
     }

   if(EMA20_g_retestState==EMA20_RETEST_PENDING && pendingCount<=0)
     {
      if(triggeredPositionFound)
        {
         EMA20_g_retestState=EMA20_RETEST_USED;
         EMA20_g_retestStatus="Retest confirmation triggered; position is open";
         EMA20_g_lastDecision=EMA20_g_retestStatus;
        }
      else
        {
         EMA20_g_retestState=(EMA20_g_retestCount>=EMA20_g_maxRetestsPerLeg ?
                        EMA20_RETEST_USED : EMA20_RETEST_WAIT_MOVE);
         EMA20_g_retestStatus="Retest pending no longer exists";
        }
      stateChanged=true;
     }
   else if(triggeredPositionFound && EMA20_g_retestState!=EMA20_RETEST_USED)
     {
      EMA20_g_retestState=EMA20_RETEST_USED;
      EMA20_g_retestCount=(int)MathMax(EMA20_g_retestCount,1);
      EMA20_g_retestStatus="Retest confirmation triggered; position is open";
      EMA20_g_lastDecision=EMA20_g_retestStatus;
      stateChanged=true;
     }
   if(stateChanged)
      EMA20_SaveEpisodeState();
  }

//+------------------------------------------------------------------+
//| Completed-candle cross.                                         |
//+------------------------------------------------------------------+
bool EMA20_ClosedBarCross(int &direction)
  {
   direction=0;
   double close1=iClose(Symbol(),SignalTimeframe,1);
   double close2=iClose(Symbol(),SignalTimeframe,2);
   double ema1=EMA20_EMAValue(1);
   double ema2=EMA20_EMAValue(2);

   // Without this guard a zero EMA reads as a crossing on every tick.
   if(ema1<=0.0 || ema2<=0.0 || close1<=0.0 || close2<=0.0)
      return(false);

   if(close2<=ema2 && close1>ema1)
      direction=1;
   else if(close2>=ema2 && close1<ema1)
      direction=-1;

   return(direction!=0);
  }

//+------------------------------------------------------------------+
//| Count completed-bar EMA crossings in the lookback window.       |
//+------------------------------------------------------------------+
int EMA20_CountRawCrossings(const int lookback)
  {
   int count=0;
   for(int shift=1; shift<=lookback; shift++)
     {
      double closeNew=iClose(Symbol(),SignalTimeframe,shift);
      double closeOld=iClose(Symbol(),SignalTimeframe,shift+1);
      double emaNew=EMA20_EMAValue(shift);
      double emaOld=EMA20_EMAValue(shift+1);
      if(emaNew<=0.0 || emaOld<=0.0)
         continue;
      if((closeOld<=emaOld && closeNew>emaNew) ||
         (closeOld>=emaOld && closeNew<emaNew))
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Net progress divided by total close-to-close movement.          |
//+------------------------------------------------------------------+
double EMA20_DirectionalEfficiency(const int lookback)
  {
   double newest=iClose(Symbol(),SignalTimeframe,1);
   double oldest=iClose(Symbol(),SignalTimeframe,1+lookback);
   double totalMovement=0.0;
   for(int shift=1; shift<=lookback; shift++)
      totalMovement+=MathAbs(iClose(Symbol(),SignalTimeframe,shift)-
                             iClose(Symbol(),SignalTimeframe,shift+1));
   if(totalMovement<=0.0)
      return(0.0);
   return(MathAbs(newest-oldest)/totalMovement);
  }

//+------------------------------------------------------------------+
//| Three independent votes identifying a ranging environment.      |
//+------------------------------------------------------------------+
int EMA20_RangeVotes(const int crossings,const double slope,const double efficiency)
  {
   int votes=0;
   if(crossings>=EMA20_g_rangeCrossVoteMin)
      votes++;
   if(MathAbs(slope)<EMA20_g_flatGradientThreshold)
      votes++;
   if(efficiency<EMA20_g_minEfficiency)
      votes++;
   return(votes);
  }

//+------------------------------------------------------------------+
//| Place one crossing entry with the user's protection settings.   |
//+------------------------------------------------------------------+
bool EMA20_OpenDirectionalTrade(const int direction,const string route,const double signalClose)
  {
   if(EMA20_g_tradingBlocked)
     {
      Print("XVISION EMA20 V12: entry suppressed -- ",EMA20_g_blockReason);
      return(false);
     }

   if(SG_ForeignModulePositionOpen(MagicNumber))
     {
      EMA20_g_lastDecision="Entry held: scalper module holds the position";
      return(false);
     }

   if(!IsTradeAllowed() || IsTradeContextBusy() ||
      MarketInfo(Symbol(),MODE_TRADEALLOWED)<0.5)
     {
       Print("XVISION EMA20 V12: trade context is not available.");
      return(false);
     }

   RefreshRates();
   if(Bid<=0.0 || Ask<=0.0)
      return(false);

   double spread=MathMax(0.0,Ask-Bid);
   if(EMA20_g_maxSpread>0.0 && spread>EMA20_g_maxSpread)
     {
       Print("XVISION EMA20 V12: entry skipped; spread ",DoubleToString(spread,Digits),
            " exceeds ",DoubleToString(EMA20_g_maxSpread,Digits));
      return(false);
     }

   int command=(direction>0 ? OP_BUY : OP_SELL);
   double entry=(command==OP_BUY ? Ask : Bid);
   if(EMA20_g_maxEntryDeviation>0.0 &&
      MathAbs(entry-signalClose)>EMA20_g_maxEntryDeviation)
     {
       Print("XVISION EMA20 V12: entry skipped; deviation from signal close is ",
            DoubleToString(MathAbs(entry-signalClose),Digits));
      return(false);
     }

   double lots=0.0;
   if(!EMA20_ResolveLotSizeForTrade(EMA20_g_fixedLot,lots))
      return(false);

   double stopDistance=0.0;
   double targetDistance=0.0;
   if(EMA20_g_stopLossMoney>0.0 || EMA20_g_takeProfitMoney>0.0)
     {
      double moneyPerPricePerLot=EMA20_MoneyPerPriceUnitPerLot();
      if(moneyPerPricePerLot<=0.0)
        {
         Print("XVISION EMA20 V12: broker tick value/tick size is unavailable.");
         return(false);
        }
      if(EMA20_g_stopLossMoney>0.0)
         stopDistance=EMA20_g_stopLossMoney/(moneyPerPricePerLot*lots);
      if(EMA20_g_takeProfitMoney>0.0)
         targetDistance=EMA20_g_takeProfitMoney/(moneyPerPricePerLot*lots);
     }

   double minimumDistance=MarketInfo(Symbol(),MODE_STOPLEVEL)*Point;
   if((stopDistance>0.0 && stopDistance<minimumDistance) ||
      (targetDistance>0.0 && targetDistance<minimumDistance))
     {
      Print("XVISION EMA20 V12: requested SL/TP is inside the broker stop level.");
      return(false);
     }

   double stopLoss=0.0;
   double takeProfit=0.0;
   if(stopDistance>0.0)
      stopLoss=EMA20_NormalizeProtectiveStop((direction>0 ? entry-stopDistance :
                                                     entry+stopDistance),command);
   if(targetDistance>0.0)
      takeProfit=EMA20_NormalizeTargetPrice((direction>0 ? entry+targetDistance :
                                                    entry-targetDistance),command);
   if((stopDistance>0.0 && stopLoss<=0.0) ||
      (targetDistance>0.0 && takeProfit<=0.0))
     {
      Print("XVISION EMA20 V12: protected price normalization failed.");
      return(false);
     }
   entry=NormalizeDouble(entry,Digits);
   if((stopLoss>0.0 && MathAbs(entry-stopLoss)+Point*0.1<minimumDistance) ||
      (takeProfit>0.0 && MathAbs(takeProfit-entry)+Point*0.1<minimumDistance))
     {
      Print("XVISION EMA20 V12: tick rounding breached the broker stop level.");
      return(false);
     }
   bool marketLevelsInvalid=
      (command==OP_BUY &&
       ((stopLoss>0.0 && stopLoss>Bid-minimumDistance) ||
        (takeProfit>0.0 && takeProfit<Bid+minimumDistance))) ||
      (command==OP_SELL &&
       ((stopLoss>0.0 && stopLoss<Ask+minimumDistance) ||
        (takeProfit>0.0 && takeProfit>Ask-minimumDistance)));
   if(marketLevelsInvalid)
     {
      Print("XVISION EMA20 V12: requested protection is too close to the executable market side.");
      return(false);
     }

   if(AccountFreeMarginCheck(Symbol(),command,lots)<=0.0)
     {
      Print("XVISION EMA20 V12: insufficient free margin.");
      return(false);
     }

   string comment="XVE9_EMA20";
   ResetLastError();
   int ticket=OrderSend(Symbol(),command,lots,entry,EMA20_SlippagePoints(),
                        stopLoss,takeProfit,comment,EMA20_g_magic,0,
                        (direction>0 ? clrDodgerBlue : clrTomato));
   if(ticket<0)
     {
      int error=GetLastError();
      Print("XVISION EMA20 V12: OrderSend failed error=",error,
            " direction=",EMA20_DirectionName(direction),
            " entry=",DoubleToString(entry,Digits),
            " SL=",DoubleToString(stopLoss,Digits),
            " TP=",DoubleToString(takeProfit,Digits));
      return(false);
     }

   Print("XVISION EMA20 V12: opened ticket=",ticket,
         " route=",route,
         " direction=",EMA20_DirectionName(direction),
         " lots=",DoubleToString(lots,EMA20_LotDigits()),
         " entry=",DoubleToString(entry,Digits),
         " SL=",DoubleToString(stopLoss,Digits),
         " TP=",DoubleToString(takeProfit,Digits));
   return(true);
  }

//+------------------------------------------------------------------+
//| Snap a price to the broker tick grid, always in the direction    |
//| that favours the trade: up for a BUY, down for a SELL.           |
//|                                                                  |
//| v6 had this body duplicated under two names with contradictory   |
//| comments, which read like a bug. It is not one -- the single     |
//| rule is correct for all four cases. BUY stop sits below entry so |
//| rounding up tightens risk; BUY target sits above so rounding up  |
//| widens reward. SELL mirrors both. Never risk more, never bank    |
//| less, than the user asked for.                                   |
//+------------------------------------------------------------------+
double EMA20_NormalizeProtectiveStop(const double price,const int orderType)
  {
   double tickSize=MarketInfo(Symbol(),MODE_TICKSIZE);
   if(tickSize<=0.0)
      tickSize=Point;
   if(tickSize<=0.0)
      return(0.0);
   double ticks=price/tickSize;
   double normalized=(orderType==OP_BUY ? MathCeil(ticks)*tickSize :
                                            MathFloor(ticks)*tickSize);
   return(NormalizeDouble(normalized,Digits));
  }

//+------------------------------------------------------------------+
//| Targets use the same rounding, and that is correct rather than a |
//| copy-paste slip -- see the note above EMA20_NormalizeProtectiveStop(). |
//| Kept as a separate name so call sites still read intelligibly,   |
//| but sharing one body so the two can never drift apart.           |
//+------------------------------------------------------------------+
double EMA20_NormalizeTargetPrice(const double price,const int orderType)
  {
   return(EMA20_NormalizeProtectiveStop(price,orderType));
  }

//+------------------------------------------------------------------+
//| Apply only the trailing/lock values explicitly entered by user. |
//+------------------------------------------------------------------+
void EMA20_ManageInputProtection()
  {
   if(!EMA20_g_enableTrailing && !EMA20_g_enableProfitLock)
      return;
   if(!IsTradeAllowed() || IsTradeContextBusy() ||
      MarketInfo(Symbol(),MODE_TRADEALLOWED)<0.5)
      return;

   RefreshRates();
   double moneyPerPricePerLot=EMA20_MoneyPerPriceUnitPerLot();
   if(moneyPerPricePerLot<=0.0 || Bid<=0.0 || Ask<=0.0)
      return;

   double brokerDistance=MathMax(MarketInfo(Symbol(),MODE_STOPLEVEL),
                                 MarketInfo(Symbol(),MODE_FREEZELEVEL))*Point;

   for(int pos=OrdersTotal()-1; pos>=0; pos--)
     {
      if(!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES))
         continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=EMA20_g_magic)
         continue;
      int orderType=OrderType();
      if(orderType!=OP_BUY && orderType!=OP_SELL)
         continue;

      int direction=(orderType==OP_BUY ? 1 : -1);
      double moneyPerPrice=moneyPerPricePerLot*OrderLots();
      if(moneyPerPrice<=0.0)
         continue;
      double carryingCosts=OrderSwap()+OrderCommission();
      double netProfit=OrderProfit()+carryingCosts;
      double candidate=0.0;
      string source="";

      if(EMA20_g_enableProfitLock && netProfit>=EMA20_g_lockTrigger)
        {
         double requiredGrossAtStop=EMA20_g_lockMoney-carryingCosts;
         candidate=OrderOpenPrice()+direction*(requiredGrossAtStop/moneyPerPrice);
         source="PROFIT_LOCK";
        }

      if(EMA20_g_enableTrailing && netProfit>=EMA20_g_trailStart)
        {
         double desiredNetAtStop=netProfit-EMA20_g_trailDistance;
         double requiredGrossAtStop=desiredNetAtStop-carryingCosts;
         double trailingStop=OrderOpenPrice()+direction*(requiredGrossAtStop/moneyPerPrice);
         if(candidate<=0.0 ||
            (orderType==OP_BUY && trailingStop>candidate) ||
            (orderType==OP_SELL && trailingStop<candidate))
           {
            candidate=trailingStop;
            source="TRAILING";
           }
        }

      if(candidate<=0.0)
         continue;
      candidate=EMA20_NormalizeProtectiveStop(candidate,orderType);
      if(candidate<=0.0)
         continue;

      // Wait until the requested protective level is legal; never weaken it.
      if((orderType==OP_BUY && candidate>Bid-brokerDistance) ||
         (orderType==OP_SELL && candidate<Ask+brokerDistance))
         continue;

      double oldStop=OrderStopLoss();
      double stepDistance=(source=="TRAILING" && EMA20_g_trailStep>0.0 ?
                           EMA20_g_trailStep/moneyPerPrice : 0.0);
      double tickSize=MarketInfo(Symbol(),MODE_TICKSIZE);
      if(tickSize<=0.0)
         tickSize=Point;
      double requiredImprovement=MathMax(stepDistance,tickSize*0.5);
      bool improves=(oldStop<=0.0 ||
                     (orderType==OP_BUY &&
                      candidate>oldStop+requiredImprovement-tickSize*0.1) ||
                     (orderType==OP_SELL &&
                      candidate<oldStop-requiredImprovement+tickSize*0.1));
      if(!improves)
         continue;

      int ticket=OrderTicket();
      ResetLastError();
      if(OrderModify(ticket,OrderOpenPrice(),candidate,OrderTakeProfit(),0,clrGold))
        {
         Print("XVISION EMA20 V12: ",source," moved ticket=",ticket,
               " SL to ",DoubleToString(candidate,Digits),
               " at net profit ",DoubleToString(netProfit,2)," ",AccountCurrency());
        }
      else
        {
         int error=GetLastError();
         if(TimeCurrent()-EMA20_g_lastManagementErrorPrint>=30)
           {
            Print("XVISION EMA20 V12: protection modification failed ticket=",ticket,
                  " error=",error," requested SL=",DoubleToString(candidate,Digits));
            EMA20_g_lastManagementErrorPrint=TimeCurrent();
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Prevent duplicate exposure from v1-v6 or another EA instance.   |
//+------------------------------------------------------------------+
bool EMA20_IsXVISIONExposureSelected()
  {
   if(OrderSymbol()!=Symbol())
      return(false);
   int magic=OrderMagicNumber();
   if(magic==EMA20_g_magic || magic==50503001 || magic==50503002 ||
      magic==50503003 || magic==50503004 || magic==50503005 ||
      magic==50503006)
      return(true);
   return(StringFind(OrderComment(),"XVE")==0);
  }

bool EMA20_HasEAExposure()
  {
   for(int pos=OrdersTotal()-1; pos>=0; pos--)
     {
      if(!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES))
         continue;
      if(EMA20_IsXVISIONExposureSelected())
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| EMA on one bar of the signal timeframe.                          |
//|                                                                  |
//| iMA() returns 0.0 while history is still synchronising (it sets  |
//| error 4066). Zero compared against a gold price always reads as  |
//| "price is above the EMA", which fabricates a BUY crossing -- so  |
//| a zero here must never reach a comparison. Callers check with    |
//| EMA20_EMAReady() or test the returned value before using it.          |
//+------------------------------------------------------------------+
double EMA20_EMAValue(const int shift)
  {
   double value=iMA(Symbol(),SignalTimeframe,EMA20_RESEARCH_EMA_PERIOD,0,MODE_EMA,PRICE_CLOSE,shift);
   if(!MathIsValidNumber(value) || value<=0.0)
      return(0.0);
   return(value);
  }

//+------------------------------------------------------------------+
//| True when every EMA value from shift 1 to deepestShift is usable.|
//+------------------------------------------------------------------+
bool EMA20_EMAReady(const int deepestShift)
  {
   for(int shift=1; shift<=deepestShift; shift++)
      if(EMA20_EMAValue(shift)<=0.0)
         return(false);
   return(true);
  }

double EMA20_MoneyPerPriceUnitPerLot()
  {
   double tickValue=MarketInfo(Symbol(),MODE_TICKVALUE);
   double tickSize=MarketInfo(Symbol(),MODE_TICKSIZE);
   if(tickValue<=0.0 || tickSize<=0.0)
      return(0.0);
   return(tickValue/tickSize);
  }

//+------------------------------------------------------------------+
//| Resolve a requested volume onto the broker's lot grid.           |
//|                                                                  |
//| v6 rejected anything that did not land exactly on the step, so on |
//| a broker whose MINLOT is 0.1 the default 0.01 meant the EA could  |
//| never open a single position -- it ran for weeks showing REJECT   |
//| in one dashboard field and nothing else.                         |
//|                                                                  |
//| Rounding DOWN can only reduce exposure below what was requested,  |
//| so it is the safe direction. Below the broker minimum there is no |
//| tradeable size at all, and that still fails.                     |
//+------------------------------------------------------------------+
bool EMA20_ResolveLotSize(const double requested,double &lots)
  {
   lots=0.0;
   double minimum=MarketInfo(Symbol(),MODE_MINLOT);
   double maximum=MarketInfo(Symbol(),MODE_MAXLOT);
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(minimum<=0.0 || maximum<=0.0 || step<=0.0 || requested<=0.0)
      return(false);

   double tolerance=MathMax(1.0e-8,step*1.0e-6);
   double capped=MathMin(requested,maximum);
   double executable=MathFloor(capped/step+tolerance)*step;

   if(executable<minimum-tolerance)
      return(false);

   lots=NormalizeDouble(executable,EMA20_LotDigits());
   return(lots>0.0);
  }

//+------------------------------------------------------------------+
//| Resolve the volume and report any adjustment. Trade paths use     |
//| this; the dashboard uses EMA20_ResolveLotSize() directly so that        |
//| refreshing the panel cannot spam the log.                        |
//+------------------------------------------------------------------+
bool EMA20_ResolveLotSizeForTrade(const double requested,double &lots)
  {
   if(!EMA20_ResolveLotSize(requested,lots))
     {
      Print("XVISION EMA20 V12: requested volume ",DoubleToString(requested,8),
            " is below the broker minimum ",
            DoubleToString(MarketInfo(Symbol(),MODE_MINLOT),8),
            " or the lot grid is unavailable; trade rejected.");
      return(false);
     }
   if(MathAbs(lots-requested)>1.0e-8)
      Print("XVISION EMA20 V12: volume ",DoubleToString(requested,8),
            " rounded down to ",DoubleToString(lots,EMA20_LotDigits()),
            " to fit the broker lot step of ",
            DoubleToString(MarketInfo(Symbol(),MODE_LOTSTEP),8),".");
   return(true);
  }

int EMA20_DecimalDigitsForValue(const double value)
  {
   double scaled=MathAbs(value);
   for(int digits=0; digits<=8; digits++)
     {
      if(MathAbs(scaled-MathRound(scaled))<=1.0e-8)
         return(digits);
      scaled*=10.0;
     }
   return(8);
  }

int EMA20_LotDigits()
  {
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   double minimum=MarketInfo(Symbol(),MODE_MINLOT);
   return((int)MathMax(EMA20_DecimalDigitsForValue(step),
                       EMA20_DecimalDigitsForValue(minimum)));
  }

int EMA20_SlippagePoints()
  {
   if(EMA20_g_maxSlippage<=0.0 || Point<=0.0)
      return(0);
   return((int)MathCeil(EMA20_g_maxSlippage/Point));
  }

bool EMA20_IsGoldSymbol()
  {
   string symbolName=Symbol();
   StringToUpper(symbolName);
   return(StringFind(symbolName,"GOLD")>=0 || StringFind(symbolName,"XAU")>=0);
  }

string EMA20_DirectionName(const int direction)
  {
   if(direction>0) return("BUY");
   if(direction<0) return("SELL");
   return("NONE");      // EMA20_g_retestDirection is legitimately 0 when idle
  }

string EMA20_BoolText(const bool value)
  {
   return(value ? "YES" : "NO");
  }

string EMA20_TimeframeName(const ENUM_TIMEFRAMES timeframe)
  {
   int resolved=(timeframe==PERIOD_CURRENT ? Period() : (int)timeframe);
   if(resolved==PERIOD_M1)  return("M1");
   if(resolved==PERIOD_M5)  return("M5");
   if(resolved==PERIOD_M15) return("M15");
   if(resolved==PERIOD_M30) return("M30");
   if(resolved==PERIOD_H1)  return("H1");
   if(resolved==PERIOD_H4)  return("H4");
   if(resolved==PERIOD_D1)  return("D1");
   if(resolved==PERIOD_W1)  return("W1");
   if(resolved==PERIOD_MN1) return("MN1");
   return(IntegerToString(resolved));
  }

//+------------------------------------------------------------------+
//| Persistent state prevents duplicate crossing trades on restart. |
//+------------------------------------------------------------------+
string EMA20_StateKey(const string suffix)
  {
   // Keep V7's XVE6 namespace and default magic for seamless takeover of an
   // existing protected position or pending retest when the EA is upgraded.
   int resolvedTimeframe=(SignalTimeframe==PERIOD_CURRENT ?
                          Period() : (int)SignalTimeframe);
   long symbolHash=0;
   string symbolName=Symbol();
   for(int index=0; index<StringLen(symbolName); index++)
      symbolHash=(symbolHash*131+StringGetCharacter(symbolName,index))%2147483647;
   return("XVE6_"+IntegerToString(AccountNumber())+"_"+
          IntegerToString((int)symbolHash)+"_"+
          IntegerToString(EMA20_g_magic)+"_"+IntegerToString(resolvedTimeframe)+"_"+
          IntegerToString(EMA20_RESEARCH_EMA_PERIOD)+"_"+suffix);
  }

bool EMA20_PersistentStateEnabled()
  {
   return(UsePersistentEpisodeState && !IsTesting());
  }

void EMA20_DeleteEpisodeState()
  {
   GlobalVariableDel(EMA20_StateKey("LOCK"));
   GlobalVariableDel(EMA20_StateKey("QUIET"));
   GlobalVariableDel(EMA20_StateKey("BAR"));
   GlobalVariableDel(EMA20_StateKey("SIGNAL"));
   GlobalVariableDel(EMA20_StateKey("RET_STATE"));
   GlobalVariableDel(EMA20_StateKey("RET_DIR"));
   GlobalVariableDel(EMA20_StateKey("RET_COUNT"));
   GlobalVariableDel(EMA20_StateKey("RET_SIGNAL"));
   GlobalVariableDel(EMA20_StateKey("RET_TICKET"));
   GlobalVariableDel(EMA20_StateKey("MKT_PENDING"));
   GlobalVariableDel(EMA20_StateKey("MKT_DIR"));
   GlobalVariableDel(EMA20_StateKey("MKT_ROUTE"));
   GlobalVariableDel(EMA20_StateKey("MKT_BAR"));
  }

void EMA20_LoadEpisodeState()
  {
   if(ResetPersistentStateOnInit && EMA20_PersistentStateEnabled())
      EMA20_DeleteEpisodeState();

   if(EMA20_PersistentStateEnabled() && GlobalVariableCheck(EMA20_StateKey("LOCK")))
     {
      EMA20_g_episodeLocked=(GlobalVariableGet(EMA20_StateKey("LOCK"))>0.5);
      EMA20_g_quietBars=(int)GlobalVariableGet(EMA20_StateKey("QUIET"));
      EMA20_g_lastProcessedBar=(datetime)GlobalVariableGet(EMA20_StateKey("BAR"));
      EMA20_g_lastSignalBar=(datetime)GlobalVariableGet(EMA20_StateKey("SIGNAL"));
      EMA20_g_retestState=(GlobalVariableCheck(EMA20_StateKey("RET_STATE")) ?
                     (int)GlobalVariableGet(EMA20_StateKey("RET_STATE")) : EMA20_RETEST_IDLE);
      EMA20_g_retestDirection=(GlobalVariableCheck(EMA20_StateKey("RET_DIR")) ?
                         (int)GlobalVariableGet(EMA20_StateKey("RET_DIR")) : 0);
      EMA20_g_retestCount=(GlobalVariableCheck(EMA20_StateKey("RET_COUNT")) ?
                     (int)GlobalVariableGet(EMA20_StateKey("RET_COUNT")) : 0);
      EMA20_g_retestSignalBar=(GlobalVariableCheck(EMA20_StateKey("RET_SIGNAL")) ?
                         (datetime)GlobalVariableGet(EMA20_StateKey("RET_SIGNAL")) : 0);
      EMA20_g_retestTicket=(GlobalVariableCheck(EMA20_StateKey("RET_TICKET")) ?
                      (int)GlobalVariableGet(EMA20_StateKey("RET_TICKET")) : 0);
      EMA20_g_marketEntryPending=(GlobalVariableCheck(EMA20_StateKey("MKT_PENDING")) &&
                            GlobalVariableGet(EMA20_StateKey("MKT_PENDING"))>0.5);
      EMA20_g_marketEntryDirection=(GlobalVariableCheck(EMA20_StateKey("MKT_DIR")) ?
                              (int)GlobalVariableGet(EMA20_StateKey("MKT_DIR")) : 0);
      EMA20_g_marketEntryRoute=(GlobalVariableCheck(EMA20_StateKey("MKT_ROUTE")) ?
                          (int)GlobalVariableGet(EMA20_StateKey("MKT_ROUTE")) :
                          EMA20_MARKET_ROUTE_NONE);
      EMA20_g_marketEntrySignalBar=(GlobalVariableCheck(EMA20_StateKey("MKT_BAR")) ?
                              (datetime)GlobalVariableGet(EMA20_StateKey("MKT_BAR")) : 0);
      if(EMA20_g_quietBars<0)
         EMA20_g_quietBars=0;
      if(EMA20_g_retestTicket<0)
         EMA20_g_retestTicket=0;
      datetime currentBar=iTime(Symbol(),SignalTimeframe,0);
      if(currentBar>0 && EMA20_g_lastProcessedBar>currentBar)
         EMA20_g_lastProcessedBar=currentBar;
      if(EMA20_g_retestState<EMA20_RETEST_IDLE || EMA20_g_retestState>EMA20_RETEST_USED ||
         EMA20_g_retestDirection<-1 || EMA20_g_retestDirection>1 || EMA20_g_retestCount<0 ||
         (EMA20_g_retestState!=EMA20_RETEST_IDLE && EMA20_g_retestDirection==0))
        {
         EMA20_g_retestState=EMA20_RETEST_IDLE;
         EMA20_g_retestDirection=0;
         EMA20_g_retestCount=0;
         EMA20_g_retestSignalBar=0;
         EMA20_g_retestTicket=0;
        }
      if(EMA20_g_marketEntryPending &&
         ((EMA20_g_marketEntryDirection!=1 && EMA20_g_marketEntryDirection!=-1) ||
          EMA20_g_marketEntryRoute!=EMA20_MARKET_ROUTE_RESEARCH ||
          EMA20_g_marketEntrySignalBar<=0))
        {
         EMA20_g_marketEntryPending=false;
         EMA20_g_marketEntryDirection=0;
         EMA20_g_marketEntryRoute=EMA20_MARKET_ROUTE_NONE;
         EMA20_g_marketEntrySignalBar=0;
        }
      EMA20_g_retestStatus=(EMA20_g_retestState==EMA20_RETEST_IDLE ?
                      "Waiting for a live EMA crossing" :
                      "Restored state: "+EMA20_RetestStateName());
     }
   else
     {
      EMA20_g_episodeLocked=false;
      EMA20_g_quietBars=0;
      EMA20_g_lastSignalBar=0;
      EMA20_g_lastProcessedBar=(TradeCurrentSignalOnAttach ? 0 :
                          iTime(Symbol(),SignalTimeframe,0));
      EMA20_g_retestState=EMA20_RETEST_IDLE;
      EMA20_g_retestDirection=0;
      EMA20_g_retestCount=0;
      EMA20_g_retestSignalBar=0;
      EMA20_g_retestTicket=0;
      EMA20_g_retestStatus="Waiting for a live EMA crossing";
      EMA20_g_marketEntryPending=false;
      EMA20_g_marketEntryDirection=0;
      EMA20_g_marketEntryRoute=EMA20_MARKET_ROUTE_NONE;
      EMA20_g_marketEntrySignalBar=0;
     }
  }

void EMA20_SaveEpisodeState()
  {
   if(!EMA20_PersistentStateEnabled())
      return;
   GlobalVariableSet(EMA20_StateKey("LOCK"),(EMA20_g_episodeLocked ? 1.0 : 0.0));
   GlobalVariableSet(EMA20_StateKey("QUIET"),(double)EMA20_g_quietBars);
   GlobalVariableSet(EMA20_StateKey("BAR"),(double)EMA20_g_lastProcessedBar);
   GlobalVariableSet(EMA20_StateKey("SIGNAL"),(double)EMA20_g_lastSignalBar);
   GlobalVariableSet(EMA20_StateKey("RET_STATE"),(double)EMA20_g_retestState);
   GlobalVariableSet(EMA20_StateKey("RET_DIR"),(double)EMA20_g_retestDirection);
   GlobalVariableSet(EMA20_StateKey("RET_COUNT"),(double)EMA20_g_retestCount);
   GlobalVariableSet(EMA20_StateKey("RET_SIGNAL"),(double)EMA20_g_retestSignalBar);
   GlobalVariableSet(EMA20_StateKey("RET_TICKET"),(double)EMA20_g_retestTicket);
   GlobalVariableSet(EMA20_StateKey("MKT_PENDING"),(EMA20_g_marketEntryPending ? 1.0 : 0.0));
   GlobalVariableSet(EMA20_StateKey("MKT_DIR"),(double)EMA20_g_marketEntryDirection);
   GlobalVariableSet(EMA20_StateKey("MKT_ROUTE"),(double)EMA20_g_marketEntryRoute);
   GlobalVariableSet(EMA20_StateKey("MKT_BAR"),(double)EMA20_g_marketEntrySignalBar);
   GlobalVariablesFlush();
  }

void EMA20_DeleteDashboard()
  {
   for(int index=ObjectsTotal()-1; index>=0; index--)
     {
      string name=ObjectName(index);
      if(StringFind(name,EMA20_g_dashboardPrefix)==0)
         ObjectDelete(0,name);
     }
   EMA20_g_panelBuilt=false;
  }

//+------------------------------------------------------------------+
//| Create the label once, then touch only what changed.             |
//| Returns true when this call actually altered the chart, so the   |
//| caller can decide whether a redraw is warranted at all.          |
//+------------------------------------------------------------------+
bool EMA20_SetDashboardLabel(const string id,const string value,const int y,
                       const color textColor,const int fontSize=0)
  {
   string name=EMA20_g_dashboardPrefix+id;
   bool   rebuild=!EMA20_g_panelBuilt;

   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0))
         return(false);
      rebuild=true;
     }

   // Geometry and style are static between re-initializations, so they are
   // applied on creation and after a geometry change -- not on every tick.
   if(rebuild)
     {
      int resolvedFont=(fontSize>0 ? (int)MathRound(fontSize*EMA20_g_panelScale) : EMA20_g_panelFont);
      resolvedFont=(int)MathMax(6,resolvedFont);
      ObjectSetInteger(0,name,OBJPROP_CORNER,DashboardCorner);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,EMA20_g_panelX+16);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,EMA20_g_panelY+EMA20_PanelRow(y));
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,resolvedFont);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_ZORDER,101);
      ObjectSetString(0,name,OBJPROP_FONT,"Arial");
     }

   bool changed=rebuild;
   if(ObjectGetString(0,name,OBJPROP_TEXT)!=value)
     {
      ObjectSetString(0,name,OBJPROP_TEXT,value);
      changed=true;
     }
   if((color)ObjectGetInteger(0,name,OBJPROP_COLOR)!=textColor)
     {
      ObjectSetInteger(0,name,OBJPROP_COLOR,textColor);
      changed=true;
     }
   if(changed)
      EMA20_g_panelChanged=true;
   return(changed);
  }

//+------------------------------------------------------------------+
//| Character budget for one row, derived from the resolved panel    |
//| width and font rather than a fixed 57 that assumed both.         |
//+------------------------------------------------------------------+
string EMA20_DashboardTextLimit(const string value,const int maximum=0)
  {
   int budget=maximum;
   if(budget<=0)
      budget=(int)MathMax(12,(EMA20_g_panelWidth-32)/MathMax(1.0,EMA20_g_panelFont*0.62));
   if(StringLen(value)<=budget)
      return(value);
   return(StringSubstr(value,0,budget-3)+"...");
  }

//+------------------------------------------------------------------+
//| Summarise exposure, separating what this instance manages from    |
//| what merely blocks it.                                            |
//|                                                                  |
//| EMA20_HasEAExposure() blocks on any XVISION magic (50503001-50503006) or |
//| any "XVE" comment, but EMA20_ManageInputProtection() only trails orders  |
//| carrying THIS instance's EMA20_g_magic. So a leftover position from  |
//| an earlier version stops new entries and is never given a         |
//| trailing stop. Taking over another EA's orders would be worse, so  |
//| the asymmetry stays -- but it is now reported instead of silent.   |
//+------------------------------------------------------------------+
string EMA20_PositionSummary(double &floatingProfit,int &foreignCount)
  {
   floatingProfit=0.0;
   foreignCount=0;
   int positionCount=0;
   string firstPosition="";
   for(int pos=OrdersTotal()-1; pos>=0; pos--)
     {
      if(!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES))
         continue;
      if(!EMA20_IsXVISIONExposureSelected())
         continue;
      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL)
         continue;
      floatingProfit+=OrderProfit()+OrderSwap()+OrderCommission();
      positionCount++;
      if(OrderMagicNumber()!=EMA20_g_magic)
         foreignCount++;
      string side=(OrderType()==OP_BUY ? "BUY" : "SELL");
      if(firstPosition=="")
         firstPosition=side+"  #"+IntegerToString(OrderTicket())+"  lot "+
                       DoubleToString(OrderLots(),EMA20_LotDigits());
     }
   if(positionCount<=0)
      return("NONE");
   if(positionCount==1)
      return(firstPosition);
   return("MULTIPLE x"+IntegerToString(positionCount));
  }

void EMA20_UpdateDashboard(const bool force=false)
  {
   if(!ShowDashboard)
     {
      if(EMA20_g_panelBuilt)
         EMA20_DeleteDashboard();          // once, not on every tick
      return;
     }

   // A non-visual backtest has no chart to draw on; drawing there is pure cost.
   if(IsTesting() && !IsVisualMode())
      return;

   if(!force && EMA20_g_panelRefreshMs>0 &&
      (uint)(GetTickCount()-EMA20_g_lastPanelRefresh)<(uint)EMA20_g_panelRefreshMs)
      return;
   EMA20_g_lastPanelRefresh=GetTickCount();
   EMA20_g_panelChanged=false;

   string background=EMA20_g_dashboardPrefix+"BACKGROUND";
   if(ObjectFind(0,background)<0)
     {
      ObjectCreate(0,background,OBJ_RECTANGLE_LABEL,0,0,0);
      EMA20_g_panelBuilt=false;
     }
   if(!EMA20_g_panelBuilt)
     {
      ObjectSetInteger(0,background,OBJPROP_CORNER,DashboardCorner);
      ObjectSetInteger(0,background,OBJPROP_XDISTANCE,EMA20_g_panelX);
      ObjectSetInteger(0,background,OBJPROP_YDISTANCE,EMA20_g_panelY);
      ObjectSetInteger(0,background,OBJPROP_XSIZE,EMA20_g_panelWidth);
      ObjectSetInteger(0,background,OBJPROP_YSIZE,EMA20_g_panelHeight);
      ObjectSetInteger(0,background,OBJPROP_BGCOLOR,DashboardBackground);
      ObjectSetInteger(0,background,OBJPROP_COLOR,DashboardBorder);
      ObjectSetInteger(0,background,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,background,OBJPROP_STYLE,STYLE_SOLID);
      ObjectSetInteger(0,background,OBJPROP_WIDTH,1);
      ObjectSetInteger(0,background,OBJPROP_BACK,false);
      ObjectSetInteger(0,background,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,background,OBJPROP_SELECTED,false);
      ObjectSetInteger(0,background,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,background,OBJPROP_ZORDER,100);
      EMA20_g_panelChanged=true;
     }

   RefreshRates();
   double floatingProfit=0.0;
   int foreignPositions=0;
   string position=EMA20_PositionSummary(floatingProfit,foreignPositions);
   double spread=MathMax(0.0,Ask-Bid);
   bool spreadAllowed=(EMA20_g_maxSpread<=0.0 || spread<=EMA20_g_maxSpread);
   double executableLot=0.0;
   bool lotAllowed=EMA20_ResolveLotSize(EMA20_g_fixedLot,executableLot);
   bool tradingAllowed=(!EMA20_g_tradingBlocked && IsTradeAllowed() && !IsTradeContextBusy() &&
                        MarketInfo(Symbol(),MODE_TRADEALLOWED)>0.5);
   string episode=(EMA20_g_episodeLocked ? "LOCKED" : "ARMED");
   string signalTime=(EMA20_g_lastSignalBar>0 ?
                      TimeToString(EMA20_g_lastSignalBar,TIME_DATE|TIME_MINUTES) : "none");
   string marketGate=(EMA20_g_marketEntryPending ?
                      "WAIT "+EMA20_DirectionName(EMA20_g_marketEntryDirection) : "IDLE");

   EMA20_SetDashboardLabel("TITLE","XVISION  |  GOLD EMA20 RESEARCH EA V9",12,DashboardAccent,14);
   EMA20_SetDashboardLabel("SUBTITLE",EMA20_TimeframeName(SignalTimeframe)+" SIGNAL  |  EMA "+
                     IntegerToString(EMA20_RESEARCH_EMA_PERIOD)+"  |  G2 + V3/A  |  2-CLOSE <= "+
                     DoubleToString(EMA20_g_maxMarketEntryDistanceATR,2)+" ATR",36,DashboardText,9);
   EMA20_SetDashboardLabel("H_STATUS","STATUS",59,DashboardHeading,10);
   EMA20_SetDashboardLabel("DECISION",EMA20_DashboardTextLimit(EMA20_g_lastDecision),77,DashboardText,11);
   EMA20_SetDashboardLabel("SIGNAL","Last qualified: "+signalTime+
                     "  |  market gate "+marketGate,97,DashboardText,10);
   EMA20_SetDashboardLabel("LOCK","Episode: "+episode+"  |  quiet "+IntegerToString(EMA20_g_quietBars)+
                     "/"+IntegerToString(EMA20_g_quietBarsRequired),115,
                     (EMA20_g_episodeLocked ? clrOrange : clrLime),10);

   EMA20_SetDashboardLabel("H_FILTERS","SIGNAL FILTERS",140,DashboardHeading,10);
   EMA20_SetDashboardLabel("GRADIENT","EMA20 G2  "+DoubleToString(EMA20_g_currentSlope,4)+
                     "  |  last directional  "+DoubleToString(EMA20_g_lastDirectionalGradient,4)+
                     "  (min "+DoubleToString(EMA20_g_minDirectionalGradient,4)+")",
                     158,DashboardText,10);
   EMA20_SetDashboardLabel("RANGE","Range votes  "+IntegerToString(EMA20_g_currentRangeVotes)+
                     "/3  |  efficiency  "+DoubleToString(EMA20_g_currentEfficiency,3),
                     194,DashboardText,10);

   string retestDirection=(EMA20_g_retestDirection==0 ? "NONE" : EMA20_DirectionName(EMA20_g_retestDirection));
   color retestColor=(EMA20_g_retestState==EMA20_RETEST_ARMED || EMA20_g_retestState==EMA20_RETEST_PENDING ?
                      clrLime : (EMA20_g_retestState==EMA20_RETEST_USED ? clrOrange : DashboardText));
   EMA20_SetDashboardLabel("H_RETEST","EMA RETEST ENGINE",219,DashboardHeading,10);
   EMA20_SetDashboardLabel("RETEST_STATE","State  "+EMA20_RetestStateName()+"  |  direction "+
                     retestDirection+"  |  used "+IntegerToString(EMA20_g_retestCount)+"/"+
                     IntegerToString(EMA20_g_maxRetestsPerLeg),237,retestColor,10);
   EMA20_SetDashboardLabel("RETEST_STATUS",EMA20_DashboardTextLimit(EMA20_g_retestStatus),255,retestColor,10);

   EMA20_SetDashboardLabel("H_TRADE","POSITION / PROTECTION",280,DashboardHeading,10);
   EMA20_SetDashboardLabel("POSITION","Position: "+position+"  |  P/L "+
                     (floatingProfit>=0.0 ? "+" : "")+DoubleToString(floatingProfit,2)+
                     (foreignPositions>0 ? "  |  "+IntegerToString(foreignPositions)+
                      " UNMANAGED (other magic)" : ""),
                     298,(foreignPositions>0 ? clrOrange :
                          (floatingProfit>=0.0 ? clrLime : clrTomato)),10);
   EMA20_SetDashboardLabel("LOT","Requested lot  "+DoubleToString(EMA20_g_fixedLot,EMA20_LotDigits())+
                     "  |  executable  "+(lotAllowed ? DoubleToString(executableLot,EMA20_LotDigits()) : "REJECT"),
                     316,(lotAllowed ? clrLime : clrTomato),10);
   EMA20_SetDashboardLabel("RISK","SL / TP ("+AccountCurrency()+")  "+
                     (EMA20_g_stopLossMoney>0.0 ? DoubleToString(EMA20_g_stopLossMoney,2) : "OFF")+" / "+
                     (EMA20_g_takeProfitMoney>0.0 ? DoubleToString(EMA20_g_takeProfitMoney,2) : "OFF"),
                     334,DashboardText,10);
   EMA20_SetDashboardLabel("TRAIL","Trailing  "+(EMA20_g_enableTrailing ? "ON" : "OFF")+
                     (EMA20_g_enableTrailing ? "  start / distance / step  "+
                      DoubleToString(EMA20_g_trailStart,2)+" / "+
                      DoubleToString(EMA20_g_trailDistance,2)+" / "+
                      DoubleToString(EMA20_g_trailStep,2) : ""),
                     352,(EMA20_g_enableTrailing ? clrLime : DashboardText),10);
   EMA20_SetDashboardLabel("PROFIT_LOCK","Profit lock  "+(EMA20_g_enableProfitLock ? "ON" : "OFF")+
                     (EMA20_g_enableProfitLock ? "  trigger / lock  "+
                      DoubleToString(EMA20_g_lockTrigger,2)+" / "+
                      DoubleToString(EMA20_g_lockMoney,2) : ""),
                     370,(EMA20_g_enableProfitLock ? clrLime : DashboardText),10);

   EMA20_SetDashboardLabel("H_LIVE","LIVE",395,DashboardHeading,10);
   EMA20_SetDashboardLabel("MARKET","Bid / Ask  "+DoubleToString(Bid,Digits)+" / "+
                     DoubleToString(Ask,Digits)+"  |  spread "+DoubleToString(spread,Digits)+
                     " (max "+DoubleToString(EMA20_g_maxSpread,Digits)+")  "+
                     (spreadAllowed ? "ENABLED" : "BLOCKED"),413,
                     (spreadAllowed ? clrLime : clrTomato),10);
   EMA20_SetDashboardLabel("PERMISSION",EMA20_DashboardTextLimit("Trade permission  "+
                     (tradingAllowed ? "ENABLED" : "BLOCKED")+
                     (EMA20_g_tradingBlocked ? "  |  "+EMA20_g_blockReason
                                       : "  |  EA modifies SL only; no forced close")),431,
                     (tradingAllowed ? clrLime : clrTomato),10);

   EMA20_g_panelBuilt=true;
   if(EMA20_g_panelChanged)
      ChartRedraw();          // only when the panel actually changed
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Shared exposure coordination                                     |
//|                                                                  |
//| Each module scopes its own exposure checks to its own magic, so   |
//| left alone they trade independently and can both be in the market |
//| at once. This is the only place the two are coupled, and it stays |
//| inert unless OnePositionAcrossModules is switched on - so the     |
//| default preserves each module's original behaviour exactly.       |
//+------------------------------------------------------------------+
bool SG_ForeignModulePositionOpen(const int callerMagic)
  {
   if(!OnePositionAcrossModules)
      return(false);

   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES))
         continue;
      if(OrderSymbol()!=Symbol())
         continue;
      int t=OrderType();
      if(t!=OP_BUY && t!=OP_SELL && t!=OP_BUYSTOP && t!=OP_SELLSTOP)
         continue;
      int m=OrderMagicNumber();
      if(m==callerMagic)
         continue;
      if(m==GSV11_MAGIC_NUMBER || m==MagicNumber)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Unified event handlers                                           |
//|                                                                  |
//| One EA, two signal modules, both live on every tick.             |
//|                                                                  |
//| OnInit never returns a non-zero value. A module that fails to     |
//| initialise is marked not-ready and skipped; the other still runs. |
//| In MT4 a non-zero return removes the expert from the chart, and   |
//| one module's bad input should not take the whole EA down.        |
//+------------------------------------------------------------------+
bool SG_g_scalperReady=false;
bool SG_g_ema20Ready=false;

int OnInit()
  {
   SG_g_scalperReady=false;
   SG_g_ema20Ready=false;

   if(EnableScalperModule)
     {
      SG_g_scalperReady=(GSV11_OnInit()==INIT_SUCCEEDED);
      if(!SG_g_scalperReady)
         Print("SUPERGOLD: scalper module failed to initialise and is disabled "
               "for this session; see the messages above. The EA stays attached.");
     }

   if(EnableEMA20Module)
     {
      SG_g_ema20Ready=(EMA20_OnInit()==INIT_SUCCEEDED);
      if(!SG_g_ema20Ready)
         Print("SUPERGOLD: EMA20 module failed to initialise and is disabled "
               "for this session. The EA stays attached.");
     }

   if(!SG_g_scalperReady && !SG_g_ema20Ready)
      Print("SUPERGOLD: no module is active. Enable one in the inputs.");
   else
      Print("SUPERGOLD initialised on ",Symbol(),
            "  scalper=",(SG_g_scalperReady?"on":"off"),
            "  ema20=",(SG_g_ema20Ready?"on":"off"),
            "  sharedExposureCap=",(OnePositionAcrossModules?"on":"off"));

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(SG_g_scalperReady) GSV11_OnDeinit(reason);
   if(SG_g_ema20Ready)   EMA20_OnDeinit(reason);
  }

void OnTick()
  {
   if(SG_g_scalperReady) GSV11_OnTick();
   if(SG_g_ema20Ready)   EMA20_OnTick();
  }

void OnTimer()
  {
   // Only the scalper installs a timer; the EMA20 module is tick-driven.
   if(SG_g_scalperReady) GSV11_OnTimer();
  }
//+------------------------------------------------------------------+
