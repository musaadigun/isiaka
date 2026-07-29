#property strict
#property version   "9.00"
#property description "XVISION Gold News Straddle V9 - F7-configured straddle with a read-only status panel"

// ============================================================================
// XVISION GOLD NEWS-STRADDLE EA VERSION 9
//
// V9 REDESIGN
// - All configuration lives in the native F7 "Inputs" tab. The primary
//   trade-setup fields are declared first so they head that list.
// - NewsDateTimeGMT is a native datetime input: F7 shows a calendar/clock
//   picker, so the old dotted-string format can no longer be mistyped.
// - Every input is range-validated at init; a bad value aborts the load
//   with a specific reason printed to the Experts log.
// - The on-chart panel is now read-only status only - no edit boxes, no
//   MODE/APPLY/RESET. The two live-action buttons (CLOSE NOW, CANCEL
//   SETUP) remain, because F7 cannot close a trade or cancel pendings.
// - The panel was rebuilt: sectioned, spaced, colour-accented, readable.
//
// V8 CARRIED FORWARD: per-side TP/SL, dedicated CANCELLED state, the panel
// lot actually being used, and the autotrading-disabled block reason.
//
// TIME STANDARD
// NewsDateTimeGMT is picked in F7 and treated as GMT/UTC. All scheduling
// decisions use TimeGMT(); broker time is display-only.
//
// PRICE STANDARD
// Pending distances, TP and SL are raw Gold price movements, not MT4 points.
// Example: 8.0 means an $8 movement in the Gold quotation.
// ============================================================================

// The exit-mode enum must be declared before the ExitMode input uses it.
enum TradeExitMode
{
   EXIT_FIXED_TP              = 0,   // Fixed TP + SL
   EXIT_TRAILING_ONLY         = 1,   // Trailing stop only
   EXIT_FIXED_TP_AND_TRAILING = 2    // Fixed TP + trailing
};

// ============================================================================
//  PRIMARY TRADE SETUP  (this group heads the F7 "Inputs" tab)
// ============================================================================
input datetime      NewsDateTimeGMT             = D'2099.01.01 00:00'; // News time (GMT) - pick with the date/time widget
input double        LotSize                     = 0.01;   // Order volume in lots
input TradeExitMode ExitMode                    = EXIT_TRAILING_ONLY;  // How triggered trades are managed
input double        BuyStopDistanceMovement     = 8.0;    // Buy-stop distance above Ask ($)
input double        SellStopDistanceMovement    = 8.0;    // Sell-stop distance below Bid ($)
input double        BuyTakeProfitMovement        = 40.0;  // Buy TP ($, fixed-TP modes only)
input double        BuyStopLossMovement          = 20.0;  // Buy SL ($)
input double        SellTakeProfitMovement       = 40.0;  // Sell TP ($, fixed-TP modes only)
input double        SellStopLossMovement         = 20.0;  // Sell SL ($)
input double        TrailingActivationMovement   = 20.0;  // Profit before trailing starts ($)
input double        TrailingStopDistanceMovement = 10.0;  // Trailing stop distance ($)
input double        TrailingStepMovement         = 2.0;   // Minimum trailing step ($)
input bool          MoveToBreakEvenFirst         = true;  // Lock break-even before trailing
input double        BreakEvenActivationMovement  = 12.0;  // Profit before break-even ($)
input double        BreakEvenLockMovement        = 1.0;   // Locked profit at break-even ($)

// ============================================================================
//  EVENT SCHEDULE
// ============================================================================
input string EventName                         = "US CPI";
input int    PlaceMinutesBeforeNews            = 5;
input int    PlaceAdditionalSecondsBeforeNews  = 0;
input int    CancelMinutesAfterNews            = 10;
input int    CancelAdditionalSecondsAfterNews  = 0;

// ============================================================================
//  EXECUTION
// ============================================================================
input bool   EnableBuyStop                     = true;
input bool   EnableSellStop                    = true;
input bool   RequireBothPendingOrders          = true;
input double MaximumSpreadMovement             = 2.0;   // 0 disables filter
input int    SlippagePoints                    = 50;
input int    MagicNumber                       = 26071451;

// ============================================================================
//  SAFETY
// ============================================================================
input bool   EnforceGoldSymbol                 = true;
input bool   CancelOppositePendingOnTrigger    = true;
input bool   CloseSecondTriggeredTrade         = true;
input bool   ReanchorTPAndSLToActualFill        = true;
input bool   DeletePendingOrdersAtExpiry       = true;
input bool   AllowPlacementAfterScheduledTime  = false;
input int    MaximumLatePlacementSeconds       = 0;

// ============================================================================
//  NOTIFICATIONS / MAINTENANCE
// ============================================================================
input bool   ForceResetEventState              = false; // wipe stored state at init (re-enables a cancelled event)
input bool   EnablePopupAlerts                 = true;
input bool   EnablePushNotifications           = false;

// ============================================================================
//  STATUS PANEL (display only)
// ============================================================================
input bool   ShowGMTPanel                      = true;
input int    PanelRightMargin                  = 12;
input int    PanelTopMargin                    = 12;
input int    PanelWidth                        = 340;
input int    PanelFontSize                     = 9;
input color  PanelBackground                   = C'18,20,26';
input color  PanelBorder                       = C'55,60,72';
input color  GMTHeaderBackground               = C'20,28,52';
input color  GMTHeaderText                     = clrGold;
input color  PanelText                         = clrGainsboro;
input color  PanelMutedText                    = C'130,136,150';
input color  PanelAccent                       = C'90,170,255';
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

string   PREFIX="XV_GOLD_NS_EA_V9_";
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
int      g_panelHeight=0;       // computed each redraw; used to place the buttons

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

   // NewsDateTimeGMT is now a native datetime input, so there is no string
   // to parse or mis-format; the F7 picker guarantees a valid value.
   ApplySchedule(NewsDateTimeGMT);

   if(ForceResetEventState && GlobalVariableCheck(g_globalStateName))
   {
      GlobalVariableDel(g_globalStateName);
      g_state=STATE_WAITING;
      Print("XVISION News Straddle V9: stored event state force-cleared.");
   }

   SynchroniseState();
   EventSetTimer(1);
   RunEngine();
   UpdatePanel();
   UpsertControls();
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

// Every input is checked here at init. Because the F7 dialog already enforces
// each field's TYPE (a double field cannot hold letters, the datetime field is
// a picker), this routine only has to reject out-of-RANGE and contradictory
// combinations. Any failure aborts the load with a specific reason logged.
bool ValidateInputs()
{
   if(NewsDateTimeGMT<=0)
   { Print("Validation: NewsDateTimeGMT is not set - pick a date/time in the F7 Inputs tab."); return(false); }

   if(LotSize<=0.0)
   { Print("Validation: LotSize must be greater than zero."); return(false); }

   double minLot=MarketInfo(Symbol(),MODE_MINLOT);
   double maxLot=MarketInfo(Symbol(),MODE_MAXLOT);
   if(minLot>0.0 && LotSize<minLot)
   { Print("Validation: LotSize ",LotSize," is below the broker minimum ",minLot,"."); return(false); }
   if(maxLot>0.0 && LotSize>maxLot)
   { Print("Validation: LotSize ",LotSize," is above the broker maximum ",maxLot,"."); return(false); }

   if(!EnableBuyStop && !EnableSellStop)
   { Print("Validation: at least one pending-order side must be enabled."); return(false); }

   if(RequireBothPendingOrders && (!EnableBuyStop || !EnableSellStop))
   { Print("Validation: RequireBothPendingOrders needs both sides enabled."); return(false); }

   bool fixedTPRequired=(ExitMode==EXIT_FIXED_TP || ExitMode==EXIT_FIXED_TP_AND_TRAILING);
   bool trailingRequired=(ExitMode==EXIT_TRAILING_ONLY || ExitMode==EXIT_FIXED_TP_AND_TRAILING);

   if(EnableBuyStop)
   {
      if(BuyStopDistanceMovement<=0.0)
      { Print("Validation: BuyStopDistanceMovement must be greater than zero."); return(false); }
      if(BuyStopLossMovement<=0.0)
      { Print("Validation: BuyStopLossMovement must be greater than zero."); return(false); }
      if(fixedTPRequired && BuyTakeProfitMovement<=0.0)
      { Print("Validation: BuyTakeProfitMovement must be positive in a fixed-TP mode."); return(false); }
   }

   if(EnableSellStop)
   {
      if(SellStopDistanceMovement<=0.0)
      { Print("Validation: SellStopDistanceMovement must be greater than zero."); return(false); }
      if(SellStopLossMovement<=0.0)
      { Print("Validation: SellStopLossMovement must be greater than zero."); return(false); }
      if(fixedTPRequired && SellTakeProfitMovement<=0.0)
      { Print("Validation: SellTakeProfitMovement must be positive in a fixed-TP mode."); return(false); }
   }

   if(trailingRequired &&
      (TrailingActivationMovement<=0.0 || TrailingStopDistanceMovement<=0.0 || TrailingStepMovement<=0.0))
   { Print("Validation: trailing activation, distance and step must all be greater than zero."); return(false); }

   if(MoveToBreakEvenFirst &&
      (BreakEvenActivationMovement<=0.0 || BreakEvenLockMovement<0.0))
   { Print("Validation: break-even activation must be positive and lock cannot be negative."); return(false); }

   if(PlaceMinutesBeforeNews<0 || PlaceAdditionalSecondsBeforeNews<0 ||
      CancelMinutesAfterNews<0 || CancelAdditionalSecondsAfterNews<0 ||
      MaximumLatePlacementSeconds<0)
   { Print("Validation: schedule offsets cannot be negative."); return(false); }

   if(PlaceMinutesBeforeNews*60+PlaceAdditionalSecondsBeforeNews<=0)
   { Print("Validation: placement lead time (minutes/seconds before news) must be greater than zero."); return(false); }

   if(CancelMinutesAfterNews*60+CancelAdditionalSecondsAfterNews<=0)
   { Print("Validation: cancel window (minutes/seconds after news) must be greater than zero."); return(false); }

   if(MaximumSpreadMovement<0.0)
   { Print("Validation: MaximumSpreadMovement cannot be negative (use 0 to disable the filter)."); return(false); }

   if(SlippagePoints<0)
   { Print("Validation: SlippagePoints cannot be negative."); return(false); }

   if(MagicNumber<=0)
   { Print("Validation: MagicNumber must be a positive number."); return(false); }

   if(PanelWidth<220)
   { Print("Validation: PanelWidth must be at least 220."); return(false); }

   if(PanelFontSize<6)
   { Print("Validation: PanelFontSize must be at least 6."); return(false); }

   return(true);
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
      Notify("XVISION News Straddle V9 alive | arming in <=60s | "+EventName+
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
      Notify("XVISION News Straddle V9 ARM BLOCKED | "+EventName+" | "+g_blockReason);
   }

   // V3: loud alarm if the news moment arrives with nothing armed
   if(!g_missedNotified && g_state==STATE_WAITING && nowGMT>=g_newsGMT)
   {
      g_missedNotified=true;
      Notify("XVISION News Straddle V9 WINDOW MISSED | "+EventName+
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

   Notify("XVISION News Straddle V9 armed | "+EventName+
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

      Notify("XVISION News Straddle V9 "+side+" triggered | Ticket "+
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
         Notify("XVISION News Straddle V9 expired without a trigger | "+EventName);
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
   string buyText =(buyPrice>0.0) ?DoubleToString(buyPrice,Digits) :"--";
   string sellText=(sellPrice>0.0)?DoubleToString(sellPrice,Digits):"--";

   int rowH  = PanelFontSize+11;    // body line pitch
   int secH  = PanelFontSize+15;    // section-header pitch
   int headH = PanelFontSize+20;    // title band height

   // Backgrounds are created first so every label renders on top of them.
   // The outer box is sized to a rough height now and trimmed to the exact
   // height at the end, once the row cursor has run to the bottom.
   PanelRect(PREFIX+"PANEL_BG",PanelTopMargin,600,PanelBackground);
   PanelRect(PREFIX+"HEADER_BG",PanelTopMargin,headH,GMTHeaderBackground);
   DrawLabel(PREFIX+"TITLE",PanelTopMargin+4,PanelFontSize+1,
             "XVISION  -  GOLD NEWS STRADDLE",GMTHeaderText,false,true);

   int y=PanelTopMargin+headH+8;

   // Primary status: STATE and COUNTDOWN, both in a larger font.
   DrawLabel(PREFIX+"CAP_ST",y,PanelFontSize,"STATUS",PanelMutedText,false,false);
   DrawLabel(PREFIX+"VAL_ST",y-1,PanelFontSize+3,StateText(),StateColor(),true,true);
   y+=rowH+6;
   DrawLabel(PREFIX+"CAP_CD",y,PanelFontSize,"COUNTDOWN",PanelMutedText,false,false);
   DrawLabel(PREFIX+"VAL_CD",y-1,PanelFontSize+2,CountdownText(nowGMT),PanelAccent,true,true);
   y+=rowH+6;

   PanelSection(PREFIX+"S_EVT",y,"EVENT");  y+=secH;
   PanelRow(PREFIX+"EVT",  y,"Event",        EventName,                                        PanelText); y+=rowH;
   PanelRow(PREFIX+"NEWS", y,"News (GMT)",   TimeToString(g_newsGMT,TIME_DATE|TIME_MINUTES),   PanelText); y+=rowH;
   PanelRow(PREFIX+"PLC",  y,"Place (GMT)",  TimeToString(g_placeGMT,TIME_DATE|TIME_MINUTES),  PanelText); y+=rowH;
   PanelRow(PREFIX+"EXP",  y,"Expire (GMT)", TimeToString(g_expiryGMT,TIME_DATE|TIME_MINUTES), PanelText); y+=rowH;

   PanelSection(PREFIX+"S_ORD",y,"ORDERS");  y+=secH;
   PanelRow(PREFIX+"BUY",  y,"Buy stop",  buyText,  BuyColor);  y+=rowH;
   PanelRow(PREFIX+"SELL", y,"Sell stop", sellText, SellColor); y+=rowH;
   double spread=Ask-Bid;
   bool spreadHigh=(MaximumSpreadMovement>0.0 && spread>MaximumSpreadMovement);
   PanelRow(PREFIX+"SPR",  y,"Spread",
            DoubleToString(spread,Digits)+(spreadHigh?"  HIGH":""),
            spreadHigh?WarningColor:PanelText); y+=rowH;

   PanelSection(PREFIX+"S_PLN",y,"PLAN");    y+=secH;
   PanelRow(PREFIX+"LOT",  y,"Lot",        DoubleToString(NormalizeLots(g_workLot),LotDigits()), PanelText); y+=rowH;
   PanelRow(PREFIX+"MODE", y,"Exit mode",  ModeText(g_workMode),                                 PanelText); y+=rowH;
   PanelRow(PREFIX+"SL",   y,"SL  buy/sell", DoubleToString(g_workBuySL,1)+" / "+DoubleToString(g_workSellSL,1), PanelText); y+=rowH;
   PanelRow(PREFIX+"TP",   y,"TP  buy/sell", DoubleToString(g_workBuyTP,1)+" / "+DoubleToString(g_workSellTP,1), PanelText); y+=rowH;
   PanelRow(PREFIX+"TRL",  y,"Trail a/d/s",  DoubleToString(TrailingActivationMovement,1)+" / "+
            DoubleToString(g_workTrail,1)+" / "+DoubleToString(TrailingStepMovement,1),          PanelText); y+=rowH;
   PanelRow(PREFIX+"BE",   y,"Break-even",   BreakEvenText(),                                    PanelText); y+=rowH;

   PanelSection(PREFIX+"S_CLK",y,"CLOCK");   y+=secH;
   PanelRow(PREFIX+"GMT",  y,"GMT now", TimeToString(nowGMT,TIME_DATE|TIME_SECONDS), GMTHeaderText); y+=rowH;
   PanelRow(PREFIX+"BRK",  y,"Broker",
            TimeToString(brokerNow,TIME_MINUTES|TIME_SECONDS)+"  ("+OffsetText(brokerOffset)+")",
            PanelMutedText); y+=rowH;
   PanelRow(PREFIX+"NOTE", y,"Note",
            (g_blockReason==""?g_lastAction:g_lastAction+" | "+g_blockReason),
            PanelMutedText); y+=rowH;

   g_panelHeight=(y+6)-PanelTopMargin;
   ObjectSetInteger(0,PREFIX+"PANEL_BG",OBJPROP_YSIZE,g_panelHeight);

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

// A filled rectangle used for the panel body and the header band.
void PanelRect(string name,int yTop,int height,color bg)
{
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,PanelRightMargin);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,yTop);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,PanelWidth);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,name,OBJPROP_COLOR,PanelBorder);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

// One text element. rightAlign=false anchors it to the panel's left inner
// edge (captions); rightAlign=true anchors it to the right inner edge (values).
void DrawLabel(string name,int y,int fontSize,string text,color col,bool rightAlign,bool bold)
{
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,rightAlign?ANCHOR_RIGHT_UPPER:ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,rightAlign?(PanelRightMargin+14):(PanelRightMargin+PanelWidth-14));
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,col);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontSize);
   ObjectSetString(0,name,OBJPROP_FONT,bold?"Tahoma Bold":"Tahoma");
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}

// A section header: accent-coloured caption plus a thin divider rule beneath.
void PanelSection(string name,int y,string title)
{
   DrawLabel(name,y,PanelFontSize-1,title,PanelAccent,false,true);

   string dv=name+"_DV";
   if(ObjectFind(0,dv)<0) ObjectCreate(0,dv,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,dv,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,dv,OBJPROP_XDISTANCE,PanelRightMargin+12);
   ObjectSetInteger(0,dv,OBJPROP_YDISTANCE,y+PanelFontSize+5);
   ObjectSetInteger(0,dv,OBJPROP_XSIZE,PanelWidth-24);
   ObjectSetInteger(0,dv,OBJPROP_YSIZE,1);
   ObjectSetInteger(0,dv,OBJPROP_BGCOLOR,PanelBorder);
   ObjectSetInteger(0,dv,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,dv,OBJPROP_COLOR,PanelBorder);
   ObjectSetInteger(0,dv,OBJPROP_BACK,false);
   ObjectSetInteger(0,dv,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,dv,OBJPROP_HIDDEN,true);
}

// A label/value line: muted caption on the left, coloured value on the right.
void PanelRow(string tag,int y,string caption,string value,color valColor)
{
   DrawLabel(tag+"_C",y,PanelFontSize,caption,PanelMutedText,false,false);
   DrawLabel(tag+"_V",y,PanelFontSize,value,valColor,true,true);
}

string ModeText(int m)
{
   if(m==EXIT_FIXED_TP)      return("Fixed TP + SL");
   if(m==EXIT_TRAILING_ONLY) return("Trailing only");
   return("TP + Trailing");
}

void DeletePanel()
{
   // Every panel object (and the two buttons) shares PREFIX, so hiding the
   // panel simply clears them all; UpsertControls re-skips while hidden.
   DeleteObjectsByPrefix();
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

//+------------------------------------------------------------------+
//| The two live-action buttons sit directly beneath the status      |
//| panel. All configuration now lives in the F7 Inputs tab, so the  |
//| old edit fields, MODE/APPLY/RESET buttons and their global-       |
//| variable override layer have been removed entirely.              |
//+------------------------------------------------------------------+
void UpsertControls()
{
   if(!ShowGMTPanel)
   {
      DeleteObject(PREFIX+"BT_CLOSE");
      DeleteObject(PREFIX+"BT_CANCEL");
      return;
   }

   int btnY = PanelTopMargin+g_panelHeight+8;
   int btnH = PanelFontSize+16;
   int halfW=(PanelWidth-8)/2;

   // CORNER_RIGHT_UPPER: CLOSE takes the right half, CANCEL the left half.
   MakeButton(PREFIX+"BT_CLOSE", "CLOSE NOW",    PanelRightMargin,          btnY,halfW,btnH,clrFireBrick);
   MakeButton(PREFIX+"BT_CANCEL","CANCEL SETUP", PanelRightMargin+halfW+8,  btnY,halfW,btnH,clrChocolate);

   UpdateActionButtons();
}

//+------------------------------------------------------------------+
//| CLOSE is live only when a trade is active; CANCEL is live only    |
//| while a setup is armed/waiting and nothing has triggered yet.     |
//| Inactive buttons are dimmed rather than hidden.                   |
//+------------------------------------------------------------------+
void UpdateActionButtons()
{
   bool tradeLive  = (CountActiveEventTrades()>0);
   bool setupArmed = (!tradeLive) &&
                     (g_state==STATE_WAITING || g_state==STATE_PENDING);

   if(ObjectFind(0,PREFIX+"BT_CLOSE")>=0)
   {
      ObjectSetInteger(0,PREFIX+"BT_CLOSE",OBJPROP_BGCOLOR, tradeLive?clrFireBrick:C'70,45,45');
      ObjectSetInteger(0,PREFIX+"BT_CLOSE",OBJPROP_COLOR,   tradeLive?clrWhite:C'150,150,150');
   }
   if(ObjectFind(0,PREFIX+"BT_CANCEL")>=0)
   {
      ObjectSetInteger(0,PREFIX+"BT_CANCEL",OBJPROP_BGCOLOR, setupArmed?clrChocolate:C'70,60,45');
      ObjectSetInteger(0,PREFIX+"BT_CANCEL",OBJPROP_COLOR,   setupArmed?clrWhite:C'150,150,150');
   }
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
      ObjectSetString(0,name,OBJPROP_FONT,"Tahoma Bold");
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetString(0,name,OBJPROP_TEXT,text);
   }
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
}

//+------------------------------------------------------------------+
//| Only the two live-action buttons are interactive now. Everything  |
//| else is configured through the F7 Inputs tab.                     |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id!=CHARTEVENT_OBJECT_CLICK) return;

   if(sparam==PREFIX+"BT_CLOSE")
   {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      if(CountActiveEventTrades()<=0)
         Notify("XVISION News Straddle V9 | CLOSE ignored - no active trade.");
      else
         PanelCloseNow();
      return;
   }

   if(sparam==PREFIX+"BT_CANCEL")
   {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      if(CountActiveEventTrades()>0)
         Notify("XVISION News Straddle V9 | CANCEL ignored - trade already triggered. Use CLOSE NOW.");
      else if(CountPendingEventOrders()<=0 && g_state!=STATE_WAITING && g_state!=STATE_PENDING)
         Notify("XVISION News Straddle V9 | CANCEL ignored - nothing armed.");
      else
         PanelCancelSetup();
      return;
   }
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
   Notify("XVISION News Straddle V9 | CLOSED BY PANEL | "+EventName+
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
   Notify("XVISION News Straddle V9 | SETUP CANCELLED | "+EventName+
          " | pendings deleted: "+IntegerToString(deleted)+
          " | will not re-arm (set ForceResetEventState=true in F7 to re-enable).");
   UpdatePanel(); UpdateActionButtons();
}

