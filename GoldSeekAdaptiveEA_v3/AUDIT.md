# Code Audit — GoldSeekAdaptiveEA_v3.mq4

**Subject:** `GoldSeekAdaptiveEA_v3.mq4`, 2,201 lines, MQL4 (`#property strict`), version 3.00
**Scope:** Full static read of the source. No compilation, no backtest, no live data.
**Date:** 2026-08-12

Line references are `line N` against the copy committed alongside this document.

---

## Summary

The engineering scaffolding is genuinely good: a clean state machine, thorough crash/restart
recovery, no repainting, and consistently careful division-by-zero hygiene. The problems are
concentrated in two places — **risk controls that are absent or bypassable**, and a **signal
stack whose sophistication is largely inert**, with an online-calibration loop that provably
stops learning.

| Severity | Count | Theme |
|---|---|---|
| P0 — Critical | 4 | Unprotected fill window, no loss caps, unbounded slippage, no instrument guard |
| P1 — High | 4 | Online calibration is self-defeating; input edits wipe user stops |
| P2 — Medium | 6 | Dead branch in direction selection, multi-instance collisions, init fragility |
| P3 — Low | 7 | Dead computation and write-only state |

**Bottom line:** not safe for live capital as written. Items P0-1 through P0-4 are each
independently capable of producing a loss far larger than the configured `StopLoss_PriceUSD`.

---

## P0 — Critical

### P0-1. Positions are opened with no stop loss, then protected afterwards

`OrderSend` is called with SL and TP hardcoded to `0.0` (line 1473–1476). Protection is applied
only afterwards, by `ApplyInputExits` → `ModifyActiveStops` (line 1132–1167, 1058). Between the
fill and the first successful `OrderModify` the position carries **no broker-side stop at all**.

The retry path makes the window wider than it first appears: each failure sets
`g_nextExitSyncAttempt = TimeCurrent() + OPERATION_RETRY_SECONDS` (2 s, line 1157), and the
fail-safe market exit only fires after `MAX_INITIAL_PROTECTION_FAILURES` = 5 attempts (line 94,
1158). That is roughly **10 seconds of unprotected exposure**, followed by a market close that
itself retries on a 2-second backoff (line 1747) — and the close needs the same trade context
that was already failing.

Worse, the fail-safe is gated on `StopLoss_PriceUSD > 0.0` (line 1158). With the stop input at
`0`, repeated modify failures produce no escalation whatsoever.

**Failure scenario:** EA fills a buy on XAUUSD one second before a US CPI print. The broker
rejects `OrderModify` with error 130/136 through the spread blowout. Ten seconds later gold has
moved $12 against the position; only then does the fail-safe attempt a market close, at whatever
price the unlimited-slippage close returns (see P0-3). Configured risk was $20; realised risk is
unbounded.

**Fix:** attempt SL/TP inside `OrderSend` first; fall back to the modify path only when the
broker rejects stops at open (ECN). Shorten the retry interval for the *initial* protection sync
specifically, and remove the `StopLoss_PriceUSD > 0.0` gate on the fail-safe.

### P0-2. No daily loss limit, no trade cap, no cooldown — and the counter that exists is never enforced

`EntriesToday()` (line 823) is a substantial piece of machinery: it persists a day key and a
count, reconciles against the terminal's open orders *and* full history every 5 seconds, and
defends against under-counting after a crash (line 842–849). It is called in exactly four
places — telemetry (line 1267), a log line (line 1552), the panel (lines 2074, 2094), and a warm-up
call in `OnInit` (line 2152).

**It is never compared to a limit.** The panel renders the count followed by the literal string
`" (UNCAPPED)"`. There is no daily loss cap, no consecutive-loss cooldown, no max-trades-per-day,
and no equity floor anywhere in the file.

This interacts badly with the re-entry path. `ResetForFreshCycle` (line 1762) runs immediately on
close and re-arms the state machine in the same call — `ComputeMarketSnapshot`,
`UpdateDirectionalTrackers`, `AdvanceAcquisitionState` (line 1796–1801) — and `OnTick` then calls
`TryOpenAcquiredTrack()` on the very same tick (line 2185). The comment at line 1793 is explicit
that this is intended: *"may take a same-direction continuation if it still independently
qualifies."*

**Failure scenario:** gold chops in a $25 band with M5 structure and ATR expansion both reading as
"qualified." A trade stops out at $20. Structure has not changed, so the same direction re-qualifies
on the same or next M1 bar and the EA re-enters. Repeat. Nothing in the code stops this from running
all session; the only brake is that structural readiness eventually decays.

**Fix:** add an enforced daily realised-loss cap and a consecutive-loss cooldown, and gate
`AcquisitionEvidenceReady` on them. The counter and persistence layer to do this already exist —
only the comparison is missing.

### P0-3. Slippage is effectively unlimited on both entry and exit

`NO_EA_SLIPPAGE_CAP_POINTS = 1000000` (line 90) is passed as the slippage argument to both
`OrderSend` (line 1474) and `OrderClose` (line 1742). On 2-digit gold (`Point` = 0.01) that is a
**$10,000 tolerance**. There is also no maximum-spread veto anywhere — the panel displays the
spread (line 2115) but nothing acts on it.

This is deliberate; `OnInit` announces it (line 2158–2159: *"no EA spread/slippage veto; actual
execution costs remain auditable"*). Auditable after the fact is not the same as bounded. On an
instrument that routinely widens to 50–100+ points at rollover and on news, an EA working a $20
stop has surrendered its entire cost structure to the execution venue.

Note the asymmetry: unlimited slippage on the *exit* is defensible (it guarantees the position
closes). Unlimited slippage on the *entry* is not — a rejected entry costs nothing.

**Fix:** keep the unlimited tolerance on `OrderClose`; cap it on `OrderSend`, and add a
maximum-spread precondition to `TryOpenAcquiredTrack`.

### P0-4. No instrument guard, on a strategy defined entirely in absolute USD

Every threshold in the model is an absolute price quantity, not a normalised one:
`StopLoss_PriceUSD` = 20.00 (line 12), `MIN_REMAINING_TRAVEL_USD` = 7.50 (line 102),
`CALIBRATION_TARGET_USD` = 30.0 (line 108), `CALIBRATION_ADVERSE_USD` = 15.0 (line 109), the
adverse clamps `Clamp(..., 5.0, 15.0)` (line 542, 682) and `Clamp(..., 8.0, 20.0)` (line 1675),
and the exit constants at lines 106–107.

There is **no check anywhere** that the chart symbol is gold — no symbol-name test, no `Digits`
test, no contract-size test. `OnInit` validates lot sizing (line 2126) and nothing else.

**Failure scenario:** the EA is attached to EURUSD. `MIN_REMAINING_TRAVEL_USD` = 7.50 means 7.50
*price units* — 75,000 pips. `expectedTravel` is clamped to `[6.0, 60.0]` (line 681), so the
remaining-travel gate can never be satisfied and the EA silently never trades. On an index CFD the
same constants are silently far too tight, and a "$20 stop" becomes 20 index points. Either way
the user gets no warning; the panel just reads `SCANNING FOR A DEVELOPING MOVE` forever.

**Fix:** validate the symbol in `OnInit` (contract size and tick value in a plausible gold range,
or an explicit symbol whitelist) and refuse to load otherwise.

---

## P1 — High

### P1-1. The online calibration writes to a different bin than it reads from

This is a concrete logic error, not a modelling opinion.

- **Read side:** `ApplyOnlineCalibration` bins on its *input*, the offline score —
  `int bin = CalibrationBin(offlineProbability)` (line 587).
- **Write side:** the trade records its outcome into the bin of the *output* —
  `g_activeCalibrationBin = CalibrationBin(decisionP30)` (lines 1503, 1533), where `decisionP30`
  is `Probability30()`, i.e. the already-calibrated value (line 1465, 1297).
- `RecordCalibrationOutcome(g_activeCalibrationBin, ...)` then increments that bin (line 1825).

Because calibration blends the offline score *toward a lower posterior*, the output frequently
falls into a lower bin than the input. When it does, the bin the EA reads from stops receiving
outcomes — permanently.

`calibration_reproducer.py` in this directory reproduces it. With a steady offline score of 0.150
and every trade labelled MISS30:

```
trade   1: readbin=1 writebin=1 calP30=0.1500 probQuality=0.846 (n_read=1)
trade  20: readbin=1 writebin=1 calP30=0.1204 probQuality=0.618 (n_read=20)
trade  50: readbin=1 writebin=0 calP30=0.1183 probQuality=0.603 (n_read=20)
trade 200: readbin=1 writebin=0 calP30=0.1183 probQuality=0.603 (n_read=20)
>> read/write bins diverge at trade 21
final counters per bin: [180, 20, 0, 0, 0]
```

Bin 1 freezes at 20 observations. The remaining 180 outcomes accumulate in bin 0, which these
setups never read. `calP30` is pinned at 0.1183 forever — the "online calibration" has silently
stopped calibrating.

**Fix:** bin on one quantity consistently. The offline score is the correct choice, since that is
what the posterior is meant to correct.

### P1-2. Calibration counters never decay and never reset

`RecordCalibrationOutcome` (line 596) increments and persists; nothing ever decrements, ages, or
caps `g_calibrationHits[]` / `g_calibrationMisses[]`. They live in terminal `GlobalVariables`
keyed by account and symbol (line 230), surviving restarts, recompiles, and input changes
indefinitely.

`learnedWeight = Clamp(observations/60.0, 0.0, 0.65)` (line 592) means influence only ever grows.
Where read and write bins agree (offline score below 0.12), the reproducer shows a monotone decay
rather than a freeze:

```
offline=0.110: trade 1 probQuality=0.538 → trade 50 = 0.104 → trade 200 = 0.025
```

`probabilityQuality` carries weight 0.12 in `opportunityScore` (line 696). Entry requires
`opportunityScore >= MIN_OPPORTUNITY_SCORE` = 0.30 (line 103, 1345). The floor guaranteed by the
other entry gates is only ≈0.215:

| Term | Guaranteed at the entry gate | Contribution |
|---|---|---|
| structuralQuality | `(0.7629 − 0.62)/1.60` = 0.089 | 0.28 × 0.089 = 0.025 |
| motionQuality | 1.0 (required by `M5MotionAligned`) | 0.140 |
| remainingQuality | `7.50/30` = 0.25 | 0.14 × 0.25 = 0.035 |
| exhaustion headroom | `1 − 0.78` = 0.22 | 0.07 × 0.22 = 0.015 |
| **Floor** | | **≈ 0.215** |

So ~0.085 must come from the soft terms, of which `probabilityQuality` can supply up to 0.12.
As calibration decays that headroom disappears and the entry gate silently tightens over the
EA's lifetime — a behaviour change with no user-visible signal and no way to reset short of
deleting global variables by hand.

**Fix:** add a decay factor or a rolling window to the counters, and expose a reset.

### P1-3. The calibration label is unreachable by construction, so nearly every outcome is a MISS

Success is defined as `g_activeMaxFavorable >= CALIBRATION_TARGET_USD` — a $30 favourable
excursion (line 1818). But the default stop is $20 (line 12), and the model's own adverse exit
triggers at `Clamp(3.8·σ·√5, 8.0, 20.0)` (line 1675), i.e. $8–$20 against.

Failure, by contrast, is recorded on almost any terminating condition: MAE ≥ $15, **or** any
model exit reason at all, **or** age beyond the horizon (line 1820–1823).

The label is therefore heavily biased toward MISS regardless of whether the signal had merit. This
is what drives P1-1 and P1-2 — the learner is being fed a target its own risk management prevents
it from hitting.

**Fix:** either measure calibration against a target the trade management can actually reach (MFE
relative to the adverse exit boundary), or record censored outcomes explicitly rather than folding
them into MISS.

### P1-4. Editing any input while a trade is open silently discards user-set stops

`OnDeinit` with `REASON_PARAMETERS` writes a `Reconfigure` flag (line 2165–2168). On re-init,
`RecoverActiveTrade` reads it and takes the reconfigure branch (line 1227–1234):

```
g_manualSLOverride = false;
g_manualTPOverride = false;
g_needExitSync     = true;
```

The EA then recomputes stops from the inputs and overwrites whatever is on the order.

**Failure scenario:** a trade is $14 in profit. The user manually drags the stop to breakeven,
then opens the Inputs tab to change `LotSize` for the *next* trade. On OK, the EA resets the stop
to `entry − $20`. A trade that was risk-free is now risking $20 again, with no warning and no log
line naming the discarded level.

**Fix:** preserve manual overrides across a parameter change, or warn explicitly in the panel and
log before overwriting.

---

## P2 — Medium

### P2-1. The tracker-score fallback in `BestTrackerDirection()` is dead code

`BestTrackerDirection` (line 707) returns the structural direction when it qualifies; otherwise it
falls through to an opportunity-score comparison and returns the better tracker (line 712–715).

That fallback can never produce a trade. Its only consumer is `AdvanceAcquisitionState`, whose
next statement in `STATE_SEARCH` is `M5StructuralReady(direction, MIN_STRUCTURAL_ONSET_SCORE)`
(line 1363), and the first line of `M5StructuralReady` is:

```c
if(direction==0 || direction!=g_market.structuralDirection) return(false);
```

If the fallback returns the structural direction, `M5StructuralReady` already returned false for
it one line earlier in `BestTrackerDirection`. If it returns the opposite direction, the guard
rejects it. Either way: false. **`STATE_SEARCH` can only ever advance on
`M5StructuralReady(structuralDirection, 0.62)`** — the dual-tracker scoring contributes nothing to
direction selection.

The trackers still matter through `AcquisitionEvidenceReady`, so this is dead *selection* logic,
not dead trackers. But the "dual-direction pursuit engine" of the file header is, at the point of
choosing a side, a single structural sign test.

### P2-2. Any foreign position on the symbol blocks the EA silently

`HasAnyOpenMarketPositionOnSymbol` (line 882) ignores magic numbers entirely and blocks both
`AdvanceAcquisitionState` (line 1357) and `TryOpenAcquiredTrack` (line 1446). Meanwhile
`FindOpenEAOrder` (line 870) matches **only** `EA_MAGIC`, so nothing is adopted.

Consequences: a manual hedge, another EA, or a leftover v1/v2 position freezes this EA
indefinitely. The panel gives no indication — it reads `SCANNING FOR A DEVELOPING MOVE` while the
EA is in fact blocked.

Note the inconsistency in the three magic-number paths: `IsStrategyFamilyMagic` recognises legacy
v1/v2 magics (line 263) but is used *only* for counting (lines 809, 816) — a count that is itself
never enforced (P0-2). Adoption uses `EA_MAGIC` only; blocking uses no magic at all.

### P2-3. Two instances on one symbol will corrupt each other

`PersistenceKey` is `"GSA3." + AccountNumber() + "." + Symbol() + "." + suffix` (line 230) — no
chart ID, no timeframe, no magic. Two charts of XAUUSD running this EA share one namespace for
`Ticket`, `ExpectedSL`, `Peak`, calibration counters, and the daily counter, and both match the
same `EA_MAGIC` in `FindOpenEAOrder`. Each will try to adopt and manage the other's position.

**Fix:** include `ChartID()` in the key, or detect and refuse a second instance.

### P2-4. `OnInit` hard-fails when broker symbol data is not yet loaded

`ValidateRequestedLots` returns false with *"broker lot specification is unavailable"* when
`MarketInfo` returns 0 for MINLOT/MAXLOT/LOTSTEP (line 966), and `OnInit` converts that into
`INIT_PARAMETERS_INCORRECT` (line 2129). `MarketInfo` legitimately returns 0 at terminal startup
and over the weekend before the symbol subscription completes.

The EA does not retry — it is dead until the user manually re-attaches it. For an EA intended to
run unattended across a restart, this is a real availability bug.

**Fix:** treat missing broker data as "wait and retry on the next tick," not as a fatal
configuration error.

### P2-5. `StopLoss_PriceUSD = 0` is accepted without warning

`ValidateUserInputs` (line 994) permits a zero stop, and the default `TakeProfit_PriceUSD` is also
0 (line 13). With both at zero the position has **no broker-side exit of any kind** — everything
depends on the EA continuing to run. If the terminal is closed, the EA removed, or the chart
changed, the position sits naked. Compounding this, the protection fail-safe is itself gated on
`StopLoss_PriceUSD > 0.0` (line 1158).

**Fix:** either require a positive stop or warn loudly in the panel and log when there is none.

### P2-6. A full order-history scan every 5 seconds, for a counter nobody reads

`CountFilledEntriesFromTerminal` (line 803) walks `OrdersTotal()` **and** the entire
`OrdersHistoryTotal()`. `EntriesToday()` calls it whenever the 5-second audit window has elapsed
(line 830), and `EntriesToday()` is itself invoked from `ShowStatus`, which runs on a 250 ms
cadence (line 2085, 2094).

On a live account with a long history this is a repeated full scan for a value used only for
display. In the strategy tester it is worse, because history grows monotonically through the run.

---

## P3 — Low (dead weight)

1. **Six of eight probability computations are dead.** `probability10Up/Down`,
   `probability20Up/Down`, and `probability50Up/Down` are computed every M1 bar (lines 777–784),
   each running a full `DestinationProbability` — two barrier formulas, a normal CDF, several
   exponentials. `DirectionRawProbability` is only ever called with `target = 30` (lines 609, 674).
2. **`probabilityUp` / `probabilityDown` are write-only** (lines 774–775). Never read.
3. **The advertised benchmark constants are unused.** `BENCHMARK_REVERSAL_USD` and
   `BENCHMARK_QUALIFYING_MOVE_USD` (lines 95–96) appear nowhere else. The panel's
   `"BENCHMARK $50 LEG | $15 REVERSAL"` (line 2018) is a hardcoded string, not derived from them,
   and no code path enforces either figure.
4. **`g_freshM1Bars` and `g_resetTime` are write-only** (lines 135, 1891, 1906, 1914, 2142).
   `g_resetTime` exists solely to gate the increment of a counter that is never read.
5. **`ReturnToSearch(const bool blockOldDirection)`** ignores its parameter (line 1327, acknowledged
   in the comment).
6. **Duplicated sigma computation.** `UpdateCUSUM` computes `ReturnSigma(PERIOD_M1, 48, 0.10)` at
   line 792, and `ComputeMarketSnapshot` — called immediately after on the same bar (line 1915–1916)
   — computes the identical value again at line 729.
7. **Mode probabilities survive session gaps.** The gap handlers reset CUSUM and both trackers
   (lines 1886–1891, 1901–1906) but leave `modeNoise`…`modeShock` carrying pre-gap state into the
   new session.

---

## What the code gets right

Worth stating plainly, because it is the part worth keeping:

- **No repainting.** Every indicator and price read uses shift ≥ 1 — `iATR(...,1)`,
  `iMA(...,1)`, `iClose(...,1)`. `LinearVelocity`, `ReturnSigma`, `DirectionalEfficiency`,
  `StructuralLocation` and `AverageBarPressure` all start at shift 1. Backtest results will not be
  inflated by look-ahead, which is the single most common defect in EAs of this type.
- **The barrier mathematics is correct.** `BarrierBeforeAdverseProbability` (line 504) matches the
  standard two-sided first-passage result for Brownian motion with drift,
  `(1 − e^{−2μa/σ²}) / (1 − e^{−2μ(a+b)/σ²})`. `HitByHorizonProbability` (line 518) matches the
  reflection-principle result `Φ((μT−a)/σ√T) + e^{2μa/σ²}·Φ((−μT−a)/σ√T)`. Units are consistent
  (per-minute drift against per-minute sigma). The Abramowitz–Stegun CDF (line 196) is correctly
  implemented including the negative-tail reflection.
- **The IMM transition prior is valid.** `0.72·p_i + 0.28·(1−p_i)/4` (line 492) is a proper
  row-stochastic mixing: 0.72 self-persistence, 0.07 to each of four alternatives.
- **Division-by-zero discipline is consistent throughout.** ATR floored at `Point`, sigma floored
  at `Point`, `path < EPSILON` guards, `MathMax(expectedTravel, 1.0)`, guarded `tickSize` — I found
  no unguarded divide in the file.
- **`GetTickCount()` wraparound is handled correctly** via unsigned arithmetic (lines 830, 2085),
  which is a detail most MQL4 code gets wrong.
- **Crash and restart recovery is thorough.** `RecoverActiveTrade` (line 1169) reconciles persisted
  state against the live order, validates that persistence matches the ticket before trusting it,
  renormalises restored mode probabilities, and falls back sensibly per field. The entry counter
  explicitly defends against the crash-after-fill-before-increment case (line 842–848).
- **Session-gap handling is correct.** Both gap branches refuse to inject the cross-gap price jump
  into CUSUM or thesis evidence (lines 1877–1911) — a subtle failure mode that is easy to miss.

---

## Recommended order of work

1. **P0-1** — send stops with the order; fix the fail-safe gate. *(small, highest risk reduction)*
2. **P0-4** — add a symbol guard in `OnInit`. *(small)*
3. **P0-2** — enforce a daily loss cap and a post-loss cooldown. *(medium; persistence exists)*
4. **P0-3** — cap entry slippage, add a max-spread precondition. *(small)*
5. **P1-1** — bin on the offline score on both sides. *(one line)*
6. **P1-3 / P1-2** — redefine the calibration label, add decay. *(medium)*
7. **P1-4** — preserve manual stops across input changes. *(small)*
8. P2 items, then delete the P3 dead code.

Items 1, 2, 4 and 5 are each an hour or less and remove the majority of the tail risk.
