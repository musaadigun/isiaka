//+------------------------------------------------------------------+
//|                                                      IsiakaEA.mq5 |
//|                                                                   |
//|  Main expert. Wires the strategy layer (Signal.mqh) to sizing     |
//|  (Risk.mqh) and order handling (Execution.mqh). The trading rules |
//|  themselves live in Signal.mqh -- not here.                       |
//+------------------------------------------------------------------+
#property copyright "Isiaka"
#property version   "1.00"
#property strict

#include <Isiaka/Defs.mqh>
#include <Isiaka/Risk.mqh>
#include <Isiaka/Execution.mqh>
#include <Isiaka/Signal.mqh>

//--- Strategy -------------------------------------------------------
input group "Strategy"
input ENUM_TIMEFRAMES InpTimeframe          = PERIOD_CURRENT; // Signal timeframe
input bool            InpNewBarOnly         = true;           // Evaluate on new bar only
input int             InpAtrPeriod          = 14;             // ATR period

//--- Stops ----------------------------------------------------------
input group "Stops and targets"
input ENUM_STOP_MODE  InpStopMode           = STOP_ATR;       // Stop loss mode
input double          InpStopPoints         = 300;            // Stop distance (points)
input double          InpAtrStopMultiplier  = 2.0;            // Stop = ATR * this
input double          InpRewardRatio        = 2.0;            // TP = stop * this (0 = no TP)

//--- Money management -----------------------------------------------
input group "Money management"
input ENUM_LOT_MODE   InpLotMode            = LOT_RISK_PERCENT; // Sizing mode
input double          InpFixedLot           = 0.10;           // Fixed volume
input double          InpRiskPercent        = 1.0;            // Risk per trade (% of balance)
input double          InpMaxLot             = 0.0;            // Volume ceiling (0 = broker max)

//--- Trade management -----------------------------------------------
input group "Trade management"
input ulong           InpMagic              = 20260816;       // Magic number
input ulong           InpDeviationPoints    = 20;             // Max slippage (points)
input int             InpMaxSpreadPoints    = 40;             // Max spread to enter (0 = off)
input int             InpMaxPositions       = 1;              // Max concurrent positions

input bool            InpUseBreakeven       = true;           // Move stop to breakeven
input double          InpBreakevenTriggerPts= 300;            // Trigger (points in profit)
input double          InpBreakevenOffsetPts = 20;             // Offset beyond entry (points)

input bool            InpUseTrailing        = false;          // Trailing stop
input double          InpTrailingStartPts   = 400;            // Start trailing after (points)
input double          InpTrailingDistPts    = 250;            // Trail distance (points)
input double          InpTrailingStepPts    = 50;             // Min step before modifying

//--- Session filter --------------------------------------------------
input group "Session filter"
input bool            InpUseSessionFilter   = false;          // Restrict trading hours
input int             InpStartHour          = 7;              // Start hour (server time)
input int             InpEndHour            = 20;             // End hour (server time)

//--- Globals ---------------------------------------------------------
CRisk      g_risk;
CExecution g_exec;
CSignal    g_signal;

ENUM_TIMEFRAMES g_tf   = PERIOD_CURRENT;
datetime        g_last_bar_time = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : InpTimeframe;

   if(InpLotMode == LOT_RISK_PERCENT && InpRiskPercent <= 0.0)
   {
      Print("InpRiskPercent must be greater than zero when sizing by risk");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpStopMode == STOP_FIXED_POINTS && InpStopPoints <= 0.0)
   {
      Print("InpStopPoints must be greater than zero in fixed-stop mode");
      return INIT_PARAMETERS_INCORRECT;
   }

   SRiskSettings risk_cfg;
   risk_cfg.lot_mode     = InpLotMode;
   risk_cfg.fixed_lot    = InpFixedLot;
   risk_cfg.risk_percent = InpRiskPercent;
   risk_cfg.max_lot      = InpMaxLot;

   STradeSettings trade_cfg;
   trade_cfg.magic                 = InpMagic;
   trade_cfg.deviation_points      = InpDeviationPoints;
   trade_cfg.max_spread_points     = InpMaxSpreadPoints;
   trade_cfg.max_positions         = InpMaxPositions;
   trade_cfg.use_breakeven         = InpUseBreakeven;
   trade_cfg.breakeven_trigger_pts = InpBreakevenTriggerPts;
   trade_cfg.breakeven_offset_pts  = InpBreakevenOffsetPts;
   trade_cfg.use_trailing          = InpUseTrailing;
   trade_cfg.trailing_start_pts    = InpTrailingStartPts;
   trade_cfg.trailing_distance_pts = InpTrailingDistPts;
   trade_cfg.trailing_step_pts     = InpTrailingStepPts;

   if(!g_risk.Init(_Symbol, risk_cfg))
      return INIT_FAILED;

   if(!g_exec.Init(_Symbol, trade_cfg))
      return INIT_FAILED;

   if(!g_signal.Init(_Symbol, g_tf, InpAtrPeriod))
      return INIT_FAILED;

   g_last_bar_time = iTime(_Symbol, g_tf, 0);

   PrintFormat("IsiakaEA initialised on %s %s, magic %I64u",
               _Symbol, EnumToString(g_tf), InpMagic);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   g_signal.Deinit();
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, g_tf, 0);
   if(t == 0)
      return false;

   if(t != g_last_bar_time)
   {
      g_last_bar_time = t;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool SessionOpen()
{
   if(!InpUseSessionFilter)
      return true;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   //--- Supports windows that wrap past midnight (e.g. 22 -> 6).
   if(InpStartHour <= InpEndHour)
      return (now.hour >= InpStartHour && now.hour < InpEndHour);

   return (now.hour >= InpStartHour || now.hour < InpEndHour);
}

//+------------------------------------------------------------------+
//| Resolve the stop distance for a pending entry, in points.        |
//| A stop supplied by the strategy always wins over the inputs.     |
//+------------------------------------------------------------------+
double ResolveStopPoints()
{
   double from_signal = g_signal.StopPoints();
   if(from_signal > 0.0)
      return from_signal;

   if(InpStopMode == STOP_ATR)
   {
      double atr_pts = g_signal.AtrPoints(1);
      if(atr_pts <= 0.0)
      {
         Print("ATR unavailable, skipping entry");
         return 0.0;
      }
      return atr_pts * InpAtrStopMultiplier;
   }

   return InpStopPoints;
}

//+------------------------------------------------------------------+
double ResolveTargetPoints(const double stop_points)
{
   double from_signal = g_signal.TargetPoints();
   if(from_signal > 0.0)
      return from_signal;

   if(InpRewardRatio <= 0.0)
      return 0.0;

   return stop_points * InpRewardRatio;
}

//+------------------------------------------------------------------+
void OnTick()
{
   //--- Housekeeping runs on every tick regardless of the bar clock.
   g_exec.ManageOpenPositions();

   bool new_bar = IsNewBar();
   if(InpNewBarOnly && !new_bar)
      return;

   if(!SessionOpen())
      return;

   if(!g_exec.CanOpenNew())
      return;

   ENUM_SIGNAL sig = g_signal.Check();
   if(sig == SIGNAL_NONE)
      return;

   double stop_points = ResolveStopPoints();
   if(stop_points <= 0.0)
      return;

   double target_points = ResolveTargetPoints(stop_points);

   double lots = g_risk.CalculateLots(stop_points);
   if(lots <= 0.0)
   {
      Print("Calculated volume resolved to zero, entry skipped");
      return;
   }

   if(!g_exec.Open(sig, lots, stop_points, target_points, "IsiakaEA"))
      PrintFormat("Entry failed: dir=%d lots=%.2f stop=%.0f", sig, lots, stop_points);
}
//+------------------------------------------------------------------+
