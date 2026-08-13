//+------------------------------------------------------------------+
//| GoldScalperM1M5.mq4                                                |
//| M1/M5 gold scalper. One position at a time, many trades a day,     |
//| losses engineered small: any trade that fails to confirm is        |
//| scratched by software long before the broker-side stop is touched. |
//|                                                                    |
//| The Inputs tab is intentionally limited to the controls that       |
//| belong to the user: lot size, SL, TP, profit lock and trailing     |
//| stop. Everything else - signal engine, regime router, entry rails, |
//| scratch engine - is a frozen system rule in the const block below  |
//| and changes only with new backtest evidence.                       |
//|                                                                    |
//| All *_PriceUSD values are absolute Gold price movements            |
//| (2.50 means $2.50 of XAUUSD price).                                |
//|                                                                    |
//| Lineage (see /reference in the repo): execution layer from         |
//| XVISION Gold Velocity V7; five-mode regime engine, CUSUM burst     |
//| and failure-to-launch exit from GoldSeekAdaptiveEA v3; big-bar     |
//| veto and blocker panel from RegimeTrailPro; ER gate and fade       |
//| template from KeltnerFade. Decisions use CLOSED M1 bars with       |
//| CLOSED M5 context only.                                            |
//|                                                                    |
//| Arming: the EA trades whenever MT4's AutoTrading is on and the     |
//| chart's "Allow live trading" box is ticked. Attach with            |
//| AutoTrading OFF to observe signals without trading.                |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "M1/M5 gold scalper: CUSUM burst entries, regime-routed, scratch-first exits."
#property description "User inputs: lot, SL, TP, profit lock, trailing stop. System rules are frozen."
// v2.00: Inputs reduced to user trade management (GoldSeek-style);
//        MaxHold time stop removed; partial banking removed; trailing
//        is now a manual fixed distance; compiler warnings silenced.
// v1.01: audit fixes (daily-cap double count, manual-position guard,
//        fast-cut debounce, panel throttle, orphan sweep).

// ------------------------ USER INPUTS -------------------------------
input double LotSize                   = 0.01;
input double StopLoss_PriceUSD         = 2.50;   // broker-side stop; 0 = none (software scratch still active)
input double TakeProfit_PriceUSD       = 0.00;   // 0 = no fixed TP (lock/trail manage the win)
input double LockTrigger_PriceUSD      = 0.60;   // at this favorable movement, lock profit; 0 = off
input double LockedProfit_PriceUSD     = 0.10;   // SL moves to entry +/- this once triggered
input double TrailingStart_PriceUSD    = 0.90;   // trailing activates from this favorable movement; 0 = off
input double TrailingDistance_PriceUSD = 0.60;   // trailing gap behind price; 0 = off

// ------------------------ FROZEN SYSTEM RULES -----------------------
// Scalp scratch engine
const double SCRATCH_ADVERSE_USD   = 0.80;   // software fast-cut, fires before the broker stop
const int    LAUNCH_WINDOW_SECONDS = 90;     // confirm-or-scratch window
const double LAUNCH_PROGRESS_USD   = 0.30;   // must reach this inside the window
const bool   EXIT_ON_OPPOSITE      = true;   // opposite qualified signal closes the trade
const double TRAIL_STEP_USD        = 0.05;   // stop-modify hysteresis
// Entry rails
const double MAX_SPREAD_USD        = 0.35;
const double MAX_CHASE_USD         = 0.30;   // max distance from signal close at fire time
const int    COOLDOWN_SECONDS      = 120;
const int    MAX_TRADES_PER_DAY    = 15;     // 0 disables
const double MAX_DAILY_LOSS_PCT    = 1.5;    // of day-start balance; 0 disables
const double MAX_DAILY_LOSS_USD    = 0.0;    // absolute cap; stricter of the two applies
const int    MAX_CONSEC_LOSSES     = 3;      // 0 disables
const int    LOSS_PAUSE_MINUTES    = 90;     // 0 = stand down for the rest of the day
const bool   BLOCK_MANUAL_POSITION = true;   // stand aside while a non-EA position is open
const bool   USE_SESSION_FILTER    = true;
const string SESSION_WINDOWS       = "09:00-12:00,14:30-20:00";  // broker time
const string NEWS_BLACKOUTS        = "";     // "HH:MM,HH:MM" broker time; empty disables
const int    BLACKOUT_MIN_BEFORE   = 15;
const int    BLACKOUT_MIN_AFTER    = 10;
const bool   BLOCK_LATE_FRIDAY     = true;
const int    FRIDAY_CUTOFF_HOUR    = 20;     // broker hour
const bool   ALLOW_LONGS           = true;
const bool   ALLOW_SHORTS          = true;
// Momentum module
const bool   USE_MOMENTUM          = true;
const double CUSUM_ALLOWANCE       = 0.18;
const double CUSUM_DECAY           = 0.94;
const double CUSUM_TRIGGER         = 3.0;
const int    CUSUM_FRESH_BARS      = 3;
const double MIN_M1_STRENGTH       = 0.10;
const double MIN_M1_COHERENCE      = 0.75;
const double BIG_BAR_MAX_ATR       = 2.0;
const double MAX_MATURITY_M5_ATR   = 1.5;
const bool   REQUIRE_M5_ALIGNMENT  = true;
// Fade module (OFF: fading gold failed H4 stability tests; it earns
// its place in the tick backtest or stays off)
const bool   USE_FADE              = false;
const int    FADE_MA_PERIOD        = 50;
const int    FADE_ATR_PERIOD       = 24;
const double FADE_BAND_ATR         = 2.5;
const double FADE_MAX_ER           = 0.15;
const double FADE_MAX_EXPANSION    = 2.0;
// Regime router
const int    ER_PERIOD             = 20;
const double MOMENTUM_MIN_ER       = 0.30;
const double MIN_IMPULSE_DRIFT     = 0.35;
const double MIN_FADE_NOISE        = 0.40;
const double MAX_SHOCK_EXHAUST     = 0.45;
// Execution / display
const double MAX_SLIPPAGE_USD      = 0.30;
const int    MAGIC_NUMBER          = 26082601;
const bool   ECN_FALLBACK          = true;
const bool   SHOW_PANEL            = true;
const bool   WRITE_LEDGER          = true;
const bool   PUSH_ALERTS           = false;

// ------------------------ internal constants ------------------------
#define GS_CLOSE_RETRY_ATTEMPTS      3
#define GS_STOP_REPAIR_LIMIT         5
#define GS_MAX_WINDOWS               8
#define GS_PANEL_ROWS                13
#define GS_OBJ_PREFIX                "GS_row"

// ------------------------ regime / signal state ---------------------
double   g_cusumUp=0.0, g_cusumDown=0.0;
datetime g_cusumUpCross=0, g_cusumDownCross=0;
double   g_modeNoise=0.2, g_modeDrift=0.2, g_modeImpulse=0.2;
double   g_modeExhaustion=0.2, g_modeShock=0.2;
double   g_m1Comp=0.0, g_m1CompPrev=0.0, g_m5Comp=0.0;
double   g_er=0.0, g_expansion=1.0;
double   g_atrM1=0.0, g_atrM5=0.0;
int      g_fadeArmed=1;
datetime g_lastM1Bar=0;
int      g_signalDir=0;
int      g_signalModule=0;              // 1=momentum 2=fade
double   g_signalRef=0.0;
double   g_signalFadeTarget=0.0;
string   g_blocker="initialising";
string   g_lastAction="attached";

// ------------------------ position state ----------------------------
int      g_posTicket=-1;
bool     g_posLaunched=false;
double   g_posMaxFav=0.0;
bool     g_pendingClose=false;
string   g_pendingCloseReason="";
int      g_stopRepairTicket=-1;
int      g_stopRepairFailures=0;
int      g_adverseHits=0;
datetime g_lastEntryTime=0;
uint     g_lastPanelMs=0;

// ------------------------ day cache ---------------------------------
datetime g_dayStart=0;
int      g_cacheHistoryTotal=-1, g_cacheOpenTotal=-1;
int      g_tradesToday=0, g_consecLosses=0;
double   g_closedPnLToday=0.0;
datetime g_lastLossClose=0;

// ------------------------ parsed schedules --------------------------
int      g_sessStart[GS_MAX_WINDOWS], g_sessEnd[GS_MAX_WINDOWS];
int      g_sessCount=0;
int      g_newsMinute[GS_MAX_WINDOWS];
int      g_newsCount=0;

//+------------------------------------------------------------------+
//| small utilities                                                   |
//+------------------------------------------------------------------+
double Clamp(const double v,const double lo,const double hi)
{
   return(MathMax(lo,MathMin(hi,v)));
}

bool IsGoldSymbol()
{
   string s=Symbol();
   StringToUpper(s);
   return(StringFind(s,"XAU")>=0 || StringFind(s,"GOLD")>=0);
}

int LotDigits(const double step)
{
   if(step>=1.0) return(0);
   if(step>=0.1) return(1);
   if(step>=0.01) return(2);
   if(step>=0.001) return(3);
   return(4);
}

// Floors to the broker lot step; refuses (returns 0) below the broker
// minimum instead of silently rounding risk upward.
double NormaliseLots(const double requested)
{
   double minimum=MarketInfo(Symbol(),MODE_MINLOT);
   double maximum=MarketInfo(Symbol(),MODE_MAXLOT);
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(step<=0.0) step=0.01;
   if(requested<minimum-1e-10) return(0.0);
   double lots=MathFloor((requested+1e-10)/step)*step;
   lots=MathMin(maximum,lots);
   if(lots<minimum-1e-10) return(0.0);
   return(NormalizeDouble(lots,LotDigits(step)));
}

int SlippagePoints()
{
   if(MAX_SLIPPAGE_USD<=0.0 || Point<=0.0) return(0);
   return((int)MathRound(MAX_SLIPPAGE_USD/Point));
}

double BrokerModifyDistance()
{
   double stopDist=MarketInfo(Symbol(),MODE_STOPLEVEL)*Point;
   double freeze=MarketInfo(Symbol(),MODE_FREEZELEVEL)*Point;
   return(MathMax(stopDist,freeze));
}

//+------------------------------------------------------------------+
//| schedule parsing ("HH:MM-HH:MM,..." and "HH:MM,...")              |
//+------------------------------------------------------------------+
int MinuteOfString(string hhmm)
{
   StringTrimLeft(hhmm); StringTrimRight(hhmm);
   int colon=StringFind(hhmm,":");
   if(colon<0) return(-1);
   int h=(int)StringToInteger(StringSubstr(hhmm,0,colon));
   int m=(int)StringToInteger(StringSubstr(hhmm,colon+1));
   if(h<0 || h>23 || m<0 || m>59) return(-1);
   return(h*60+m);
}

bool ParseSchedules()
{
   g_sessCount=0;
   g_newsCount=0;
   string parts[];
   int n=StringSplit(SESSION_WINDOWS,',',parts);
   for(int i=0;i<n && g_sessCount<GS_MAX_WINDOWS;i++)
   {
      string w=parts[i];
      StringTrimLeft(w); StringTrimRight(w);
      if(StringLen(w)==0) continue;
      int dash=StringFind(w,"-");
      if(dash<0) return(false);
      int a=MinuteOfString(StringSubstr(w,0,dash));
      int b=MinuteOfString(StringSubstr(w,dash+1));
      if(a<0 || b<0) return(false);
      g_sessStart[g_sessCount]=a;
      g_sessEnd[g_sessCount]=b;
      g_sessCount++;
   }
   if(USE_SESSION_FILTER && g_sessCount==0) return(false);

   if(StringLen(NEWS_BLACKOUTS)>0)
   {
      string times[];
      int k=StringSplit(NEWS_BLACKOUTS,',',times);
      for(int j=0;j<k && g_newsCount<GS_MAX_WINDOWS;j++)
      {
         string t=times[j];
         StringTrimLeft(t); StringTrimRight(t);
         if(StringLen(t)==0) continue;
         int mm=MinuteOfString(t);
         if(mm<0) return(false);
         g_newsMinute[g_newsCount]=mm;
         g_newsCount++;
      }
   }
   return(true);
}

bool SessionOK(const datetime t)
{
   if(!USE_SESSION_FILTER) return(true);
   int m=TimeHour(t)*60+TimeMinute(t);
   for(int i=0;i<g_sessCount;i++)
   {
      int a=g_sessStart[i], b=g_sessEnd[i];
      bool inWindow=(a<=b) ? (m>=a && m<b) : (m>=a || m<b);   // start>end wraps midnight
      if(inWindow) return(true);
   }
   return(false);
}

bool BlackoutActive(const datetime t)
{
   if(g_newsCount==0) return(false);
   int m=TimeHour(t)*60+TimeMinute(t);
   for(int i=0;i<g_newsCount;i++)
   {
      int diff=m-g_newsMinute[i];
      if(diff>=-BLACKOUT_MIN_BEFORE && diff<=BLACKOUT_MIN_AFTER) return(true);
   }
   return(false);
}

bool LateFridayBlocked(const datetime t)
{
   if(!BLOCK_LATE_FRIDAY) return(false);
   return(TimeDayOfWeek(t)==5 && TimeHour(t)>=FRIDAY_CUTOFF_HOUR);
}

//+------------------------------------------------------------------+
//| market measurements (closed bars only)                            |
//+------------------------------------------------------------------+
// ATR-normalised multi-window velocity composite. Windows sized for
// scalp cadence; sqrt scaling keeps windows comparable.
double M1Composite(const int shift)
{
   double atr=iATR(Symbol(),PERIOD_M1,14,shift);
   if(atr<=0.0) return(0.0);
   int    w[4]={1,3,5,15};
   double wt[4]={0.35,0.30,0.20,0.15};
   double c=0.0;
   for(int i=0;i<4;i++)
      c+=wt[i]*(iClose(Symbol(),PERIOD_M1,shift)-iOpen(Symbol(),PERIOD_M1,shift+w[i]-1))/
         (atr*MathSqrt(w[i]));
   return(c);
}

double M5Composite(const int shift)
{
   double atr=iATR(Symbol(),PERIOD_M5,12,shift);
   if(atr<=0.0) return(0.0);
   int    w[4]={1,3,6,12};
   double wt[4]={0.30,0.30,0.25,0.15};
   double c=0.0;
   for(int i=0;i<4;i++)
      c+=wt[i]*(iClose(Symbol(),PERIOD_M5,shift)-iOpen(Symbol(),PERIOD_M5,shift+w[i]-1))/
         (atr*MathSqrt(w[i]));
   return(c);
}

double M1Coherence(const int shift,const int dir)
{
   double atr=iATR(Symbol(),PERIOD_M1,14,shift);
   if(atr<=0.0 || dir==0) return(0.0);
   int w[4]={1,3,5,15};
   int aligned=0;
   for(int i=0;i<4;i++)
   {
      double v=iClose(Symbol(),PERIOD_M1,shift)-iOpen(Symbol(),PERIOD_M1,shift+w[i]-1);
      if(dir*v>0.0) aligned++;
   }
   return(aligned/4.0);
}

// Signed efficiency ratio: |ER| near 1 = clean directional path.
double EfficiencyRatio(const int shift)
{
   double net=iClose(Symbol(),PERIOD_M1,shift)-iClose(Symbol(),PERIOD_M1,shift+ER_PERIOD);
   double path=0.0;
   for(int k=0;k<ER_PERIOD;k++)
      path+=MathAbs(iClose(Symbol(),PERIOD_M1,shift+k)-iClose(Symbol(),PERIOD_M1,shift+k+1));
   if(path<=0.0) return(0.0);
   return(net/path);
}

double ReturnSigmaM1(const int shift)
{
   double variance=0.0;
   bool seeded=false;
   for(int s=shift+48;s>=shift;s--)
   {
      double c=iClose(Symbol(),PERIOD_M1,s);
      double p=iClose(Symbol(),PERIOD_M1,s+1);
      if(c<=0.0 || p<=0.0) continue;
      double r=c-p;
      if(!seeded) { variance=r*r; seeded=true; }
      else variance=0.90*variance+0.10*r*r;
   }
   return(MathMax(MathSqrt(MathMax(variance,0.0)),Point));
}

void UpdateCusum(const datetime barTime)
{
   double c=iClose(Symbol(),PERIOD_M1,1);
   double p=iClose(Symbol(),PERIOD_M1,2);
   if(c<=0.0 || p<=0.0) return;
   double z=(c-p)/ReturnSigmaM1(1);
   double prevUp=g_cusumUp, prevDown=g_cusumDown;
   g_cusumUp=Clamp(MathMax(0.0,CUSUM_DECAY*g_cusumUp+z-CUSUM_ALLOWANCE),0.0,12.0);
   g_cusumDown=Clamp(MathMax(0.0,CUSUM_DECAY*g_cusumDown-z-CUSUM_ALLOWANCE),0.0,12.0);
   if(prevUp<CUSUM_TRIGGER && g_cusumUp>=CUSUM_TRIGGER)     g_cusumUpCross=barTime;
   if(prevDown<CUSUM_TRIGGER && g_cusumDown>=CUSUM_TRIGGER) g_cusumDownCross=barTime;
}

// Five-mode regime posterior (noise/drift/impulse/exhaustion/shock)
// with an IMM-style sticky prior. Feature scales follow GoldSeek v3.
void UpdateModes()
{
   double speed=0.40*MathAbs(g_m1Comp)+0.60*MathAbs(g_m5Comp);
   double accel=MathAbs(g_m1Comp-g_m1CompPrev);
   double eff=MathAbs(g_er);
   double agree=((g_m1Comp*g_m5Comp)>0.0 ? 1.0 : -1.0)*
                MathMin(MathAbs(g_m1Comp),MathAbs(g_m5Comp));
   double lastRet=iClose(Symbol(),PERIOD_M1,1)-iClose(Symbol(),PERIOD_M1,2);
   double lastZ=lastRet/ReturnSigmaM1(1);

   double ll[5];
   ArrayInitialize(ll,0.0);
   ll[0]=1.35*(1.0-eff)-0.45*speed-0.25*MathAbs(g_expansion-1.0);
   ll[1]=1.20*eff+0.45*speed+0.35*MathMax(agree,0.0)-0.35*accel;
   ll[2]=0.90*eff+0.75*speed+0.70*MathMax(accel,0.0)+0.35*MathMax(g_expansion-1.0,0.0);
   ll[3]=0.65*speed+0.90*MathMax(-agree,0.0)+0.65*(1.0-eff)+0.30*accel;
   ll[4]=1.15*MathMax(g_expansion-1.65,0.0)+0.55*MathMax(MathAbs(lastZ)-2.0,0.0);

   double mx=ll[0];
   for(int i=1;i<5;i++) mx=MathMax(mx,ll[i]);
   double like[5];
   ArrayInitialize(like,0.0);
   double total=0.0;
   for(int j=0;j<5;j++)
   {
      like[j]=MathExp(Clamp(ll[j]-mx,-50.0,50.0));
      total+=like[j];
   }
   if(total<=0.0) total=1.0;

   double prev[5];
   ArrayInitialize(prev,0.0);
   prev[0]=g_modeNoise; prev[1]=g_modeDrift; prev[2]=g_modeImpulse;
   prev[3]=g_modeExhaustion; prev[4]=g_modeShock;
   double upd[5];
   ArrayInitialize(upd,0.0);
   double updTotal=0.0;
   for(int m=0;m<5;m++)
   {
      double prior=0.72*prev[m]+0.28*(1.0-prev[m])/4.0;
      upd[m]=prior*(like[m]/total);
      updTotal+=upd[m];
   }
   if(updTotal<=0.0) updTotal=1.0;
   g_modeNoise=upd[0]/updTotal;
   g_modeDrift=upd[1]/updTotal;
   g_modeImpulse=upd[2]/updTotal;
   g_modeExhaustion=upd[3]/updTotal;
   g_modeShock=upd[4]/updTotal;
}

void UpdateRegime(const datetime barTime)
{
   g_m1CompPrev=g_m1Comp;
   g_m1Comp=M1Composite(1);
   g_m5Comp=M5Composite(1);
   g_er=EfficiencyRatio(1);
   g_atrM1=iATR(Symbol(),PERIOD_M1,14,1);
   g_atrM5=iATR(Symbol(),PERIOD_M5,12,1);
   double atrSlow=iATR(Symbol(),PERIOD_M1,48,1);
   g_expansion=(atrSlow>0.0 ? Clamp(iATR(Symbol(),PERIOD_M1,6,1)/atrSlow,0.25,4.0) : 1.0);
   UpdateCusum(barTime);
   UpdateModes();
}

//+------------------------------------------------------------------+
//| signal modules (evaluated once per closed M1 bar)                 |
//+------------------------------------------------------------------+
int EvaluateMomentum(string &blocker)
{
   if(!USE_MOMENTUM) { blocker="momentum module off"; return(0); }
   if(g_modeShock+g_modeExhaustion>MAX_SHOCK_EXHAUST)
      { blocker=StringFormat("shock/exhaust %.2f",g_modeShock+g_modeExhaustion); return(0); }
   if(g_modeImpulse+g_modeDrift<MIN_IMPULSE_DRIFT)
      { blocker=StringFormat("impulse+drift %.2f",g_modeImpulse+g_modeDrift); return(0); }

   int dir=0;
   datetime cross=0;
   if(g_cusumUp>=CUSUM_TRIGGER && g_cusumUp-g_cusumDown>=CUSUM_TRIGGER*0.5)
      { dir=1; cross=g_cusumUpCross; }
   else if(g_cusumDown>=CUSUM_TRIGGER && g_cusumDown-g_cusumUp>=CUSUM_TRIGGER*0.5)
      { dir=-1; cross=g_cusumDownCross; }
   if(dir==0) { blocker="no CUSUM burst"; return(0); }
   if(cross==0 || (iTime(Symbol(),PERIOD_M1,1)-cross)>CUSUM_FRESH_BARS*60)
      { blocker="burst stale"; return(0); }

   if(dir*g_er<=0.0 || MathAbs(g_er)<MOMENTUM_MIN_ER)
      { blocker=StringFormat("ER %.2f",g_er); return(0); }
   if(dir*g_m1Comp<MIN_M1_STRENGTH)
      { blocker=StringFormat("M1 strength %.2f",dir*g_m1Comp); return(0); }
   if(M1Coherence(1,dir)<MIN_M1_COHERENCE)
      { blocker="M1 coherence"; return(0); }

   double body=iClose(Symbol(),PERIOD_M1,1)-iOpen(Symbol(),PERIOD_M1,1);
   if(dir*body<=0.0) { blocker="trigger bar body against"; return(0); }

   double tr=iHigh(Symbol(),PERIOD_M1,1)-iLow(Symbol(),PERIOD_M1,1);
   if(g_atrM1>0.0 && tr>BIG_BAR_MAX_ATR*g_atrM1)
      { blocker="oversized trigger bar"; return(0); }

   // move maturity: never chase a burst that already ran
   double lo=iLow(Symbol(),PERIOD_M1,1), hi=iHigh(Symbol(),PERIOD_M1,1);
   for(int k=2;k<=31;k++)
   {
      lo=MathMin(lo,iLow(Symbol(),PERIOD_M1,k));
      hi=MathMax(hi,iHigh(Symbol(),PERIOD_M1,k));
   }
   double close1=iClose(Symbol(),PERIOD_M1,1);
   double maturity=(dir>0 ? close1-lo : hi-close1);
   if(g_atrM5>0.0 && maturity/g_atrM5>MAX_MATURITY_M5_ATR)
      { blocker="move mature - no chase"; return(0); }

   if(REQUIRE_M5_ALIGNMENT)
   {
      if(dir*g_m5Comp<=0.0) { blocker="M5 velocity against"; return(0); }
      double e20=iMA(Symbol(),PERIOD_M5,20,0,MODE_EMA,PRICE_CLOSE,1);
      double e30=iMA(Symbol(),PERIOD_M5,30,0,MODE_EMA,PRICE_CLOSE,1);
      if(g_atrM5>0.0 && dir*(e20-e30)/g_atrM5<-0.05)
         { blocker="M5 ribbon against"; return(0); }
   }

   blocker="";
   return(dir);
}

int EvaluateFade(string &blocker,double &target)
{
   target=0.0;
   if(!USE_FADE) { blocker="fade module off"; return(0); }
   if(g_modeShock+g_modeExhaustion>MAX_SHOCK_EXHAUST) { blocker="shock/exhaust"; return(0); }
   if(g_modeNoise<MIN_FADE_NOISE)
      { blocker=StringFormat("noise %.2f",g_modeNoise); return(0); }
   if(MathAbs(g_er)>FADE_MAX_ER) { blocker="trending - no fade"; return(0); }
   if(g_expansion>FADE_MAX_EXPANSION) { blocker="vol expanding - no fade"; return(0); }

   double mid=iMA(Symbol(),PERIOD_M1,FADE_MA_PERIOD,0,MODE_SMA,PRICE_CLOSE,1);
   double atr=iATR(Symbol(),PERIOD_M1,FADE_ATR_PERIOD,1);
   if(mid<=0.0 || atr<=0.0) { blocker="fade data"; return(0); }
   double up=mid+FADE_BAND_ATR*atr;
   double dn=mid-FADE_BAND_ATR*atr;
   double close1=iClose(Symbol(),PERIOD_M1,1);

   // re-arm only after price returns inside the bands: one fade per excursion
   if(close1<up && close1>dn) { g_fadeArmed=1; blocker="inside bands"; return(0); }
   if(g_fadeArmed==0) { blocker="excursion already faded"; return(0); }

   int dir=0;
   if(close1>up) dir=-1;
   if(close1<dn) dir=1;
   if(dir==0) { blocker="no band break"; return(0); }
   g_fadeArmed=0;
   target=mid;
   blocker="";
   return(dir);
}

//+------------------------------------------------------------------+
//| day cache: trades, closed PnL, consecutive-loss streak            |
//+------------------------------------------------------------------+
datetime BrokerDayStart()
{
   datetime d=iTime(Symbol(),PERIOD_D1,0);
   if(d<=0) d=StrToTime(TimeToString(TimeCurrent(),TIME_DATE));
   return(d);
}

void InvalidateDayCache()
{
   g_cacheHistoryTotal=-1;
   g_cacheOpenTotal=-1;
}

void RefreshDayCache()
{
   datetime start=BrokerDayStart();
   int historyTotal=OrdersHistoryTotal();
   int openTotal=OrdersTotal();
   if(start==g_dayStart && historyTotal==g_cacheHistoryTotal && openTotal==g_cacheOpenTotal)
      return;

   datetime closeTimes[200];
   double   profits[200];
   datetime opens[400];
   int      z=0;
   for(z=0;z<200;z++) { closeTimes[z]=0; profits[z]=0.0; }
   for(z=0;z<400;z++) opens[z]=0;
   int      n=0;
   int      oc=0;
   double pnl=0.0;

   for(int h=OrdersHistoryTotal()-1;h>=0;h--)
   {
      if(!OrderSelect(h,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MAGIC_NUMBER) continue;
      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) continue;
      if(OrderOpenTime()>=start && oc<400) opens[oc++]=OrderOpenTime();
      if(OrderCloseTime()>=start && n<200)
      {
         double p=OrderProfit()+OrderSwap()+OrderCommission();
         pnl+=p;
         closeTimes[n]=OrderCloseTime();
         profits[n]=p;
         n++;
      }
   }
   for(int t=OrdersTotal()-1;t>=0;t--)
   {
      if(!OrderSelect(t,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MAGIC_NUMBER) continue;
      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) continue;
      if(OrderOpenTime()>=start && oc<400) opens[oc++]=OrderOpenTime();
   }

   // Tickets split by partial/manual partial closes share an open time:
   // count unique open times, not tickets, so the daily cap counts
   // true entries.
   int trades=0;
   if(oc>0)
   {
      ArraySort(opens,oc,0,MODE_ASCEND);
      trades=1;
      for(int u=1;u<oc;u++)
         if(opens[u]!=opens[u-1]) trades++;
   }

   // sort today's closed trades by close time (insertion sort, n is small)
   for(int i=1;i<n;i++)
   {
      datetime ct=closeTimes[i];
      double pf=profits[i];
      int j=i-1;
      while(j>=0 && closeTimes[j]>ct)
      {
         closeTimes[j+1]=closeTimes[j];
         profits[j+1]=profits[j];
         j--;
      }
      closeTimes[j+1]=ct;
      profits[j+1]=pf;
   }
   int streak=0;
   datetime lastLoss=0;
   for(int s=n-1;s>=0;s--)
   {
      if(profits[s]<0.0)
      {
         streak++;
         if(lastLoss==0) lastLoss=closeTimes[s];
      }
      else break;
   }

   g_dayStart=start;
   g_cacheHistoryTotal=historyTotal;
   g_cacheOpenTotal=openTotal;
   g_tradesToday=trades;
   g_closedPnLToday=pnl;
   g_consecLosses=streak;
   g_lastLossClose=lastLoss;
}

double DailyLossLimit()
{
   double limit=0.0;
   if(MAX_DAILY_LOSS_PCT>0.0)
   {
      double dayStartBalance=AccountBalance()-g_closedPnLToday;
      limit=dayStartBalance*MAX_DAILY_LOSS_PCT/100.0;
   }
   if(MAX_DAILY_LOSS_USD>0.0)
      limit=(limit>0.0 ? MathMin(limit,MAX_DAILY_LOSS_USD) : MAX_DAILY_LOSS_USD);
   return(limit);
}

//+------------------------------------------------------------------+
//| ledger                                                            |
//+------------------------------------------------------------------+
void LedgerWrite(const string eventName,const int dir,const double lots,
                 const double price,const double profit,const string reason)
{
   if(!WRITE_LEDGER) return;
   string file=StringFormat("GoldScalper_%s_%d.csv",Symbol(),AccountNumber());
   int h=FileOpen(file,FILE_CSV|FILE_READ|FILE_WRITE,';');
   if(h==INVALID_HANDLE) return;
   if(FileSize(h)==0)
      FileWrite(h,"time","event","dir","lots","price","profit_usd","reason",
                "spread","er","noise","drift","impulse","exhaust","shock");
   FileSeek(h,0,SEEK_END);
   RefreshRates();
   FileWrite(h,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),eventName,
             (dir>0?"BUY":(dir<0?"SELL":"-")),DoubleToString(lots,2),
             DoubleToString(price,Digits),DoubleToString(profit,2),reason,
             DoubleToString(Ask-Bid,Digits),DoubleToString(g_er,2),
             DoubleToString(g_modeNoise,2),DoubleToString(g_modeDrift,2),
             DoubleToString(g_modeImpulse,2),DoubleToString(g_modeExhaustion,2),
             DoubleToString(g_modeShock,2));
   FileClose(h);
}

//+------------------------------------------------------------------+
//| position discovery + per-ticket scalp state                       |
//+------------------------------------------------------------------+
int FindManagedTicket()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MAGIC_NUMBER) continue;
      if(OrderType()==OP_BUY || OrderType()==OP_SELL) return(OrderTicket());
   }
   return(-1);
}

double ProfitMovementSelected()
{
   RefreshRates();
   if(OrderType()==OP_BUY) return(Bid-OrderOpenPrice());
   if(OrderType()==OP_SELL) return(OrderOpenPrice()-Ask);
   return(0.0);
}

string TicketKey(const int ticket,const string suffix)
{
   return(StringFormat("GS1.%d.%d.%d.%s",AccountNumber(),MAGIC_NUMBER,ticket,suffix));
}

void PersistTicketState(const int ticket)
{
   if(IsTesting()) return;
   GlobalVariableSet(TicketKey(ticket,"MF"),g_posMaxFav);
   GlobalVariableSet(TicketKey(ticket,"LN"),g_posLaunched?1.0:0.0);
}

void DropTicketState(const int ticket)
{
   if(IsTesting() || ticket<0) return;
   GlobalVariableDel(TicketKey(ticket,"MF"));
   GlobalVariableDel(TicketKey(ticket,"LN"));
}

// Adopt a position found in the terminal (fresh entry or restart).
void AdoptTicket(const int ticket)
{
   g_posTicket=ticket;
   g_adverseHits=0;
   g_posMaxFav=MathMax(0.0,ProfitMovementSelected());
   g_posLaunched=(g_posMaxFav>=LAUNCH_PROGRESS_USD);
   if(!IsTesting())
   {
      if(GlobalVariableCheck(TicketKey(ticket,"MF")))
         g_posMaxFav=MathMax(g_posMaxFav,GlobalVariableGet(TicketKey(ticket,"MF")));
      if(GlobalVariableCheck(TicketKey(ticket,"LN")))
         g_posLaunched=(g_posLaunched || GlobalVariableGet(TicketKey(ticket,"LN"))>0.5);
      PersistTicketState(ticket);
   }
}

void ForgetPosition()
{
   DropTicketState(g_posTicket);
   g_posTicket=-1;
   g_adverseHits=0;
   g_posLaunched=false;
   g_posMaxFav=0.0;
   g_pendingClose=false;
   g_pendingCloseReason="";
   g_stopRepairTicket=-1;
   g_stopRepairFailures=0;
}

//+------------------------------------------------------------------+
//| close / entry execution                                           |
//+------------------------------------------------------------------+
bool IsRetryableTradeError(const int error)
{
   return(error==4 || error==6 || error==128 || error==135 || error==136 ||
          error==137 || error==138 || error==146);
}

bool CloseSelectedOrder(const string reason)
{
   int ticket=OrderTicket();
   double lots=OrderLots();
   int type=OrderType();
   int finalError=0;
   for(int attempt=1;attempt<=GS_CLOSE_RETRY_ATTEMPTS;attempt++)
   {
      if(!OrderSelect(ticket,SELECT_BY_TICKET)) { finalError=GetLastError(); break; }
      RefreshRates();
      double price=(type==OP_BUY ? Bid : Ask);
      ResetLastError();
      if(OrderClose(ticket,lots,price,SlippagePoints(),clrSilver))
      {
         double profit=0.0;
         if(OrderSelect(ticket,SELECT_BY_TICKET,MODE_HISTORY))
            profit=OrderProfit()+OrderSwap()+OrderCommission();
         LedgerWrite("EXIT",(type==OP_BUY?1:-1),lots,price,profit,reason);
         if(PUSH_ALERTS)
            SendNotification(StringFormat("GoldScalper closed %.2f lot: %s (%.2f)",lots,reason,profit));
         g_lastAction="CLOSED: "+reason;
         ForgetPosition();
         InvalidateDayCache();
         Print("GoldScalper: closed ticket ",ticket,": ",reason);
         return(true);
      }
      finalError=GetLastError();
      if(!IsRetryableTradeError(finalError)) break;
      RefreshRates();
      if(!IsTesting()) Sleep(100);
   }
   g_pendingClose=true;
   g_pendingCloseReason=reason;
   g_lastAction=StringFormat("CLOSE RETRY PENDING %d",finalError);
   Print("GoldScalper: close pending, ticket ",ticket,", error ",finalError,", reason ",reason);
   return(false);
}

bool SendEntry(const int dir,const int module,const double reference,const double fadeTarget)
{
   RefreshRates();
   double ask=Ask, bid=Bid;
   if(ask<=0.0 || bid<=0.0 || ask<bid)
      { g_lastAction="ENTRY BLOCKED: NO QUOTE"; return(false); }
   double spread=ask-bid;
   if(MAX_SPREAD_USD>0.0 && spread>MAX_SPREAD_USD)
      { g_lastAction="ENTRY BLOCKED: SPREAD"; return(false); }
   double entry=(dir>0 ? ask : bid);
   if(MAX_CHASE_USD>0.0 && MathAbs(entry-reference)>MAX_CHASE_USD)
      { g_lastAction="ENTRY BLOCKED: PRICE MOVED - NO CHASE"; return(false); }

   double lots=NormaliseLots(LotSize);
   if(lots<=0.0) { g_lastAction="ENTRY BLOCKED: LOT INVALID"; return(false); }
   int type=(dir>0 ? OP_BUY : OP_SELL);
   if(AccountFreeMarginCheck(Symbol(),type,lots)<=0.0)
      { g_lastAction="ENTRY BLOCKED: MARGIN"; return(false); }

   double sl=(StopLoss_PriceUSD>0.0 ? (dir>0 ? entry-StopLoss_PriceUSD : entry+StopLoss_PriceUSD) : 0.0);
   double tp=0.0;
   if(TakeProfit_PriceUSD>0.0)
      tp=(dir>0 ? entry+TakeProfit_PriceUSD : entry-TakeProfit_PriceUSD);
   else if(module==2 && fadeTarget>0.0)
   {
      double minDist=BrokerModifyDistance();
      if(MathAbs(fadeTarget-entry)>minDist && dir*(fadeTarget-entry)>0.0) tp=fadeTarget;
   }
   sl=(sl>0.0 ? NormalizeDouble(sl,Digits) : 0.0);
   tp=(tp>0.0 ? NormalizeDouble(tp,Digits) : 0.0);

   string comment=StringFormat(module==2 ? "GSF_%d" : "GSM_%d",(int)TimeCurrent());
   ResetLastError();
   int ticket=OrderSend(Symbol(),type,lots,entry,SlippagePoints(),sl,tp,comment,MAGIC_NUMBER,0,
                        (dir>0 ? clrLime : clrTomato));
   int firstError=GetLastError();
   bool usedFallback=false;
   if(ticket<0 && ECN_FALLBACK && firstError==ERR_INVALID_STOPS)
   {
      RefreshRates();
      entry=(dir>0 ? Ask : Bid);
      if(MAX_SPREAD_USD>0.0 && Ask-Bid>MAX_SPREAD_USD)
         { g_lastAction="ENTRY ABORTED: SPREAD"; return(false); }
      ResetLastError();
      ticket=OrderSend(Symbol(),type,lots,entry,SlippagePoints(),0.0,0.0,comment,MAGIC_NUMBER,0,
                       (dir>0 ? clrLime : clrTomato));
      usedFallback=(ticket>=0);
      firstError=GetLastError();
   }
   if(ticket<0)
   {
      g_lastAction=StringFormat("ENTRY FAILED %d",firstError);
      Print("GoldScalper: OrderSend failed, error ",firstError);
      return(false);
   }

   g_lastEntryTime=TimeCurrent();
   InvalidateDayCache();

   if(OrderSelect(ticket,SELECT_BY_TICKET))
   {
      double open=OrderOpenPrice();
      double exactSL=(StopLoss_PriceUSD>0.0 ?
         (dir>0 ? open-StopLoss_PriceUSD : open+StopLoss_PriceUSD) : 0.0);
      double exactTP=(TakeProfit_PriceUSD>0.0 ?
         (dir>0 ? open+TakeProfit_PriceUSD : open-TakeProfit_PriceUSD) : OrderTakeProfit());
      exactSL=(exactSL>0.0 ? NormalizeDouble(exactSL,Digits) : 0.0);
      exactTP=(exactTP>0.0 ? NormalizeDouble(exactTP,Digits) : 0.0);
      if(usedFallback || MathAbs(OrderStopLoss()-exactSL)>Point || MathAbs(OrderTakeProfit()-exactTP)>Point)
      {
         ResetLastError();
         if(!OrderModify(ticket,open,exactSL,exactTP,0,clrNONE) && StopLoss_PriceUSD>0.0)
         {
            // refuse to run unprotected: close rather than hold a naked position
            Print("GoldScalper: stop anchoring failed, error ",GetLastError());
            g_pendingClose=true;
            g_pendingCloseReason="PROTECTIVE STOP COULD NOT BE SET";
            if(OrderSelect(ticket,SELECT_BY_TICKET) && CloseSelectedOrder(g_pendingCloseReason))
            {
               g_lastAction="ENTRY OPENED THEN CLOSED: STOP FAILED";
               return(false);
            }
            g_lastAction="UNPROTECTED ENTRY: CLOSE PENDING";
            AdoptTicket(ticket);
            return(true);
         }
      }
      AdoptTicket(ticket);
   }
   else
      g_posTicket=ticket;

   g_lastAction=StringFormat("OPENED %s %.2f LOT (%s)",dir>0?"BUY":"SELL",lots,
                             module==2?"FADE":"MOMENTUM");
   LedgerWrite("ENTRY",dir,lots,entry,0.0,module==2?"fade":"momentum");
   if(PUSH_ALERTS)
      SendNotification(StringFormat("GoldScalper opened %s %.2f lot (%s)",
                       dir>0?"BUY":"SELL",lots,module==2?"fade":"momentum"));
   return(true);
}

//+------------------------------------------------------------------+
//| stop protection + scalp management (every tick)                   |
//+------------------------------------------------------------------+
bool EnsureStopProtection()
{
   if(StopLoss_PriceUSD<=0.0) return(true);
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
   double repair=(isBuy ? OrderOpenPrice()-StopLoss_PriceUSD : OrderOpenPrice()+StopLoss_PriceUSD);
   double minDist=BrokerModifyDistance();
   if(isBuy) repair=MathMin(repair,Bid-minDist);
   else      repair=MathMax(repair,Ask+minDist);
   repair=NormalizeDouble(repair,Digits);
   ResetLastError();
   if(OrderModify(ticket,OrderOpenPrice(),repair,OrderTakeProfit(),0,clrNONE))
   {
      g_stopRepairFailures=0;
      g_lastAction="PROTECTIVE STOP REPAIRED";
      return(true);
   }
   g_stopRepairFailures++;
   Print("GoldScalper: stop repair failed, attempt ",g_stopRepairFailures,
         ", error ",GetLastError());
   if(g_stopRepairFailures>=GS_STOP_REPAIR_LIMIT)
      CloseSelectedOrder("UNPROTECTED POSITION");
   return(false);
}

void ApplyStopManagement()
{
   RefreshRates();
   bool isBuy=(OrderType()==OP_BUY);
   double desired=OrderStopLoss();
   bool haveDesired=(desired>0.0);

   // profit lock: once movement reached the trigger, the stop holds at
   // least entry +/- LockedProfit for the rest of the trade
   if(LockTrigger_PriceUSD>0.0 && g_posMaxFav>=LockTrigger_PriceUSD)
   {
      double lock=(isBuy ? OrderOpenPrice()+LockedProfit_PriceUSD
                         : OrderOpenPrice()-LockedProfit_PriceUSD);
      if(!haveDesired || (isBuy && lock>desired) || (!isBuy && lock<desired))
         { desired=lock; haveDesired=true; }
   }
   // manual trailing stop: fixed distance behind price once started
   if(TrailingStart_PriceUSD>0.0 && TrailingDistance_PriceUSD>0.0 &&
      g_posMaxFav>=TrailingStart_PriceUSD)
   {
      double trail=(isBuy ? Bid-TrailingDistance_PriceUSD : Ask+TrailingDistance_PriceUSD);
      if(!haveDesired || (isBuy && trail>desired) || (!isBuy && trail<desired))
         { desired=trail; haveDesired=true; }
   }
   if(!haveDesired) return;

   double minDist=BrokerModifyDistance();
   if(isBuy) desired=MathMin(desired,Bid-minDist);
   else      desired=MathMax(desired,Ask+minDist);
   desired=NormalizeDouble(desired,Digits);

   double oldStop=OrderStopLoss();
   bool improves=(oldStop<=0.0 || (isBuy && desired>oldStop) || (!isBuy && desired<oldStop));
   if(!improves) return;
   if(oldStop>0.0 && MathAbs(desired-oldStop)<MathMax(TRAIL_STEP_USD,Point)) return;

   ResetLastError();
   if(!OrderModify(OrderTicket(),OrderOpenPrice(),desired,OrderTakeProfit(),0,clrDodgerBlue))
   {
      int error=GetLastError();
      if(error!=ERR_NO_RESULT)
         Print("GoldScalper: stop modify failed, error ",error);
   }
}

void ManagePosition()
{
   int ticket=FindManagedTicket();
   if(ticket<0)
   {
      if(g_posTicket>=0) { ForgetPosition(); InvalidateDayCache(); }
      return;
   }
   if(!OrderSelect(ticket,SELECT_BY_TICKET)) return;
   if(ticket!=g_posTicket) AdoptTicket(ticket);

   if(g_pendingClose) { CloseSelectedOrder(g_pendingCloseReason); return; }
   if(!EnsureStopProtection()) return;

   double movement=ProfitMovementSelected();
   if(movement>g_posMaxFav)
   {
      bool crossedLaunch=(!g_posLaunched && movement>=LAUNCH_PROGRESS_USD);
      if(crossedLaunch) g_posLaunched=true;
      if(crossedLaunch || movement-g_posMaxFav>0.05)
      {
         g_posMaxFav=movement;
         PersistTicketState(ticket);
      }
      else
         g_posMaxFav=movement;
   }

   // 1. fast cut: the working loss limit, inside the broker stop.
   //    Movement is measured close-side, so a one-tick spread spike can
   //    breach it; require two consecutive breaches before cutting.
   if(SCRATCH_ADVERSE_USD>0.0 && movement<=-SCRATCH_ADVERSE_USD)
   {
      g_adverseHits++;
      if(g_adverseHits>=2) { CloseSelectedOrder("FAST CUT"); return; }
   }
   else
      g_adverseHits=0;

   // 2. confirm-or-scratch: no launch inside the window = dead trade
   if(LAUNCH_WINDOW_SECONDS>0 && !g_posLaunched &&
      TimeCurrent()-OrderOpenTime()>=LAUNCH_WINDOW_SECONDS)
      { CloseSelectedOrder("FAILURE TO LAUNCH"); return; }

   ApplyStopManagement();
}

//+------------------------------------------------------------------+
//| entry gating                                                      |
//+------------------------------------------------------------------+
bool EntryAllowed(const int dir,string &blocker)
{
   if(dir>0 && !ALLOW_LONGS)  { blocker="longs disabled"; return(false); }
   if(dir<0 && !ALLOW_SHORTS) { blocker="shorts disabled"; return(false); }
   if(!IsTesting() && !IsTradeAllowed()) { blocker="AutoTrading off"; return(false); }
   if(FindManagedTicket()>=0) { blocker="position open"; return(false); }
   if(BLOCK_MANUAL_POSITION)
   {
      for(int i=OrdersTotal()-1;i>=0;i--)
      {
         if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
         if(OrderSymbol()!=Symbol() || OrderMagicNumber()==MAGIC_NUMBER) continue;
         if(OrderType()==OP_BUY || OrderType()==OP_SELL)
            { blocker="manual/other position on symbol"; return(false); }
      }
   }

   datetime now=TimeCurrent();
   if(!SessionOK(now)) { blocker="outside session"; return(false); }
   if(BlackoutActive(now)) { blocker="news blackout"; return(false); }
   if(LateFridayBlocked(now)) { blocker="Friday cutoff"; return(false); }
   if(COOLDOWN_SECONDS>0 && g_lastEntryTime>0 && now-g_lastEntryTime<COOLDOWN_SECONDS)
      { blocker="cooldown"; return(false); }

   RefreshDayCache();
   if(MAX_TRADES_PER_DAY>0 && g_tradesToday>=MAX_TRADES_PER_DAY)
      { blocker="daily trade cap"; return(false); }
   double lossLimit=DailyLossLimit();
   if(lossLimit>0.0 && g_closedPnLToday<=-lossLimit)
      { blocker="DAILY LOSS BRAKE"; return(false); }
   if(MAX_CONSEC_LOSSES>0 && g_consecLosses>=MAX_CONSEC_LOSSES)
   {
      if(LOSS_PAUSE_MINUTES<=0) { blocker="loss streak - down for the day"; return(false); }
      if(g_lastLossClose>0 && now-g_lastLossClose<LOSS_PAUSE_MINUTES*60)
         { blocker="loss streak pause"; return(false); }
   }
   blocker="";
   return(true);
}

//+------------------------------------------------------------------+
//| panel                                                             |
//+------------------------------------------------------------------+
void PanelRow(const int row,const string text,const color clr)
{
   string name=GS_OBJ_PREFIX+IntegerToString(row);
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,8);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,16+row*15);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
   }
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
}

void UpdatePanel(const bool force=false)
{
   if(!SHOW_PANEL) return;
   uint nowMs=GetTickCount();
   if(!force && nowMs-g_lastPanelMs<300) return;   // gold ticks fast; don't redraw 13 labels per tick
   g_lastPanelMs=nowMs;
   RefreshRates();
   RefreshDayCache();
   double lossLimit=DailyLossLimit();
   bool armed=(IsTesting() || IsTradeAllowed());

   PanelRow(0,"GoldScalper M1/M5 v2  "+Symbol(),clrWhite);
   PanelRow(1,armed ? "ARMED - AutoTrading ON" :
              "STANDBY - AutoTrading OFF (signals only)",
              armed ? clrLimeGreen : clrOrange);
   PanelRow(2,StringFormat("Regime  N %.2f  D %.2f  I %.2f  X %.2f  S %.2f",
            g_modeNoise,g_modeDrift,g_modeImpulse,g_modeExhaustion,g_modeShock),clrSilver);
   PanelRow(3,StringFormat("ER %.2f   CUSUM up %.1f / dn %.1f   exp %.2f",
            g_er,g_cusumUp,g_cusumDown,g_expansion),clrSilver);
   PanelRow(4,StringFormat("Spread %.2f (max %.2f)   ATR M1 %.2f  M5 %.2f",
            Ask-Bid,MAX_SPREAD_USD,g_atrM1,g_atrM5),
            (MAX_SPREAD_USD>0.0 && Ask-Bid>MAX_SPREAD_USD) ? clrOrange : clrSilver);
   PanelRow(5,StringFormat("Session %s   blackout %s   Friday %s",
            SessionOK(TimeCurrent())?"OPEN":"closed",
            BlackoutActive(TimeCurrent())?"ACTIVE":"clear",
            LateFridayBlocked(TimeCurrent())?"BLOCKED":"ok"),clrSilver);
   PanelRow(6,StringFormat("Today  trades %d/%s   closed PnL %.2f%s",
            g_tradesToday,
            MAX_TRADES_PER_DAY>0?IntegerToString(MAX_TRADES_PER_DAY):"-",
            g_closedPnLToday,
            lossLimit>0.0?StringFormat("  (brake -%.0f)",lossLimit):""),
            (lossLimit>0.0 && g_closedPnLToday<=-lossLimit) ? clrOrange : clrSilver);
   PanelRow(7,StringFormat("Loss streak %d/%s",g_consecLosses,
            MAX_CONSEC_LOSSES>0?IntegerToString(MAX_CONSEC_LOSSES):"-"),
            (MAX_CONSEC_LOSSES>0 && g_consecLosses>=MAX_CONSEC_LOSSES)?clrOrange:clrSilver);

   int ticket=FindManagedTicket();
   if(ticket>=0 && OrderSelect(ticket,SELECT_BY_TICKET))
      PanelRow(8,StringFormat("POSITION %s %.2f lot  move %.2f  maxFav %.2f  %s",
               OrderType()==OP_BUY?"BUY":"SELL",OrderLots(),
               ProfitMovementSelected(),g_posMaxFav,
               g_posLaunched?"launched":"confirm window"),
               OrderType()==OP_BUY?clrDodgerBlue:clrTomato);
   else
      PanelRow(8,"POSITION none",clrGray);

   PanelRow(9,StringFormat("Signal  %s%s",
            g_signalDir>0?"BUY":(g_signalDir<0?"SELL":"none"),
            g_signalDir!=0?(g_signalModule==2?" (fade)":" (momentum)"):""),
            g_signalDir>0?clrDodgerBlue:(g_signalDir<0?clrTomato:clrGray));
   PanelRow(10,(StringLen(g_blocker)==0 ? "Status: watching" : "Blocked by: "+g_blocker),
            StringLen(g_blocker)==0?clrLimeGreen:clrOrange);
   PanelRow(11,"Last: "+g_lastAction,clrSilver);
   PanelRow(12,StringFormat("SL %.2f  TP %s  lock %.2f@%.2f  trail %.2f@%.2f  scratch %.2f/%.2f-%ds",
            StopLoss_PriceUSD,
            TakeProfit_PriceUSD>0.0?DoubleToString(TakeProfit_PriceUSD,2):"off",
            LockedProfit_PriceUSD,LockTrigger_PriceUSD,
            TrailingDistance_PriceUSD,TrailingStart_PriceUSD,
            SCRATCH_ADVERSE_USD,LAUNCH_PROGRESS_USD,LAUNCH_WINDOW_SECONDS),clrGray);
}

//+------------------------------------------------------------------+
//| input validation + orphan sweep                                   |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   if(LotSize<=0.0)
   {
      Print("GoldScalper: LotSize must be positive.");
      return(false);
   }
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(step>0.0 && NormaliseLots(LotSize)<=0.0)
   {
      Print("GoldScalper: LotSize ",DoubleToString(LotSize,2),
            " is below the broker minimum ",
            DoubleToString(MarketInfo(Symbol(),MODE_MINLOT),LotDigits(step)),".");
      return(false);
   }
   if(StopLoss_PriceUSD<0.0 || TakeProfit_PriceUSD<0.0 ||
      LockTrigger_PriceUSD<0.0 || LockedProfit_PriceUSD<0.0 ||
      TrailingStart_PriceUSD<0.0 || TrailingDistance_PriceUSD<0.0)
   {
      Print("GoldScalper: price movement inputs cannot be negative.");
      return(false);
   }
   if(LockedProfit_PriceUSD>0.0 && LockTrigger_PriceUSD<=0.0)
   {
      Print("GoldScalper: LockedProfit_PriceUSD requires a positive LockTrigger_PriceUSD.");
      return(false);
   }
   if(LockTrigger_PriceUSD>0.0 && LockedProfit_PriceUSD>=LockTrigger_PriceUSD)
   {
      Print("GoldScalper: LockedProfit_PriceUSD must be smaller than LockTrigger_PriceUSD.");
      return(false);
   }
   bool trailStart=(TrailingStart_PriceUSD>0.0);
   bool trailDist=(TrailingDistance_PriceUSD>0.0);
   if(trailStart!=trailDist)
   {
      Print("GoldScalper: TrailingStart_PriceUSD and TrailingDistance_PriceUSD must both be zero or both be positive.");
      return(false);
   }
   if(StopLoss_PriceUSD>0.0 && SCRATCH_ADVERSE_USD>=StopLoss_PriceUSD)
      Print("GoldScalper: note - StopLoss_PriceUSD is at or inside the software scratch (",
            DoubleToString(SCRATCH_ADVERSE_USD,2),"); the broker stop will act first.");
   return(true);
}

// Sweep per-ticket GlobalVariables left behind by tickets that no
// longer exist or are already closed (EA removed mid-trade, manual
// closes). Runs once at init; the adopted open ticket survives.
void CleanOrphanedTicketState()
{
   if(IsTesting()) return;
   string prefix=StringFormat("GS1.%d.%d.",AccountNumber(),MAGIC_NUMBER);
   for(int i=GlobalVariablesTotal()-1;i>=0;i--)
   {
      string name=GlobalVariableName(i);
      if(StringFind(name,prefix)!=0) continue;
      string rest=StringSubstr(name,StringLen(prefix));
      int dot=StringFind(rest,".");
      if(dot<0) { GlobalVariableDel(name); continue; }
      int ticket=(int)StringToInteger(StringSubstr(rest,0,dot));
      if(ticket<=0) { GlobalVariableDel(name); continue; }
      if(!OrderSelect(ticket,SELECT_BY_TICKET) || OrderCloseTime()>0)
         GlobalVariableDel(name);
   }
}

//+------------------------------------------------------------------+
//| lifecycle                                                         |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!IsGoldSymbol())
   {
      Print("GoldScalper: attach only to a Gold/XAU symbol. Current: ",Symbol());
      return(INIT_FAILED);
   }
   if(Period()!=PERIOD_M1)
      Print("GoldScalper: designed to run on the M1 chart. Current: ",Period()," min.");
   if(!ParseSchedules())
   {
      Print("GoldScalper: could not parse the frozen session/blackout schedule.");
      return(INIT_FAILED);
   }
   if(!ValidateInputs()) return(INIT_FAILED);

   int ticket=FindManagedTicket();
   if(ticket>=0 && OrderSelect(ticket,SELECT_BY_TICKET))
   {
      AdoptTicket(ticket);
      Print("GoldScalper: adopted open ticket ",ticket," after restart.");
   }
   CleanOrphanedTicketState();
   EventSetTimer(1);
   g_blocker="waiting for M1/M5 history";
   g_lastAction="attached";
   UpdatePanel(true);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int r=0;r<GS_PANEL_ROWS;r++) ObjectDelete(0,GS_OBJ_PREFIX+IntegerToString(r));
}

void OnTick()
{
   ManagePosition();

   datetime bar=iTime(Symbol(),PERIOD_M1,0);
   if(bar>0 && bar!=g_lastM1Bar)
   {
      g_lastM1Bar=bar;
      if(iBars(Symbol(),PERIOD_M1)>ER_PERIOD+60 && iBars(Symbol(),PERIOD_M5)>40)
      {
         UpdateRegime(iTime(Symbol(),PERIOD_M1,1));

         string momBlocker="", fadeBlocker="";
         double fadeTarget=0.0;
         int dir=EvaluateMomentum(momBlocker);
         int module=1;
         if(dir==0)
         {
            int fdir=EvaluateFade(fadeBlocker,fadeTarget);
            if(fdir!=0) { dir=fdir; module=2; }
         }
         g_signalDir=dir;
         g_signalModule=(dir!=0?module:0);
         g_signalRef=iClose(Symbol(),PERIOD_M1,1);
         g_signalFadeTarget=fadeTarget;

         if(dir!=0)
         {
            // opposite qualified signal while holding: the thesis is dead
            int held=FindManagedTicket();
            if(held>=0 && EXIT_ON_OPPOSITE && OrderSelect(held,SELECT_BY_TICKET))
            {
               int heldDir=(OrderType()==OP_BUY ? 1 : -1);
               if(heldDir!=dir) CloseSelectedOrder("OPPOSITE SIGNAL");
            }
            string railBlocker="";
            if(EntryAllowed(dir,railBlocker))
            {
               LedgerWrite("SIGNAL",dir,0.0,g_signalRef,0.0,module==2?"fade":"momentum");
               g_blocker=(SendEntry(dir,module,g_signalRef,fadeTarget) ? "" : g_lastAction);
            }
            else
               g_blocker=railBlocker;
         }
         else if(USE_MOMENTUM && USE_FADE)
            g_blocker="mom: "+momBlocker+" | fade: "+fadeBlocker;
         else if(USE_MOMENTUM)
            g_blocker=momBlocker;
         else if(USE_FADE)
            g_blocker=fadeBlocker;
         else
            g_blocker="all modules off";
      }
   }
   UpdatePanel();
}

void OnTimer()
{
   // quiet-market safety net: retries and panel still run without ticks
   if(g_pendingClose)
   {
      int ticket=FindManagedTicket();
      if(ticket>=0 && OrderSelect(ticket,SELECT_BY_TICKET))
         CloseSelectedOrder(g_pendingCloseReason);
      else
         { g_pendingClose=false; g_pendingCloseReason=""; }
   }
   UpdatePanel(true);
}
//+------------------------------------------------------------------+
