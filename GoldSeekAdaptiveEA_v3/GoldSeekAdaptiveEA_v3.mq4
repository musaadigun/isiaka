//+------------------------------------------------------------------+
//|                                        GoldSeekAdaptiveEA_v3.mq4 |
//|  Dual-direction, causal XAUUSD pursuit engine for MetaTrader 4   |
//+------------------------------------------------------------------+
#property strict
#property version   "3.00"
#property description "M5 structural acquisition with EMA20/EMA30 and ATR energy; M1 tracks the live move."
#property description "One full-position trade at a time. Qualified continuation entries are uncapped."

// The Inputs tab is intentionally limited to controls that belong to the user.
input double LotSize                    = 0.01;
input double StopLoss_PriceUSD          = 20.00;
input double TakeProfit_PriceUSD        = 0.00;
input double LockTrigger_PriceUSD       = 0.00;
input double LockedProfit_PriceUSD      = 0.00;
input double TrailingStart_PriceUSD     = 0.00;
input double TrailingDistance_PriceUSD  = 0.00;

enum TrackerState
  {
   STATE_SEARCH=0,
   STATE_CANDIDATE=1,
   STATE_ACQUIRED=2,
   STATE_ACTIVE=3,
   STATE_EXITING=4
  };

struct MarketSnapshot
  {
   double velocityM1;
   double velocityM5;
   double accelerationM1;
   double accelerationM5;
   double sigmaM1;
   double sigmaM5;
   double efficiencyM1;
   double efficiencyM5;
   double rangeExpansion;
   double atrM5;
   double atrExpansionM5;
   double atrAccelerationM5;
   double ema20M5;
   double ema30M5;
   double gap20ATR;
   double structureM5;
   double velocity3M5ATR;
   double ribbon20_30ATR;
   double ribbonVelocity3;
   double structuralScore;
   int    structuralDirection;
   double environmentFactor;
   double horizonMinutes;
   double directionalLogit;
   double probabilityUp;
   double probabilityDown;
   double probability10Up;
   double probability10Down;
   double probability20Up;
   double probability20Down;
   double probability30Up;
   double probability30Down;
   double probability50Up;
   double probability50Down;
   double modeNoise;
   double modeDrift;
   double modeImpulse;
   double modeExhaustion;
   double modeShock;
  };

struct DirectionTracker
  {
   double evidenceLogOdds;
   double rawP30;
   double calibratedP30;
   double expectedTravel;
   double expectedAdverse;
   double remainingTravel;
   double chaseDistance;
   double exhaustionRisk;
   double opportunityScore;
   int    supportBars;
   int    contradictionBars;
  };

// Frozen system rules. These are deliberately not optimization inputs.
const int    LEGACY_V1_EA_MAGIC               = 26081151;
const int    LEGACY_V2_EA_MAGIC               = 26081152;
const int    EA_MAGIC                         = 26081153;
const int    NO_EA_SLIPPAGE_CAP_POINTS       = 1000000;
const int    MIN_CANDIDATE_BARS               = 1;
const int    MAX_CANDIDATE_BARS               = 12;
const int    OPERATION_RETRY_SECONDS           = 2;
const int    MAX_INITIAL_PROTECTION_FAILURES   = 5;
const double BENCHMARK_REVERSAL_USD           = 15.0;
const double BENCHMARK_QUALIFYING_MOVE_USD    = 50.0;
const double CUSUM_ALLOWANCE                  = 0.18;
const double CUSUM_DECAY                      = 0.94;
const double STRUCTURAL_SCORE_THRESHOLD       = 0.7629589434;
const double MIN_M5_ATR_EXPANSION             = 0.90;
const double MIN_STRUCTURAL_ONSET_SCORE        = 0.62;
const double MIN_REMAINING_TRAVEL_USD         = 7.50;
const double MIN_OPPORTUNITY_SCORE            = 0.30;
const double MAX_ENTRY_EXHAUSTION_RISK         = 0.78;
const int    MIN_THESIS_INVALID_BARS          = 3;
const int    FAILURE_TO_LAUNCH_MINUTES        = 10;
const double FAILURE_TO_LAUNCH_PROGRESS_USD   = 5.0;
const double CALIBRATION_TARGET_USD           = 30.0;
const double CALIBRATION_ADVERSE_USD          = 15.0;
const double EPSILON                          = 0.0000001;

// Fixed presentation settings. They do not appear in the Inputs tab.
const string PANEL_PREFIX                     = "GSA_PANEL_";
const int    PANEL_LEFT                       = 10;
const int    PANEL_TOP                        = 18;
const int    PANEL_WIDTH                      = 414;
const int    PANEL_HEIGHT                     = 390;
const int    PANEL_LABEL_X                    = 26;
const int    PANEL_VALUE_X                    = 408;

TrackerState  g_state=STATE_SEARCH;
MarketSnapshot g_market;
DirectionTracker g_trackerUp;
DirectionTracker g_trackerDown;

datetime g_lastClosedM1=0;
datetime g_resetTime=0;
datetime g_candidateStart=0;
datetime g_nextOrderAttempt=0;
datetime g_acquiredSignalBar=0;
datetime g_nextExitSyncAttempt=0;
datetime g_nextCloseAttempt=0;
datetime g_activeEntryTime=0;

int    g_freshM1Bars=0;
int    g_candidateDirection=0;
int    g_candidateBars=0;
int    g_activeTicket=-1;
int    g_activeDirection=0;
int    g_invalidBars=0;
int    g_exitSyncFailures=0;
int    g_activeCalibrationBin=-1;

double g_candidateAnchor=0.0;
double g_cusumUp=0.0;
double g_cusumDown=0.0;
double g_trackLogOdds=0.0;
double g_favorableExtreme=0.0;
double g_expectedSL=0.0;
double g_expectedTP=0.0;
double g_activeEntryP30=0.0;
double g_activeEntryExpectedTravel=0.0;
double g_activeEntryRemainingTravel=0.0;
double g_activeEntryOpportunity=0.0;
double g_activeMaxFavorable=0.0;
double g_activeMaxAdverse=0.0;
double g_activeHorizonMinutes=0.0;
double g_calibrationHits[5];
double g_calibrationMisses[5];

bool   g_manualSLOverride=false;
bool   g_manualTPOverride=false;
bool   g_needExitSync=false;
bool   g_modelExitRequested=false;
bool   g_reconfiguredInputs=false;
string g_modelExitReason="";
uint   g_lastPanelRenderMs=0;
uint   g_lastEntryReconcileMs=0;

//+------------------------------------------------------------------+
//| Utility functions                                                |
//+------------------------------------------------------------------+
double Clamp(const double value,const double lower,const double upper)
  {
   return(MathMax(lower,MathMin(upper,value)));
  }

int SignOf(const double value)
  {
   if(value>0.0) return(1);
   if(value<0.0) return(-1);
   return(0);
  }

bool SamePrice(const double left,const double right)
  {
   return(MathAbs(left-right)<=MathMax(Point*0.75,EPSILON));
  }

double Logistic(const double value)
  {
   double bounded=Clamp(value,-50.0,50.0);
   return(1.0/(1.0+MathExp(-bounded)));
  }

double NormalCDF(const double value)
  {
   // Abramowitz-Stegun approximation; deterministic in old MT4 builds.
   double x=MathAbs(value);
   double t=1.0/(1.0+0.2316419*x);
   double density=0.3989422804014327*MathExp(-0.5*x*x);
   double polynomial=t*(0.319381530+t*(-0.356563782+t*(1.781477937+t*(-1.821255978+t*1.330274429))));
   double cdf=1.0-density*polynomial;
   if(value<0.0) cdf=1.0-cdf;
   return(Clamp(cdf,0.0,1.0));
  }

double CurrentMidPrice()
  {
   return((Bid+Ask)*0.5);
  }

string StateName()
  {
   if(g_state==STATE_SEARCH)    return("SEARCH");
   if(g_state==STATE_CANDIDATE) return("CANDIDATE");
   if(g_state==STATE_ACQUIRED) return("ACQUIRED");
   if(g_state==STATE_ACTIVE)   return("ACTIVE");
   if(g_state==STATE_EXITING)  return("EXITING");
   return("UNKNOWN");
  }

string DirectionName(const int direction)
  {
   if(direction>0) return("BUY");
   if(direction<0) return("SELL");
   return("NONE");
  }

string PersistenceKey(const string suffix)
  {
   return("GSA3."+IntegerToString(AccountNumber())+"."+Symbol()+"."+suffix);
  }

double ReadPersistent(const string suffix,const double fallback)
  {
   string key=PersistenceKey(suffix);
   if(!GlobalVariableCheck(key)) return(fallback);
   return(GlobalVariableGet(key));
  }

void WritePersistent(const string suffix,const double value)
  {
   GlobalVariableSet(PersistenceKey(suffix),value);
  }

void DeletePersistent(const string suffix)
  {
   string key=PersistenceKey(suffix);
   if(GlobalVariableCheck(key)) GlobalVariableDel(key);
  }

int BrokerDayKey(const datetime stamp)
  {
   return(TimeYear(stamp)*10000+TimeMonth(stamp)*100+TimeDay(stamp));
  }

bool IsMarketOrderType(const int orderType)
  {
   return(orderType==OP_BUY || orderType==OP_SELL);
  }

bool IsStrategyFamilyMagic(const int magic)
  {
   return(magic==EA_MAGIC || magic==LEGACY_V2_EA_MAGIC || magic==LEGACY_V1_EA_MAGIC);
  }

bool HasSufficientData()
  {
   if(iBars(Symbol(),PERIOD_M1)<220)  return(false);
   if(iBars(Symbol(),PERIOD_M5)<220)  return(false);
   if(iBars(Symbol(),PERIOD_M30)<40)  return(false);
   if(iClose(Symbol(),PERIOD_M1,1)<=0.0) return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Causal market measurements                                       |
//+------------------------------------------------------------------+
double LinearVelocity(const int timeframe,const int bars)
  {
   if(iBars(Symbol(),timeframe)<bars+3) return(0.0);
   double sumX=0.0,sumY=0.0,sumXX=0.0,sumXY=0.0;
   double minutes=(double)timeframe;
   if(minutes<=0.0) minutes=1.0;

   for(int index=0; index<bars; index++)
     {
      int shift=bars-index;
      double x=(double)index*minutes;
      double y=iClose(Symbol(),timeframe,shift);
      if(y<=0.0) return(0.0);
      sumX+=x;
      sumY+=y;
      sumXX+=x*x;
      sumXY+=x*y;
     }

   double denominator=bars*sumXX-sumX*sumX;
   if(MathAbs(denominator)<EPSILON) return(0.0);
   return((bars*sumXY-sumX*sumY)/denominator);
  }

double ReturnSigma(const int timeframe,const int bars,const double alpha)
  {
   if(iBars(Symbol(),timeframe)<bars+3) return(Point);
   double variance=0.0;
   bool seeded=false;
   for(int shift=bars; shift>=1; shift--)
     {
      double current=iClose(Symbol(),timeframe,shift);
      double previous=iClose(Symbol(),timeframe,shift+1);
      if(current<=0.0 || previous<=0.0) continue;
      double movement=current-previous;
      if(!seeded)
        {
         variance=movement*movement;
         seeded=true;
        }
      else
         variance=(1.0-alpha)*variance+alpha*movement*movement;
     }
   return(MathMax(MathSqrt(MathMax(variance,0.0)),Point));
  }

double DirectionalEfficiency(const int timeframe,const int bars)
  {
   if(iBars(Symbol(),timeframe)<bars+3) return(0.0);
   double newest=iClose(Symbol(),timeframe,1);
   double oldest=iClose(Symbol(),timeframe,bars+1);
   double path=0.0;
   for(int shift=1; shift<=bars; shift++)
      path+=MathAbs(iClose(Symbol(),timeframe,shift)-iClose(Symbol(),timeframe,shift+1));
   if(path<EPSILON) return(0.0);
   return(Clamp((newest-oldest)/path,-1.0,1.0));
  }

double AverageBarPressure(const int timeframe,const int bars)
  {
   if(iBars(Symbol(),timeframe)<bars+3) return(0.0);
   double pressure=0.0;
   int valid=0;
   for(int shift=1; shift<=bars; shift++)
     {
      double high=iHigh(Symbol(),timeframe,shift);
      double low=iLow(Symbol(),timeframe,shift);
      double close=iClose(Symbol(),timeframe,shift);
      double range=high-low;
      if(range<=Point) continue;
      pressure+=((close-low)-(high-close))/range;
      valid++;
     }
   if(valid<=0) return(0.0);
   return(Clamp(pressure/valid,-1.0,1.0));
  }

double SafeATR(const int timeframe,const int period)
  {
   double result=iATR(Symbol(),timeframe,period,1);
   if(result<=Point) result=Point;
   return(result);
  }

double EMAOfATR(const int timeframe,const int atrPeriod,const int emaPeriod,const int targetShift)
  {
   int oldest=targetShift+MathMax(emaPeriod*4,emaPeriod+2);
   double value=iATR(Symbol(),timeframe,atrPeriod,oldest);
   if(value<=Point) value=Point;
   double alpha=2.0/(emaPeriod+1.0);
   for(int shift=oldest-1;shift>=targetShift;shift--)
     {
      double observation=iATR(Symbol(),timeframe,atrPeriod,shift);
      if(observation<=Point) observation=value;
      value=alpha*observation+(1.0-alpha)*value;
     }
   return(MathMax(value,Point));
  }

double StructuralLocation(const int timeframe,const int bars,const int closeShift)
  {
   double closePrice=iClose(Symbol(),timeframe,closeShift);
   double priorHigh=iHigh(Symbol(),timeframe,closeShift+1);
   double priorLow=iLow(Symbol(),timeframe,closeShift+1);
   if(closePrice<=0.0 || priorHigh<=0.0 || priorLow<=0.0) return(0.0);
   for(int shift=closeShift+2;shift<=closeShift+bars;shift++)
     {
      priorHigh=MathMax(priorHigh,iHigh(Symbol(),timeframe,shift));
      priorLow=MathMin(priorLow,iLow(Symbol(),timeframe,shift));
     }
   double width=priorHigh-priorLow;
   if(width<=Point) return(0.0);
   return(Clamp((2.0*closePrice-priorHigh-priorLow)/width,-3.0,3.0));
  }

double M5RibbonATRAtShift(const int shift)
  {
   double atr=iATR(Symbol(),PERIOD_M5,14,shift);
   if(atr<=Point) atr=Point;
   double ema20=iMA(Symbol(),PERIOD_M5,20,0,MODE_EMA,PRICE_CLOSE,shift);
   double ema30=iMA(Symbol(),PERIOD_M5,30,0,MODE_EMA,PRICE_CLOSE,shift);
   return((ema20-ema30)/atr);
  }

void ComputeM5StructuralFeatures()
  {
   g_market.atrM5=MathMax(iATR(Symbol(),PERIOD_M5,14,1),Point);
   double atrBase=EMAOfATR(PERIOD_M5,14,20,1);
   double atrThreeBarsAgo=MathMax(iATR(Symbol(),PERIOD_M5,14,4),Point);
   g_market.atrExpansionM5=Clamp(g_market.atrM5/atrBase,0.25,4.0);
   g_market.atrAccelerationM5=Clamp((g_market.atrM5-atrThreeBarsAgo)/g_market.atrM5,-2.0,2.0);
   g_market.ema20M5=iMA(Symbol(),PERIOD_M5,20,0,MODE_EMA,PRICE_CLOSE,1);
   g_market.ema30M5=iMA(Symbol(),PERIOD_M5,30,0,MODE_EMA,PRICE_CLOSE,1);
   double closeM5=iClose(Symbol(),PERIOD_M5,1);
   g_market.gap20ATR=(closeM5-g_market.ema20M5)/g_market.atrM5;
   g_market.structureM5=StructuralLocation(PERIOD_M5,12,1);
   g_market.velocity3M5ATR=(closeM5-iClose(Symbol(),PERIOD_M5,4))/(3.0*g_market.atrM5);
   g_market.ribbon20_30ATR=(g_market.ema20M5-g_market.ema30M5)/g_market.atrM5;
   g_market.ribbonVelocity3=(g_market.ribbon20_30ATR-M5RibbonATRAtShift(4))/3.0;

   // Frozen train-only standardization from the supplied GOLD M5 data.
   // Each input is winsorized at its training 1st/99th percentiles.
   double zGap=(Clamp(g_market.gap20ATR,-3.130203,3.406464)+0.068448)/1.275260;
   double zStructure=(Clamp(g_market.structureM5,-1.571429,1.684980)+0.025718)/0.701767;
   double zRibbon=(Clamp(g_market.ribbonVelocity3,-0.076647,0.084752)+0.000728)/0.032197;
   double zVelocity=(Clamp(g_market.velocity3M5ATR,-0.869676,0.944521)+0.010149)/0.349549;
   g_market.structuralScore=(zGap+zStructure+zRibbon+zVelocity)/4.0;
   g_market.structuralDirection=SignOf(g_market.structuralScore);
  }

bool M5EnergyReady()
  {
   return(g_market.atrExpansionM5>=MIN_M5_ATR_EXPANSION && g_market.atrAccelerationM5>0.0);
  }

bool M5MotionAligned(const int direction)
  {
   if(direction==0) return(false);
   if(direction*g_market.gap20ATR<=0.0) return(false);
   if(direction*g_market.ribbonVelocity3<=0.0) return(false);
   if(direction*g_market.velocity3M5ATR<=0.0) return(false);
   return(true);
  }

bool M5StructuralReady(const int direction,const double minimumScore)
  {
   if(direction==0 || direction!=g_market.structuralDirection) return(false);
   if(direction*g_market.structuralScore<minimumScore) return(false);
   if(!M5EnergyReady()) return(false);
   return(M5MotionAligned(direction));
  }

void UpdateModeProbabilities(const double speed,const double acceleration,
                             const double efficiency,const double agreement,
                             const double expansion,const double lastReturnZ)
  {
   double logLikelihood[5];
   logLikelihood[0]=1.35*(1.0-efficiency)-0.45*speed-0.25*MathAbs(expansion-1.0);
   logLikelihood[1]=1.20*efficiency+0.45*speed+0.35*MathMax(agreement,0.0)-0.35*acceleration;
   logLikelihood[2]=0.90*efficiency+0.75*speed+0.70*MathMax(acceleration,0.0)+0.35*MathMax(expansion-1.0,0.0);
   logLikelihood[3]=0.65*speed+0.90*MathMax(-agreement,0.0)+0.65*(1.0-efficiency)+0.30*acceleration;
   logLikelihood[4]=1.15*MathMax(expansion-1.65,0.0)+0.55*MathMax(MathAbs(lastReturnZ)-2.0,0.0);

   double maximum=logLikelihood[0];
   for(int i=1;i<5;i++) maximum=MathMax(maximum,logLikelihood[i]);
   double likelihood[5];
   ArrayInitialize(likelihood,0.0);
   double total=0.0;
   for(int j=0;j<5;j++)
     {
      likelihood[j]=MathExp(Clamp(logLikelihood[j]-maximum,-50.0,50.0));
      total+=likelihood[j];
     }
   if(total<EPSILON) total=1.0;

   double previous[5];
   previous[0]=g_market.modeNoise;
   previous[1]=g_market.modeDrift;
   previous[2]=g_market.modeImpulse;
   previous[3]=g_market.modeExhaustion;
   previous[4]=g_market.modeShock;
   double previousTotal=0.0;
   for(int k=0;k<5;k++) previousTotal+=previous[k];
   if(previousTotal<EPSILON)
      for(int seed=0;seed<5;seed++) previous[seed]=0.20;

   double updated[5];
   ArrayInitialize(updated,0.0);
   double updatedTotal=0.0;
   for(int mode=0;mode<5;mode++)
     {
      // Persistence approximates an interacting-multiple-model transition prior.
      double mixedPrior=0.72*previous[mode]+0.28*(1.0-previous[mode])/4.0;
      updated[mode]=mixedPrior*(likelihood[mode]/total);
      updatedTotal+=updated[mode];
     }
   if(updatedTotal<EPSILON) updatedTotal=1.0;
   g_market.modeNoise=updated[0]/updatedTotal;
   g_market.modeDrift=updated[1]/updatedTotal;
   g_market.modeImpulse=updated[2]/updatedTotal;
   g_market.modeExhaustion=updated[3]/updatedTotal;
   g_market.modeShock=updated[4]/updatedTotal;
  }

double BarrierBeforeAdverseProbability(const double drift,const double sigma,
                                       const double target,const double adverse)
  {
   double variance=MathMax(sigma*sigma,Point*Point);
   if(MathAbs(drift)<0.000001)
      return(Clamp(adverse/(target+adverse),0.0,1.0));
   double exponent=-2.0*drift/variance;
   double numerator=1.0-MathExp(Clamp(exponent*adverse,-50.0,50.0));
   double denominator=1.0-MathExp(Clamp(exponent*(target+adverse),-50.0,50.0));
   if(MathAbs(denominator)<EPSILON)
      return(Clamp(adverse/(target+adverse),0.0,1.0));
   return(Clamp(numerator/denominator,0.0,1.0));
  }

double HitByHorizonProbability(const double drift,const double sigma,
                               const double target,const double horizonMinutes)
  {
   double safeSigma=MathMax(sigma,Point);
   double rootTime=MathSqrt(MathMax(horizonMinutes,1.0));
   double z1=(drift*horizonMinutes-target)/(safeSigma*rootTime);
   double z2=(-drift*horizonMinutes-target)/(safeSigma*rootTime);
   double multiplier=MathExp(Clamp(2.0*drift*target/(safeSigma*safeSigma),-50.0,50.0));
   return(Clamp(NormalCDF(z1)+multiplier*NormalCDF(z2),0.0,1.0));
  }

double ContinuationProbability(const int direction)
  {
   double directionalEvidence=direction*g_market.directionalLogit;
   double regimeSupport=g_market.modeDrift+g_market.modeImpulse;
   double regimeRisk=g_market.modeNoise+g_market.modeExhaustion+0.7*g_market.modeShock;
   return(Logistic(0.95*directionalEvidence+0.85*regimeSupport-0.55*regimeRisk-0.35));
  }

double DestinationProbability(const int direction,const double target)
  {
   double fusedDrift=0.58*g_market.velocityM1+0.42*g_market.velocityM5;
   double directedDrift=direction*fusedDrift;
   double sigmaPerMinute=MathMax(g_market.sigmaM1,0.45*g_market.sigmaM5/MathSqrt(5.0));
   double adverse=Clamp(2.4*sigmaPerMinute*MathSqrt(8.0),5.0,15.0);
   double barrier=BarrierBeforeAdverseProbability(directedDrift,sigmaPerMinute,target,adverse);
   double timed=HitByHorizonProbability(directedDrift,sigmaPerMinute,target,g_market.horizonMinutes);
   double continuation=ContinuationProbability(direction);
   double combined=(0.48*barrier+0.52*timed)*(0.58+0.42*continuation);
   return(Clamp(combined,0.0,1.0));
  }

double DirectionRawProbability(const int direction,const int target)
  {
   if(target==10) return(direction>0 ? g_market.probability10Up : g_market.probability10Down);
   if(target==20) return(direction>0 ? g_market.probability20Up : g_market.probability20Down);
   if(target==30) return(direction>0 ? g_market.probability30Up : g_market.probability30Down);
   return(direction>0 ? g_market.probability50Up : g_market.probability50Down);
  }

double CalibrationPriorRate(const int bin)
  {
   if(bin<=0) return(0.08);
   if(bin==1) return(0.11);
   if(bin==2) return(0.14);
   if(bin==3) return(0.17);
   return(0.21);
  }

int CalibrationBin(const double probability)
  {
   if(probability<0.12) return(0);
   if(probability<0.16) return(1);
   if(probability<0.20) return(2);
   if(probability<0.25) return(3);
   return(4);
  }

void InitializeCalibration()
  {
   for(int bin=0;bin<5;bin++)
     {
      g_calibrationHits[bin]=MathMax(0.0,ReadPersistent("CalHits"+IntegerToString(bin),0.0));
      g_calibrationMisses[bin]=MathMax(0.0,ReadPersistent("CalMisses"+IntegerToString(bin),0.0));
     }
  }

double ApplyOnlineCalibration(const double offlineProbability)
  {
   int bin=CalibrationBin(offlineProbability);
   double observations=g_calibrationHits[bin]+g_calibrationMisses[bin];
   double priorStrength=20.0;
   double posterior=(priorStrength*CalibrationPriorRate(bin)+g_calibrationHits[bin])/
                    (priorStrength+observations);
   double learnedWeight=Clamp(observations/60.0,0.0,0.65);
   return(Clamp((1.0-learnedWeight)*offlineProbability+learnedWeight*posterior,0.02,0.60));
  }

void RecordCalibrationOutcome(const int bin,const bool success)
  {
   if(bin<0 || bin>4) return;
   if(success) g_calibrationHits[bin]++;
   else g_calibrationMisses[bin]++;
   WritePersistent("CalHits"+IntegerToString(bin),g_calibrationHits[bin]);
   WritePersistent("CalMisses"+IntegerToString(bin),g_calibrationMisses[bin]);
   GlobalVariablesFlush();
  }

double OfflineCalibratedP30(const int direction,const double chaseDistance)
  {
   double sigma1=MathMax(g_market.sigmaM1,Point);
   double rawP30=DirectionRawProbability(direction,30);
   double structuralQuality=Clamp((direction*g_market.structuralScore-0.55)/1.75,0.0,1.0);
   double energyQuality=0.55*Clamp((g_market.atrExpansionM5-0.90)/0.35,0.0,1.0)+
                        0.45*Clamp(g_market.atrAccelerationM5/0.12,0.0,1.0);
   double m1Tracking=Clamp(direction*g_market.velocityM1/(sigma1+Point),-1.0,1.0);
   double chaseRisk=Clamp(chaseDistance/MathMax(5.0,2.5*g_market.atrM5),0.0,1.0);

   // This is deliberately conservative.  The supplied holdout did not justify
   // treating a $30 excursion as a high-probability event.  Online calibration
   // may move the estimate only after resolved live outcomes accumulate.
   double offline=0.055+0.050*structuralQuality+0.025*energyQuality+
                  0.012*Clamp(rawP30,0.0,1.0)+0.008*MathMax(0.0,m1Tracking)-
                  0.020*chaseRisk;
   return(ApplyOnlineCalibration(Clamp(offline,0.03,0.20)));
  }

void ClearDirectionTracker(DirectionTracker &tracker)
  {
   tracker.evidenceLogOdds=0.0;
   tracker.rawP30=0.0;
   tracker.calibratedP30=0.0;
   tracker.expectedTravel=0.0;
   tracker.expectedAdverse=0.0;
   tracker.remainingTravel=0.0;
   tracker.chaseDistance=0.0;
   tracker.exhaustionRisk=0.0;
   tracker.opportunityScore=0.0;
   tracker.supportBars=0;
   tracker.contradictionBars=0;
  }

void UpdateDirectionTracker(const int direction,DirectionTracker &tracker)
  {
   double current=CurrentMidPrice();
   double anchor=RecentMovementAnchor(direction,12);
   double chase=MathMax(0.0,direction*(current-anchor));
   double sigma=MathMax(g_market.sigmaM1,Point);
   double directedLogit=direction*g_market.directionalLogit;
   double cusumEdge=DirectionalCUSUM(direction)-OpposingCUSUM(direction);
   double structuralSupport=direction*g_market.structuralScore;
   double directedEfficiency=direction*g_market.efficiencyM5;
   double m1Tracking=direction*g_market.velocityM1/(sigma+Point);
   double energySupport=0.55*Clamp((g_market.atrExpansionM5-0.90)/0.35,0.0,1.0)+
                        0.45*Clamp(g_market.atrAccelerationM5/0.12,0.0,1.0);
   double regimeSupport=g_market.modeDrift+g_market.modeImpulse;
   double contradiction=MathMax(0.0,-m1Tracking)+MathMax(0.0,-cusumEdge)*0.12;
   double instantEvidence=0.46*structuralSupport+0.22*directedLogit+
                           0.16*direction*g_market.velocity3M5ATR+
                           0.10*directedEfficiency+0.12*energySupport+
                           0.07*Clamp(cusumEdge,-3.0,5.0)+0.06*m1Tracking+
                           0.12*regimeSupport-0.30*g_market.modeExhaustion-
                           0.25*g_market.modeShock;
   tracker.evidenceLogOdds=Clamp(0.72*tracker.evidenceLogOdds+0.46*instantEvidence,-8.0,8.0);

   if(instantEvidence>0.55)
     {
      tracker.supportBars=MathMin(tracker.supportBars+1,30);
      tracker.contradictionBars=MathMax(0,tracker.contradictionBars-1);
     }
   else if(instantEvidence<-0.20)
     {
      tracker.contradictionBars=MathMin(tracker.contradictionBars+1,30);
      tracker.supportBars=MathMax(0,tracker.supportBars-1);
     }

   tracker.rawP30=DirectionRawProbability(direction,30);
   tracker.calibratedP30=OfflineCalibratedP30(direction,chase);
   double directedDrift=MathMax(0.0,direction*(0.18*g_market.velocityM1+0.82*g_market.velocityM5));
   double diffusionCapacity=1.35*sigma*MathSqrt(MathMax(g_market.horizonMinutes,1.0));
   double driftCapacity=0.65*directedDrift*g_market.horizonMinutes;
   double environmentCapacity=0.75*SafeATR(PERIOD_M30,14)+2.0*g_market.atrM5;
   tracker.expectedTravel=Clamp(0.34*diffusionCapacity+0.31*driftCapacity+
                                 0.35*environmentCapacity+16.0*tracker.calibratedP30,6.0,60.0);
   tracker.expectedAdverse=Clamp(2.4*sigma*MathSqrt(8.0),5.0,15.0);
   tracker.chaseDistance=chase;
   tracker.remainingTravel=MathMax(0.0,tracker.expectedTravel-0.72*chase);
   double chaseRisk=Clamp(chase/MathMax(tracker.expectedTravel,1.0),0.0,1.5);
   double disagreement=(!M5MotionAligned(direction) ? 1.0 : 0.0);
   tracker.exhaustionRisk=Clamp(0.42*g_market.modeExhaustion+0.22*g_market.modeShock+
                                0.24*chaseRisk+0.08*contradiction+0.12*disagreement,0.0,1.0);

   double structuralQuality=Clamp((structuralSupport-MIN_STRUCTURAL_ONSET_SCORE)/1.60,0.0,1.0);
   double motionQuality=(M5MotionAligned(direction) ? 1.0 : 0.0);
   double probabilityQuality=Clamp((tracker.calibratedP30-0.04)/0.13,0.0,1.0);
   double remainingQuality=Clamp(tracker.remainingTravel/30.0,0.0,1.0);
   double persistenceQuality=Clamp(tracker.evidenceLogOdds/2.5,0.0,1.0);
   tracker.opportunityScore=Clamp(0.28*structuralQuality+0.17*energySupport+
                                   0.14*motionQuality+0.12*probabilityQuality+
                                   0.14*remainingQuality+0.08*persistenceQuality+
                                   0.07*(1.0-tracker.exhaustionRisk),0.0,1.0);
  }

void UpdateDirectionalTrackers()
  {
   UpdateDirectionTracker(1,g_trackerUp);
   UpdateDirectionTracker(-1,g_trackerDown);
  }

int BestTrackerDirection()
  {
   int structuralDirection=g_market.structuralDirection;
   if(M5StructuralReady(structuralDirection,MIN_STRUCTURAL_ONSET_SCORE))
      return(structuralDirection);
   double upScore=g_trackerUp.opportunityScore+0.015*MathMin(g_trackerUp.supportBars,4);
   double downScore=g_trackerDown.opportunityScore+0.015*MathMin(g_trackerDown.supportBars,4);
   if(upScore<=0.0 && downScore<=0.0) return(0);
   return(upScore>=downScore ? 1 : -1);
  }

void ComputeMarketSnapshot(const bool updateModes)
  {
   double velocityFastM1=LinearVelocity(PERIOD_M1,4);
   double velocitySlowM1=LinearVelocity(PERIOD_M1,12);
   double velocityFastM5=LinearVelocity(PERIOD_M5,3);
   double velocitySlowM5=LinearVelocity(PERIOD_M5,8);

   g_market.velocityM1=0.68*velocityFastM1+0.32*velocitySlowM1;
   g_market.velocityM5=0.62*velocityFastM5+0.38*velocitySlowM5;
   g_market.accelerationM1=(velocityFastM1-velocitySlowM1)/4.0;
   g_market.accelerationM5=(velocityFastM5-velocitySlowM5)/15.0;
   g_market.sigmaM1=ReturnSigma(PERIOD_M1,48,0.10);
   g_market.sigmaM5=ReturnSigma(PERIOD_M5,36,0.12);
   g_market.efficiencyM1=DirectionalEfficiency(PERIOD_M1,10);
   g_market.efficiencyM5=DirectionalEfficiency(PERIOD_M5,6);
   ComputeM5StructuralFeatures();

   g_market.rangeExpansion=g_market.atrExpansionM5;

   // M30 is strictly unsigned: it sizes the horizon but cannot impose direction.
   double environment30=SafeATR(PERIOD_M30,4)/SafeATR(PERIOD_M30,16);
   g_market.environmentFactor=Clamp(MathSqrt(MathMax(g_market.atrExpansionM5*environment30,0.01)),0.65,1.65);
   g_market.horizonMinutes=Clamp(120.0/g_market.environmentFactor,60.0,180.0);

   double sigmaVelocityM1=MathMax(g_market.sigmaM1,Point);
   double sigmaVelocityM5=MathMax(g_market.sigmaM5/5.0,Point);
   double zVelocityM1=Clamp(g_market.velocityM1/sigmaVelocityM1,-4.0,4.0);
   double zVelocityM5=Clamp(g_market.velocityM5/sigmaVelocityM5,-4.0,4.0);
   double zAccelerationM1=Clamp(g_market.accelerationM1/(sigmaVelocityM1/4.0+Point),-4.0,4.0);
   double zAccelerationM5=Clamp(g_market.accelerationM5/(sigmaVelocityM5/3.0+Point),-4.0,4.0);
   double pressure=0.20*AverageBarPressure(PERIOD_M1,4)+0.80*AverageBarPressure(PERIOD_M5,2);
   double speed=0.20*MathAbs(zVelocityM1)+0.80*MathAbs(zVelocityM5);
   double acceleration=MathAbs(0.20*zAccelerationM1+0.80*zAccelerationM5);
   double efficiency=0.20*MathAbs(g_market.efficiencyM1)+0.80*MathAbs(g_market.efficiencyM5);
   double agreement=SignOf(zVelocityM1*zVelocityM5)*MathMin(MathAbs(zVelocityM1),MathAbs(zVelocityM5));
   double latestReturn=iClose(Symbol(),PERIOD_M1,1)-iClose(Symbol(),PERIOD_M1,2);
   double latestReturnZ=latestReturn/MathMax(g_market.sigmaM1,Point);

   if(updateModes)
      UpdateModeProbabilities(speed,acceleration,efficiency,agreement,g_market.rangeExpansion,latestReturnZ);

   double accelerationWeight=0.10+0.08*g_market.modeImpulse-0.05*g_market.modeExhaustion;
   double cusumEvidence=0.05*(g_cusumUp-g_cusumDown);

   g_market.directionalLogit=
      0.88*g_market.structuralScore+
      (0.22+0.10*g_market.modeDrift)*zVelocityM5+
      accelerationWeight*(0.15*zAccelerationM1+0.85*zAccelerationM5)+
      0.16*g_market.efficiencyM5+
      0.08*zVelocityM1+
      0.10*pressure+
      cusumEvidence;

   // Exhaustion and shock reduce magnitude symmetrically; they never choose direction.
   double magnitudeDamping=Clamp(1.0-0.30*g_market.modeExhaustion-0.22*g_market.modeShock,0.45,1.0);
   g_market.directionalLogit*=magnitudeDamping;
   g_market.probabilityUp=Logistic(1.15*g_market.directionalLogit);
   g_market.probabilityDown=1.0-g_market.probabilityUp;

   g_market.probability10Up=DestinationProbability(1,10.0);
   g_market.probability10Down=DestinationProbability(-1,10.0);
   g_market.probability20Up=DestinationProbability(1,20.0);
   g_market.probability20Down=DestinationProbability(-1,20.0);
   g_market.probability30Up=DestinationProbability(1,30.0);
   g_market.probability30Down=DestinationProbability(-1,30.0);
   g_market.probability50Up=DestinationProbability(1,50.0);
   g_market.probability50Down=DestinationProbability(-1,50.0);
  }

void UpdateCUSUM()
  {
   double newest=iClose(Symbol(),PERIOD_M1,1);
   double previous=iClose(Symbol(),PERIOD_M1,2);
   if(newest<=0.0 || previous<=0.0) return;
   double sigma=ReturnSigma(PERIOD_M1,48,0.10);
   double standardized=(newest-previous)/MathMax(sigma,Point);
   g_cusumUp=MathMax(0.0,CUSUM_DECAY*g_cusumUp+standardized-CUSUM_ALLOWANCE);
   g_cusumDown=MathMax(0.0,CUSUM_DECAY*g_cusumDown-standardized-CUSUM_ALLOWANCE);
   g_cusumUp=Clamp(g_cusumUp,0.0,12.0);
   g_cusumDown=Clamp(g_cusumDown,0.0,12.0);
  }

//+------------------------------------------------------------------+
//| Daily entry accounting                                           |
//+------------------------------------------------------------------+
int CountFilledEntriesFromTerminal(const int dayKey)
  {
   int count=0;
   for(int openIndex=OrdersTotal()-1; openIndex>=0; openIndex--)
     {
      if(!OrderSelect(openIndex,SELECT_BY_POS,MODE_TRADES)) continue;
       if(!IsStrategyFamilyMagic(OrderMagicNumber()) || OrderSymbol()!=Symbol()) continue;
      if(!IsMarketOrderType(OrderType())) continue;
      if(BrokerDayKey(OrderOpenTime())==dayKey) count++;
     }
   for(int historyIndex=OrdersHistoryTotal()-1; historyIndex>=0; historyIndex--)
     {
      if(!OrderSelect(historyIndex,SELECT_BY_POS,MODE_HISTORY)) continue;
       if(!IsStrategyFamilyMagic(OrderMagicNumber()) || OrderSymbol()!=Symbol()) continue;
      if(!IsMarketOrderType(OrderType())) continue;
      if(BrokerDayKey(OrderOpenTime())==dayKey) count++;
     }
   return(count);
  }

int EntriesToday()
  {
   int today=BrokerDayKey(TimeCurrent());
   int storedDay=(int)ReadPersistent("Day",0.0);
   int storedCount=(int)ReadPersistent("Entries",-1.0);
   uint now=GetTickCount();
   bool dayReset=(storedDay!=today || storedCount<0);
   bool auditDue=(g_lastEntryReconcileMs==0 || now-g_lastEntryReconcileMs>=5000);
   if(!dayReset && !auditDue) return(storedCount);

   int terminalCount=CountFilledEntriesFromTerminal(today);
   g_lastEntryReconcileMs=now;
   if(dayReset)
     {
      storedCount=terminalCount;
      WritePersistent("Day",today);
      WritePersistent("Entries",storedCount);
      GlobalVariablesFlush();
     }
   else if(terminalCount>storedCount)
     {
      // A crash can occur after a fill but before the persistent counter increments.
      // Never let the stored value undercount orders that the terminal can prove exist.
      storedCount=terminalCount;
      WritePersistent("Entries",storedCount);
      GlobalVariablesFlush();
     }
   return(storedCount);
  }

void IncrementEntriesToday()
  {
   int today=BrokerDayKey(TimeCurrent());
   int storedDay=(int)ReadPersistent("Day",0.0);
   int storedCount=(int)ReadPersistent("Entries",0.0);
   if(storedDay!=today || storedCount<0) storedCount=0;
   int terminalCount=CountFilledEntriesFromTerminal(today);
   int count=(int)MathMax(storedCount+1,terminalCount);
   WritePersistent("Day",today);
   WritePersistent("Entries",count);
   g_lastEntryReconcileMs=GetTickCount();
   GlobalVariablesFlush();
  }

//+------------------------------------------------------------------+
//| Order discovery and persistence                                  |
//+------------------------------------------------------------------+
int FindOpenEAOrder()
  {
   for(int index=OrdersTotal()-1; index>=0; index--)
     {
      if(!OrderSelect(index,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderMagicNumber()!=EA_MAGIC || OrderSymbol()!=Symbol()) continue;
      if(!IsMarketOrderType(OrderType())) continue;
      return(OrderTicket());
     }
   return(-1);
  }

bool HasAnyOpenMarketPositionOnSymbol()
  {
   for(int index=OrdersTotal()-1; index>=0; index--)
     {
      if(!OrderSelect(index,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()) continue;
      if(IsMarketOrderType(OrderType())) return(true);
     }
   return(false);
  }

void PersistActiveTrade()
  {
   if(g_activeTicket<=0) return;
   WritePersistent("Ticket",g_activeTicket);
   WritePersistent("ExpectedSL",g_expectedSL);
   WritePersistent("ExpectedTP",g_expectedTP);
   WritePersistent("ManualSL",g_manualSLOverride ? 1.0 : 0.0);
   WritePersistent("ManualTP",g_manualTPOverride ? 1.0 : 0.0);
   WritePersistent("Peak",g_favorableExtreme);
   WritePersistent("TrackLogOdds",g_trackLogOdds);
   WritePersistent("InvalidBars",g_invalidBars);
   WritePersistent("EntryTime",g_activeEntryTime);
   WritePersistent("EntryP30",g_activeEntryP30);
   WritePersistent("EntryExpected",g_activeEntryExpectedTravel);
   WritePersistent("EntryRemaining",g_activeEntryRemainingTravel);
   WritePersistent("EntryOpportunity",g_activeEntryOpportunity);
   WritePersistent("CalibrationBin",g_activeCalibrationBin);
   WritePersistent("MaxFavorable",g_activeMaxFavorable);
   WritePersistent("MaxAdverse",g_activeMaxAdverse);
   WritePersistent("EntryHorizon",g_activeHorizonMinutes);
   WritePersistent("CusumUp",g_cusumUp);
   WritePersistent("CusumDown",g_cusumDown);
   WritePersistent("ModeNoise",g_market.modeNoise);
   WritePersistent("ModeDrift",g_market.modeDrift);
   WritePersistent("ModeImpulse",g_market.modeImpulse);
   WritePersistent("ModeExhaustion",g_market.modeExhaustion);
   WritePersistent("ModeShock",g_market.modeShock);
   GlobalVariablesFlush();
  }

void ClearActiveTradePersistence()
  {
   DeletePersistent("Ticket");
   DeletePersistent("ExpectedSL");
   DeletePersistent("ExpectedTP");
   DeletePersistent("ManualSL");
   DeletePersistent("ManualTP");
   DeletePersistent("Peak");
   DeletePersistent("TrackLogOdds");
   DeletePersistent("InvalidBars");
   DeletePersistent("EntryTime");
   DeletePersistent("EntryP30");
   DeletePersistent("EntryExpected");
   DeletePersistent("EntryRemaining");
   DeletePersistent("EntryOpportunity");
   DeletePersistent("CalibrationBin");
   DeletePersistent("MaxFavorable");
   DeletePersistent("MaxAdverse");
   DeletePersistent("EntryHorizon");
   DeletePersistent("CusumUp");
   DeletePersistent("CusumDown");
   DeletePersistent("ModeNoise");
   DeletePersistent("ModeDrift");
   DeletePersistent("ModeImpulse");
   DeletePersistent("ModeExhaustion");
   DeletePersistent("ModeShock");
   GlobalVariablesFlush();
  }

int LotDigitsFromStep(const double step)
  {
   if(step>=1.0) return(0);
   if(step>=0.1) return(1);
   if(step>=0.01) return(2);
   if(step>=0.001) return(3);
   return(4);
  }

bool ValidateRequestedLots(const double requested,string &reason)
  {
   double minimum=MarketInfo(Symbol(),MODE_MINLOT);
   double maximum=MarketInfo(Symbol(),MODE_MAXLOT);
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(minimum<=0.0 || maximum<=0.0 || step<=0.0)
     {
      reason="broker lot specification is unavailable";
      return(false);
     }

   int lotDigits=LotDigitsFromStep(step);
   double tolerance=MathMax(0.00000001,step*0.000001);
   if(requested<minimum-tolerance)
     {
      reason="LotSize "+DoubleToString(requested,lotDigits)+" is below broker minimum "+DoubleToString(minimum,lotDigits);
      return(false);
     }
   if(requested>maximum+tolerance)
     {
      reason="LotSize "+DoubleToString(requested,lotDigits)+" exceeds broker maximum "+DoubleToString(maximum,lotDigits);
      return(false);
     }

   double nearest=MathRound(requested/step)*step;
   if(MathAbs(requested-nearest)>tolerance)
     {
      reason="LotSize "+DoubleToString(requested,lotDigits)+" is not aligned to broker step "+DoubleToString(step,lotDigits);
      return(false);
     }
   return(true);
  }

bool ValidateUserInputs(string &reason)
  {
   if(LotSize<=0.0 || StopLoss_PriceUSD<0.0 || TakeProfit_PriceUSD<0.0 ||
      LockTrigger_PriceUSD<0.0 || LockedProfit_PriceUSD<0.0 ||
      TrailingStart_PriceUSD<0.0 || TrailingDistance_PriceUSD<0.0)
     {
      reason="values cannot be negative and LotSize must be positive";
      return(false);
     }
   if(!ValidateRequestedLots(LotSize,reason)) return(false);
   if(LockTrigger_PriceUSD<=0.0 && LockedProfit_PriceUSD>0.0)
     {
      reason="LockedProfit_PriceUSD requires a positive LockTrigger_PriceUSD";
      return(false);
     }
   if(LockTrigger_PriceUSD>0.0 && LockedProfit_PriceUSD>=LockTrigger_PriceUSD)
     {
      reason="LockedProfit_PriceUSD must be smaller than LockTrigger_PriceUSD";
      return(false);
     }
   bool trailingStartEnabled=(TrailingStart_PriceUSD>0.0);
   bool trailingDistanceEnabled=(TrailingDistance_PriceUSD>0.0);
   if(trailingStartEnabled!=trailingDistanceEnabled)
     {
      reason="TrailingStart_PriceUSD and TrailingDistance_PriceUSD must both be zero or both be positive";
      return(false);
     }
   return(true);
  }

double NormalizeLots(const double requested)
  {
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   string reason="";
   if(!ValidateRequestedLots(requested,reason)) return(0.0);
   return(NormalizeDouble(MathRound(requested/step)*step,LotDigitsFromStep(step)));
  }

void CalculateInputStops(const int type,const double openPrice,double &stopLoss,double &takeProfit)
  {
   stopLoss=0.0;
   takeProfit=0.0;
   double minimumDistance=MarketInfo(Symbol(),MODE_STOPLEVEL)*Point;
   double safetyDistance=MathMax(minimumDistance,Point);

   if(type==OP_BUY)
     {
      if(StopLoss_PriceUSD>0.0)
         stopLoss=MathMin(openPrice-StopLoss_PriceUSD,Bid-safetyDistance);
      if(TakeProfit_PriceUSD>0.0)
         takeProfit=MathMax(openPrice+TakeProfit_PriceUSD,Bid+safetyDistance);
     }
   else if(type==OP_SELL)
     {
      if(StopLoss_PriceUSD>0.0)
         stopLoss=MathMax(openPrice+StopLoss_PriceUSD,Ask+safetyDistance);
      if(TakeProfit_PriceUSD>0.0)
         takeProfit=MathMin(openPrice-TakeProfit_PriceUSD,Ask-safetyDistance);
     }

   if(stopLoss>0.0) stopLoss=NormalizeDouble(stopLoss,Digits);
   if(takeProfit>0.0) takeProfit=NormalizeDouble(takeProfit,Digits);
  }

bool ModifyActiveStops(const double requestedSL,const double requestedTP,const string source)
  {
   if(g_activeTicket<=0) return(false);
   if(!OrderSelect(g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return(false);
   if(SamePrice(OrderStopLoss(),requestedSL) && SamePrice(OrderTakeProfit(),requestedTP))
     {
      g_expectedSL=OrderStopLoss();
      g_expectedTP=OrderTakeProfit();
      return(true);
     }

   ResetLastError();
   bool modified=OrderModify(OrderTicket(),OrderOpenPrice(),requestedSL,requestedTP,0,clrNONE);
   if(!modified)
     {
      int error=GetLastError();
      if(error==ERR_NO_RESULT)
        {
         if(OrderSelect(g_activeTicket,SELECT_BY_TICKET,MODE_TRADES))
           {
            g_expectedSL=OrderStopLoss();
            g_expectedTP=OrderTakeProfit();
           }
         PersistActiveTrade();
         return(true);
        }
      Print("GoldSeek: OrderModify failed source=",source," ticket=",g_activeTicket," error=",error,
            " sl=",DoubleToString(requestedSL,Digits)," tp=",DoubleToString(requestedTP,Digits));
      return(false);
     }

   if(OrderSelect(g_activeTicket,SELECT_BY_TICKET,MODE_TRADES))
     {
      g_expectedSL=OrderStopLoss();
      g_expectedTP=OrderTakeProfit();
     }
   PersistActiveTrade();
   return(true);
  }

bool InputExitAlreadyReached(string &reason)
  {
   if(g_activeTicket<=0 || !OrderSelect(g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return(false);
   int type=OrderType();
   double openPrice=OrderOpenPrice();
   if(type==OP_BUY)
     {
      if(StopLoss_PriceUSD>0.0 && Bid<=openPrice-StopLoss_PriceUSD)
        {
         reason="configured stop level already crossed";
         return(true);
        }
      if(TakeProfit_PriceUSD>0.0 && Bid>=openPrice+TakeProfit_PriceUSD)
        {
         reason="configured take-profit level already crossed";
         return(true);
        }
     }
   else if(type==OP_SELL)
     {
      if(StopLoss_PriceUSD>0.0 && Ask>=openPrice+StopLoss_PriceUSD)
        {
         reason="configured stop level already crossed";
         return(true);
        }
      if(TakeProfit_PriceUSD>0.0 && Ask<=openPrice-TakeProfit_PriceUSD)
        {
         reason="configured take-profit level already crossed";
         return(true);
        }
     }
   return(false);
  }

void ApplyInputExits()
  {
   if(g_activeTicket<=0) return;
   if(!OrderSelect(g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return;
   string reachedReason="";
   if(InputExitAlreadyReached(reachedReason))
     {
      Print("GoldSeek: ",reachedReason,"; requesting full market exit ticket=",g_activeTicket);
      g_needExitSync=false;
      g_modelExitRequested=true;
      g_state=STATE_EXITING;
      return;
     }
   if(TimeCurrent()<g_nextExitSyncAttempt) return;
   double stopLoss=0.0,takeProfit=0.0;
   CalculateInputStops(OrderType(),OrderOpenPrice(),stopLoss,takeProfit);
   if(ModifyActiveStops(stopLoss,takeProfit,"input-sync"))
     {
      g_needExitSync=false;
      g_exitSyncFailures=0;
      g_nextExitSyncAttempt=0;
     }
   else
     {
      g_exitSyncFailures++;
      g_nextExitSyncAttempt=TimeCurrent()+OPERATION_RETRY_SECONDS;
      if(StopLoss_PriceUSD>0.0 && g_exitSyncFailures>=MAX_INITIAL_PROTECTION_FAILURES)
        {
         Print("GoldSeek: required stop protection could not be synchronized after ",g_exitSyncFailures,
               " attempts; requesting fail-safe full exit ticket=",g_activeTicket);
         g_needExitSync=false;
         g_modelExitRequested=true;
         g_state=STATE_EXITING;
        }
     }
  }

void RecoverActiveTrade(const int ticket)
  {
   if(ticket<=0 || !OrderSelect(ticket,SELECT_BY_TICKET,MODE_TRADES)) return;
   bool matchingPersistence=((int)ReadPersistent("Ticket",-1.0)==ticket);
   g_activeTicket=ticket;
   g_activeDirection=(OrderType()==OP_BUY ? 1 : -1);
   g_state=STATE_ACTIVE;
   g_modelExitRequested=false;
   g_invalidBars=(matchingPersistence ? (int)ReadPersistent("InvalidBars",0.0) : 0);
   g_cusumUp=(matchingPersistence ? Clamp(ReadPersistent("CusumUp",0.0),0.0,12.0) : 0.0);
   g_cusumDown=(matchingPersistence ? Clamp(ReadPersistent("CusumDown",0.0),0.0,12.0) : 0.0);

   if(matchingPersistence)
     {
      g_market.modeNoise=MathMax(0.0,ReadPersistent("ModeNoise",g_market.modeNoise));
      g_market.modeDrift=MathMax(0.0,ReadPersistent("ModeDrift",g_market.modeDrift));
      g_market.modeImpulse=MathMax(0.0,ReadPersistent("ModeImpulse",g_market.modeImpulse));
      g_market.modeExhaustion=MathMax(0.0,ReadPersistent("ModeExhaustion",g_market.modeExhaustion));
      g_market.modeShock=MathMax(0.0,ReadPersistent("ModeShock",g_market.modeShock));
      double modeTotal=g_market.modeNoise+g_market.modeDrift+g_market.modeImpulse+
                       g_market.modeExhaustion+g_market.modeShock;
      if(modeTotal>EPSILON)
        {
         g_market.modeNoise/=modeTotal;
         g_market.modeDrift/=modeTotal;
         g_market.modeImpulse/=modeTotal;
         g_market.modeExhaustion/=modeTotal;
         g_market.modeShock/=modeTotal;
        }
      else
        {
         g_market.modeNoise=0.20;
         g_market.modeDrift=0.20;
         g_market.modeImpulse=0.20;
         g_market.modeExhaustion=0.20;
         g_market.modeShock=0.20;
        }
     }
   if(HasSufficientData()) ComputeMarketSnapshot(false);
   g_trackLogOdds=(matchingPersistence ? ReadPersistent("TrackLogOdds",MathAbs(g_market.directionalLogit)) :
                                          MathAbs(g_market.directionalLogit));
   g_activeEntryTime=(datetime)(matchingPersistence ? ReadPersistent("EntryTime",OrderOpenTime()) : OrderOpenTime());
   g_activeEntryP30=(matchingPersistence ? ReadPersistent("EntryP30",0.0) : 0.0);
   g_activeEntryExpectedTravel=(matchingPersistence ? ReadPersistent("EntryExpected",0.0) : 0.0);
   g_activeEntryRemainingTravel=(matchingPersistence ? ReadPersistent("EntryRemaining",0.0) : 0.0);
   g_activeEntryOpportunity=(matchingPersistence ? ReadPersistent("EntryOpportunity",0.0) : 0.0);
   g_activeCalibrationBin=(matchingPersistence ? (int)ReadPersistent("CalibrationBin",-1.0) : -1);
   g_activeMaxFavorable=(matchingPersistence ? MathMax(0.0,ReadPersistent("MaxFavorable",0.0)) : 0.0);
   g_activeMaxAdverse=(matchingPersistence ? MathMax(0.0,ReadPersistent("MaxAdverse",0.0)) : 0.0);
   g_activeHorizonMinutes=(matchingPersistence ? ReadPersistent("EntryHorizon",g_market.horizonMinutes) : g_market.horizonMinutes);
   g_modelExitReason="";
   double persistedPeak=(matchingPersistence ? ReadPersistent("Peak",OrderOpenPrice()) : OrderOpenPrice());
   if(g_activeDirection>0) g_favorableExtreme=MathMax(OrderOpenPrice(),MathMax(persistedPeak,Bid));
   else g_favorableExtreme=MathMin(OrderOpenPrice(),MathMin(persistedPeak,Ask));
   g_exitSyncFailures=0;
   g_nextExitSyncAttempt=0;
   g_nextCloseAttempt=0;

   if(g_reconfiguredInputs)
     {
      g_manualSLOverride=false;
      g_manualTPOverride=false;
      g_expectedSL=OrderStopLoss();
      g_expectedTP=OrderTakeProfit();
      g_needExitSync=true;
     }
   else
     {
      g_expectedSL=(matchingPersistence ? ReadPersistent("ExpectedSL",OrderStopLoss()) : OrderStopLoss());
      g_expectedTP=(matchingPersistence ? ReadPersistent("ExpectedTP",OrderTakeProfit()) : OrderTakeProfit());
      g_manualSLOverride=(matchingPersistence && ReadPersistent("ManualSL",0.0)>0.5);
      g_manualTPOverride=(matchingPersistence && ReadPersistent("ManualTP",0.0)>0.5);
      g_needExitSync=false;
     }
   PersistActiveTrade();
  }

void AppendTelemetry(const string eventName,const string reason)
  {
   string fileName="GoldSeekAdaptiveEA_v3_telemetry.csv";
   int handle=FileOpen(fileName,FILE_CSV|FILE_READ|FILE_WRITE|FILE_SHARE_READ,',');
   if(handle==INVALID_HANDLE)
     {
      Print("GoldSeek V3: telemetry open failed error=",GetLastError());
      return;
     }
   if(FileSize(handle)==0)
      FileWrite(handle,"event_time","event","ticket","direction","reason","entry_time","entry_price",
                "entry_p30","expected_travel","remaining_travel","opportunity_score","max_favorable",
                "max_adverse","track_log_odds","invalid_bars","entries_today");
   FileSeek(handle,0,SEEK_END);
   double entryPrice=0.0;
   if(g_activeTicket>0 && OrderSelect(g_activeTicket,SELECT_BY_TICKET)) entryPrice=OrderOpenPrice();
   FileWrite(handle,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),eventName,g_activeTicket,
             DirectionName(g_activeDirection),reason,TimeToString(g_activeEntryTime,TIME_DATE|TIME_SECONDS),
             DoubleToString(entryPrice,Digits),DoubleToString(g_activeEntryP30,4),
             DoubleToString(g_activeEntryExpectedTravel,2),DoubleToString(g_activeEntryRemainingTravel,2),
             DoubleToString(g_activeEntryOpportunity,4),DoubleToString(g_activeMaxFavorable,2),
             DoubleToString(g_activeMaxAdverse,2),DoubleToString(g_trackLogOdds,4),g_invalidBars,EntriesToday());
   FileClose(handle);
  }

//+------------------------------------------------------------------+
//| Acquisition state machine                                        |
//+------------------------------------------------------------------+
double RecentMovementAnchor(const int direction,const int bars)
  {
   if(direction>0)
     {
      double lowest=iLow(Symbol(),PERIOD_M1,1);
      for(int shift=2;shift<=bars;shift++) lowest=MathMin(lowest,iLow(Symbol(),PERIOD_M1,shift));
      return(lowest);
     }
   double highest=iHigh(Symbol(),PERIOD_M1,1);
   for(int index=2;index<=bars;index++) highest=MathMax(highest,iHigh(Symbol(),PERIOD_M1,index));
   return(highest);
  }

double DirectionalCUSUM(const int direction)
  {
   return(direction>0 ? g_cusumUp : g_cusumDown);
  }

double OpposingCUSUM(const int direction)
  {
   return(direction>0 ? g_cusumDown : g_cusumUp);
  }

double Probability30(const int direction)
  {
   return(direction>0 ? g_trackerUp.calibratedP30 : g_trackerDown.calibratedP30);
  }

double RemainingTravel(const int direction)
  {
   return(direction>0 ? g_trackerUp.remainingTravel : g_trackerDown.remainingTravel);
  }

double ExpectedTravel(const int direction)
  {
   return(direction>0 ? g_trackerUp.expectedTravel : g_trackerDown.expectedTravel);
  }

double OpportunityScore(const int direction)
  {
   return(direction>0 ? g_trackerUp.opportunityScore : g_trackerDown.opportunityScore);
  }

double TrackerEvidence(const int direction)
  {
   return(direction>0 ? g_trackerUp.evidenceLogOdds : g_trackerDown.evidenceLogOdds);
  }

int TrackerSupportBars(const int direction)
  {
   return(direction>0 ? g_trackerUp.supportBars : g_trackerDown.supportBars);
  }

void ReturnToSearch(const bool blockOldDirection)
  {
   // blockOldDirection is retained in the signature for safe state-machine
   // cleanup, but V3 never blacklists a direction.  A continuing thesis may
   // legitimately produce a new same-direction entry after the prior close.
   g_state=STATE_SEARCH;
   g_candidateDirection=0;
   g_candidateBars=0;
   g_candidateAnchor=0.0;
   g_candidateStart=0;
   g_acquiredSignalBar=0;
   g_nextOrderAttempt=0;
  }

bool AcquisitionEvidenceReady(const int direction)
  {
   if(!M5StructuralReady(direction,STRUCTURAL_SCORE_THRESHOLD)) return(false);
   if(RemainingTravel(direction)<MIN_REMAINING_TRAVEL_USD) return(false);
   if(OpportunityScore(direction)<MIN_OPPORTUNITY_SCORE) return(false);
   // Strong live contradiction vetoes an immediate re-entry after a model
   // invalidation.  Positive M1 confirmation is never required.
   if(TrackerEvidence(direction)<-0.35) return(false);
   if((direction>0 ? g_trackerUp.exhaustionRisk : g_trackerDown.exhaustionRisk)>MAX_ENTRY_EXHAUSTION_RISK) return(false);
   if(g_market.modeShock>0.70 && direction*g_market.structuralScore<STRUCTURAL_SCORE_THRESHOLD+0.45) return(false);
   return(true);
  }

void AdvanceAcquisitionState()
  {
   if(g_state==STATE_ACTIVE || g_state==STATE_EXITING) return;
   if(HasAnyOpenMarketPositionOnSymbol()) return;

   int direction=BestTrackerDirection();

   if(g_state==STATE_SEARCH)
     {
       if(!M5StructuralReady(direction,MIN_STRUCTURAL_ONSET_SCORE)) return;
       g_candidateDirection=direction;
       g_candidateAnchor=RecentMovementAnchor(direction,12);
       g_candidateStart=iTime(Symbol(),PERIOD_M1,1);
       g_candidateBars=0;
       g_state=STATE_CANDIDATE;
       // A fully formed M5 structure is acquired immediately.  M1 is not used
       // as a late confirmation gate; it remains active for live tracking.
       if(AcquisitionEvidenceReady(direction))
         {
          g_state=STATE_ACQUIRED;
          g_acquiredSignalBar=iTime(Symbol(),PERIOD_M1,1);
          g_nextOrderAttempt=0;
         }
       return;
      }

   if(g_state!=STATE_CANDIDATE) return;
   g_candidateBars++;

   int competingDirection=g_market.structuralDirection;
   if(competingDirection!=0 && competingDirection!=g_candidateDirection &&
      M5StructuralReady(competingDirection,MIN_STRUCTURAL_ONSET_SCORE))
     {
      ReturnToSearch(false);
      return;
     }

   double newAnchor=RecentMovementAnchor(g_candidateDirection,12);
   if(g_candidateDirection>0 && newAnchor<g_candidateAnchor)
     {
      g_candidateAnchor=newAnchor;
      g_candidateBars=0;
      g_candidateStart=iTime(Symbol(),PERIOD_M1,1);
     }
   else if(g_candidateDirection<0 && newAnchor>g_candidateAnchor)
     {
      g_candidateAnchor=newAnchor;
      g_candidateBars=0;
      g_candidateStart=iTime(Symbol(),PERIOD_M1,1);
     }

   if(!M5StructuralReady(g_candidateDirection,MIN_STRUCTURAL_ONSET_SCORE))
     {
      ReturnToSearch(false);
      return;
     }

   if(g_candidateBars>MAX_CANDIDATE_BARS)
     {
      ReturnToSearch(false);
      return;
     }

   if(g_candidateBars>=MIN_CANDIDATE_BARS && AcquisitionEvidenceReady(g_candidateDirection))
     {
      g_state=STATE_ACQUIRED;
      g_acquiredSignalBar=iTime(Symbol(),PERIOD_M1,1);
      g_nextOrderAttempt=0;
     }
  }

//+------------------------------------------------------------------+
//| Trading and full-position exit management                        |
//+------------------------------------------------------------------+
bool TryOpenAcquiredTrack()
  {
   if(g_state!=STATE_ACQUIRED || g_candidateDirection==0) return(false);
   if(TimeCurrent()<g_nextOrderAttempt) return(false);
   datetime latestClosedBar=iTime(Symbol(),PERIOD_M1,1);
   if(g_acquiredSignalBar<=0 || latestClosedBar!=g_acquiredSignalBar)
     {
      Print("GoldSeek: acquired signal expired before fill direction=",DirectionName(g_candidateDirection));
      ReturnToSearch(false);
      return(false);
     }
   if(!AcquisitionEvidenceReady(g_candidateDirection))
     {
      Print("GoldSeek: acquired structural signal no longer valid before fill direction=",
            DirectionName(g_candidateDirection));
      ReturnToSearch(false);
      return(false);
     }
   if(HasAnyOpenMarketPositionOnSymbol()) return(false);
   if(!IsTradeAllowed()) return(false);

   RefreshRates();
   int command=(g_candidateDirection>0 ? OP_BUY : OP_SELL);
   double price=(command==OP_BUY ? Ask : Bid);
   if(Bid<=0.0 || Ask<=0.0 || price<=0.0)
     {
      g_nextOrderAttempt=TimeCurrent()+OPERATION_RETRY_SECONDS;
      return(false);
     }
   double lots=NormalizeLots(LotSize);
   if(lots<=0.0)
     {
      Print("GoldSeek: entry cancelled because LotSize is invalid for the current broker contract.");
      ReturnToSearch(false);
      return(false);
     }

   double decisionP30=Probability30(g_candidateDirection);
   double decisionExpected=ExpectedTravel(g_candidateDirection);
   double decisionRemaining=RemainingTravel(g_candidateDirection);
   double decisionOpportunity=OpportunityScore(g_candidateDirection);
   double decisionEvidence=TrackerEvidence(g_candidateDirection);
   double decisionHorizon=g_market.horizonMinutes;

   ResetLastError();
   int ticket=OrderSend(Symbol(),command,lots,NormalizeDouble(price,Digits),
                        NO_EA_SLIPPAGE_CAP_POINTS,0.0,0.0,
                         "GoldSeekAdaptiveV3",EA_MAGIC,0,
                        (command==OP_BUY ? clrDodgerBlue : clrTomato));
   if(ticket<0)
     {
      int error=GetLastError();
      Print("GoldSeek: OrderSend failed direction=",DirectionName(g_candidateDirection)," error=",error);
      g_nextOrderAttempt=TimeCurrent()+OPERATION_RETRY_SECONDS;
      return(false);
     }

   IncrementEntriesToday();
   if(!OrderSelect(ticket,SELECT_BY_TICKET,MODE_TRADES))
     {
      Print("GoldSeek: filled ticket is temporarily unavailable for selection ticket=",ticket,
            "; protection sync will retry.");
      g_activeTicket=ticket;
      g_activeDirection=(command==OP_BUY ? 1 : -1);
       g_state=STATE_ACTIVE;
       g_modelExitRequested=false;
       g_modelExitReason="";
       g_invalidBars=0;
       g_trackLogOdds=decisionEvidence;
       g_favorableExtreme=price;
       g_activeEntryTime=TimeCurrent();
       g_activeEntryP30=decisionP30;
       g_activeEntryExpectedTravel=decisionExpected;
       g_activeEntryRemainingTravel=decisionRemaining;
       g_activeEntryOpportunity=decisionOpportunity;
       g_activeCalibrationBin=CalibrationBin(decisionP30);
       g_activeMaxFavorable=0.0;
       g_activeMaxAdverse=0.0;
       g_activeHorizonMinutes=decisionHorizon;
      g_expectedSL=0.0;
      g_expectedTP=0.0;
      g_manualSLOverride=false;
      g_manualTPOverride=false;
      g_needExitSync=true;
      g_exitSyncFailures=0;
      g_nextExitSyncAttempt=0;
      g_acquiredSignalBar=0;
       PersistActiveTrade();
       AppendTelemetry("ENTRY","acquired-selection-pending");
       return(true);
     }

   g_activeTicket=ticket;
   g_activeDirection=(OrderType()==OP_BUY ? 1 : -1);
   g_state=STATE_ACTIVE;
   g_modelExitRequested=false;
   g_modelExitReason="";
   g_invalidBars=0;
   g_trackLogOdds=decisionEvidence;
   g_favorableExtreme=OrderOpenPrice();
   g_activeEntryTime=OrderOpenTime();
   g_activeEntryP30=decisionP30;
   g_activeEntryExpectedTravel=decisionExpected;
   g_activeEntryRemainingTravel=decisionRemaining;
   g_activeEntryOpportunity=decisionOpportunity;
   g_activeCalibrationBin=CalibrationBin(decisionP30);
   g_activeMaxFavorable=0.0;
   g_activeMaxAdverse=0.0;
   g_activeHorizonMinutes=decisionHorizon;
   g_expectedSL=OrderStopLoss();
   g_expectedTP=OrderTakeProfit();
   g_manualSLOverride=false;
   g_manualTPOverride=false;
   g_needExitSync=true;
   g_exitSyncFailures=0;
   g_nextExitSyncAttempt=0;
   g_acquiredSignalBar=0;
   PersistActiveTrade();
   ApplyInputExits();
   AppendTelemetry("ENTRY","acquired");

   Print("GoldSeek V3: entry filled ticket=",ticket," direction=",DirectionName(g_activeDirection),
          " price=",DoubleToString(OrderOpenPrice(),Digits)," p30=",DoubleToString(Probability30(g_activeDirection),3),
          " remaining=",DoubleToString(decisionRemaining,2),
          " opportunity=",DoubleToString(decisionOpportunity,3)," entriesToday=",EntriesToday());
   return(true);
  }

void DetectManualExitChanges()
  {
   if(g_activeTicket<=0 || g_needExitSync) return;
   if(!OrderSelect(g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return;
   bool changed=false;

   if(!SamePrice(OrderStopLoss(),g_expectedSL))
     {
      g_manualSLOverride=true;
      g_expectedSL=OrderStopLoss();
      changed=true;
      Print("GoldSeek: manual SL override detected ticket=",g_activeTicket,
            "; profit-lock and trailing adjustments suspended for this trade.");
     }
   if(!SamePrice(OrderTakeProfit(),g_expectedTP))
     {
      g_manualTPOverride=true;
      g_expectedTP=OrderTakeProfit();
      changed=true;
      Print("GoldSeek: manual TP override detected ticket=",g_activeTicket);
     }
   if(changed) PersistActiveTrade();
  }

void ManageProfitProtection()
  {
   if(g_activeTicket<=0 || g_manualSLOverride || g_needExitSync) return;
   if(TimeCurrent()<g_nextExitSyncAttempt) return;
   if(!OrderSelect(g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return;
   int type=OrderType();
   double openPrice=OrderOpenPrice();
   double currentSL=OrderStopLoss();
   double currentTP=OrderTakeProfit();
   double desiredSL=currentSL;
   double minimumDistance=MathMax(MarketInfo(Symbol(),MODE_STOPLEVEL)*Point,Point);

   if(type==OP_BUY)
     {
      g_favorableExtreme=MathMax(g_favorableExtreme,Bid);
      double gain=g_favorableExtreme-openPrice;
      if(LockTrigger_PriceUSD>0.0 && gain>=LockTrigger_PriceUSD)
        {
         double lockLevel=openPrice+MathMax(LockedProfit_PriceUSD,0.0);
         if(desiredSL<=0.0 || lockLevel>desiredSL) desiredSL=lockLevel;
        }
      if(TrailingStart_PriceUSD>0.0 && TrailingDistance_PriceUSD>0.0 && gain>=TrailingStart_PriceUSD)
        {
         double trailingLevel=g_favorableExtreme-TrailingDistance_PriceUSD;
         if(desiredSL<=0.0 || trailingLevel>desiredSL) desiredSL=trailingLevel;
        }
      if(desiredSL>0.0) desiredSL=MathMin(desiredSL,Bid-minimumDistance);
      if(currentSL>0.0 && desiredSL<currentSL) desiredSL=currentSL;
     }
   else if(type==OP_SELL)
     {
      if(g_favorableExtreme<=0.0) g_favorableExtreme=openPrice;
      g_favorableExtreme=MathMin(g_favorableExtreme,Ask);
      double gain=openPrice-g_favorableExtreme;
      if(LockTrigger_PriceUSD>0.0 && gain>=LockTrigger_PriceUSD)
        {
         double lockLevel=openPrice-MathMax(LockedProfit_PriceUSD,0.0);
         if(desiredSL<=0.0 || lockLevel<desiredSL) desiredSL=lockLevel;
        }
      if(TrailingStart_PriceUSD>0.0 && TrailingDistance_PriceUSD>0.0 && gain>=TrailingStart_PriceUSD)
        {
         double trailingLevel=g_favorableExtreme+TrailingDistance_PriceUSD;
         if(desiredSL<=0.0 || trailingLevel<desiredSL) desiredSL=trailingLevel;
        }
      if(desiredSL>0.0) desiredSL=MathMax(desiredSL,Ask+minimumDistance);
      if(currentSL>0.0 && desiredSL>currentSL) desiredSL=currentSL;
     }

   if(desiredSL>0.0) desiredSL=NormalizeDouble(desiredSL,Digits);
   if(!SamePrice(desiredSL,currentSL))
     {
      if(ModifyActiveStops(desiredSL,currentTP,"profit-protection"))
         g_nextExitSyncAttempt=0;
      else
         g_nextExitSyncAttempt=TimeCurrent()+OPERATION_RETRY_SECONDS;
     }
  }

void UpdateActiveExcursions()
  {
   if(g_activeTicket<=0) return;
   if(!OrderSelect(g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return;
   double currentExecutable=(g_activeDirection>0 ? Bid : Ask);
   double favorable=g_activeDirection*(currentExecutable-OrderOpenPrice());
   double adverse=-favorable;
   g_activeMaxFavorable=MathMax(g_activeMaxFavorable,MathMax(0.0,favorable));
   g_activeMaxAdverse=MathMax(g_activeMaxAdverse,MathMax(0.0,adverse));
   if(g_activeDirection>0) g_favorableExtreme=MathMax(g_favorableExtreme,currentExecutable);
   else g_favorableExtreme=MathMin(g_favorableExtreme,currentExecutable);
  }

void UpdateThesisAndMaybeInvalidate()
  {
   if(g_activeTicket<=0 || g_state!=STATE_ACTIVE) return;
   if(!OrderSelect(g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return;

   double directedEvidence=g_activeDirection*g_market.directionalLogit;
   double regimeSupport=g_market.modeDrift+g_market.modeImpulse;
   double regimeRisk=g_market.modeExhaustion+0.75*g_market.modeShock;
   double cusumEdge=DirectionalCUSUM(g_activeDirection)-OpposingCUSUM(g_activeDirection);
   double trackerEvidence=TrackerEvidence(g_activeDirection);
   double evidenceInnovation=0.52*directedEvidence+0.18*Clamp(cusumEdge,-4.0,5.0)+
                             0.22*trackerEvidence+0.18*regimeSupport-0.34*regimeRisk;
   g_trackLogOdds=Clamp(0.86*g_trackLogOdds+0.34*evidenceInnovation,-8.0,8.0);

   if(evidenceInnovation<-0.25 || OpposingCUSUM(g_activeDirection)>DirectionalCUSUM(g_activeDirection)+0.65)
      g_invalidBars++;
   else if(evidenceInnovation>0.30 && g_invalidBars>0)
      g_invalidBars=MathMax(0,g_invalidBars-1);

   double currentExecutable=(g_activeDirection>0 ? Bid : Ask);
   UpdateActiveExcursions();
   double giveback=g_activeDirection*(g_favorableExtreme-currentExecutable);
   double adverseFromEntry=-g_activeDirection*(currentExecutable-OrderOpenPrice());
   double adaptiveReversal=Clamp(2.7*g_market.sigmaM1*MathSqrt(5.0),5.0,10.0);
   double hardAdverse=Clamp(3.8*g_market.sigmaM1*MathSqrt(5.0),8.0,20.0);
   double lastMove=iClose(Symbol(),PERIOD_M1,1)-iClose(Symbol(),PERIOD_M1,2);
   double oppositeShock=-g_activeDirection*lastMove/MathMax(g_market.sigmaM1,Point);

   bool invalid=false;
   string reason="";
   double ageMinutes=MathMax(0.0,(TimeCurrent()-g_activeEntryTime)/60.0);
   double launchThreshold=MathMax(FAILURE_TO_LAUNCH_PROGRESS_USD,
                                  1.80*g_market.sigmaM1*MathSqrt(5.0));
   if(g_invalidBars>=MIN_THESIS_INVALID_BARS && g_trackLogOdds<-0.15)
     {
      invalid=true;
      reason="persistent evidence failure";
     }
   else if(ageMinutes>=FAILURE_TO_LAUNCH_MINUTES &&
           g_activeMaxFavorable<launchThreshold &&
           g_invalidBars>=MIN_THESIS_INVALID_BARS && g_trackLogOdds<0.25)
     {
      invalid=true;
      reason="failure to launch";
     }
   else if(giveback>=adaptiveReversal && g_invalidBars>=2 && g_trackLogOdds<0.0)
      {
       invalid=true;
       reason="persistent adaptive reversal";
      }
   else if(adverseFromEntry>=hardAdverse && (g_invalidBars>=2 || g_trackLogOdds<0.0))
      {
       invalid=true;
       reason="adverse thesis boundary";
      }
   else if(oppositeShock>=3.0 && g_invalidBars>=2 && g_trackLogOdds<0.0)
      {
       invalid=true;
       reason="confirmed opposite shock";
      }
   else if(ageMinutes>=MathMax(60.0,g_activeHorizonMinutes) &&
           g_activeMaxFavorable<15.0 && g_trackLogOdds<0.40)
      {
       invalid=true;
       reason="stale thesis horizon";
      }

   if(invalid)
     {
       g_modelExitRequested=true;
       g_modelExitReason=reason;
       g_state=STATE_EXITING;
       Print("GoldSeek V3: thesis invalidated ticket=",g_activeTicket," reason=",reason,
             " trackLogOdds=",DoubleToString(g_trackLogOdds,3)," invalidBars=",g_invalidBars,
             " giveback=",DoubleToString(giveback,2)," MFE=",DoubleToString(g_activeMaxFavorable,2));
      }
   PersistActiveTrade();
  }

bool CloseFullActivePosition()
  {
   if(g_activeTicket<=0) return(false);
   if(TimeCurrent()<g_nextCloseAttempt) return(false);
   if(!IsTradeAllowed()) return(false);
   if(!OrderSelect(g_activeTicket,SELECT_BY_TICKET,MODE_TRADES)) return(false);
   RefreshRates();
   int type=OrderType();
   double price=(type==OP_BUY ? Bid : Ask);
   double lots=OrderLots();
   ResetLastError();
   bool closed=OrderClose(g_activeTicket,lots,NormalizeDouble(price,Digits),
                          NO_EA_SLIPPAGE_CAP_POINTS,clrGold);
   if(!closed)
     {
      int error=GetLastError();
      Print("GoldSeek: full-position close failed ticket=",g_activeTicket," error=",error);
      g_nextCloseAttempt=TimeCurrent()+OPERATION_RETRY_SECONDS;
      return(false);
     }
   g_nextCloseAttempt=0;
   return(true);
  }

double MoneyPerPriceUnitPerLot()
  {
   double tickValue=MarketInfo(Symbol(),MODE_TICKVALUE);
   double tickSize=MarketInfo(Symbol(),MODE_TICKSIZE);
   if(tickSize<=0.0 || tickValue<=0.0) return(0.0);
   return(tickValue/tickSize);
  }

void ResetForFreshCycle(const datetime closureTime)
  {
   g_activeTicket=-1;
   g_activeDirection=0;
   g_modelExitRequested=false;
   g_manualSLOverride=false;
   g_manualTPOverride=false;
   g_needExitSync=false;
   g_expectedSL=0.0;
   g_expectedTP=0.0;
   g_favorableExtreme=0.0;
   g_trackLogOdds=0.0;
   g_invalidBars=0;
   g_activeEntryTime=0;
   g_activeEntryP30=0.0;
   g_activeEntryExpectedTravel=0.0;
   g_activeEntryRemainingTravel=0.0;
   g_activeEntryOpportunity=0.0;
   g_activeCalibrationBin=-1;
   g_activeMaxFavorable=0.0;
   g_activeMaxAdverse=0.0;
   g_activeHorizonMinutes=0.0;
   g_modelExitReason="";
   g_exitSyncFailures=0;
   g_acquiredSignalBar=0;
   g_nextOrderAttempt=0;
   g_nextExitSyncAttempt=0;
   g_nextCloseAttempt=0;
   ReturnToSearch(false);
   ClearActiveTradePersistence();

   // Preserve the live structural thesis, CUSUM and tracker memory across the
   // close.  The next cycle reassesses current evidence immediately and may
   // take a same-direction continuation if it still independently qualifies.
   if(HasSufficientData())
     {
      ComputeMarketSnapshot(false);
      UpdateDirectionalTrackers();
      AdvanceAcquisitionState();
     }
  }

void FinalizeClosedTrade()
  {
   int closedTicket=g_activeTicket;
   datetime closeTime=TimeCurrent();
   if(closedTicket>0 && OrderSelect(closedTicket,SELECT_BY_TICKET,MODE_HISTORY))
     {
      closeTime=OrderCloseTime();
      int direction=(OrderType()==OP_BUY ? 1 : -1);
      double grossCapture=direction*(OrderClosePrice()-OrderOpenPrice());
      double netCapture=grossCapture;
      double moneyPerPrice=MoneyPerPriceUnitPerLot();
      if(moneyPerPrice>0.0 && OrderLots()>0.0)
         netCapture+=(OrderCommission()+OrderSwap())/(moneyPerPrice*OrderLots());
       string closeReason=(g_modelExitReason!="" ? g_modelExitReason : "manual-or-input-close");
       bool calibrationSuccess=(g_activeMaxFavorable>=CALIBRATION_TARGET_USD);
       double activeAgeMinutes=MathMax(0.0,(closeTime-g_activeEntryTime)/60.0);
       bool calibrationFailure=(!calibrationSuccess &&
                                (g_activeMaxAdverse>=CALIBRATION_ADVERSE_USD ||
                                 g_modelExitReason!="" ||
                                 activeAgeMinutes>=MathMax(60.0,g_activeHorizonMinutes)));
       if(calibrationSuccess || calibrationFailure)
          RecordCalibrationOutcome(g_activeCalibrationBin,calibrationSuccess);
       AppendTelemetry("EXIT",closeReason);
        Print("GoldSeek V3: cycle closed ticket=",closedTicket,
             " grossCapture=",DoubleToString(grossCapture,2),
             " netCapture=",DoubleToString(netCapture,2),
             " MFE=",DoubleToString(g_activeMaxFavorable,2),
             " MAE=",DoubleToString(g_activeMaxAdverse,2),
             " calibration=",(calibrationSuccess ? "HIT30" : (calibrationFailure ? "MISS30" : "CENSORED")),
             " closeTime=",TimeToString(closeTime,TIME_DATE|TIME_MINUTES));
     }
   else
      Print("GoldSeek: active ticket disappeared; starting a fresh acquisition cycle ticket=",closedTicket);
   ResetForFreshCycle(closeTime);
  }

void SuperviseActiveLifecycle()
  {
   int discovered=FindOpenEAOrder();
   if(g_activeTicket<=0 && discovered>0)
     {
      RecoverActiveTrade(discovered);
      return;
     }
   if(g_activeTicket>0 && discovered<=0)
     {
      FinalizeClosedTrade();
      return;
     }
   if(g_activeTicket<=0) return;

   if(!OrderSelect(g_activeTicket,SELECT_BY_TICKET,MODE_TRADES))
     {
      FinalizeClosedTrade();
      return;
     }

   UpdateActiveExcursions();

   if(g_needExitSync) ApplyInputExits();
   else DetectManualExitChanges();

   if(g_state==STATE_EXITING || g_modelExitRequested)
     {
      if(CloseFullActivePosition()) FinalizeClosedTrade();
      return;
     }
   ManageProfitProtection();
  }

//+------------------------------------------------------------------+
//| Bar processing and display                                       |
//+------------------------------------------------------------------+
void ProcessNewClosedM1Bar()
  {
   datetime closedBar=iTime(Symbol(),PERIOD_M1,1);
   if(closedBar<=0 || closedBar==g_lastClosedM1) return;

   datetime currentBar=iTime(Symbol(),PERIOD_M1,0);
   if(currentBar>0 && currentBar-closedBar>180)
     {
      // Do not act on the final stale bar from a closed-session gap.
      g_lastClosedM1=closedBar;
      g_cusumUp=0.0;
       g_cusumDown=0.0;
       ClearDirectionTracker(g_trackerUp);
       ClearDirectionTracker(g_trackerDown);
      g_freshM1Bars=0;
      g_resetTime=currentBar;
      if(g_state==STATE_CANDIDATE || g_state==STATE_ACQUIRED) ReturnToSearch(false);
      return;
     }

   if(g_lastClosedM1>0 && closedBar-g_lastClosedM1>180)
     {
      // The first completed bar after a session/data gap must not inject the
      // cross-gap price jump into CUSUM or thesis evidence.
      g_lastClosedM1=closedBar;
      g_cusumUp=0.0;
       g_cusumDown=0.0;
       ClearDirectionTracker(g_trackerUp);
       ClearDirectionTracker(g_trackerDown);
      g_freshM1Bars=0;
      g_resetTime=closedBar;
      if(g_state==STATE_CANDIDATE || g_state==STATE_ACQUIRED) ReturnToSearch(false);
      PersistActiveTrade();
      return;
     }

   g_lastClosedM1=closedBar;
   if(closedBar>g_resetTime) g_freshM1Bars++;
   UpdateCUSUM();
   ComputeMarketSnapshot(true);
   UpdateDirectionalTrackers();
   if(g_state==STATE_ACTIVE)
      UpdateThesisAndMaybeInvalidate();
   else if(g_state!=STATE_EXITING)
     {
      AdvanceAcquisitionState();
      if(g_state==STATE_ACQUIRED) TryOpenAcquiredTrack();
     }
  }

void PanelSetBox(const string suffix,const int x,const int y,const int width,const int height,
                 const color background,const color border,const int zOrder=0)
  {
   string name=PANEL_PREFIX+suffix;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
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
   ObjectSetInteger(0,name,OBJPROP_ZORDER,zOrder);
  }

void PanelSetText(const string suffix,const string text,const int x,const int y,
                  const color textColor,const int fontSize=9,
                  const int anchor=ANCHOR_LEFT_UPPER,const string fontName="Arial")
  {
   string name=PANEL_PREFIX+suffix;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,anchor);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,textColor);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontSize);
   ObjectSetString(0,name,OBJPROP_FONT,fontName);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,1);
  }

void PanelSetDivider(const string suffix,const int y)
  {
   PanelSetBox(suffix,PANEL_LABEL_X,y,PANEL_WIDTH-36,1,C'65,77,96',C'65,77,96',1);
  }

void PanelSection(const string suffix,const string title,const int titleY,const int lineY)
  {
   PanelSetText(suffix+"Title",title,PANEL_LABEL_X,titleY,C'55,169,255',9);
   PanelSetDivider(suffix+"Line",lineY);
  }

void CreateStatusPanel()
  {
   Comment("");
   PanelSetBox("Background",PANEL_LEFT,PANEL_TOP,PANEL_WIDTH,PANEL_HEIGHT,C'13,16,23',C'55,64,80',0);
   PanelSetText("Title","XVISION  |  GOLD SEEK ADAPTIVE V3",PANEL_LABEL_X,24,C'255,218,0',13);
   PanelSetText("Subtitle","M5 STRUCTURE  |  M1 LIVE TRACKING  |  ONE TRADE",PANEL_LABEL_X,44,C'128,151,190',9);
   PanelSetDivider("HeaderLine",62);

   PanelSection("Status","STATUS",70,85);
   PanelSetText("StatusMessage","INITIALIZING",PANEL_LABEL_X,92,C'225,230,240',11);
   PanelSetText("DirectionLabel","Tracking direction",PANEL_LABEL_X,117,C'174,184,201',9);
   PanelSetText("DirectionValue","NONE",PANEL_VALUE_X,117,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("EntriesLabel","Entries today",PANEL_LABEL_X,137,C'174,184,201',9);
   PanelSetText("EntriesValue","0 (UNCAPPED)",PANEL_VALUE_X,137,C'225,230,240',9,ANCHOR_RIGHT_UPPER);

   PanelSection("Management","TRADE MANAGEMENT",155,170);
   PanelSetText("LotsLabel","Requested / executable lot",PANEL_LABEL_X,177,C'174,184,201',9);
   PanelSetText("LotsValue","--",PANEL_VALUE_X,177,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("StopsLabel","Stop loss / take profit",PANEL_LABEL_X,195,C'174,184,201',9);
   PanelSetText("StopsValue","--",PANEL_VALUE_X,195,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("LockLabel","Lock trigger / locked profit",PANEL_LABEL_X,213,C'174,184,201',9);
   PanelSetText("LockValue","--",PANEL_VALUE_X,213,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("TrailLabel","Trailing start / distance",PANEL_LABEL_X,231,C'174,184,201',9);
   PanelSetText("TrailValue","--",PANEL_VALUE_X,231,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("OwnershipLabel","Exit ownership",PANEL_LABEL_X,249,C'174,184,201',9);
   PanelSetText("OwnershipValue","EA SL + EA TP",PANEL_VALUE_X,249,C'225,230,240',9,ANCHOR_RIGHT_UPPER);

   PanelSection("Live","LIVE",271,286);
   PanelSetText("TimeLabel","Broker time",PANEL_LABEL_X,293,C'174,184,201',9);
   PanelSetText("TimeValue","--",PANEL_VALUE_X,293,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("PriceLabel","Live Bid / Ask",PANEL_LABEL_X,311,C'174,184,201',9);
   PanelSetText("PriceValue","-- / --",PANEL_VALUE_X,311,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("SpreadLabel","Spread / trading permission",PANEL_LABEL_X,329,C'174,184,201',9);
   PanelSetText("SpreadValue","--",PANEL_VALUE_X,329,C'225,230,240',9,ANCHOR_RIGHT_UPPER);

   PanelSetText("Benchmark","BENCHMARK  $50 LEG  |  $15 REVERSAL",PANEL_LABEL_X,358,C'255,168,32',9);
   PanelSetText("Footer","FULL POSITION  |  CLOSE REASSESS  |  CONTINUATIONS ALLOWED",PANEL_LABEL_X,381,C'128,151,190',8);
  }

void DeleteStatusPanel()
  {
   ObjectsDeleteAll(0,PANEL_PREFIX);
   g_lastPanelRenderMs=0;
  }

string PanelStateMessage()
  {
   if(g_state==STATE_SEARCH)    return("SCANNING FOR A DEVELOPING MOVE");
   if(g_state==STATE_CANDIDATE) return("MOVEMENT CANDIDATE DETECTED");
   if(g_state==STATE_ACQUIRED) return("TARGET ACQUIRED - SEEKING ENTRY");
   if(g_state==STATE_ACTIVE)   return("TRACKING LIVE PRICE MOVEMENT");
   if(g_state==STATE_EXITING)  return("THESIS INVALID - EXITING POSITION");
   return("INITIALIZING");
  }

color PanelStateColor()
  {
   if(g_state==STATE_SEARCH)    return(C'225,230,240');
   if(g_state==STATE_CANDIDATE) return(C'255,218,0');
   if(g_state==STATE_ACQUIRED) return(C'55,190,255');
   if(g_state==STATE_ACTIVE)   return(C'0,230,96');
   if(g_state==STATE_EXITING)  return(C'255,168,32');
   return(C'225,230,240');
  }

color PanelDirectionColor(const int direction)
  {
   if(direction>0) return(C'0,230,96');
   if(direction<0) return(C'255,0,220');
   return(C'225,230,240');
  }

string PanelSettingPrice(const double value)
  {
   if(value<=0.0) return("OFF");
   return("$"+DoubleToString(value,2));
  }

string PanelExitOwnership()
  {
   if(g_manualSLOverride && g_manualTPOverride) return("MANUAL SL + MANUAL TP");
   if(g_manualSLOverride) return("MANUAL SL + EA TP");
   if(g_manualTPOverride) return("EA SL + MANUAL TP");
   return("EA SL + EA TP");
  }

void ShowWaitingStatus()
  {
   if(ObjectFind(0,PANEL_PREFIX+"Background")<0) CreateStatusPanel();
   PanelSetText("StatusMessage","WAITING FOR M1/M5/M30 HISTORY",PANEL_LABEL_X,92,C'255,218,0',11);
   PanelSetText("DirectionValue","NONE",PANEL_VALUE_X,117,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("EntriesValue",IntegerToString(EntriesToday())+" (UNCAPPED)",
                PANEL_VALUE_X,137,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("TimeValue",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),PANEL_VALUE_X,293,C'255,218,0',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("PriceValue",DoubleToString(Bid,Digits)+" / "+DoubleToString(Ask,Digits),
                PANEL_VALUE_X,311,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   ChartRedraw(0);
  }

void ShowStatus(const bool force=false)
  {
   uint now=GetTickCount();
   if(!force && g_lastPanelRenderMs>0 && now-g_lastPanelRenderMs<250) return;
   g_lastPanelRenderMs=now;
   if(ObjectFind(0,PANEL_PREFIX+"Background")<0) CreateStatusPanel();

   int displayDirection=(g_state==STATE_ACTIVE || g_state==STATE_EXITING ? g_activeDirection : g_candidateDirection);
   color directionColor=PanelDirectionColor(displayDirection);

   PanelSetText("StatusMessage",PanelStateMessage(),PANEL_LABEL_X,92,PanelStateColor(),11);
   PanelSetText("DirectionValue",DirectionName(displayDirection),PANEL_VALUE_X,117,directionColor,9,ANCHOR_RIGHT_UPPER);
   PanelSetText("EntriesValue",IntegerToString(EntriesToday())+" (UNCAPPED)",
                PANEL_VALUE_X,137,C'225,230,240',9,ANCHOR_RIGHT_UPPER);

   PanelSetText("LotsValue",DoubleToString(LotSize,2)+" / "+DoubleToString(NormalizeLots(LotSize),2),
                PANEL_VALUE_X,177,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("StopsValue",PanelSettingPrice(StopLoss_PriceUSD)+" / "+PanelSettingPrice(TakeProfit_PriceUSD),
                PANEL_VALUE_X,195,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("LockValue",PanelSettingPrice(LockTrigger_PriceUSD)+" / "+PanelSettingPrice(LockedProfit_PriceUSD),
                PANEL_VALUE_X,213,(LockTrigger_PriceUSD>0.0 ? C'0,230,96' : C'225,230,240'),9,ANCHOR_RIGHT_UPPER);
   PanelSetText("TrailValue",PanelSettingPrice(TrailingStart_PriceUSD)+" / "+PanelSettingPrice(TrailingDistance_PriceUSD),
                PANEL_VALUE_X,231,(TrailingStart_PriceUSD>0.0 && TrailingDistance_PriceUSD>0.0 ? C'0,230,96' : C'225,230,240'),9,ANCHOR_RIGHT_UPPER);
   PanelSetText("OwnershipValue",PanelExitOwnership(),PANEL_VALUE_X,249,
                (g_manualSLOverride || g_manualTPOverride ? C'255,218,0' : C'225,230,240'),9,ANCHOR_RIGHT_UPPER);

   string tradingPermission=(IsTradeAllowed() ? "ENABLED" : "DISABLED");
   color permissionColor=(IsTradeAllowed() ? C'0,230,96' : C'255,168,32');
   double spreadPrice=MathMax(0.0,Ask-Bid);
   double spreadPoints=(Point>0.0 ? spreadPrice/Point : 0.0);
   PanelSetText("TimeValue",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),PANEL_VALUE_X,293,C'255,218,0',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("PriceValue",DoubleToString(Bid,Digits)+" / "+DoubleToString(Ask,Digits),
                PANEL_VALUE_X,311,C'225,230,240',9,ANCHOR_RIGHT_UPPER);
   PanelSetText("SpreadValue","$"+DoubleToString(spreadPrice,Digits)+" ("+DoubleToString(spreadPoints,0)+" pts) / "+tradingPermission,
                PANEL_VALUE_X,329,permissionColor,8,ANCHOR_RIGHT_UPPER);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| MT4 event handlers                                                |
//+------------------------------------------------------------------+
int OnInit()
  {
   string inputError="";
   if(!ValidateUserInputs(inputError))
     {
      Print("GoldSeek: invalid input configuration - ",inputError);
      return(INIT_PARAMETERS_INCORRECT);
     }

   InitializeCalibration();
   ClearDirectionTracker(g_trackerUp);
   ClearDirectionTracker(g_trackerDown);
   g_market.modeNoise=0.20;
   g_market.modeDrift=0.20;
   g_market.modeImpulse=0.20;
   g_market.modeExhaustion=0.20;
   g_market.modeShock=0.20;
   g_lastClosedM1=iTime(Symbol(),PERIOD_M1,1);
   g_resetTime=TimeCurrent();
   g_freshM1Bars=0;
   g_reconfiguredInputs=(ReadPersistent("Reconfigure",0.0)>0.5);
   DeletePersistent("Reconfigure");

   if(HasSufficientData()) ComputeMarketSnapshot(false);
   int ticket=FindOpenEAOrder();
   if(ticket>0) RecoverActiveTrade(ticket);
   else ResetForFreshCycle(TimeCurrent());
   if(g_reconfiguredInputs && g_activeTicket>0) ApplyInputExits();

   EntriesToday();
   CreateStatusPanel();
   if(HasSufficientData()) ShowStatus(true);
   else ShowWaitingStatus();
   if(!EventSetTimer(1))
      Print("GoldSeek: warning - one-second timer could not be started; tick events remain active.");
   Print("GoldSeek Adaptive EA V3 initialized symbol=",Symbol(),
          " no EA spread/slippage veto; actual execution costs remain auditable.");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(reason==REASON_PARAMETERS)
     {
      WritePersistent("Reconfigure",1.0);
      GlobalVariablesFlush();
     }
   PersistActiveTrade();
   EventKillTimer();
   DeleteStatusPanel();
   Comment("");
  }

void OnTick()
  {
   SuperviseActiveLifecycle();
   if(!HasSufficientData())
     {
      ShowWaitingStatus();
      return;
     }
   ProcessNewClosedM1Bar();
   if(g_state==STATE_ACQUIRED) TryOpenAcquiredTrack();
   ShowStatus();
  }

void OnTimer()
  {
   RefreshRates();
   SuperviseActiveLifecycle();
   if(!HasSufficientData())
     {
      ShowWaitingStatus();
      return;
     }
   if(g_state==STATE_ACQUIRED) TryOpenAcquiredTrack();
   ShowStatus();
  }
