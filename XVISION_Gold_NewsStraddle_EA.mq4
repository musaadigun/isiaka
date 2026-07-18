#property strict
#property version   "8.00"
#property description "XVISION Gold News Straddle V8 - panel-driven straddle with CLOSE/CANCEL, mode selector, diagnostics"

// ============================================================================
// XVISION GOLD NEWS-STRADDLE EA VERSION 8
//
// V8 FIXES
// - Panel LOT override is now actually used when sending orders (V7 sent
//   the LotSize input regardless of the panel value).
// - CANCEL SETUP now sets a dedicated CANCELLED state that the stale-state
//   cleaner respects, so a pre-window cancel no longer silently re-arms.
// - Buy/Sell TP and SL inputs are honoured per side (V7 averaged them).
// - NewsDateTimeGMT parsing is genuinely strict: malformed input is
//   rejected instead of resolving to an unintended datetime.
// - Arming is blocked with a visible reason when autotrading is disabled.
//
// TIME STANDARD
// NewsDateTimeGMT is entered strictly in GMT/UTC as YYYY.MM.DD HH:MI.
// All scheduling decisions use TimeGMT(). Broker time is display-only.
//
// PRICE STANDARD
// Pending distances, TP and SL are raw Gold price movements, not MT4 points.
// Example: 8.0 means an $8 movement in the Gold quotation.
// ============================================================================

// --------------------------- Event schedule ---------------------------------
input string EventName                         = "US CPI";
input string NewsDateTimeGMT                   = "2099.01.01 00:00";
input int    PlaceMinutesBeforeNews            = 5;
input int    PlaceAdditionalSecondsBeforeNews  = 0;
input int    CancelMinutesAfterNews            = 10;
input int    CancelAdditionalSecondsAfterNews  = 0;

enum TradeExitMode
{
   EXIT_FIXED_TP              = 0,
   EXIT_TRAILING_ONLY         = 1,
   EXIT_FIXED_TP_AND_TRAILING = 2
};

// --------------------------- Order controls ---------------------------------
input double LotSize                           = 0.01;
input bool   EnableBuyStop                     = true;
input bool   EnableSellStop                    = true;
input bool   RequireBothPendingOrders          = true;

input double BuyStopDistanceMovement           = 8.0;
input double SellStopDistanceMovement          = 8.0;

input TradeExitMode ExitMode                   = EXIT_TRAILING_ONLY;

input double BuyTakeProfitMovement             = 40.0;
input double BuyStopLossMovement               = 20.0;
input double SellTakeProfitMovement            = 40.0;
input double SellStopLossMovement              = 20.0;

// Trailing values are raw Gold-price movements.
input double TrailingActivationMovement        = 20.0;
input double TrailingStopDistanceMovement      = 10.0;
input double TrailingStepMovement              = 2.0;

// Optional break-even stage before the trailing stop becomes active.
input bool   MoveToBreakEvenFirst               = true;
input double BreakEvenActivationMovement       = 12.0;
input double BreakEvenLockMovement             = 1.0;

input double MaximumSpreadMovement             = 2.0;   // 0 disables filter
input int    SlippagePoints                    = 50;
input int    MagicNumber                       = 26071451;

// --------------------------- Safety controls --------------------------------
input bool   EnforceGoldSymbol                 = true;
input bool   CancelOppositePendingOnTrigger    = true;
input bool   CloseSecondTriggeredTrade         = true;
input bool   ReanchorTPAndSLToActualFill        = true;
input bool   DeletePendingOrdersAtExpiry       = true;
input bool   AllowPlacementAfterScheduledTime  = false;
input int    MaximumLatePlacementSeconds       = 0;

// --------------------------- Notifications ----------------------------------
input bool   ForceResetEventState              = false; // wipe stored state for this event at init
input bool   EnablePopupAlerts                 = true;
input bool   EnablePushNotifications           = false;

// --------------------------- Panel controls ---------------------------------
input bool   ShowGMTPanel                      = true;
input int    PanelRightMargin                  = 10;
input int    PanelTopMargin                    = 8;
input int    PanelWidth                        = 600;
input int    PanelHeight                       = 151;
input int    PanelFontSize                     = 9;
input color  PanelBackground                   = clrBlack;
input color  PanelBorder                       = clrDimGray;
input color  GMTHeaderBackground               = clrMidnightBlue;
input color  GMTHeaderText                     = clrYellow;
input color  PanelText                         = clrWhite;
input color  BuyColor                          = clrAqua;
input color  SellColor                         = clrMagenta;
input color  WarningColor                      = clrOrange;

#define STATE_WAITING   0
#define STATE_PENDING   1
#define STATE_ACTIVE    2
#define STATE_COMPLETE  3
#define STATE_EXPIRED   4
#define STATE_ERROR     5
#define STATE_CANCELLED 6

string   PREFIX="XV_GOLD_NS_EA_V8_";
datetime g_newsGMT=0;
datetime g_placeGMT=0;
datetime g_expiryGMT=0;
string   g_eventToken="";
string   g_globalStateName="";
int      g_state=STATE_WAITING;
bool     g_engineBusy=false;
int      g_lastTriggerAlertTicket=-1;
string   g_lastAction="INITIALISING";
double   g_workLot=0.0;
double   g_workBuyDist=0.0, g_workSellDist=0.0;
double   g_workBuyTP=0.0, g_workSellTP=0.0;
double   g_workBuySL=0.0, g_workSellSL=0.0;
double   g_workTrail=0.0;
double   g_workBE=0.0;          // break-even activation (0 = BE disabled)
int      g_workMode=1;          // 0 FIXED_TP, 1 TRAILING_ONLY, 2 TP+TRAILING
string   g_blockReason="";
string   g_notifiedReason="";
bool     g_missedNotified=false;
bool     g_heartbeatSent=false;

int OnInit()
{
   g_workLot=LotSize;
   g_workBuyDist=BuyStopDistanceMovement;
   g_workSellDist=SellStopDistanceMovement;
   g_workBuyTP=BuyTakeProfitMovement;
   g_workSellTP=SellTakeProfitMovement;
   g_workBuySL=BuyStopLossMovement;
   g_workSellSL=SellStopLossMovement;
   g_workTrail=TrailingStopDistanceMovement;
   g_workBE=(MoveToBreakEvenFirst?BreakEvenActivationMovement:0.0);
   g_workMode=(int)ExitMode;

   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

   g_newsGMT=ParseStrictGMT(NewsDateTimeGMT);
   if(g_newsGMT<=0)
   {
      Print("XVISION News-Straddle: invalid NewsDateTimeGMT. Use YYYY.MM.DD HH:MI.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   ApplySchedule(g_newsGMT);
   RestoreOverrides();

   if(ForceResetEventState && GlobalVariableCheck(g_globalStateName))
   {
      GlobalVariableDel(g_globalStateName);
      Print("XVISION News Straddle V8: stored event state force-cleared.");
   }

   SynchroniseState();
   EventSetTimer(1);
   RunEngine();
   UpdatePanel();
   UpsertControls();
   SetControlTexts();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteObjectsByPrefix();
   ChartRedraw();
}

void OnTick()
{
   RunEngine();
   UpdatePanel();
   UpsertControls();
   UpdateActionButtons();
}

void OnTimer()
{
   RunEngine();
   UpdatePanel();
   UpsertControls();
   UpdateActionButtons();
}

bool ValidateInputs()
{
   if(LotSize<=0.0)
   {
      Print("LotSize must be greater than zero.");
      return(false);
   }

   if(!EnableBuyStop && !EnableSellStop)
   {
      Print("At least one pending-order side must be enabled.");
      return(false);
   }

   if(RequireBothPendingOrders && (!EnableBuyStop || !EnableSellStop))
   {
      Print("RequireBothPendingOrders requires both sides to be enabled.");
      return(false);
   }

   bool fixedTPRequired=(ExitMode==EXIT_FIXED_TP ||
                         ExitMode==EXIT_FIXED_TP_AND_TRAILING);
   bool trailingRequired=(ExitMode==EXIT_TRAILING_ONLY ||
                          ExitMode==EXIT_FIXED_TP_AND_TRAILING);

   if(EnableBuyStop &&
      (g_workBuyDist<=0.0 || g_workBuySL<=0.0 ||
       (fixedTPRequired && g_workBuyTP<=0.0)))
   {
      Print("BUY distance and SL must be greater than zero. BUY TP must also be positive when fixed TP is enabled.");
      return(false);
   }

   if(EnableSellStop &&
      (g_workSellDist<=0.0 || g_workSellSL<=0.0 ||
       (fixedTPRequired && g_workSellTP<=0.0)))
   {
      Print("SELL distance and SL must be greater than zero. SELL TP must also be positive when fixed TP is enabled.");
      return(false);
   }

   if(trailingRequired &&
      (TrailingActivationMovement<=0.0 ||
       g_workTrail<=0.0 ||
       TrailingStepMovement<=0.0))
   {
      Print("Trailing activation, distance and step must all be greater than zero.");
      return(false);
   }

   if(MoveToBreakEvenFirst &&
      (BreakEvenActivationMovement<=0.0 || BreakEvenLockMovement<0.0))
   {
      Print("Break-even activation must be positive and lock movement cannot be negative.");
      return(false);
   }

   if(PlaceMinutesBeforeNews<0 || PlaceAdditionalSecondsBeforeNews<0 ||
      CancelMinutesAfterNews<0 || CancelAdditionalSecondsAfterNews<0 ||
      MaximumLatePlacementSeconds<0)
   {
      Print("Schedule offsets cannot be negative.");
      return(false);
   }

   return(true);
}

// Accepts only a complete "YYYY.MM.DD HH:MI" ('-' and 'T' separators are
// tolerated). StringToTime() alone is lenient - an empty or mangled string
// resolves to a plausible datetime for today - so the parsed value is
// round-tripped through TimeToString() and must reproduce the input.
datetime ParseStrictGMT(string value)
{
   string cleaned=value;
   StringTrimLeft(cleaned);
   StringTrimRight(cleaned);
   StringReplace(cleaned,"-",".");
   StringReplace(cleaned,"T"," ");

   datetime parsed=StringToTime(cleaned);
   if(parsed<=0)
      return(0);

   if(TimeToString(parsed,TIME_DATE|TIME_MINUTES)!=cleaned)
      return(0);

   return(parsed);
}

void RunEngine()
{
   if(g_engineBusy)
      return;

   g_engineBusy=true;

   if(EnforceGoldSymbol && !IsGoldSymbol())
   {
      g_lastAction="ATTACH TO GOLD/XAU";
      g_engineBusy=false;
      return;
   }

   SynchroniseState();
   ManageTriggeredTrades();
   ManageActiveTradeExits();

   datetime nowGMT=TimeGMT();

   if(DeletePendingOrdersAtExpiry && nowGMT>=g_expiryGMT)
      ExpirePendingOrders();

   SynchroniseState();

   // V3: heartbeat 60s before arming so a dead terminal is discovered in time
   if(!g_heartbeatSent && g_state==STATE_WAITING &&
      nowGMT>=g_placeGMT-60 && nowGMT<g_placeGMT)
   {
      g_heartbeatSent=true;
      Notify("XVISION News Straddle V8 alive | arming in <=60s | "+EventName+
             " | spread "+DoubleToString(Ask-Bid,Digits));
   }

   if(CanPlaceNow(nowGMT))
   {
      if(!PlaceNewsStraddle())
         g_blockReason=g_lastAction;      // surface placement failures too
   }

   // V3: one-shot alert per distinct blocking reason while the window is live
   if(g_blockReason!="" && g_blockReason!=g_notifiedReason &&
      nowGMT>=g_placeGMT && nowGMT<g_expiryGMT && g_state==STATE_WAITING)
   {
      g_notifiedReason=g_blockReason;
      Notify("XVISION News Straddle V8 ARM BLOCKED | "+EventName+" | "+g_blockReason);
   }

   // V3: loud alarm if the news moment arrives with nothing armed
   if(!g_missedNotified && g_state==STATE_WAITING && nowGMT>=g_newsGMT)
   {
      g_missedNotified=true;
      Notify("XVISION News Straddle V8 WINDOW MISSED | "+EventName+
             " | last block: "+(g_blockReason==""?"none recorded":g_blockReason));
   }

   SynchroniseState();
   g_engineBusy=false;
}

bool CanPlaceNow(datetime nowGMT)
{
   g_blockReason="";

   if(EventHasAnyOpenOrder())
   { g_blockReason="event orders already exist"; return(false); }

   if(g_state==STATE_PENDING || g_state==STATE_ACTIVE ||
      g_state==STATE_COMPLETE || g_state==STATE_EXPIRED ||
      g_state==STATE_CANCELLED)
   { g_blockReason="state="+StateText()+" vetoes arming"; return(false); }

   if(GlobalVariableCheck(g_globalStateName) &&
      GlobalVariableGet(g_globalStateName)>=STATE_PENDING)
   { g_blockReason="stored terminal state vetoes arming"; return(false); }

   if(!IsTradeAllowed())
   { g_blockReason="autotrading disabled in terminal"; return(false); }

   if(nowGMT<g_placeGMT)
   { g_blockReason="before placement time"; return(false); }

   if(nowGMT<g_newsGMT)
      return(true);

   if(!AllowPlacementAfterScheduledTime)
   { g_blockReason="window passed; late placement disabled"; return(false); }

   if(nowGMT<=g_newsGMT+MaximumLatePlacementSeconds)
      return(true);

   g_blockReason="beyond maximum late-placement seconds";
   return(false);
}

bool PlaceNewsStraddle()
{
   RefreshRates();

   double spread=Ask-Bid;
   if(MaximumSpreadMovement>0.0 && spread>MaximumSpreadMovement)
   {
      g_lastAction="SPREAD TOO HIGH: "+DoubleToString(spread,Digits);
      return(false);
   }

   double lots=NormalizeLots(g_workLot);
   if(lots<=0.0)
   {
      g_lastAction="INVALID LOT SIZE";
      return(false);
   }

   int buyTicket=-1;
   int sellTicket=-1;

   if(EnableBuyStop)
   {
      double buyPrice=NormalizeDouble(Ask+g_workBuyDist,Digits);
      double buySL=NormalizeDouble(buyPrice-g_workBuySL,Digits);
      double buyTP=InitialTakeProfit(OP_BUY,buyPrice);

      if(!PendingGeometryIsValid(OP_BUYSTOP,buyPrice,buySL,buyTP))
      {
         g_lastAction="BUY LEVELS VIOLATE BROKER MINIMUM";
         return(false);
      }

      buyTicket=SendPendingOrder(OP_BUYSTOP,lots,buyPrice,buySL,buyTP,g_eventToken+"_B",BuyColor);
      if(buyTicket<0 && RequireBothPendingOrders)
      {
         g_lastAction="BUY STOP PLACEMENT FAILED";
         return(false);
      }
   }

   if(EnableSellStop)
   {
      RefreshRates();

      double sellPrice=NormalizeDouble(Bid-g_workSellDist,Digits);
      double sellSL=NormalizeDouble(sellPrice+g_workSellSL,Digits);
      double sellTP=InitialTakeProfit(OP_SELL,sellPrice);

      if(!PendingGeometryIsValid(OP_SELLSTOP,sellPrice,sellSL,sellTP))
      {
         if(buyTicket>=0 && RequireBothPendingOrders)
            DeleteOrderByTicket(buyTicket);

         g_lastAction="SELL LEVELS VIOLATE BROKER MINIMUM";
         return(false);
      }

      sellTicket=SendPendingOrder(OP_SELLSTOP,lots,sellPrice,sellSL,sellTP,g_eventToken+"_S",SellColor);

      if(sellTicket<0 && RequireBothPendingOrders)
      {
         if(buyTicket>=0)
            DeleteOrderByTicket(buyTicket);

         g_lastAction="SELL STOP PLACEMENT FAILED";
         return(false);
      }
   }

   bool buyOK=(!EnableBuyStop || buyTicket>=0);
   bool sellOK=(!EnableSellStop || sellTicket>=0);

   if(!buyOK && !sellOK)
   {
      g_lastAction="NO PENDING ORDER PLACED";
      return(false);
   }

   if(RequireBothPendingOrders && (!buyOK || !sellOK))
   {
      if(buyTicket>=0) DeleteOrderByTicket(buyTicket);
      if(sellTicket>=0) DeleteOrderByTicket(sellTicket);
      g_lastAction="BOTH ORDERS REQUIRED";
      return(false);
   }

   SetState(STATE_PENDING);
   g_lastAction="STRADDLE ARMED";

   Notify("XVISION News Straddle V8 armed | "+EventName+
          " | News GMT "+TimeToString(g_newsGMT,TIME_DATE|TIME_MINUTES)+
          " | Buy ticket "+IntegerToString(buyTicket)+
          " | Sell ticket "+IntegerToString(sellTicket));

   return(true);
}

int SendPendingOrder(int orderType,
                     double lots,
                     double entryPrice,
                     double stopLoss,
                     double takeProfit,
                     string orderComment,
                     color arrowColor)
{
   ResetLastError();

   int ticket=OrderSend(Symbol(),orderType,lots,entryPrice,
                        SlippagePoints,stopLoss,takeProfit,orderComment,
                        MagicNumber,0,arrowColor);

   if(ticket>=0)
      return(ticket);

   int firstError=GetLastError();
   ResetLastError();

   // ECN fallback: place without protection, then attach TP/SL immediately.
   if(firstError==130)
   {
      ticket=OrderSend(Symbol(),orderType,lots,entryPrice,
                       SlippagePoints,0,0,orderComment,MagicNumber,0,arrowColor);

      if(ticket<0)
      {
         Print("Pending fallback failed. Error ",GetLastError());
         ResetLastError();
         return(-1);
      }

      if(!OrderSelect(ticket,SELECT_BY_TICKET))
      {
         DeleteOrderByTicket(ticket);
         return(-1);
      }

      if(!OrderModify(ticket,OrderOpenPrice(),stopLoss,takeProfit,0,clrNONE))
      {
         Print("Cannot attach TP/SL to pending order. Error ",GetLastError());
         ResetLastError();
         DeleteOrderByTicket(ticket);
         return(-1);
      }

      return(ticket);
   }

   Print("OrderSend failed. Type ",orderType," Error ",firstError);
   return(-1);
}

bool PendingGeometryIsValid(int orderType,double entryPrice,double stopLoss,double takeProfit)
{
   double stopDistance=MarketInfo(Symbol(),MODE_STOPLEVEL)*Point;
   if(stopDistance<0.0) stopDistance=0.0;

   RefreshRates();

   if(orderType==OP_BUYSTOP)
   {
      if(entryPrice-Ask<stopDistance) return(false);
      if(entryPrice-stopLoss<stopDistance) return(false);
      if(takeProfit>0.0 && takeProfit-entryPrice<stopDistance) return(false);
   }
   else if(orderType==OP_SELLSTOP)
   {
      if(Bid-entryPrice<stopDistance) return(false);
      if(stopLoss-entryPrice<stopDistance) return(false);
      if(takeProfit>0.0 && entryPrice-takeProfit<stopDistance) return(false);
   }

   return(true);
}

void ManageTriggeredTrades()
{
   int activeCount=CountActiveEventTrades();
   if(activeCount<=0)
      return;

   int survivorTicket=FindEarliestActiveTicket();
   SetState(STATE_ACTIVE);

   if(CloseSecondTriggeredTrade && activeCount>1 && survivorTicket>0)
      CloseAllActiveExcept(survivorTicket);

   if(!OrderSelect(survivorTicket,SELECT_BY_TICKET))
      return;

   int survivorType=OrderType();

   if(CancelOppositePendingOnTrigger)
      CancelPendingOppositeTo(survivorType);

   if(ReanchorTPAndSLToActualFill)
      EnsureInitialProtection(survivorTicket);

   if(g_lastTriggerAlertTicket!=survivorTicket)
   {
      g_lastTriggerAlertTicket=survivorTicket;
      string side=(survivorType==OP_BUY)?"BUY":"SELL";
      g_lastAction=side+" TRIGGERED";

      Notify("XVISION News Straddle V8 "+side+" triggered | Ticket "+
             IntegerToString(survivorTicket)+" | Fill "+
             DoubleToString(OrderOpenPrice(),Digits));
   }
}

int FindEarliestActiveTicket()
{
   int bestTicket=-1;
   datetime bestTime=0;

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(!IsEventOrderSelected()) continue;
      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) continue;

      if(bestTicket<0 || OrderOpenTime()<bestTime ||
         (OrderOpenTime()==bestTime && OrderTicket()<bestTicket))
      {
         bestTicket=OrderTicket();
         bestTime=OrderOpenTime();
      }
   }

   return(bestTicket);
}

int CountActiveEventTrades()
{
   int count=0;

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(!IsEventOrderSelected()) continue;
      if(OrderType()==OP_BUY || OrderType()==OP_SELL) count++;
   }

   return(count);
}

void CloseAllActiveExcept(int survivorTicket)
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(!IsEventOrderSelected()) continue;
      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) continue;
      if(OrderTicket()==survivorTicket) continue;

      int ticket=OrderTicket();
      double lots=OrderLots();
      int type=OrderType();

      RefreshRates();
      double closePrice=(type==OP_BUY)?Bid:Ask;
      closePrice=NormalizeDouble(closePrice,Digits);

      if(OrderClose(ticket,lots,closePrice,SlippagePoints,WarningColor))
      {
         g_lastAction="SECOND TRIGGER CLOSED";
         Print("Closed second triggered trade ",ticket);
      }
      else
      {
         Print("Failed to close second triggered trade ",ticket,
               ". Error ",GetLastError());
         ResetLastError();
      }
   }
}

void CancelPendingOppositeTo(int activeType)
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(!IsEventOrderSelected()) continue;

      bool deleteIt=false;
      if(activeType==OP_BUY && OrderType()==OP_SELLSTOP) deleteIt=true;
      if(activeType==OP_SELL && OrderType()==OP_BUYSTOP) deleteIt=true;

      if(deleteIt)
      {
         int ticket=OrderTicket();
         if(!OrderDelete(ticket,WarningColor))
         {
            Print("Failed to cancel opposite pending order ",ticket,
                  ". Error ",GetLastError());
            ResetLastError();
         }
      }
   }
}

double InitialTakeProfit(int marketType,double entryPrice)
{
   if(g_workMode==EXIT_TRAILING_ONLY)
      return(0.0);

   if(marketType==OP_BUY)
      return(NormalizeDouble(entryPrice+g_workBuyTP,Digits));

   return(NormalizeDouble(entryPrice-g_workSellTP,Digits));
}

double InitialStopLoss(int marketType,double entryPrice)
{
   if(marketType==OP_BUY)
      return(NormalizeDouble(entryPrice-g_workBuySL,Digits));

   return(NormalizeDouble(entryPrice+g_workSellSL,Digits));
}

bool UsesTrailingStop()
{
   return(g_workMode==EXIT_TRAILING_ONLY ||
          g_workMode==EXIT_FIXED_TP_AND_TRAILING);
}

bool UsesFixedTakeProfit()
{
   return(g_workMode==EXIT_FIXED_TP ||
          g_workMode==EXIT_FIXED_TP_AND_TRAILING);
}

void EnsureInitialProtection(int ticket)
{
   if(!OrderSelect(ticket,SELECT_BY_TICKET))
      return;

   int type=OrderType();
   if(type!=OP_BUY && type!=OP_SELL)
      return;

   double expectedSL=InitialStopLoss(type,OrderOpenPrice());
   double expectedTP=InitialTakeProfit(type,OrderOpenPrice());
   double currentSL=OrderStopLoss();
   double currentTP=OrderTakeProfit();

   bool needSL=false;
   if(currentSL<=0.0)
      needSL=true;
   else if(type==OP_BUY && currentSL<expectedSL-2.0*Point)
      needSL=true;
   else if(type==OP_SELL && currentSL>expectedSL+2.0*Point)
      needSL=true;

   bool needTP=false;
   if(UsesFixedTakeProfit())
      needTP=(MathAbs(currentTP-expectedTP)>2.0*Point);
   else
      needTP=(currentTP>0.0);

   if(!needSL && !needTP)
      return;

   double newSL=needSL ? expectedSL : currentSL;
   double newTP=needTP ? expectedTP : currentTP;

   if(!ModifyMarketProtection(ticket,newSL,newTP))
   {
      Print("Initial TP/SL protection update failed for ticket ",ticket,
            ". Error ",GetLastError());
      ResetLastError();
   }
}

void ManageActiveTradeExits()
{
   if(!UsesTrailingStop() && g_workBE<=0.0)
      return;

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES))
         continue;

      if(!IsEventOrderSelected())
         continue;

      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL)
         continue;

      ManageOneActiveTrade(OrderTicket());
   }
}

void ManageOneActiveTrade(int ticket)
{
   if(!OrderSelect(ticket,SELECT_BY_TICKET))
      return;

   int type=OrderType();
   if(type!=OP_BUY && type!=OP_SELL)
      return;

   RefreshRates();

   double marketPrice=(type==OP_BUY)?Bid:Ask;
   double profitMovement=(type==OP_BUY)
                         ? marketPrice-OrderOpenPrice()
                         : OrderOpenPrice()-marketPrice;

   double currentSL=OrderStopLoss();
   double desiredSL=currentSL;
   bool improve=false;

   if(g_workBE>0.0 &&
      profitMovement>=g_workBE)
   {
      double breakEvenSL=(type==OP_BUY)
                         ? OrderOpenPrice()+BreakEvenLockMovement
                         : OrderOpenPrice()-BreakEvenLockMovement;
      breakEvenSL=NormalizeDouble(breakEvenSL,Digits);

      if(IsStopImprovement(type,currentSL,breakEvenSL,0.0))
      {
         desiredSL=breakEvenSL;
         improve=true;
      }
   }

   if(UsesTrailingStop() &&
      profitMovement>=TrailingActivationMovement)
   {
      double trailingSL=(type==OP_BUY)
                        ? Bid-g_workTrail
                        : Ask+g_workTrail;
      trailingSL=NormalizeDouble(trailingSL,Digits);

      double comparisonSL=improve ? desiredSL : currentSL;

      if(IsStopImprovement(type,comparisonSL,trailingSL,TrailingStepMovement))
      {
         desiredSL=trailingSL;
         improve=true;
      }
   }

   if(!improve)
      return;

   if(!MarketStopIsValid(type,desiredSL))
      return;

   if(!ModifyMarketProtection(ticket,desiredSL,OrderTakeProfit()))
   {
      int errorCode=GetLastError();
      ResetLastError();

      if(errorCode!=1)
         Print("Trailing/break-even modification failed for ticket ",
               ticket,". Error ",errorCode);
   }
   else
   {
      g_lastAction="SL ADVANCED: "+DoubleToString(desiredSL,Digits);
   }
}

bool IsStopImprovement(int marketType,
                       double currentSL,
                       double proposedSL,
                       double minimumStep)
{
   if(proposedSL<=0.0)
      return(false);

   if(currentSL<=0.0)
      return(true);

   if(marketType==OP_BUY)
      return(proposedSL>=currentSL+minimumStep-Point);

   return(proposedSL<=currentSL-minimumStep+Point);
}

bool MarketStopIsValid(int marketType,double stopLoss)
{
   RefreshRates();

   double brokerDistance=MathMax(
      MarketInfo(Symbol(),MODE_STOPLEVEL),
      MarketInfo(Symbol(),MODE_FREEZELEVEL)
   )*Point;

   if(marketType==OP_BUY)
      return(Bid-stopLoss>=brokerDistance);

   return(stopLoss-Ask>=brokerDistance);
}

bool ModifyMarketProtection(int ticket,double stopLoss,double takeProfit)
{
   if(!OrderSelect(ticket,SELECT_BY_TICKET))
      return(false);

   stopLoss=NormalizeDouble(stopLoss,Digits);
   takeProfit=(takeProfit>0.0)
              ? NormalizeDouble(takeProfit,Digits)
              : 0.0;

   return(OrderModify(
      ticket,
      OrderOpenPrice(),
      stopLoss,
      takeProfit,
      0,
      clrNONE
   ));
}

void ExpirePendingOrders()
{
   int deleted=0;

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(!IsEventOrderSelected()) continue;
      if(OrderType()!=OP_BUYSTOP && OrderType()!=OP_SELLSTOP) continue;

      int ticket=OrderTicket();
      if(OrderDelete(ticket,WarningColor))
         deleted++;
      else
      {
         Print("Expiry deletion failed for ticket ",ticket,
               ". Error ",GetLastError());
         ResetLastError();
      }
   }

   if(CountActiveEventTrades()>0)
   {
      SetState(STATE_ACTIVE);
      return;
   }

   if(CountPendingEventOrders()==0 && g_state!=STATE_COMPLETE)
   {
      SetState(STATE_EXPIRED);

      if(deleted>0)
      {
         g_lastAction="UNTRIGGERED ORDERS EXPIRED";
         Notify("XVISION News Straddle V8 expired without a trigger | "+EventName);
      }
   }
}

int CountPendingEventOrders()
{
   int count=0;

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(!IsEventOrderSelected()) continue;
      if(OrderType()==OP_BUYSTOP || OrderType()==OP_SELLSTOP) count++;
   }

   return(count);
}

bool EventHasAnyOpenOrder()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(IsEventOrderSelected()) return(true);
   }
   return(false);
}

bool EventHasMarketHistory()
{
   for(int i=OrdersHistoryTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(!IsEventOrderSelected()) continue;
      if(OrderType()==OP_BUY || OrderType()==OP_SELL) return(true);
   }
   return(false);
}

bool IsEventOrderSelected()
{
   if(OrderSymbol()!=Symbol()) return(false);
   if(OrderMagicNumber()!=MagicNumber) return(false);
   return(StringFind(OrderComment(),g_eventToken,0)==0);
}

void SynchroniseState()
{
   int active=CountActiveEventTrades();
   int pending=CountPendingEventOrders();

   if(active>0)
   {
      SetState(STATE_ACTIVE);
      return;
   }

   if(pending>0)
   {
      SetState(STATE_PENDING);
      return;
   }

   if(EventHasMarketHistory())
   {
      SetState(STATE_COMPLETE);
      return;
   }

   if(GlobalVariableCheck(g_globalStateName))
   {
      int stored=(int)GlobalVariableGet(g_globalStateName);
      // V3 FIX: a stored PENDING/EXPIRED/etc with NO live orders and NO history
      // for a window that has not even opened yet is stale residue from an
      // earlier attach/test. It must not veto a fresh upcoming event.
      // V8: CANCELLED is a deliberate user decision, never stale residue -
      // clearing it here would silently re-arm a cancelled event.
      if(stored>=STATE_PENDING && stored!=STATE_CANCELLED && TimeGMT()<g_placeGMT)
      {
         GlobalVariableDel(g_globalStateName);
         g_state=STATE_WAITING;
         g_lastAction="STALE STATE CLEARED";
         return;
      }
      if(stored==STATE_PENDING && TimeGMT()>=g_expiryGMT)
         stored=STATE_EXPIRED;
      g_state=stored;
      return;
   }

   g_state=STATE_WAITING;
}

void SetState(int stateValue)
{
   g_state=stateValue;
   GlobalVariableSet(g_globalStateName,(double)stateValue);
}

bool DeleteOrderByTicket(int ticket)
{
   if(!OrderSelect(ticket,SELECT_BY_TICKET)) return(false);
   if(OrderType()!=OP_BUYSTOP && OrderType()!=OP_SELLSTOP) return(false);

   bool result=OrderDelete(ticket,WarningColor);
   if(!result)
   {
      Print("OrderDelete failed for ticket ",ticket,
            ". Error ",GetLastError());
      ResetLastError();
   }
   return(result);
}

double NormalizeLots(double requestedLots)
{
   double minLot=MarketInfo(Symbol(),MODE_MINLOT);
   double maxLot=MarketInfo(Symbol(),MODE_MAXLOT);
   double lotStep=MarketInfo(Symbol(),MODE_LOTSTEP);

   if(lotStep<=0.0) lotStep=0.01;

   double lots=MathMax(minLot,MathMin(maxLot,requestedLots));
   lots=MathFloor((lots/lotStep)+0.0000001)*lotStep;
   lots=NormalizeDouble(lots,LotDigits());
   if(lots<minLot) lots=minLot;
   return(lots);
}

int LotDigits()
{
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(step>=1.0) return(0);
   if(step>=0.1) return(1);
   if(step>=0.01) return(2);
   return(3);
}

bool IsGoldSymbol()
{
   string symbolName=Symbol();
   StringToUpper(symbolName);
   return(StringFind(symbolName,"GOLD",0)>=0 ||
          StringFind(symbolName,"XAU",0)>=0);
}

string BuildGlobalStateName()
{
   string name="XVNS_"+IntegerToString(AccountNumber())+"_"+
               IntegerToString(MagicNumber)+"_"+
               IntegerToString((int)g_newsGMT);

   if(StringLen(name)>63) name=StringSubstr(name,0,63);
   return(name);
}

void Notify(string message)
{
   Print(message);
   if(EnablePopupAlerts) Alert(message);
   if(EnablePushNotifications) SendNotification(message);
}

void UpdatePanel()
{
   if(!ShowGMTPanel)
   {
      DeletePanel();
      return;
   }

   datetime nowGMT=TimeGMT();
   datetime brokerNow=TimeCurrent();
   int brokerOffset=(int)(brokerNow-nowGMT);

   double buyPrice=FindOpenOrderPrice(OP_BUYSTOP);
   double sellPrice=FindOpenOrderPrice(OP_SELLSTOP);

   string buyText=(buyPrice>0.0)?DoubleToString(buyPrice,Digits):"not placed";
   string sellText=(sellPrice>0.0)?DoubleToString(sellPrice,Digits):"not placed";

   UpsertHeaderBackground();
   UpsertPanelBackground();

   UpsertPanelLabel(PREFIX+"GMT",
      "GMT NOW: "+TimeToString(nowGMT,TIME_DATE|TIME_SECONDS),
      GMTHeaderText,4,true);

   UpsertPanelLabel(PREFIX+"L1",
      "EVENT: "+EventName+"  |  NEWS GMT: "+
      TimeToString(g_newsGMT,TIME_DATE|TIME_MINUTES),
      PanelText,32,false);

   UpsertPanelLabel(PREFIX+"L2",
      "PLACE GMT: "+TimeToString(g_placeGMT,TIME_DATE|TIME_SECONDS)+
      "  |  EXPIRE GMT: "+TimeToString(g_expiryGMT,TIME_DATE|TIME_SECONDS),
      PanelText,49,false);

   UpsertPanelLabel(PREFIX+"L3",
      "STATE: "+StateText()+"  |  COUNTDOWN: "+CountdownText(nowGMT)+
      "  |  LAST: "+g_lastAction+"  |  DIAG: "+(g_blockReason==""?"-":g_blockReason),
      StateColor(),66,false);

   UpsertPanelLabel(PREFIX+"L4",
      "BUY STOP: "+buyText+"  |  SELL STOP: "+sellText+
      "  |  SPREAD: "+DoubleToString(Ask-Bid,Digits),
      PanelText,83,false);

   UpsertPanelLabel(PREFIX+"L5",
      "LOT: "+DoubleToString(NormalizeLots(g_workLot),LotDigits())+
      "  |  EXIT: "+ModeShort(g_workMode)+
      "  |  SL B/S: "+DoubleToString(g_workBuySL,1)+
      "/"+DoubleToString(g_workSellSL,1)+
      "  |  TP B/S: "+DoubleToString(g_workBuyTP,1)+
      "/"+DoubleToString(g_workSellTP,1),
      PanelText,100,false);

   UpsertPanelLabel(PREFIX+"L6",
      "TRAIL ACT/DIST/STEP: "+DoubleToString(TrailingActivationMovement,1)+
      "/"+DoubleToString(g_workTrail,1)+
      "/"+DoubleToString(TrailingStepMovement,1)+
      "  |  BE: "+BreakEvenText(),
      PanelText,117,false);

   UpsertPanelLabel(PREFIX+"L7",
      "BROKER TIME: "+TimeToString(brokerNow,TIME_DATE|TIME_SECONDS)+
      "  |  BROKER-GMT OFFSET: "+OffsetText(brokerOffset),
      PanelText,134,false);

   ChartRedraw();
}

double FindOpenOrderPrice(int requestedType)
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(!IsEventOrderSelected()) continue;
      if(OrderType()==requestedType) return(OrderOpenPrice());
   }
   return(0.0);
}

string BreakEvenText()
{
   if(!MoveToBreakEvenFirst)
      return("OFF");

   return(DoubleToString(BreakEvenActivationMovement,1)+
          " -> +"+DoubleToString(BreakEvenLockMovement,1));
}

string StateText()
{
   if(EnforceGoldSymbol && !IsGoldSymbol()) return("WRONG SYMBOL");
   if(g_state==STATE_PENDING)  return("ARMED");
   if(g_state==STATE_ACTIVE)   return("TRADE ACTIVE");
   if(g_state==STATE_COMPLETE) return("COMPLETE");
   if(g_state==STATE_EXPIRED)  return("EXPIRED");
   if(g_state==STATE_CANCELLED) return("CANCELLED");
   if(g_state==STATE_ERROR)    return("ERROR");

   datetime nowGMT=TimeGMT();
   if(nowGMT<g_placeGMT) return("WAITING");
   if(nowGMT<g_newsGMT) return("PLACEMENT WINDOW");
   if(nowGMT<=g_expiryGMT) return("NEWS WINDOW");
   return("PAST EVENT");
}

color StateColor()
{
   if(g_state==STATE_PENDING) return(clrLime);
   if(g_state==STATE_ACTIVE) return(BuyColor);
   if(g_state==STATE_COMPLETE) return(clrLimeGreen);
   if(g_state==STATE_EXPIRED) return(WarningColor);
   if(g_state==STATE_CANCELLED) return(WarningColor);
   if(g_state==STATE_ERROR) return(clrRed);
   return(PanelText);
}

string CountdownText(datetime nowGMT)
{
   datetime target=g_placeGMT;
   string prefix="TO PLACEMENT ";

   if(nowGMT>=g_placeGMT && nowGMT<g_newsGMT)
   {
      target=g_newsGMT;
      prefix="TO NEWS ";
   }
   else if(nowGMT>=g_newsGMT && nowGMT<g_expiryGMT)
   {
      target=g_expiryGMT;
      prefix="TO EXPIRY ";
   }
   else if(nowGMT>=g_expiryGMT)
   {
      return("EVENT WINDOW CLOSED");
   }

   long seconds=(long)(target-nowGMT);
   if(seconds<0) seconds=0;
   return(prefix+DurationText(seconds));
}

string DurationText(long totalSeconds)
{
   long days=totalSeconds/86400;
   long remainder=totalSeconds%86400;
   long hours=remainder/3600;
   remainder%=3600;
   long minutes=remainder/60;
   long seconds=remainder%60;

   string result="";
   if(days>0) result=IntegerToString((int)days)+"d ";
   result+=TwoDigits((int)hours)+":"+TwoDigits((int)minutes)+":"+TwoDigits((int)seconds);
   return(result);
}

string TwoDigits(int value)
{
   if(value<10) return("0"+IntegerToString(value));
   return(IntegerToString(value));
}

string OffsetText(int totalSeconds)
{
   string sign=(totalSeconds>=0)?"+":"-";
   int absolute=MathAbs(totalSeconds);
   int hours=absolute/3600;
   int minutes=(absolute%3600)/60;
   return(sign+TwoDigits(hours)+":"+TwoDigits(minutes));
}

void UpsertHeaderBackground()
{
   string name=PREFIX+"HEADER_BG";
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);

   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,PanelRightMargin);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,PanelTopMargin);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,PanelWidth);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,25);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,GMTHeaderBackground);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,PanelBorder);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

void UpsertPanelBackground()
{
   string name=PREFIX+"PANEL_BG";
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);

   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,PanelRightMargin);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,PanelTopMargin+25);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,PanelWidth);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,PanelHeight-25);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,PanelBackground);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,PanelBorder);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

void UpsertPanelLabel(string name,string text,color textColor,int yOffset,bool bold)
{
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);

   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,PanelRightMargin+10);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,PanelTopMargin+yOffset);
   ObjectSetInteger(0,name,OBJPROP_COLOR,textColor);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,bold?PanelFontSize+2:PanelFontSize);
   ObjectSetString(0,name,OBJPROP_FONT,bold?"Arial Bold":"Arial");
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

void DeletePanel()
{
   DeleteObject(PREFIX+"HEADER_BG");
   DeleteObject(PREFIX+"PANEL_BG");
   DeleteObject(PREFIX+"GMT");
   DeleteObject(PREFIX+"L1");
   DeleteObject(PREFIX+"L2");
   DeleteObject(PREFIX+"L3");
   DeleteObject(PREFIX+"L4");
   DeleteObject(PREFIX+"L5");
   DeleteObject(PREFIX+"L6");
   DeleteObject(PREFIX+"L7");
}

void DeleteObjectsByPrefix()
{
   for(int i=ObjectsTotal(0,-1,-1)-1;i>=0;i--)
   {
      string objectName=ObjectName(0,i);
      if(StringFind(objectName,PREFIX,0)==0) ObjectDelete(0,objectName);
   }
}

void DeleteObject(string name)
{
   if(ObjectFind(0,name)>=0) ObjectDelete(0,name);
}

//+------------------------------------------------------------------+
//| V4 ON-PANEL CONTROLS                                              |
//+------------------------------------------------------------------+
void ApplySchedule(datetime newsGMT)
{
   g_newsGMT=newsGMT;
   int leadSeconds=PlaceMinutesBeforeNews*60+PlaceAdditionalSecondsBeforeNews;
   int expirySeconds=CancelMinutesAfterNews*60+CancelAdditionalSecondsAfterNews;
   g_placeGMT=g_newsGMT-leadSeconds;
   g_expiryGMT=g_newsGMT+expirySeconds;
   g_eventToken="XVN2_"+IntegerToString((int)g_newsGMT);
   g_globalStateName=BuildGlobalStateName();
   g_blockReason=""; g_notifiedReason="";
   g_missedNotified=false; g_heartbeatSent=false;
   SynchroniseState();
}

string OvrName(string tag)
{ return(PREFIX+"OVR_"+tag+"_"+Symbol()+"_"+IntegerToString(MagicNumber)); }

void SaveOverrides()
{
   GlobalVariableSet(OvrName("NEWS"),(double)g_newsGMT);
   GlobalVariableSet(OvrName("LOT"),g_workLot);
   GlobalVariableSet(OvrName("BDIST"),g_workBuyDist);
   GlobalVariableSet(OvrName("SDIST"),g_workSellDist);
   GlobalVariableSet(OvrName("BTP"),g_workBuyTP);
   GlobalVariableSet(OvrName("STP"),g_workSellTP);
   GlobalVariableSet(OvrName("BSL"),g_workBuySL);
   GlobalVariableSet(OvrName("SSL"),g_workSellSL);
   GlobalVariableSet(OvrName("TRAIL"),g_workTrail);
   GlobalVariableSet(OvrName("BE"),g_workBE);
   GlobalVariableSet(OvrName("MODE"),(double)g_workMode);
}

void RestoreOverrides()
{
   if(GlobalVariableCheck(OvrName("LOT")))
      g_workLot=NormalizeLots(GlobalVariableGet(OvrName("LOT")));
   if(g_workLot<=0.0) g_workLot=LotSize;
   if(GlobalVariableCheck(OvrName("BDIST")) && GlobalVariableGet(OvrName("BDIST"))>0)
      g_workBuyDist=GlobalVariableGet(OvrName("BDIST"));
   if(GlobalVariableCheck(OvrName("SDIST")) && GlobalVariableGet(OvrName("SDIST"))>0)
      g_workSellDist=GlobalVariableGet(OvrName("SDIST"));
   if(GlobalVariableCheck(OvrName("BTP")) && GlobalVariableGet(OvrName("BTP"))>0)
      g_workBuyTP=GlobalVariableGet(OvrName("BTP"));
   if(GlobalVariableCheck(OvrName("STP")) && GlobalVariableGet(OvrName("STP"))>0)
      g_workSellTP=GlobalVariableGet(OvrName("STP"));
   if(GlobalVariableCheck(OvrName("BSL")) && GlobalVariableGet(OvrName("BSL"))>0)
      g_workBuySL=GlobalVariableGet(OvrName("BSL"));
   if(GlobalVariableCheck(OvrName("SSL")) && GlobalVariableGet(OvrName("SSL"))>0)
      g_workSellSL=GlobalVariableGet(OvrName("SSL"));
   if(GlobalVariableCheck(OvrName("TRAIL")) && GlobalVariableGet(OvrName("TRAIL"))>0)
      g_workTrail=GlobalVariableGet(OvrName("TRAIL"));
   if(GlobalVariableCheck(OvrName("BE")))
      g_workBE=GlobalVariableGet(OvrName("BE"));
   if(GlobalVariableCheck(OvrName("MODE")))
      g_workMode=(int)GlobalVariableGet(OvrName("MODE"));
   if(GlobalVariableCheck(OvrName("NEWS")))
   {
      datetime dt=(datetime)GlobalVariableGet(OvrName("NEWS"));
      if(dt>0) ApplySchedule(dt);
   }
}

void ClearOverrides()
{
   // TP/SL are the legacy V7 tag names, cleared for terminals upgrading in place.
   string tags[13]={"NEWS","LOT","BDIST","SDIST","BTP","STP","BSL","SSL",
                    "TP","SL","TRAIL","BE","MODE"};
   for(int k=0;k<13;k++)
      if(GlobalVariableCheck(OvrName(tags[k]))) GlobalVariableDel(OvrName(tags[k]));
}

void UpsertControls()
{
   int y1=PanelTopMargin+PanelHeight+8;    // row 1: schedule
   int y2=y1+26;                            // row 2: distances/TP/SL/trail
   int y3=y2+26;                            // row 3: mode + break-even
   int y4=y3+26;                            // row 4: actions
   MakeLabelCtl(PREFIX+"LB_TIME","NEWS GMT:",PanelRightMargin+520,y1+4);
   MakeEdit(PREFIX+"ED_TIME",PanelRightMargin+330,y1,180,22,
            TimeToString(g_newsGMT,TIME_DATE|TIME_MINUTES));
   MakeLabelCtl(PREFIX+"LB_LOT","LOT:",PanelRightMargin+280,y1+4);
   MakeEdit(PREFIX+"ED_LOT",PanelRightMargin+190,y1,85,22,
            DoubleToString(g_workLot,2));

   MakeLabelCtl(PREFIX+"LB_BD","B.DIST:",PanelRightMargin+560,y2+4);
   MakeEdit(PREFIX+"ED_BD",PanelRightMargin+490,y2,68,22,DoubleToString(g_workBuyDist,1));
   MakeLabelCtl(PREFIX+"LB_SD","S.DIST:",PanelRightMargin+448,y2+4);
   MakeEdit(PREFIX+"ED_SD",PanelRightMargin+378,y2,68,22,DoubleToString(g_workSellDist,1));
   MakeLabelCtl(PREFIX+"LB_TP","TP:",PanelRightMargin+346,y2+4);
   MakeEdit(PREFIX+"ED_TP",PanelRightMargin+276,y2,68,22,DoubleToString(g_workBuyTP,1));
   MakeLabelCtl(PREFIX+"LB_SL","SL:",PanelRightMargin+244,y2+4);
   MakeEdit(PREFIX+"ED_SL",PanelRightMargin+174,y2,68,22,DoubleToString(g_workBuySL,1));
   MakeLabelCtl(PREFIX+"LB_TR","TRAIL:",PanelRightMargin+140,y2+4);
   MakeEdit(PREFIX+"ED_TR",PanelRightMargin+72,y2,68,22,DoubleToString(g_workTrail,1));

   // row 3: mode selector + break-even
   MakeLabelCtl(PREFIX+"LB_MODE","MODE:",PanelRightMargin+560,y3+4);
   MakeButton(PREFIX+"BT_MODE",ModeShort(g_workMode),PanelRightMargin+372,y3,186,22,clrDarkSlateGray);
   MakeLabelCtl(PREFIX+"LB_BE","BREAK-EVEN:",PanelRightMargin+346,y3+4);
   MakeEdit(PREFIX+"ED_BE",PanelRightMargin+276,y3,68,22,DoubleToString(g_workBE,1));

   // row 4: actions
   MakeButton(PREFIX+"BT_APPLY","APPLY",PanelRightMargin+560,y4,88,22,clrSeaGreen);
   MakeButton(PREFIX+"BT_RESET","RESET",PanelRightMargin+467,y4,88,22,clrDarkSlateGray);
   MakeButton(PREFIX+"BT_CANCEL","CANCEL SETUP",PanelRightMargin+330,y4,132,22,clrChocolate);
   MakeButton(PREFIX+"BT_CLOSE","CLOSE NOW",PanelRightMargin+193,y4,132,22,clrFireBrick);
   MakeLabelCtl(PREFIX+"LB_HINT",
      "amounts in $  |  TP/SL edits set both sides  |  BE 0=off  |  MODE cycles  |  CANCEL=pre-trigger  |  CLOSE=post-trigger",
      PanelRightMargin+560,y4+4);

   ApplyTrailGreying();
}

string ModeShort(int m)
{
   if(m==EXIT_FIXED_TP) return("MODE: FIXED TP+SL");
   if(m==EXIT_TRAILING_ONLY) return("MODE: TRAILING ONLY");
   return("MODE: TP + TRAILING");
}

void ApplyTrailGreying()
{
   bool trailOn=(g_workMode==EXIT_TRAILING_ONLY || g_workMode==EXIT_FIXED_TP_AND_TRAILING);
   color edgeCol=trailOn?clrYellow:clrDimGray;
   color lblCol =trailOn?clrSilver:clrDimGray;
   if(ObjectFind(0,PREFIX+"ED_TR")>=0)
   {
      ObjectSetInteger(0,PREFIX+"ED_TR",OBJPROP_COLOR,edgeCol);
      ObjectSetInteger(0,PREFIX+"ED_TR",OBJPROP_READONLY,!trailOn);
   }
   if(ObjectFind(0,PREFIX+"LB_TR")>=0)
      ObjectSetInteger(0,PREFIX+"LB_TR",OBJPROP_COLOR,lblCol);
   // TP field greyed when a fixed-TP mode is NOT active
   bool tpOn=(g_workMode==EXIT_FIXED_TP || g_workMode==EXIT_FIXED_TP_AND_TRAILING);
   if(ObjectFind(0,PREFIX+"ED_TP")>=0)
   {
      ObjectSetInteger(0,PREFIX+"ED_TP",OBJPROP_COLOR,tpOn?clrYellow:clrDimGray);
      ObjectSetInteger(0,PREFIX+"ED_TP",OBJPROP_READONLY,!tpOn);
   }
   if(ObjectFind(0,PREFIX+"LB_TP")>=0)
      ObjectSetInteger(0,PREFIX+"LB_TP",OBJPROP_COLOR,tpOn?clrSilver:clrDimGray);
   UpdateActionButtons();
}

//+------------------------------------------------------------------+
//| CLOSE live only when a trade is active; CANCEL live only while a  |
//| setup is armed/pending and nothing has triggered yet.            |
void UpdateActionButtons()
{
   bool tradeLive  = (CountActiveEventTrades()>0);
   bool setupArmed = (!tradeLive) &&
                     (g_state==STATE_WAITING || g_state==STATE_PENDING);

   if(ObjectFind(0,PREFIX+"BT_CLOSE")>=0)
   {
      ObjectSetInteger(0,PREFIX+"BT_CLOSE",OBJPROP_BGCOLOR, tradeLive?clrFireBrick:clrDimGray);
      ObjectSetInteger(0,PREFIX+"BT_CLOSE",OBJPROP_COLOR,   tradeLive?clrWhite:clrGray);
   }
   if(ObjectFind(0,PREFIX+"BT_CANCEL")>=0)
   {
      ObjectSetInteger(0,PREFIX+"BT_CANCEL",OBJPROP_BGCOLOR, setupArmed?clrChocolate:clrDimGray);
      ObjectSetInteger(0,PREFIX+"BT_CANCEL",OBJPROP_COLOR,   setupArmed?clrWhite:clrGray);
   }
}

void MakeEdit(string name,int x,int y,int w,int hgt,string initial)
{
   if(ObjectFind(0,name)>=0) return;      // never clobber user typing
   ObjectCreate(0,name,OBJ_EDIT,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,hgt);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,PanelFontSize);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,clrBlack);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrYellow);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,clrDimGray);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetString(0,name,OBJPROP_TEXT,initial);
}

void MakeButton(string name,string text,int x,int y,int w,int hgt,color bg)
{
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
      ObjectSetInteger(0,name,OBJPROP_YSIZE,hgt);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,PanelFontSize);
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetString(0,name,OBJPROP_TEXT,text);
   }
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
}

void MakeLabelCtl(string name,string text,int x,int y)
{
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,PanelFontSize);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrSilver);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   }
   ObjectSetString(0,name,OBJPROP_TEXT,text);
}

void SetControlTexts()
{
   if(ObjectFind(0,PREFIX+"ED_TIME")>=0)
      ObjectSetString(0,PREFIX+"ED_TIME",OBJPROP_TEXT,
                      TimeToString(g_newsGMT,TIME_DATE|TIME_MINUTES));
   if(ObjectFind(0,PREFIX+"ED_LOT")>=0)
      ObjectSetString(0,PREFIX+"ED_LOT",OBJPROP_TEXT,DoubleToString(g_workLot,2));
   if(ObjectFind(0,PREFIX+"ED_BD")>=0)
      ObjectSetString(0,PREFIX+"ED_BD",OBJPROP_TEXT,DoubleToString(g_workBuyDist,1));
   if(ObjectFind(0,PREFIX+"ED_SD")>=0)
      ObjectSetString(0,PREFIX+"ED_SD",OBJPROP_TEXT,DoubleToString(g_workSellDist,1));
   if(ObjectFind(0,PREFIX+"ED_TP")>=0)
      ObjectSetString(0,PREFIX+"ED_TP",OBJPROP_TEXT,DoubleToString(g_workBuyTP,1));
   if(ObjectFind(0,PREFIX+"ED_SL")>=0)
      ObjectSetString(0,PREFIX+"ED_SL",OBJPROP_TEXT,DoubleToString(g_workBuySL,1));
   if(ObjectFind(0,PREFIX+"ED_TR")>=0)
      ObjectSetString(0,PREFIX+"ED_TR",OBJPROP_TEXT,DoubleToString(g_workTrail,1));
   if(ObjectFind(0,PREFIX+"ED_BE")>=0)
      ObjectSetString(0,PREFIX+"ED_BE",OBJPROP_TEXT,DoubleToString(g_workBE,1));
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id!=CHARTEVENT_OBJECT_CLICK) return;

   if(sparam==PREFIX+"BT_CLOSE")
   {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      if(CountActiveEventTrades()<=0)
      { Notify("XVISION News Straddle V8 | CLOSE ignored - no active trade."); }
      else
         PanelCloseNow();
      return;
   }
   if(sparam==PREFIX+"BT_CANCEL")
   {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      if(CountActiveEventTrades()>0)
      { Notify("XVISION News Straddle V8 | CANCEL ignored - trade already triggered. Use CLOSE NOW."); }
      else if(CountPendingEventOrders()<=0 && g_state!=STATE_WAITING && g_state!=STATE_PENDING)
      { Notify("XVISION News Straddle V8 | CANCEL ignored - nothing armed."); }
      else
         PanelCancelSetup();
      return;
   }
   if(sparam==PREFIX+"BT_MODE")
   {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      if(g_state==STATE_PENDING || g_state==STATE_ACTIVE)
      { Notify("XVISION News Straddle V8 | cannot change mode while orders/trades are live."); }
      else
      {
         g_workMode=(g_workMode+1)%3;
         ObjectSetString(0,sparam,OBJPROP_TEXT,ModeShort(g_workMode));
         ApplyTrailGreying();
         g_lastAction="MODE -> "+ModeShort(g_workMode);
         // persist immediately so a mis-click survives, but do not re-arm
         GlobalVariableSet(OvrName("MODE"),(double)g_workMode);
      }
   }
   else if(sparam==PREFIX+"BT_APPLY")
   {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      ApplyFromPanel();
   }
   else if(sparam==PREFIX+"BT_RESET")
   {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      ClearOverrides();
      if(GlobalVariableCheck(g_globalStateName)) GlobalVariableDel(g_globalStateName);
      g_workLot=LotSize;
      g_workBuyDist=BuyStopDistanceMovement;
      g_workSellDist=SellStopDistanceMovement;
      g_workBuyTP=BuyTakeProfitMovement;
      g_workSellTP=SellTakeProfitMovement;
      g_workBuySL=BuyStopLossMovement;
      g_workSellSL=SellStopLossMovement;
      g_workTrail=TrailingStopDistanceMovement;
   g_workBE=(MoveToBreakEvenFirst?BreakEvenActivationMovement:0.0);
   g_workMode=(int)ExitMode;
      ApplySchedule(ParseStrictGMT(NewsDateTimeGMT));
      if(GlobalVariableCheck(g_globalStateName)) GlobalVariableDel(g_globalStateName);
      SynchroniseState();
      SetControlTexts();
      g_lastAction="PANEL RESET TO INPUTS";
      Notify("XVISION News Straddle V8 | panel RESET | news "+
             TimeToString(g_newsGMT,TIME_DATE|TIME_MINUTES)+" | lot "+
             DoubleToString(g_workLot,2));
      UpdatePanel();
   }
}

void ApplyFromPanel()
{
   string tTxt=ObjectGetString(0,PREFIX+"ED_TIME",OBJPROP_TEXT);
   string lTxt=ObjectGetString(0,PREFIX+"ED_LOT",OBJPROP_TEXT);

   datetime dt=ParseStrictGMT(tTxt);
   if(dt<=0)
   {
      g_lastAction="PANEL: BAD TIME FORMAT";
      Notify("XVISION News Straddle V8 | invalid time. Use YYYY.MM.DD HH:MI (GMT).");
      SetControlTexts();
      return;
   }
   double lot=NormalizeLots(StringToDouble(lTxt));
   if(lot<=0.0)
   {
      g_lastAction="PANEL: BAD LOT";
      Notify("XVISION News Straddle V8 | invalid lot size.");
      SetControlTexts();
      return;
   }
   double bd=StringToDouble(ObjectGetString(0,PREFIX+"ED_BD",OBJPROP_TEXT));
   double sd=StringToDouble(ObjectGetString(0,PREFIX+"ED_SD",OBJPROP_TEXT));
   double tp=StringToDouble(ObjectGetString(0,PREFIX+"ED_TP",OBJPROP_TEXT));
   double sl=StringToDouble(ObjectGetString(0,PREFIX+"ED_SL",OBJPROP_TEXT));
   double tl=StringToDouble(ObjectGetString(0,PREFIX+"ED_TR",OBJPROP_TEXT));
   double be=StringToDouble(ObjectGetString(0,PREFIX+"ED_BE",OBJPROP_TEXT));
   bool trailOn=(g_workMode==EXIT_TRAILING_ONLY || g_workMode==EXIT_FIXED_TP_AND_TRAILING);
   bool tpOn=(g_workMode==EXIT_FIXED_TP || g_workMode==EXIT_FIXED_TP_AND_TRAILING);
   if(bd<=0.0 || sd<=0.0 || sl<=0.0)
   {
      g_lastAction="PANEL: BAD PARAMETER";
      Notify("XVISION News Straddle V8 | B.DIST, S.DIST and SL must be positive.");
      SetControlTexts(); return;
   }
   if(tpOn && tp<=0.0)
   {
      g_lastAction="PANEL: BAD TP";
      Notify("XVISION News Straddle V8 | TP must be positive in a fixed-TP mode.");
      SetControlTexts(); return;
   }
   if(trailOn && tl<=0.0)
   {
      g_lastAction="PANEL: BAD TRAIL";
      Notify("XVISION News Straddle V8 | TRAIL must be positive when a trailing mode is selected.");
      SetControlTexts(); return;
   }
   if(be<0.0)
   {
      g_lastAction="PANEL: BAD BREAK-EVEN";
      Notify("XVISION News Straddle V8 | BREAK-EVEN cannot be negative (use 0 to disable).");
      SetControlTexts(); return;
   }
   if(g_state==STATE_PENDING || g_state==STATE_ACTIVE)
   {
      g_lastAction="PANEL: BLOCKED - ORDERS LIVE";
      Notify("XVISION News Straddle V8 | cannot re-schedule while orders/trades are live. Manage or expire them first.");
      return;
   }

   g_workLot=lot;
   g_workBuyDist=bd; g_workSellDist=sd;
   g_workBuyTP=tp; g_workSellTP=tp;
   g_workBuySL=sl; g_workSellSL=sl;
   g_workTrail=tl; g_workBE=be;
   ApplySchedule(dt);
   SaveOverrides();
   SetControlTexts();
   g_lastAction="PANEL APPLIED";
   string warn=(dt<=TimeGMT())?"  (WARNING: time is in the past!)":"";
   Notify("XVISION News Straddle V8 | APPLIED | news "+
          TimeToString(dt,TIME_DATE|TIME_MINUTES)+" GMT | lot "+
          DoubleToString(lot,2)+
          " | dist B/S "+DoubleToString(bd,1)+"/"+DoubleToString(sd,1)+
          " | TP "+DoubleToString(tp,1)+" SL "+DoubleToString(sl,1)+
          " trail "+DoubleToString(tl,1)+" BE "+DoubleToString(be,1)+
          " | "+ModeShort(g_workMode)+warn);
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| PANEL ACTION: close the active trade(s) at market, remove any    |
//| leftover pendings, mark the event COMPLETE so nothing re-arms.   |
void PanelCloseNow()
{
   int closed=0;
   for(int pass=0; pass<3; pass++)   // retry a few times against requotes
   {
      bool again=false;
      for(int i=OrdersTotal()-1;i>=0;i--)
      {
         if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
         if(!IsEventOrderSelected()) continue;
         int type=OrderType();
         if(type==OP_BUY || type==OP_SELL)
         {
            double px=(type==OP_BUY)?Bid:Ask;
            px=NormalizeDouble(px,Digits);
            if(OrderClose(OrderTicket(),OrderLots(),px,SlippagePoints,WarningColor))
               closed++;
            else { again=true; ResetLastError(); }
         }
      }
      if(!again) break;
      Sleep(300); RefreshRates();
   }
   // sweep any still-resting pendings for this event
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(!IsEventOrderSelected()) continue;
      if(OrderType()==OP_BUYSTOP || OrderType()==OP_SELLSTOP)
         if(!OrderDelete(OrderTicket(),WarningColor))
         {
            Print("CLOSE NOW: pending delete failed, ticket ",OrderTicket(),
                  " error ",GetLastError());
            ResetLastError();
         }
   }
   SetState(STATE_COMPLETE);
   g_lastAction="MANUAL CLOSE (panel)";
   Notify("XVISION News Straddle V8 | CLOSED BY PANEL | "+EventName+
          " | positions closed: "+IntegerToString(closed));
   UpdatePanel(); UpdateActionButtons();
}

//+------------------------------------------------------------------+
//| PANEL ACTION: delete un-triggered pendings and disarm the setup  |
//| so it will not place again for this event.                       |
void PanelCancelSetup()
{
   int deleted=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(!IsEventOrderSelected()) continue;
      if(OrderType()==OP_BUYSTOP || OrderType()==OP_SELLSTOP)
         if(OrderDelete(OrderTicket(),WarningColor)) deleted++;
   }
   // CANCELLED (not EXPIRED): survives the stale-state cleaner, so a cancel
   // issued before the placement window opens can never silently re-arm.
   SetState(STATE_CANCELLED);
   g_lastAction="SETUP CANCELLED (panel)";
   Notify("XVISION News Straddle V8 | SETUP CANCELLED | "+EventName+
          " | pendings deleted: "+IntegerToString(deleted)+
          " | will not re-arm for this event (use RESET to re-enable).");
   UpdatePanel(); UpdateActionButtons();
}

