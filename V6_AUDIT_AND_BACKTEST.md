# XVISION_Gold_Velocity_AI_EA_V6.mq4 — audit and backtest

**Date:** 2026-08-08
**Subject:** 1664-line MQL4 expert advisor, gold-only. Closed-H1 regime gate → closed-M5 setup → closed-M1 trigger.
**Method:** static review plus an independent Python port. Not MetaEditor, not the Strategy Tester — the file was **not compiled**.

---

## Verdict

**V6 is a different system, and a materially better one.** Every blocking finding from the V4 audit is fixed, and fixed correctly. The fitted logistic model is gone entirely, replaced by a deterministic three-timeframe threshold stack. Most consequentially, dropping the trailing stop **collapsed the intrabar-ordering ambiguity that made V4 unmeasurable** — this backtest has a determinate answer where V4's did not.

The result is **consistent with a small real edge, and not yet established as one.** On the 12.4-month reduced-form test the profit factor is 1.22 with t = 1.55 (P(net ≤ 0) = 5.9%). On the short full-stack window it is 1.84 with t = 2.24, but that window is only 47 trading days and one shipped default looks fitted to it.

**One question I can't answer and you can: what data were the 17 thresholds chosen on?** If they were tuned on this gold history, everything below is in-sample and proves nothing. If they were set a priori, the out-of-window agreement in §4 is meaningful evidence.

---

## 1. The binding constraint: there is very little testable data

V6 requires closed **M1** bars. The supplied M1 file has a **56-day hole**:

| Gap | From | To |
|---|---|---|
| **56 days 02:34** | 2026-04-14 13:36 | 2026-06-09 16:10 |
| 2 days | 2026-07-03 | 2026-07-06 |
| 2 days | 2026-06-19 | 2026-06-22 |

Actual M1 coverage is 2026-04-06 → 2026-04-14 plus 2026-06-09 → 2026-08-07: **67 calendar days, 47 distinct trading days, 101 trades.** V4 got 12.4 months and 380 trades on the same account. This is one-fifth the evidence.

Everything in §2–3 rests on those 101 trades. §4 is the attempt to get around it.

---

## 2. Baseline backtest — V6 shipped defaults

SL $25, no take profit, no trailing, no break-even, 120-minute time stop, 3 trades/day, spread modelled at $0.30, 0.01 lots on $10,000.

| | Trades | Net | PF | Win | Max DD | Expectancy |
|---|---:|---:|---:|---:|---:|---:|
| Stop checked before trail | 101 | **+$446.27** | 1.842 | 58.4% | $78.10 | +$4.42 |
| Trail advanced before stop | 101 | **+$446.27** | 1.842 | 58.4% | $78.10 | +$4.42 |

**Identical.** This is the single most important structural improvement over V4. With no trailing stop and no take profit there is only one price level in play, so the order in which price touches the bar's extremes cannot change the outcome. V4's ±$390 measurement bracket — the thing that made its sign undeterminable — **does not exist in V6.**

- t = 2.241, bootstrap 95% CI **[+$66, +$842]**, P(net ≤ 0) = **0.9%**
- Exits: **90 time stop, 11 stop loss.** 49 long, 52 short.
- Blocked: 118 by the 3-per-day cap. Median hold 120 min.
- 47 trading days → 2.15 trades/day.
- Random-direction control (200 runs, coin-flip direction, same timing and management): real +$446 against a control mean of +$21 (sd $178) — **100th percentile**.

Cost robustness is good, and unlike V4 costs are not the binding issue:

| Spread | $0.00 | $0.15 | $0.30 | $0.50 | $0.80 |
|---|---:|---:|---:|---:|---:|
| Net | +$473 | +$460 | +$446 | +$428 | +$401 |

Gross edge is $473 over 101 trades — **$4.68 per trade**, versus V4's $1.10. Four times the margin against the same costs.

---

## 3. One shipped default looks fitted

`MaximumHoldingMinutes = 120` sits on a sharp single-point maximum of its own sweep:

| Hold (min) | 30 | 60 | 90 | **120** | 150 | 180 | 240 | 360 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Net (101-trade window) | $8 | $102 | $289 | **$446** | $330 | $170 | $273 | −$34 |

That is exactly the shape you get from tuning on the sample. The same sweep on the longer reduced-form test in §4 **peaks somewhere else**:

| Hold (min) | 60 | 90 | **120** | 150 | 180 | 240 | 300 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Net (560-trade core) | $348 | $725 | **$802** | **$1,139** | $631 | $733 | $985 |

120 is not the optimum on 12.4 months — 150 is, by 42%. **The 120 peak does not reproduce out of window.** Treat it as a fitted parameter, not a discovered horizon.

`InitialStopLossMovement = 25` looks better. Its sweep is a **broad plateau**, not a spike:

| SL | 10 | 15 | 20 | **25** | 30 | 35 | 40 | 50 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Net | $115 | $111 | $298 | **$446** | $461 | $436 | $416 | $433 |

Anything from 25 to 50 works; below 20 it breaks down. A plateau with a sharp cliff on one side is what a real effect looks like — the strategy needs room for a 2-hour hold, and $15 (V4's value) is too tight. That one I'd trust.

---

## 4. The out-of-window test

The M1 trigger can only be evaluated where M1 data exists. But the **H1 regime gate and M5 setup** need only M5 and H1, both of which cover the full 12.4 months. Running that reduced form — same thresholds, same management, entering on the next M5 open — gives a sample 5.5× larger and covers 9 months the M1 file never saw:

| Window | Trades | Net | PF | Win | Expectancy |
|---|---:|---:|---:|---:|---:|
| Full 12.4 months | 560 | +$801.70 | **1.219** | 47.5% | +$1.43 |
| **Outside the M1 window** (2025-07 → 2026-04) | 396 | +$548.77 | **1.216** | 46.2% | +$1.39 |
| Inside the M1 window | 164 | +$252.93 | **1.226** | 50.6% | +$1.54 |

**Profit factor agrees to within 0.01 across windows that share no data.** That is the strongest single piece of evidence in this report, and it is the thing V4 never produced.

The honest counterweight — the same sample's significance is weaker than the short window's:

- t = **1.545**, bootstrap 95% CI **[−$191, +$1,848]**, P(net ≤ 0) = **5.9%**
- 10 of 14 months positive. Worst month −$204 (2025-12), best +$261 (2026-01).
- Random-direction control: real +$802 against control mean +$47 (sd $458) — **95th percentile**.

So: two samples, two readings. 101 trades at PF 1.84 (t = 2.24) and 560 trades at PF 1.22 (t = 1.55). **The larger sample is the more trustworthy number**, and it says the edge is real-ish but small — around +0.06 R per trade, the same order as V4's, but this time without a sign ambiguity, without a split-half collapse, and with out-of-window agreement.

**Split-half on the 101 trades is also consistent**, which V4's never was:

| Half | Trades | Net | PF | Win |
|---|---:|---:|---:|---:|
| 2026-04-06 → 2026-06-30 | 50 | +$277.49 | 1.850 | 60.0% |
| 2026-07-01 → 2026-08-06 | 51 | +$168.78 | 1.829 | 56.9% |

---

## 5. Does V6's confidence score rank outcomes?

V4's probability output was inverted (correlation −0.036, highest quartile the only loser). V6's hand-built score is **right-signed**, though weak:

| Ranked by | Q1 | Q2 | Q3 | Q4 | correlation |
|---|---:|---:|---:|---:|---:|
| V6 confidence | +$4.41 | −$1.17 | +$5.24 | **+$9.20** | **+0.065** |
| M1 trigger strength | +$2.44 | −$0.05 | +$2.28 | **+$13.09** | **+0.173** |
| H1 gap | +$2.18 | +$4.69 | +$0.92 | **+$9.97** | **+0.114** |

All three point the right way, and M1 strength is the best of them. On 101 trades none of this is conclusive, but it is the opposite of V4's result rather than a repeat of it.

---

## 6. Structural note: the edge is the 120-minute horizon

90 of 101 exits are the time stop; only 11 are stop losses. Adding a $30 take profit and removing the time stop **collapses the result to −$15** (PF 0.988). The strategy is therefore: *qualified trigger → hold about two hours → exit at market.* The $25 stop participates in roughly one trade in nine.

That is clean and testable, and it is a legitimate way to build a system. But it means two things:

1. The risk management is doing almost nothing. Nearly all outcome variance comes from the 2-hour forward return after a trigger.
2. **The entire edge rides on the one parameter that §3 shows is fitted.** If the true horizon is 150 minutes, or if it drifts with volatility regime, the shipped configuration is not the one to trade.

---

## 7. Audit — V4 findings, all fixed

Verified in source. This is a thorough and correct response to the previous audit.

| V4 finding | V6 status |
|---|---|
| **H1** naked position after ECN fallback | **Fixed.** `EnsureInitialStopProtection()` (1173–1216) runs first in `ManagePositionEveryTick`, re-asserts the stop every tick, and closes after 5 failures via `GV_STOP_REPAIR_FAILURE_LIMIT`. `g_pendingClose` persists a close intent across ticks. This is the reconciler pattern, implemented correctly. |
| **H2** digit-dependent slippage | **Fixed.** `MaximumSlippageMovement = 0.50` in price units; `SlippagePointsForBroker()` (801–805) converts with `MathRound(movement/Point)`. |
| **H3** per-tick history scans | **Fixed.** `RefreshAccountCache()` (699–753) computes all three counters in one pass, keyed on day start + history/open totals, with `InvalidateAccountCache()` on every trade action. The O(n²) dedupe is now `ArraySort` + linear scan. `UpdatePanelThrottled()` caps the panel at 1 Hz. |
| **H4** GlobalVariables never deleted | **Fixed.** Partial state is in memory (`g_partialDone1/2/3`), with an explicit `IsTesting()` branch so tester passes never read stale flags, `CleanupPartialState()` on close, and `CleanupOrphanedPartialGlobals()` at init. |
| **M2** ATR trail on the forming bar | **Fixed.** `iATR(...,PERIOD_M1,TrailingATRPeriod,1)` — shift 1. |
| **M3** stop level + freeze level summed | **Fixed.** `BrokerModificationDistance()` uses `MathMax`. |
| **M4** silent validation failures | **Fixed.** `InvalidInput(name, requirement)` on every branch. |
| **M5** no close retries | **Fixed.** 3 attempts with `IsRetryableCloseError()` covering 4/6/128/135/136/137/138/146, plus a pending-close retry next tick. |
| **L7** silent max-lot cap | **Fixed.** Prints a warning. |
| **L8** modal alert by default | **Fixed.** `EnableEntryPopupAlert = false`. |

---

## 8. Audit — new findings in V6

### V6-1 (medium) — the staleness guard was removed

V4 rejected any H4 regime bar older than 12 hours (`h4AgeHours > 12.0 → return false`). V6's `GVLastFullyClosedShift` (196–208) checks only that the bar has closed (`barClose > decisionTime → -1`). **There is no upper bound on age.**

Measured on the supplied data: H1 regime bars up to **54 hours old**, 530 valid bars affected, and **6 qualified signals fired on H1 data more than 12 hours stale**. After a weekend or a feed outage the EA will trade Monday off Friday's H1 regime.

The P/L impact here is small — restoring a 12-hour bound gives +$461.88 vs +$446.27, slightly *better* — but that is a 6-signal sample, not a reason to leave it out.

**Fix.** Add an age bound inside the helper:
```mq4
if(decisionTime-barClose > (datetime)requiredMaxAgeSeconds) return(-1);
```
called with something like `3*timeframe*60` for M5 and `12*3600` for H1.

### V6-2 (low-medium) — `atrM5Slow` is dead but still gates every signal

Line 225 computes `GVATR(symbol,PERIOD_M5,48,closedM5)` and line 228 rejects the whole calculation if it is ≤ 0. **The value is never used again.** In V4 it fed the `volatilityRatio` feature; that feature is gone, the computation is not. Since `GVATR` returns 0 if *any* of 48 true ranges is 0, a single flat M5 bar silently kills the signal for no reason at all. Delete it, or use it.

### V6-3 (low) — `SendEntry` returns `false` after a successful `OrderSend`

Two paths (1063–1069 and 1084–1092) return `false` when the order **is already open** — `OrderSelect` failed, or stop anchoring failed. The position is real; the return value says otherwise, and `g_lastEntryTime` (line 1098) is never reached on those paths. Nothing breaks, because `InvalidateAccountCache()` fired at 1061 and `FindManagedTicket()` blocks re-entry — but a caller cannot distinguish "no position" from "position open, protection pending". Return a tri-state or set the entry time before the protection block.

### V6-4 (low) — `MaximumM1ChaseATR` is measured in M5 ATR

Line 314: `m1Chase = MathAbs(m1Close - m5Close)/atrM5`. The divisor is the **M5** ATR, but the input is named `MaximumM1ChaseATR` and defaults to 1.00. A reader setting "1 ATR of chase" will get roughly 5× more tolerance than they expect. The behaviour is defensible; the name is not.

### V6-5 (low) — `GV_STATE_EXHAUSTING` is never assigned

Defined at line 24, rendered at 129, tested at 1317 (`ProcessVelocityExit`) and 1468 (panel colour) — but **no code path ever sets it**. Half the velocity-exit condition is dead, and `UseVelocityExit` is therefore weaker than it reads.

### V6-6 (low) — two sources of truth for bar requirements

`GV_REQUIRED_M5_BARS 80` and `GV_REQUIRED_H1_BARS 40` are checked at 213–214, then `GVLastFullyClosedShift` is called with hard-coded `79` and `30` at 220–221. Four numbers, two of which are silently authoritative.

### V6-7 (low) — `result.velocityM15` holds an M1 value

Line 357 assigns `m1Strength` to a field named `velocityM15`, left over from V4's struct. The panel label at 1586 correctly says "M1 STR", so only the field name is wrong.

---

## 9. What I could not check

1. **Not compiled.** No MetaEditor. `ArraySort` on a `datetime[]` and the `GVLastFullyClosedShift` signature look correct by inspection, but this needs a real build.
2. **47 trading days of M1.** The primary constraint. No amount of analysis fixes a 101-trade sample.
3. **Provenance of the 17 thresholds** — see below.
4. **Constant spread.** Real gold spreads widen at rollover; the M1 trigger has no session filter.
5. **The reduced-form test in §4 drops the M1 trigger.** It validates the H1+M5 core, not the full stack.

---

## 10. What to do next

1. **Answer the provenance question.** Were the thresholds and the SL/hold defaults chosen on this gold history? If yes, §2–4 are in-sample and the honest status is "promising, untested". If no, §4 is genuine out-of-sample agreement and that is a real result. This changes the interpretation more than any further computation would.
2. **Get more M1 data.** Two years of M1 would let the full stack be tested properly. This is the highest-value action available and nothing else substitutes for it.
3. **Re-pick the hold time on the long sample, or stop treating it as fixed.** 120 is a fitted peak. 90–150 all work on the 560-trade core; pick from that range on evidence, or make it adaptive to ATR rather than a constant.
4. **Fix V6-1 (staleness) and V6-2 (dead ATR gate) before live.** Neither is a money-loser today; both are correctness issues that will bite on a Monday or a bad feed.
5. **Do not re-enable trailing without re-measuring.** The absence of a trailing stop is why this backtest has a determinate answer at all. Adding it back reintroduces the path-dependence that made V4 unmeasurable — and on this sample it *reduced* net from $446 to $312 anyway.

---

*Reproduction: `backtest/engine_v6.py`, `run_v6.py`, `overfit_v6.py`. V4 harness (`engine.py`, `sim.py`) reused unchanged for execution and management.*
