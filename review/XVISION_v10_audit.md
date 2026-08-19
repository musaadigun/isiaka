# Audit — XVISION_Gold_EMA20_Directional_EA_v10.mq4

2,615 lines, read in full. v10 carries the v7 audit fixes forward intact: the
clamping resolver, the guarded `EMAValue()`, ticket-based order identity, the
throttled dashboard and the never-detach `OnInit()` are all present and correct.
The findings below are in the code v8/v9/v10 added on top.

Fixes are in `MQL4/Experts/Isiaka/XVISION_Gold_EMA20_Directional_EA_v11.mq4`.
Nothing was compiled — no MetaEditor on Linux — so each finding says how it was
established.

---

## C1 — CRITICAL: the retest engine can never fire

Three pieces, each reasonable alone, combine into a dead route.

**1.** v9 changed retest ownership. A raw crossing no longer arms a leg — it
*clears* one (`ProcessRetestState`, v10 line 1476):

```cpp
if(rawCross)
  {
   g_retestDirection=0;
   g_retestState=RETEST_IDLE;      // raw crossings no longer own a leg
   ...
   return(false);
  }
```

Only a fully qualified crossing grants a leg, in `ProcessNewSignalBar`:

```cpp
if(g_enableRetest)
  {
   g_retestDirection=direction;
   g_retestState=RETEST_WAIT_MOVE;
```

**2.** The very next statements lock the episode:

```cpp
g_episodeLocked=true;
g_quietBars=0;
```

**3.** But v7's guard — written for the *old* model where any raw cross armed a
leg — is still in `ProcessRetestState`, ahead of the state machine:

```cpp
if(g_episodeLocked)
  {
   g_retestStatus="Retest paused: episode is locked";
   return(false);
  }
```

So the leg is granted and immediately frozen for `QuietBarsRequiredToRearm`
bars — four M30 candles, two hours. During that freeze:

- any raw crossing hits branch 1 and resets the leg to `IDLE`, and
- the first touch of the EMA — the entire event the route exists to catch —
  happens unobserved.

`RETEST_ARMED` is effectively unreachable. The panel shows `WAIT MOVE-AWAY` then
`IDLE` forever.

**Fix:** the guard is deleted. It was load-bearing under the auto-arming model
and became harmful under the ownership model; ownership alone now gates the
route, which is what v9 intended.

## C2 — CRITICAL: one missed instant cross blacks out the next four bars

With `EnableInstantCrossEntry = true` (the default), `ProcessNewSignalBar` takes
no entry on the close — it hands market entries to the live path. But v10 still
locked the episode first:

```cpp
g_episodeLocked=true;                      // no order was placed
g_quietBars=0;
...
if(g_enableInstantCross)
  { ... return; }                          // "took no late entry"
```

and `ProcessInstantCrossEntry` refuses to run while locked:

```cpp
if(g_episodeLocked || g_marketEntryPending)
   return;
```

So a crossing the live path happened to miss — a spread spike, price already
past `MaximumMarketEntryDistanceATR`, the EA started mid-bar — consumed the
episode and disabled the live path for the next four bars, **including for
later, entirely valid crossings.** The one route expected to trade was switched
off by the route that no longer trades.

**Fix:** the lock now marks real consumption only — an entry taken, existing
exposure, or a confirmation setup armed. Not locking cannot re-fire the same
crossing: the instant test requires `close[1]` on the *old* side of the EMA, and
that bar has closed across. Only a genuinely new crossing can trigger it.

## C3 — `InstantCrossRetrySeconds` of 0 is an OrderSend storm

```cpp
ClampInt("InstantCrossRetrySeconds",InstantCrossRetrySeconds,0,3600,...);
```

The value is allowed to be 0, and the backoff is `TimeCurrent()+0`, which the
guard `TimeCurrent()<g_instantNextAttempt` treats as already expired. A send
failing for a persistent reason — stops inside the broker's stop level, no
margin — is then retried on **every tick** for as long as price stays in the
entry band. **Fix:** floor of 1.

---

## Correct, and worth recording as such

Three things that look like defects and are not. They are documented in v11 so a
later reader does not "fix" them back into bugs.

- **`OnTick` ordering.** `ProcessNewSignalBar()` runs before
  `ProcessInstantCrossEntry()`, so the live path uses diagnostics refreshed on
  the bar that just closed. Deliberate and right.
- **The duplicated rounding function.** `NormalizeProtectiveStop` and
  `NormalizeTargetPrice` had identical bodies under contradictory comments. The
  single rule is correct for all four cases: BUY stop below entry rounds up and
  tightens risk, BUY target above entry rounds up and widens reward; SELL
  mirrors both. v11 shares one body so they cannot drift, with a comment stating
  the rule.
- **Zero-return velocity/acceleration.** `PriceVelocityPerHour()` returns 0.0 on
  failure, and with the strict `>` comparison and a 0.0 minimum that fails the
  filter. Failing safe.

---

## Open, needing a decision rather than a patch

- **`MinimumDirectionalEfficiency` does double duty** — a range-vote threshold in
  `RangeVotes()` *and* a hard gate in `RetestCandleQualifies()` and
  `ProcessRetestState()`. Moving it moves two independent parts at once, so the
  EA cannot be optimised coherently. Same defect as v6's M2.
- **Efficiency is checked asymmetrically.** The cross route tests it only through
  range votes; the retest route also tests it directly. Deliberate or an
  oversight — only you know which.
- **Namespaces disagree three ways.** `StateKey()` uses `XVE6_` (deliberate, for
  upgrade takeover), the panel prefix is `XVE9_PANEL_`, order comments are
  `XVE9_EMA20`. Harmless today; confusing to grep.
- **The confirmation route is dead code by default.** `EnableInstantCrossEntry`
  defaults on, so `ProcessPendingMarketEntry()` never runs unless the switch is
  flipped. Its state is still persisted and restored correctly — it is dormant,
  not broken.

## Cosmetic, fixed

`DirectionName(0)` returned `"SELL"`, so an idle retest direction displayed as a
confident SELL. Startup text hardcoded "M30" while the timeframe is an input. A
duplicated header comment block sat above `IsCurrentRetestOrder()`.
