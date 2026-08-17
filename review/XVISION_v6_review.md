# Code review — XVISION_Gold_EMA50_Directional_EA_v6.mq4

1,657 lines, reviewed in full. Findings are ordered by severity. Nothing here was
compiled — there is no MetaEditor on Linux — so each finding is marked with how it
was established: **[read]** = certain from the source, **[log]** = needs a line
from your Experts log to confirm which branch you are hitting.

---

# Part 1 — the crash

**It is not a crash. The EA is being unloaded by its own `OnInit()`, and the
dashboard disappearing is what makes it look like one.**

## The mechanism

When you click OK in the properties dialog, MT4 runs `OnDeinit(REASON_PARAMETERS)`
then `OnInit()`. `OnDeinit` calls `DeleteDashboard()` (line 154), which removes
every panel object. `OnInit` then does this, first thing, before anything else:

```cpp
int OnInit()
  {
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);     // line 125-126
```

In MT4, returning `INIT_PARAMETERS_INCORRECT` **removes the expert from the
chart**. The panel is already gone, the smiley face goes, and the only trace is a
single `Print()` line in the Experts tab. From the outside that is
indistinguishable from a crash.

## Why ordinary edits trigger it

`ValidateInputs()` (lines 171-222) enforces constraints that are undocumented in
the input names, several of them *coupled* between inputs. Every one of these is a
value a reasonable person would type, and every one silently removes the EA:

| Input you change | Trips on | Line |
|---|---|---|
| `DashboardHeight` | anything **< 450** — shrinking the panel kills the EA | 218 |
| `DashboardWidth` | anything **< 360** | 218 |
| `DashboardFontSize` | anything **< 8** | 219 |
| `MaximumRangeVotesForContinuation` | **> 3** | 186 |
| `RangeLookbackBars` | dropping it **below** `RangeCrossingVoteMinimum` | 180-181 |
| `MinimumDirectionalEfficiency` | **> 1.0** — it reads like a percentage, so `25` kills it | 184 |
| `RetestMinimumCloseLocationPercent` | **< 50** or **> 100** | 197 |
| `RetestTrendClosesRequired` | **< 2** | 193 |
| `ProfitLockMoney` | **>=** `ProfitLockTriggerMoney`, once profit lock is on | 216 |
| `TrailingDistanceMoney` | **0**, once trailing is on | 212 |
| `MagicNumber` | **<= 0** | 173 |

The dashboard trio is the most likely one you hit, because resizing the panel is
the most natural thing to fiddle with and the constraint is completely arbitrary —
the panel's own labels are hardcoded down to y=431 (line 1653), so the author
picked 450 as a floor and rejected everything below it rather than clamping.

## Confirm it in ten seconds

Open the **Experts** tab (not Journal) and look at the last line when it
"crashes". You will see exactly one of these:

```
Validation: dashboard position, size, or font is invalid.
Validation: MaximumRangeVotesForContinuation must be from 0 to 3.
Validation: range lookback inputs are invalid.
Validation: EMA retest inputs are invalid.
Validation: profit lock must satisfy 0 <= lock < trigger.
```

That line names the branch. If instead you see **no** `Validation:` line and the
terminal froze rather than the EA vanishing, it is finding **C2** below.

## Why this was never caught

`PersistentStateEnabled()` (line 1403) returns `UsePersistentEpisodeState && !IsTesting()`.
The Strategy Tester therefore **never executes the state-restore path**, and the
tester never re-inits with changed parameters the way the live chart does. The
exact code path that runs when you edit an input is, by construction, the one path
the tester cannot exercise.

## The fix

Validation should **clamp and warn**, not reject. Cosmetic inputs must never be
able to unload a trading EA:

```cpp
// instead of rejecting:
int panelHeight = (int)MathMax(450, DashboardHeight);
int panelWidth  = (int)MathMax(360, DashboardWidth);
```

Reserve `INIT_PARAMETERS_INCORRECT` for values that make trading genuinely unsafe
(lot size, magic number). Everything else gets clamped with a `Print()` saying what
was adjusted.

---

# Part 2 — critical

### C1. Broker comment rewriting orphans every pending order **[read]**

`IsCurrentRetestOrder()` (line 442) identifies the EA's own orders by comment:

```cpp
return(OrderSymbol()==Symbol() && OrderMagicNumber()==MagicNumber &&
       StringFind(OrderComment(),"XVE6_RET")==0);
```

Brokers routinely rewrite order comments — appending `[sl]`/`[tp]`, or replacing
them wholesale on partial fills and on some bridge/ECN setups. When that happens
this returns `false` for the EA's *own* order, and every consumer breaks at once:
`HasActiveRetestPending()` says no pending exists, `ManageRetestOrders()` stops
cancelling it, and `RecoverRetestOrderState()` cannot find it after a restart. The
result is an orphaned live stop order that nothing will ever clean up, plus the EA
happily placing a second one.

The magic number is already checked and is not rewritable. The comment test adds
nothing but a failure mode — track the ticket in a global instead.

### C2. Full dashboard rebuild plus `ChartRedraw()` on every tick **[read]**

`OnTick()` (line 165) calls `UpdateDashboard()` unconditionally. That function
re-sets **every property of every object** each time — 13 `ObjectSetInteger` calls
for the background, then ~18 labels × 12 property calls each — and finishes with
`ChartRedraw()` (line 1655). That is roughly **230 chart-object calls plus a forced
full repaint, per tick**.

Gold ticks several times a second. This is thousands of GUI calls per second
competing with the terminal's UI thread — and it is at its worst precisely when you
have the properties dialog open, because the dialog and the redraw storm fight over
the same thread. If your symptom is the terminal freezing rather than the EA
vanishing, this is why.

Fix: only touch objects whose text actually changed, drop the per-property re-set
to creation time only, throttle to once or twice a second, and skip drawing
entirely under `IsTesting() && !IsVisualMode()`.

### C3. `EMAValue()` has no validity guard — phantom crossings **[read]**

```cpp
double EMAValue(const int shift)
  {
   return(iMA(Symbol(),SignalTimeframe,EMA_Period,0,MODE_EMA,PRICE_CLOSE,shift));
  }
```

When history is still syncing, `iMA` returns **0.0** and sets error 4066. Feed that
into `ClosedBarCross()` (line 930):

```cpp
if(close2<=ema2 && close1>ema1)
   direction=1;
```

With `ema1 == 0` and gold at 4300, `close1 > ema1` is trivially true — a phantom
BUY cross. The `iBars()` check at line 268 reduces the window but does not close
it: bar *count* can be sufficient while `iMA` is still returning zeros mid-sync,
which is exactly the state a chart is in right after a re-init.

Every `iATR` call in this file is guarded with `<= 0.0`. The EMA — the actual
signal — is not.

### C4. Server-side expiry silently disables the retest route on many brokers **[read]**

`RequireServerSidePendingExpiry` defaults to `true`, so `PlaceRetestPending()`
sends a non-zero `expiration` to `OrderSend` (line 672). A large number of brokers,
ECN accounts especially, reject pending expiry outright with **error 147
(ERR_TRADE_EXPIRATION_DENIED)**. `OrderSend` returns -1, the function returns
false, and `ProcessRetestState()` (line 825) sets `g_retestState = RETEST_USED`.

The headline feature of the EA is then dead for the entire trend leg, on every
leg, forever — and the only evidence is one log line. Error 147 needs an explicit
retry with `expiration = 0`, falling back to the bar-age cancel that
`ManageRetestOrders()` already implements.

---

# Part 3 — high

### H1. Stale diagnostics drive live decisions **[read]**

`UpdateCurrentDiagnostics()` (line 416) bails out early when ATR is unavailable:

```cpp
double atr=iATR(Symbol(),SignalTimeframe,ATR_Period,1);
if(atr<=0.0)
   return;                       // g_currentSlope etc. keep LAST BAR'S values
```

`g_currentSlope`, `g_currentEfficiency` and `g_currentRangeVotes` retain the
previous bar's values, and `RetestCandleQualifies()` and `ProcessRetestState()`
then gate real entries on them. A silent bail-out that leaves stale globals behind
is worse than no update — either reset them or set a validity flag the callers
check.

### H2. `MaximumEntryDeviationMovement = 0.50` blocks most entries **[read]**

```cpp
if(MaximumEntryDeviationMovement>0.0 &&
   MathAbs(entry-signalClose)>MaximumEntryDeviationMovement)
```

`signalClose` is the M30 **close**; `entry` is the live Ask/Bid at the moment the
new bar opens. Gold routinely moves more than $0.50 in the seconds around an M30
boundary. This default rejects a large share of qualified signals and logs it as a
skip, so the EA looks like it is "not taking signals" when it is actually working
as written. On gold this wants to be ATR-relative, not a fixed 50 cents.

### H3. `ExactLotSize()` rejects instead of rounding **[read]**

```cpp
if(MathAbs(executable-requested)>tolerance)
   return(false);
```

Any `FixedLotSize` not landing exactly on the broker's lot step kills the trade.
On a broker with `MINLOT = 0.1`, the default `0.01` means **the EA can never open
a single position** — it will run for weeks showing "REJECT" in one dashboard
field and nothing else. Rounding down to the nearest valid step (and refusing only
below minimum) is the standard behaviour.

### H4. Exposure detection and position management disagree **[read]**

`IsXVISIONExposureSelected()` (line 1269) matches magic numbers 50503001-50503006
**and** any comment starting `"XVE"`. But `ManageInputProtection()` (line 1183)
matches only `OrderMagicNumber() == MagicNumber`.

So a position left over from v1-v5 will **block** new entries via `HasEAExposure()`,
and will be counted in the dashboard P/L via `PositionSummary()` — but will never
get a trailing stop or profit lock. The EA blocks itself on positions it then
refuses to manage.

### H5. Retest state advances while the episode is locked **[read]**

`ProcessRetestState()` is called at line 280, *before* the `g_episodeLocked` check
at line 287. On a raw cross it arms a fresh trend leg (line 743-751) even though
the locked branch will return without evaluating that cross. Once the lock clears,
the retest engine can fire off a leg whose crossing was never actually traded or
even assessed.

### H6. Failed pending deletion is retried every tick **[read]**

In `ManageRetestOrders()` the `OrderDelete` at line 880 is attempted on every tick
while the cancel condition holds. Only the *error message* is throttled to 30
seconds (line 891); the order operation itself is not. A pending inside the
broker's freeze level will refuse deletion and be hammered continuously. Throttle
the attempt, not the print.

### H7. Margin is checked for the wrong order type **[read]**

```cpp
if(AccountFreeMarginCheck(Symbol(),marketCommand,lots)<=0.0)
```

`marketCommand` is `OP_BUY`/`OP_SELL`, but the order actually being sent is
`OP_BUYSTOP`/`OP_SELLSTOP` (line 658). Pending orders do not consume margin at
placement, so this rejects legitimate pendings whenever free margin is tight.

---

# Part 4 — medium

### M1. Duplicated functions with contradictory comments **[read]**

`NormalizeProtectiveStop()` (line 1131) and `NormalizeTargetPrice()` (line 1147)
are **byte-for-byte identical** — same `MathCeil` on `OP_BUY`, same `MathFloor`
otherwise — while their header comments claim opposite intentions ("round toward
safety" vs "round outward"). One of the two rounding behaviours is wrong, and
because they share an implementation you cannot fix either without silently
changing the other.

### M2. One input controls two unrelated gates **[read]**

`MinimumDirectionalEfficiency` is both a range-vote threshold (line 991) and a hard
retest gate (line 550). `ContinuationGradientMinimum` is both the continuation
route threshold (line 344) and the retest slope gate (line 546). Tuning either one
moves two independent parts of the system at once, which makes the EA effectively
impossible to optimise coherently.

### M3. Orphaned global variables accumulate forever **[read]**

`StateKey()` (line 1389) embeds `MagicNumber`, `EMA_Period` and the resolved
timeframe. Change any of those three and the EA writes to a **new** key, stranding
the previous 8 globals permanently. `ResetPersistentStateOnInit` only deletes the
current key (line 1408), so it cannot clean up what it orphaned. Iterating over
`EMA_Period` during testing leaves 8 dead globals per value tried.

### M4. Stale lock survives removal and re-attach **[read]**

`OnDeinit` saves state regardless of `reason`. Remove the EA while locked,
re-attach it, and `LoadEpisodeState()` restores `g_episodeLocked = true` — the EA
sits there refusing to trade until `QuietBarsRequiredToRearm` bars pass, with no
obvious explanation. `REASON_REMOVE` should clear the state.

### M5. `g_quietBars` stalls whenever a retest is consumed **[read]**

When `ProcessRetestState()` returns true, `ProcessNewSignalBar()` returns at line
284, skipping the `g_quietBars++` in the locked branch. Bars that consume a retest
never count toward re-arming, so the unlock takes longer than
`QuietBarsRequiredToRearm` suggests.

### M6. `g_quietBars` read without an existence check **[read]**

```cpp
g_quietBars=(int)GlobalVariableGet(StateKey("QUIET"));
```

Every sibling field in `LoadEpisodeState()` is wrapped in `GlobalVariableCheck()`;
this one is not (line 1428). A missing key returns 0.0 and sets an error, which is
survivable here but is an inconsistency that will bite when someone adds a field
whose zero value is meaningful.

### M7. No upper bound on derived stop distance **[read]**

`stopDistance = StopLossMoney/(moneyPerPricePerLot*lots)` (line 1049). With
`StopLossMoney = 500` and `0.01` lots on gold this yields a **$500** stop distance.
Nothing caps it. A money-denominated stop needs a sanity ceiling in ATR or price
terms.

### M8. `RecoverRetestOrderState()` returns from inside its loop **[read]**

Line 486 returns on the first pending found, so the market-order scan below it
(line 488) never runs when a pending exists. If both a pending and a triggered
position are present, the position is missed.

### M9. Dashboard layout does not scale with font size **[read]**

`DashboardFontSize` is an input, but every label's Y coordinate is hardcoded
(12, 36, 59, 77 … 431). Raising the font overlaps the rows and overflows the panel,
and the validator's fixed 450-pixel floor does not account for it.

---

# Part 5 — low / cosmetic

- **L1.** `DirectionName(0)` returns `"SELL"` (line 1361). `g_retestDirection` can
  legitimately be 0, so the dashboard can display a confident "SELL" for no
  direction at all.
- **L2.** `g_lastDecision` initialises to `"Waiting for first completed M30 candle"`
  (line 95) — hardcodes M30 although `SignalTimeframe` is an input.
- **L3.** `#property description` (lines 7-8) and the file header both describe the
  EA as M30-specific; the timeframe is configurable.
- **L4.** `barExpired=(ageBars>=RetestPendingExpiryBars && ageBars>=0)` (line 865)
  — the `>= 0` term is unreachable given the first condition.
- **L5.** `AccountFreeMarginCheck()` is deprecated; on several builds it returns 0
  and sets error 134 rather than a negative number, so `<= 0.0` is doing the right
  thing by accident rather than by design.
- **L6.** `UpdateDashboard()` runs from `OnInit()` before any tick, where
  `RefreshRates()` fails and Bid/Ask display as 0.00.
- **L7.** Line 44 `RetestMaximumPenetrationATR` has a stray extra space breaking the
  otherwise consistent input alignment.

---

# Suggested order of work

1. **Clamp the cosmetic validators** — stops the unload-on-edit immediately.
2. **Throttle the dashboard** — stops the freeze, and makes backtests usable.
3. **Guard `EMAValue()`** — C3 is the one that can place a real trade on a fake signal.
4. **Drop the comment check from `IsCurrentRetestOrder()`** — magic number alone.
5. **Handle error 147** — restores the retest route on ECN brokers.
6. Then H1-H7 in order.

Items 1 and 2 are roughly thirty lines between them and account for everything you
are seeing when you edit an input.
