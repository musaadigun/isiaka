//+------------------------------------------------------------------+
//| XVISION_EURUSD_Breakout_EA_v4_claude.mq4                          |
//|                                                                   |
//| ONE JOB: take the London breakout entry. You manage the trade.    |
//|                                                                   |
//| THE ENTRY                                                         |
//|   00:00-07:00 GMT is the thinnest EURUSD book of the day. If that |
//|   range closes TIGHT against the 14-day average daily range, the  |
//|   pair is coiled going into the European open, when the banks     |
//|   that actually trade it arrive. The EA brackets that range and   |
//|   takes the break.                                                |
//|                                                                   |
//|   Proactive: from 07:00 the trigger prices are known and shown on |
//|   the panel. In PENDING mode the orders are already sitting in    |
//|   the market, so you are filled at the level, not after a bar     |
//|   closes past it.                                                 |
//|                                                                   |
//| WHAT IT DOES AFTER ENTRY - only what you switch on                |
//|   Break-even, trailing stop, optional time exit. Nothing else.    |
//|   No adaptive sizing, no shadow trades, no equity breaker, no     |
//|   hidden state. Set them all off and it places the order and      |
//|   leaves you alone.                                               |
//|                                                                   |
//| REMOVED FROM v3 - deliberately                                    |
//|   EWMA self-monitoring, shadow trading, per-engine stand-down,    |
//|   drawdown halt, consecutive-loss breaker, file-backed state and  |
//|   the Asian fade engine. Fewer moving parts, fewer ways to fail.  |
//+------------------------------------------------------------------+
#property strict
#property description "EURUSD London breakout - entry only, you manage the trade"

enum EntryModeEnum
{
   ENTRY_PENDING,        // Pending stop orders at the levels (proactive)
   ENTRY_ON_CLOSE        // Market order after an M15 close beyond the level
};
enum LotModeEnum
{
   LOT_FIXED,            // Fixed lots
   LOT_RISK_PERCENT      // % of balance risked on the stop
};
enum CornerEnum
{
   CORNER_TL,            // Top left
   CORNER_TR,            // Top right
   CORNER_BL,            // Bottom left
   CORNER_BR             // Bottom right
};

//==================== ENTRY =========================================
input EntryModeEnum EntryMode        = ENTRY_PENDING;  // how the break is taken
input int    AsianStartHour          = 0;      // GMT, range window opens
input int    AsianEndHour            = 7;      // GMT, range closes / London opens
input int    EntryEndHour            = 11;     // GMT, no entries after this
input double MaxRangeToAdr           = 0.55;   // range must be tight vs 14d ADR
input double MinRangeToAdr           = 0.12;   // ...but not dead
input double BreakBufferPips         = 1.5;    // trigger this far beyond the edge
input int    MinAsianBars            = 20;     // of 28; guards holidays and gaps
input int    MaxTradesPerDay         = 1;      // hard cap
input int    ServerGmtOffsetHours    = 99;     // 99 = auto-detect

//==================== ORDER =========================================
input LotModeEnum LotMode            = LOT_FIXED;
input double FixedLots               = 0.10;
input double RiskPercent             = 0.75;   // used only in LOT_RISK_PERCENT
input double StopLossPips            = 20.0;   // 0 = use the far side of the range
input double TakeProfitPips          = 30.0;   // 0 = no take profit
input double MaxSpreadPips           = 2.0;
input int    SlippagePoints          = 15;
input int    MagicNumber             = 270904;

//==================== YOUR TRADE MANAGEMENT =========================
input bool   UseBreakEven            = false;
input double BreakEvenAtPips         = 15.0;   // profit needed to move the stop
input double BreakEvenLockPips       = 2.0;    // locked in above entry
input bool   UseTrailingStop         = false;
input double TrailStartPips          = 20.0;   // profit before trailing begins
input double TrailDistancePips       = 15.0;   // stop held this far behind price
input double TrailStepPips           = 5.0;    // minimum move before modifying
input bool   UseTimeExit             = false;  // off: the trade is yours to close
input int    CloseAtHour             = 16;     // GMT, only if UseTimeExit

//==================== PANEL =========================================
input bool   ShowPanel               = true;
input CornerEnum PanelCorner         = CORNER_TL;
input int    PanelX                  = 8;      // px from the chosen corner
input int    PanelY                  = 18;
input int    PanelWidth              = 400;
input int    PanelFontSize           = 8;
input string PanelFont               = "Consolas";
input color  PanelBackColor          = C'18,22,30';
input color  PanelBorderColor        = C'70,82,102';
input color  PanelHeaderColor        = C'30,38,52';
input color  PanelTextColor          = C'223,230,240';
input color  PanelDimColor           = C'126,138,158';
input color  PanelGoodColor          = C'80,205,132';
input color  PanelWarnColor          = C'240,180,70';
input color  PanelBadColor           = C'238,92,92';

//==================== ALERTS / LOG ==================================
input bool   PopupAlert              = true;
input bool   PushAlert               = false;
input bool   WriteEntryLog           = true;

#define TF        PERIOD_M15
#define PFX       "xv4c_"
#define NROWS     11
#define ROW_H     14
#define TITLE_H   22

string LOGFILE = "XVISION_EURUSD_v4_claude_Entries.csv";

int      g_offsetSec = 0;
double   g_pip       = 0.0001;
datetime g_lastBar   = 0;
bool     g_configOk  = false;

// session cache, rebuilt once per GMT day
datetime g_sessDay   = 0;
double   g_hi = 0, g_lo = 0, g_adr = 0;
int      g_bars      = 0;
bool     g_rangeOk   = false;
bool     g_placed    = false;   // pendings placed for today

//+------------------------------------------------------------------+
//|                        TIME HELPERS                              |
//+------------------------------------------------------------------+
datetime ToGmt(datetime s)    { return((datetime)(s - g_offsetSec)); }
datetime ToServer(datetime g) { return((datetime)(g + g_offsetSec)); }
datetime GmtDay(datetime g)   { return((datetime)(g - (g % 86400))); }
datetime GmtNow()             { return(ToGmt(TimeCurrent())); }
int      GmtHour()            { return(TimeHour(GmtNow())); }
double   SpreadPips()         { return((Ask - Bid)/g_pip); }
string   Pad2(int v)          { return(v<10 ? "0"+IntegerToString(v) : IntegerToString(v)); }

void DetectOffset()
{
   if(ServerGmtOffsetHours != 99) { g_offsetSec = ServerGmtOffsetHours*3600; return; }
   if(IsTesting() || IsOptimization())
   {
      g_offsetSec = 0;
      Print("v4: TimeGMT() is unreliable in the tester - assuming server = GMT. ",
            "Set ServerGmtOffsetHours explicitly for a valid test.");
      return;
   }
   g_offsetSec = (int)(MathRound((double)(TimeCurrent()-TimeGMT())/3600.0)*3600);
   Print("v4: server is GMT", (g_offsetSec>=0?"+":""), g_offsetSec/3600,
         ". Sessions are GMT - check this matches your broker.");
}

//+------------------------------------------------------------------+
//| Refuse to run on a session config that cannot behave sanely.      |
//| v3 shipped without this and a stop hour below the entry hour      |
//| silently produced overnight holds.                                |
//+------------------------------------------------------------------+
bool ValidateConfig()
{
   string e = "";
   if(AsianStartHour < 0  || AsianStartHour > 23) e += "AsianStartHour must be 0-23. ";
   if(AsianEndHour   < 0  || AsianEndHour   > 23) e += "AsianEndHour must be 0-23. ";
   if(EntryEndHour   < 0  || EntryEndHour   > 23) e += "EntryEndHour must be 0-23. ";
   if(AsianEndHour  <= AsianStartHour)  e += "AsianEndHour must be after AsianStartHour. ";
   if(EntryEndHour  <= AsianEndHour)    e += "EntryEndHour must be after AsianEndHour. ";
   if(UseTimeExit && (CloseAtHour <= EntryEndHour || CloseAtHour > 23))
      e += "CloseAtHour must be after EntryEndHour and <= 23, or the exit lands tomorrow. ";
   if(MinRangeToAdr >= MaxRangeToAdr)   e += "MinRangeToAdr must be below MaxRangeToAdr. ";
   if(StopLossPips < 0 || TakeProfitPips < 0) e += "Stop/target pips cannot be negative. ";
   if(LotMode==LOT_FIXED && FixedLots <= 0)   e += "FixedLots must be above zero. ";
   if(LotMode==LOT_RISK_PERCENT && RiskPercent <= 0) e += "RiskPercent must be above zero. ";
   if(UseTrailingStop && TrailDistancePips <= 0) e += "TrailDistancePips must be above zero. ";
   if(StopLossPips > 0 && TakeProfitPips > 0 && TakeProfitPips < StopLossPips*0.5)
      Print("v4: NOTE take profit is under half the stop - fine if deliberate.");

   if(e == "") return(true);
   Alert("v4 CONFIG ERROR: ", e);
   Print("v4 CONFIG ERROR: ", e);
   return(false);
}

//+------------------------------------------------------------------+
//|                        LIFECYCLE                                 |
//+------------------------------------------------------------------+
int OnInit()
{
   string sym = Symbol(); StringToUpper(sym);
   if(StringFind(sym,"EURUSD") < 0)
   { Alert("v4: reasoned for EURUSD only, not ", Symbol()); return(INIT_FAILED); }

   g_pip = (Digits==5 || Digits==3) ? Point*10 : Point;
   DetectOffset();

   g_configOk = ValidateConfig();
   if(!g_configOk) return(INIT_FAILED);

   if(iBars(NULL,TF) < 200)
      Print("v4: ONLY ", iBars(NULL,TF), " M15 BARS. The EA works on M15 whatever chart ",
            "it sits on - open a EURUSD M15 chart once so history downloads, then reattach.");

   g_lastBar = iTime(NULL,TF,0);

   if(WriteEntryLog && !FileIsExist(LOGFILE))
   {
      int fh = FileOpen(LOGFILE, FILE_CSV|FILE_WRITE|FILE_SHARE_READ, ',');
      if(fh != INVALID_HANDLE)
      {
         FileWrite(fh,"gmt_time","mode","dir","lots","entry","sl","tp",
                      "range_pips","adr_pips","range_to_adr","spread_pips","ticket");
         FileClose(fh);
      }
   }
   EventSetTimer(5);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); PanelDestroy(); Comment(""); }
void OnTimer() { Cycle(); }
void OnTick()  { Cycle(); }

void Cycle()
{
   if(!g_configOk) return;
   ManageOpen();
   HousekeepPendings();
   WarnIfHedged();

   datetime b = iTime(NULL,TF,0);
   if(b != g_lastBar) { g_lastBar = b; OnBar(); }

   if(ShowPanel) Panel();
}

//| Both stop orders can fill on one spike before the cancel lands. MT4
//| allows the hedge silently; this makes sure you hear about it.
void WarnIfHedged()
{
   static datetime lastWarn = 0;
   int n = 0;
   for(int i=OrdersTotal()-1; i>=0; i--)
      if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES) && OrderMagicNumber()==MagicNumber
         && OrderSymbol()==Symbol() && OrderType()<=OP_SELL) n++;
   if(n > 1 && TimeCurrent()-lastWarn > 300)
   {
      lastWarn = TimeCurrent();
      Say(StringConcatenate("v4: WARNING ",n," positions open at once - both sides of the ",
          "bracket filled. You are hedged; close one."));
   }
}

void OnBar()
{
   if(iBars(NULL,TF) < 200) return;

   datetime day0 = GmtDay(GmtNow());
   if(g_sessDay != day0) { g_sessDay = day0; g_rangeOk = false; g_placed = false; g_bars = 0; }

   BuildRange();          // cheap and cached; keeps the panel honest all day

   int hour = GmtHour();
   if(hour < AsianEndHour || hour >= EntryEndHour) return;
   if(!g_rangeOk)   return;
   if(!Qualifies()) return;
   if(TradesToday() >= MaxTradesPerDay) return;

   if(EntryMode == ENTRY_PENDING) PlacePendings();
   else                           CheckCloseBreak();
}

//+------------------------------------------------------------------+
//|                     RANGE AND FILTER                             |
//+------------------------------------------------------------------+
bool BuildRange()
{
   if(g_rangeOk) return(true);

   datetime day0 = GmtDay(GmtNow());
   datetime aS = day0 + AsianStartHour*3600;
   datetime aE = day0 + AsianEndHour*3600;
   if(GmtNow() < aE) return(false);

   int iE = iBarShift(NULL,TF,ToServer(aE)-1,false);
   int iS = iBarShift(NULL,TF,ToServer(aS),false);
   if(iE < 0 || iS < 0 || iS < iE) return(false);      // history still loading

   g_bars = iS - iE + 1;
   if(g_bars < MinAsianBars) return(false);

   g_hi  = iHigh(NULL,TF,iHighest(NULL,TF,MODE_HIGH,g_bars,iE));
   g_lo  = iLow (NULL,TF,iLowest (NULL,TF,MODE_LOW ,g_bars,iE));
   g_adr = iATR(NULL,PERIOD_D1,14,1);
   if(g_adr <= 0 || g_hi <= g_lo) return(false);

   g_rangeOk = true;
   return(true);
}

double RangePips() { return((g_hi-g_lo)/g_pip); }
double AdrPips()   { return(g_adr/g_pip); }
double Ratio()     { return(AdrPips()>0 ? RangePips()/AdrPips() : 0); }
bool   Qualifies() { return(g_rangeOk && Ratio() <= MaxRangeToAdr && Ratio() >= MinRangeToAdr); }
double BuyTrigger()  { return(NormalizeDouble(g_hi + BreakBufferPips*g_pip, Digits)); }
double SellTrigger() { return(NormalizeDouble(g_lo - BreakBufferPips*g_pip, Digits)); }

//| Counts today's entries from live orders and history, so a restart |
//| cannot hand you a second trade on the same setup.                 |
int TradesToday()
{
   int n = 0; datetime day0 = GmtDay(GmtNow());
   for(int i=OrdersTotal()-1; i>=0; i--)
      if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES) && OrderMagicNumber()==MagicNumber
         && OrderSymbol()==Symbol() && OrderType()<=OP_SELL
         && GmtDay(ToGmt(OrderOpenTime()))==day0) n++;
   for(int j=OrdersHistoryTotal()-1; j>=0; j--)
      if(OrderSelect(j,SELECT_BY_POS,MODE_HISTORY) && OrderMagicNumber()==MagicNumber
         && OrderSymbol()==Symbol() && OrderType()<=OP_SELL
         && GmtDay(ToGmt(OrderOpenTime()))==day0) n++;
   return(n);
}

int CountPendings()
{
   int n = 0;
   for(int i=OrdersTotal()-1; i>=0; i--)
      if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES) && OrderMagicNumber()==MagicNumber
         && OrderSymbol()==Symbol() && OrderType()>OP_SELL) n++;
   return(n);
}

int OpenTicket()
{
   for(int i=OrdersTotal()-1; i>=0; i--)
      if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES) && OrderMagicNumber()==MagicNumber
         && OrderSymbol()==Symbol() && OrderType()<=OP_SELL) return(OrderTicket());
   return(-1);
}

//+------------------------------------------------------------------+
//|                        SIZING                                    |
//+------------------------------------------------------------------+
double Lots(double slDist)
{
   double lots;
   if(LotMode == LOT_FIXED) lots = FixedLots;
   else
   {
      double tv = MarketInfo(Symbol(),MODE_TICKVALUE), ts = MarketInfo(Symbol(),MODE_TICKSIZE);
      if(tv<=0 || ts<=0 || slDist<=0) return(0);
      double perLot = slDist/ts*tv;
      if(perLot <= 0) return(0);
      lots = AccountBalance()*RiskPercent/100.0/perLot;
   }
   double step = MarketInfo(Symbol(),MODE_LOTSTEP);
   double mn   = MarketInfo(Symbol(),MODE_MINLOT);
   double mx   = MarketInfo(Symbol(),MODE_MAXLOT);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots/step)*step;
   if(lots < mn) return(0);
   if(lots > mx) lots = mx;
   int d = (step>=1.0)?0:((step>=0.1)?1:((step>=0.01)?2:3));
   return(NormalizeDouble(lots,d));
}

//| Stop and target for a given direction and entry price.            |
void Levels(int dir, double entry, double &sl, double &tp)
{
   if(StopLossPips > 0) sl = entry - dir*StopLossPips*g_pip;
   else                 sl = (dir>0) ? g_lo : g_hi;     // far side of the range
   tp = (TakeProfitPips > 0) ? entry + dir*TakeProfitPips*g_pip : 0;
   sl = NormalizeDouble(sl,Digits);
   if(tp > 0) tp = NormalizeDouble(tp,Digits);
}

//+------------------------------------------------------------------+
//|                   ENTRY - PENDING STOPS                          |
//+------------------------------------------------------------------+
void PlacePendings()
{
   if(g_placed || CountPendings() > 0 || OpenTicket() >= 0) return;
   if(SpreadPips() > MaxSpreadPips) return;
   if(!IsTradeAllowed()) return;

   double bt = BuyTrigger(), st = SellTrigger();
   double slB,tpB,slS,tpS;
   Levels( 1, bt, slB, tpB);
   Levels(-1, st, slS, tpS);

   double lotB = Lots(MathAbs(bt-slB)), lotS = Lots(MathAbs(st-slS));
   if(lotB <= 0 || lotS <= 0) { Print("v4: lot size resolved to zero"); return; }

   double minDist = MathMax(MarketInfo(Symbol(),MODE_STOPLEVEL),
                            MarketInfo(Symbol(),MODE_FREEZELEVEL))*Point;
   RefreshRates();
   if(bt - Ask < minDist || Bid - st < minDist)
   {
      Print("v4: triggers are inside the broker stop level (",
            DoubleToString(minDist/g_pip,1)," pips) - price is already at the edge.");
      return;
   }

   datetime exp = ToServer(GmtDay(GmtNow()) + EntryEndHour*3600);
   int tB = SendPending(OP_BUYSTOP, lotB, bt, slB, tpB, exp);
   int tS = SendPending(OP_SELLSTOP, lotS, st, slS, tpS, exp);

   if(tB >= 0 || tS >= 0)
   {
      g_placed = true;
      Say(StringConcatenate("v4: bracket set  BUY STOP ",DoubleToString(bt,Digits),
          "   SELL STOP ",DoubleToString(st,Digits),
          "   range ",DoubleToString(RangePips(),1),"p (",DoubleToString(Ratio(),2)," ADR)"));
      if(tB>=0) LogEntry("PENDING", 1,lotB,bt,slB,tpB,tB);
      if(tS>=0) LogEntry("PENDING",-1,lotS,st,slS,tpS,tS);
   }
}

int SendPending(int type, double lots, double price, double sl, double tp, datetime exp)
{
   for(int a=0; a<3; a++)
   {
      RefreshRates();
      int t = OrderSend(Symbol(),type,lots,price,SlippagePoints,sl,tp,
                        "XV4claude",MagicNumber,exp,
                        (type==OP_BUYSTOP)?clrDodgerBlue:clrTomato);
      if(t >= 0) return(t);
      int err = GetLastError();

      // plenty of brokers reject any expiry on pendings; resend without one
      // and let HousekeepPendings() delete them at EntryEndHour instead
      if(err == 147)
      {
         t = OrderSend(Symbol(),type,lots,price,SlippagePoints,sl,tp,
                       "XV4claude",MagicNumber,0,
                       (type==OP_BUYSTOP)?clrDodgerBlue:clrTomato);
         if(t >= 0) return(t);
         err = GetLastError();
      }
      Print("v4: pending ",type," failed, error ",err);
      if(err==146||err==136||err==138||err==135||err==137) { Sleep(300*(a+1)); continue; }
      break;
   }
   return(-1);
}

//| One side filled cancels the other; anything still resting at      |
//| EntryEndHour is cancelled outright.                               |
void HousekeepPendings()
{
   if(CountPendings() == 0) return;
   bool filled  = (OpenTicket() >= 0);
   bool expired = (GmtHour() >= EntryEndHour || GmtHour() < AsianEndHour);
   if(!filled && !expired) return;

   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderMagicNumber()!=MagicNumber || OrderSymbol()!=Symbol()) continue;
      if(OrderType() <= OP_SELL) continue;
      if(!OrderDelete(OrderTicket(), clrGray))
         Print("v4: could not delete pending ",OrderTicket(),", error ",GetLastError());
      else if(filled)
         Print("v4: opposite side cancelled after fill");
   }
}

//+------------------------------------------------------------------+
//|                   ENTRY - CLOSE CONFIRMATION                     |
//+------------------------------------------------------------------+
void CheckCloseBreak()
{
   if(OpenTicket() >= 0) return;
   if(SpreadPips() > MaxSpreadPips) return;

   double c = iClose(NULL,TF,1);
   int dir = 0;
   if(c > BuyTrigger())       dir = 1;
   else if(c < SellTrigger()) dir = -1;
   if(dir == 0) return;

   RefreshRates();
   double entry = (dir>0) ? Ask : Bid;
   double sl,tp; Levels(dir,entry,sl,tp);
   double lots = Lots(MathAbs(entry-sl));
   if(lots <= 0) return;

   double minDist = MathMax(MarketInfo(Symbol(),MODE_STOPLEVEL),
                            MarketInfo(Symbol(),MODE_FREEZELEVEL))*Point;
   if(MathAbs(entry-sl) < minDist || (tp>0 && MathAbs(entry-tp) < minDist))
   { Print("v4: stop or target inside broker minimum distance - skipped"); return; }

   for(int a=0; a<3; a++)
   {
      RefreshRates();
      entry = (dir>0) ? Ask : Bid;
      int t = OrderSend(Symbol(),(dir>0)?OP_BUY:OP_SELL,lots,entry,SlippagePoints,sl,tp,
                        "XV4claude",MagicNumber,0,(dir>0)?clrDodgerBlue:clrTomato);
      if(t >= 0)
      {
         Say(StringConcatenate("v4: ",(dir>0?"BUY ":"SELL "),DoubleToString(lots,2),
             " @ ",DoubleToString(entry,Digits),"  SL ",DoubleToString(sl,Digits),
             "  TP ",(tp>0?DoubleToString(tp,Digits):"none")));
         LogEntry("MARKET",dir,lots,entry,sl,tp,t);
         return;
      }
      int err = GetLastError();
      if(err==130 || err==132 || err==145)      // ECN: open bare, then attach
      {
         RefreshRates();
         t = OrderSend(Symbol(),(dir>0)?OP_BUY:OP_SELL,lots,(dir>0)?Ask:Bid,
                       SlippagePoints,0,0,"XV4claude",MagicNumber,0,clrNONE);
         if(t >= 0)
         {
            if(OrderSelect(t,SELECT_BY_TICKET) && !OrderModify(t,OrderOpenPrice(),sl,tp,0,clrNONE))
               Print("v4: WARNING ticket ",t," opened WITHOUT stops, error ",GetLastError());
            LogEntry("MARKET",dir,lots,OrderOpenPrice(),sl,tp,t);
            return;
         }
         err = GetLastError();
      }
      Print("v4: entry failed, error ",err);
      if(err==146||err==136||err==138) { Sleep(300*(a+1)); continue; }
      break;
   }
}

//+------------------------------------------------------------------+
//|          YOUR TRADE MANAGEMENT - only what you enabled           |
//+------------------------------------------------------------------+
//| Absolute exit instant, derived from when the trade opened. Comparing
//| hours instead would miss the exit entirely if the EA were offline
//| across it, because the hour wraps to a smaller number after midnight.
datetime ExitDeadline(datetime openedSrv)
{
   datetime g  = ToGmt(openedSrv);
   datetime dl = GmtDay(g) + CloseAtHour*3600;
   if(dl <= g) dl += 86400;
   return(ToServer(dl));
}

void ManageOpen()
{
   int t = OpenTicket();
   if(t < 0 || !OrderSelect(t,SELECT_BY_TICKET)) return;

   int    dir   = (OrderType()==OP_BUY) ? 1 : -1;
   double entry = OrderOpenPrice();
   double sl    = OrderStopLoss();
   double tp    = OrderTakeProfit();
   RefreshRates();
   double px    = (dir>0) ? Bid : Ask;
   double prof  = (px-entry)*dir/g_pip;
   double minD  = MathMax(MarketInfo(Symbol(),MODE_STOPLEVEL),
                          MarketInfo(Symbol(),MODE_FREEZELEVEL))*Point;
   double want  = sl;

   if(UseBreakEven && prof >= BreakEvenAtPips)
   {
      double be = NormalizeDouble(entry + dir*BreakEvenLockPips*g_pip, Digits);
      if((dir>0 && be > want) || (dir<0 && (be < want || want==0))) want = be;
   }

   if(UseTrailingStop && prof >= TrailStartPips)
   {
      double tr = NormalizeDouble(px - dir*TrailDistancePips*g_pip, Digits);
      if((dir>0 && tr > want + TrailStepPips*g_pip - 1e-10) ||
         (dir<0 && (tr < want - TrailStepPips*g_pip + 1e-10 || want==0))) want = tr;
   }

   // never widen a stop, never place one the broker will reject
   if(want != sl && want != 0)
   {
      if((dir>0 && want < px - minD) || (dir<0 && want > px + minD))
      {
         if(!OrderModify(t,entry,want,tp,0,clrNONE))
            Print("v4: stop update rejected, error ",GetLastError());
      }
   }

   if(UseTimeExit && TimeCurrent() >= ExitDeadline(OrderOpenTime()))
   {
      RefreshRates();
      if(!OrderClose(t,OrderLots(),(dir>0)?Bid:Ask,SlippagePoints,clrGray))
         Print("v4: time exit failed, error ",GetLastError());
      else Say("v4: closed on time exit at "+Pad2(CloseAtHour)+":00 GMT");
   }
}

//+------------------------------------------------------------------+
//|                      ALERT AND LOG                               |
//+------------------------------------------------------------------+
void Say(string m)
{
   Print(m);
   if(IsTesting() || IsOptimization()) return;
   if(PopupAlert) Alert(m);
   if(PushAlert)  SendNotification(StringSubstr(m,0,250));
}

void LogEntry(string mode,int dir,double lots,double px,double sl,double tp,int ticket)
{
   if(!WriteEntryLog) return;
   int fh = FileOpen(LOGFILE, FILE_CSV|FILE_READ|FILE_WRITE|FILE_SHARE_READ, ',');
   if(fh == INVALID_HANDLE) { Print("v4: entry log not writable"); return; }
   FileSeek(fh,0,SEEK_END);
   FileWrite(fh, TimeToString(GmtNow(),TIME_DATE|TIME_SECONDS), mode, (dir>0?"BUY":"SELL"),
             DoubleToString(lots,2), DoubleToString(px,Digits),
             DoubleToString(sl,Digits), (tp>0?DoubleToString(tp,Digits):"none"),
             DoubleToString(RangePips(),1), DoubleToString(AdrPips(),1),
             DoubleToString(Ratio(),3), DoubleToString(SpreadPips(),2),
             IntegerToString(ticket));
   FileClose(fh);
}

//+------------------------------------------------------------------+
//|                          PANEL                                   |
//| Positioned and coloured from the inputs. Objects always anchor    |
//| top-left and the origin is computed from the chosen corner, so    |
//| text stays left-aligned in every corner.                          |
//+------------------------------------------------------------------+
int PanelH() { return(TITLE_H + NROWS*ROW_H + 12); }

int OriginX()
{
   int w = (int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
   if(PanelCorner==CORNER_TR || PanelCorner==CORNER_BR) return(MathMax(0, w - PanelWidth - PanelX));
   return(PanelX);
}
int OriginY()
{
   int h = (int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS);
   if(PanelCorner==CORNER_BL || PanelCorner==CORNER_BR) return(MathMax(0, h - PanelH() - PanelY));
   return(PanelY);
}

void PBox(string id,int x,int y,int w,int h,color bg,color brd)
{
   string nm=PFX+id;
   if(ObjectFind(0,nm)<0)
   {
      ObjectCreate(0,nm,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,nm,OBJPROP_BACK,false);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,nm,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   }
   ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,nm,OBJPROP_XSIZE,w);     ObjectSetInteger(0,nm,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,nm,OBJPROP_BGCOLOR,bg);  ObjectSetInteger(0,nm,OBJPROP_COLOR,brd);
}

void PTxt(string id,int x,int y,string s,color c,int size)
{
   string nm=PFX+id;
   if(ObjectFind(0,nm)<0)
   {
      ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,nm,OBJPROP_BACK,false);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   }
   ObjectSetString (0,nm,OBJPROP_FONT,PanelFont);
   ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,size);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,c);     ObjectSetString(0,nm,OBJPROP_TEXT,s);
}

string Pad(string s,int n) { while(StringLen(s)<n) s=s+" "; return(s); }

void PRow(int row,string k,string v,color c)
{
   PTxt("r"+IntegerToString(row), OriginX()+10,
        OriginY()+TITLE_H+5+row*ROW_H, Pad(k,10)+v, c, PanelFontSize);
}

void PanelDestroy()
{
   for(int i=ObjectsTotal(0,-1,-1)-1;i>=0;i--)
   {
      string nm=ObjectName(0,i);
      if(StringFind(nm,PFX)==0) ObjectDelete(0,nm);
   }
   ChartRedraw();
}

string Action(color &c)
{
   int hour = GmtHour();
   if(iBars(NULL,TF) < 200)
   { c=PanelBadColor; return("NO M15 DATA - open a EURUSD M15 chart, then reattach"); }
   if(OpenTicket() >= 0)
   { c=PanelGoodColor; return("IN TRADE - yours to manage"); }
   if(CountPendings() > 0)
   { c=PanelGoodColor; return("ORDERS LIVE - bracket waiting for the break"); }
   if(hour < AsianEndHour)
   { c=PanelDimColor; return("RANGE FORMING - closes "+Pad2(AsianEndHour)+":00 GMT"); }
   if(hour >= EntryEndHour)
   { c=PanelDimColor; return("DONE FOR TODAY - window closed at "+Pad2(EntryEndHour)+":00 GMT"); }
   if(!g_rangeOk)
   { c=PanelWarnColor; return("NO RANGE - only "+IntegerToString(g_bars)+" of 28 Asian bars"); }
   if(!Qualifies())
   { c=PanelDimColor; return("STOOD ASIDE - range "+DoubleToString(Ratio(),2)+" ADR, outside filter"); }
   if(TradesToday() >= MaxTradesPerDay)
   { c=PanelDimColor; return("DONE - daily limit of "+IntegerToString(MaxTradesPerDay)+" reached"); }
   if(SpreadPips() > MaxSpreadPips)
   { c=PanelBadColor; return("BLOCKED - spread "+DoubleToString(SpreadPips(),2)+" over cap"); }
   c=PanelGoodColor; return("ARMED - placing the bracket");
}

void Panel()
{
   PBox("bg", OriginX(),OriginY(),PanelWidth,PanelH(),PanelBackColor,PanelBorderColor);
   PBox("hd", OriginX(),OriginY(),PanelWidth,TITLE_H,PanelHeaderColor,PanelBorderColor);
   PTxt("t1", OriginX()+10,OriginY()+5,"XVISION EURUSD BREAKOUT v4",
        PanelTextColor,PanelFontSize+1);
   PTxt("t2", OriginX()+PanelWidth-70,OriginY()+5,
        (EntryMode==ENTRY_PENDING)?"PENDING":"ON CLOSE",PanelDimColor,PanelFontSize+1);

   color ac; string a = Action(ac);
   int r=0;
   PRow(r++,"ACTION",a,ac);
   PRow(r++,"","",PanelDimColor);

   int t = OpenTicket();
   if(t >= 0 && OrderSelect(t,SELECT_BY_TICKET))
   {
      int dir = (OrderType()==OP_BUY)?1:-1;
      double px = (dir>0)?Bid:Ask;
      double pips = (px-OrderOpenPrice())*dir/g_pip;
      double mny = OrderProfit()+OrderCommission()+OrderSwap();
      PRow(r++,"POSITION",StringConcatenate((dir>0?"BUY  ":"SELL "),
           DoubleToString(OrderLots(),2)," @ ",DoubleToString(OrderOpenPrice(),Digits)),
           PanelTextColor);
      PRow(r++,"P/L",StringConcatenate((pips>=0?"+":""),DoubleToString(pips,1)," pips   ",
           (mny>=0?"+":""),DoubleToString(mny,2)), mny>=0?PanelGoodColor:PanelBadColor);
      PRow(r++,"STOPS",StringConcatenate("SL ",DoubleToString(OrderStopLoss(),Digits),
           "   TP ",(OrderTakeProfit()>0?DoubleToString(OrderTakeProfit(),Digits):"none")),
           PanelDimColor);
   }
   else
   {
      PRow(r++,"POSITION","none",PanelDimColor);
      PRow(r++,"","",PanelDimColor);
      PRow(r++,"","",PanelDimColor);
   }
   PRow(r++,"","",PanelDimColor);

   if(g_rangeOk)
   {
      PRow(r++,"RANGE",StringConcatenate(DoubleToString(RangePips(),1),"p   ",
           DoubleToString(Ratio(),2)," ADR   ",Qualifies()?"tradeable":"outside filter"),
           Qualifies()?PanelGoodColor:PanelDimColor);
      PRow(r++,"TRIGGER",StringConcatenate("BUY ",DoubleToString(BuyTrigger(),Digits),
           "   SELL ",DoubleToString(SellTrigger(),Digits)),PanelTextColor);
   }
   else
   {
      PRow(r++,"RANGE",GmtHour()<AsianEndHour?"forming":"not available today",PanelDimColor);
      PRow(r++,"","",PanelDimColor);
   }

   string mg = "";
   if(UseBreakEven)     mg += "BE@"+DoubleToString(BreakEvenAtPips,0)+"p  ";
   if(UseTrailingStop)  mg += "trail "+DoubleToString(TrailDistancePips,0)+"p  ";
   if(UseTimeExit)      mg += "exit "+Pad2(CloseAtHour)+":00  ";
   if(mg == "")         mg  = "manual - nothing automated";
   PRow(r++,"MANAGE",mg,(mg=="manual - nothing automated")?PanelDimColor:PanelWarnColor);

   PRow(r++,"ORDER",StringConcatenate(
        LotMode==LOT_FIXED?StringConcatenate(DoubleToString(FixedLots,2)," lots")
                          :StringConcatenate(DoubleToString(RiskPercent,2),"% risk"),
        "   SL ",(StopLossPips>0?DoubleToString(StopLossPips,0)+"p":"range"),
        "   TP ",(TakeProfitPips>0?DoubleToString(TakeProfitPips,0)+"p":"none")),PanelTextColor);

   PRow(r++,"",StringConcatenate(Pad2(GmtHour()),":00 GMT (",(g_offsetSec>=0?"+":""),
        IntegerToString(g_offsetSec/3600),"h)   spread ",DoubleToString(SpreadPips(),2),
        "   today ",IntegerToString(TradesToday()),"/",IntegerToString(MaxTradesPerDay)),
        PanelDimColor);

   ChartRedraw();
}
//+------------------------------------------------------------------+
