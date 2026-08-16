//+------------------------------------------------------------------+
//|                                                         Risk.mqh |
//|          Position sizing. Everything here is in symbol points so |
//|          the same code works on FX, indices, metals and crypto.  |
//+------------------------------------------------------------------+
#ifndef ISIAKA_RISK_MQH
#define ISIAKA_RISK_MQH

#include <Isiaka/Defs.mqh>

class CRisk
{
private:
   string         m_symbol;
   SRiskSettings  m_cfg;

   //--- Money gained/lost per point of price movement, per 1.0 lot.
   double         ValuePerPoint() const
   {
      double tick_value = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      double tick_size  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      double point      = SymbolInfoDouble(m_symbol, SYMBOL_POINT);

      if(tick_value <= 0.0 || tick_size <= 0.0 || point <= 0.0)
         return 0.0;

      return tick_value * (point / tick_size);
   }

public:
   bool Init(const string symbol, const SRiskSettings &cfg)
   {
      m_symbol = symbol;
      m_cfg    = cfg;

      if(ValuePerPoint() <= 0.0)
      {
         PrintFormat("CRisk: cannot resolve tick value/size for %s", m_symbol);
         return false;
      }
      return true;
   }

   //--- Clamp a raw volume to the broker's min/max/step grid.
   double Normalize(const double raw) const
   {
      double min_lot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double max_lot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      double step    = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);

      if(step <= 0.0)
         step = min_lot > 0.0 ? min_lot : 0.01;

      double lots = MathFloor(raw / step) * step;

      if(m_cfg.max_lot > 0.0)
         lots = MathMin(lots, m_cfg.max_lot);

      lots = MathMin(lots, max_lot);

      //--- Below the broker minimum there is no tradeable size: report 0
      //--- rather than silently rounding a rejected risk level up.
      if(lots < min_lot)
         return 0.0;

      int step_digits = (int)MathMax(0, MathRound(-MathLog10(step)));
      return NormalizeDouble(lots, step_digits);
   }

   //--- Volume such that `stop_points` against us costs risk_percent of balance.
   double CalculateLots(const double stop_points) const
   {
      if(m_cfg.lot_mode == LOT_FIXED)
         return Normalize(m_cfg.fixed_lot);

      if(stop_points <= 0.0)
      {
         Print("CRisk: risk-based sizing needs a non-zero stop distance");
         return 0.0;
      }

      double vpp = ValuePerPoint();
      if(vpp <= 0.0)
         return 0.0;

      double risk_money = AccountInfoDouble(ACCOUNT_BALANCE) * m_cfg.risk_percent / 100.0;
      double raw_lots   = risk_money / (stop_points * vpp);

      return Normalize(raw_lots);
   }
};

#endif // ISIAKA_RISK_MQH
