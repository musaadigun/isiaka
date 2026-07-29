// Behavioural tests: the EA's own engine, run against the simulated terminal.
#include <cstdio>

extern datetime SIM_now;
extern int      SIM_brokerOffset;
extern bool     SIM_tradeAllowed;
extern double   SIM_stopLevel;
void   SIM_reset();
void   SIM_clearGlobals();
bool   SIM_trigger(int ticket);
int    SIM_countLive(int magic,int type);
int    SIM_findLive(int magic,int type);
double SIM_slOf(int ticket);
void   SIM_addHistory(int type,int magic,double price,const string& comment,datetime openTime);

static int g_fail = 0, g_pass = 0;

static void CHECK(bool ok, const char* what)
{
   if(ok){ g_pass++; return; }
   g_fail++;
   printf("  FAIL: %s\n", what);
}

static datetime utc(int Y,int M,int D,int h,int m)
{
   struct tm g{}; g.tm_year=Y-1900; g.tm_mon=M-1; g.tm_mday=D; g.tm_hour=h; g.tm_min=m;
   return (datetime)timegm(&g);
}

static int weekday(datetime t)
{
   MqlDateTime s; TimeToStruct(t,s); return s.day_of_week;
}

// Reset the terminal and the EA input block to a known baseline.
static void baseline()
{
   SIM_reset();
   SIM_clearGlobals();
   Bid=2400.00; Ask=2400.30;

   NewsDateTimeGMT            = 4070908800LL;   // the 2099 placeholder
   UsePrimaryNewsDateTime     = false;
   ExtraEventTimesGMT         = "";
   RepeatEventsDaily          = false;
   SkipWeekendEvents          = true;
   LotSize                    = 0.01;
   ExitMode                   = EXIT_TRAILING_ONLY;
   BuyStopDistanceMovement    = 8.0;
   SellStopDistanceMovement   = 8.0;
   BuyStopLossMovement        = 20.0;
   SellStopLossMovement       = 20.0;
   TrailingActivationMovement = 20.0;
   TrailingStopDistanceMovement = 10.0;
   TrailingStepMovement       = 2.0;
   MoveToBreakEvenFirst       = true;
   BreakEvenActivationMovement= 12.0;
   BreakEvenLockMovement      = 1.0;
   EventName                  = "News";
   PlaceMinutesBeforeNews     = 5;
   PlaceAdditionalSecondsBeforeNews = 0;
   CancelMinutesAfterNews     = 10;
   CancelAdditionalSecondsAfterNews = 0;
   EnableBuyStop              = true;
   EnableSellStop             = true;
   RequireBothPendingOrders   = true;
   MaximumSpreadMovement      = 2.0;
   MagicNumber                = 26071451;
   EnforceGoldSymbol          = true;
   DeletePendingOrdersAtExpiry= true;
   ForceResetEventState       = false;
   EnablePopupAlerts          = false;
   ShowGMTPanel               = true;
}

// ---------------------------------------------------------------------------
static void test_parse_two_events_one_day()
{
   printf("test: two events parsed for the same day\n");
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   ExtraEventTimesGMT = "12:30=US CPI, 14:00=FOMC";

   CHECK(OnInit()==INIT_SUCCEEDED, "OnInit succeeds");
   CHECK(g_eventCount==2, "two slots built");
   CHECK(ev_news[0]==utc(2026,7,29,12,30), "slot 0 news = 12:30");
   CHECK(ev_news[1]==utc(2026,7,29,14,0),  "slot 1 news = 14:00");
   CHECK(ev_place[0]==ev_news[0]-300,  "slot 0 arms 5 min early");
   CHECK(ev_expiry[0]==ev_news[0]+600, "slot 0 expires 10 min late");
   CHECK(ev_magic[0]==MagicNumber,     "slot 0 owns the base magic");
   CHECK(ev_magic[1]==MagicNumber+1,   "slot 1 owns base magic + 1");
   CHECK(ev_gv[0]!=ev_gv[1],           "slots keep separate state keys");
   CHECK(ev_label[0]=="US CPI" && ev_label[1]=="FOMC", "labels parsed");
   CHECK(ev_state[0]==STATE_WAITING && ev_state[1]==STATE_WAITING, "both waiting");
   OnDeinit(0);
}

// The V9 headline failure: run a second event later the same day.
static void test_second_event_same_day()
{
   printf("test: second event of the day still arms after the first completes\n");
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   ExtraEventTimesGMT = "12:30=US CPI, 14:00=FOMC";
   OnInit();

   // --- event 1 arms
   SIM_now = utc(2026,7,29,12,26);
   RunEngine();
   CHECK(ev_state[0]==STATE_PENDING, "event 1 armed");
   CHECK(SIM_countLive(MagicNumber,OP_BUYSTOP)==1, "event 1 buy stop placed");
   CHECK(SIM_countLive(MagicNumber,OP_SELLSTOP)==1, "event 1 sell stop placed");
   CHECK(ev_state[1]==STATE_WAITING, "event 2 untouched while event 1 arms");

   // --- event 1 triggers long
   int buyTicket = SIM_findLive(MagicNumber,OP_BUYSTOP);
   SIM_now = utc(2026,7,29,12,30);
   SIM_trigger(buyTicket);
   RunEngine();
   CHECK(ev_state[0]==STATE_ACTIVE, "event 1 active after trigger");
   CHECK(SIM_countLive(MagicNumber,OP_SELLSTOP)==0, "opposite pending cancelled");

   // --- event 1 closes out
   OrderClose(buyTicket,0.01,2410.0,50,clrNONE);
   RunEngine();
   CHECK(ev_state[0]==STATE_COMPLETE, "event 1 complete once closed");

   // --- event 2 must now arm on its own schedule
   SIM_now = utc(2026,7,29,13,56);
   RunEngine();
   CHECK(ev_state[1]==STATE_PENDING, "event 2 ARMS (V9 could not do this)");
   CHECK(SIM_countLive(MagicNumber+1,OP_BUYSTOP)==1, "event 2 buy stop placed");
   CHECK(SIM_countLive(MagicNumber+1,OP_SELLSTOP)==1, "event 2 sell stop placed");
   CHECK(ev_state[0]==STATE_COMPLETE, "event 1 stays complete");
   OnDeinit(0);
}

// The other half of the V9 failure: an open trade must keep being managed
// while a later event in the same session arms.
static void test_open_trade_survives_next_event()
{
   printf("test: an open trade keeps trailing while the next event arms\n");
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   ExtraEventTimesGMT = "12:30=US CPI, 14:00=FOMC";
   OnInit();

   SIM_now = utc(2026,7,29,12,26);
   RunEngine();
   int buyTicket = SIM_findLive(MagicNumber,OP_BUYSTOP);
   double entry = 0.0;
   if(OrderSelect(buyTicket,SELECT_BY_TICKET)) entry = OrderOpenPrice();

   SIM_now = utc(2026,7,29,12,30);
   SIM_trigger(buyTicket);
   RunEngine();
   CHECK(ev_state[0]==STATE_ACTIVE, "trade is live");

   // leave it open, walk price into profit, and arm the later event
   Bid = entry + 25.0; Ask = Bid + 0.30;
   SIM_now = utc(2026,7,29,13,56);
   RunEngine();

   CHECK(ev_state[1]==STATE_PENDING, "later event arms with a trade still open");
   CHECK(SIM_countLive(MagicNumber,OP_BUY)==1, "earlier trade still open");

   double sl = SIM_slOf(buyTicket);
   CHECK(sl > entry, "earlier trade's stop was advanced past entry");
   CHECK(MathAbs(sl-(Bid-TrailingStopDistanceMovement)) < 0.011,
         "stop trails at the configured distance");
   OnDeinit(0);
}

// ---------------------------------------------------------------------------
static void test_daily_rollover()
{
   printf("test: a daily event rolls to the next day and re-arms\n");
   baseline();
   SIM_now = utc(2026,7,29,8,0);          // Wednesday
   ExtraEventTimesGMT = "12:30=Daily CPI";
   RepeatEventsDaily = true;
   OnInit();
   CHECK(ev_news[0]==utc(2026,7,29,12,30), "first occurrence is today");

   // arm, expire without a trigger
   SIM_now = utc(2026,7,29,12,26);
   RunEngine();
   CHECK(ev_state[0]==STATE_PENDING, "armed");
   SIM_now = utc(2026,7,29,12,41);
   RunEngine();
   CHECK(ev_state[0]==STATE_EXPIRED, "expired without a trigger");
   CHECK(SIM_countLive(MagicNumber,OP_BUYSTOP)==0, "pendings deleted at expiry");

   // past the window it should roll to tomorrow, WAITING, with no stale veto
   SIM_now = utc(2026,7,29,12,45);
   RunEngine();
   CHECK(ev_news[0]==utc(2026,7,30,12,30), "rolled to the next day");
   CHECK(ev_state[0]==STATE_WAITING, "state reset to waiting");
   CHECK(!GlobalVariableCheck(ev_gv[0]), "no stored state vetoing tomorrow");

   // and it genuinely arms again the next day
   SIM_now = utc(2026,7,30,12,26);
   RunEngine();
   CHECK(ev_state[0]==STATE_PENDING, "re-armed the next day");
   CHECK(SIM_countLive(MagicNumber,OP_BUYSTOP)==1, "next day's orders placed");
   OnDeinit(0);
}

static void test_weekend_skip()
{
   printf("test: daily rollover skips the weekend\n");
   baseline();
   SIM_now = utc(2026,7,31,8,0);           // Friday
   CHECK(weekday(SIM_now)==5, "fixture date really is a Friday");
   ExtraEventTimesGMT = "12:30";
   RepeatEventsDaily = true;
   SkipWeekendEvents = true;
   OnInit();
   CHECK(ev_news[0]==utc(2026,7,31,12,30), "Friday occurrence");

   SIM_now = utc(2026,7,31,12,45);
   RunEngine();
   CHECK(weekday(ev_news[0])==1, "rolled to Monday, not Saturday");
   CHECK(ev_news[0]==utc(2026,8,3,12,30), "Monday 12:30");
   OnDeinit(0);
}

static void test_no_roll_while_position_open()
{
   printf("test: a daily event will not roll while its trade is still open\n");
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   ExtraEventTimesGMT = "12:30";
   RepeatEventsDaily = true;
   OnInit();

   SIM_now = utc(2026,7,29,12,26);
   RunEngine();
   SIM_trigger(SIM_findLive(MagicNumber,OP_BUYSTOP));
   SIM_now = utc(2026,7,29,13,30);          // well past expiry
   RunEngine();

   CHECK(ev_news[0]==utc(2026,7,29,12,30), "did not roll with a live position");
   CHECK(ev_state[0]==STATE_ACTIVE, "still reported as active");
   OnDeinit(0);
}

// Yesterday's closed trade shares the slot's magic number; it must not make
// today's instance look COMPLETE.
static void test_yesterday_history_does_not_block_today()
{
   printf("test: yesterday's closed trade does not block today's event\n");

   for(int variant=0; variant<2; variant++)
   {
      baseline();
      SIM_now = utc(2026,7,30,8,0);
      ExtraEventTimesGMT = "12:30";
      RepeatEventsDaily = true;

      // variant 0: broker preserved the comment. variant 1: broker wiped it.
      string comment = (variant==0)
                       ? ("XV1_"+IntegerToString((int)utc(2026,7,29,12,30))+"_B")
                       : "";
      SIM_addHistory(OP_BUY,MagicNumber,2400.0,comment,
                     utc(2026,7,29,12,31)+SIM_brokerOffset);

      OnInit();
      CHECK(ev_state[0]==STATE_WAITING,
            variant==0 ? "waiting despite yesterday's history (comment kept)"
                       : "waiting despite yesterday's history (comment wiped)");

      SIM_now = utc(2026,7,30,12,26);
      RunEngine();
      CHECK(ev_state[0]==STATE_PENDING,
            variant==0 ? "arms today (comment kept)" : "arms today (comment wiped)");
      OnDeinit(0);
   }
}

static void test_today_history_completes_slot()
{
   printf("test: this instance's closed trade does mark the slot complete\n");
   baseline();
   SIM_now = utc(2026,7,29,12,50);
   ExtraEventTimesGMT = "2026.07.29 12:30";       // absolute, so it stays today
   SIM_addHistory(OP_BUY,MagicNumber,2400.0,"",utc(2026,7,29,12,31)+SIM_brokerOffset);
   OnInit();
   CHECK(ev_news[0]==utc(2026,7,29,12,30), "absolute entry stays on its date");
   CHECK(ev_state[0]==STATE_COMPLETE, "slot recognised as complete");
   OnDeinit(0);
}

// An HH:MM entry has no date, so attaching after its window has closed means
// the next occurrence, not a dead event.
static void test_time_of_day_entry_rolls_forward_on_attach()
{
   printf("test: an HH:MM entry attached late targets the next occurrence\n");
   baseline();
   SIM_now = utc(2026,7,29,12,50);       // window 12:25-12:40 already gone
   ExtraEventTimesGMT = "12:30";
   OnInit();
   CHECK(ev_news[0]==utc(2026,7,30,12,30), "scheduled for tomorrow");
   CHECK(ev_state[0]==STATE_WAITING, "waiting, not expired");
   OnDeinit(0);

   // attached before the window, it stays on today
   baseline();
   SIM_now = utc(2026,7,29,9,0);
   ExtraEventTimesGMT = "12:30";
   OnInit();
   CHECK(ev_news[0]==utc(2026,7,29,12,30), "stays on today when still ahead");
   OnDeinit(0);
}

// ---------------------------------------------------------------------------
// Reordering the schedule mid-day makes a finished event's history land on a
// different slot's magic number. The comment token has to veto it.
static void test_reordered_schedule_does_not_inherit_history()
{
   printf("test: reordering the schedule mid-day does not block the later event\n");
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   ExtraEventTimesGMT = "12:30=CPI, 14:00=FOMC";
   OnInit();

   // run the 12:30 event to completion
   SIM_now = utc(2026,7,29,12,26);
   RunEngine();
   int buyTicket = SIM_findLive(MagicNumber,OP_BUYSTOP);
   SIM_now = utc(2026,7,29,12,30);
   SIM_trigger(buyTicket);
   RunEngine();
   OrderClose(buyTicket,0.01,2410.0,50,clrNONE);
   RunEngine();
   CHECK(ev_state[0]==STATE_COMPLETE, "12:30 event completed");
   OnDeinit(0);

   // the user now retypes the list with the events the other way round
   SIM_now = utc(2026,7,29,13,56);
   ExtraEventTimesGMT = "14:00=FOMC, 12:30=CPI";
   OnInit();
   CHECK(ev_news[0]==utc(2026,7,29,14,0), "slot 0 is now the 14:00 event");
   CHECK(ev_state[0]!=STATE_COMPLETE,
         "14:00 event did not inherit the 12:30 event's history");

   RunEngine();
   CHECK(ev_state[0]==STATE_PENDING, "14:00 event still arms after the reorder");
   OnDeinit(0);
}

static void test_schedule_validation()
{
   printf("test: schedule validation\n");
   struct { const char* text; bool ok; const char* what; } cases[] = {
      { "12:30",                 true,  "plain HH:MM" },
      { "12:30:30",              true,  "HH:MM:SS" },
      { "2026.08.03 12:30=NFP",  true,  "absolute date" },
      { "12:30, 14:00, 15:45",   true,  "three events" },
      { "25:00",                 false, "hour out of range rejected" },
      { "12:75",                 false, "minute out of range rejected" },
      { "abc",                   false, "non-numeric rejected" },
      { "=Label",                false, "label with no time rejected" },
      { "12.30",                 false, "dotted time rejected as a bad date" },
   };

   for(unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++)
   {
      baseline();
      SIM_now = utc(2026,7,29,8,0);
      ExtraEventTimesGMT = cases[i].text;
      bool ok = (OnInit()==INIT_SUCCEEDED);
      CHECK(ok==cases[i].ok, cases[i].what);
      OnDeinit(0);
   }

   // nothing scheduled at all
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   UsePrimaryNewsDateTime = true;      // left at the 2099 placeholder
   CHECK(OnInit()==INIT_PARAMETERS_INCORRECT, "empty schedule rejected");
   OnDeinit(0);

   // too many events
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   string many;
   for(int i=0;i<MAX_EVENTS+2;i++) many += (i?",":"") + string("0")+IntegerToString(i%10)+":15";
   ExtraEventTimesGMT = many;
   CHECK(OnInit()==INIT_PARAMETERS_INCORRECT, "over-long schedule rejected");
   OnDeinit(0);
}

static void test_primary_datetime_still_works()
{
   printf("test: the F7 date picker alone still works (V9 compatibility)\n");
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   UsePrimaryNewsDateTime = true;
   NewsDateTimeGMT = utc(2026,7,29,12,30);

   CHECK(OnInit()==INIT_SUCCEEDED, "OnInit succeeds");
   CHECK(g_eventCount==1, "single slot");
   CHECK(ev_magic[0]==MagicNumber, "uses the base magic, as V9 did");

   SIM_now = utc(2026,7,29,12,26);
   RunEngine();
   CHECK(ev_state[0]==STATE_PENDING, "arms");
   CHECK(SIM_countLive(MagicNumber,OP_BUYSTOP)==1, "buy stop placed");
   OnDeinit(0);
}

static void test_panel_cancel_is_per_event()
{
   printf("test: cancelling one event leaves the others running\n");
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   ExtraEventTimesGMT = "12:30=CPI, 14:00=FOMC";
   OnInit();

   SIM_now = utc(2026,7,29,12,26);
   RunEngine();
   CHECK(ev_state[0]==STATE_PENDING, "event 1 armed");

   PanelCancelSlot(0);
   CHECK(ev_state[0]==STATE_CANCELLED, "event 1 cancelled");
   CHECK(SIM_countLive(MagicNumber,OP_BUYSTOP)==0, "its pendings were deleted");

   SIM_now = utc(2026,7,29,13,56);
   RunEngine();
   CHECK(ev_state[1]==STATE_PENDING, "event 2 still arms after event 1 cancelled");
   CHECK(ev_state[0]==STATE_CANCELLED, "cancelled event does not come back");
   OnDeinit(0);
}

static void test_cancelled_survives_restart()
{
   printf("test: a cancelled event stays cancelled across a reload\n");
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   ExtraEventTimesGMT = "12:30=CPI";
   OnInit();
   PanelCancelSlot(0);
   OnDeinit(0);

   // reload with the same settings, still before the arm window
   OnInit();
   CHECK(ev_state[0]==STATE_CANCELLED, "still cancelled after reload");
   SIM_now = utc(2026,7,29,12,26);
   RunEngine();
   CHECK(SIM_countLive(MagicNumber,OP_BUYSTOP)==0, "does not re-arm");

   // ForceResetEventState is the documented way back
   OnDeinit(0);
   ForceResetEventState = true;
   SIM_now = utc(2026,7,29,8,0);
   OnInit();
   CHECK(ev_state[0]==STATE_WAITING, "force reset clears it");
   OnDeinit(0);
}

static void test_stale_state_cleared_for_future_window()
{
   printf("test: stale stored state does not veto a future window\n");
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   ExtraEventTimesGMT = "12:30=CPI";
   OnInit();
   GlobalVariableSet(ev_gv[0],(double)STATE_EXPIRED);   // residue from a test run
   RunEngine();
   CHECK(ev_state[0]==STATE_WAITING, "stale EXPIRED cleared before the window");

   SIM_now = utc(2026,7,29,12,26);
   RunEngine();
   CHECK(ev_state[0]==STATE_PENDING, "still arms");
   OnDeinit(0);
}

static void test_autotrading_off_blocks_and_recovers()
{
   printf("test: autotrading off blocks arming, and arming resumes when re-enabled\n");
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   ExtraEventTimesGMT = "12:30=CPI";
   OnInit();

   SIM_tradeAllowed = false;
   SIM_now = utc(2026,7,29,12,26);
   RunEngine();
   CHECK(ev_state[0]==STATE_WAITING, "did not arm");
   CHECK(ev_block[0]=="autotrading disabled in terminal", "reason reported");

   SIM_tradeAllowed = true;
   SIM_now = utc(2026,7,29,12,27);
   RunEngine();
   CHECK(ev_state[0]==STATE_PENDING, "arms once autotrading is back on");
   OnDeinit(0);
}

static void test_broker_offset_tracking()
{
   printf("test: broker/GMT offset is measured and cached\n");
   baseline();
   SIM_now = utc(2026,7,29,8,0);
   SIM_brokerOffset = 10800;              // GMT+3
   ExtraEventTimesGMT = "12:30";
   OnInit();
   OnTick();
   CHECK(g_brokerOffset==10800, "offset measured from a live tick");
   CHECK(GlobalVariableCheck("XVNS_OFF_555001"), "offset cached for restarts");
   SIM_brokerOffset = 7200;
   OnDeinit(0);
}

int main()
{
   test_parse_two_events_one_day();
   test_second_event_same_day();
   test_open_trade_survives_next_event();
   test_daily_rollover();
   test_weekend_skip();
   test_no_roll_while_position_open();
   test_yesterday_history_does_not_block_today();
   test_today_history_completes_slot();
   test_time_of_day_entry_rolls_forward_on_attach();
   test_reordered_schedule_does_not_inherit_history();
   test_schedule_validation();
   test_primary_datetime_still_works();
   test_panel_cancel_is_per_event();
   test_cancelled_survives_restart();
   test_stale_state_cleared_for_future_window();
   test_autotrading_off_blocks_and_recovers();
   test_broker_offset_tracking();

   printf("\n%d passed, %d failed\n", g_pass, g_fail);
   return g_fail ? 1 : 0;
}
