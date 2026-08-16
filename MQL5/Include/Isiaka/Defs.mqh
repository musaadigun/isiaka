//+------------------------------------------------------------------+
//|                                                         Defs.mqh |
//|                    Shared enums and settings structs for the EA. |
//+------------------------------------------------------------------+
#ifndef ISIAKA_DEFS_MQH
#define ISIAKA_DEFS_MQH

//--- What the strategy layer hands back to the EA each evaluation.
enum ENUM_SIGNAL
{
   SIGNAL_NONE =  0,
   SIGNAL_BUY  =  1,
   SIGNAL_SELL = -1
};

//--- How the protective stop distance is derived.
enum ENUM_STOP_MODE
{
   STOP_FIXED_POINTS,   // Fixed distance in points
   STOP_ATR             // ATR(period) * multiplier
};

//--- How position size is decided.
enum ENUM_LOT_MODE
{
   LOT_FIXED,           // Always the same volume
   LOT_RISK_PERCENT     // Volume derived from % of balance at risk
};

struct SRiskSettings
{
   ENUM_LOT_MODE  lot_mode;
   double         fixed_lot;
   double         risk_percent;     // percent of balance risked per trade
   double         max_lot;          // hard ceiling regardless of the maths
};

struct STradeSettings
{
   ulong          magic;
   ulong          deviation_points;
   int            max_spread_points;   // skip entries when spread is wider
   int            max_positions;       // concurrent positions for this magic

   bool           use_breakeven;
   double         breakeven_trigger_pts;
   double         breakeven_offset_pts;

   bool           use_trailing;
   double         trailing_start_pts;
   double         trailing_distance_pts;
   double         trailing_step_pts;   // minimum SL improvement before modifying
};

#endif // ISIAKA_DEFS_MQH
