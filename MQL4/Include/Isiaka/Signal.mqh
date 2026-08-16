//+------------------------------------------------------------------+
//|                                                       Signal.mqh |
//|                                                                  |
//|  THIS IS THE FILE YOUR STRATEGY GOES IN. Everything else in the  |
//|  project is plumbing that does not change when the rules change. |
//|                                                                  |
//|  Contract:                                                       |
//|    Check() returns SIGNAL_BUY / SIGNAL_SELL / SIGNAL_NONE.       |
//|    StopPoints() / TargetPoints() return the distances the EA     |
//|    should use for the trade it is about to open, or 0 to let     |
//|    the EA inputs decide.                                         |
//|                                                                  |
//|  Bar indexing rule: shift 0 is the forming bar -- its high, low  |
//|  and close are still moving. Read your conditions from shift 1   |
//|  or higher unless you deliberately want intrabar behaviour.      |
//|  Reading shift 0 is the single most common reason a backtest     |
//|  looks brilliant and the live account does not.                  |
//+------------------------------------------------------------------+
#property strict

#ifndef ISIAKA_SIGNAL_MQH
#define ISIAKA_SIGNAL_MQH

#include <Isiaka/Defs.mqh>

class CSignal
{
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   int               m_atr_period;

   double            m_stop_points;
   double            m_target_points;

public:
   CSignal(void) : m_atr_period(14),
                   m_stop_points(0.0),
                   m_target_points(0.0) {}

   bool Init(const string symbol, const ENUM_TIMEFRAMES tf, const int atr_period)
   {
      m_symbol     = symbol;
      m_timeframe  = tf;
      m_atr_period = atr_period;

      // TODO: any one-off setup your rules need goes here.

      return true;
   }

   void Deinit(void)
   {
      // TODO: release anything Init() acquired. Nothing to do yet.
   }

   //--- ATR on a closed bar, expressed in points.
   double AtrPoints(const int shift = 1)
   {
      double atr   = iATR(m_symbol, m_timeframe, m_atr_period, shift);
      double point = MarketInfo(m_symbol, MODE_POINT);

      if(atr <= 0.0 || point <= 0.0)
         return 0.0;

      return atr / point;
   }

   double StopPoints(void)   { return m_stop_points;   }
   double TargetPoints(void) { return m_target_points; }

   //+---------------------------------------------------------------+
   //| Evaluate the entry rules for the bar that just closed.        |
   //|                                                               |
   //| Fill in the body below with the trend you observed. Set       |
   //| m_stop_points / m_target_points before returning a direction  |
   //| if the stop depends on the setup (e.g. behind the swing that  |
   //| triggered it); leave them at 0 to use the EA inputs instead.  |
   //+---------------------------------------------------------------+
   ENUM_SIGNAL Check(void)
   {
      m_stop_points   = 0.0;
      m_target_points = 0.0;

      // ------------------------------------------------------------
      // TODO: strategy rules.
      //
      // Example of the shape this takes -- closed bars only, so shift 1
      // is the bar that just finished and shift 2 the one before it:
      //
      //   double close1 = iClose(m_symbol, m_timeframe, 1);
      //   double high2  = iHigh(m_symbol, m_timeframe, 2);
      //   double low2   = iLow(m_symbol, m_timeframe, 2);
      //
      //   if(<your bullish condition>)
      //   {
      //      m_stop_points = (close1 - low2) / MarketInfo(m_symbol, MODE_POINT);
      //      return SIGNAL_BUY;
      //   }
      //
      //   if(<your bearish condition>)
      //      return SIGNAL_SELL;
      // ------------------------------------------------------------

      return SIGNAL_NONE;
   }

   //--- Optional: return true to close an open order early, independently of
   //--- stop loss and take profit (e.g. the trend condition has flipped).
   //--- `order_type` is OP_BUY or OP_SELL.
   bool ShouldExit(const int order_type)
   {
      // TODO: exit rules, if the strategy has any beyond SL/TP.
      return false;
   }
};

#endif // ISIAKA_SIGNAL_MQH
