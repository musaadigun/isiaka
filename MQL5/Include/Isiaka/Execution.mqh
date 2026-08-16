//+------------------------------------------------------------------+
//|                                                    Execution.mqh |
//|      Order placement and open-position housekeeping. Keeps every |
//|      broker-constraint check (stops level, freeze level, spread, |
//|      filling mode) in one place so the strategy never sees them. |
//+------------------------------------------------------------------+
#ifndef ISIAKA_EXECUTION_MQH
#define ISIAKA_EXECUTION_MQH

#include <Trade/Trade.mqh>
#include <Isiaka/Defs.mqh>

class CExecution
{
private:
   CTrade          m_trade;
   string          m_symbol;
   STradeSettings  m_cfg;
   int             m_digits;
   double          m_point;

   double          Bid() const { return SymbolInfoDouble(m_symbol, SYMBOL_BID); }
   double          Ask() const { return SymbolInfoDouble(m_symbol, SYMBOL_ASK); }

   //--- Minimum distance the broker allows between price and SL/TP.
   double          StopsLevelPts() const
   {
      return (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   }

   void            SelectFillingMode()
   {
      long modes = SymbolInfoInteger(m_symbol, SYMBOL_FILLING_MODE);

      if((modes & SYMBOL_FILLING_FOK) != 0)
         m_trade.SetTypeFilling(ORDER_FILLING_FOK);
      else if((modes & SYMBOL_FILLING_IOC) != 0)
         m_trade.SetTypeFilling(ORDER_FILLING_IOC);
      else
         m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   }

public:
   bool Init(const string symbol, const STradeSettings &cfg)
   {
      m_symbol = symbol;
      m_cfg    = cfg;
      m_digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      m_point  = SymbolInfoDouble(m_symbol, SYMBOL_POINT);

      if(m_point <= 0.0)
      {
         PrintFormat("CExecution: bad point size for %s", m_symbol);
         return false;
      }

      m_trade.SetExpertMagicNumber(m_cfg.magic);
      m_trade.SetDeviationInPoints(m_cfg.deviation_points);
      m_trade.SetAsyncMode(false);
      SelectFillingMode();
      return true;
   }

   double CurrentSpreadPts() const
   {
      return (Ask() - Bid()) / m_point;
   }

   bool SpreadAcceptable() const
   {
      if(m_cfg.max_spread_points <= 0)
         return true;
      return CurrentSpreadPts() <= (double)m_cfg.max_spread_points;
   }

   //--- Positions currently open on this symbol under our magic number.
   int CountPositions() const
   {
      int count = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol)
            continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != m_cfg.magic)
            continue;
         count++;
      }
      return count;
   }

   bool CanOpenNew() const
   {
      if(m_cfg.max_positions > 0 && CountPositions() >= m_cfg.max_positions)
         return false;
      return SpreadAcceptable();
   }

   //--- stop_points / target_points are distances from the entry price.
   //--- Pass target_points <= 0 for "no take profit".
   bool Open(const ENUM_SIGNAL dir,
             const double      lots,
             const double      stop_points,
             const double      target_points,
             const string      comment = "")
   {
      if(lots <= 0.0)
      {
         Print("CExecution: refusing to send a zero-volume order");
         return false;
      }

      double min_dist = MathMax(StopsLevelPts(), 0.0);
      if(stop_points > 0.0 && stop_points < min_dist)
      {
         PrintFormat("CExecution: stop %.0f pts is inside the broker minimum of %.0f pts",
                     stop_points, min_dist);
         return false;
      }

      double price, sl = 0.0, tp = 0.0;

      if(dir == SIGNAL_BUY)
      {
         price = Ask();
         if(stop_points   > 0.0) sl = NormalizeDouble(price - stop_points   * m_point, m_digits);
         if(target_points > 0.0) tp = NormalizeDouble(price + target_points * m_point, m_digits);
         return m_trade.Buy(lots, m_symbol, price, sl, tp, comment);
      }

      if(dir == SIGNAL_SELL)
      {
         price = Bid();
         if(stop_points   > 0.0) sl = NormalizeDouble(price + stop_points   * m_point, m_digits);
         if(target_points > 0.0) tp = NormalizeDouble(price - target_points * m_point, m_digits);
         return m_trade.Sell(lots, m_symbol, price, sl, tp, comment);
      }

      return false;
   }

   void CloseAll()
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol)
            continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != m_cfg.magic)
            continue;

         m_trade.PositionClose(ticket);
      }
   }

   //--- Breakeven and trailing. Called every tick; only sends a modify when
   //--- the new stop is a genuine improvement, to avoid spamming the server.
   void ManageOpenPositions()
   {
      if(!m_cfg.use_breakeven && !m_cfg.use_trailing)
         return;

      double min_dist = MathMax(StopsLevelPts(), 0.0);

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol)
            continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != m_cfg.magic)
            continue;

         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         double cur_sl     = PositionGetDouble(POSITION_SL);
         double cur_tp     = PositionGetDouble(POSITION_TP);

         bool   is_buy  = (type == POSITION_TYPE_BUY);
         double market  = is_buy ? Bid() : Ask();
         double profit_pts = (is_buy ? (market - open_price) : (open_price - market)) / m_point;

         double new_sl = cur_sl;

         if(m_cfg.use_breakeven && profit_pts >= m_cfg.breakeven_trigger_pts)
         {
            double be = is_buy
                        ? open_price + m_cfg.breakeven_offset_pts * m_point
                        : open_price - m_cfg.breakeven_offset_pts * m_point;

            if(is_buy ? (be > new_sl) : (be < new_sl || new_sl == 0.0))
               new_sl = be;
         }

         if(m_cfg.use_trailing && profit_pts >= m_cfg.trailing_start_pts)
         {
            double trail = is_buy
                           ? market - m_cfg.trailing_distance_pts * m_point
                           : market + m_cfg.trailing_distance_pts * m_point;

            if(is_buy ? (trail > new_sl) : (trail < new_sl || new_sl == 0.0))
               new_sl = trail;
         }

         if(new_sl == cur_sl)
            continue;

         //--- Only move if the improvement clears the configured step, and if
         //--- the resulting stop is legal against the broker's stops level.
         double improvement = MathAbs(new_sl - cur_sl) / m_point;
         if(cur_sl != 0.0 && improvement < m_cfg.trailing_step_pts)
            continue;

         double distance_pts = MathAbs(market - new_sl) / m_point;
         if(distance_pts < min_dist)
            continue;

         new_sl = NormalizeDouble(new_sl, m_digits);
         if(!m_trade.PositionModify(ticket, new_sl, cur_tp))
            PrintFormat("CExecution: PositionModify(%I64u) failed, retcode %d",
                        ticket, m_trade.ResultRetcode());
      }
   }
};

#endif // ISIAKA_EXECUTION_MQH
