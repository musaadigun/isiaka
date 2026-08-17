//+------------------------------------------------------------------+
//|                 XVISION_Gold_EMA50_Directional_EA_v7.mq4        |
//|  EMA-50 crossing and first-retest entries on a configurable      |
//|  signal timeframe.                                               |
//|                                                                  |
//|  v7 changes from v6:                                             |
//|   - OnInit() NEVER returns a non-zero value. In MT4 that removes |
//|     the expert from the chart, and because OnDeinit() has already |
//|     deleted the panel the EA simply vanishes -- which is what    |
//|     "it crashes when I change an input" actually was. v6 had     |
//|     fourteen such traps. Every repairable one is now clamped and |
//|     reported; the two genuinely unusable states (a non-gold      |
//|     symbol under RestrictToGoldSymbols, and an untradeable lot   |
//|     size) block trading while the EA stays attached and says so. |
//|   - Every tunable input is read through a resolved g_* copy, so  |
//|     a clamped value is the one the logic actually uses.          |
//|   - The dashboard no longer rewrites every object property on    |
//|     every tick, and only redraws when something actually         |
//|     changed.                                                     |
//|   - The panel layout scales with the font size.                  |
//+------------------------------------------------------------------+
#property strict
#property version   "7.00"
#property description "Directional Gold EMA-50 EA with normalized gradient, range voting,"
#property description "crossing/reversal routes, EMA retest confirmation, and input protection."

// Trading controls.
input int                MagicNumber                         = 50503006;
input double             FixedLotSize                        = 0.01;
input bool               EnableBuyTrades                     = true;
input bool               EnableSellTrades                    = true;
input bool               RestrictToGoldSymbols               = true;

// Signal construction. All decisions use completed candles.
input ENUM_TIMEFRAMES    SignalTimeframe                     = PERIOD_M30;
input int                EMA_Period                          = 50;
input int                ATR_Period                          = 14;
input int                GradientLookbackBars                = 3;

// Continuation route.
input double             ContinuationGradientMinimum        = 0.04;
input int                MaximumRangeVotesForContinuation    = 1;

// Range votes: repeated crossings, flat EMA, and inefficient price path.
input int                RangeLookbackBars                   = 8;
input int                RangeCrossingVoteMinimum            = 3;
input double             FlatGradientThreshold               = 0.02;
input double             MinimumDirectionalEfficiency        = 0.25;

// Reversal-breakout route.
input double             ReversalMinimumCloseDistanceATR     = 0.60;
input double             ReversalMinimumGradientImprovement  = 0.03;
input double             ReversalMinimumBodyATR              = 0.50;
input double             ReversalMinimumDirectionalGradient  = 0.00;

// First EMA50 retest route. The sequence must be observed live.
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

datetime g_lastProcessedBar=0;
datetime g_lastSignalBar=0;
bool     g_episodeLocked=false;
int      g_quietBars=0;
string   g_lastDecision="Waiting for first completed M30 candle";
double   g_lastSlope=0.0;
double   g_lastDirectionalGradient=0.0;
double   g_lastEfficiency=0.0;
int      g_lastRangeVotes=0;
double   g_currentSlope=0.0;
double   g_currentEfficiency=0.0;
int      g_currentRangeVotes=0;
// v6 left the three g_current* values holding the PREVIOUS bar's numbers when
// UpdateCurrentDiagnostics() bailed out, and then gated live entries on them.
bool     g_diagnosticsValid=false;
// The retest pending order is tracked by ticket. v6 identified it by order
// comment, which brokers rewrite, orphaning the order and allowing a duplicate.
int      g_retestTicket=0;
enum ENUM_RETEST_STATE
  {
   RETEST_IDLE=0,
   RETEST_WAIT_MOVE=1,
   RETEST_ARMED=2,
   RETEST_PENDING=3,
   RETEST_USED=4
  };

int      g_retestState=RETEST_IDLE;
int      g_retestDirection=0;
int      g_retestCount=0;
datetime g_retestSignalBar=0;
string   g_retestStatus="Waiting for a live EMA crossing";
string   g_dashboardPrefix="XVE6_PANEL_";
datetime g_lastManagementErrorPrint=0;
#define PENDING_DELETE_RETRY_SECONDS 5
datetime g_lastPendingDeleteAttempt=0;

// Resolved (clamped) dashboard geometry. The inputs themselves are read-only,
// and a cosmetic value must never be able to unload a trading EA, so every
// panel dimension is validated into these instead of rejected.
int      g_panelX=12;
int      g_panelY=24;
int      g_panelWidth=430;
int      g_panelHeight=472;
int      g_panelFont=10;
double   g_panelScale=1.0;      // v6's layout was hand-placed for font size 10
int      g_panelRefreshMs=250;
uint     g_lastPanelRefresh=0;
bool     g_panelBuilt=false;
bool     g_panelChanged=false;

// Resolved (clamped) trading inputs. Every tunable value is read from these
// rather than from the input variables directly, so that a value which cannot
// be used is repaired and reported instead of unloading the EA.
int      g_magic=50503006;
double   g_fixedLot=0.01;
int      g_emaPeriod=50;
int      g_atrPeriod=14;
int      g_gradientLookback=3;
double   g_contGradientMin=0.04;
int      g_maxRangeVotes=1;
int      g_rangeLookback=8;
int      g_rangeCrossVoteMin=3;
double   g_flatGradientThreshold=0.02;
double   g_minEfficiency=0.25;
double   g_revMinCloseDistATR=0.60;
double   g_revMinGradImprove=0.03;
double   g_revMinBodyATR=0.50;
double   g_revMinDirGradient=0.00;
bool     g_enableRetest=true;
int      g_retestTrendCloses=3;
double   g_retestMinMoveAwayATR=0.50;
double   g_retestTouchTolATR=0.10;
double   g_retestMaxPenetrationATR=0.25;
double   g_retestMinRecoveryATR=0.10;
double   g_retestMinCloseLocPct=65.0;
double   g_retestEntryBufferATR=0.05;
int      g_retestExpiryBars=2;
int      g_maxRetestsPerLeg=1;
int      g_quietBarsRequired=4;
double   g_stopLossMoney=5.00;
double   g_takeProfitMoney=5.00;
double   g_maxSpread=0.20;
double   g_maxEntryDeviation=2.00;
double   g_maxSlippage=0.50;
bool     g_enableTrailing=false;
double   g_trailStart=5.00;
double   g_trailDistance=2.00;
double   g_trailStep=0.50;
bool     g_enableProfitLock=false;
double   g_lockTrigger=5.00;
double   g_lockMoney=1.00;

// Set when the EA cannot trade at all but must stay on the chart anyway.
bool     g_tradingBlocked=false;
string   g_blockReason="";

//+------------------------------------------------------------------+
//| Initialization.                                                  |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Nothing below may return a non-zero value. See ResolveInputs().
   ResolveDashboardGeometry();
   ResolveInputs();
   g_panelBuilt=false;

   LoadEpisodeState();
   RecoverRetestOrderState();
   if(HasEAExposure())
      g_episodeLocked=true;
   SaveEpisodeState();

   UpdateDashboard(true);
   Print("XVISION EMA50 V7 initialized on ",Symbol(),
         " timeframe=",TimeframeName(SignalTimeframe),
         " magic=",g_magic,
         " locked=",BoolText(g_episodeLocked),
         " quietBars=",g_quietBars,
         " trading=",(g_tradingBlocked ? "BLOCKED ("+g_blockReason+")" : "enabled"));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinitialization.                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   SaveEpisodeState();
   DeleteDashboard();
  }

//+------------------------------------------------------------------+
//| Tick handler.                                                    |
//+------------------------------------------------------------------+
void OnTick()
  {
   ManageRetestOrders();
   ManageInputProtection();
   ProcessNewSignalBar();
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Resolve every tunable input into a usable value.                 |
//|                                                                  |
//| THE RULE: OnInit() must never return a non-zero value. In MT4    |
//| that removes the expert from the chart, and because OnDeinit()   |
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
//| grid. Both set g_tradingBlocked, which stops orders and says so  |
//| on the dashboard instead of unloading the EA.                    |
//+------------------------------------------------------------------+
void ClampInt(const string name,const int requested,const int low,
              const int high,int &target)
  {
   target=(int)MathMax(low,MathMin(high,requested));
   if(target!=requested)
      Print("XVISION EMA50 V7: ",name," ",requested," clamped to ",target,".");
  }

void ClampDouble(const string name,const double requested,const double low,
                 const double high,double &target)
  {
   target=MathMax(low,MathMin(high,requested));
   if(MathAbs(target-requested)>1.0e-12)
      Print("XVISION EMA50 V7: ",name," ",DoubleToString(requested,4),
            " clamped to ",DoubleToString(target,4),".");
  }

void ResolveInputs()
  {
   g_tradingBlocked=false;
   g_blockReason="";

   ClampInt("MagicNumber",MagicNumber,1,2147483647,g_magic);
   ClampInt("EMA_Period",EMA_Period,2,10000,g_emaPeriod);
   ClampInt("ATR_Period",ATR_Period,2,10000,g_atrPeriod);
   ClampInt("GradientLookbackBars",GradientLookbackBars,1,10000,g_gradientLookback);
   ClampInt("RangeLookbackBars",RangeLookbackBars,2,10000,g_rangeLookback);

   // Coupled: the vote threshold cannot exceed the window it counts within.
   ClampInt("RangeCrossingVoteMinimum",RangeCrossingVoteMinimum,1,
            g_rangeLookback,g_rangeCrossVoteMin);
   ClampInt("MaximumRangeVotesForContinuation",MaximumRangeVotesForContinuation,
            0,3,g_maxRangeVotes);

   ClampDouble("ContinuationGradientMinimum",ContinuationGradientMinimum,
               0.0,1000.0,g_contGradientMin);
   ClampDouble("FlatGradientThreshold",FlatGradientThreshold,0.0,1000.0,
               g_flatGradientThreshold);
   // An efficiency is a ratio; typing it as a percentage is the obvious slip.
   ClampDouble("MinimumDirectionalEfficiency",MinimumDirectionalEfficiency,
               0.0,1.0,g_minEfficiency);

   ClampDouble("ReversalMinimumCloseDistanceATR",ReversalMinimumCloseDistanceATR,
               0.0,1000.0,g_revMinCloseDistATR);
   ClampDouble("ReversalMinimumGradientImprovement",ReversalMinimumGradientImprovement,
               0.0,1000.0,g_revMinGradImprove);
   ClampDouble("ReversalMinimumBodyATR",ReversalMinimumBodyATR,0.0,1000.0,
               g_revMinBodyATR);
   ClampDouble("ReversalMinimumDirectionalGradient",ReversalMinimumDirectionalGradient,
               0.0,1000.0,g_revMinDirGradient);

   g_enableRetest=EnableEMARetestEntry;
   ClampInt("RetestTrendClosesRequired",RetestTrendClosesRequired,2,10000,
            g_retestTrendCloses);
   ClampDouble("RetestMinimumMoveAwayATR",RetestMinimumMoveAwayATR,0.0,1000.0,
               g_retestMinMoveAwayATR);
   ClampDouble("RetestTouchToleranceATR",RetestTouchToleranceATR,0.0,1000.0,
               g_retestTouchTolATR);
   ClampDouble("RetestMaximumPenetrationATR",RetestMaximumPenetrationATR,0.0,1000.0,
               g_retestMaxPenetrationATR);
   ClampDouble("RetestMinimumRecoveryCloseATR",RetestMinimumRecoveryCloseATR,
               0.0,1000.0,g_retestMinRecoveryATR);
   ClampDouble("RetestMinimumCloseLocationPercent",RetestMinimumCloseLocationPercent,
               50.0,100.0,g_retestMinCloseLocPct);
   ClampDouble("RetestEntryBufferATR",RetestEntryBufferATR,0.0,1000.0,
               g_retestEntryBufferATR);
   ClampInt("RetestPendingExpiryBars",RetestPendingExpiryBars,1,10000,
            g_retestExpiryBars);
   ClampInt("MaximumRetestsPerTrendLeg",MaximumRetestsPerTrendLeg,1,100,
            g_maxRetestsPerLeg);

   ClampInt("QuietBarsRequiredToRearm",QuietBarsRequiredToRearm,1,10000,
            g_quietBarsRequired);

   ClampDouble("StopLossMoney",StopLossMoney,0.0,1.0e9,g_stopLossMoney);
   ClampDouble("TakeProfitMoney",TakeProfitMoney,0.0,1.0e9,g_takeProfitMoney);
   ClampDouble("MaximumSpreadMovement",MaximumSpreadMovement,0.0,1.0e9,g_maxSpread);
   ClampDouble("MaximumEntryDeviationMovement",MaximumEntryDeviationMovement,
               0.0,1.0e9,g_maxEntryDeviation);
   ClampDouble("MaximumSlippageMovement",MaximumSlippageMovement,0.0,1.0e9,
               g_maxSlippage);

   // Trailing with a zero distance would park the stop on the current price and
   // close the trade immediately. There is no safe value to invent, so the
   // feature switches itself off rather than acting on a nonsensical setting.
   g_enableTrailing=EnableTrailingStop;
   ClampDouble("TrailingStartMoney",TrailingStartMoney,0.0,1.0e9,g_trailStart);
   ClampDouble("TrailingStepMoney",TrailingStepMoney,0.0,1.0e9,g_trailStep);
   g_trailDistance=TrailingDistanceMoney;
   if(g_enableTrailing && g_trailDistance<=0.0)
     {
      g_enableTrailing=false;
      Print("XVISION EMA50 V7: TrailingDistanceMoney must be positive; "
            "trailing stop disabled for this session. Trading continues.");
     }

   // Locking at or above the trigger can never fire. Pull the lock under the
   // trigger rather than discarding the user's intent entirely.
   g_enableProfitLock=EnableProfitLock;
   ClampDouble("ProfitLockTriggerMoney",ProfitLockTriggerMoney,0.0,1.0e9,g_lockTrigger);
   ClampDouble("ProfitLockMoney",ProfitLockMoney,0.0,1.0e9,g_lockMoney);
   if(g_enableProfitLock && g_lockTrigger<=0.0)
     {
      g_enableProfitLock=false;
      Print("XVISION EMA50 V7: ProfitLockTriggerMoney must be positive; "
            "profit lock disabled for this session. Trading continues.");
     }
   else if(g_enableProfitLock && g_lockMoney>=g_lockTrigger)
     {
      double reduced=g_lockTrigger*0.5;
      Print("XVISION EMA50 V7: ProfitLockMoney ",DoubleToString(g_lockMoney,2),
            " is not below its trigger ",DoubleToString(g_lockTrigger,2),
            "; reduced to ",DoubleToString(reduced,2),".");
      g_lockMoney=reduced;
     }

   // Lot size is the one number the EA cannot invent on the user's behalf,
   // but an unusable value blocks trading rather than unloading the EA.
   g_fixedLot=FixedLotSize;
   double probe=0.0;
   if(g_fixedLot<=0.0 || !ResolveLotSize(g_fixedLot,probe))
     {
      g_tradingBlocked=true;
      g_blockReason="FixedLotSize "+DoubleToString(FixedLotSize,4)+
                    " is not tradeable on this symbol";
      Print("XVISION EMA50 V7: ",g_blockReason,
            " (min ",DoubleToString(MarketInfo(Symbol(),MODE_MINLOT),4),
            ", step ",DoubleToString(MarketInfo(Symbol(),MODE_LOTSTEP),4),
            "). The EA stays attached and will not trade until this is fixed.");
     }

   if(RestrictToGoldSymbols && !IsGoldSymbol())
     {
      g_tradingBlocked=true;
      g_blockReason="RestrictToGoldSymbols is on and "+Symbol()+" is not a GOLD/XAU symbol";
      Print("XVISION EMA50 V7: ",g_blockReason,
            ". The EA stays attached and will not trade.");
     }
  }

//+------------------------------------------------------------------+
//| Clamp the cosmetic inputs into usable values and report any      |
//| adjustment. Never fails: a panel setting cannot stop trading.    |
//+------------------------------------------------------------------+
void ResolveDashboardGeometry()
  {
   g_panelFont  =(int)MathMax(6,MathMin(24,DashboardFontSize));
   g_panelScale =g_panelFont/10.0;
   g_panelX     =(int)MathMax(0,DashboardX);
   g_panelY     =(int)MathMax(0,DashboardY);

   // The tallest hand-placed row sits at y=431; leave room for it plus padding.
   int requiredHeight=PanelRow(431)+g_panelFont*2+16;
   int requiredWidth =(int)MathMax(200,PanelRow(200));

   g_panelWidth =(int)MathMax(requiredWidth,DashboardWidth);
   g_panelHeight=(int)MathMax(requiredHeight,DashboardHeight);
   g_panelRefreshMs=(int)MathMax(0,MathMin(5000,DashboardRefreshMs));

   if(g_panelFont!=DashboardFontSize || g_panelX!=DashboardX ||
      g_panelY!=DashboardY || g_panelWidth!=DashboardWidth ||
      g_panelHeight!=DashboardHeight || g_panelRefreshMs!=DashboardRefreshMs)
      Print("XVISION EMA50 V7: dashboard settings clamped to x=",g_panelX,
            " y=",g_panelY," w=",g_panelWidth," h=",g_panelHeight,
            " font=",g_panelFont," refresh=",g_panelRefreshMs,"ms",
            " (requested w=",DashboardWidth," h=",DashboardHeight,
            " font=",DashboardFontSize,"). Trading is unaffected.");
  }

//+------------------------------------------------------------------+
//| Scale a row offset from v6's font-10 layout to the chosen font.  |
//+------------------------------------------------------------------+
int PanelRow(const int baseY)
  {
   return((int)MathRound(baseY*g_panelScale));
  }

//+------------------------------------------------------------------+
//| Process exactly once when a new signal-timeframe candle opens.   |
//+------------------------------------------------------------------+
void ProcessNewSignalBar()
  {
   datetime currentBar=iTime(Symbol(),SignalTimeframe,0);
   if(currentBar<=0)
      return;

   if(g_lastProcessedBar==0)
     {
      g_lastProcessedBar=currentBar;
      SaveEpisodeState();
      if(!TradeCurrentSignalOnAttach)
         return;
     }
   else if(currentBar==g_lastProcessedBar)
      return;

   int barGap=iBarShift(Symbol(),SignalTimeframe,g_lastProcessedBar,false);
   if(barGap>1)
     {
      g_lastProcessedBar=currentBar;
      g_episodeLocked=HasEAExposure();
      g_quietBars=0;
      if(!HasActiveRetestPending())
        {
         g_retestState=RETEST_IDLE;
         g_retestDirection=0;
         g_retestCount=0;
         g_retestSignalBar=0;
         g_retestStatus="Live-data gap detected; retest sequence reset";
        }
      g_lastDecision="Historical bars skipped after a live-data gap";
      SaveEpisodeState();
      return;
     }

   g_lastProcessedBar=currentBar;

   int maximumShift=(int)MathMax(2+g_gradientLookback,g_rangeLookback+1);
   if(g_enableRetest)
      maximumShift=(int)MathMax(maximumShift,g_retestTrendCloses);
   int minimumBars=(int)MathMax(g_emaPeriod+maximumShift+5,g_atrPeriod+maximumShift+5);
   if(iBars(Symbol(),SignalTimeframe)<minimumBars)
     {
      g_lastDecision="Waiting for sufficient EMA/ATR history";
      SaveEpisodeState();
      return;
     }

   // Bar count being sufficient does not mean iMA() is returning values yet;
   // mid-synchronisation it still hands back 0.0, which is exactly the state a
   // chart is in right after a re-initialization.
   if(!EMAReady(maximumShift+1))
     {
      g_lastDecision="Waiting for the EMA to finish loading on the signal timeframe";
      SaveEpisodeState();
      return;
     }

   UpdateCurrentDiagnostics();
   if(!g_diagnosticsValid)
     {
      g_lastDecision="Waiting for usable EMA/ATR values on the signal timeframe";
      SaveEpisodeState();
      return;
     }

   int direction=0;
   bool rawCross=ClosedBarCross(direction);

   bool retestConsumed=ProcessRetestState(rawCross,direction);
   if(retestConsumed)
     {
      // v6 returned here without touching the quiet counter, so any bar that
      // consumed a retest never counted toward re-arming and the unlock took
      // longer than g_quietBarsRequired implies. The retest message is
      // more informative than the lock message, so keep it.
      AdvanceEpisodeLock(rawCross,false);
      SaveEpisodeState();
      return;
     }

   if(g_episodeLocked)
     {
      AdvanceEpisodeLock(rawCross,true);
      SaveEpisodeState();
      return;
     }

   if(!rawCross)
     {
      g_lastDecision="No completed-candle EMA crossing";
      SaveEpisodeState();
      return;
     }

   double atr1=iATR(Symbol(),SignalTimeframe,g_atrPeriod,1);
   double atr2=iATR(Symbol(),SignalTimeframe,g_atrPeriod,2);
   if(atr1<=0.0 || atr2<=0.0)
     {
      g_lastDecision="Cross rejected: ATR is unavailable";
      SaveEpisodeState();
      return;
     }

   double ema1=EMAValue(1);
   double emaPast=EMAValue(1+g_gradientLookback);
   double ema2=EMAValue(2);
   double emaPreviousPast=EMAValue(2+g_gradientLookback);
   if(ema1<=0.0 || emaPast<=0.0 || ema2<=0.0 || emaPreviousPast<=0.0)
     {
      g_lastDecision="Cross rejected: EMA history is incomplete";
      SaveEpisodeState();
      return;
     }
   double close1=iClose(Symbol(),SignalTimeframe,1);
   double open1=iOpen(Symbol(),SignalTimeframe,1);

   g_lastSlope=g_currentSlope;
   double previousSlope=(ema2-emaPreviousPast)/atr2;
   g_lastDirectionalGradient=direction*g_lastSlope;
   double previousDirectionalGradient=direction*previousSlope;
   double gradientImprovement=g_lastDirectionalGradient-previousDirectionalGradient;
   double closeDistanceATR=direction*(close1-ema1)/atr1;
   double bodyATR=direction*(close1-open1)/atr1;
   int crossingCount=CountRawCrossings(g_rangeLookback);
   g_lastEfficiency=g_currentEfficiency;
   g_lastRangeVotes=g_currentRangeVotes;

   bool continuation=(g_lastDirectionalGradient>=g_contGradientMin &&
                      g_lastRangeVotes<=g_maxRangeVotes);
   bool reversal=(closeDistanceATR>=g_revMinCloseDistATR &&
                  g_lastDirectionalGradient>g_revMinDirGradient &&
                  gradientImprovement>=g_revMinGradImprove &&
                  bodyATR>=g_revMinBodyATR);

   string route="";
   if(continuation)
      route="CONTINUATION";
   else if(reversal)
      route="REVERSAL";

   if(PrintSignalDiagnostics)
     {
       Print("XVISION EMA50 V7 cross ",DirectionName(direction),
            " time=",TimeToString(iTime(Symbol(),SignalTimeframe,1),TIME_DATE|TIME_MINUTES),
            " gradient=",DoubleToString(g_lastDirectionalGradient,4),
            " improvement=",DoubleToString(gradientImprovement,4),
            " gapATR=",DoubleToString(closeDistanceATR,3),
            " bodyATR=",DoubleToString(bodyATR,3),
            " crossings=",crossingCount,
            " efficiency=",DoubleToString(g_lastEfficiency,3),
            " rangeVotes=",g_lastRangeVotes,
            " route=",(route=="" ? "REJECT" : route));
     }

   if(route=="")
     {
      g_lastDecision="Cross rejected by continuation and reversal rules";
      SaveEpisodeState();
      return;
     }

   if((direction>0 && !EnableBuyTrades) || (direction<0 && !EnableSellTrades))
     {
      g_lastDecision=DirectionName(direction)+" qualified but that direction is disabled";
      SaveEpisodeState();
      return;
     }

   // A qualified crossing consumes the episode even if execution is blocked.
   // This prevents late entry or another order from the same crossing cluster.
   g_episodeLocked=true;
   g_quietBars=0;
   g_lastSignalBar=iTime(Symbol(),SignalTimeframe,1);
   SaveEpisodeState();

   if(HasEAExposure())
     {
      g_lastDecision=route+" qualified but existing EA exposure blocked entry";
      g_retestState=RETEST_USED;
      g_retestStatus="Existing EA exposure consumed this trend leg";
      SaveEpisodeState();
      return;
     }

   if(OpenDirectionalTrade(direction,route,close1))
     {
      g_lastDecision=route+" "+DirectionName(direction)+" opened";
      g_retestState=RETEST_USED;
      g_retestStatus="Cross entry opened; retest disabled for this trend leg";
     }
   else
      g_lastDecision=route+" qualified; execution blocked or failed";

   SaveEpisodeState();
  }

//+------------------------------------------------------------------+
//| Advance the crossing-episode lock by one completed candle.        |
//|                                                                  |
//| setDecision is false when the caller has already written a more   |
//| specific g_lastDecision that should not be overwritten.          |
//+------------------------------------------------------------------+
void AdvanceEpisodeLock(const bool rawCross,const bool setDecision)
  {
   if(!g_episodeLocked)
      return;

   if(rawCross)
     {
      g_quietBars=0;
      if(setDecision)
         g_lastDecision="LOCKED: raw crossing restarted the quiet counter";
      return;
     }

   g_quietBars++;
   if(g_quietBars>=g_quietBarsRequired && !HasEAExposure())
     {
      g_episodeLocked=false;
      g_quietBars=0;
      if(setDecision)
         g_lastDecision="Episode reset completed; waiting for a new crossing";
     }
   else if(setDecision)
      g_lastDecision="LOCKED: waiting for quiet candles and closed exposure";
  }

//+------------------------------------------------------------------+
//| Refresh panel diagnostics on every completed signal candle.      |
//+------------------------------------------------------------------+
void UpdateCurrentDiagnostics()
  {
   g_diagnosticsValid=false;
   double atr=iATR(Symbol(),SignalTimeframe,g_atrPeriod,1);
   if(atr<=0.0)
      return;
   double emaNow=EMAValue(1);
   double emaPast=EMAValue(1+g_gradientLookback);
   if(emaNow<=0.0 || emaPast<=0.0)
      return;
   g_currentSlope=(emaNow-emaPast)/atr;
   g_currentEfficiency=DirectionalEfficiency(g_rangeLookback);
   int crossings=CountRawCrossings(g_rangeLookback);
   g_currentRangeVotes=RangeVotes(crossings,g_currentSlope,g_currentEfficiency);
   g_diagnosticsValid=true;
  }

//+------------------------------------------------------------------+
//| Human-readable state for the dashboard.                          |
//+------------------------------------------------------------------+
string RetestStateName()
  {
   if(g_retestState==RETEST_WAIT_MOVE) return("WAIT MOVE-AWAY");
   if(g_retestState==RETEST_ARMED)     return("ARMED");
   if(g_retestState==RETEST_PENDING)   return("PENDING BREAKOUT");
   if(g_retestState==RETEST_USED)      return("USED / INVALIDATED");
   return("IDLE");
  }

//+------------------------------------------------------------------+
//| Identify a V6 retest order selected in the terminal order pool. |
//+------------------------------------------------------------------+
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
bool IsCurrentRetestOrder()
  {
   return(OrderSymbol()==Symbol() && OrderMagicNumber()==g_magic);
  }

//+------------------------------------------------------------------+
//| A broker-side pending order takes priority over saved state.     |
//| Prefers the tracked ticket and falls back to a scan, adopting    |
//| whatever it finds so state survives a lost global variable.      |
//+------------------------------------------------------------------+
bool HasActiveRetestPending()
  {
   if(g_retestTicket>0 &&
      OrderSelect(g_retestTicket,SELECT_BY_TICKET,MODE_TRADES) &&
      IsCurrentRetestOrder())
     {
      int trackedType=OrderType();
      if(trackedType==OP_BUYSTOP || trackedType==OP_SELLSTOP)
         return(true);
     }

   for(int pos=OrdersTotal()-1; pos>=0; pos--)
     {
      if(!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES) || !IsCurrentRetestOrder())
         continue;
      int type=OrderType();
      if(type==OP_BUYSTOP || type==OP_SELLSTOP)
        {
         g_retestTicket=OrderTicket();
         return(true);
        }
     }

   if(g_retestTicket>0)
      g_retestTicket=0;
   return(false);
  }

//+------------------------------------------------------------------+
//| Recover safely if terminal global variables were lost/reset.    |
//+------------------------------------------------------------------+
void RecoverRetestOrderState()
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
      if(!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES) || !IsCurrentRetestOrder())
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
      g_retestState=RETEST_PENDING;
      g_retestTicket=pendingTicket;
      g_retestDirection=pendingDirection;
      g_retestCount=(int)MathMax(g_retestCount,1);
      g_retestSignalBar=pendingTime;
      g_retestStatus="Recovered pending confirmation #"+IntegerToString(pendingTicket);
      return;
     }

   if(marketFound)
     {
      g_retestState=RETEST_USED;
      g_retestTicket=0;
      g_retestDirection=recoveredDirection;
      g_retestCount=(int)MathMax(g_retestCount,1);
      g_retestSignalBar=recoveredTime;
      g_retestStatus="Recovered triggered retest position";
     }
  }

//+------------------------------------------------------------------+
//| Verify the required consecutive closes remain on the trend side.|
//+------------------------------------------------------------------+
bool HasTrendCloses(const int direction)
  {
   for(int shift=1; shift<=g_retestTrendCloses; shift++)
     {
      double closeValue=iClose(Symbol(),SignalTimeframe,shift);
      double emaValue=EMAValue(shift);
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
bool RetestTouchesBand(const int direction)
  {
   double atr=iATR(Symbol(),SignalTimeframe,g_atrPeriod,1);
   if(atr<=0.0)
      return(false);
   double ema=EMAValue(1);
   if(ema<=0.0)
      return(false);
   if(direction>0)
      return(iLow(Symbol(),SignalTimeframe,1)<=ema+g_retestTouchTolATR*atr);
   return(iHigh(Symbol(),SignalTimeframe,1)>=ema-g_retestTouchTolATR*atr);
  }

//+------------------------------------------------------------------+
//| Apply all rejection-candle requirements to the first EMA touch. |
//+------------------------------------------------------------------+
bool RetestCandleQualifies(const int direction,string &reason)
  {
   reason="";
   double atr=iATR(Symbol(),SignalTimeframe,g_atrPeriod,1);
   if(atr<=0.0)
     { reason="ATR unavailable"; return(false); }
   if(!g_diagnosticsValid)
     { reason="diagnostics are stale"; return(false); }
   if(direction*g_currentSlope<g_contGradientMin)
     { reason="EMA slope lost direction"; return(false); }
   if(g_currentRangeVotes>g_maxRangeVotes)
     { reason="too many range votes"; return(false); }
   if(g_currentEfficiency<g_minEfficiency)
     { reason="directional efficiency too low"; return(false); }

   double openValue=iOpen(Symbol(),SignalTimeframe,1);
   double highValue=iHigh(Symbol(),SignalTimeframe,1);
   double lowValue=iLow(Symbol(),SignalTimeframe,1);
   double closeValue=iClose(Symbol(),SignalTimeframe,1);
   double emaValue=EMAValue(1);
   if(emaValue<=0.0)
     { reason="EMA unavailable"; return(false); }
   double candleRange=highValue-lowValue;
   if(candleRange<=0.0)
     { reason="zero candle range"; return(false); }

   double recovery=direction*(closeValue-emaValue)/atr;
   double penetration=(direction>0 ? (emaValue-lowValue)/atr :
                                     (highValue-emaValue)/atr);
   if(penetration>g_retestMaxPenetrationATR)
     { reason="EMA penetration was too deep"; return(false); }
   if(recovery<g_retestMinRecoveryATR)
     { reason="close did not recover far enough from EMA"; return(false); }
   if(RetestRequireDirectionalBody && direction*(closeValue-openValue)<=0.0)
     { reason="candle body disagreed with trend"; return(false); }

   double closeLocation=(direction>0 ?
                         (closeValue-lowValue)/candleRange*100.0 :
                         (highValue-closeValue)/candleRange*100.0);
   if(closeLocation<g_retestMinCloseLocPct)
     { reason="close location was too weak"; return(false); }
   return(true);
  }

//+------------------------------------------------------------------+
//| Normalize stop-entry prices away from the current market.        |
//+------------------------------------------------------------------+
double NormalizeRetestEntry(const double price,const int direction)
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
bool PlaceRetestPending(const int direction)
  {
   if(g_tradingBlocked)
     { g_lastDecision="RETEST suppressed: "+g_blockReason; return(false); }

   if(!IsTradeAllowed() || IsTradeContextBusy() ||
      MarketInfo(Symbol(),MODE_TRADEALLOWED)<0.5)
     { g_lastDecision="RETEST rejected: trade context unavailable"; return(false); }
   RefreshRates();
   if(Bid<=0.0 || Ask<=0.0)
     { g_lastDecision="RETEST rejected: prices unavailable"; return(false); }

   double spread=MathMax(0.0,Ask-Bid);
   if(g_maxSpread>0.0 && spread>g_maxSpread)
     { g_lastDecision="RETEST rejected: spread too wide"; return(false); }

   double lots=0.0;
   if(!ResolveLotSizeForTrade(g_fixedLot,lots))
     { g_lastDecision="RETEST rejected: volume is not executable"; return(false); }

   double atr=iATR(Symbol(),SignalTimeframe,g_atrPeriod,1);
   if(atr<=0.0)
     { g_lastDecision="RETEST rejected: ATR unavailable"; return(false); }
   double rawEntry=(direction>0 ? iHigh(Symbol(),SignalTimeframe,1)+g_retestEntryBufferATR*atr :
                                  iLow(Symbol(),SignalTimeframe,1)-g_retestEntryBufferATR*atr);
   double entry=NormalizeRetestEntry(rawEntry,direction);
   if(entry<=0.0)
     { g_lastDecision="RETEST rejected: invalid pending price"; return(false); }

   double minimumDistance=MarketInfo(Symbol(),MODE_STOPLEVEL)*Point;
   if((direction>0 && entry<=Ask+minimumDistance) ||
      (direction<0 && entry>=Bid-minimumDistance))
     { g_lastDecision="RETEST skipped: breakout already passed or pending too close"; return(false); }

   double stopLoss=0.0;
   double takeProfit=0.0;
   int marketCommand=(direction>0 ? OP_BUY : OP_SELL);
   if(g_stopLossMoney>0.0 || g_takeProfitMoney>0.0)
     {
      double moneyPerPrice=MoneyPerPriceUnitPerLot()*lots;
      if(moneyPerPrice<=0.0)
        { g_lastDecision="RETEST rejected: tick value unavailable"; return(false); }
      double stopDistance=(g_stopLossMoney>0.0 ? g_stopLossMoney/moneyPerPrice : 0.0);
      double targetDistance=(g_takeProfitMoney>0.0 ? g_takeProfitMoney/moneyPerPrice : 0.0);
      if((stopDistance>0.0 && stopDistance<minimumDistance) ||
         (targetDistance>0.0 && targetDistance<minimumDistance))
        { g_lastDecision="RETEST rejected: SL/TP inside broker stop level"; return(false); }
      if(stopDistance>0.0)
         stopLoss=NormalizeProtectiveStop(entry-direction*stopDistance,marketCommand);
      if(targetDistance>0.0)
         takeProfit=NormalizeTargetPrice(entry+direction*targetDistance,marketCommand);
      if((stopDistance>0.0 && stopLoss<=0.0) ||
         (targetDistance>0.0 && takeProfit<=0.0))
        { g_lastDecision="RETEST rejected: protected price normalization failed"; return(false); }
      if((stopLoss>0.0 && MathAbs(entry-stopLoss)+Point*0.1<minimumDistance) ||
         (takeProfit>0.0 && MathAbs(takeProfit-entry)+Point*0.1<minimumDistance))
        { g_lastDecision="RETEST rejected: tick rounding breached broker stop level"; return(false); }
     }

   // A pending order consumes no margin until it triggers, and margin at that
   // future moment is what decides the fill. v6 rejected the placement using a
   // MARKET order check, which blocked valid pendings whenever margin was tight.
   // Warn and let the broker enforce margin on trigger instead.
   if(AccountFreeMarginCheck(Symbol(),marketCommand,lots)<=0.0)
     {
      ResetLastError();
      Print("XVISION EMA50 V7: free margin would not support ",
            DoubleToString(lots,LotDigits())," lots right now; placing the pending "
            "anyway since margin is only required if it triggers.");
     }

   int pendingCommand=(direction>0 ? OP_BUYSTOP : OP_SELLSTOP);
   string orderComment=(direction>0 ? "XVE6_RET_BUY" : "XVE6_RET_SELL");
   datetime expiration=0;
   if(RequireServerSidePendingExpiry)
     {
      int timeframeSeconds=PeriodSeconds(SignalTimeframe);
      datetime activeBar=iTime(Symbol(),SignalTimeframe,0);
      if(timeframeSeconds<=0 || activeBar<=0)
        { g_lastDecision="RETEST rejected: server expiry time unavailable"; return(false); }
      expiration=(datetime)(activeBar+g_retestExpiryBars*timeframeSeconds);
      if(expiration<=TimeCurrent())
        { g_lastDecision="RETEST rejected: computed server expiry is stale"; return(false); }
     }
   bool serverExpiryRequested=(expiration>0);
   ResetLastError();
   int ticket=OrderSend(Symbol(),pendingCommand,lots,entry,SlippagePoints(),
                        stopLoss,takeProfit,orderComment,g_magic,expiration,
                        (direction>0 ? clrDodgerBlue : clrTomato));

   // Many brokers -- ECN/STP accounts especially -- refuse pending expiry
   // outright with error 147. v6 treated that as a hard failure and burned the
   // trend leg, so the retest route never worked at all on those accounts.
   // The bar-age cancel in ManageRetestOrders() already enforces the same
   // lifetime locally, so falling back is safe rather than a loosening.
   if(ticket<0 && serverExpiryRequested)
     {
      int expiryError=GetLastError();
      if(expiryError==ERR_TRADE_EXPIRATION_DENIED ||
         expiryError==ERR_INVALID_TRADE_PARAMETERS)
        {
         Print("XVISION EMA50 V7: broker refused pending expiry (error=",expiryError,
               "); resending without it and expiring locally after ",
               g_retestExpiryBars," ",TimeframeName(SignalTimeframe)," bars.");
         serverExpiryRequested=false;
         expiration=0;
         ResetLastError();
         ticket=OrderSend(Symbol(),pendingCommand,lots,entry,SlippagePoints(),
                          stopLoss,takeProfit,orderComment,g_magic,0,
                          (direction>0 ? clrDodgerBlue : clrTomato));
        }
     }

   if(ticket<0)
     {
      Print("XVISION EMA50 V7: retest pending failed error=",GetLastError(),
            " entry=",DoubleToString(entry,Digits));
      g_lastDecision="RETEST qualified; pending order failed";
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
         Print("XVISION EMA50 V7: pending #",ticket," was accepted without the "
               "requested server expiry; it will be expired locally after ",
               g_retestExpiryBars," ",TimeframeName(SignalTimeframe)," bars.");
        }
     }

   g_retestTicket=ticket;
   g_retestState=RETEST_PENDING;
   g_retestCount++;
   g_retestSignalBar=iTime(Symbol(),SignalTimeframe,1);
   g_lastSignalBar=g_retestSignalBar;
   g_episodeLocked=true;
   g_quietBars=0;
   g_retestStatus=DirectionName(direction)+" confirmation pending #"+
                  IntegerToString(ticket)+" at "+DoubleToString(entry,Digits)+
                  (expiryVerified ? "" : " (local expiry)");
   g_lastDecision="RETEST "+DirectionName(direction)+" confirmation pending";
   Print("XVISION EMA50 V7: retest pending ticket=",ticket,
         " direction=",DirectionName(direction),
         " entry=",DoubleToString(entry,Digits),
         " expires after ",g_retestExpiryBars," ",
         TimeframeName(SignalTimeframe)," bars",
         " serverExpiry=",(expiration>0 ?
         TimeToString(expiration,TIME_DATE|TIME_MINUTES) : "manual-only"));
   return(true);
  }

//+------------------------------------------------------------------+
//| Advance the live-only trend -> move-away -> first-retest state.  |
//+------------------------------------------------------------------+
bool ProcessRetestState(const bool rawCross,const int crossDirection)
  {
   if(!g_enableRetest)
     {
      g_retestState=RETEST_IDLE;
      g_retestStatus="Retest module disabled";
      return(false);
     }

   if(HasActiveRetestPending())
     {
      g_retestState=RETEST_PENDING;
      g_retestStatus="Broker retest confirmation remains pending";
      return(false);
     }

   if(rawCross)
     {
      g_retestDirection=crossDirection;
      g_retestState=RETEST_WAIT_MOVE;
      g_retestCount=0;
      g_retestSignalBar=0;
      g_retestStatus="New "+DirectionName(crossDirection)+" leg; waiting for move-away";
      return(false);
     }

   // v6 advanced -- and could fire -- the retest sequence while the episode was
   // locked, because ProcessRetestState() runs before the lock check in
   // ProcessNewSignalBar(). A leg whose crossing was never traded or even
   // assessed could therefore still produce an entry once the lock cleared.
   // A raw cross above still resets the leg; only the advance is paused.
   if(g_episodeLocked)
     {
      g_retestStatus="Retest paused: episode is locked";
      return(false);
     }

   if(g_retestState==RETEST_IDLE || g_retestState==RETEST_PENDING ||
      g_retestState==RETEST_USED || g_retestDirection==0)
      return(false);

   double atr=iATR(Symbol(),SignalTimeframe,g_atrPeriod,1);
   if(atr<=0.0)
      return(false);
   double closeValue=iClose(Symbol(),SignalTimeframe,1);
   double emaValue=EMAValue(1);
   if(emaValue<=0.0)
      return(false);
   double directionalDistance=g_retestDirection*(closeValue-emaValue)/atr;

   if(directionalDistance<=0.0 || g_retestDirection*g_currentSlope<=0.0)
     {
      g_retestState=RETEST_USED;
      g_retestStatus="Trend leg invalidated before retest";
      return(false);
     }

   if(g_retestState==RETEST_WAIT_MOVE)
     {
      if(HasTrendCloses(g_retestDirection) &&
         directionalDistance>=g_retestMinMoveAwayATR &&
         g_retestDirection*g_currentSlope>=g_contGradientMin &&
         g_currentRangeVotes<=g_maxRangeVotes &&
         g_currentEfficiency>=g_minEfficiency)
        {
         g_retestState=RETEST_ARMED;
         g_retestStatus=DirectionName(g_retestDirection)+" retest armed; waiting for first touch";
        }
      if(g_retestState!=RETEST_ARMED)
         return(false);
     }

   if(g_retestState!=RETEST_ARMED || !RetestTouchesBand(g_retestDirection))
      return(false);

   // The first touch consumes the opportunity whether it passes or fails.
   string reason="";
   if(!RetestCandleQualifies(g_retestDirection,reason))
     {
      g_retestState=RETEST_USED;
      g_retestStatus="First retest rejected: "+reason;
      g_lastDecision=g_retestStatus;
      return(true);
     }

   if(g_retestCount>=g_maxRetestsPerLeg)
     {
      g_retestState=RETEST_USED;
      g_retestStatus="Retest limit already reached for this trend leg";
      g_lastDecision=g_retestStatus;
      return(true);
     }
   if(HasEAExposure())
     {
      g_retestState=RETEST_USED;
      g_retestStatus="Qualified retest blocked by existing exposure";
      g_lastDecision=g_retestStatus;
      return(true);
     }
   if((g_retestDirection>0 && !EnableBuyTrades) ||
      (g_retestDirection<0 && !EnableSellTrades))
     {
      g_retestState=RETEST_USED;
      g_retestStatus="Qualified retest direction is disabled";
      g_lastDecision=g_retestStatus;
      return(true);
     }

   bool placed=PlaceRetestPending(g_retestDirection);
   if(!placed)
     {
      g_retestState=RETEST_USED;
      g_retestStatus=g_lastDecision;
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Cancel stale/invalid retest stops and detect confirmed entries.  |
//+------------------------------------------------------------------+
void ManageRetestOrders()
  {
   int pendingCount=0;
   bool triggeredPositionFound=false;
   bool stateChanged=false;
   double atr=iATR(Symbol(),SignalTimeframe,g_atrPeriod,1);
   double closedSlope=0.0;
   bool   slopeKnown=false;
   double manageEma=EMAValue(1);
   double manageEmaPast=EMAValue(1+g_gradientLookback);
   if(atr>0.0 && manageEma>0.0 && manageEmaPast>0.0)
     {
      closedSlope=(manageEma-manageEmaPast)/atr;
      slopeKnown=true;
     }

   for(int pos=OrdersTotal()-1; pos>=0; pos--)
     {
      if(!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES))
         continue;
      if(!IsCurrentRetestOrder())
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
      bool barExpired=(ageBars>=g_retestExpiryBars);
      bool serverExpired=(OrderExpiration()>0 && TimeCurrent()>=OrderExpiration());
      bool expired=(barExpired || serverExpired);
      // Never judge the setup against an unavailable EMA -- a zero would read
      // as "invalidated" for sells and cancel a perfectly good pending order.
      bool closeInvalid=(emaValue>0.0 && closeValue>0.0 &&
                         (direction>0 ? closeValue<=emaValue : closeValue>=emaValue));
      bool slopeInvalid=(slopeKnown && direction*closedSlope<=0.0);
      bool cancel=(!g_enableRetest || expired || closeInvalid || slopeInvalid);
      if(!cancel || !IsTradeAllowed() || IsTradeContextBusy() ||
         MarketInfo(Symbol(),MODE_TRADEALLOWED)<0.5)
         continue;

      // v6 throttled only the error message, so a pending sitting inside the
      // broker's freeze level was hammered with OrderDelete on every tick.
      if(TimeCurrent()-g_lastPendingDeleteAttempt<PENDING_DELETE_RETRY_SECONDS)
         continue;
      g_lastPendingDeleteAttempt=TimeCurrent();

      int ticket=OrderTicket();
      string cancelReason=(!g_enableRetest ? "module disabled" :
                           (expired ? "confirmation expired" :
                            (closeInvalid ? "EMA close invalidated" : "slope invalidated")));
      ResetLastError();
      if(OrderDelete(ticket,clrSilver))
        {
         Print("XVISION EMA50 V7: deleted retest pending #",ticket,
               " reason=",cancelReason);
         pendingCount--;
         if(g_retestTicket==ticket)
            g_retestTicket=0;
         g_retestState=(g_retestCount>=g_maxRetestsPerLeg ?
                        RETEST_USED : RETEST_WAIT_MOVE);
         g_retestStatus="Pending cancelled: "+cancelReason;
         g_lastDecision=g_retestStatus;
         stateChanged=true;
        }
      else if(TimeCurrent()-g_lastManagementErrorPrint>=30)
        {
         Print("XVISION EMA50 V7: pending deletion failed #",ticket,
               " error=",GetLastError());
         g_lastManagementErrorPrint=TimeCurrent();
        }
     }

   if(g_retestState==RETEST_PENDING && pendingCount<=0)
     {
      if(triggeredPositionFound)
        {
         g_retestState=RETEST_USED;
         g_retestStatus="Retest confirmation triggered; position is open";
         g_lastDecision=g_retestStatus;
        }
      else
        {
         g_retestState=(g_retestCount>=g_maxRetestsPerLeg ?
                        RETEST_USED : RETEST_WAIT_MOVE);
         g_retestStatus="Retest pending no longer exists";
        }
      stateChanged=true;
     }
   else if(triggeredPositionFound && g_retestState!=RETEST_USED)
     {
      g_retestState=RETEST_USED;
      g_retestCount=(int)MathMax(g_retestCount,1);
      g_retestStatus="Retest confirmation triggered; position is open";
      g_lastDecision=g_retestStatus;
      stateChanged=true;
     }
   if(stateChanged)
      SaveEpisodeState();
  }

//+------------------------------------------------------------------+
//| Completed-candle cross.                                         |
//+------------------------------------------------------------------+
bool ClosedBarCross(int &direction)
  {
   direction=0;
   double close1=iClose(Symbol(),SignalTimeframe,1);
   double close2=iClose(Symbol(),SignalTimeframe,2);
   double ema1=EMAValue(1);
   double ema2=EMAValue(2);

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
int CountRawCrossings(const int lookback)
  {
   int count=0;
   for(int shift=1; shift<=lookback; shift++)
     {
      double closeNew=iClose(Symbol(),SignalTimeframe,shift);
      double closeOld=iClose(Symbol(),SignalTimeframe,shift+1);
      double emaNew=EMAValue(shift);
      double emaOld=EMAValue(shift+1);
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
double DirectionalEfficiency(const int lookback)
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
int RangeVotes(const int crossings,const double slope,const double efficiency)
  {
   int votes=0;
   if(crossings>=g_rangeCrossVoteMin)
      votes++;
   if(MathAbs(slope)<g_flatGradientThreshold)
      votes++;
   if(efficiency<g_minEfficiency)
      votes++;
   return(votes);
  }

//+------------------------------------------------------------------+
//| Place one crossing entry with the user's protection settings.   |
//+------------------------------------------------------------------+
bool OpenDirectionalTrade(const int direction,const string route,const double signalClose)
  {
   if(g_tradingBlocked)
     {
      Print("XVISION EMA50 V7: entry suppressed -- ",g_blockReason);
      return(false);
     }

   if(!IsTradeAllowed() || IsTradeContextBusy() ||
      MarketInfo(Symbol(),MODE_TRADEALLOWED)<0.5)
     {
       Print("XVISION EMA50 V7: trade context is not available.");
      return(false);
     }

   RefreshRates();
   if(Bid<=0.0 || Ask<=0.0)
      return(false);

   double spread=MathMax(0.0,Ask-Bid);
   if(g_maxSpread>0.0 && spread>g_maxSpread)
     {
       Print("XVISION EMA50 V7: entry skipped; spread ",DoubleToString(spread,Digits),
            " exceeds ",DoubleToString(g_maxSpread,Digits));
      return(false);
     }

   int command=(direction>0 ? OP_BUY : OP_SELL);
   double entry=(command==OP_BUY ? Ask : Bid);
   if(g_maxEntryDeviation>0.0 &&
      MathAbs(entry-signalClose)>g_maxEntryDeviation)
     {
       Print("XVISION EMA50 V7: entry skipped; deviation from signal close is ",
            DoubleToString(MathAbs(entry-signalClose),Digits));
      return(false);
     }

   double lots=0.0;
   if(!ResolveLotSizeForTrade(g_fixedLot,lots))
      return(false);

   double stopDistance=0.0;
   double targetDistance=0.0;
   if(g_stopLossMoney>0.0 || g_takeProfitMoney>0.0)
     {
      double moneyPerPricePerLot=MoneyPerPriceUnitPerLot();
      if(moneyPerPricePerLot<=0.0)
        {
         Print("XVISION EMA50 V7: broker tick value/tick size is unavailable.");
         return(false);
        }
      if(g_stopLossMoney>0.0)
         stopDistance=g_stopLossMoney/(moneyPerPricePerLot*lots);
      if(g_takeProfitMoney>0.0)
         targetDistance=g_takeProfitMoney/(moneyPerPricePerLot*lots);
     }

   double minimumDistance=MarketInfo(Symbol(),MODE_STOPLEVEL)*Point;
   if((stopDistance>0.0 && stopDistance<minimumDistance) ||
      (targetDistance>0.0 && targetDistance<minimumDistance))
     {
      Print("XVISION EMA50 V7: requested SL/TP is inside the broker stop level.");
      return(false);
     }

   double stopLoss=0.0;
   double takeProfit=0.0;
   if(stopDistance>0.0)
      stopLoss=NormalizeProtectiveStop((direction>0 ? entry-stopDistance :
                                                     entry+stopDistance),command);
   if(targetDistance>0.0)
      takeProfit=NormalizeTargetPrice((direction>0 ? entry+targetDistance :
                                                    entry-targetDistance),command);
   if((stopDistance>0.0 && stopLoss<=0.0) ||
      (targetDistance>0.0 && takeProfit<=0.0))
     {
      Print("XVISION EMA50 V7: protected price normalization failed.");
      return(false);
     }
   entry=NormalizeDouble(entry,Digits);
   if((stopLoss>0.0 && MathAbs(entry-stopLoss)+Point*0.1<minimumDistance) ||
      (takeProfit>0.0 && MathAbs(takeProfit-entry)+Point*0.1<minimumDistance))
     {
      Print("XVISION EMA50 V7: tick rounding breached the broker stop level.");
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
      Print("XVISION EMA50 V7: requested protection is too close to the executable market side.");
      return(false);
     }

   if(AccountFreeMarginCheck(Symbol(),command,lots)<=0.0)
     {
      Print("XVISION EMA50 V7: insufficient free margin.");
      return(false);
     }

   string comment=(route=="CONTINUATION" ? "XVE6_CONT" : "XVE6_REV");
   ResetLastError();
   int ticket=OrderSend(Symbol(),command,lots,entry,SlippagePoints(),
                        stopLoss,takeProfit,comment,g_magic,0,
                        (direction>0 ? clrDodgerBlue : clrTomato));
   if(ticket<0)
     {
      int error=GetLastError();
      Print("XVISION EMA50 V7: OrderSend failed error=",error,
            " direction=",DirectionName(direction),
            " entry=",DoubleToString(entry,Digits),
            " SL=",DoubleToString(stopLoss,Digits),
            " TP=",DoubleToString(takeProfit,Digits));
      return(false);
     }

   Print("XVISION EMA50 V7: opened ticket=",ticket,
         " route=",route,
         " direction=",DirectionName(direction),
         " lots=",DoubleToString(lots,LotDigits()),
         " entry=",DoubleToString(entry,Digits),
         " SL=",DoubleToString(stopLoss,Digits),
         " TP=",DoubleToString(takeProfit,Digits));
   return(true);
  }

//+------------------------------------------------------------------+
//| Round an SL toward safety so requested risk/lock is not weakened.|
//+------------------------------------------------------------------+
double NormalizeProtectiveStop(const double price,const int orderType)
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
//| Round a target outward so tick rounding cannot reduce distance. |
//+------------------------------------------------------------------+
double NormalizeTargetPrice(const double price,const int orderType)
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
//| Apply only the trailing/lock values explicitly entered by user. |
//+------------------------------------------------------------------+
void ManageInputProtection()
  {
   if(!g_enableTrailing && !g_enableProfitLock)
      return;
   if(!IsTradeAllowed() || IsTradeContextBusy() ||
      MarketInfo(Symbol(),MODE_TRADEALLOWED)<0.5)
      return;

   RefreshRates();
   double moneyPerPricePerLot=MoneyPerPriceUnitPerLot();
   if(moneyPerPricePerLot<=0.0 || Bid<=0.0 || Ask<=0.0)
      return;

   double brokerDistance=MathMax(MarketInfo(Symbol(),MODE_STOPLEVEL),
                                 MarketInfo(Symbol(),MODE_FREEZELEVEL))*Point;

   for(int pos=OrdersTotal()-1; pos>=0; pos--)
     {
      if(!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES))
         continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=g_magic)
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

      if(g_enableProfitLock && netProfit>=g_lockTrigger)
        {
         double requiredGrossAtStop=g_lockMoney-carryingCosts;
         candidate=OrderOpenPrice()+direction*(requiredGrossAtStop/moneyPerPrice);
         source="PROFIT_LOCK";
        }

      if(g_enableTrailing && netProfit>=g_trailStart)
        {
         double desiredNetAtStop=netProfit-g_trailDistance;
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
      candidate=NormalizeProtectiveStop(candidate,orderType);
      if(candidate<=0.0)
         continue;

      // Wait until the requested protective level is legal; never weaken it.
      if((orderType==OP_BUY && candidate>Bid-brokerDistance) ||
         (orderType==OP_SELL && candidate<Ask+brokerDistance))
         continue;

      double oldStop=OrderStopLoss();
      double stepDistance=(source=="TRAILING" && g_trailStep>0.0 ?
                           g_trailStep/moneyPerPrice : 0.0);
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
         Print("XVISION EMA50 V7: ",source," moved ticket=",ticket,
               " SL to ",DoubleToString(candidate,Digits),
               " at net profit ",DoubleToString(netProfit,2)," ",AccountCurrency());
        }
      else
        {
         int error=GetLastError();
         if(TimeCurrent()-g_lastManagementErrorPrint>=30)
           {
            Print("XVISION EMA50 V7: protection modification failed ticket=",ticket,
                  " error=",error," requested SL=",DoubleToString(candidate,Digits));
            g_lastManagementErrorPrint=TimeCurrent();
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Prevent duplicate exposure from v1-v6 or another EA instance.   |
//+------------------------------------------------------------------+
bool IsXVISIONExposureSelected()
  {
   if(OrderSymbol()!=Symbol())
      return(false);
   int magic=OrderMagicNumber();
   if(magic==g_magic || magic==50503001 || magic==50503002 ||
      magic==50503003 || magic==50503004 || magic==50503005 ||
      magic==50503006)
      return(true);
   return(StringFind(OrderComment(),"XVE")==0);
  }

bool HasEAExposure()
  {
   for(int pos=OrdersTotal()-1; pos>=0; pos--)
     {
      if(!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES))
         continue;
      if(IsXVISIONExposureSelected())
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
//| EMAReady() or test the returned value before using it.          |
//+------------------------------------------------------------------+
double EMAValue(const int shift)
  {
   double value=iMA(Symbol(),SignalTimeframe,g_emaPeriod,0,MODE_EMA,PRICE_CLOSE,shift);
   if(!MathIsValidNumber(value) || value<=0.0)
      return(0.0);
   return(value);
  }

//+------------------------------------------------------------------+
//| True when every EMA value from shift 1 to deepestShift is usable.|
//+------------------------------------------------------------------+
bool EMAReady(const int deepestShift)
  {
   for(int shift=1; shift<=deepestShift; shift++)
      if(EMAValue(shift)<=0.0)
         return(false);
   return(true);
  }

double MoneyPerPriceUnitPerLot()
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
bool ResolveLotSize(const double requested,double &lots)
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

   lots=NormalizeDouble(executable,LotDigits());
   return(lots>0.0);
  }

//+------------------------------------------------------------------+
//| Resolve the volume and report any adjustment. Trade paths use     |
//| this; the dashboard uses ResolveLotSize() directly so that        |
//| refreshing the panel cannot spam the log.                        |
//+------------------------------------------------------------------+
bool ResolveLotSizeForTrade(const double requested,double &lots)
  {
   if(!ResolveLotSize(requested,lots))
     {
      Print("XVISION EMA50 V7: requested volume ",DoubleToString(requested,8),
            " is below the broker minimum ",
            DoubleToString(MarketInfo(Symbol(),MODE_MINLOT),8),
            " or the lot grid is unavailable; trade rejected.");
      return(false);
     }
   if(MathAbs(lots-requested)>1.0e-8)
      Print("XVISION EMA50 V7: volume ",DoubleToString(requested,8),
            " rounded down to ",DoubleToString(lots,LotDigits()),
            " to fit the broker lot step of ",
            DoubleToString(MarketInfo(Symbol(),MODE_LOTSTEP),8),".");
   return(true);
  }

int DecimalDigitsForValue(const double value)
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

int LotDigits()
  {
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   double minimum=MarketInfo(Symbol(),MODE_MINLOT);
   return((int)MathMax(DecimalDigitsForValue(step),
                       DecimalDigitsForValue(minimum)));
  }

int SlippagePoints()
  {
   if(g_maxSlippage<=0.0 || Point<=0.0)
      return(0);
   return((int)MathCeil(g_maxSlippage/Point));
  }

bool IsGoldSymbol()
  {
   string symbolName=Symbol();
   StringToUpper(symbolName);
   return(StringFind(symbolName,"GOLD")>=0 || StringFind(symbolName,"XAU")>=0);
  }

string DirectionName(const int direction)
  {
   return(direction>0 ? "BUY" : "SELL");
  }

string BoolText(const bool value)
  {
   return(value ? "YES" : "NO");
  }

string TimeframeName(const ENUM_TIMEFRAMES timeframe)
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
string StateKey(const string suffix)
  {
   int resolvedTimeframe=(SignalTimeframe==PERIOD_CURRENT ?
                          Period() : (int)SignalTimeframe);
   long symbolHash=0;
   string symbolName=Symbol();
   for(int index=0; index<StringLen(symbolName); index++)
      symbolHash=(symbolHash*131+StringGetCharacter(symbolName,index))%2147483647;
   return("XVE6_"+IntegerToString(AccountNumber())+"_"+
          IntegerToString((int)symbolHash)+"_"+
          IntegerToString(g_magic)+"_"+IntegerToString(resolvedTimeframe)+"_"+
          IntegerToString(g_emaPeriod)+"_"+suffix);
  }

bool PersistentStateEnabled()
  {
   return(UsePersistentEpisodeState && !IsTesting());
  }

void DeleteEpisodeState()
  {
   GlobalVariableDel(StateKey("LOCK"));
   GlobalVariableDel(StateKey("QUIET"));
   GlobalVariableDel(StateKey("BAR"));
   GlobalVariableDel(StateKey("SIGNAL"));
   GlobalVariableDel(StateKey("RET_STATE"));
   GlobalVariableDel(StateKey("RET_DIR"));
   GlobalVariableDel(StateKey("RET_COUNT"));
   GlobalVariableDel(StateKey("RET_SIGNAL"));
   GlobalVariableDel(StateKey("RET_TICKET"));
  }

void LoadEpisodeState()
  {
   if(ResetPersistentStateOnInit && PersistentStateEnabled())
      DeleteEpisodeState();

   if(PersistentStateEnabled() && GlobalVariableCheck(StateKey("LOCK")))
     {
      g_episodeLocked=(GlobalVariableGet(StateKey("LOCK"))>0.5);
      g_quietBars=(int)GlobalVariableGet(StateKey("QUIET"));
      g_lastProcessedBar=(datetime)GlobalVariableGet(StateKey("BAR"));
      g_lastSignalBar=(datetime)GlobalVariableGet(StateKey("SIGNAL"));
      g_retestState=(GlobalVariableCheck(StateKey("RET_STATE")) ?
                     (int)GlobalVariableGet(StateKey("RET_STATE")) : RETEST_IDLE);
      g_retestDirection=(GlobalVariableCheck(StateKey("RET_DIR")) ?
                         (int)GlobalVariableGet(StateKey("RET_DIR")) : 0);
      g_retestCount=(GlobalVariableCheck(StateKey("RET_COUNT")) ?
                     (int)GlobalVariableGet(StateKey("RET_COUNT")) : 0);
      g_retestSignalBar=(GlobalVariableCheck(StateKey("RET_SIGNAL")) ?
                         (datetime)GlobalVariableGet(StateKey("RET_SIGNAL")) : 0);
      g_retestTicket=(GlobalVariableCheck(StateKey("RET_TICKET")) ?
                      (int)GlobalVariableGet(StateKey("RET_TICKET")) : 0);
      if(g_quietBars<0)
         g_quietBars=0;
      if(g_retestTicket<0)
         g_retestTicket=0;
      datetime currentBar=iTime(Symbol(),SignalTimeframe,0);
      if(currentBar>0 && g_lastProcessedBar>currentBar)
         g_lastProcessedBar=currentBar;
      if(g_retestState<RETEST_IDLE || g_retestState>RETEST_USED ||
         g_retestDirection<-1 || g_retestDirection>1 || g_retestCount<0 ||
         (g_retestState!=RETEST_IDLE && g_retestDirection==0))
        {
         g_retestState=RETEST_IDLE;
         g_retestDirection=0;
         g_retestCount=0;
         g_retestSignalBar=0;
         g_retestTicket=0;
        }
      g_retestStatus=(g_retestState==RETEST_IDLE ?
                      "Waiting for a live EMA crossing" :
                      "Restored state: "+RetestStateName());
     }
   else
     {
      g_episodeLocked=false;
      g_quietBars=0;
      g_lastSignalBar=0;
      g_lastProcessedBar=(TradeCurrentSignalOnAttach ? 0 :
                          iTime(Symbol(),SignalTimeframe,0));
      g_retestState=RETEST_IDLE;
      g_retestDirection=0;
      g_retestCount=0;
      g_retestSignalBar=0;
      g_retestTicket=0;
      g_retestStatus="Waiting for a live EMA crossing";
     }
  }

void SaveEpisodeState()
  {
   if(!PersistentStateEnabled())
      return;
   GlobalVariableSet(StateKey("LOCK"),(g_episodeLocked ? 1.0 : 0.0));
   GlobalVariableSet(StateKey("QUIET"),(double)g_quietBars);
   GlobalVariableSet(StateKey("BAR"),(double)g_lastProcessedBar);
   GlobalVariableSet(StateKey("SIGNAL"),(double)g_lastSignalBar);
   GlobalVariableSet(StateKey("RET_STATE"),(double)g_retestState);
   GlobalVariableSet(StateKey("RET_DIR"),(double)g_retestDirection);
   GlobalVariableSet(StateKey("RET_COUNT"),(double)g_retestCount);
   GlobalVariableSet(StateKey("RET_SIGNAL"),(double)g_retestSignalBar);
   GlobalVariableSet(StateKey("RET_TICKET"),(double)g_retestTicket);
   GlobalVariablesFlush();
  }

void DeleteDashboard()
  {
   for(int index=ObjectsTotal()-1; index>=0; index--)
     {
      string name=ObjectName(index);
      if(StringFind(name,g_dashboardPrefix)==0)
         ObjectDelete(0,name);
     }
   g_panelBuilt=false;
  }

//+------------------------------------------------------------------+
//| Create the label once, then touch only what changed.             |
//| Returns true when this call actually altered the chart, so the   |
//| caller can decide whether a redraw is warranted at all.          |
//+------------------------------------------------------------------+
bool SetDashboardLabel(const string id,const string value,const int y,
                       const color textColor,const int fontSize=0)
  {
   string name=g_dashboardPrefix+id;
   bool   rebuild=!g_panelBuilt;

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
      int resolvedFont=(fontSize>0 ? (int)MathRound(fontSize*g_panelScale) : g_panelFont);
      resolvedFont=(int)MathMax(6,resolvedFont);
      ObjectSetInteger(0,name,OBJPROP_CORNER,DashboardCorner);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,g_panelX+16);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,g_panelY+PanelRow(y));
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
      g_panelChanged=true;
   return(changed);
  }

//+------------------------------------------------------------------+
//| Character budget for one row, derived from the resolved panel    |
//| width and font rather than a fixed 57 that assumed both.         |
//+------------------------------------------------------------------+
string DashboardTextLimit(const string value,const int maximum=0)
  {
   int budget=maximum;
   if(budget<=0)
      budget=(int)MathMax(12,(g_panelWidth-32)/MathMax(1.0,g_panelFont*0.62));
   if(StringLen(value)<=budget)
      return(value);
   return(StringSubstr(value,0,budget-3)+"...");
  }

//+------------------------------------------------------------------+
//| Summarise exposure, separating what this instance manages from    |
//| what merely blocks it.                                            |
//|                                                                  |
//| HasEAExposure() blocks on any XVISION magic (50503001-50503006) or |
//| any "XVE" comment, but ManageInputProtection() only trails orders  |
//| carrying THIS instance's g_magic. So a leftover position from  |
//| an earlier version stops new entries and is never given a         |
//| trailing stop. Taking over another EA's orders would be worse, so  |
//| the asymmetry stays -- but it is now reported instead of silent.   |
//+------------------------------------------------------------------+
string PositionSummary(double &floatingProfit,int &foreignCount)
  {
   floatingProfit=0.0;
   foreignCount=0;
   int positionCount=0;
   string firstPosition="";
   for(int pos=OrdersTotal()-1; pos>=0; pos--)
     {
      if(!OrderSelect(pos,SELECT_BY_POS,MODE_TRADES))
         continue;
      if(!IsXVISIONExposureSelected())
         continue;
      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL)
         continue;
      floatingProfit+=OrderProfit()+OrderSwap()+OrderCommission();
      positionCount++;
      if(OrderMagicNumber()!=g_magic)
         foreignCount++;
      string side=(OrderType()==OP_BUY ? "BUY" : "SELL");
      if(firstPosition=="")
         firstPosition=side+"  #"+IntegerToString(OrderTicket())+"  lot "+
                       DoubleToString(OrderLots(),LotDigits());
     }
   if(positionCount<=0)
      return("NONE");
   if(positionCount==1)
      return(firstPosition);
   return("MULTIPLE x"+IntegerToString(positionCount));
  }

void UpdateDashboard(const bool force=false)
  {
   if(!ShowDashboard)
     {
      if(g_panelBuilt)
         DeleteDashboard();          // once, not on every tick
      return;
     }

   // A non-visual backtest has no chart to draw on; drawing there is pure cost.
   if(IsTesting() && !IsVisualMode())
      return;

   if(!force && g_panelRefreshMs>0 &&
      (uint)(GetTickCount()-g_lastPanelRefresh)<(uint)g_panelRefreshMs)
      return;
   g_lastPanelRefresh=GetTickCount();
   g_panelChanged=false;

   string background=g_dashboardPrefix+"BACKGROUND";
   if(ObjectFind(0,background)<0)
     {
      ObjectCreate(0,background,OBJ_RECTANGLE_LABEL,0,0,0);
      g_panelBuilt=false;
     }
   if(!g_panelBuilt)
     {
      ObjectSetInteger(0,background,OBJPROP_CORNER,DashboardCorner);
      ObjectSetInteger(0,background,OBJPROP_XDISTANCE,g_panelX);
      ObjectSetInteger(0,background,OBJPROP_YDISTANCE,g_panelY);
      ObjectSetInteger(0,background,OBJPROP_XSIZE,g_panelWidth);
      ObjectSetInteger(0,background,OBJPROP_YSIZE,g_panelHeight);
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
      g_panelChanged=true;
     }

   RefreshRates();
   double floatingProfit=0.0;
   int foreignPositions=0;
   string position=PositionSummary(floatingProfit,foreignPositions);
   double spread=MathMax(0.0,Ask-Bid);
   bool spreadAllowed=(g_maxSpread<=0.0 || spread<=g_maxSpread);
   double executableLot=0.0;
   bool lotAllowed=ResolveLotSize(g_fixedLot,executableLot);
   bool tradingAllowed=(!g_tradingBlocked && IsTradeAllowed() && !IsTradeContextBusy() &&
                        MarketInfo(Symbol(),MODE_TRADEALLOWED)>0.5);
   string episode=(g_episodeLocked ? "LOCKED" : "ARMED");
   string signalTime=(g_lastSignalBar>0 ?
                      TimeToString(g_lastSignalBar,TIME_DATE|TIME_MINUTES) : "none");

   SetDashboardLabel("TITLE","XVISION  |  GOLD EMA50 EA V7",12,DashboardAccent,14);
   SetDashboardLabel("SUBTITLE",TimeframeName(SignalTimeframe)+" SIGNAL  |  EMA "+
                     IntegerToString(g_emaPeriod)+"  |  CROSS + FIRST RETEST",36,DashboardText,9);
   SetDashboardLabel("H_STATUS","STATUS",59,DashboardHeading,10);
   SetDashboardLabel("DECISION",DashboardTextLimit(g_lastDecision),77,DashboardText,11);
   SetDashboardLabel("SIGNAL","Last qualified: "+signalTime,97,DashboardText,10);
   SetDashboardLabel("LOCK","Episode: "+episode+"  |  quiet "+IntegerToString(g_quietBars)+
                     "/"+IntegerToString(g_quietBarsRequired),115,
                     (g_episodeLocked ? clrOrange : clrLime),10);

   SetDashboardLabel("H_FILTERS","SIGNAL FILTERS",140,DashboardHeading,10);
   SetDashboardLabel("GRADIENT","EMA slope now  "+DoubleToString(g_currentSlope,4)+
                     "  |  last-cross direction  "+DoubleToString(g_lastDirectionalGradient,4),
                     158,DashboardText,10);
   SetDashboardLabel("RANGE","Current range votes  "+IntegerToString(g_currentRangeVotes)+
                     "/3  (continuation max "+IntegerToString(g_maxRangeVotes)+")",
                     176,DashboardText,10);
   SetDashboardLabel("EFFICIENCY","Current efficiency  "+DoubleToString(g_currentEfficiency,3)+
                     "  (min "+DoubleToString(g_minEfficiency,3)+")",
                     194,DashboardText,10);

   string retestDirection=(g_retestDirection==0 ? "NONE" : DirectionName(g_retestDirection));
   color retestColor=(g_retestState==RETEST_ARMED || g_retestState==RETEST_PENDING ?
                      clrLime : (g_retestState==RETEST_USED ? clrOrange : DashboardText));
   SetDashboardLabel("H_RETEST","EMA RETEST ENGINE",219,DashboardHeading,10);
   SetDashboardLabel("RETEST_STATE","State  "+RetestStateName()+"  |  direction "+
                     retestDirection+"  |  used "+IntegerToString(g_retestCount)+"/"+
                     IntegerToString(g_maxRetestsPerLeg),237,retestColor,10);
   SetDashboardLabel("RETEST_STATUS",DashboardTextLimit(g_retestStatus),255,retestColor,10);

   SetDashboardLabel("H_TRADE","POSITION / PROTECTION",280,DashboardHeading,10);
   SetDashboardLabel("POSITION","Position: "+position+"  |  P/L "+
                     (floatingProfit>=0.0 ? "+" : "")+DoubleToString(floatingProfit,2)+
                     (foreignPositions>0 ? "  |  "+IntegerToString(foreignPositions)+
                      " UNMANAGED (other magic)" : ""),
                     298,(foreignPositions>0 ? clrOrange :
                          (floatingProfit>=0.0 ? clrLime : clrTomato)),10);
   SetDashboardLabel("LOT","Requested lot  "+DoubleToString(g_fixedLot,LotDigits())+
                     "  |  executable  "+(lotAllowed ? DoubleToString(executableLot,LotDigits()) : "REJECT"),
                     316,(lotAllowed ? clrLime : clrTomato),10);
   SetDashboardLabel("RISK","SL / TP ("+AccountCurrency()+")  "+
                     (g_stopLossMoney>0.0 ? DoubleToString(g_stopLossMoney,2) : "OFF")+" / "+
                     (g_takeProfitMoney>0.0 ? DoubleToString(g_takeProfitMoney,2) : "OFF"),
                     334,DashboardText,10);
   SetDashboardLabel("TRAIL","Trailing  "+(g_enableTrailing ? "ON" : "OFF")+
                     (g_enableTrailing ? "  start / distance / step  "+
                      DoubleToString(g_trailStart,2)+" / "+
                      DoubleToString(g_trailDistance,2)+" / "+
                      DoubleToString(g_trailStep,2) : ""),
                     352,(g_enableTrailing ? clrLime : DashboardText),10);
   SetDashboardLabel("PROFIT_LOCK","Profit lock  "+(g_enableProfitLock ? "ON" : "OFF")+
                     (g_enableProfitLock ? "  trigger / lock  "+
                      DoubleToString(g_lockTrigger,2)+" / "+
                      DoubleToString(g_lockMoney,2) : ""),
                     370,(g_enableProfitLock ? clrLime : DashboardText),10);

   SetDashboardLabel("H_LIVE","LIVE",395,DashboardHeading,10);
   SetDashboardLabel("MARKET","Bid / Ask  "+DoubleToString(Bid,Digits)+" / "+
                     DoubleToString(Ask,Digits)+"  |  spread "+DoubleToString(spread,Digits)+
                     " (max "+DoubleToString(g_maxSpread,Digits)+")  "+
                     (spreadAllowed ? "ENABLED" : "BLOCKED"),413,
                     (spreadAllowed ? clrLime : clrTomato),10);
   SetDashboardLabel("PERMISSION",DashboardTextLimit("Trade permission  "+
                     (tradingAllowed ? "ENABLED" : "BLOCKED")+
                     (g_tradingBlocked ? "  |  "+g_blockReason
                                       : "  |  EA modifies SL only; no forced close")),431,
                     (tradingAllowed ? clrLime : clrTomato),10);

   g_panelBuilt=true;
   if(g_panelChanged)
      ChartRedraw();          // only when the panel actually changed
  }
//+------------------------------------------------------------------+
