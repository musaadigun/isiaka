//+------------------------------------------------------------------+
//| XVISION_Gold_Velocity_AI_EA_V4.mq4                           |
//| Automated execution of the shared closed-bar velocity engine.    |
//+------------------------------------------------------------------+
#property strict
#property version   "4.00"
#property description "XVISION Gold Velocity AI EA V4 - clean closed-M5 entry, closed-H4 confirmation and flexible management"

// Embedded V2 core: this source compiles without a separate .mqh file.
#ifndef __XVISION_GOLD_VELOCITY_CORE_V2_MQH__
#define __XVISION_GOLD_VELOCITY_CORE_V2_MQH__

// XVISION Gold Velocity AI V2 compact inference engine.
// Closed M5 velocity features; last fully closed H4 bar is the highest
// confirmation timeframe.  No DLL, file, network or Python dependency.

#define GV_FEATURE_COUNT       18
#define GV_TARGET_MOVEMENT     30.0
#define GV_TARGET_HORIZON_MIN  240
#define GV_REQUIRED_M5_BARS    80

#define GV_STATE_NO_TRADE       0
#define GV_STATE_BUILDING       1
#define GV_STATE_GOOD           2
#define GV_STATE_ACCELERATING   3
#define GV_STATE_OVEREXTENDED   4
#define GV_STATE_EXHAUSTING     5
#define GV_STATE_REVERSING      6
#define GV_STATE_DATA_WAIT      7
#define GV_STATE_H4_CONFLICT    8

struct GVThresholds
{
   double minimumP30;
   double minimumContinuation;    // V2: minimum P($10 before $15 stop)
   double maximumExhaustion;      // V2: maximum P($15 stop before $10)
   double minimumProbabilityEdge; // P30 - Pbad
   double minimumEfficiencyM15;   // V2: one-hour path efficiency
   double maximumShockRatio;
   double maximumVelocityStrength;
   bool   requireH4Alignment;
};

struct GVResult
{
   bool     valid;
   bool     qualified;
   int      direction;
   int      state;
   datetime signalTime;
   double   referenceEntry;
   double   confidence;
   double   probability10;
   double   probability20;
   double   probability30;
   double   continuationProbability;
   double   exhaustionProbability;
   double   tradeableReach;
   double   stopRiskMovement;
   double   atrM5;
   double   velocityM5;
   double   velocityM15;
   double   velocityH1;
   double   h4Alignment;
   double   pathQuality;
   double   acceleration;
   double   velocityStrength;
   double   shockRatio;
   string   reason;
};

double GV_MEAN[GV_FEATURE_COUNT] =
{
   0.374181123796594,0.350330800400409,0.424263222321453,0.41614406597278,0.368859749477103,
   0.298510679954531,0.242475490091068,0.277889161672146,0.141485127523914,0.743233233868746,
   0.184659574426205,1.00161698586867,1.01009428321479,-0.946420422883488,0.751243307303245,
   0.0862128675148545,0.0552027853267929,0.185915108565955
};

double GV_SCALE[GV_FEATURE_COUNT] =
{
   0.310848596415106,0.555723499527384,0.487189391734892,0.468673138239048,0.48275072739271,
   0.537955510647334,0.623531488982057,0.189951073101989,0.103637703828047,0.116066490605106,
   0.386000932938842,0.44574724815579,0.284534020101779,0.683320796659603,0.198243871360218,
   0.896188210101405,0.23678597286172,0.620764392355243
};

double GV_W_P10[GV_FEATURE_COUNT] =
{
   -0.0871162160325488,0.0138523014478107,-0.00824790409587448,0.0099908332607123,-0.0449774950154227,
   -0.301687141439503,-0.303112718684833,0.0111775578817596,-0.0502977735553706,-0.00326921236262372,
   0.0092850324728807,0.098956742803495,-0.00397388687080714,-0.00211674822448152,0.030244739550231,
   -0.0465826023025315,0.288026598161509,0.947157952956155
};

double GV_W_P20[GV_FEATURE_COUNT] =
{
   -0.0763434113399279,0.0186244397461443,-0.0121386459238844,0.0294602178157844,-0.00320756675009526,
   -0.306624654456992,-0.348801280877247,-0.00136387039248372,-0.0820778164026169,0.0157983796503911,
   -0.00827991616524101,0.0963928039276705,-0.0249031387409481,-0.0385191522692936,0.0229945752764106,
   -0.103902485137147,0.314621975091277,0.989186994212931
};

double GV_W_P30[GV_FEATURE_COUNT] =
{
   -0.0515894547911208,0.0216703433579721,0.0140912030303844,0.0162253175301388,0.0875924885777673,
   -0.302169073793308,-0.396829467131808,0.0105576909985007,-0.198796523127003,0.0536553876026269,
   -0.0270173179219084,0.089822900424633,-0.0693287391399023,-0.112781387074275,0.0217320691438533,
   -0.184270801739023,0.353636873149091,1.00701379829479
};

double GV_W_BAD[GV_FEATURE_COUNT] =
{
   0.123309780587141,0.0135168122496239,0.0348849047154786,-0.00980593571445967,0.144772768027678,
   0.252551025818724,0.290395632530969,-0.029905068070795,-0.0558959396015299,-0.0177364131345675,
   -0.0329645652553512,-0.0138605738090414,0.142437896559029,-0.0950582000720443,-0.00555806923429172,
   0.0831733906377258,-0.281128025206671,-0.931010112614693
};

#define GV_B_P10  -0.25566355641265
#define GV_B_P20  -1.37079235407647
#define GV_B_P30  -2.2043970118605
#define GV_B_BAD  -0.895915987192757

void GVDefaultThresholds(GVThresholds &thresholds)
{
   thresholds.minimumP30              = 0.20000000;
   thresholds.minimumContinuation     = 0.70000000;
   thresholds.maximumExhaustion       = 1.00;
   thresholds.minimumProbabilityEdge  = -0.30000000;
   thresholds.minimumEfficiencyM15    = 0.05;
   thresholds.maximumShockRatio       = 2.50;
   thresholds.maximumVelocityStrength = 2.50;
   thresholds.requireH4Alignment      = true;
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

string GVStateText(const int state)
{
   if(state==GV_STATE_BUILDING)     return("BUILDING");
   if(state==GV_STATE_GOOD)         return("GOOD VELOCITY");
   if(state==GV_STATE_ACCELERATING) return("ACCELERATING");
   if(state==GV_STATE_OVEREXTENDED) return("OVEREXTENDED");
   if(state==GV_STATE_EXHAUSTING)   return("STOP RISK");
   if(state==GV_STATE_REVERSING)    return("REVERSING");
   if(state==GV_STATE_DATA_WAIT)    return("WAITING FOR DATA");
   if(state==GV_STATE_H4_CONFLICT)  return("H4 CONFLICT");
   return("NO TRADE");
}

void GVResetResult(GVResult &result)
{
   result.valid=false;
   result.qualified=false;
   result.direction=0;
   result.state=GV_STATE_DATA_WAIT;
   result.signalTime=0;
   result.referenceEntry=0.0;
   result.confidence=0.0;
   result.probability10=0.0;
   result.probability20=0.0;
   result.probability30=0.0;
   result.continuationProbability=0.0;
   result.exhaustionProbability=0.0;
   result.tradeableReach=0.0;
   result.stopRiskMovement=0.0;
   result.atrM5=0.0;
   result.velocityM5=0.0;
   result.velocityM15=0.0;
   result.velocityH1=0.0;
   result.h4Alignment=0.0;
   result.pathQuality=0.0;
   result.acceleration=0.0;
   result.velocityStrength=0.0;
   result.shockRatio=0.0;
   result.reason="INSUFFICIENT CLOSED M5/H4 DATA";
}

double GVLinear(double &features[],double &weights[],const double intercept)
{
   double value=intercept;
   for(int i=0;i<GV_FEATURE_COUNT;i++)
   {
      double scale=GV_SCALE[i];
      if(scale<=0.0) scale=1.0;
      value+=weights[i]*((features[i]-GV_MEAN[i])/scale);
   }
   return(value);
}

double GVProbability(double &features[],double &weights[],const double intercept)
{
   double z=GVClamp(GVLinear(features,weights,intercept),-35.0,35.0);
   return(1.0/(1.0+MathExp(-z)));
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

bool GVCalculate(const string symbol,const int shift,GVThresholds &thresholds,GVResult &result)
{
   GVResetResult(result);
   if(shift<1 || iBars(symbol,PERIOD_M5)<shift+GV_REQUIRED_M5_BARS || iBars(symbol,PERIOD_H4)<40)
      return(false);

   datetime signalOpen=iTime(symbol,PERIOD_M5,shift);
   if(signalOpen<=0) return(false);
   datetime decisionClose=signalOpen+5*60;
   int containingH4=iBarShift(symbol,PERIOD_H4,decisionClose,false);
   int h4Shift=containingH4+1;
   if(containingH4<0 || h4Shift+22>=iBars(symbol,PERIOD_H4)) return(false);

   double atr12=GVATR(symbol,PERIOD_M5,12,shift);
   double atr48=GVATR(symbol,PERIOD_M5,48,shift);
   if(atr12<=0.0 || atr48<=0.0) return(false);

   int windows[6]={1,3,6,12,24,48};
   double velocity[6];
   ArrayInitialize(velocity,0.0);
   for(int w=0;w<6;w++) velocity[w]=GVNet(symbol,PERIOD_M5,windows[w],shift)/(atr12*MathSqrt(windows[w]));
   double composite=0.25*velocity[0]+0.25*velocity[1]+0.20*velocity[2]+0.15*velocity[3]+0.10*velocity[4]+0.05*velocity[5];
   int direction=(composite>=0.0 ? 1 : -1);

   double range3=0.0,range12=0.0,body12=0.0;
   int alignedBodies=0;
   double high12=-DBL_MAX,low12=DBL_MAX;
   for(int b=0;b<12;b++)
   {
      double tr=GVTrueRange(symbol,PERIOD_M5,shift+b);
      range12+=tr;
      if(b<3) range3+=tr;
      double op=iOpen(symbol,PERIOD_M5,shift+b);
      double cl=iClose(symbol,PERIOD_M5,shift+b);
      body12+=cl-op;
      if((direction>0 && cl-op>0.0) || (direction<0 && cl-op<0.0)) alignedBodies++;
      high12=MathMax(high12,iHigh(symbol,PERIOD_M5,shift+b));
      low12=MathMin(low12,iLow(symbol,PERIOD_M5,shift+b));
   }
   range3=MathMax(range3,0.01);
   range12=MathMax(range12,0.01);
   double efficiency3=MathAbs(GVNet(symbol,PERIOD_M5,3,shift))/range3;
   double efficiency12=MathAbs(GVNet(symbol,PERIOD_M5,12,shift))/range12;
   double persistence12=alignedBodies/12.0;
   double recent3=GVNet(symbol,PERIOD_M5,3,shift)/3.0;
   double prior9=(iClose(symbol,PERIOD_M5,shift+3)-iOpen(symbol,PERIOD_M5,shift+11))/9.0;
   double acceleration=direction*(recent3-prior9)/atr12;
   double shock=GVTrueRange(symbol,PERIOD_M5,shift)/atr12;
   double volatilityRatio=atr12/MathMax(atr48,0.01);
   double close=iClose(symbol,PERIOD_M5,shift);
   double pullback=(direction>0 ? (close-high12)/atr12 : (low12-close)/atr12);
   int alignedVelocities=0;
   for(int v=0;v<6;v++) if(direction*velocity[v]>0.0) alignedVelocities++;
   double coherence=alignedVelocities/6.0;

   double h4Atr=GVATR(symbol,PERIOD_H4,14,h4Shift);
   if(h4Atr<=0.0) return(false);
   double ema8=iMA(symbol,PERIOD_H4,8,0,MODE_EMA,PRICE_CLOSE,h4Shift);
   double ema8Previous=iMA(symbol,PERIOD_H4,8,0,MODE_EMA,PRICE_CLOSE,h4Shift+1);
   double ema21=iMA(symbol,PERIOD_H4,21,0,MODE_EMA,PRICE_CLOSE,h4Shift);
   double h4Gap=direction*(ema8-ema21)/h4Atr;
   double h4Slope=direction*(ema8-ema8Previous)/h4Atr;
   double h4Body=direction*(iClose(symbol,PERIOD_H4,h4Shift)-iOpen(symbol,PERIOD_H4,h4Shift))/h4Atr;
   datetime h4Close=iTime(symbol,PERIOD_H4,h4Shift)+4*60*60;
   double h4AgeHours=(decisionClose-h4Close)/3600.0;
   if(h4AgeHours<0.0 || h4AgeHours>12.0) return(false);

   double features[GV_FEATURE_COUNT];
   features[0]=MathAbs(composite);
   features[1]=direction*velocity[0];
   features[2]=direction*velocity[1];
   features[3]=direction*velocity[2];
   features[4]=direction*velocity[3];
   features[5]=direction*velocity[4];
   features[6]=direction*velocity[5];
   features[7]=efficiency3;
   features[8]=efficiency12;
   features[9]=persistence12;
   features[10]=acceleration;
   features[11]=shock;
   features[12]=volatilityRatio;
   features[13]=pullback;
   features[14]=coherence;
   features[15]=h4Gap;
   features[16]=h4Slope;
   features[17]=h4Body;

   for(int f=0;f<GV_FEATURE_COUNT;f++) if(!MathIsValidNumber(features[f])) return(false);
   double p10=GVProbability(features,GV_W_P10,GV_B_P10);
   double p20=MathMin(p10,GVProbability(features,GV_W_P20,GV_B_P20));
   double p30=MathMin(p20,GVProbability(features,GV_W_P30,GV_B_P30));
   double pBad=GVProbability(features,GV_W_BAD,GV_B_BAD);
   double edge=p30-pBad;
   double strength=MathAbs(composite);
   bool h4OK=(!thresholds.requireH4Alignment || h4Gap>0.0);
   bool qualified=(p30>=thresholds.minimumP30 &&
                   p10>=thresholds.minimumContinuation &&
                   pBad<=thresholds.maximumExhaustion &&
                   edge>=thresholds.minimumProbabilityEdge &&
                   h4OK && efficiency12>=thresholds.minimumEfficiencyM15 &&
                   strength>=0.10 && strength<=thresholds.maximumVelocityStrength &&
                   shock<=thresholds.maximumShockRatio);

   int state=GV_STATE_NO_TRADE;
   string reason="MODEL THRESHOLD NOT MET";
   if(!h4OK) { state=GV_STATE_H4_CONFLICT; reason="DIRECTION CONFLICTS WITH CLOSED H4"; }
   else if(strength>thresholds.maximumVelocityStrength || shock>thresholds.maximumShockRatio)
      { state=GV_STATE_OVEREXTENDED; reason="MOVE IS OVEREXTENDED"; }
   else if(qualified)
   {
      state=(acceleration>0.15 && coherence>=0.833 ? GV_STATE_ACCELERATING : GV_STATE_GOOD);
      reason="P10/P30, RISK AND CLOSED H4 FILTERS PASSED";
   }
   else if(pBad>0.50) { state=GV_STATE_EXHAUSTING; reason="STOP-FIRST RISK IS ELEVATED"; }
   else if(acceleration<0.0) { state=GV_STATE_REVERSING; reason="VELOCITY IS DECELERATING"; }
   else if(direction*velocity[1]>0.0 && direction*velocity[2]>0.0)
      { state=GV_STATE_BUILDING; reason="VELOCITY IS BUILDING"; }

   result.valid=true;
   result.qualified=qualified;
   result.direction=direction;
   result.state=state;
   result.signalTime=signalOpen;
   result.referenceEntry=close;
   result.confidence=100.0*(0.70*p10+0.30*p30);
   result.probability10=p10;
   result.probability20=p20;
   result.probability30=p30;
   result.continuationProbability=1.0-pBad;
   result.exhaustionProbability=pBad;
   // Survival-weighted reach and stop-risk scores are transparent functions
   // of the calibrated probabilities; they are not profit targets or P/L.
   result.tradeableReach=10.0*(p10+p20+p30);
   result.stopRiskMovement=15.0*pBad;
   result.atrM5=atr12;
   result.velocityM5=direction*velocity[0];
   result.velocityM15=direction*velocity[1];
   result.velocityH1=direction*velocity[3];
   result.h4Alignment=h4Gap;
   result.pathQuality=efficiency12;
   result.acceleration=acceleration;
   result.velocityStrength=strength;
   result.shockRatio=shock;
   result.reason=reason;
   return(true);
}

#endif
// End embedded V2 core.

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
input double InitialStopLossMovement      = 15.0; // 0 permits no initial SL in fixed-lot mode

// ------------------------ 3. PROFIT MANAGEMENT ---------------------
// Every feature below is optional.  With all disabled, management is manual.
input bool   UseFixedTakeProfit           = false;
input double FixedTakeProfitMovement      = 30.0;

input bool   UseBreakEven                 = false;
input double BreakEvenActivationMovement  = 10.0;
input double BreakEvenLockMovement        = 1.0;

input bool   UseTrailingStop              = true;
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
input int    MaximumHoldingMinutes        = 240; // 0 disables; model horizon is 240

// ------------------------ 4. ENTRY SAFETY --------------------------
input bool   TradeCurrentSignalOnAttach   = false;
input int    MinimumMinutesBetweenEntries = 15;
input double MaximumEntryDeviationMovement= 3.0;  // absolute Gold price movement; 0 disables
input double MaximumSpreadMovement        = 2.0;  // absolute Gold price movement; 0 disables
input int    MaximumTradesPerBrokerDay     = 3;    // 0 disables
input double MaximumDailyLossCurrency      = 0.0;  // 0 disables new-entry block

// ------------------------ 5. MODEL FILTERS (ADVANCED) ---------------
input bool   RequireClosedH4Alignment      = true;
input double MinimumProbability30Percent  = 20.0;
input double MinimumProbability10Percent  = 70.0;
input double MaximumBadBefore10Percent     = 100.0;
input double MinimumProbabilityEdgePct    = -30.0;
input double MinimumH1PathEfficiencyPct    = 5.0;
input double MaximumShockRatio             = 2.5;
input double MaximumVelocityStrength       = 2.5;

// ------------------------ 6. EXECUTION (ADVANCED) -------------------
input int    SlippagePoints               = 50;
input int    MagicNumber                  = 26080740;
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
input bool   EnableEntryPopupAlert        = true;
input bool   EnableEntryPushNotification  = false;

GVThresholds g_thresholds;
GVResult g_lastSignal;
datetime g_lastM5Bar=0;
datetime g_lastEntryTime=0;
string g_lastAction="INITIALISING";
bool g_engineBusy=false;

#define GV_EA_OBJECT_PREFIX "XVISION_GV_EA_V4_"
#define GV_EA_PANEL_HEIGHT 286

double ClampValue(const double value,const double lower,const double upper)
{
   return(MathMax(lower,MathMin(upper,value)));
}

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
   lots=MathMin(maximum,lots);
   if(lots<minimum-1e-10) return(0.0);
   return(NormalizeDouble(lots,LotDigits(step)));
}

bool PercentInputValid(const double value)
{
   return(value>=0.0 && value<=100.0);
}

bool ValidateInputs()
{
   if(!GVIsGoldSymbol(Symbol()))
   {
      Print("XVISION Gold Velocity EA: attach only to a Gold/XAU symbol.");
      return(false);
   }
   if(!PercentInputValid(MinimumProbability30Percent) ||
      !PercentInputValid(MinimumProbability10Percent) ||
      !PercentInputValid(MaximumBadBefore10Percent) ||
      !PercentInputValid(MinimumH1PathEfficiencyPct))
   {
      Print("XVISION Gold Velocity EA: probability and efficiency inputs must be 0..100.");
      return(false);
   }
   if(MinimumProbabilityEdgePct<-100.0 || MinimumProbabilityEdgePct>100.0 ||
      MaximumShockRatio<=0.0 || MaximumVelocityStrength<=0.0 ||
      MinimumMinutesBetweenEntries<0 || MaximumEntryDeviationMovement<0.0 ||
      MaximumSpreadMovement<0.0 || MaximumTradesPerBrokerDay<0 ||
      MaximumDailyLossCurrency<0.0 || SlippagePoints<0 || MagicNumber<=0)
      return(false);
   if(PanelX<0 || PanelY<0 || PanelWidth<500 || PanelWidth>1000 ||
      PanelFontSize<8 || PanelFontSize>14)
      return(false);
   if(FixedLotSize<=0.0 || RiskPercentOfBalance<=0.0 || RiskPercentOfBalance>100.0 ||
      InitialStopLossMovement<0.0)
      return(false);
   if(LotSizingMode==GV_RISK_PERCENT && InitialStopLossMovement<=0.0)
   {
      Print("XVISION Gold Velocity EA: risk-percent sizing requires a positive initial stop.");
      return(false);
   }
   if(UseFixedTakeProfit && FixedTakeProfitMovement<=0.0) return(false);
   if(UseBreakEven && (BreakEvenActivationMovement<=0.0 || BreakEvenLockMovement<0.0 ||
      BreakEvenLockMovement>=BreakEvenActivationMovement)) return(false);
   if(UseTrailingStop && (TrailingActivationMovement<0.0 || TrailingDistanceMovement<=0.0 ||
      TrailingATRPeriod<2 || TrailingATRMultiplier<=0.0 || TrailingStepMovement<=0.0)) return(false);
   if(MaximumHoldingMinutes<0) return(false);

   if(UsePartialProfits)
   {
      double totalPercent=0.0;
      double previousLevel=0.0;
      if(EnablePartialLevel1)
      {
         if(PartialLevel1Movement<=0.0 || PartialLevel1Percent<=0.0 || PartialLevel1Percent>=100.0) return(false);
         previousLevel=PartialLevel1Movement;
         totalPercent+=PartialLevel1Percent;
      }
      if(EnablePartialLevel2)
      {
         if(PartialLevel2Movement<=previousLevel || PartialLevel2Percent<=0.0 || PartialLevel2Percent>=100.0) return(false);
         previousLevel=PartialLevel2Movement;
         totalPercent+=PartialLevel2Percent;
      }
      if(EnablePartialLevel3)
      {
         if(PartialLevel3Movement<=previousLevel || PartialLevel3Percent<=0.0 || PartialLevel3Percent>=100.0) return(false);
         totalPercent+=PartialLevel3Percent;
      }
      if(totalPercent>=100.0)
      {
         Print("XVISION Gold Velocity EA: enabled partial percentages must total less than 100%.");
         return(false);
      }
   }
   return(true);
}

void LoadThresholds()
{
   g_thresholds.minimumP30=MinimumProbability30Percent/100.0;
   g_thresholds.minimumContinuation=MinimumProbability10Percent/100.0;
   g_thresholds.maximumExhaustion=MaximumBadBefore10Percent/100.0;
   g_thresholds.minimumProbabilityEdge=MinimumProbabilityEdgePct/100.0;
   g_thresholds.minimumEfficiencyM15=MinimumH1PathEfficiencyPct/100.0;
   g_thresholds.maximumShockRatio=MaximumShockRatio;
   g_thresholds.maximumVelocityStrength=MaximumVelocityStrength;
   g_thresholds.requireH4Alignment=RequireClosedH4Alignment;
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

int TradesOpenedToday()
{
   datetime start=BrokerDayStart();
   datetime seen[];
   int count=0;
   for(int h=OrdersHistoryTotal()-1;h>=0;h--)
   {
      if(!OrderSelect(h,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderSymbol()==Symbol() && OrderMagicNumber()==MagicNumber &&
         (OrderType()==OP_BUY || OrderType()==OP_SELL) && OrderOpenTime()>=start)
      {
         bool duplicate=false;
         for(int s=0;s<count;s++) if(seen[s]==OrderOpenTime()) { duplicate=true; break; }
         if(!duplicate)
         {
            ArrayResize(seen,count+1);
            seen[count]=OrderOpenTime();
            count++;
         }
      }
   }
   for(int t=OrdersTotal()-1;t>=0;t--)
   {
      if(!OrderSelect(t,SELECT_BY_POS,MODE_TRADES)) continue;
      if(IsManagedSelectedOrder() && OrderOpenTime()>=start)
      {
         bool duplicate=false;
         for(int s=0;s<count;s++) if(seen[s]==OrderOpenTime()) { duplicate=true; break; }
         if(!duplicate)
         {
            ArrayResize(seen,count+1);
            seen[count]=OrderOpenTime();
            count++;
         }
      }
   }
   return(count);
}

double ClosedPnLToday()
{
   datetime start=BrokerDayStart();
   double pnl=0.0;
   for(int h=OrdersHistoryTotal()-1;h>=0;h--)
   {
      if(!OrderSelect(h,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderSymbol()==Symbol() && OrderMagicNumber()==MagicNumber &&
         (OrderType()==OP_BUY || OrderType()==OP_SELL) && OrderCloseTime()>=start)
         pnl+=OrderProfit()+OrderSwap()+OrderCommission();
   }
   return(pnl);
}

datetime LatestEntryTime()
{
   datetime latest=0;
   for(int h=OrdersHistoryTotal()-1;h>=0;h--)
   {
      if(!OrderSelect(h,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderSymbol()==Symbol() && OrderMagicNumber()==MagicNumber && OrderOpenTime()>latest)
         latest=OrderOpenTime();
   }
   for(int t=OrdersTotal()-1;t>=0;t--)
   {
      if(!OrderSelect(t,SELECT_BY_POS,MODE_TRADES)) continue;
      if(IsManagedSelectedOrder() && OrderOpenTime()>latest) latest=OrderOpenTime();
   }
   return(latest);
}

string PositionKey()
{
   return(StringFormat("XVG.%d.%d.%d",AccountNumber(),MagicNumber,(int)OrderOpenTime()));
}

double ProfitMovementForSelectedOrder()
{
   RefreshRates();
   if(OrderType()==OP_BUY) return(Bid-OrderOpenPrice());
   if(OrderType()==OP_SELL) return(OrderOpenPrice()-Ask);
   return(0.0);
}

double CalculateLots()
{
   if(LotSizingMode==GV_FIXED_LOTS) return(NormaliseLots(FixedLotSize));
   double tickValue=MarketInfo(Symbol(),MODE_TICKVALUE);
   double tickSize=MarketInfo(Symbol(),MODE_TICKSIZE);
   if(tickSize<=0.0) tickSize=Point;
   if(tickValue<=0.0 || InitialStopLossMovement<=0.0) return(0.0);
   double riskMoney=AccountBalance()*RiskPercentOfBalance/100.0;
   double riskPerLot=(InitialStopLossMovement/tickSize)*tickValue;
   if(riskPerLot<=0.0) return(0.0);
   double rawLots=riskMoney/riskPerLot;
   if(rawLots<MarketInfo(Symbol(),MODE_MINLOT)) return(0.0); // never round risk upward
   return(NormaliseLots(rawLots));
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

bool CloseSelectedOrder(const string reason)
{
   int ticket=OrderTicket();
   double lots=OrderLots();
   RefreshRates();
   double price=(OrderType()==OP_BUY ? Bid : Ask);
   ResetLastError();
   if(!OrderClose(ticket,lots,price,SlippagePoints,clrSilver))
   {
      int error=GetLastError();
      g_lastAction=StringFormat("CLOSE FAILED %d",error);
      Print("XVISION Gold Velocity EA: close failed, ticket ",ticket,", error ",error,", reason ",reason);
      return(false);
   }
   g_lastAction="CLOSED: "+reason;
   Print("XVISION Gold Velocity EA: closed ticket ",ticket,": ",reason);
   return(true);
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
   status="WAIT - NO QUALIFIED CLOSED-M5 SIGNAL";
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

   double lots=CalculateLots();
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
   if(InitialStopLossMovement>0.0)
      sl=(signal.direction>0 ? entry-InitialStopLossMovement : entry+InitialStopLossMovement);
   if(UseFixedTakeProfit)
      tp=(signal.direction>0 ? entry+FixedTakeProfitMovement : entry-FixedTakeProfitMovement);
   sl=(sl>0.0 ? NormalizeDouble(sl,Digits) : 0.0);
   tp=(tp>0.0 ? NormalizeDouble(tp,Digits) : 0.0);
   if(!StopsRespectBroker(signal.direction,entry,sl,tp))
   {
      g_lastAction="ENTRY BLOCKED: BROKER STOP DISTANCE";
      return(false);
   }

   string comment=StringFormat("XV_GVAI_%d",(int)signal.signalTime);
   ResetLastError();
   int ticket=OrderSend(Symbol(),type,lots,entry,SlippagePoints,sl,tp,comment,MagicNumber,0,
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
      ticket=OrderSend(Symbol(),type,lots,entry,SlippagePoints,0.0,0.0,comment,MagicNumber,0,
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

   if(!OrderSelect(ticket,SELECT_BY_TICKET))
   {
      g_lastAction="ENTRY OPENED; SELECT FAILED";
      return(true);
   }
   double actualOpen=OrderOpenPrice();
   double exactSL=(InitialStopLossMovement>0.0 ?
      (signal.direction>0 ? actualOpen-InitialStopLossMovement : actualOpen+InitialStopLossMovement) : 0.0);
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
         if(InitialStopLossMovement>0.0)
         {
            if(OrderSelect(ticket,SELECT_BY_TICKET)) CloseSelectedOrder("PROTECTIVE STOP COULD NOT BE SET");
            g_lastAction="ENTRY ABORTED: STOP SET FAILED";
            return(false);
         }
      }
   }

   if(OrderSelect(ticket,SELECT_BY_TICKET))
   {
      string key=PositionKey();
      GlobalVariableSet(key+".LOT",OrderLots());
      GlobalVariableSet(key+".P1",0.0);
      GlobalVariableSet(key+".P2",0.0);
      GlobalVariableSet(key+".P3",0.0);
   }
   g_lastEntryTime=TimeCurrent();
   g_lastAction=StringFormat("OPENED %s %.2f LOT",GVDirectionText(signal.direction),lots);
   string message=StringFormat("XVISION Gold Velocity opened %s %.2f lot | P30 %.1f%%",
      GVDirectionText(signal.direction),lots,100.0*signal.probability30);
   if(EnableEntryPopupAlert) Alert(message);
   if(EnableEntryPushNotification) SendNotification(message);
   return(true);
}

bool ProcessPartialLevel(const int levelNumber,const double triggerMovement,const double percent)
{
   int ticket=FindManagedTicket();
   if(ticket<0 || !OrderSelect(ticket,SELECT_BY_TICKET)) return(false);
   string key=PositionKey();
   string flagKey=key+StringFormat(".P%d",levelNumber);
   if(GlobalVariableCheck(flagKey) && GlobalVariableGet(flagKey)>0.5) return(false);
   if(ProfitMovementForSelectedOrder()<triggerMovement) return(false);

   double initialLots=(GlobalVariableCheck(key+".LOT") ? GlobalVariableGet(key+".LOT") : OrderLots());
   double minimum=MarketInfo(Symbol(),MODE_MINLOT);
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(step<=0.0) step=0.01;
   double closeLots=MathFloor((initialLots*percent/100.0+1e-10)/step)*step;
   closeLots=NormalizeDouble(closeLots,LotDigits(step));
   double currentLots=OrderLots();
   if(closeLots<minimum || currentLots-closeLots<minimum-1e-10)
   {
      GlobalVariableSet(flagKey,1.0);
      Print("XVISION Gold Velocity EA: partial level ",levelNumber,
            " skipped because broker minimum lot would be violated.");
      return(false);
   }

   RefreshRates();
   double price=(OrderType()==OP_BUY ? Bid : Ask);
   ResetLastError();
   if(!OrderClose(ticket,closeLots,price,SlippagePoints,clrGold))
   {
      int error=GetLastError();
      Print("XVISION Gold Velocity EA: partial level ",levelNumber," failed, error ",error);
      return(false);
   }
   GlobalVariableSet(flagKey,1.0);
   g_lastAction=StringFormat("PARTIAL %d: %.2f LOT",levelNumber,closeLots);
   return(true);
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
         double atr=iATR(Symbol(),PERIOD_M1,TrailingATRPeriod,0);
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

   double minimumStop=(MarketInfo(Symbol(),MODE_STOPLEVEL)+MarketInfo(Symbol(),MODE_FREEZELEVEL))*Point;
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
   if(ticket<0 || !OrderSelect(ticket,SELECT_BY_TICKET)) return;
   if(MaximumHoldingMinutes>0 && TimeCurrent()-OrderOpenTime()>=MaximumHoldingMinutes*60)
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

bool EntryIsAllowed(GVResult &signal)
{
   if(!EnableAutomaticEntries || !signal.valid || !signal.qualified) return(false);
   if(signal.direction>0 && !AllowBuySignals) return(false);
   if(signal.direction<0 && !AllowSellSignals) return(false);
   if(FindManagedTicket()>=0) return(false);
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
      !UseVelocityExit && MaximumHoldingMinutes<=0) return("MANUAL");
   string text="";
   if(UseFixedTakeProfit) text+="TP ";
   if(UseBreakEven) text+="BE ";
   if(UseTrailingStop) text+="TRAIL ";
   if(UsePartialProfits) text+="PARTIAL ";
   if(UseVelocityExit) text+="VEL-EXIT ";
   if(MaximumHoldingMinutes>0) text+="TIME ";
   return(text);
}

string EATimeframeText(const int timeframe)
{
   if(timeframe==PERIOD_M1) return("M1");
   if(timeframe==PERIOD_M5) return("M5");
   if(timeframe==PERIOD_M15) return("M15");
   if(timeframe==PERIOD_M30) return("M30");
   if(timeframe==PERIOD_H1) return("H1");
   if(timeframe==PERIOD_H4) return("H4");
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
                "V4  |  CLOSED M5 EXECUTION  |  CLOSED H4 CONFIRMATION",
                PanelSecondaryTextColor,PanelFontSize,"Segoe UI");
}

color EAStateColor(GVResult &signal)
{
   if(signal.qualified) return(signal.direction>0 ? CleanBuyEntryColor : CleanSellEntryColor);
   if(signal.state==GV_STATE_H4_CONFLICT || signal.state==GV_STATE_EXHAUSTING ||
      signal.state==GV_STATE_REVERSING || signal.state==GV_STATE_OVEREXTENDED) return(clrOrangeRed);
   if(signal.state==GV_STATE_BUILDING) return(clrGold);
   return(PanelPrimaryTextColor);
}

string OperationalEntryStatus(GVResult &signal,const bool clean,const string cleanStatus)
{
   if(!clean) return(cleanStatus);
   if(!EnableAutomaticEntries) return("READY - AUTO ENTRY OFF");
   if(signal.direction>0 && !AllowBuySignals) return("WAIT - BUY ENTRIES DISABLED");
   if(signal.direction<0 && !AllowSellSignals) return("WAIT - SELL ENTRIES DISABLED");
   if(FindManagedTicket()>=0) return("WAIT - MANAGED POSITION ALREADY OPEN");
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
      "EA CLEAN "+GVDirectionText(signal.direction)+" ENTRY  "+
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
      orderText=StringFormat("%s  #%d  |  %.2f LOT  |  MOVE $%.2f",
         (OrderType()==OP_BUY ? "BUY" : "SELL"),ticket,OrderLots(),ProfitMovementForSelectedOrder());
   if(ticket>=0 && OrderSelect(ticket,SELECT_BY_TICKET))
      orderText+=StringFormat("  |  P/L %.2f",OrderProfit()+OrderSwap()+OrderCommission());

   color modeColor=(EnableAutomaticEntries ? clrLimeGreen : clrGold);
   string mode=(EnableAutomaticEntries ? "AUTO ENTRY ENABLED" : "AUTO ENTRY DISABLED");
   string h4=(g_lastSignal.valid ? (g_lastSignal.h4Alignment>0.0 ? "ALIGNED" : "CONFLICT") : "WAITING");
   color h4Color=(h4=="ALIGNED" ? clrLimeGreen : (h4=="CONFLICT" ? clrOrangeRed : clrGold));
   string direction=(g_lastSignal.valid && g_lastSignal.qualified ?
      GVDirectionText(g_lastSignal.direction) : "WAIT");
   string entryLevel="--";
   if(g_lastSignal.valid && g_lastSignal.qualified)
      entryLevel=DoubleToString(g_lastSignal.referenceEntry,(int)MarketInfo(Symbol(),MODE_DIGITS));
   string entryText="DIRECTION  "+direction+"  |  ENTRY  "+entryLevel+"  |  "+operationStatus;
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
                Symbol()+"  |  CHART "+EATimeframeText(Period())+"  |  ENGINE CLOSED M5",
                PanelSecondaryTextColor,PanelFontSize,"Segoe UI");
   EAPanelLabel("MODE",PanelX+20,PanelY+73,mode,
                modeColor,PanelFontSize+1,"Segoe UI Semibold");
   EAPanelLabel("SIGNAL",PanelX+220,PanelY+74,
                (g_lastSignal.valid ? GVStateText(g_lastSignal.state) : "WAITING FOR DATA"),
                stateColor,PanelFontSize,"Segoe UI Semibold");
   EAPanelLabel("H4",PanelX+PanelWidth-132,PanelY+74,"H4  "+h4,h4Color,
                PanelFontSize,"Segoe UI Semibold");
   EAPanelLabel("ENTRY",PanelX+20,PanelY+111,entryText,entryColor,
                PanelFontSize,"Segoe UI Semibold");
   if(g_lastSignal.valid)
   {
      EAPanelLabel("PROB",PanelX+20,PanelY+143,
                   "MOVE PROBABILITY     $10  "+DoubleToString(100.0*g_lastSignal.probability10,1)+
                   "%     $20  "+DoubleToString(100.0*g_lastSignal.probability20,1)+
                   "%     $30  "+DoubleToString(100.0*g_lastSignal.probability30,1)+"%",
                   PanelPrimaryTextColor,PanelFontSize,"Segoe UI");
      EAPanelLabel("PATH",PanelX+20,PanelY+164,
                   "PATH QUALITY          CONTINUATION  "+DoubleToString(100.0*g_lastSignal.continuationProbability,1)+
                   "%     EXHAUSTION  "+DoubleToString(100.0*g_lastSignal.exhaustionProbability,1)+"%",
                   PanelPrimaryTextColor,PanelFontSize,"Segoe UI");
   }
   else
   {
      EAPanelLabel("PROB",PanelX+20,PanelY+143,"MOVE PROBABILITY     WAITING FOR CLOSED M5/H4 DATA",
                   PanelSecondaryTextColor,PanelFontSize,"Segoe UI");
      EAPanelLabel("PATH",PanelX+20,PanelY+164,"PATH QUALITY          WAITING",
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

int OnInit()
{
   if(!ValidateInputs()) return(INIT_PARAMETERS_INCORRECT);
   LoadThresholds();
   GVResetResult(g_lastSignal);
   GVCalculate(Symbol(),1,g_thresholds,g_lastSignal);
   g_lastEntryTime=LatestEntryTime();
   g_lastM5Bar=(TradeCurrentSignalOnAttach ? 0 : iTime(Symbol(),PERIOD_M5,0));
   g_lastAction=(EnableAutomaticEntries ? "WAITING FOR CLOSED M5 SIGNAL" : "AUTO ENTRY DISABLED");
   UpdatePanel();
   Print("XVISION Gold Velocity AI EA V4: initialized on ",Symbol(),
         ". Auto entry ",(EnableAutomaticEntries ? "ENABLED" : "DISABLED"),
         ", magic ",MagicNumber,".");
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

   datetime currentM5=iTime(Symbol(),PERIOD_M5,0);
   if(currentM5>0 && currentM5!=g_lastM5Bar)
   {
      g_lastM5Bar=currentM5;
      GVCalculate(Symbol(),1,g_thresholds,g_lastSignal);
      bool closed=ProcessVelocityExit(g_lastSignal);
      if(!closed && EntryIsAllowed(g_lastSignal)) SendEntry(g_lastSignal);
   }
   UpdatePanel();
   g_engineBusy=false;
}
//+------------------------------------------------------------------+
