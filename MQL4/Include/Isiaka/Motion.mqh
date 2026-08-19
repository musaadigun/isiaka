//+------------------------------------------------------------------+
//|                                                       Motion.mqh |
//|                                                                  |
//|  Live intrabar speed measurement on a finer clock.                |
//|                                                                  |
//|  WHY THIS EXISTS                                                  |
//|  The EA's PriceAccelerationPerHour2() cannot see a spike. Expand   |
//|  it and the 3-bar velocity telescopes away:                       |
//|                                                                   |
//|      A = [ (c1-c2) - (c4-c5) ] / 0.75                             |
//|                                                                   |
//|  Inside a forming bar c1, c4 and c5 are already closed, so only    |
//|  c0 moves and A(0) = 1.3333*c0 + constant -- the live price,       |
//|  rescaled. Measured over 11,034 M30 bars the slope was exactly     |
//|  1.3333 every time (sd 3.7e-13).                                  |
//|                                                                   |
//|  Because the divisor is a fixed 1.5h window, a $10 move in two     |
//|  minutes and a $10 drift over ninety read identically. On bars of  |
//|  comparable size, slow drifts and fast spikes gave median |A| of   |
//|  15.20 and 15.40 - a ratio of 1.01x. Bar range over ATR is no      |
//|  better at 1.03x, because neither knows the PATH price took.      |
//|                                                                   |
//|  Sub-bar sampling does know. The same test gives 1.90x for the     |
//|  peak M1 step and 1.86x for the velocity ratio below.             |
//|                                                                   |
//|  NOTE ON THE ECHO                                                  |
//|  Any (Vnow - Vprev) construction replays a move with the opposite  |
//|  sign one lookback later - the EA's version does it at lag 3 with  |
//|  autocorrelation -0.503. IntrabarAcceleration() has the same       |
//|  property, but at a lookback of minutes rather than 90 of them.    |
//|  Shorter memory, same mechanism. Do not treat it as fixed.        |
//+------------------------------------------------------------------+
#property strict

#ifndef ISIAKA_MOTION_MQH
#define ISIAKA_MOTION_MQH

//+------------------------------------------------------------------+
//| Fastest single closed M1 minute inside the forming bar, in $/hour.|
//| Uses closed M1 bars only, so it never repaints. Returns 0 until    |
//| at least two M1 bars have completed inside the current bar.        |
//+------------------------------------------------------------------+
double IntrabarPeakVelocity(const ENUM_TIMEFRAMES signalTf)
  {
   datetime barStart=iTime(Symbol(),signalTf,0);
   if(barStart<=0)
      return(0.0);

   int elapsedMinutes=(int)((TimeCurrent()-barStart)/60);
   if(elapsedMinutes<2)
      return(0.0);

   int samples=(int)MathMin(elapsedMinutes,(int)(PeriodSeconds(signalTf)/60));
   double peak=0.0;
   for(int k=1; k<samples; k++)
     {
      double now =iClose(Symbol(),PERIOD_M1,k);
      double prev=iClose(Symbol(),PERIOD_M1,k+1);
      if(now<=0.0 || prev<=0.0)
         continue;
      double step=MathAbs(now-prev);
      if(step>peak)
         peak=step;
     }
   return(peak*60.0);            // $ per minute -> $ per hour
  }

//+------------------------------------------------------------------+
//| Peak intrabar velocity against the pace of an ordinary bar.       |
//|                                                                  |
//| A whole average bar covers one ATR in barHours, so ATR/barHours   |
//| is "normal" speed. A return of 3.0 means the fastest minute so    |
//| far is travelling three times faster than a typical whole bar.    |
//| Self-normalising: no threshold needs re-tuning when volatility    |
//| doubles, which is what happened to gold across 2024-2026.         |
//+------------------------------------------------------------------+
double IntrabarSpikeRatio(const ENUM_TIMEFRAMES signalTf,const int atrPeriod)
  {
   double atr=iATR(Symbol(),signalTf,atrPeriod,1);
   double barHours=PeriodSeconds(signalTf)/3600.0;
   if(atr<=0.0 || barHours<=0.0)
      return(0.0);

   double typicalVelocity=atr/barHours;
   if(typicalVelocity<=0.0)
      return(0.0);

   return(IntrabarPeakVelocity(signalTf)/typicalVelocity);
  }

//+------------------------------------------------------------------+
//| Signed velocity over the last `minutes`, in $/hour, from closed   |
//| M1 bars. shiftMinutes offsets the window further back.            |
//+------------------------------------------------------------------+
double IntrabarVelocity(const int minutes,const int shiftMinutes=0)
  {
   if(minutes<1)
      return(0.0);
   double now =iClose(Symbol(),PERIOD_M1,1+shiftMinutes);
   double past=iClose(Symbol(),PERIOD_M1,1+shiftMinutes+minutes);
   if(now<=0.0 || past<=0.0)
      return(0.0);
   return((now-past)/(minutes/60.0));
  }

//+------------------------------------------------------------------+
//| Genuine intrabar acceleration on the M1 clock, in $/hour^2.       |
//|                                                                  |
//| Same shape as the EA's formula but with the window set in         |
//| minutes, so it measures the rate of a move rather than its size.  |
//| Closed M1 bars only -- no repainting.                             |
//+------------------------------------------------------------------+
double IntrabarAcceleration(const int minutes)
  {
   if(minutes<1)
      return(0.0);
   double vNow =IntrabarVelocity(minutes,0);
   double vPrev=IntrabarVelocity(minutes,minutes);
   if(vNow==0.0 && vPrev==0.0)
      return(0.0);
   return((vNow-vPrev)/(minutes/60.0));
  }

//+------------------------------------------------------------------+
//| SELF-CONTAINED velocity of the running candle, in $/hour.        |
//|                                                                  |
//|     V0 = (price_now - open[0]) / hours_elapsed_in_this_bar        |
//|                                                                  |
//| Uses only this candle's own open and the live price. No close[3], |
//| no prior bar, nothing that survives the bar boundary. That is the |
//| difference from the EA's PriceVelocityPerHour(), which spans 90   |
//| minutes and whose current-candle content is only 37.3% of its     |
//| variance.                                                         |
//|                                                                   |
//| THE DIVISOR IS THE HAZARD. Early in the bar hours_elapsed is tiny |
//| and an ordinary tick becomes an enormous reading. Measured over   |
//| 11,038 M30 candles, median |V0| against its settled value:        |
//|                                                                   |
//|      5 min in : 2.76x   corr 0.479   sign right 65.1%             |
//|     10 min in : 1.87x   corr 0.632   sign right 71.9%             |
//|     15 min in : 1.50x   corr 0.756   sign right 77.2%             |
//|     20 min in : 1.25x   corr 0.861   sign right 82.0%             |
//|     25 min in : 1.11x   corr 0.932   sign right 87.8%             |
//|                                                                   |
//| minimumSeconds rejects readings before that much of the bar has   |
//| elapsed. 0 disables the guard and returns whatever the divisor    |
//| produces - only sensible if the caller does its own gating.       |
//| A third of the bar (600s on M30) is the point where the reading   |
//| stops being dominated by its own denominator.                     |
//+------------------------------------------------------------------+
double CandleVelocityNow(const ENUM_TIMEFRAMES signalTf,
                         const int minimumSeconds=600)
  {
   datetime barStart=iTime(Symbol(),signalTf,0);
   if(barStart<=0)
      return(0.0);

   int elapsedSeconds=(int)(TimeCurrent()-barStart);
   if(elapsedSeconds<=0 || elapsedSeconds<minimumSeconds)
      return(0.0);

   double barOpen=iOpen(Symbol(),signalTf,0);
   double price  =iClose(Symbol(),signalTf,0);   // live price of the forming bar
   if(barOpen<=0.0 || price<=0.0)
      return(0.0);

   return((price-barOpen)/(elapsedSeconds/3600.0));
  }

//+------------------------------------------------------------------+
//| The same reading against what an ordinary bar manages, so the     |
//| threshold does not need re-tuning when volatility changes. Gold's |
//| median M30 ATR went from $4.40 to $13.87 across 2024-2026, so a   |
//| fixed $/hour cutoff would have drifted badly over that period.    |
//| Returns 1.0 when this candle is pacing exactly like a normal one. |
//+------------------------------------------------------------------+
double CandleVelocityRatio(const ENUM_TIMEFRAMES signalTf,const int atrPeriod,
                           const int minimumSeconds=600)
  {
   double atr=iATR(Symbol(),signalTf,atrPeriod,1);
   double barHours=PeriodSeconds(signalTf)/3600.0;
   if(atr<=0.0 || barHours<=0.0)
      return(0.0);
   return(CandleVelocityNow(signalTf,minimumSeconds)/(atr/barHours));
  }

//+------------------------------------------------------------------+
//| How far into the forming bar are we, 0.0 .. 1.0?                  |
//| Study 12: the live reading correlates 0.801 with its settled      |
//| value at 5 minutes into an M30 bar and 0.938 at the halfway mark, |
//| so gating on bar age is cheap protection against early noise.     |
//+------------------------------------------------------------------+
double BarProgress(const ENUM_TIMEFRAMES signalTf)
  {
   datetime barStart=iTime(Symbol(),signalTf,0);
   int span=PeriodSeconds(signalTf);
   if(barStart<=0 || span<=0)
      return(0.0);
   double p=(double)(TimeCurrent()-barStart)/(double)span;
   return(MathMax(0.0,MathMin(1.0,p)));
  }

#endif // ISIAKA_MOTION_MQH
