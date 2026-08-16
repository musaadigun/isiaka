//+------------------------------------------------------------------+
//|                                                    Execution.mqh |
//|      Order placement and open-order housekeeping. Every broker   |
//|      constraint (stop level, freeze level, spread, ECN stops,    |
//|      requotes) is handled here so the strategy never sees them.  |
//+------------------------------------------------------------------+
#property strict

#ifndef ISIAKA_EXECUTION_MQH
#define ISIAKA_EXECUTION_MQH

#include <Isiaka/Defs.mqh>

class CExecution
{
private:
   string          m_symbol;
   STradeSettings  m_cfg;
   int             m_digits;
   double          m_point;

   double          Bid() { return MarketInfo(m_symbol, MODE_BID); }
   double          Ask() { return MarketInfo(m_symbol, MODE_ASK); }

   //--- Minimum distance the broker allows between price and SL/TP.
   double          StopsLevelPts()  { return MarketInfo(m_symbol, MODE_STOPLEVEL);  }
   //--- Distance inside which an order cannot be modified or closed at all.
   double          FreezeLevelPts() { return MarketInfo(m_symbol, MODE_FREEZELEVEL); }

   //--- Errors worth resending on. Anything else is a real rejection and
   //--- retrying it just repeats the same mistake against the server.
   bool            IsRetryable(const int err)
   {
      switch(err)
      {
         case ERR_SERVER_BUSY:
         case ERR_NO_CONNECTION:
         case ERR_TRADE_TIMEOUT:
         case ERR_PRICE_CHANGED:
         case ERR_OFF_QUOTES:
         case ERR_BROKER_BUSY:
         case ERR_REQUOTE:
         case ERR_TRADE_CONTEXT_BUSY:
            return true;
      }
      return false;
   }

   void            Backoff(const int attempt)
   {
      //--- Give the terminal time to free the trade context and refresh quotes.
      Sleep(200 * (attempt + 1));
      RefreshRates();
   }

public:
   bool Init(const string symbol, const STradeSettings &cfg)
   {
      m_symbol = symbol;
      m_cfg    = cfg;
      m_digits = (int)MarketInfo(m_symbol, MODE_DIGITS);
      m_point  = MarketInfo(m_symbol, MODE_POINT);

      if(m_point <= 0.0)
      {
         PrintFormat("CExecution: bad point size for %s", m_symbol);
         return false;
      }
      return true;
   }

   double CurrentSpreadPts()
   {
      return (Ask() - Bid()) / m_point;
   }

   bool SpreadAcceptable()
   {
      if(m_cfg.max_spread_points <= 0)
         return true;
      return (CurrentSpreadPts() <= (double)m_cfg.max_spread_points);
   }

   //--- Orders currently open on this symbol under our magic number.
   int CountPositions()
   {
      int count = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;
         if(OrderSymbol() != m_symbol)
            continue;
         if(OrderMagicNumber() != m_cfg.magic)
            continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL)
            continue;
         count++;
      }
      return count;
   }

   bool CanOpenNew()
   {
      if(!IsTradeAllowed())
         return false;
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
      if(dir != SIGNAL_BUY && dir != SIGNAL_SELL)
         return false;

      double min_dist = MathMax(StopsLevelPts(), 0.0);
      if(stop_points > 0.0 && stop_points < min_dist)
      {
         PrintFormat("CExecution: stop %.0f pts is inside the broker minimum of %.0f pts",
                     stop_points, min_dist);
         return false;
      }

      int cmd = (dir == SIGNAL_BUY) ? OP_BUY : OP_SELL;

      for(int attempt = 0; attempt <= m_cfg.max_retries; attempt++)
      {
         if(IsTradeContextBusy())
         {
            Backoff(attempt);
            continue;
         }

         RefreshRates();

         double price = (cmd == OP_BUY) ? Ask() : Bid();
         double sl = 0.0, tp = 0.0;

         if(stop_points > 0.0)
            sl = NormalizeDouble((cmd == OP_BUY) ? price - stop_points * m_point
                                                 : price + stop_points * m_point, m_digits);
         if(target_points > 0.0)
            tp = NormalizeDouble((cmd == OP_BUY) ? price + target_points * m_point
                                                 : price - target_points * m_point, m_digits);

         price = NormalizeDouble(price, m_digits);

         int ticket = OrderSend(m_symbol, cmd, lots, price, m_cfg.slippage_points,
                                sl, tp, comment, m_cfg.magic, 0, clrNONE);

         if(ticket >= 0)
            return true;

         int err = GetLastError();

         //--- Many ECN/STP servers reject stops attached to a market order.
         //--- Send the position naked, then attach the stops immediately.
         if(err == ERR_INVALID_STOPS && (sl != 0.0 || tp != 0.0))
         {
            ticket = OrderSend(m_symbol, cmd, lots, price, m_cfg.slippage_points,
                               0, 0, comment, m_cfg.magic, 0, clrNONE);
            if(ticket >= 0)
            {
               if(!AttachStops(ticket, sl, tp))
                  PrintFormat("CExecution: order %d opened but stops could not be attached "
                              "-- position is unprotected", ticket);
               return true;
            }
            err = GetLastError();
         }

         if(!IsRetryable(err))
         {
            PrintFormat("CExecution: OrderSend failed, error %d (not retryable)", err);
            return false;
         }

         PrintFormat("CExecution: OrderSend error %d, retry %d/%d",
                     err, attempt + 1, m_cfg.max_retries);
         Backoff(attempt);
      }

      Print("CExecution: OrderSend gave up after retries");
      return false;
   }

   //--- Used by the ECN fallback path above.
   bool AttachStops(const int ticket, const double sl, const double tp)
   {
      for(int attempt = 0; attempt <= m_cfg.max_retries; attempt++)
      {
         if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES))
            return false;

         if(OrderModify(ticket, OrderOpenPrice(), sl, tp, 0, clrNONE))
            return true;

         int err = GetLastError();
         if(!IsRetryable(err))
         {
            PrintFormat("CExecution: OrderModify(%d) failed, error %d", ticket, err);
            return false;
         }
         Backoff(attempt);
      }
      return false;
   }

   //--- Is there an open order of this type (OP_BUY / OP_SELL) under our magic?
   bool HasPosition(const int type_filter)
   {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;
         if(OrderSymbol() != m_symbol)
            continue;
         if(OrderMagicNumber() != m_cfg.magic)
            continue;
         if(OrderType() == type_filter)
            return true;
      }
      return false;
   }

   //--- Close our open orders. Pass OP_BUY or OP_SELL to close one side only,
   //--- or leave the default to close both.
   void CloseAll(const int type_filter = -1)
   {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;
         if(OrderSymbol() != m_symbol)
            continue;
         if(OrderMagicNumber() != m_cfg.magic)
            continue;

         int type = OrderType();
         if(type != OP_BUY && type != OP_SELL)
            continue;
         if(type_filter >= 0 && type != type_filter)
            continue;

         RefreshRates();
         double price = (type == OP_BUY) ? Bid() : Ask();

         if(!OrderClose(OrderTicket(), OrderLots(), NormalizeDouble(price, m_digits),
                        m_cfg.slippage_points, clrNONE))
            PrintFormat("CExecution: OrderClose(%d) failed, error %d",
                        OrderTicket(), GetLastError());
      }
   }

   //--- Breakeven and trailing. Called every tick; only sends a modify when
   //--- the new stop is a genuine improvement, so the server is not spammed.
   void ManageOpenPositions()
   {
      if(!m_cfg.use_breakeven && !m_cfg.use_trailing)
         return;

      double min_dist    = MathMax(StopsLevelPts(), 0.0);
      double freeze_dist = MathMax(FreezeLevelPts(), 0.0);

      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;
         if(OrderSymbol() != m_symbol)
            continue;
         if(OrderMagicNumber() != m_cfg.magic)
            continue;

         int type = OrderType();
         if(type != OP_BUY && type != OP_SELL)
            continue;

         bool   is_buy     = (type == OP_BUY);
         double open_price = OrderOpenPrice();
         double cur_sl     = OrderStopLoss();
         double cur_tp     = OrderTakeProfit();

         RefreshRates();
         double market     = is_buy ? Bid() : Ask();
         double profit_pts = (is_buy ? (market - open_price) : (open_price - market)) / m_point;

         double new_sl = cur_sl;

         if(m_cfg.use_breakeven && profit_pts >= m_cfg.breakeven_trigger_pts)
         {
            double be = is_buy ? open_price + m_cfg.breakeven_offset_pts * m_point
                               : open_price - m_cfg.breakeven_offset_pts * m_point;

            if(is_buy ? (be > new_sl) : (be < new_sl || new_sl == 0.0))
               new_sl = be;
         }

         if(m_cfg.use_trailing && profit_pts >= m_cfg.trailing_start_pts)
         {
            double trail = is_buy ? market - m_cfg.trailing_distance_pts * m_point
                                  : market + m_cfg.trailing_distance_pts * m_point;

            if(is_buy ? (trail > new_sl) : (trail < new_sl || new_sl == 0.0))
               new_sl = trail;
         }

         if(new_sl == cur_sl)
            continue;

         //--- Only move if the improvement clears the configured step.
         double improvement = MathAbs(new_sl - cur_sl) / m_point;
         if(cur_sl != 0.0 && improvement < m_cfg.trailing_step_pts)
            continue;

         //--- Respect both the stops level and the freeze level.
         double distance_pts = MathAbs(market - new_sl) / m_point;
         if(distance_pts < min_dist || distance_pts < freeze_dist)
            continue;

         new_sl = NormalizeDouble(new_sl, m_digits);

         if(!OrderModify(OrderTicket(), open_price, new_sl, cur_tp, 0, clrNONE))
         {
            int err = GetLastError();
            //--- ERR_NO_RESULT just means the values were already in place.
            if(err != ERR_NO_RESULT)
               PrintFormat("CExecution: OrderModify(%d) failed, error %d",
                           OrderTicket(), err);
         }
      }
   }
};

#endif // ISIAKA_EXECUTION_MQH
