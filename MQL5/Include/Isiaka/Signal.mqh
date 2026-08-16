//+------------------------------------------------------------------+
//|                                                       Signal.mqh |
//|                                                                  |
//|  THIS IS THE FILE YOUR STRATEGY GOES IN. Everything else in the  |
//|  project is plumbing that does not change when the rules change. |
//|                                                                  |
//|  Contract:                                                       |
//|    Check() returns SIGNAL_BUY / SIGNAL_SELL / SIGNAL_NONE.       |
//|    StopPoints() / TargetPoints() return the distances the EA     |
//|    should use for the trade it is about to open.                 |
//|                                                                  |
//|  Bar indexing rule: index 0 is the forming bar and its high,     |
//|  low and close are still moving. Read your conditions from bar   |
//|  1 or higher unless you deliberately want intrabar behaviour --  |
//|  reading bar 0 is the single most common reason a backtest looks |
//|  brilliant and the live account does not.                        |
//+------------------------------------------------------------------+
#ifndef ISIAKA_SIGNAL_MQH
#define ISIAKA_SIGNAL_MQH

#include <Isiaka/Defs.mqh>

class CSignal
{
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;

   //--- ATR is wired up because stop sizing usually wants it. If your rules
   //--- do not use ATR you can drop this handle and the STOP_ATR mode.
   int               m_atr_handle;
   int               m_atr_period;

   double            m_stop_points;
   double            m_target_points;

public:
   CSignal(void) : m_atr_handle(INVALID_HANDLE),
                   m_atr_period(14),
                   m_stop_points(0.0),
                   m_target_points(0.0) {}

   bool Init(const string symbol, const ENUM_TIMEFRAMES tf, const int atr_period)
   {
      m_symbol     = symbol;
      m_timeframe  = tf;
      m_atr_period = atr_period;

      m_atr_handle = iATR(m_symbol, m_timeframe, m_atr_period);
      if(m_atr_handle == INVALID_HANDLE)
      {
         PrintFormat("CSignal: iATR failed for %s, error %d", m_symbol, GetLastError());
         return false;
      }

      // TODO: create the indicator handles your trend needs here.

      return true;
   }

   void Deinit(void)
   {
      if(m_atr_handle != INVALID_HANDLE)
      {
         IndicatorRelease(m_atr_handle);
         m_atr_handle = INVALID_HANDLE;
      }
   }

   //--- ATR value on a closed bar, in points.
   double AtrPoints(const int shift = 1) const
   {
      double buf[];
      if(CopyBuffer(m_atr_handle, 0, shift, 1, buf) != 1)
         return 0.0;

      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0.0)
         return 0.0;

      return buf[0] / point;
   }

   double StopPoints(void)   const { return m_stop_points;   }
   double TargetPoints(void) const { return m_target_points; }

   //+---------------------------------------------------------------+
   //| Evaluate the entry rules for the bar that just closed.        |
   //|                                                               |
   //| Fill in the body below with the trend you observed. Set       |
   //| m_stop_points / m_target_points before returning a direction  |
   //| if the stop depends on the setup (e.g. behind the swing that  |
   //| triggered it); leave them at 0 to let the EA inputs decide.   |
   //+---------------------------------------------------------------+
   ENUM_SIGNAL Check(void)
   {
      m_stop_points   = 0.0;
      m_target_points = 0.0;

      // ------------------------------------------------------------
      // TODO: strategy rules.
      //
      // Example of the shape this takes -- read closed bars only:
      //
      //   MqlRates rates[];
      //   ArraySetAsSeries(rates, true);
      //   if(CopyRates(m_symbol, m_timeframe, 1, 3, rates) != 3)
      //      return SIGNAL_NONE;
      //
      //   if(<your bullish condition on rates[0], rates[1], ...>)
      //      return SIGNAL_BUY;
      //
      //   if(<your bearish condition>)
      //      return SIGNAL_SELL;
      // ------------------------------------------------------------

      return SIGNAL_NONE;
   }

   //--- Optional: return true to close an open position early, independently
   //--- of stop loss and take profit (e.g. the trend condition has flipped).
   bool ShouldExit(const ENUM_POSITION_TYPE type)
   {
      // TODO: exit rules, if the strategy has any beyond SL/TP.
      return false;
   }
};

#endif // ISIAKA_SIGNAL_MQH
