//+------------------------------------------------------------------+
//| XVISION_Gold_Velocity_AI_EA_V7.mq4                            |
//| Adaptive strict-continuation and early-initiation Gold engine. |
//+------------------------------------------------------------------+
#property strict
#property version   "7.00"
#property description "XVISION Gold Velocity AI EA V7 - adaptive strict and early velocity engines"

#ifndef __XVISION_GOLD_VELOCITY_CORE_V7_MQH__
#define __XVISION_GOLD_VELOCITY_CORE_V7_MQH__

// H1 is the highest timeframe. No higher-timeframe data is requested.
// Every decision uses closed M1, M5 and H1 bars only.

#define GV_REQUIRED_M1_BARS  80
#define GV_REQUIRED_M5_BARS  80
#define GV_REQUIRED_H1_BARS  40
#define GV_MAX_M5_CONTEXT_AGE_SECONDS  (15*60)
#define GV_MAX_H1_CONTEXT_AGE_SECONDS  (12*60*60)

#define GV_STATE_NO_TRADE       0
#define GV_STATE_BUILDING       1
#define GV_STATE_GOOD           2
#define GV_STATE_ACCELERATING   3
#define GV_STATE_OVEREXTENDED   4
#define GV_STATE_EXHAUSTING     5
#define GV_STATE_REVERSING      6
#define GV_STATE_DATA_WAIT      7
#define GV_STATE_H1_CONFLICT    8
#define GV_STATE_M5_SETUP_WAIT  9
#define GV_STATE_M1_TRIGGER_WAIT 10

#define GV_ENTRY_MODE_NONE    0
#define GV_ENTRY_MODE_EARLY   1
#define GV_ENTRY_MODE_STRICT  2

struct GVThresholds
{
   double minimumM5Efficiency;
   double minimumM5Strength;
   double maximumM5Strength;
   double minimumM5Coherence;
   double maximumM5Shock;
   double maximumM5PullbackATR;
   double minimumH1GapATR;
   double minimumH1SlopeATR;
   double minimumH1Efficiency;
   int    minimumH1AlignedBodies;
   double maximumH1Shock;
   double minimumM1Strength;
   double minimumM1Acceleration;
   double minimumM1Coherence;
   double maximumM1Shock;
   double maximumM1ChaseM5ATR;
   bool   requireM1Pattern;
   double earlyH1GapTolerance;
   double earlyH1SlopeTolerance;
   double earlyH1VelocityTolerance;
   double minimumEarlyM5Efficiency;
   double minimumEarlyM5Strength;
   double minimumEarlyM5Coherence;
   double minimumEarlyM5Acceleration;
   double minimumEarlyM5Release;
   double minimumEarlyM1Strength;
   double minimumEarlyM1Acceleration;
   double minimumEarlyM1Release;
   double maximumEarlyMaturityM5ATR;
};

struct GVResult
{
   bool     valid;
   bool     qualified;
   int      direction;
   int      state;
   int      entryMode;
   bool     strictQualified;
   bool     earlyQualified;
   datetime signalTime;
   datetime m5SetupTime;
   datetime h1RegimeTime;
   double   referenceEntry;
   double   confidence;
   double   atrM5;
   double   velocityM5;
   double   velocityM1;
   double   velocityH1;
   double   h1Alignment;
   double   h1Slope;
   double   h1Efficiency;
   double   h1Persistence;
   double   pathQuality;
   double   acceleration;
   double   velocityStrength;
   double   shockRatio;
   double   m5Coherence;
   double   m1Coherence;
   double   m1ChaseM5ATR;
   double   m5Acceleration;
   double   m5Release;
   double   m1Release;
   double   maturityM5ATR;
   bool     m1PullbackSeen;
   bool     m1BreakoutSeen;
   string   triggerPattern;
   string   reason;
};

void GVDefaultThresholds(GVThresholds &thresholds)
{
   thresholds.minimumM5Efficiency   = 0.15;
   thresholds.minimumM5Strength     = 0.10;
   thresholds.maximumM5Strength     = 2.50;
   thresholds.minimumM5Coherence    = 0.667;
   thresholds.maximumM5Shock        = 2.50;
   thresholds.maximumM5PullbackATR  = 1.50;
   thresholds.minimumH1GapATR       = 0.00;
   thresholds.minimumH1SlopeATR     = 0.00;
   thresholds.minimumH1Efficiency   = 0.10;
   thresholds.minimumH1AlignedBodies= 3;
   thresholds.maximumH1Shock        = 2.50;
   thresholds.minimumM1Strength     = 0.05;
   thresholds.minimumM1Acceleration = 0.00;
   thresholds.minimumM1Coherence    = 0.75;
   thresholds.maximumM1Shock        = 2.50;
   thresholds.maximumM1ChaseM5ATR   = 1.00;
   thresholds.requireM1Pattern      = true;
   thresholds.earlyH1GapTolerance        = 0.50;
   thresholds.earlyH1SlopeTolerance      = 0.15;
   thresholds.earlyH1VelocityTolerance   = 0.50;
   thresholds.minimumEarlyM5Efficiency   = 0.10;
   thresholds.minimumEarlyM5Strength     = 0.05;
   thresholds.minimumEarlyM5Coherence    = 0.667;
   thresholds.minimumEarlyM5Acceleration = 0.05;
   thresholds.minimumEarlyM5Release      = 0.70;
   thresholds.minimumEarlyM1Strength     = 0.05;
   thresholds.minimumEarlyM1Acceleration = 0.05;
   thresholds.minimumEarlyM1Release      = 0.60;
   thresholds.maximumEarlyMaturityM5ATR  = 1.25;
}

double GVClamp(const double value,const double lower,const double upper)
{
   return(MathMax(lower,MathMin(upper,value)));
}

bool GVIsGoldSymbol(string symbol)
{
   StringToUpper(symbol);
   return(StringFind(symbol,"XAU")>=0 || StringFind(symbol,"GOLD")>=0);
}

string GVDirectionText(const int direction)
{
   if(direction>0) return("BUY");
   if(direction<0) return("SELL");
   return("NONE");
}

string GVEntryModeText(const int mode)
{
   if(mode==GV_ENTRY_MODE_EARLY) return("EARLY");
   if(mode==GV_ENTRY_MODE_STRICT) return("STRICT");
   return("NONE");
}

string GVStateText(const int state)
{
   if(state==GV_STATE_BUILDING)        return("BUILDING");
   if(state==GV_STATE_GOOD)            return("QUALIFIED");
   if(state==GV_STATE_ACCELERATING)    return("M1 ACCELERATING");
   if(state==GV_STATE_OVEREXTENDED)    return("OVEREXTENDED");
   if(state==GV_STATE_EXHAUSTING)      return("SHOCK / EXHAUSTION");
   if(state==GV_STATE_REVERSING)       return("M1 REVERSING");
   if(state==GV_STATE_DATA_WAIT)       return("WAITING FOR DATA");
   if(state==GV_STATE_H1_CONFLICT)     return("H1 CONFLICT");
   if(state==GV_STATE_M5_SETUP_WAIT)   return("M5 SETUP WAIT");
   if(state==GV_STATE_M1_TRIGGER_WAIT) return("M1 TRIGGER WAIT");
   return("NO TRADE");
}

void GVResetResult(GVResult &result)
{
   result.valid=false;
   result.qualified=false;
   result.direction=0;
   result.state=GV_STATE_DATA_WAIT;
   result.entryMode=GV_ENTRY_MODE_NONE;
   result.strictQualified=false;
   result.earlyQualified=false;
   result.signalTime=0;
   result.m5SetupTime=0;
   result.h1RegimeTime=0;
   result.referenceEntry=0.0;
   result.confidence=0.0;
   result.atrM5=0.0;
   result.velocityM5=0.0;
   result.velocityM1=0.0;
   result.velocityH1=0.0;
   result.h1Alignment=0.0;
   result.h1Slope=0.0;
   result.h1Efficiency=0.0;
   result.h1Persistence=0.0;
   result.pathQuality=0.0;
   result.acceleration=0.0;
   result.velocityStrength=0.0;
   result.shockRatio=0.0;
   result.m5Coherence=0.0;
   result.m1Coherence=0.0;
   result.m1ChaseM5ATR=0.0;
   result.m5Acceleration=0.0;
   result.m5Release=0.0;
   result.m1Release=0.0;
   result.maturityM5ATR=0.0;
   result.m1PullbackSeen=false;
   result.m1BreakoutSeen=false;
   result.triggerPattern="NONE";
   result.reason="INSUFFICIENT OR STALE CLOSED M1/M5/H1 DATA";
}

double GVTrueRange(const string symbol,const int timeframe,const int shift)
{
   double high=iHigh(symbol,timeframe,shift);
   double low=iLow(symbol,timeframe,shift);
   double previous=iClose(symbol,timeframe,shift+1);
   if(high<=0.0 || low<=0.0 || previous<=0.0) return(0.0);
   return(MathMax(high-low,MathMax(MathAbs(high-previous),MathAbs(low-previous))));
}

double GVATR(const string symbol,const int timeframe,const int period,const int shift)
{
   double sum=0.0;
   for(int i=0;i<period;i++)
   {
      double value=GVTrueRange(symbol,timeframe,shift+i);
      if(value<=0.0) return(0.0);
      sum+=value;
   }
   return(sum/period);
}

double GVNet(const string symbol,const int timeframe,const int window,const int shift)
{
   return(iClose(symbol,timeframe,shift)-iOpen(symbol,timeframe,shift+window-1));
}

double GVM5CompositeAtShift(const string symbol,const int shift)
{
   double atr=GVATR(symbol,PERIOD_M5,12,shift);
   if(atr<=0.0) return(0.0);
   int windows[6]={1,3,6,12,24,48};
   double weights[6]={0.25,0.25,0.20,0.15,0.10,0.05};
   double composite=0.0;
   for(int index=0;index<6;index++)
      composite+=weights[index]*GVNet(symbol,PERIOD_M5,windows[index],shift)/
         (atr*MathSqrt(windows[index]));
   return(composite);
}

int GVLastFullyClosedShift(const string symbol,const int timeframe,const datetime decisionTime,
                           const int requiredOlderBars,const int maximumAgeSeconds)
{
   int containing=iBarShift(symbol,timeframe,decisionTime,false);
   if(containing<0) return(-1);
   int closedShift=containing+1;
   if(closedShift+requiredOlderBars>=iBars(symbol,timeframe)) return(-1);
   datetime barOpen=iTime(symbol,timeframe,closedShift);
   if(barOpen<=0) return(-1);
   datetime barClose=barOpen+timeframe*60;
   if(barClose>decisionTime) return(-1);
   if(maximumAgeSeconds>0 && decisionTime-barClose>maximumAgeSeconds) return(-1);
   return(closedShift);
}

bool GVCalculate(const string symbol,const int m1Shift,GVThresholds &thresholds,GVResult &result)
{
   GVResetResult(result);
   if(m1Shift<1 || iBars(symbol,PERIOD_M1)<m1Shift+GV_REQUIRED_M1_BARS ||
      iBars(symbol,PERIOD_M5)<GV_REQUIRED_M5_BARS || iBars(symbol,PERIOD_H1)<GV_REQUIRED_H1_BARS)
      return(false);

   datetime signalOpen=iTime(symbol,PERIOD_M1,m1Shift);
   if(signalOpen<=0) return(false);
   datetime decisionTime=signalOpen+60;
   int closedM5=GVLastFullyClosedShift(symbol,PERIOD_M5,decisionTime,
      GV_REQUIRED_M5_BARS-1,GV_MAX_M5_CONTEXT_AGE_SECONDS);
   int closedH1=GVLastFullyClosedShift(symbol,PERIOD_H1,decisionTime,
      GV_REQUIRED_H1_BARS-1,GV_MAX_H1_CONTEXT_AGE_SECONDS);
   if(closedM5<1 || closedH1<1) return(false);

   double atrM5=GVATR(symbol,PERIOD_M5,12,closedM5);
   double atrH1=GVATR(symbol,PERIOD_H1,14,closedH1);
   double atrM1=GVATR(symbol,PERIOD_M1,14,m1Shift);
   if(atrM5<=0.0 || atrH1<=0.0 || atrM1<=0.0) return(false);

   int m5Windows[6]={1,3,6,12,24,48};
   double m5Velocity[6];
   ArrayInitialize(m5Velocity,0.0);
   for(int w=0;w<6;w++)
      m5Velocity[w]=GVNet(symbol,PERIOD_M5,m5Windows[w],closedM5)/(atrM5*MathSqrt(m5Windows[w]));
   double m5Composite=0.25*m5Velocity[0]+0.25*m5Velocity[1]+0.20*m5Velocity[2]+
                      0.15*m5Velocity[3]+0.10*m5Velocity[4]+0.05*m5Velocity[5];
   int direction=(m5Composite>=0.0 ? 1 : -1);
   double m5Strength=MathAbs(m5Composite);
   double priorM5Composite=GVM5CompositeAtShift(symbol,closedM5+1);
   double m5Acceleration=direction*(m5Composite-priorM5Composite);
   double priorM5Range6=GVATR(symbol,PERIOD_M5,6,closedM5+1);
   if(priorM5Range6<=0.0) return(false);
   double m5Release=GVTrueRange(symbol,PERIOD_M5,closedM5)/priorM5Range6;

   double range12=0.0;
   double high12=-DBL_MAX,low12=DBL_MAX;
   for(int b=0;b<12;b++)
   {
      range12+=GVTrueRange(symbol,PERIOD_M5,closedM5+b);
      high12=MathMax(high12,iHigh(symbol,PERIOD_M5,closedM5+b));
      low12=MathMin(low12,iLow(symbol,PERIOD_M5,closedM5+b));
   }
   double m5Efficiency=MathAbs(GVNet(symbol,PERIOD_M5,12,closedM5))/MathMax(range12,0.01);
   double m5Shock=GVTrueRange(symbol,PERIOD_M5,closedM5)/atrM5;
   int alignedM5=0;
   for(int mv=0;mv<6;mv++) if(direction*m5Velocity[mv]>0.0) alignedM5++;
   double m5Coherence=alignedM5/6.0;
   double m5Close=iClose(symbol,PERIOD_M5,closedM5);
   double m5Pullback=(direction>0 ? (m5Close-high12)/atrM5 : (low12-m5Close)/atrM5);
   bool m5Setup=(m5Efficiency>=thresholds.minimumM5Efficiency &&
                 m5Strength>=thresholds.minimumM5Strength &&
                 m5Strength<=thresholds.maximumM5Strength &&
                 m5Coherence>=thresholds.minimumM5Coherence &&
                 m5Shock<=thresholds.maximumM5Shock &&
                 m5Pullback>=-thresholds.maximumM5PullbackATR);

   double h1Ema8=iMA(symbol,PERIOD_H1,8,0,MODE_EMA,PRICE_CLOSE,closedH1);
   double h1Ema8Prior=iMA(symbol,PERIOD_H1,8,0,MODE_EMA,PRICE_CLOSE,closedH1+1);
   double h1Ema21=iMA(symbol,PERIOD_H1,21,0,MODE_EMA,PRICE_CLOSE,closedH1);
   double h1Gap=direction*(h1Ema8-h1Ema21)/atrH1;
   double h1Slope=direction*(h1Ema8-h1Ema8Prior)/atrH1;
   double h1Velocity1=direction*GVNet(symbol,PERIOD_H1,1,closedH1)/atrH1;
   double h1Velocity2=direction*GVNet(symbol,PERIOD_H1,2,closedH1)/(atrH1*MathSqrt(2.0));
   double h1Velocity4=direction*GVNet(symbol,PERIOD_H1,4,closedH1)/(atrH1*2.0);
   double h1Range4=0.0;
   int h1AlignedBodies=0;
   for(int h=0;h<4;h++)
   {
      h1Range4+=GVTrueRange(symbol,PERIOD_H1,closedH1+h);
      double body=iClose(symbol,PERIOD_H1,closedH1+h)-iOpen(symbol,PERIOD_H1,closedH1+h);
      if(direction*body>0.0) h1AlignedBodies++;
   }
   double h1Efficiency=MathAbs(GVNet(symbol,PERIOD_H1,4,closedH1))/MathMax(h1Range4,0.01);
   double h1Persistence=h1AlignedBodies/4.0;
   double h1Shock=GVTrueRange(symbol,PERIOD_H1,closedH1)/atrH1;
   bool h1Gate=(h1Gap>thresholds.minimumH1GapATR && h1Slope>thresholds.minimumH1SlopeATR &&
                h1Velocity1>0.0 && h1Velocity2>0.0 && h1Velocity4>0.0 &&
                h1AlignedBodies>=thresholds.minimumH1AlignedBodies &&
                h1Efficiency>=thresholds.minimumH1Efficiency && h1Shock<=thresholds.maximumH1Shock);
   bool earlyH1Veto=(h1Gap>-thresholds.earlyH1GapTolerance &&
                     h1Slope>-thresholds.earlyH1SlopeTolerance &&
                     h1Velocity4>-thresholds.earlyH1VelocityTolerance &&
                     h1Shock<=thresholds.maximumH1Shock);

   int m1Windows[4]={1,3,5,15};
   double m1Velocity[4];
   ArrayInitialize(m1Velocity,0.0);
   for(int m=0;m<4;m++)
      m1Velocity[m]=GVNet(symbol,PERIOD_M1,m1Windows[m],m1Shift)/(atrM1*MathSqrt(m1Windows[m]));
   double m1Composite=0.35*m1Velocity[0]+0.30*m1Velocity[1]+0.20*m1Velocity[2]+0.15*m1Velocity[3];
   double m1Strength=direction*m1Composite;
   int alignedM1=0;
   for(int av=0;av<4;av++) if(direction*m1Velocity[av]>0.0) alignedM1++;
   double m1Coherence=alignedM1/4.0;
   double recentM1=GVNet(symbol,PERIOD_M1,3,m1Shift)/3.0;
   double priorM1=(iClose(symbol,PERIOD_M1,m1Shift+3)-iOpen(symbol,PERIOD_M1,m1Shift+14))/12.0;
   double m1Acceleration=direction*(recentM1-priorM1)/atrM1;
   double m1Shock=GVTrueRange(symbol,PERIOD_M1,m1Shift)/atrM1;
   double priorM1Range5=GVATR(symbol,PERIOD_M1,5,m1Shift+1);
   if(priorM1Range5<=0.0) return(false);
   double m1Release=GVTrueRange(symbol,PERIOD_M1,m1Shift)/priorM1Range5;
   double m1Close=iClose(symbol,PERIOD_M1,m1Shift);
   double m1Body=m1Close-iOpen(symbol,PERIOD_M1,m1Shift);
   bool alignedBody=(direction*m1Body>0.0);
   bool pullbackSeen=false;
   double previousHigh=-DBL_MAX,previousLow=DBL_MAX;
   for(int p=1;p<=3;p++)
   {
      double priorBody=iClose(symbol,PERIOD_M1,m1Shift+p)-iOpen(symbol,PERIOD_M1,m1Shift+p);
      if(direction*priorBody<0.0) pullbackSeen=true;
      previousHigh=MathMax(previousHigh,iHigh(symbol,PERIOD_M1,m1Shift+p));
      previousLow=MathMin(previousLow,iLow(symbol,PERIOD_M1,m1Shift+p));
   }
   bool breakoutSeen=(direction>0 ? m1Close>previousHigh : m1Close<previousLow);
   bool patternOK=(!thresholds.requireM1Pattern || pullbackSeen || breakoutSeen);
   // The M1 close is deliberately compared with the closed-M5 setup using M5 ATR.
   double m1ChaseM5ATR=MathAbs(m1Close-m5Close)/atrM5;
   double priorLow30=DBL_MAX,priorHigh30=-DBL_MAX;
   for(int origin=1;origin<=30;origin++)
   {
      priorLow30=MathMin(priorLow30,iLow(symbol,PERIOD_M1,m1Shift+origin));
      priorHigh30=MathMax(priorHigh30,iHigh(symbol,PERIOD_M1,m1Shift+origin));
   }
   double maturityDistance=(direction>0 ? m1Close-priorLow30 : priorHigh30-m1Close);
   double maturityM5ATR=maturityDistance/atrM5;
   bool m1Trigger=(m1Strength>=thresholds.minimumM1Strength &&
                   m1Acceleration>=thresholds.minimumM1Acceleration &&
                   m1Coherence>=thresholds.minimumM1Coherence &&
                   m1Shock<=thresholds.maximumM1Shock &&
                    m1ChaseM5ATR<=thresholds.maximumM1ChaseM5ATR && alignedBody && patternOK);

   bool earlyM5Setup=(m5Efficiency>=thresholds.minimumEarlyM5Efficiency &&
                      m5Strength>=thresholds.minimumEarlyM5Strength && m5Strength<=thresholds.maximumM5Strength &&
                      m5Coherence>=thresholds.minimumEarlyM5Coherence &&
                      m5Shock<=thresholds.maximumM5Shock &&
                      m5Pullback>=-thresholds.maximumM5PullbackATR &&
                      m5Acceleration>=thresholds.minimumEarlyM5Acceleration &&
                      m5Release>=thresholds.minimumEarlyM5Release);
   bool earlyM1Trigger=(m1Strength>=thresholds.minimumEarlyM1Strength &&
                        m1Acceleration>=thresholds.minimumEarlyM1Acceleration &&
                        m1Coherence>=thresholds.minimumM1Coherence &&
                        m1Shock<=thresholds.maximumM1Shock &&
                        m1Release>=thresholds.minimumEarlyM1Release &&
                        m1ChaseM5ATR<=thresholds.maximumM1ChaseM5ATR &&
                        maturityM5ATR<=thresholds.maximumEarlyMaturityM5ATR &&
                        alignedBody && patternOK);
   bool strictQualified=(h1Gate && m5Setup && m1Trigger);
   bool earlyQualified=(earlyH1Veto && earlyM5Setup && earlyM1Trigger);
   bool qualified=(strictQualified || earlyQualified);
   int entryMode=(earlyQualified ? GV_ENTRY_MODE_EARLY :
                  (strictQualified ? GV_ENTRY_MODE_STRICT : GV_ENTRY_MODE_NONE));
   int state=GV_STATE_NO_TRADE;
   string reason="NO QUALIFIED SETUP";
   if(qualified)
   {
      state=(m1Acceleration>0.15 ? GV_STATE_ACCELERATING : GV_STATE_GOOD);
      reason=(entryMode==GV_ENTRY_MODE_EARLY ?
         "EARLY H1 VETO, M5 INITIATION AND M1 TRIGGER PASSED" :
         "STRICT H1 REGIME, M5 SETUP AND M1 TRIGGER PASSED");
   }
   else if(!h1Gate && !earlyH1Veto) { state=GV_STATE_H1_CONFLICT; reason="CLOSED-H1 CONTEXT IS HOSTILE"; }
   else if(!m5Setup && !earlyM5Setup) { state=GV_STATE_M5_SETUP_WAIT; reason="CLOSED-M5 VELOCITY SETUP NOT READY"; }
   else if(m1Shock>thresholds.maximumM1Shock || m5Shock>thresholds.maximumM5Shock)
      { state=GV_STATE_OVEREXTENDED; reason="VELOCITY SHOCK ABOVE LIMIT"; }
   else if(!m1Trigger && !earlyM1Trigger)
   {
       if(m1Acceleration<0.0)
       {
          state=(m1Strength<0.0 ? GV_STATE_REVERSING : GV_STATE_EXHAUSTING);
          reason=(m1Strength<0.0 ? "CLOSED-M1 VELOCITY REVERSED" : "CLOSED-M1 VELOCITY IS EXHAUSTING");
       }
       else
       {
          state=GV_STATE_M1_TRIGGER_WAIT;
          reason="WAITING FOR CLOSED-M1 REACCELERATION";
       }
   }
   else
   {
      state=GV_STATE_M1_TRIGGER_WAIT;
      reason=(maturityM5ATR>thresholds.maximumEarlyMaturityM5ATR ?
         "NO ENTRY - MOVE MATURE" : "WAITING FOR ADAPTIVE ENGINE ALIGNMENT");
   }

   double h1Score=0.25*GVClamp(h1Gap/0.50,0.0,1.0)+0.25*GVClamp(h1Slope/0.20,0.0,1.0)+
                  0.25*GVClamp(h1Efficiency/0.40,0.0,1.0)+0.25*h1Persistence;
   double m5Score=0.50*GVClamp(m5Efficiency/0.40,0.0,1.0)+0.25*GVClamp(m5Strength/1.0,0.0,1.0)+
                  0.25*m5Coherence;
   double m1Score=0.40*GVClamp(m1Strength/0.50,0.0,1.0)+0.30*GVClamp(m1Acceleration/0.50,0.0,1.0)+
                  0.30*m1Coherence;

   result.valid=true;
   result.qualified=qualified;
   result.direction=direction;
   result.state=state;
   result.entryMode=entryMode;
   result.strictQualified=strictQualified;
   result.earlyQualified=earlyQualified;
   result.signalTime=signalOpen;
   result.m5SetupTime=iTime(symbol,PERIOD_M5,closedM5);
   result.h1RegimeTime=iTime(symbol,PERIOD_H1,closedH1);
   result.referenceEntry=m1Close;
   result.confidence=100.0*GVClamp((h1Score+m5Score+m1Score)/3.0,0.0,1.0);
   result.atrM5=atrM5;
   result.velocityM5=direction*m5Velocity[0];
   result.velocityM1=m1Strength;
   result.velocityH1=h1Velocity4;
   result.h1Alignment=h1Gap;
   result.h1Slope=h1Slope;
   result.h1Efficiency=h1Efficiency;
   result.h1Persistence=h1Persistence;
   result.pathQuality=m5Efficiency;
   result.acceleration=m1Acceleration;
   result.velocityStrength=m5Strength;
   result.shockRatio=m1Shock;
   result.m5Coherence=m5Coherence;
   result.m1Coherence=m1Coherence;
   result.m1ChaseM5ATR=m1ChaseM5ATR;
   result.m5Acceleration=m5Acceleration;
   result.m5Release=m5Release;
   result.m1Release=m1Release;
   result.maturityM5ATR=maturityM5ATR;
   result.m1PullbackSeen=pullbackSeen;
   result.m1BreakoutSeen=breakoutSeen;
   result.triggerPattern=(breakoutSeen ? "BREAKOUT" : (pullbackSeen ? "PULLBACK/RECLAIM" : "NONE"));
   result.reason=reason;
   return(true);
}

#endif
// End embedded V7 adaptive core.

enum GVLotSizingMode
{
   GV_FIXED_LOTS   = 0,
   GV_RISK_PERCENT = 1
};

enum GVTrailingMode
{
   GV_TRAIL_FIXED_MOVEMENT = 0,
   GV_TRAIL_M1_ATR         = 1
};

// ------------------------ 1. START / DIRECTION ---------------------
input bool   EnableAutomaticEntries       = false;
input bool   AllowBuySignals              = true;
input bool   AllowSellSignals             = true;

// ------------------------ 2. LOT / RISK ----------------------------
input GVLotSizingMode LotSizingMode       = GV_FIXED_LOTS;
input double FixedLotSize                 = 0.01;
input double RiskPercentOfBalance         = 1.0;
input double StrictInitialStopLossMovement= 25.0;
input double EarlyInitialStopLossMovement = 30.0;

// ------------------------ 3. PROFIT MANAGEMENT ---------------------
// Every feature below is optional.  With all disabled, management is manual.
input bool   UseFixedTakeProfit           = false;
input double FixedTakeProfitMovement      = 30.0;

input bool   UseBreakEven                 = false;
input double BreakEvenActivationMovement  = 10.0;
input double BreakEvenLockMovement        = 1.0;

input bool   UseTrailingStop              = false;
input GVTrailingMode TrailingMode         = GV_TRAIL_FIXED_MOVEMENT;
input double TrailingActivationMovement   = 10.0;
input double TrailingDistanceMovement     = 5.0;
input int    TrailingATRPeriod            = 14;
input double TrailingATRMultiplier        = 2.0;
input double TrailingStepMovement         = 1.0;

input bool   UsePartialProfits            = false;
input bool   EnablePartialLevel1          = true;
input double PartialLevel1Movement        = 10.0;
input double PartialLevel1Percent         = 25.0;
input bool   EnablePartialLevel2          = true;
input double PartialLevel2Movement        = 20.0;
input double PartialLevel2Percent         = 25.0;
input bool   EnablePartialLevel3          = false;
input double PartialLevel3Movement        = 30.0;
input double PartialLevel3Percent         = 25.0;

input bool   UseVelocityExit              = false;
input bool   ExitOnVelocityExhaustion     = true;
input bool   ExitOnOppositeQualifiedSignal= true;
input int    StrictMaximumHoldingMinutes  = 120; // 0 disables
input int    EarlyMaximumHoldingMinutes   = 180; // 0 disables

// ------------------------ 4. ENTRY SAFETY --------------------------
input bool   TradeCurrentSignalOnAttach   = false;
input int    MinimumMinutesBetweenEntries = 15;
input double MaximumEntryDeviationMovement= 3.0;  // absolute Gold price movement; 0 disables
input double MaximumSpreadMovement        = 0.80; // V6 clean-entry default; 0 disables
input int    MaximumTradesPerBrokerDay     = 3;    // 0 disables
input double MaximumDailyLossCurrency      = 0.0;  // 0 disables new-entry block
input bool   BlockLateFridayEntries        = true; // broker-time weekend exposure guard
input int    FridayEntryCutoffBrokerHour   = 20;   // block new Friday entries from this hour

// ------------------------ 5. H1 / M5 / M1 ENGINE (ADVANCED) --------
// H1 is the highest timeframe. Values are based on fully closed bars.
input double MinimumM5PathEfficiencyPct    = 15.0;
input double MinimumM5VelocityStrength     = 0.10;
input double MaximumM5VelocityStrength     = 2.50;
input double MinimumM5CoherencePct         = 66.7;
input double MaximumM5ShockRatio           = 2.50;
input double MaximumM5PullbackATR          = 1.50;
input double MinimumH1GapATR               = 0.00;
input double MinimumH1SlopeATR             = 0.00;
input double MinimumH1FourBarEfficiencyPct = 10.0;
input int    MinimumH1AlignedBodiesOf4     = 3;
input double MaximumH1ShockRatio           = 2.50;
input double MinimumM1TriggerStrength      = 0.05;
input double MinimumM1AccelerationATR      = 0.00;
input double MinimumM1CoherencePct         = 75.0;
input double MaximumM1ShockRatio           = 2.50;
input double MaximumM1ChaseM5ATR           = 1.00; // M1 close distance from M5 setup, divided by M5 ATR
input bool   RequireM1PullbackOrBreakout   = true;

// Adaptive early engine. These defaults are the audited V7 candidate values.
input double EarlyH1GapToleranceATR        = 0.50;
input double EarlyH1SlopeToleranceATR      = 0.15;
input double EarlyH1VelocityToleranceATR   = 0.50;
input double MinimumEarlyM5EfficiencyPct   = 10.0;
input double MinimumEarlyM5Strength        = 0.05;
input double MinimumEarlyM5CoherencePct    = 66.7;
input double MinimumEarlyM5AccelerationATR = 0.05;
input double MinimumEarlyM5ReleaseRatio    = 0.70;
input double MinimumEarlyM1Strength        = 0.05;
input double MinimumEarlyM1AccelerationATR = 0.05;
input double MinimumEarlyM1ReleaseRatio    = 0.60;
input double MaximumEarlyMaturityM5ATR     = 1.25;

// ------------------------ 6. EXECUTION (ADVANCED) -------------------
input double MaximumSlippageMovement      = 0.50; // absolute Gold price movement
input int    MagicNumber                  = 26081070;
input bool   AllowECNStopPlacementFallback= true;

// ------------------------ 7. DISPLAY / ALERTS -----------------------
input bool   ShowEAStatusPanel            = true;
input int    PanelX                       = 12;
input int    PanelY                       = 300;
input int    PanelWidth                   = 560;
input int    PanelFontSize                = 9;
input color  PanelBackgroundColor         = C'10,16,25';
input color  PanelHeaderColor             = C'24,36,54';
input color  PanelSectionColor            = C'16,26,40';
input color  PanelBorderColor             = C'83,105,130';
input color  PanelPrimaryTextColor        = C'238,243,248';
input color  PanelSecondaryTextColor      = C'159,177,196';
input bool   ShowCleanEntryLine           = true;
input color  CleanBuyEntryColor           = clrLimeGreen;
input color  CleanSellEntryColor          = clrTomato;
input bool   EnableEntryPopupAlert        = false;
input bool   EnableEntryPushNotification  = false;

GVThresholds g_thresholds;
GVResult g_lastSignal;
datetime g_lastM1Bar=0;
datetime g_lastEntryTime=0;
string g_lastAction="INITIALISING";
bool g_engineBusy=false;
datetime g_cacheDayStart=0;
int g_cacheHistoryTotal=-1;
int g_cacheOpenTotal=-1;
int g_cacheTradesToday=0;
double g_cacheClosedPnLToday=0.0;
datetime g_cacheLatestEntryTime=0;
datetime g_lastPanelUpdate=0;
bool g_pendingClose=false;
string g_pendingCloseReason="";
int g_stopRepairTicket=-1;
int g_stopRepairFailures=0;
datetime g_partialOpenTime=0;
double g_partialInitialLots=0.0;
bool g_partialDone1=false;
bool g_partialDone2=false;
bool g_partialDone3=false;

#define GV_EA_OBJECT_PREFIX "XVISION_GV_EA_V7_"
#define GV_EA_PANEL_HEIGHT 286
#define GV_CLOSE_RETRY_ATTEMPTS 3
#define GV_STOP_REPAIR_FAILURE_LIMIT 5

int LotDigits(const double step)
{
   if(step>=1.0) return(0);
   if(step>=0.1) return(1);
   if(step>=0.01) return(2);
   if(step>=0.001) return(3);
   return(4);
}

double NormaliseLots(const double requested)
{
   double minimum=MarketInfo(Symbol(),MODE_MINLOT);
   double maximum=MarketInfo(Symbol(),MODE_MAXLOT);
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(step<=0.0) step=0.01;
   // Never silently increase a requested lot size to the broker minimum.
   if(requested<minimum-1e-10) return(0.0);
   double lots=MathFloor((requested+1e-10)/step)*step;
   if(requested>maximum+1e-10)
      Print("XVISION Gold Velocity EA: requested lot size capped at broker maximum ",
            DoubleToString(maximum,LotDigits(step)),".");
   lots=MathMin(maximum,lots);
   if(lots<minimum-1e-10) return(0.0);
   return(NormalizeDouble(lots,LotDigits(step)));
}

bool PercentInputValid(const double value)
{
   return(value>=0.0 && value<=100.0);
}

bool InvalidInput(const string inputName,const string requirement)
{
   Print("XVISION Gold Velocity EA V7: invalid input ",inputName,". ",requirement);
   return(false);
}

bool ValidateInputs()
{
   if(!GVIsGoldSymbol(Symbol()))
   {
      return(InvalidInput("Symbol","Attach the EA only to a Gold/XAU symbol."));
   }
   if(!PercentInputValid(MinimumM5PathEfficiencyPct))
      return(InvalidInput("MinimumM5PathEfficiencyPct","Use a value from 0 to 100."));
   if(!PercentInputValid(MinimumM5CoherencePct))
      return(InvalidInput("MinimumM5CoherencePct","Use a value from 0 to 100."));
   if(!PercentInputValid(MinimumH1FourBarEfficiencyPct))
      return(InvalidInput("MinimumH1FourBarEfficiencyPct","Use a value from 0 to 100."));
   if(!PercentInputValid(MinimumM1CoherencePct))
      return(InvalidInput("MinimumM1CoherencePct","Use a value from 0 to 100."));
   if(MinimumM5VelocityStrength<0.0 || MaximumM5VelocityStrength<=MinimumM5VelocityStrength)
      return(InvalidInput("M5 velocity strength","Maximum must be greater than the non-negative minimum."));
   if(MaximumM5ShockRatio<=0.0 || MaximumH1ShockRatio<=0.0 || MaximumM1ShockRatio<=0.0)
      return(InvalidInput("Shock ratios","All maximum shock ratios must be greater than zero."));
   if(MaximumM5PullbackATR<=0.0 || MaximumM1ChaseM5ATR<=0.0)
      return(InvalidInput("Pullback/chase ATR limits","Use values greater than zero."));
   if(MinimumH1GapATR<0.0 || MinimumH1SlopeATR<0.0)
      return(InvalidInput("H1 alignment thresholds","Use zero or positive ATR-normalised values."));
   if(MinimumH1AlignedBodiesOf4<1 || MinimumH1AlignedBodiesOf4>4)
      return(InvalidInput("MinimumH1AlignedBodiesOf4","Use an integer from 1 to 4."));
   if(MinimumM1TriggerStrength<0.0 || MinimumM1AccelerationATR<-10.0 || MinimumM1AccelerationATR>10.0)
      return(InvalidInput("M1 trigger thresholds","Strength must be non-negative; acceleration must be from -10 to 10."));
   if(MinimumMinutesBetweenEntries<0)
      return(InvalidInput("MinimumMinutesBetweenEntries","Use zero or a positive number."));
   if(MaximumEntryDeviationMovement<0.0)
      return(InvalidInput("MaximumEntryDeviationMovement","Use zero or a positive movement."));
   if(MaximumSpreadMovement<0.0)
      return(InvalidInput("MaximumSpreadMovement","Use zero or a positive movement."));
   if(MaximumTradesPerBrokerDay<0)
      return(InvalidInput("MaximumTradesPerBrokerDay","Use zero or a positive number."));
   if(MaximumDailyLossCurrency<0.0)
      return(InvalidInput("MaximumDailyLossCurrency","Use zero or a positive currency amount."));
   if(FridayEntryCutoffBrokerHour<0 || FridayEntryCutoffBrokerHour>23)
      return(InvalidInput("FridayEntryCutoffBrokerHour","Use a broker-time hour from 0 to 23."));
   if(MaximumSlippageMovement<0.0)
      return(InvalidInput("MaximumSlippageMovement","Use zero or a positive Gold movement."));
   if(MagicNumber<=0)
      return(InvalidInput("MagicNumber","Use a positive integer."));
   if(PanelX<0) return(InvalidInput("PanelX","Use zero or a positive pixel position."));
   if(PanelY<0) return(InvalidInput("PanelY","Use zero or a positive pixel position."));
   if(PanelWidth<500 || PanelWidth>1000)
      return(InvalidInput("PanelWidth","Use a value from 500 to 1000."));
   if(PanelFontSize<8 || PanelFontSize>14)
      return(InvalidInput("PanelFontSize","Use a value from 8 to 14."));
   if(FixedLotSize<=0.0)
      return(InvalidInput("FixedLotSize","Use a value greater than zero."));
   if(RiskPercentOfBalance<=0.0 || RiskPercentOfBalance>100.0)
      return(InvalidInput("RiskPercentOfBalance","Use a value greater than 0 and no greater than 100."));
   if(StrictInitialStopLossMovement<0.0 || EarlyInitialStopLossMovement<0.0)
      return(InvalidInput("Initial stop movements","Use zero or positive movements."));
   if(LotSizingMode==GV_RISK_PERCENT &&
      (StrictInitialStopLossMovement<=0.0 || EarlyInitialStopLossMovement<=0.0))
      return(InvalidInput("Initial stop movements","Risk-percent sizing requires positive strict and early stops."));
   if(UseFixedTakeProfit && FixedTakeProfitMovement<=0.0)
      return(InvalidInput("FixedTakeProfitMovement","Fixed TP requires a positive movement."));
   if(UseBreakEven && (BreakEvenActivationMovement<=0.0 || BreakEvenLockMovement<0.0 ||
      BreakEvenLockMovement>=BreakEvenActivationMovement))
      return(InvalidInput("BreakEven settings","Activation must be positive; lock must be non-negative and below activation."));
   if(UseTrailingStop && (TrailingActivationMovement<0.0 || TrailingDistanceMovement<=0.0 ||
      TrailingATRPeriod<2 || TrailingATRMultiplier<=0.0 || TrailingStepMovement<=0.0))
      return(InvalidInput("Trailing settings","Check activation, distance, ATR period/multiplier and step."));
   if(StrictMaximumHoldingMinutes<0 || EarlyMaximumHoldingMinutes<0)
      return(InvalidInput("Maximum holding minutes","Use zero or positive numbers."));
   if(EarlyH1GapToleranceATR<0.0 || EarlyH1SlopeToleranceATR<0.0 || EarlyH1VelocityToleranceATR<0.0)
      return(InvalidInput("Early H1 tolerances","Use zero or positive values."));
   if(!PercentInputValid(MinimumEarlyM5EfficiencyPct) || !PercentInputValid(MinimumEarlyM5CoherencePct))
      return(InvalidInput("Early M5 percentages","Use values from 0 to 100."));
   if(MinimumEarlyM5Strength<0.0 || MinimumEarlyM5ReleaseRatio<=0.0 ||
      MinimumEarlyM1Strength<0.0 || MinimumEarlyM1ReleaseRatio<=0.0 || MaximumEarlyMaturityM5ATR<=0.0)
      return(InvalidInput("Early engine thresholds","Strengths must be non-negative; release and maturity limits must be positive."));

   if(UsePartialProfits)
   {
      double totalPercent=0.0;
      double previousLevel=0.0;
      if(EnablePartialLevel1)
      {
         if(PartialLevel1Movement<=0.0 || PartialLevel1Percent<=0.0 || PartialLevel1Percent>=100.0)
            return(InvalidInput("Partial level 1","Movement must be positive and percent must be between 0 and 100."));
         previousLevel=PartialLevel1Movement;
         totalPercent+=PartialLevel1Percent;
      }
      if(EnablePartialLevel2)
      {
         if(PartialLevel2Movement<=previousLevel || PartialLevel2Percent<=0.0 || PartialLevel2Percent>=100.0)
            return(InvalidInput("Partial level 2","Movement must exceed the prior level and percent must be between 0 and 100."));
         previousLevel=PartialLevel2Movement;
         totalPercent+=PartialLevel2Percent;
      }
      if(EnablePartialLevel3)
      {
         if(PartialLevel3Movement<=previousLevel || PartialLevel3Percent<=0.0 || PartialLevel3Percent>=100.0)
            return(InvalidInput("Partial level 3","Movement must exceed the prior level and percent must be between 0 and 100."));
         totalPercent+=PartialLevel3Percent;
      }
      if(totalPercent>=100.0)
      {
         return(InvalidInput("Partial percentages","Enabled percentages must total less than 100%."));
      }
   }
   return(true);
}

void LoadThresholds()
{
   g_thresholds.minimumM5Efficiency=MinimumM5PathEfficiencyPct/100.0;
   g_thresholds.minimumM5Strength=MinimumM5VelocityStrength;
   g_thresholds.maximumM5Strength=MaximumM5VelocityStrength;
   g_thresholds.minimumM5Coherence=MinimumM5CoherencePct/100.0;
   g_thresholds.maximumM5Shock=MaximumM5ShockRatio;
   g_thresholds.maximumM5PullbackATR=MaximumM5PullbackATR;
   g_thresholds.minimumH1GapATR=MinimumH1GapATR;
   g_thresholds.minimumH1SlopeATR=MinimumH1SlopeATR;
   g_thresholds.minimumH1Efficiency=MinimumH1FourBarEfficiencyPct/100.0;
   g_thresholds.minimumH1AlignedBodies=MinimumH1AlignedBodiesOf4;
   g_thresholds.maximumH1Shock=MaximumH1ShockRatio;
   g_thresholds.minimumM1Strength=MinimumM1TriggerStrength;
   g_thresholds.minimumM1Acceleration=MinimumM1AccelerationATR;
   g_thresholds.minimumM1Coherence=MinimumM1CoherencePct/100.0;
   g_thresholds.maximumM1Shock=MaximumM1ShockRatio;
   g_thresholds.maximumM1ChaseM5ATR=MaximumM1ChaseM5ATR;
   g_thresholds.requireM1Pattern=RequireM1PullbackOrBreakout;
   g_thresholds.earlyH1GapTolerance=EarlyH1GapToleranceATR;
   g_thresholds.earlyH1SlopeTolerance=EarlyH1SlopeToleranceATR;
   g_thresholds.earlyH1VelocityTolerance=EarlyH1VelocityToleranceATR;
   g_thresholds.minimumEarlyM5Efficiency=MinimumEarlyM5EfficiencyPct/100.0;
   g_thresholds.minimumEarlyM5Strength=MinimumEarlyM5Strength;
   g_thresholds.minimumEarlyM5Coherence=MinimumEarlyM5CoherencePct/100.0;
   g_thresholds.minimumEarlyM5Acceleration=MinimumEarlyM5AccelerationATR;
   g_thresholds.minimumEarlyM5Release=MinimumEarlyM5ReleaseRatio;
   g_thresholds.minimumEarlyM1Strength=MinimumEarlyM1Strength;
   g_thresholds.minimumEarlyM1Acceleration=MinimumEarlyM1AccelerationATR;
   g_thresholds.minimumEarlyM1Release=MinimumEarlyM1ReleaseRatio;
   g_thresholds.maximumEarlyMaturityM5ATR=MaximumEarlyMaturityM5ATR;
}

datetime BrokerDayStart()
{
   datetime start=iTime(Symbol(),PERIOD_D1,0);
   if(start<=0) start=StrToTime(TimeToString(TimeCurrent(),TIME_DATE));
   return(start);
}

bool IsManagedSelectedOrder()
{
   if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) return(false);
   return(OrderType()==OP_BUY || OrderType()==OP_SELL);
}

int FindManagedTicket()
{
   for(int index=OrdersTotal()-1;index>=0;index--)
   {
      if(!OrderSelect(index,SELECT_BY_POS,MODE_TRADES)) continue;
      if(IsManagedSelectedOrder()) return(OrderTicket());
   }
   return(-1);
}

void InvalidateAccountCache()
{
   g_cacheHistoryTotal=-1;
   g_cacheOpenTotal=-1;
}

void RefreshAccountCache(const bool force=false)
{
   datetime start=BrokerDayStart();
   int historyTotal=OrdersHistoryTotal();
   int openTotal=OrdersTotal();
   if(!force && start==g_cacheDayStart && historyTotal==g_cacheHistoryTotal &&
      openTotal==g_cacheOpenTotal) return;

   datetime openTimes[];
   int openTimeCount=0;
   double closedPnL=0.0;
   datetime latest=0;

   for(int h=historyTotal-1;h>=0;h--)
   {
      if(!OrderSelect(h,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber ||
         (OrderType()!=OP_BUY && OrderType()!=OP_SELL)) continue;
      if(OrderOpenTime()>latest) latest=OrderOpenTime();
      if(OrderCloseTime()>=start)
         closedPnL+=OrderProfit()+OrderSwap()+OrderCommission();
      if(OrderOpenTime()>=start)
      {
         ArrayResize(openTimes,openTimeCount+1);
         openTimes[openTimeCount++]=OrderOpenTime();
      }
   }
   for(int t=openTotal-1;t>=0;t--)
   {
      if(!OrderSelect(t,SELECT_BY_POS,MODE_TRADES)) continue;
      if(!IsManagedSelectedOrder()) continue;
      if(OrderOpenTime()>latest) latest=OrderOpenTime();
      if(OrderOpenTime()>=start)
      {
         ArrayResize(openTimes,openTimeCount+1);
         openTimes[openTimeCount++]=OrderOpenTime();
      }
   }

   int uniqueCount=0;
   if(openTimeCount>0)
   {
      ArraySort(openTimes,WHOLE_ARRAY,0,MODE_ASCEND);
      uniqueCount=1;
      for(int s=1;s<openTimeCount;s++)
         if(openTimes[s]!=openTimes[s-1]) uniqueCount++;
   }

   g_cacheDayStart=start;
   g_cacheHistoryTotal=historyTotal;
   g_cacheOpenTotal=openTotal;
   g_cacheTradesToday=uniqueCount;
   g_cacheClosedPnLToday=closedPnL;
   g_cacheLatestEntryTime=latest;
}

int TradesOpenedToday()
{
   RefreshAccountCache();
   return(g_cacheTradesToday);
}

double ClosedPnLToday()
{
   RefreshAccountCache();
   return(g_cacheClosedPnLToday);
}

datetime LatestEntryTime()
{
   RefreshAccountCache();
   return(g_cacheLatestEntryTime);
}

string PositionKey(const datetime openTime)
{
   return(StringFormat("XVG.%d.%d.%d",AccountNumber(),MagicNumber,(int)openTime));
}

double ProfitMovementForSelectedOrder()
{
   RefreshRates();
   if(OrderType()==OP_BUY) return(Bid-OrderOpenPrice());
   if(OrderType()==OP_SELL) return(OrderOpenPrice()-Ask);
   return(0.0);
}

double StopMovementForMode(const int mode)
{
   return(mode==GV_ENTRY_MODE_EARLY ? EarlyInitialStopLossMovement : StrictInitialStopLossMovement);
}

int HoldMinutesForMode(const int mode)
{
   return(mode==GV_ENTRY_MODE_EARLY ? EarlyMaximumHoldingMinutes : StrictMaximumHoldingMinutes);
}

int SelectedOrderEntryMode()
{
   string comment=OrderComment();
   if(StringFind(comment,"XV7E_")==0) return(GV_ENTRY_MODE_EARLY);
   return(GV_ENTRY_MODE_STRICT);
}

double CalculateLots(const double stopMovement)
{
   if(LotSizingMode==GV_FIXED_LOTS) return(NormaliseLots(FixedLotSize));
   double tickValue=MarketInfo(Symbol(),MODE_TICKVALUE);
   double tickSize=MarketInfo(Symbol(),MODE_TICKSIZE);
   if(tickSize<=0.0) tickSize=Point;
   if(tickValue<=0.0 || stopMovement<=0.0) return(0.0);
   double riskMoney=AccountBalance()*RiskPercentOfBalance/100.0;
   double riskPerLot=(stopMovement/tickSize)*tickValue;
   if(riskPerLot<=0.0) return(0.0);
   double rawLots=riskMoney/riskPerLot;
   if(rawLots<MarketInfo(Symbol(),MODE_MINLOT)) return(0.0); // never round risk upward
   return(NormaliseLots(rawLots));
}

int SlippagePointsForBroker()
{
   if(MaximumSlippageMovement<=0.0 || Point<=0.0) return(0);
   return((int)MathMax(0.0,MathRound(MaximumSlippageMovement/Point)));
}

bool StopsRespectBroker(const int direction,const double entry,const double sl,const double tp)
{
   double minimum=MarketInfo(Symbol(),MODE_STOPLEVEL)*Point;
   if(sl>0.0 && MathAbs(entry-sl)<minimum) return(false);
   if(tp>0.0 && MathAbs(tp-entry)<minimum) return(false);
   if(direction>0 && ((sl>0.0 && sl>=entry) || (tp>0.0 && tp<=entry))) return(false);
   if(direction<0 && ((sl>0.0 && sl<=entry) || (tp>0.0 && tp>=entry))) return(false);
   return(true);
}

void ResetPartialMemory()
{
   g_partialOpenTime=0;
   g_partialInitialLots=0.0;
   g_partialDone1=false;
   g_partialDone2=false;
   g_partialDone3=false;
}

void InitialisePartialStateForSelectedOrder(const bool forceNew=false)
{
   datetime openTime=OrderOpenTime();
   if(!forceNew && g_partialOpenTime==openTime) return;
   g_partialOpenTime=openTime;
   string key=PositionKey(openTime);
   if(forceNew || IsTesting())
   {
      g_partialInitialLots=OrderLots();
      g_partialDone1=false;
      g_partialDone2=false;
      g_partialDone3=false;
      if(!IsTesting())
      {
         GlobalVariableSet(key+".LOT",g_partialInitialLots);
         GlobalVariableSet(key+".P1",0.0);
         GlobalVariableSet(key+".P2",0.0);
         GlobalVariableSet(key+".P3",0.0);
      }
      return;
   }

   g_partialInitialLots=(GlobalVariableCheck(key+".LOT") ?
      GlobalVariableGet(key+".LOT") : OrderLots());
   g_partialDone1=(GlobalVariableCheck(key+".P1") && GlobalVariableGet(key+".P1")>0.5);
   g_partialDone2=(GlobalVariableCheck(key+".P2") && GlobalVariableGet(key+".P2")>0.5);
   g_partialDone3=(GlobalVariableCheck(key+".P3") && GlobalVariableGet(key+".P3")>0.5);
   if(!GlobalVariableCheck(key+".LOT")) GlobalVariableSet(key+".LOT",g_partialInitialLots);
}

bool PartialLevelDoneForSelectedOrder(const int levelNumber)
{
   InitialisePartialStateForSelectedOrder();
   if(levelNumber==1) return(g_partialDone1);
   if(levelNumber==2) return(g_partialDone2);
   if(levelNumber==3) return(g_partialDone3);
   return(true);
}

void MarkPartialLevelDone(const int levelNumber,const datetime openTime)
{
   if(levelNumber==1) g_partialDone1=true;
   if(levelNumber==2) g_partialDone2=true;
   if(levelNumber==3) g_partialDone3=true;
   if(!IsTesting())
      GlobalVariableSet(PositionKey(openTime)+StringFormat(".P%d",levelNumber),1.0);
}

void CleanupPartialState(const datetime openTime)
{
   if(openTime<=0) return;
   if(!IsTesting())
   {
      string key=PositionKey(openTime);
      GlobalVariableDel(key+".LOT");
      GlobalVariableDel(key+".P1");
      GlobalVariableDel(key+".P2");
      GlobalVariableDel(key+".P3");
   }
   if(g_partialOpenTime==openTime) ResetPartialMemory();
}

void CleanupOrphanedPartialGlobals()
{
   if(IsTesting()) return;
   string prefix=StringFormat("XVG.%d.%d.",AccountNumber(),MagicNumber);
   string keepPrefix="";
   int ticket=FindManagedTicket();
   if(ticket>=0 && OrderSelect(ticket,SELECT_BY_TICKET))
      keepPrefix=PositionKey(OrderOpenTime())+".";

   for(int index=GlobalVariablesTotal()-1;index>=0;index--)
   {
      string name=GlobalVariableName(index);
      if(StringFind(name,prefix)!=0) continue;
      if(keepPrefix!="" && StringFind(name,keepPrefix)==0) continue;
      GlobalVariableDel(name);
   }
}

bool IsRetryableCloseError(const int error)
{
   return(error==4 || error==6 || error==128 || error==135 || error==136 ||
          error==137 || error==138 || error==146);
}

bool CloseSelectedOrder(const string reason)
{
   int ticket=OrderTicket();
   double lots=OrderLots();
   int type=OrderType();
   datetime openTime=OrderOpenTime();
   int finalError=0;
   for(int attempt=1;attempt<=GV_CLOSE_RETRY_ATTEMPTS;attempt++)
   {
      if(!OrderSelect(ticket,SELECT_BY_TICKET))
      {
         finalError=GetLastError();
         break;
      }
      RefreshRates();
      double price=(type==OP_BUY ? Bid : Ask);
      ResetLastError();
      if(OrderClose(ticket,lots,price,SlippagePointsForBroker(),clrSilver))
      {
         CleanupPartialState(openTime);
         InvalidateAccountCache();
         g_pendingClose=false;
         g_pendingCloseReason="";
         g_lastAction="CLOSED: "+reason;
         Print("XVISION Gold Velocity EA V7: closed ticket ",ticket,": ",reason);
         return(true);
      }
      finalError=GetLastError();
      if(!IsRetryableCloseError(finalError)) break;
      RefreshRates();
      if(!IsTesting()) Sleep(100);
   }
   g_pendingClose=true;
   g_pendingCloseReason=reason;
   g_lastAction=StringFormat("CLOSE RETRY PENDING %d",finalError);
   Print("XVISION Gold Velocity EA V7: close remains pending, ticket ",ticket,
         ", error ",finalError,", reason ",reason);
   return(false);
}

bool CloseManagedOrder(const string reason)
{
   int ticket=FindManagedTicket();
   if(ticket<0 || !OrderSelect(ticket,SELECT_BY_TICKET)) return(false);
   return(CloseSelectedOrder(reason));
}

bool CleanEntryStatus(GVResult &signal,double &executionPrice,double &deviation,
                      double &spread,string &status)
{
   executionPrice=0.0;
   deviation=0.0;
   spread=0.0;
   status="WAIT - NO QUALIFIED CLOSED-M1 TRIGGER";
   if(!signal.valid || !signal.qualified || signal.direction==0 || signal.referenceEntry<=0.0)
      return(false);

   RefreshRates();
   double ask=MarketInfo(Symbol(),MODE_ASK);
   double bid=MarketInfo(Symbol(),MODE_BID);
   if(ask<=0.0 || bid<=0.0)
   {
      status="WAIT - LIVE BID/ASK NOT AVAILABLE";
      return(false);
   }
   executionPrice=(signal.direction>0 ? ask : bid);
   spread=MathMax(0.0,ask-bid);
   deviation=MathAbs(executionPrice-signal.referenceEntry);
   if(MaximumSpreadMovement>0.0 && spread>MaximumSpreadMovement)
   {
      status="WAIT - SPREAD ABOVE CLEAN LIMIT";
      return(false);
   }
   if(MaximumEntryDeviationMovement>0.0 && deviation>MaximumEntryDeviationMovement)
   {
      status="WAIT - PRICE MOVED; DO NOT CHASE";
      return(false);
   }
   status="READY";
   return(true);
}

bool SendEntry(GVResult &signal)
{
   double entry=0.0,deviation=0.0,spread=0.0;
   string cleanStatus="";
   if(!CleanEntryStatus(signal,entry,deviation,spread,cleanStatus))
   {
      g_lastAction="ENTRY BLOCKED: "+cleanStatus;
      return(false);
   }
   int type=(signal.direction>0 ? OP_BUY : OP_SELL);

   double stopMovement=StopMovementForMode(signal.entryMode);
   double lots=CalculateLots(stopMovement);
   if(lots<=0.0)
   {
      g_lastAction="ENTRY BLOCKED: LOT CALCULATION";
      return(false);
   }
   if(AccountFreeMarginCheck(Symbol(),type,lots)<=0.0)
   {
      g_lastAction="ENTRY BLOCKED: FREE MARGIN";
      return(false);
   }

   double sl=0.0;
   double tp=0.0;
   if(stopMovement>0.0)
      sl=(signal.direction>0 ? entry-stopMovement : entry+stopMovement);
   if(UseFixedTakeProfit)
      tp=(signal.direction>0 ? entry+FixedTakeProfitMovement : entry-FixedTakeProfitMovement);
   sl=(sl>0.0 ? NormalizeDouble(sl,Digits) : 0.0);
   tp=(tp>0.0 ? NormalizeDouble(tp,Digits) : 0.0);
   if(!StopsRespectBroker(signal.direction,entry,sl,tp))
   {
      g_lastAction="ENTRY BLOCKED: BROKER STOP DISTANCE";
      return(false);
   }

   string comment=StringFormat(signal.entryMode==GV_ENTRY_MODE_EARLY ? "XV7E_%d" : "XV7S_%d",
                               (int)signal.signalTime);
   ResetLastError();
   int ticket=OrderSend(Symbol(),type,lots,entry,SlippagePointsForBroker(),sl,tp,comment,MagicNumber,0,
                        (signal.direction>0 ? clrLime : clrTomato));
   int firstError=GetLastError();
   int finalError=firstError;
   bool usedFallback=false;
   if(ticket<0 && AllowECNStopPlacementFallback && firstError==ERR_INVALID_STOPS)
   {
      double fallbackDeviation=0.0,fallbackSpread=0.0;
      string fallbackStatus="";
      if(!CleanEntryStatus(signal,entry,fallbackDeviation,fallbackSpread,fallbackStatus))
      {
         g_lastAction="ENTRY ABORTED: "+fallbackStatus;
         return(false);
      }
      ResetLastError();
      ticket=OrderSend(Symbol(),type,lots,entry,SlippagePointsForBroker(),0.0,0.0,comment,MagicNumber,0,
                       (signal.direction>0 ? clrLime : clrTomato));
      usedFallback=(ticket>=0);
      finalError=GetLastError();
   }
   if(ticket<0)
   {
      g_lastAction=StringFormat("ENTRY FAILED %d",finalError);
      Print("XVISION Gold Velocity EA: OrderSend failed. First error ",firstError,
            ", final error ",finalError);
      return(false);
   }

   // OrderSend succeeded. Record the entry immediately even if the subsequent
   // selection or protection check must be completed on a later tick.
   g_lastEntryTime=TimeCurrent();
   InvalidateAccountCache();

   if(!OrderSelect(ticket,SELECT_BY_TICKET))
   {
      g_lastAction="ENTRY OPENED; PROTECTION CHECK PENDING";
      Print("XVISION Gold Velocity EA V7: opened ticket ",ticket,
             " but could not select it for the protection check.");
      return(true);
   }
   double actualOpen=OrderOpenPrice();
   double exactSL=(stopMovement>0.0 ?
      (signal.direction>0 ? actualOpen-stopMovement : actualOpen+stopMovement) : 0.0);
   double exactTP=(UseFixedTakeProfit ?
      (signal.direction>0 ? actualOpen+FixedTakeProfitMovement : actualOpen-FixedTakeProfitMovement) : 0.0);
   exactSL=(exactSL>0.0 ? NormalizeDouble(exactSL,Digits) : 0.0);
   exactTP=(exactTP>0.0 ? NormalizeDouble(exactTP,Digits) : 0.0);
   if(usedFallback || MathAbs(OrderStopLoss()-exactSL)>Point || MathAbs(OrderTakeProfit()-exactTP)>Point)
   {
      ResetLastError();
      if(!OrderModify(ticket,actualOpen,exactSL,exactTP,0,clrNONE))
      {
         int modifyError=GetLastError();
         Print("XVISION Gold Velocity EA: post-fill stop anchoring failed, error ",modifyError);
         if(stopMovement>0.0)
         {
            g_pendingClose=true;
            g_pendingCloseReason="PROTECTIVE STOP COULD NOT BE SET";
            bool emergencyClosed=false;
            if(OrderSelect(ticket,SELECT_BY_TICKET))
               emergencyClosed=CloseSelectedOrder(g_pendingCloseReason);
            if(emergencyClosed)
            {
               g_lastAction="ENTRY OPENED THEN CLOSED: STOP PROTECTION FAILED";
               return(false);
            }
            g_lastAction="UNPROTECTED ENTRY: CLOSE RETRY PENDING";
            return(true);
         }
      }
   }

   if(OrderSelect(ticket,SELECT_BY_TICKET))
      InitialisePartialStateForSelectedOrder(true);
   g_lastAction=StringFormat("OPENED %s %s %.2f LOT",GVEntryModeText(signal.entryMode),
                             GVDirectionText(signal.direction),lots);
   string message=StringFormat("XVISION Gold Velocity V7 opened %s %s %.2f lot | quality %.1f",
      GVEntryModeText(signal.entryMode),GVDirectionText(signal.direction),lots,signal.confidence);
   if(EnableEntryPopupAlert) Alert(message);
   if(EnableEntryPushNotification) SendNotification(message);
   return(true);
}

bool ProcessPartialLevel(const int levelNumber,const double triggerMovement,const double percent)
{
   int ticket=FindManagedTicket();
   if(ticket<0 || !OrderSelect(ticket,SELECT_BY_TICKET)) return(false);
   InitialisePartialStateForSelectedOrder();
   datetime openTime=OrderOpenTime();
   if(PartialLevelDoneForSelectedOrder(levelNumber)) return(false);
   if(ProfitMovementForSelectedOrder()<triggerMovement) return(false);

   double initialLots=g_partialInitialLots;
   double minimum=MarketInfo(Symbol(),MODE_MINLOT);
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(step<=0.0) step=0.01;
   double closeLots=MathFloor((initialLots*percent/100.0+1e-10)/step)*step;
   closeLots=NormalizeDouble(closeLots,LotDigits(step));
   double currentLots=OrderLots();
   if(closeLots<minimum || currentLots-closeLots<minimum-1e-10)
   {
      MarkPartialLevelDone(levelNumber,openTime);
      Print("XVISION Gold Velocity EA: partial level ",levelNumber,
            " skipped because broker minimum lot would be violated.");
      return(false);
   }

   int type=OrderType();
   int finalError=0;
   bool closed=false;
   for(int attempt=1;attempt<=GV_CLOSE_RETRY_ATTEMPTS;attempt++)
   {
      if(!OrderSelect(ticket,SELECT_BY_TICKET))
      {
         finalError=GetLastError();
         break;
      }
      RefreshRates();
      double price=(type==OP_BUY ? Bid : Ask);
      ResetLastError();
      if(OrderClose(ticket,closeLots,price,SlippagePointsForBroker(),clrGold))
      {
         closed=true;
         break;
      }
      finalError=GetLastError();
      if(!IsRetryableCloseError(finalError)) break;
      RefreshRates();
      if(!IsTesting()) Sleep(100);
   }
   if(!closed)
   {
      Print("XVISION Gold Velocity EA V7: partial level ",levelNumber,
            " failed after retries, error ",finalError);
      return(false);
   }
   MarkPartialLevelDone(levelNumber,openTime);
   InvalidateAccountCache();
   g_lastAction=StringFormat("PARTIAL %d: %.2f LOT",levelNumber,closeLots);
   return(true);
}

double BrokerModificationDistance()
{
   double stopDistance=MarketInfo(Symbol(),MODE_STOPLEVEL)*Point;
   double freezeDistance=MarketInfo(Symbol(),MODE_FREEZELEVEL)*Point;
   return(MathMax(stopDistance,freezeDistance));
}

bool EnsureInitialStopProtection()
{
   double stopMovement=StopMovementForMode(SelectedOrderEntryMode());
   if(stopMovement<=0.0) return(true);
   int ticket=OrderTicket();
   if(OrderStopLoss()>0.0)
   {
      g_stopRepairTicket=ticket;
      g_stopRepairFailures=0;
      return(true);
   }
   if(g_stopRepairTicket!=ticket)
   {
      g_stopRepairTicket=ticket;
      g_stopRepairFailures=0;
   }

   RefreshRates();
   bool isBuy=(OrderType()==OP_BUY);
   double repair=(isBuy ? OrderOpenPrice()-stopMovement :
                          OrderOpenPrice()+stopMovement);
   double minimumDistance=BrokerModificationDistance();
   if(isBuy) repair=MathMin(repair,Bid-minimumDistance);
   else repair=MathMax(repair,Ask+minimumDistance);
   repair=NormalizeDouble(repair,Digits);

   ResetLastError();
   if(OrderModify(ticket,OrderOpenPrice(),repair,OrderTakeProfit(),0,clrNONE))
   {
      g_stopRepairFailures=0;
      g_lastAction="PROTECTIVE STOP REPAIRED";
      Print("XVISION Gold Velocity EA V7: protective stop repaired for ticket ",ticket,".");
      return(true);
   }

   int error=GetLastError();
   g_stopRepairFailures++;
   g_lastAction=StringFormat("STOP REPAIR %d/%d FAILED %d",g_stopRepairFailures,
                             GV_STOP_REPAIR_FAILURE_LIMIT,error);
   Print("XVISION Gold Velocity EA V7: protective stop repair failed for ticket ",ticket,
         ", attempt ",g_stopRepairFailures,", error ",error,".");
   if(g_stopRepairFailures>=GV_STOP_REPAIR_FAILURE_LIMIT)
      CloseSelectedOrder("UNPROTECTED POSITION");
   return(false);
}

void ApplyStopManagement()
{
   int ticket=FindManagedTicket();
   if(ticket<0 || !OrderSelect(ticket,SELECT_BY_TICKET)) return;
   RefreshRates();
   bool isBuy=(OrderType()==OP_BUY);
   double movement=ProfitMovementForSelectedOrder();
   double desired=OrderStopLoss();
   bool haveDesired=(desired>0.0);

   if(UseBreakEven && movement>=BreakEvenActivationMovement)
   {
      double breakEven=(isBuy ? OrderOpenPrice()+BreakEvenLockMovement : OrderOpenPrice()-BreakEvenLockMovement);
      if(!haveDesired || (isBuy && breakEven>desired) || (!isBuy && breakEven<desired))
      {
         desired=breakEven;
         haveDesired=true;
      }
   }

   if(UseTrailingStop && movement>=TrailingActivationMovement)
   {
      double distance=TrailingDistanceMovement;
      if(TrailingMode==GV_TRAIL_M1_ATR)
      {
         double atr=iATR(Symbol(),PERIOD_M1,TrailingATRPeriod,1);
         if(atr>0.0) distance=atr*TrailingATRMultiplier;
      }
      double trailing=(isBuy ? Bid-distance : Ask+distance);
      if(!haveDesired || (isBuy && trailing>desired) || (!isBuy && trailing<desired))
      {
         desired=trailing;
         haveDesired=true;
      }
   }
   if(!haveDesired) return;

   double minimumStop=BrokerModificationDistance();
   if(isBuy) desired=MathMin(desired,Bid-minimumStop);
   else desired=MathMax(desired,Ask+minimumStop);
   desired=NormalizeDouble(desired,Digits);

   double oldStop=OrderStopLoss();
   bool improves=(oldStop<=0.0 || (isBuy && desired>oldStop) || (!isBuy && desired<oldStop));
   if(!improves) return;
   double requiredStep=(UseTrailingStop ? TrailingStepMovement : Point);
   if(oldStop>0.0 && MathAbs(desired-oldStop)<requiredStep) return;

   ResetLastError();
   if(!OrderModify(ticket,OrderOpenPrice(),desired,OrderTakeProfit(),0,clrDodgerBlue))
   {
      int error=GetLastError();
      if(error!=ERR_NO_RESULT)
         Print("XVISION Gold Velocity EA: stop management modify failed, error ",error);
   }
}

void ManagePositionEveryTick()
{
   int ticket=FindManagedTicket();
   if(ticket<0)
   {
      if(g_partialOpenTime>0) CleanupPartialState(g_partialOpenTime);
      g_pendingClose=false;
      g_pendingCloseReason="";
      g_stopRepairTicket=-1;
      g_stopRepairFailures=0;
      return;
   }
   if(!OrderSelect(ticket,SELECT_BY_TICKET)) return;
   if(g_pendingClose)
   {
      CloseSelectedOrder(g_pendingCloseReason);
      return;
   }
   if(!EnsureInitialStopProtection()) return;
   int holdMinutes=HoldMinutesForMode(SelectedOrderEntryMode());
   if(holdMinutes>0 && TimeCurrent()-OrderOpenTime()>=holdMinutes*60)
   {
      CloseSelectedOrder("MAXIMUM HOLDING TIME");
      return;
   }
   if(UsePartialProfits)
   {
      if(EnablePartialLevel1) ProcessPartialLevel(1,PartialLevel1Movement,PartialLevel1Percent);
      if(EnablePartialLevel2) ProcessPartialLevel(2,PartialLevel2Movement,PartialLevel2Percent);
      if(EnablePartialLevel3) ProcessPartialLevel(3,PartialLevel3Movement,PartialLevel3Percent);
   }
   ApplyStopManagement();
}

bool ProcessVelocityExit(GVResult &signal)
{
   if(!UseVelocityExit) return(false);
   int ticket=FindManagedTicket();
   if(ticket<0 || !OrderSelect(ticket,SELECT_BY_TICKET)) return(false);
   int tradeDirection=(OrderType()==OP_BUY ? 1 : -1);
   if(ExitOnOppositeQualifiedSignal && signal.valid && signal.qualified && signal.direction!=tradeDirection)
      return(CloseSelectedOrder("OPPOSITE QUALIFIED VELOCITY"));
   if(ExitOnVelocityExhaustion && signal.valid && signal.direction==tradeDirection &&
      (signal.state==GV_STATE_EXHAUSTING || signal.state==GV_STATE_REVERSING))
      return(CloseSelectedOrder("VELOCITY EXHAUSTION/REVERSAL"));
   return(false);
}

bool LateFridayEntryBlocked()
{
   if(!BlockLateFridayEntries) return(false);
   datetime now=TimeCurrent();
   return(TimeDayOfWeek(now)==5 && TimeHour(now)>=FridayEntryCutoffBrokerHour);
}

bool EntryIsAllowed(GVResult &signal)
{
   if(!EnableAutomaticEntries || !signal.valid || !signal.qualified) return(false);
   if(signal.direction>0 && !AllowBuySignals) return(false);
   if(signal.direction<0 && !AllowSellSignals) return(false);
   if(FindManagedTicket()>=0) return(false);
   if(LateFridayEntryBlocked())
   {
      g_lastAction="ENTRY BLOCKED: FRIDAY CUTOFF";
      return(false);
   }
   if(!IsTradeAllowed())
   {
      g_lastAction="ENTRY BLOCKED: AUTOTRADING/OCCUPIED CONTEXT";
      return(false);
   }
   datetime latest=MathMax(g_lastEntryTime,LatestEntryTime());
   if(MinimumMinutesBetweenEntries>0 && latest>0 &&
      TimeCurrent()-latest<MinimumMinutesBetweenEntries*60)
   {
      g_lastAction="ENTRY BLOCKED: COOLDOWN";
      return(false);
   }
   if(MaximumTradesPerBrokerDay>0 && TradesOpenedToday()>=MaximumTradesPerBrokerDay)
   {
      g_lastAction="ENTRY BLOCKED: DAILY TRADE LIMIT";
      return(false);
   }
   if(MaximumDailyLossCurrency>0.0 && ClosedPnLToday()<=-MaximumDailyLossCurrency)
   {
      g_lastAction="ENTRY BLOCKED: DAILY LOSS LIMIT";
      return(false);
   }
   return(true);
}

string ProfitManagementText()
{
   if(!UseFixedTakeProfit && !UseBreakEven && !UseTrailingStop && !UsePartialProfits &&
      !UseVelocityExit && StrictMaximumHoldingMinutes<=0 && EarlyMaximumHoldingMinutes<=0) return("MANUAL");
   string text="";
   if(UseFixedTakeProfit) text+="TP ";
   if(UseBreakEven) text+="BE ";
   if(UseTrailingStop) text+="TRAIL ";
   if(UsePartialProfits) text+="PARTIAL ";
   if(UseVelocityExit) text+="VEL-EXIT ";
   if(StrictMaximumHoldingMinutes>0 || EarlyMaximumHoldingMinutes>0) text+="MODE-TIME ";
   return(text);
}

string EATimeframeText(const int timeframe)
{
   if(timeframe==PERIOD_M1) return("M1");
   if(timeframe==PERIOD_M5) return("M5");
   if(timeframe==PERIOD_M15) return("M15");
   if(timeframe==PERIOD_M30) return("M30");
   if(timeframe==PERIOD_H1) return("H1");
   if(timeframe==PERIOD_D1) return("D1");
   return(IntegerToString(timeframe));
}

string EAPanelName(const string key)
{
   return(GV_EA_OBJECT_PREFIX+IntegerToString(MagicNumber)+"_PANEL_"+key);
}

string EAEntryObjectName()
{
   return(GV_EA_OBJECT_PREFIX+IntegerToString(MagicNumber)+"_CLEAN_ENTRY");
}

void DeleteEAPanel()
{
   ObjectsDeleteAll(0,GV_EA_OBJECT_PREFIX+IntegerToString(MagicNumber)+"_PANEL_");
   ChartRedraw(0);
}

void DeleteEAEntryLine()
{
   ObjectDelete(0,EAEntryObjectName());
}

void EAPanelRectangle(const string key,const int x,const int y,const int width,
                      const int height,const color background,const color border)
{
   string name=EAPanelName(key);
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
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
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

void EAPanelLabel(const string key,const int x,const int y,const string value,
                  const color textColor,const int fontSize,const string fontName="Segoe UI")
{
   string name=EAPanelName(key);
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,textColor);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontSize);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetString(0,name,OBJPROP_FONT,fontName);
   ObjectSetString(0,name,OBJPROP_TEXT,value);
}

void EAPanelFrame()
{
   if(!ShowEAStatusPanel)
   {
      DeleteEAPanel();
      return;
   }
   EAPanelRectangle("BACKGROUND",PanelX,PanelY,PanelWidth,GV_EA_PANEL_HEIGHT,
                    PanelBackgroundColor,PanelBorderColor);
   EAPanelRectangle("HEADER",PanelX+1,PanelY+1,PanelWidth-2,34,
                    PanelHeaderColor,PanelHeaderColor);
   EAPanelRectangle("MODE_BOX",PanelX+10,PanelY+66,PanelWidth-20,32,
                    PanelSectionColor,PanelSectionColor);
   EAPanelRectangle("ENTRY_BOX",PanelX+10,PanelY+103,PanelWidth-20,32,
                    PanelSectionColor,PanelBorderColor);
   EAPanelRectangle("POSITION_BOX",PanelX+10,PanelY+185,PanelWidth-20,32,
                    PanelSectionColor,PanelSectionColor);
   EAPanelRectangle("ACTION_BOX",PanelX+10,PanelY+244,PanelWidth-20,32,
                    PanelSectionColor,PanelBorderColor);
   EAPanelLabel("TITLE",PanelX+14,PanelY+8,"XVISION GOLD VELOCITY AI EA",
                PanelPrimaryTextColor,PanelFontSize+2,"Segoe UI Semibold");
   EAPanelLabel("ENGINE",PanelX+14,PanelY+38,
                 "V7  |  ADAPTIVE STRICT + EARLY  |  CLOSED H1 > M5 > M1",
                PanelSecondaryTextColor,PanelFontSize,"Segoe UI");
}

color EAStateColor(GVResult &signal)
{
   if(signal.qualified) return(signal.direction>0 ? CleanBuyEntryColor : CleanSellEntryColor);
   if(signal.state==GV_STATE_H1_CONFLICT || signal.state==GV_STATE_EXHAUSTING ||
      signal.state==GV_STATE_REVERSING || signal.state==GV_STATE_OVEREXTENDED) return(clrOrangeRed);
   if(signal.state==GV_STATE_BUILDING || signal.state==GV_STATE_M5_SETUP_WAIT ||
      signal.state==GV_STATE_M1_TRIGGER_WAIT) return(clrGold);
   return(PanelPrimaryTextColor);
}

string OperationalEntryStatus(GVResult &signal,const bool clean,const string cleanStatus)
{
   if(!clean) return(cleanStatus);
   if(!EnableAutomaticEntries) return("READY - AUTO ENTRY OFF");
   if(signal.direction>0 && !AllowBuySignals) return("WAIT - BUY ENTRIES DISABLED");
   if(signal.direction<0 && !AllowSellSignals) return("WAIT - SELL ENTRIES DISABLED");
   if(FindManagedTicket()>=0) return("WAIT - MANAGED POSITION ALREADY OPEN");
   if(LateFridayEntryBlocked()) return("WAIT - FRIDAY ENTRY CUTOFF");
   if(!IsTradeAllowed()) return("WAIT - AUTOTRADING OFF OR TRADE CONTEXT BUSY");
   datetime latest=MathMax(g_lastEntryTime,LatestEntryTime());
   if(MinimumMinutesBetweenEntries>0 && latest>0 &&
      TimeCurrent()-latest<MinimumMinutesBetweenEntries*60)
      return("WAIT - ENTRY COOLDOWN");
   if(MaximumTradesPerBrokerDay>0 && TradesOpenedToday()>=MaximumTradesPerBrokerDay)
      return("WAIT - DAILY TRADE LIMIT");
   if(MaximumDailyLossCurrency>0.0 && ClosedPnLToday()<=-MaximumDailyLossCurrency)
      return("WAIT - DAILY LOSS LIMIT");
   return("READY - AUTO ENTRY ARMED");
}

void UpdateEAEntryLine(GVResult &signal,const bool clean,const string status)
{
   if(!ShowCleanEntryLine || !signal.valid || !signal.qualified || signal.referenceEntry<=0.0)
   {
      DeleteEAEntryLine();
      return;
   }
   string entryName=EAEntryObjectName();
   if(ObjectFind(0,entryName)<0)
      ObjectCreate(0,entryName,OBJ_HLINE,0,0,signal.referenceEntry);
   color lineColor=(clean ?
      (signal.direction>0 ? CleanBuyEntryColor : CleanSellEntryColor) : clrDimGray);
   int digits=(int)MarketInfo(Symbol(),MODE_DIGITS);
   ObjectSetDouble(0,entryName,OBJPROP_PRICE1,signal.referenceEntry);
   ObjectSetInteger(0,entryName,OBJPROP_COLOR,lineColor);
   ObjectSetInteger(0,entryName,OBJPROP_STYLE,(clean ? STYLE_SOLID : STYLE_DASH));
   ObjectSetInteger(0,entryName,OBJPROP_WIDTH,(clean ? 2 : 1));
   ObjectSetInteger(0,entryName,OBJPROP_BACK,false);
   ObjectSetInteger(0,entryName,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,entryName,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,entryName,OBJPROP_HIDDEN,true);
   ObjectSetString(0,entryName,OBJPROP_TEXT,
      "EA "+GVEntryModeText(signal.entryMode)+" "+GVDirectionText(signal.direction)+" ENTRY  "+
      DoubleToString(signal.referenceEntry,digits)+"  |  "+status);
}

void UpdatePanel()
{
   double executionPrice=0.0,deviation=0.0,spread=0.0;
   string cleanStatus="";
   bool clean=CleanEntryStatus(g_lastSignal,executionPrice,deviation,spread,cleanStatus);
   string operationStatus=OperationalEntryStatus(g_lastSignal,clean,cleanStatus);
   UpdateEAEntryLine(g_lastSignal,clean,operationStatus);
   if(!ShowEAStatusPanel)
   {
      DeleteEAPanel();
      return;
   }

   EAPanelFrame();
   string orderText="NONE";
   int ticket=FindManagedTicket();
   if(ticket>=0 && OrderSelect(ticket,SELECT_BY_TICKET))
      orderText=StringFormat("%s %s  #%d  |  %.2f LOT  |  MOVE $%.2f  |  P/L %.2f",
         GVEntryModeText(SelectedOrderEntryMode()),(OrderType()==OP_BUY ? "BUY" : "SELL"),ticket,OrderLots(),
         ProfitMovementForSelectedOrder(),OrderProfit()+OrderSwap()+OrderCommission());

   color modeColor=(EnableAutomaticEntries ? clrLimeGreen : clrGold);
   string mode=(EnableAutomaticEntries ? "AUTO ENTRY ENABLED" : "AUTO ENTRY DISABLED");
   string h1=(g_lastSignal.valid && g_lastSignal.h1Alignment>MinimumH1GapATR &&
              g_lastSignal.h1Slope>MinimumH1SlopeATR ? "ALIGNED" :
              (g_lastSignal.valid ? "WAIT" : "DATA"));
   color h1Color=(h1=="ALIGNED" ? clrLimeGreen : (h1=="WAIT" ? clrOrangeRed : clrGold));
   string direction=(g_lastSignal.valid && g_lastSignal.qualified ?
      GVDirectionText(g_lastSignal.direction) : "WAIT");
   string entryLevel="--";
   if(g_lastSignal.valid && g_lastSignal.qualified)
      entryLevel=DoubleToString(g_lastSignal.referenceEntry,(int)MarketInfo(Symbol(),MODE_DIGITS));
   string signalMode=(g_lastSignal.valid && g_lastSignal.qualified ?
      GVEntryModeText(g_lastSignal.entryMode) : "NONE");
   string entryText="ENGINE  "+signalMode+"  |  DIRECTION  "+direction+
                    "  |  ENTRY  "+entryLevel+"  |  "+operationStatus;
   if(g_lastSignal.valid && g_lastSignal.qualified && executionPrice>0.0)
      entryText+="  |  DEV $"+DoubleToString(deviation,2)+"  |  SPREAD $"+DoubleToString(spread,2);
   color entryColor=(clean ?
      (g_lastSignal.direction>0 ? CleanBuyEntryColor : CleanSellEntryColor) : clrGold);
   color stateColor=(g_lastSignal.valid ? EAStateColor(g_lastSignal) : clrGold);
   color actionColor=PanelSecondaryTextColor;
   if(StringFind(g_lastAction,"OPENED")>=0) actionColor=clrLimeGreen;
   else if(StringFind(g_lastAction,"FAILED")>=0 || StringFind(g_lastAction,"BLOCKED")>=0 ||
           StringFind(g_lastAction,"ABORTED")>=0) actionColor=clrOrangeRed;

   EAPanelLabel("CONTEXT",PanelX+14,PanelY+53,
                Symbol()+"  |  CHART "+EATimeframeText(Period())+"  |  ENGINE CLOSED M1/M5/H1",
                PanelSecondaryTextColor,PanelFontSize,"Segoe UI");
   EAPanelLabel("MODE",PanelX+20,PanelY+73,mode,
                modeColor,PanelFontSize+1,"Segoe UI Semibold");
   EAPanelLabel("SIGNAL",PanelX+220,PanelY+74,
                (g_lastSignal.valid ? GVStateText(g_lastSignal.state) : "WAITING FOR DATA"),
                stateColor,PanelFontSize,"Segoe UI Semibold");
   EAPanelLabel("H1",PanelX+PanelWidth-132,PanelY+74,"H1  "+h1,h1Color,
                PanelFontSize,"Segoe UI Semibold");
   EAPanelLabel("ENTRY",PanelX+20,PanelY+111,entryText,entryColor,
                PanelFontSize,"Segoe UI Semibold");
   if(g_lastSignal.valid)
   {
      EAPanelLabel("PROB",PanelX+20,PanelY+143,
                   "H1 CONTEXT   GAP "+DoubleToString(g_lastSignal.h1Alignment,2)+
                   "  SLOPE "+DoubleToString(g_lastSignal.h1Slope,2)+
                   "  EFF "+DoubleToString(100.0*g_lastSignal.h1Efficiency,1)+
                   "%  PERSIST "+DoubleToString(4.0*g_lastSignal.h1Persistence,0)+"/4",
                   PanelPrimaryTextColor,PanelFontSize,"Segoe UI");
      EAPanelLabel("PATH",PanelX+20,PanelY+164,
                   "M5 EFF "+DoubleToString(100.0*g_lastSignal.pathQuality,1)+
                   "% COH "+DoubleToString(100.0*g_lastSignal.m5Coherence,0)+
                    "%  |  M1 STR "+DoubleToString(g_lastSignal.velocityM1,2)+
                   " ACC "+DoubleToString(g_lastSignal.acceleration,2)+
                   " COH "+DoubleToString(100.0*g_lastSignal.m1Coherence,0)+
                   "%  "+g_lastSignal.triggerPattern,
                   PanelPrimaryTextColor,PanelFontSize,"Segoe UI");
   }
   else
   {
      EAPanelLabel("PROB",PanelX+20,PanelY+143,"H1 GATE     WAITING FOR CLOSED H1 DATA",
                   PanelSecondaryTextColor,PanelFontSize,"Segoe UI");
      EAPanelLabel("PATH",PanelX+20,PanelY+164,"M5 SETUP / M1 TRIGGER     WAITING",
                   PanelSecondaryTextColor,PanelFontSize,"Segoe UI");
   }
   EAPanelLabel("POSITION",PanelX+20,PanelY+193,"POSITION  "+orderText,
                (ticket>=0 ? clrDeepSkyBlue : PanelSecondaryTextColor),PanelFontSize,"Segoe UI Semibold");
   EAPanelLabel("MANAGEMENT",PanelX+20,PanelY+223,
                "MANAGEMENT  "+ProfitManagementText()+"  |  MAGIC "+IntegerToString(MagicNumber)+
                "  |  TRADES TODAY "+IntegerToString(TradesOpenedToday()),
                PanelPrimaryTextColor,PanelFontSize,"Segoe UI");
   EAPanelLabel("ACTION",PanelX+20,PanelY+252,"ACTION  "+g_lastAction,
                actionColor,PanelFontSize,"Segoe UI Semibold");
   ChartRedraw(0);
}

void UpdatePanelThrottled(const bool force=false)
{
   datetime now=TimeCurrent();
   if(!force && g_lastPanelUpdate>0 && now-g_lastPanelUpdate<1) return;
   g_lastPanelUpdate=now;
   UpdatePanel();
}

int OnInit()
{
   if(!ValidateInputs()) return(INIT_PARAMETERS_INCORRECT);
   LoadThresholds();
   RefreshAccountCache(true);
   GVResetResult(g_lastSignal);
   GVCalculate(Symbol(),1,g_thresholds,g_lastSignal);
   g_lastEntryTime=LatestEntryTime();
   g_lastM1Bar=(TradeCurrentSignalOnAttach ? 0 : iTime(Symbol(),PERIOD_M1,0));
   g_lastAction=(EnableAutomaticEntries ? "WAITING FOR CLOSED M1 TRIGGER" : "AUTO ENTRY DISABLED");
   CleanupOrphanedPartialGlobals();
   int existingTicket=FindManagedTicket();
   if(existingTicket>=0 && OrderSelect(existingTicket,SELECT_BY_TICKET))
      InitialisePartialStateForSelectedOrder();
   UpdatePanelThrottled(true);
   Print("XVISION Gold Velocity AI EA V7: initialized on ",Symbol(),
         ". Auto entry ",(EnableAutomaticEntries ? "ENABLED" : "DISABLED"),
         ", highest timeframe H1, magic ",MagicNumber,".");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   DeleteEAPanel();
   DeleteEAEntryLine();
}

void OnTick()
{
   if(g_engineBusy) return;
   g_engineBusy=true;
   ManagePositionEveryTick();

   datetime currentM1=iTime(Symbol(),PERIOD_M1,0);
   bool processedClosedM1=false;
   if(currentM1>0 && currentM1!=g_lastM1Bar)
   {
      processedClosedM1=true;
      g_lastM1Bar=currentM1;
      GVCalculate(Symbol(),1,g_thresholds,g_lastSignal);
      bool closed=ProcessVelocityExit(g_lastSignal);
      if(!closed && EntryIsAllowed(g_lastSignal)) SendEntry(g_lastSignal);
   }
   UpdatePanelThrottled(processedClosedM1);
   g_engineBusy=false;
}
//+------------------------------------------------------------------+
