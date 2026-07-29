#property strict
#property version   "10.00"
#property description "XVISION Gold News Straddle V10 - multi-event daily schedule, per-event isolation, repeat-safe"

// ============================================================================
// XVISION GOLD NEWS-STRADDLE EA VERSION 10
//
// WHY V10 EXISTS
// V9 could only ever hold ONE event. Everything that identified an order -
// the comment token, the state global variable, the countdown, the panel -
// was derived from the single NewsDateTimeGMT input. Running a second event
// on the same day therefore meant editing NewsDateTimeGMT in F7, and that
// silently broke the EA:
//
//   1. Changing the input re-keyed g_eventToken, so a position still open
//      from the earlier event stopped matching IsEventOrderSelected(). The
//      EA abandoned it mid-flight: no trailing, no break-even, no CLOSE NOW.
//   2. The stored state global for the finished event kept its COMPLETE /
//      EXPIRED / CANCELLED value, and the "stored terminal state vetoes
//      arming" rule in CanPlaceNow() then blocked the next event unless the
//      user remembered to tick ForceResetEventState.
//   3. Order identity relied on the broker preserving the order comment.
//      Many brokers rewrite or strip comments when a pending order fills, at
//      which point the EA lost its own trade and re-armed on top of it.
//
// V10 replaces the single event with a SCHEDULE of up to MAX_EVENTS slots.
// Every slot carries its own times, its own magic number, its own state and
// its own countdown, and all of them are serviced on every cycle. Nothing has
// to be retyped between events, and a live trade from an earlier slot keeps
// being managed while a later slot arms.
//
// ORDER IDENTITY (the fix for point 3)
// Slot N owns magic number MagicNumber+N. A broker cannot rewrite a magic
// number, so order ownership no longer depends on comment text. The comment
// token is still written for readability and is used as a secondary match
// when scanning history. MagicNumber .. MagicNumber+MAX_EVENTS-1 is reserved
// for this EA - keep other EAs' magic numbers outside that range.
//
// SCHEDULING
//   NewsDateTimeGMT       - slot 1, absolute, picked with the F7 widget.
//   ExtraEventTimesGMT    - additional slots, comma or semicolon separated:
//                             "12:30=US CPI, 14:00=FOMC"
//                             "2026.08.01 12:30=NFP"
//                           A bare HH:MM entry means that time today (GMT),
//                           rolling to the next day once its window closes.
//   RepeatEventsDaily     - HH:MM slots re-arm every day instead of once.
//   SkipWeekendEvents     - daily rollover jumps Saturday and Sunday.
//
// TIME STANDARD
// Every scheduling decision uses TimeGMT(). Broker time is display-only, and
// the broker/GMT offset is measured from live ticks, rounded to the nearest
// quarter hour and cached in a global variable so it survives weekends and
// restarts.
//
// PRICE STANDARD
// Pending distances, TP and SL are raw Gold price movements, not MT4 points.
// Example: 8.0 means an $8 movement in the Gold quotation.
// ============================================================================

#define MAX_EVENTS 12

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
input bool          UsePrimaryNewsDateTime      = true;   // Include NewsDateTimeGMT as an event slot
input string        ExtraEventTimesGMT          = "";     // More events: "12:30=US CPI, 14:00=FOMC"
input bool          RepeatEventsDaily           = false;  // HH:MM entries re-arm every day
input bool          SkipWeekendEvents           = true;   // Daily rollover skips Sat/Sun
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
//  EVENT SCHEDULE  (these offsets apply to every slot)
// ============================================================================
input string EventName                         = "News";
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
input int    MaximumOrderAttempts              = 5;     // Retries per side on requote/off-quotes
input int    OrderRetryDelayMilliseconds       = 300;
input int    MagicNumber                       = 26071451; // Reserves MagicNumber..MagicNumber+11

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
input bool   ForceResetEventState              = false; // wipe stored state at init (re-enables cancelled events)
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

// NewsDateTimeGMT at or beyond this value is treated as "left at the factory
// placeholder", so a user who schedules purely through ExtraEventTimesGMT is
// not lumbered with a dead slot in the year 2099.
#define PRIMARY_SENTINEL D'2099.01.01 00:00'

string   PREFIX="XV_GOLD_NS_EA_V10_";

// ---------------------------------------------------------------------------
// Per-slot schedule and state. Fixed-size arrays keep this compilable on every
// MT4 build, and a slot's index is what ties it to its magic number, so the
// order of the schedule must stay stable while its orders are live.
// ---------------------------------------------------------------------------
datetime ev_news[MAX_EVENTS];
datetime ev_place[MAX_EVENTS];
datetime ev_expiry[MAX_EVENTS];
int      ev_magic[MAX_EVENTS];
string   ev_token[MAX_EVENTS];
string   ev_gv[MAX_EVENTS];
string   ev_label[MAX_EVENTS];
int      ev_state[MAX_EVENTS];
bool     ev_daily[MAX_EVENTS];        // HH:MM slot that rolls to the next day
int      ev_tod[MAX_EVENTS];          // seconds past midnight, daily slots only
int      ev_active[MAX_EVENTS];       // live counts, refreshed by ScanOrders
int      ev_pending[MAX_EVENTS];
int      ev_survivor[MAX_EVENTS];     // earliest live market ticket for the slot
double   ev_buyPx[MAX_EVENTS];
double   ev_sellPx[MAX_EVENTS];
bool     ev_hist[MAX_EVENTS];         // slot has a closed market order this instance
int      ev_ticketBuy[MAX_EVENTS];
int      ev_ticketSell[MAX_EVENTS];
bool     ev_heartbeat[MAX_EVENTS];
bool     ev_missed[MAX_EVENTS];
string   ev_block[MAX_EVENTS];
string   ev_notified[MAX_EVENTS];
int      ev_lastAlertTicket[MAX_EVENTS];

int      g_eventCount=0;
bool     g_scheduleOK=false;
string   g_scheduleError="";
int      g_focusSlot=0;

bool     g_engineBusy=false;
string   g_lastAction="INITIALISING";
double   g_workLot=0.0;
double   g_workBuyDist=0.0, g_workSellDist=0.0;
double   g_workBuyTP=0.0, g_workSellTP=0.0;
double   g_workBuySL=0.0, g_workSellSL=0.0;
double   g_workTrail=0.0;
double   g_workBE=0.0;          // break-even activation (0 = BE disabled)
int      g_workMode=1;          // 0 FIXED_TP, 1 TRAILING_ONLY, 2 TP+TRAILING
int      g_panelHeight=0;       // computed each redraw; used to place the buttons

int      g_brokerOffset=0;      // broker time - GMT, in seconds
string   g_offsetGV="";
uint     g_lastHistScan=0;
bool     g_histScanned=false;
string   g_lastAlertMessage="";
datetime g_lastAlertTime=0;

int OnInit()
{
   ResetRuntimeState();

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

   LoadBrokerOffset();

   // The schedule is built after the numeric inputs are validated, because
   // every slot's place/expiry time is derived from the offsets above.
   if(!BuildSchedule())
   {
      Print("Validation: ",g_scheduleError);
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(ForceResetEventState)
      ClearAllStoredState();

   PurgeStaleStateGlobals();

   ScanOrders();
   ScanHistory(true);
   SyncAllSlotStates();

   DescribeSchedule();
   WarnOnAdoptedOrders();

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
   // A real tick means TimeCurrent() is genuinely current, which is the only
   // moment the broker/GMT offset can be measured honestly.
   RefreshBrokerOffset();

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

// Globals are not re-initialised when MT4 reloads the EA after an input
// change, so every piece of per-run state is cleared explicitly here.
void ResetRuntimeState()
{
   g_eventCount=0;
   g_scheduleOK=false;
   g_scheduleError="";
   g_focusSlot=0;
   g_engineBusy=false;
   g_lastAction="INITIALISING";
   g_panelHeight=0;
   g_histScanned=false;
   g_lastHistScan=0;
   g_lastAlertMessage="";
   g_lastAlertTime=0;

   for(int s=0;s<MAX_EVENTS;s++)
   {
      ev_news[s]=0; ev_place[s]=0; ev_expiry[s]=0;
      ev_magic[s]=0; ev_token[s]=""; ev_gv[s]=""; ev_label[s]="";
      ev_state[s]=STATE_WAITING;
      ev_daily[s]=false; ev_tod[s]=0;
      ev_active[s]=0; ev_pending[s]=0; ev_survivor[s]=-1;
      ev_buyPx[s]=0.0; ev_sellPx[s]=0.0;
      ev_hist[s]=false;
      ev_ticketBuy[s]=-1; ev_ticketSell[s]=-1;
      ev_heartbeat[s]=false; ev_missed[s]=false;
      ev_block[s]=""; ev_notified[s]="";
      ev_lastAlertTicket[s]=-1;
   }
}

// ============================================================================
//  INPUT VALIDATION
// ============================================================================
bool ValidateInputs()
{
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

   if(MaximumOrderAttempts<1 || MaximumOrderAttempts>20)
   { Print("Validation: MaximumOrderAttempts must be between 1 and 20."); return(false); }

   if(OrderRetryDelayMilliseconds<0 || OrderRetryDelayMilliseconds>5000)
   { Print("Validation: OrderRetryDelayMilliseconds must be between 0 and 5000."); return(false); }

   if(MagicNumber<=0)
   { Print("Validation: MagicNumber must be a positive number."); return(false); }

   if(MagicNumber>2000000000-MAX_EVENTS)
   { Print("Validation: MagicNumber is too large to reserve ",MAX_EVENTS," consecutive numbers."); return(false); }

   if(PanelWidth<220)
   { Print("Validation: PanelWidth must be at least 220."); return(false); }

   if(PanelFontSize<6)
   { Print("Validation: PanelFontSize must be at least 6."); return(false); }

   return(true);
}

// ============================================================================
//  SCHEDULE CONSTRUCTION
// ============================================================================
bool BuildSchedule()
{
   g_eventCount=0;
   g_scheduleOK=false;
   g_scheduleError="";

   string list=ExtraEventTimesGMT;
   StringTrimLeft(list);
   StringTrimRight(list);

   bool primaryUsable=(UsePrimaryNewsDateTime &&
                       NewsDateTimeGMT>0 &&
                       NewsDateTimeGMT<PRIMARY_SENTINEL);

   if(UsePrimaryNewsDateTime && !primaryUsable && list=="")
   {
      g_scheduleError="NewsDateTimeGMT is the 2099 placeholder and ExtraEventTimesGMT is empty.";
      return(false);
   }

   if(primaryUsable)
      AddSlot(NewsDateTimeGMT,false,0,EventName);
   else if(UsePrimaryNewsDateTime && list!="")
      Print("Schedule: NewsDateTimeGMT left at the 2099 placeholder - ",
            "slot skipped, using ExtraEventTimesGMT only.");

   if(list!="")
   {
      StringReplace(list,";",",");

      string parts[];
      int n=StringSplit(list,StringGetCharacter(",",0),parts);

      for(int i=0;i<n;i++)
      {
         string entry=parts[i];
         StringTrimLeft(entry);
         StringTrimRight(entry);
         if(entry=="") continue;

         if(g_eventCount>=MAX_EVENTS)
         {
            g_scheduleError="too many events - the maximum is "+IntegerToString(MAX_EVENTS)+".";
            return(false);
         }

         if(!ParseScheduleEntry(entry))
            return(false);   // ParseScheduleEntry filled g_scheduleError
      }
   }

   if(g_eventCount<=0)
   {
      g_scheduleError="the schedule is empty - set NewsDateTimeGMT or ExtraEventTimesGMT.";
      return(false);
   }

   WarnOnOverlappingWindows();

   g_scheduleOK=true;
   return(true);
}

// One "HH:MM[:SS]" or "yyyy.mm.dd HH:MM" entry, with an optional "=Label".
bool ParseScheduleEntry(string entry)
{
   string label=EventName;

   int eq=StringFind(entry,"=",0);
   if(eq>=0)
   {
      label=StringSubstr(entry,eq+1);
      entry=StringSubstr(entry,0,eq);
      StringTrimLeft(label);  StringTrimRight(label);
      StringTrimLeft(entry);  StringTrimRight(entry);
      if(label=="") label=EventName;
   }

   if(entry=="")
   {
      g_scheduleError="an ExtraEventTimesGMT entry has a label but no time.";
      return(false);
   }

   // A dot or slash means the user supplied a full date, so hand it to the
   // platform parser. Anything else is treated as a time of day.
   if(StringFind(entry,".",0)>=0 || StringFind(entry,"/",0)>=0)
   {
      datetime absolute=StringToTime(entry);
      if(absolute<=0)
      {
         g_scheduleError="cannot read \""+entry+"\" as a date/time - use \"yyyy.mm.dd HH:MM\".";
         return(false);
      }
      AddSlot(absolute,false,0,label);
      return(true);
   }

   int hour=0,minute=0,second=0;
   if(!ParseTimeOfDay(entry,hour,minute,second))
   {
      g_scheduleError="cannot read \""+entry+"\" as a time - use HH:MM or HH:MM:SS.";
      return(false);
   }

   int tod=hour*3600+minute*60+second;
   datetime nowGMT=TimeGMT();
   datetime candidate=DayStartGMT(nowGMT)+tod;

   // A slot whose window has already closed today belongs to the next day,
   // otherwise the EA would boot straight into an EXPIRED event.
   int expirySeconds=CancelMinutesAfterNews*60+CancelAdditionalSecondsAfterNews;
   for(int guard=0;guard<14;guard++)
   {
      bool tooLate=(nowGMT>candidate+expirySeconds);
      bool badDay =(SkipWeekendEvents && IsWeekendGMT(candidate));
      if(!tooLate && !badDay) break;
      candidate+=86400;
   }

   AddSlot(candidate,true,tod,label);
   return(true);
}

bool ParseTimeOfDay(string text,int &hour,int &minute,int &second)
{
   string bits[];
   int n=StringSplit(text,StringGetCharacter(":",0),bits);
   if(n<2 || n>3) return(false);

   for(int i=0;i<n;i++)
   {
      StringTrimLeft(bits[i]);
      StringTrimRight(bits[i]);
      if(!IsAllDigits(bits[i])) return(false);
   }

   hour=(int)StringToInteger(bits[0]);
   minute=(int)StringToInteger(bits[1]);
   second=(n==3)?(int)StringToInteger(bits[2]):0;

   if(hour<0 || hour>23) return(false);
   if(minute<0 || minute>59) return(false);
   if(second<0 || second>59) return(false);
   return(true);
}

bool IsAllDigits(string text)
{
   int len=StringLen(text);
   if(len<=0) return(false);

   for(int i=0;i<len;i++)
   {
      ushort c=StringGetCharacter(text,i);
      if(c<'0' || c>'9') return(false);
   }
   return(true);
}

void AddSlot(datetime news,bool daily,int tod,string label)
{
   if(g_eventCount>=MAX_EVENTS) return;

   int s=g_eventCount;
   g_eventCount++;

   ev_daily[s]=daily;
   ev_tod[s]=tod;
   ev_label[s]=label;
   ev_magic[s]=MagicNumber+s;

   ApplySlotTimes(s,news);
}

// Recomputes everything a slot derives from its news time. Called when the
// schedule is built and again on every daily rollover.
void ApplySlotTimes(int s,datetime news)
{
   int leadSeconds=PlaceMinutesBeforeNews*60+PlaceAdditionalSecondsBeforeNews;
   int expirySeconds=CancelMinutesAfterNews*60+CancelAdditionalSecondsAfterNews;

   ev_news[s]=news;
   ev_place[s]=news-leadSeconds;
   ev_expiry[s]=news+expirySeconds;
   ev_token[s]="XV"+IntegerToString(s+1)+"_"+IntegerToString((int)news);
   ev_gv[s]=BuildSlotGlobalName(s);
   ev_state[s]=STATE_WAITING;
   ev_heartbeat[s]=false;
   ev_missed[s]=false;
   ev_block[s]="";
   ev_notified[s]="";
   ev_hist[s]=false;
   ev_ticketBuy[s]=-1;
   ev_ticketSell[s]=-1;
   ev_lastAlertTicket[s]=-1;
}

string BuildSlotGlobalName(int s)
{
   string name="XVNS_"+IntegerToString(AccountNumber())+"_"+
               IntegerToString(ev_magic[s])+"_"+
               IntegerToString((int)ev_news[s]);

   if(StringLen(name)>63) name=StringSubstr(name,0,63);
   return(name);
}

// Two straddles armed at once is legitimate but doubles exposure, so it is
// called out at init rather than silently allowed.
void WarnOnOverlappingWindows()
{
   for(int a=0;a<g_eventCount;a++)
      for(int b=a+1;b<g_eventCount;b++)
         if(ev_place[a]<=ev_expiry[b] && ev_place[b]<=ev_expiry[a])
            Print("Schedule WARNING: event ",a+1," and event ",b+1,
                  " overlap - both can be armed at the same time.");
}

// A slot's magic number is its index, so reordering ExtraEventTimesGMT while
// orders are live hands those orders to a different event. The comment token
// still records which instance placed them, which makes the swap detectable.
void WarnOnAdoptedOrders()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()) continue;

      int s=SlotOfMagic(OrderMagicNumber());
      if(s<0) continue;

      string comment=OrderComment();
      if(StringFind(comment,"XV",0)!=0) continue;          // broker rewrote it
      if(StringFind(comment,ev_token[s],0)==0) continue;   // belongs to this instance

      Print("Schedule WARNING: order ",OrderTicket()," (comment ",comment,
            ") now belongs to event ",s+1," at ",
            TimeToString(ev_news[s],TIME_DATE|TIME_MINUTES),
            " GMT because they share magic ",ev_magic[s],
            ". Avoid reordering ExtraEventTimesGMT while orders are live.");
   }
}

void DescribeSchedule()
{
   Print("XVISION News Straddle V10: ",g_eventCount," event(s) scheduled. ",
         "Magic numbers ",MagicNumber," to ",MagicNumber+g_eventCount-1," are reserved.");

   for(int s=0;s<g_eventCount;s++)
      Print("  Event ",s+1,": ",ev_label[s],
            " | news GMT ",TimeToString(ev_news[s],TIME_DATE|TIME_MINUTES),
            " | arm ",TimeToString(ev_place[s],TIME_DATE|TIME_MINUTES),
            " | expire ",TimeToString(ev_expiry[s],TIME_DATE|TIME_MINUTES),
            " | magic ",ev_magic[s],
            (ev_daily[s]?" | repeats daily":""),
            " | state ",SlotStateText(s));

   if(ExtraEventTimesGMT=="")
      Print("  Tip: to run several events in one day, fill ExtraEventTimesGMT, ",
            "for example \"12:30=US CPI, 14:00=FOMC\".");
}

// ============================================================================
//  BROKER / GMT OFFSET
// ============================================================================
void LoadBrokerOffset()
{
   g_offsetGV="XVNS_OFF_"+IntegerToString(AccountNumber());

   if(GlobalVariableCheck(g_offsetGV))
   {
      g_brokerOffset=(int)GlobalVariableGet(g_offsetGV);
      return;
   }

   // Nothing cached yet: measure now and store it, so the very first restart
   // already has a value to fall back on when the feed is quiet.
   g_brokerOffset=RoundOffset((int)(TimeCurrent()-TimeGMT()));
   GlobalVariableSet(g_offsetGV,(double)g_brokerOffset);
}

void RefreshBrokerOffset()
{
   int measured=RoundOffset((int)(TimeCurrent()-TimeGMT()));
   if(measured==g_brokerOffset) return;

   g_brokerOffset=measured;
   GlobalVariableSet(g_offsetGV,(double)measured);
}

// Broker offsets are whole or half hours; rounding to the nearest quarter
// hour removes tick jitter without hiding a genuine DST change.
int RoundOffset(int seconds)
{
   int quarter=900;
   int sign=(seconds<0)?-1:1;
   int magnitude=MathAbs(seconds);
   int rounded=((magnitude+quarter/2)/quarter)*quarter;
   return(sign*rounded);
}

datetime BrokerToGMT(datetime brokerTime)
{
   return(brokerTime-g_brokerOffset);
}

// ============================================================================
//  ORDER AND HISTORY SCANNING
//
//  Both run as a single pass and fan the results out into the per-slot arrays,
//  so cost is O(orders) per cycle rather than O(slots x orders).
// ============================================================================
void ScanOrders()
{
   datetime bestTime[MAX_EVENTS];

   for(int s=0;s<g_eventCount;s++)
   {
      ev_active[s]=0;
      ev_pending[s]=0;
      ev_survivor[s]=-1;
      ev_buyPx[s]=0.0;
      ev_sellPx[s]=0.0;
      bestTime[s]=0;
   }

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()) continue;

      int slot=SlotOfMagic(OrderMagicNumber());
      if(slot<0) continue;

      int type=OrderType();

      if(type==OP_BUY || type==OP_SELL)
      {
         ev_active[slot]++;

         int ticket=OrderTicket();
         datetime opened=OrderOpenTime();

         if(ev_survivor[slot]<0 || opened<bestTime[slot] ||
            (opened==bestTime[slot] && ticket<ev_survivor[slot]))
         {
            ev_survivor[slot]=ticket;
            bestTime[slot]=opened;
         }
      }
      else if(type==OP_BUYSTOP)
      {
         ev_pending[slot]++;
         ev_buyPx[slot]=OrderOpenPrice();
      }
      else if(type==OP_SELLSTOP)
      {
         ev_pending[slot]++;
         ev_sellPx[slot]=OrderOpenPrice();
      }
   }
}

// History is the expensive scan and only changes when a trade closes, so it
// is throttled to once a second unless a caller forces it.
void ScanHistory(bool force)
{
   if(!force && g_histScanned && (GetTickCount()-g_lastHistScan)<1000)
      return;

   g_lastHistScan=GetTickCount();
   g_histScanned=true;

   for(int s=0;s<g_eventCount;s++)
      ev_hist[s]=false;

   for(int i=OrdersHistoryTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderSymbol()!=Symbol()) continue;

      int slot=SlotOfMagic(OrderMagicNumber());
      if(slot<0) continue;
      if(ev_hist[slot]) continue;

      int type=OrderType();
      if(type!=OP_BUY && type!=OP_SELL) continue;

      if(HistoryOrderBelongsToCurrentInstance(slot))
         ev_hist[slot]=true;
   }
}

// A daily slot reuses its magic number every day, so a closed trade only
// counts as "this instance completed" when it also belongs to the current
// window. The ticket registry and comment token are checked first because
// they are exact; the time comparison is the fallback after a restart.
bool HistoryOrderBelongsToCurrentInstance(int s)
{
   int ticket=OrderTicket();
   if(ticket==ev_ticketBuy[s] || ticket==ev_ticketSell[s])
      return(true);

   string comment=OrderComment();
   if(StringFind(comment,ev_token[s],0)>=0)
      return(true);

   // A comment carrying a different instance's token is positively excluded.
   if(StringFind(comment,"XV"+IntegerToString(s+1)+"_",0)>=0)
      return(false);

   // Two hours of slack: the cached broker offset can be an hour stale across
   // a DST change, and consecutive instances are at least a day apart anyway.
   datetime openedGMT=BrokerToGMT(OrderOpenTime());
   return(openedGMT>=ev_place[s]-7200);
}

int SlotOfMagic(int magic)
{
   int index=magic-MagicNumber;
   if(index<0 || index>=g_eventCount) return(-1);
   return(index);
}

// ============================================================================
//  ENGINE
// ============================================================================
void RunEngine()
{
   if(g_engineBusy)
      return;

   g_engineBusy=true;

   if(!g_scheduleOK)
   {
      g_lastAction="SCHEDULE ERROR";
      g_engineBusy=false;
      return;
   }

   if(EnforceGoldSymbol && !IsGoldSymbol())
   {
      g_lastAction="ATTACH TO GOLD/XAU";
      g_engineBusy=false;
      return;
   }

   ScanOrders();
   ScanHistory(false);
   SyncAllSlotStates();

   for(int s=0;s<g_eventCount;s++)
      ManageSlotTriggers(s);

   // Trailing and break-even run across every slot, so a position left open
   // by an earlier event keeps being managed while a later event arms.
   ManageActiveTradeExits();

   datetime nowGMT=TimeGMT();

   for(int e=0;e<g_eventCount;e++)
      if(DeletePendingOrdersAtExpiry && nowGMT>=ev_expiry[e] && ev_pending[e]>0)
         ExpireSlotPendings(e);

   ScanOrders();
   SyncAllSlotStates();

   for(int p=0;p<g_eventCount;p++)
      ServiceSlotSchedule(p,nowGMT);

   RollDailySlots(nowGMT);

   UpdateFocusSlot(nowGMT);

   g_engineBusy=false;
}

void ServiceSlotSchedule(int s,datetime nowGMT)
{
   // Heartbeat 60s before arming, so a dead terminal is discovered in time.
   if(!ev_heartbeat[s] && ev_state[s]==STATE_WAITING &&
      nowGMT>=ev_place[s]-60 && nowGMT<ev_place[s])
   {
      ev_heartbeat[s]=true;
      Notify("XVISION V10 alive | arming in <=60s | "+SlotName(s)+
             " | spread "+DoubleToString(Ask-Bid,Digits));
   }

   if(CanPlaceNow(s,nowGMT))
   {
      if(!PlaceStraddle(s))
         ev_block[s]=g_lastAction;      // surface placement failures too
   }

   // One-shot alert per distinct blocking reason while the window is live.
   if(ev_block[s]!="" && ev_block[s]!=ev_notified[s] &&
      nowGMT>=ev_place[s] && nowGMT<ev_expiry[s] && ev_state[s]==STATE_WAITING)
   {
      ev_notified[s]=ev_block[s];
      Notify("XVISION V10 ARM BLOCKED | "+SlotName(s)+" | "+ev_block[s]);
   }

   // Loud alarm if the news moment arrives with nothing armed.
   if(!ev_missed[s] && ev_state[s]==STATE_WAITING && nowGMT>=ev_news[s])
   {
      ev_missed[s]=true;
      Notify("XVISION V10 WINDOW MISSED | "+SlotName(s)+
             " | last block: "+(ev_block[s]==""?"none recorded":ev_block[s]));
   }
}

bool CanPlaceNow(int s,datetime nowGMT)
{
   ev_block[s]="";

   if(ev_active[s]>0 || ev_pending[s]>0)
   { ev_block[s]="event orders already exist"; return(false); }

   if(ev_state[s]!=STATE_WAITING)
   { ev_block[s]="state="+SlotStateText(s)+" vetoes arming"; return(false); }

   if(GlobalVariableCheck(ev_gv[s]) &&
      GlobalVariableGet(ev_gv[s])>=STATE_PENDING)
   { ev_block[s]="stored terminal state vetoes arming"; return(false); }

   if(!IsTradeAllowed())
   { ev_block[s]="autotrading disabled in terminal"; return(false); }

   if(nowGMT<ev_place[s])
   { ev_block[s]="before placement time"; return(false); }

   if(nowGMT<ev_news[s])
      return(true);

   if(!AllowPlacementAfterScheduledTime)
   { ev_block[s]="window passed; late placement disabled"; return(false); }

   if(nowGMT<=ev_news[s]+MaximumLatePlacementSeconds)
      return(true);

   ev_block[s]="beyond maximum late-placement seconds";
   return(false);
}

bool PlaceStraddle(int s)
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
      buyTicket=PlaceSide(s,OP_BUYSTOP,lots);
      if(buyTicket<0 && RequireBothPendingOrders)
      {
         g_lastAction="BUY STOP PLACEMENT FAILED";
         return(false);
      }
   }

   if(EnableSellStop)
   {
      sellTicket=PlaceSide(s,OP_SELLSTOP,lots);
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

   ev_ticketBuy[s]=buyTicket;
   ev_ticketSell[s]=sellTicket;

   SetSlotState(s,STATE_PENDING);
   g_lastAction="STRADDLE ARMED: "+SlotClock(s);

   Notify("XVISION V10 armed | "+SlotName(s)+
          " | News GMT "+TimeToString(ev_news[s],TIME_DATE|TIME_MINUTES)+
          " | Buy ticket "+IntegerToString(buyTicket)+
          " | Sell ticket "+IntegerToString(sellTicket));

   return(true);
}

// Entry, SL and TP are recomputed on every attempt, because a requote means
// the price the geometry was built around has already moved.
int PlaceSide(int s,int orderType,double lots)
{
   string side=(orderType==OP_BUYSTOP)?"BUY":"SELL";

   for(int attempt=1;attempt<=MaximumOrderAttempts;attempt++)
   {
      if(IsStopped()) break;

      if(!WaitForTradeContext())
      {
         g_lastAction="TRADE CONTEXT BUSY";
         return(-1);
      }

      RefreshRates();

      double entry,stopLoss,takeProfit;

      if(orderType==OP_BUYSTOP)
      {
         entry=NormalizeDouble(Ask+g_workBuyDist,Digits);
         stopLoss=NormalizeDouble(entry-g_workBuySL,Digits);
         takeProfit=InitialTakeProfit(OP_BUY,entry);
      }
      else
      {
         entry=NormalizeDouble(Bid-g_workSellDist,Digits);
         stopLoss=NormalizeDouble(entry+g_workSellSL,Digits);
         takeProfit=InitialTakeProfit(OP_SELL,entry);
      }

      if(!PendingGeometryIsValid(orderType,entry,stopLoss,takeProfit))
      {
         g_lastAction=side+" LEVELS VIOLATE BROKER MINIMUM";
         Sleep(OrderRetryDelayMilliseconds);
         continue;
      }

      string comment=ev_token[s]+((orderType==OP_BUYSTOP)?"_B":"_S");
      color  arrow  =((orderType==OP_BUYSTOP)?BuyColor:SellColor);

      ResetLastError();
      int ticket=OrderSend(Symbol(),orderType,lots,entry,SlippagePoints,
                           stopLoss,takeProfit,comment,ev_magic[s],0,arrow);

      if(ticket>=0)
         return(ticket);

      int error=GetLastError();
      ResetLastError();

      // ECN fallback: place bare, then attach protection immediately.
      if(error==ERR_INVALID_STOPS)
      {
         ticket=PlaceBareThenProtect(s,orderType,lots,entry,stopLoss,takeProfit,comment,arrow);
         if(ticket>=0) return(ticket);
         Sleep(OrderRetryDelayMilliseconds);
         continue;
      }

      Print("OrderSend failed. Event ",s+1," type ",orderType,
            " attempt ",attempt,"/",MaximumOrderAttempts," error ",error);

      if(!IsRetryableTradeError(error))
      {
         g_lastAction="ORDER REJECTED: ERROR "+IntegerToString(error);
         return(-1);
      }

      Sleep(OrderRetryDelayMilliseconds);
   }

   g_lastAction=side+" STOP EXHAUSTED RETRIES";
   return(-1);
}

int PlaceBareThenProtect(int s,int orderType,double lots,double entry,
                         double stopLoss,double takeProfit,
                         string comment,color arrow)
{
   ResetLastError();

   int ticket=OrderSend(Symbol(),orderType,lots,entry,SlippagePoints,
                        0,0,comment,ev_magic[s],0,arrow);

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

bool IsRetryableTradeError(int error)
{
   return(error==ERR_SERVER_BUSY          ||   //   4  server busy
          error==ERR_NO_CONNECTION        ||   //   6  no connection
          error==ERR_TOO_FREQUENT_REQUESTS||   //   8  too frequent requests
          error==ERR_TRADE_TIMEOUT        ||   // 128  trade timeout
          error==ERR_INVALID_PRICE        ||   // 129  invalid price
          error==ERR_PRICE_CHANGED        ||   // 135  price changed
          error==ERR_OFF_QUOTES           ||   // 136  off quotes
          error==ERR_BROKER_BUSY          ||   // 137  broker busy
          error==ERR_REQUOTE              ||   // 138  requote
          error==ERR_TOO_MANY_REQUESTS    ||   // 141  too many requests
          error==ERR_TRADE_CONTEXT_BUSY);      // 146  trade context busy
}

bool WaitForTradeContext()
{
   for(int i=0;i<25;i++)
   {
      if(!IsTradeContextBusy()) return(true);
      Sleep(100);
   }
   return(!IsTradeContextBusy());
}

bool PendingGeometryIsValid(int orderType,double entryPrice,double stopLoss,double takeProfit)
{
   double stopDistance=MathMax(MarketInfo(Symbol(),MODE_STOPLEVEL),
                               MarketInfo(Symbol(),MODE_FREEZELEVEL))*Point;
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

// ============================================================================
//  TRIGGER HANDLING
// ============================================================================
void ManageSlotTriggers(int s)
{
   if(ev_active[s]<=0)
      return;

   int survivorTicket=ev_survivor[s];
   SetSlotState(s,STATE_ACTIVE);

   if(CloseSecondTriggeredTrade && ev_active[s]>1 && survivorTicket>0)
      CloseSlotActiveExcept(s,survivorTicket);

   if(!OrderSelect(survivorTicket,SELECT_BY_TICKET))
      return;

   int    survivorType=OrderType();
   double survivorFill=OrderOpenPrice();   // cached: the calls below re-select

   if(CancelOppositePendingOnTrigger)
      CancelSlotPendingOppositeTo(s,survivorType);

   if(ReanchorTPAndSLToActualFill)
      EnsureInitialProtection(survivorTicket);

   if(ev_lastAlertTicket[s]!=survivorTicket)
   {
      ev_lastAlertTicket[s]=survivorTicket;
      string side=(survivorType==OP_BUY)?"BUY":"SELL";
      g_lastAction=side+" TRIGGERED "+SlotClock(s);

      Notify("XVISION V10 "+side+" triggered | "+SlotName(s)+
             " | Ticket "+IntegerToString(survivorTicket)+
             " | Fill "+DoubleToString(survivorFill,Digits));
   }
}

void CloseSlotActiveExcept(int s,int survivorTicket)
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()) continue;
      if(OrderMagicNumber()!=ev_magic[s]) continue;

      int type=OrderType();
      if(type!=OP_BUY && type!=OP_SELL) continue;
      if(OrderTicket()==survivorTicket) continue;

      int    ticket=OrderTicket();
      double lots=OrderLots();

      RefreshRates();
      double closePrice=NormalizeDouble((type==OP_BUY)?Bid:Ask,Digits);

      if(OrderClose(ticket,lots,closePrice,SlippagePoints,WarningColor))
      {
         g_lastAction="SECOND TRIGGER CLOSED";
         Print("Closed second triggered trade ",ticket," (event ",s+1,")");
      }
      else
      {
         Print("Failed to close second triggered trade ",ticket,
               ". Error ",GetLastError());
         ResetLastError();
      }
   }
}

void CancelSlotPendingOppositeTo(int s,int activeType)
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()) continue;
      if(OrderMagicNumber()!=ev_magic[s]) continue;

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

// ============================================================================
//  EXIT MANAGEMENT
// ============================================================================
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

// Runs over every slot's positions, so re-arming a later event never orphans
// an earlier event's open trade - the V9 failure this release exists to fix.
void ManageActiveTradeExits()
{
   if(!UsesTrailingStop() && g_workBE<=0.0)
      return;

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES))
         continue;

      if(OrderSymbol()!=Symbol())
         continue;

      if(SlotOfMagic(OrderMagicNumber())<0)
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

      if(errorCode!=ERR_NO_RESULT)
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

// ============================================================================
//  EXPIRY AND DAILY ROLLOVER
// ============================================================================
void ExpireSlotPendings(int s)
{
   int deleted=0;

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()) continue;
      if(OrderMagicNumber()!=ev_magic[s]) continue;
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

   if(deleted<=0)
      return;

   ScanOrders();

   if(ev_active[s]>0)
   {
      SetSlotState(s,STATE_ACTIVE);
      return;
   }

   if(ev_pending[s]==0 && ev_state[s]!=STATE_COMPLETE)
   {
      SetSlotState(s,STATE_EXPIRED);
      g_lastAction="UNTRIGGERED ORDERS EXPIRED "+SlotClock(s);
      Notify("XVISION V10 expired without a trigger | "+SlotName(s));
   }
}

// A daily slot advances to its next occurrence once its window has closed and
// it holds nothing live. Its state global is removed at the same time, which
// is what lets the same clock time re-arm tomorrow without ForceResetEventState.
void RollDailySlots(datetime nowGMT)
{
   if(!RepeatEventsDaily)
      return;

   for(int s=0;s<g_eventCount;s++)
   {
      if(!ev_daily[s]) continue;
      if(nowGMT<=ev_expiry[s]+60) continue;
      if(ev_active[s]>0 || ev_pending[s]>0) continue;

      string previousState=SlotStateText(s);

      if(GlobalVariableCheck(ev_gv[s]))
         GlobalVariableDel(ev_gv[s]);

      datetime next=ev_news[s];
      for(int guard=0;guard<14;guard++)
      {
         next+=86400;
         if(next<=nowGMT) continue;
         if(SkipWeekendEvents && IsWeekendGMT(next)) continue;
         break;
      }

      ApplySlotTimes(s,next);

      Print("XVISION V10: event ",s+1," (",ev_label[s],") rolled from ",
            previousState," to ",TimeToString(ev_news[s],TIME_DATE|TIME_MINUTES)," GMT.");
   }
}

// ============================================================================
//  STATE
// ============================================================================
void SyncAllSlotStates()
{
   for(int s=0;s<g_eventCount;s++)
      SyncSlotState(s);
}

void SyncSlotState(int s)
{
   if(ev_active[s]>0)
   {
      SetSlotState(s,STATE_ACTIVE);
      return;
   }

   if(ev_pending[s]>0)
   {
      SetSlotState(s,STATE_PENDING);
      return;
   }

   if(ev_hist[s])
   {
      SetSlotState(s,STATE_COMPLETE);
      return;
   }

   if(GlobalVariableCheck(ev_gv[s]))
   {
      int stored=(int)GlobalVariableGet(ev_gv[s]);
      datetime nowGMT=TimeGMT();

      // A stored non-waiting state with no live orders and no history, for a
      // window that has not even opened, is residue from an earlier attach or
      // test and must not veto a fresh event. CANCELLED is a deliberate user
      // decision, so it survives this cleaner.
      if(stored>=STATE_PENDING && stored!=STATE_CANCELLED && nowGMT<ev_place[s])
      {
         GlobalVariableDel(ev_gv[s]);
         ev_state[s]=STATE_WAITING;
         g_lastAction="STALE STATE CLEARED";
         return;
      }

      // Nothing live and the window is over: PENDING means the orders went
      // away without the EA seeing it, ACTIVE means the close is not visible
      // in the history tab. Either way the instance is finished.
      if(nowGMT>=ev_expiry[s])
      {
         if(stored==STATE_PENDING) stored=STATE_EXPIRED;
         else if(stored==STATE_ACTIVE) stored=STATE_COMPLETE;
      }

      ev_state[s]=stored;
      return;
   }

   ev_state[s]=STATE_WAITING;
}

// Only writes when the value actually changes. V9 wrote a global variable on
// every tick, several times per tick.
void SetSlotState(int s,int stateValue)
{
   if(ev_state[s]==stateValue && GlobalVariableCheck(ev_gv[s]))
      return;

   ev_state[s]=stateValue;
   GlobalVariableSet(ev_gv[s],(double)stateValue);
}

void ClearAllStoredState()
{
   int cleared=0;

   for(int s=0;s<g_eventCount;s++)
      if(GlobalVariableCheck(ev_gv[s]))
      {
         GlobalVariableDel(ev_gv[s]);
         ev_state[s]=STATE_WAITING;
         cleared++;
      }

   Print("XVISION V10: stored event state force-cleared for ",cleared," event(s).");
}

// Removes state globals from events that finished more than a week ago, so a
// terminal used daily does not accumulate them indefinitely.
void PurgeStaleStateGlobals()
{
   string mine="XVNS_"+IntegerToString(AccountNumber())+"_";
   datetime cutoff=TimeGMT()-7*86400;
   int removed=0;

   for(int i=GlobalVariablesTotal()-1;i>=0;i--)
   {
      string name=GlobalVariableName(i);
      if(StringFind(name,mine,0)!=0) continue;

      bool current=false;
      for(int s=0;s<g_eventCount;s++)
         if(name==ev_gv[s]) { current=true; break; }
      if(current) continue;

      int lastUnderscore=StringLen(name)-1;
      while(lastUnderscore>=0 && StringGetCharacter(name,lastUnderscore)!='_')
         lastUnderscore--;
      if(lastUnderscore<0) continue;

      string stamp=StringSubstr(name,lastUnderscore+1);
      if(!IsAllDigits(stamp)) continue;

      if((datetime)StringToInteger(stamp)<cutoff)
      {
         GlobalVariableDel(name);
         removed++;
      }
   }

   if(removed>0)
      Print("XVISION V10: purged ",removed," expired event-state global(s).");
}

// ============================================================================
//  HELPERS
// ============================================================================
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
   if(maxLot<=0.0) maxLot=requestedLots;

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

datetime DayStartGMT(datetime moment)
{
   return((datetime)((long)moment/86400*86400));
}

bool IsWeekendGMT(datetime moment)
{
   MqlDateTime parts;
   TimeToStruct(moment,parts);
   return(parts.day_of_week==0 || parts.day_of_week==6);
}

string SlotClock(int s)
{
   return(TimeToString(ev_news[s],TIME_MINUTES));
}

string SlotName(int s)
{
   return(ev_label[s]+" "+SlotClock(s)+"Z");
}

// Alerts are modal, and a schedule with several events can produce the same
// message repeatedly. Printing is always unconditional; the popup is not.
void Notify(string message)
{
   Print(message);

   bool duplicate=(message==g_lastAlertMessage &&
                   TimeGMT()-g_lastAlertTime<30);

   g_lastAlertMessage=message;
   g_lastAlertTime=TimeGMT();

   if(duplicate) return;

   if(EnablePopupAlerts) Alert(message);
   if(EnablePushNotifications) SendNotification(message);
}

// ============================================================================
//  PANEL
// ============================================================================

// The focus slot drives STATUS, COUNTDOWN, the order rows and the CANCEL
// button: a live trade first, then an armed setup, then the next event due.
void UpdateFocusSlot(datetime nowGMT)
{
   int best=-1;

   for(int s=0;s<g_eventCount;s++)
      if(ev_state[s]==STATE_ACTIVE)
      { best=s; break; }

   if(best<0)
      for(int p=0;p<g_eventCount;p++)
         if(ev_state[p]==STATE_PENDING)
         { best=p; break; }

   if(best<0)
   {
      datetime soonest=0;
      for(int u=0;u<g_eventCount;u++)
      {
         if(ev_expiry[u]<nowGMT) continue;
         if(best<0 || ev_news[u]<soonest)
         {
            best=u;
            soonest=ev_news[u];
         }
      }
   }

   if(best<0)
   {
      datetime latest=0;
      for(int d=0;d<g_eventCount;d++)
         if(best<0 || ev_news[d]>latest)
         {
            best=d;
            latest=ev_news[d];
         }
   }

   g_focusSlot=(best<0)?0:best;
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

   int f=g_focusSlot;
   if(f<0 || f>=g_eventCount) f=0;

   int rowH  = PanelFontSize+11;    // body line pitch
   int secH  = PanelFontSize+15;    // section-header pitch
   int headH = PanelFontSize+20;    // title band height

   // Backgrounds are created first so every label renders on top of them.
   // The outer box is sized to a rough height now and trimmed to the exact
   // height at the end, once the row cursor has run to the bottom.
   PanelRect(PREFIX+"PANEL_BG",PanelTopMargin,900,PanelBackground);
   PanelRect(PREFIX+"HEADER_BG",PanelTopMargin,headH,GMTHeaderBackground);
   DrawLabel(PREFIX+"TITLE",PanelTopMargin+4,PanelFontSize+1,
             "XVISION  -  GOLD NEWS STRADDLE",GMTHeaderText,false,true);

   int y=PanelTopMargin+headH+8;

   if(!g_scheduleOK)
   {
      DrawLabel(PREFIX+"CAP_ST",y,PanelFontSize,"STATUS",PanelMutedText,false,false);
      DrawLabel(PREFIX+"VAL_ST",y-1,PanelFontSize+3,"SCHEDULE ERROR",clrRed,true,true);
      y+=rowH+6;
      PanelRow(PREFIX+"ERR",y,"Reason",g_scheduleError,WarningColor); y+=rowH;

      g_panelHeight=(y+6)-PanelTopMargin;
      ObjectSetInteger(0,PREFIX+"PANEL_BG",OBJPROP_YSIZE,g_panelHeight);
      ChartRedraw();
      return;
   }

   // Primary status: STATE and COUNTDOWN, both in a larger font.
   DrawLabel(PREFIX+"CAP_ST",y,PanelFontSize,"STATUS",PanelMutedText,false,false);
   DrawLabel(PREFIX+"VAL_ST",y-1,PanelFontSize+3,FocusStateText(f),FocusStateColor(f),true,true);
   y+=rowH+6;
   DrawLabel(PREFIX+"CAP_CD",y,PanelFontSize,"COUNTDOWN",PanelMutedText,false,false);
   DrawLabel(PREFIX+"VAL_CD",y-1,PanelFontSize+2,CountdownText(f,nowGMT),PanelAccent,true,true);
   y+=rowH+6;

   PanelSection(PREFIX+"S_EVT",y,"SCHEDULE  (GMT)");  y+=secH;
   for(int s=0;s<g_eventCount;s++)
   {
      string caption=((s==f)?"> ":"   ")+
                     TimeToString(ev_news[s],TIME_DATE|TIME_MINUTES)+
                     (ev_daily[s]?" *":"");
      PanelRow(PREFIX+"EV"+IntegerToString(s),y,caption,
               ShortLabel(s)+"  "+SlotStateText(s),SlotStateColor(s));
      y+=rowH;
   }
   if(RepeatEventsDaily)
   {
      PanelRow(PREFIX+"RPT",y,"","* repeats daily",PanelMutedText);
      y+=rowH;
   }

   PanelSection(PREFIX+"S_ORD",y,"ORDERS  -  "+ShortLabel(f));  y+=secH;
   string buyText =(ev_buyPx[f]>0.0) ?DoubleToString(ev_buyPx[f],Digits) :"--";
   string sellText=(ev_sellPx[f]>0.0)?DoubleToString(ev_sellPx[f],Digits):"--";
   PanelRow(PREFIX+"BUY",  y,"Buy stop",  buyText,  BuyColor);  y+=rowH;
   PanelRow(PREFIX+"SELL", y,"Sell stop", sellText, SellColor); y+=rowH;
   double spread=Ask-Bid;
   bool spreadHigh=(MaximumSpreadMovement>0.0 && spread>MaximumSpreadMovement);
   PanelRow(PREFIX+"SPR",  y,"Spread",
            DoubleToString(spread,Digits)+(spreadHigh?"  HIGH":""),
            spreadHigh?WarningColor:PanelText); y+=rowH;
   PanelRow(PREFIX+"LIVE", y,"Live / pending",
            IntegerToString(TotalActiveTrades())+" / "+IntegerToString(TotalPendingOrders()),
            PanelText); y+=rowH;

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
            TimeToString(brokerNow,TIME_MINUTES|TIME_SECONDS)+"  ("+OffsetText(g_brokerOffset)+")",
            PanelMutedText); y+=rowH;
   PanelRow(PREFIX+"NOTE", y,"Note",
            (ev_block[f]==""?g_lastAction:g_lastAction+" | "+ev_block[f]),
            PanelMutedText); y+=rowH;

   g_panelHeight=(y+6)-PanelTopMargin;
   ObjectSetInteger(0,PREFIX+"PANEL_BG",OBJPROP_YSIZE,g_panelHeight);

   ChartRedraw();
}

int TotalActiveTrades()
{
   int total=0;
   for(int s=0;s<g_eventCount;s++) total+=ev_active[s];
   return(total);
}

int TotalPendingOrders()
{
   int total=0;
   for(int s=0;s<g_eventCount;s++) total+=ev_pending[s];
   return(total);
}

string ShortLabel(int s)
{
   string label=ev_label[s];
   if(StringLen(label)>14) label=StringSubstr(label,0,13)+".";
   return(label);
}

string BreakEvenText()
{
   if(!MoveToBreakEvenFirst)
      return("OFF");

   return(DoubleToString(BreakEvenActivationMovement,1)+
          " -> +"+DoubleToString(BreakEvenLockMovement,1));
}

string SlotStateText(int s)
{
   if(ev_state[s]==STATE_PENDING)   return("ARMED");
   if(ev_state[s]==STATE_ACTIVE)    return("TRADE ACTIVE");
   if(ev_state[s]==STATE_COMPLETE)  return("COMPLETE");
   if(ev_state[s]==STATE_EXPIRED)   return("EXPIRED");
   if(ev_state[s]==STATE_CANCELLED) return("CANCELLED");
   if(ev_state[s]==STATE_ERROR)     return("ERROR");

   datetime nowGMT=TimeGMT();
   if(nowGMT<ev_place[s])   return("WAITING");
   if(nowGMT<ev_news[s])    return("ARM WINDOW");
   if(nowGMT<=ev_expiry[s]) return("NEWS WINDOW");
   return("PAST");
}

string FocusStateText(int s)
{
   if(EnforceGoldSymbol && !IsGoldSymbol()) return("WRONG SYMBOL");
   return(SlotStateText(s));
}

color SlotStateColor(int s)
{
   if(ev_state[s]==STATE_PENDING)   return(clrLime);
   if(ev_state[s]==STATE_ACTIVE)    return(BuyColor);
   if(ev_state[s]==STATE_COMPLETE)  return(clrLimeGreen);
   if(ev_state[s]==STATE_EXPIRED)   return(WarningColor);
   if(ev_state[s]==STATE_CANCELLED) return(WarningColor);
   if(ev_state[s]==STATE_ERROR)     return(clrRed);
   return(PanelText);
}

color FocusStateColor(int s)
{
   if(EnforceGoldSymbol && !IsGoldSymbol()) return(clrRed);
   return(SlotStateColor(s));
}

string CountdownText(int s,datetime nowGMT)
{
   datetime target=ev_place[s];
   string prefix="TO ARM ";

   if(nowGMT>=ev_place[s] && nowGMT<ev_news[s])
   {
      target=ev_news[s];
      prefix="TO NEWS ";
   }
   else if(nowGMT>=ev_news[s] && nowGMT<ev_expiry[s])
   {
      target=ev_expiry[s];
      prefix="TO EXPIRY ";
   }
   else if(nowGMT>=ev_expiry[s])
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
//| The two live-action buttons sit directly beneath the status      |
//| panel. All configuration lives in the F7 Inputs tab; these two    |
//| exist because F7 cannot close a trade or cancel pendings.         |
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
   MakeButton(PREFIX+"BT_CLOSE", "CLOSE ALL NOW", PanelRightMargin,          btnY,halfW,btnH,clrFireBrick);
   MakeButton(PREFIX+"BT_CANCEL","CANCEL SETUP",  PanelRightMargin+halfW+8,  btnY,halfW,btnH,clrChocolate);

   UpdateActionButtons();
}

//+------------------------------------------------------------------+
//| CLOSE is live only when something is open; CANCEL is live only    |
//| while the focus slot is armed/waiting and nothing has triggered.  |
//| Inactive buttons are dimmed rather than hidden.                   |
//+------------------------------------------------------------------+
void UpdateActionButtons()
{
   int f=g_focusSlot;
   if(f<0 || f>=g_eventCount) f=0;

   bool tradeLive  = (TotalActiveTrades()>0);
   bool setupArmed = g_scheduleOK && (g_eventCount>0) && (ev_active[f]<=0) &&
                     (ev_state[f]==STATE_WAITING || ev_state[f]==STATE_PENDING);

   if(ObjectFind(0,PREFIX+"BT_CLOSE")>=0)
   {
      ObjectSetInteger(0,PREFIX+"BT_CLOSE",OBJPROP_BGCOLOR, tradeLive?clrFireBrick:C'70,45,45');
      ObjectSetInteger(0,PREFIX+"BT_CLOSE",OBJPROP_COLOR,   tradeLive?clrWhite:C'150,150,150');
   }
   if(ObjectFind(0,PREFIX+"BT_CANCEL")>=0)
   {
      // The label names the slot the click will cancel, because with several
      // events on the panel "CANCEL SETUP" alone would be ambiguous.
      ObjectSetString(0,PREFIX+"BT_CANCEL",OBJPROP_TEXT,
                      (g_scheduleOK && g_eventCount>0)?("CANCEL "+SlotClock(f)):"CANCEL SETUP");
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
      ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
      ObjectSetInteger(0,name,OBJPROP_YSIZE,hgt);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,PanelFontSize);
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
      ObjectSetString(0,name,OBJPROP_FONT,"Tahoma Bold");
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetString(0,name,OBJPROP_TEXT,text);
   }

   // The panel grows and shrinks with the schedule, so the buttons are
   // repositioned on every refresh rather than only at creation.
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
}

//+------------------------------------------------------------------+
//| Only the two live-action buttons are interactive. Everything else |
//| is configured through the F7 Inputs tab.                          |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id!=CHARTEVENT_OBJECT_CLICK) return;

   if(sparam==PREFIX+"BT_CLOSE")
   {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      if(TotalActiveTrades()<=0 && TotalPendingOrders()<=0)
         Notify("XVISION V10 | CLOSE ignored - nothing open.");
      else
         PanelCloseAllNow();
      return;
   }

   if(sparam==PREFIX+"BT_CANCEL")
   {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);

      int f=g_focusSlot;
      if(!g_scheduleOK || f<0 || f>=g_eventCount) return;

      if(ev_active[f]>0)
         Notify("XVISION V10 | CANCEL ignored - "+SlotName(f)+
                " already triggered. Use CLOSE ALL NOW.");
      else if(ev_pending[f]<=0 && ev_state[f]!=STATE_WAITING && ev_state[f]!=STATE_PENDING)
         Notify("XVISION V10 | CANCEL ignored - "+SlotName(f)+" is not armed.");
      else
         PanelCancelSlot(f);
      return;
   }
}

//+------------------------------------------------------------------+
//| PANEL ACTION: flatten everything this EA owns and disarm every    |
//| slot, so no later event in the schedule can re-arm behind it.     |
//+------------------------------------------------------------------+
void PanelCloseAllNow()
{
   int closed=0;

   for(int pass=0; pass<3; pass++)   // retry a few times against requotes
   {
      bool again=false;
      RefreshRates();

      for(int i=OrdersTotal()-1;i>=0;i--)
      {
         if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
         if(OrderSymbol()!=Symbol()) continue;
         if(SlotOfMagic(OrderMagicNumber())<0) continue;

         int type=OrderType();
         if(type==OP_BUY || type==OP_SELL)
         {
            double px=NormalizeDouble((type==OP_BUY)?Bid:Ask,Digits);
            if(OrderClose(OrderTicket(),OrderLots(),px,SlippagePoints,WarningColor))
               closed++;
            else { again=true; ResetLastError(); }
         }
      }

      if(!again) break;
      Sleep(300);
   }

   // sweep any still-resting pendings across every slot
   int deleted=0;
   for(int j=OrdersTotal()-1;j>=0;j--)
   {
      if(!OrderSelect(j,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()) continue;
      if(SlotOfMagic(OrderMagicNumber())<0) continue;
      if(OrderType()!=OP_BUYSTOP && OrderType()!=OP_SELLSTOP) continue;

      if(OrderDelete(OrderTicket(),WarningColor))
         deleted++;
      else
      {
         Print("CLOSE ALL: pending delete failed, ticket ",OrderTicket(),
               " error ",GetLastError());
         ResetLastError();
      }
   }

   // A slot that traded is COMPLETE; one that never armed is CANCELLED. Both
   // veto re-arming, which is the point of a panic button.
   for(int s=0;s<g_eventCount;s++)
      SetSlotState(s,(ev_active[s]>0 || ev_hist[s])?STATE_COMPLETE:STATE_CANCELLED);

   ScanOrders();
   g_lastAction="MANUAL CLOSE ALL (panel)";

   Notify("XVISION V10 | CLOSED BY PANEL | positions closed: "+
          IntegerToString(closed)+" | pendings deleted: "+IntegerToString(deleted)+
          " | all "+IntegerToString(g_eventCount)+" event(s) disarmed "+
          "(set ForceResetEventState=true in F7 to re-enable).");

   UpdatePanel(); UpdateActionButtons();
}

//+------------------------------------------------------------------+
//| PANEL ACTION: delete one slot's un-triggered pendings and disarm  |
//| it. Other slots in the schedule are left running.                 |
//+------------------------------------------------------------------+
void PanelCancelSlot(int s)
{
   int deleted=0;

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()) continue;
      if(OrderMagicNumber()!=ev_magic[s]) continue;
      if(OrderType()!=OP_BUYSTOP && OrderType()!=OP_SELLSTOP) continue;

      if(OrderDelete(OrderTicket(),WarningColor)) deleted++;
   }

   // CANCELLED (not EXPIRED): it survives the stale-state cleaner, so a
   // cancel issued before the arm window opens can never silently re-arm.
   // A daily slot still rolls to tomorrow - that is a new instance, not a
   // re-arm of the one that was cancelled.
   SetSlotState(s,STATE_CANCELLED);
   ScanOrders();
   g_lastAction="CANCELLED "+SlotClock(s)+" (panel)";

   Notify("XVISION V10 | SETUP CANCELLED | "+SlotName(s)+
          " | pendings deleted: "+IntegerToString(deleted)+
          " | this event will not re-arm"+
          ((ev_daily[s] && RepeatEventsDaily) ? " today." :
           " (set ForceResetEventState=true in F7 to re-enable)."));

   UpdatePanel(); UpdateActionButtons();
}
