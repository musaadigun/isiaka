# Audit — XVISION_Gold_Velocity_AI_EA_V4.mq4

**Subject:** 1363-line MQL4 expert advisor, gold-only, embedded "V2 core" inference engine.
**Date:** 2026-08-08
**Scope:** static review of the single source file. No MetaEditor on this machine, so **the file was not compiled** — API/signature correctness below is by inspection, not by build. Nothing was run against a broker or the Strategy Tester.

---

## Verdict

The signal side is honest work: no lookahead, no repainting, no external dependencies, and two genuinely careful pieces of lot-sizing code. The execution side has one defect that can leave a live position without a stop loss, and one that will make the EA unusable in the Strategy Tester. The bigger finding is not a bug at all — **the model is one feature wearing eighteen features' clothing**, and at shipped defaults six of its eight advertised filters do nothing.

Do not run this on a live account until H1 and H2 are fixed.

---

## What it actually does

`GVCalculate(Symbol(), 1, ...)` fires once per M5 bar change and reads **shift 1** — the last closed M5 bar. Eighteen features are standardized and pushed through four independent logistic heads (P10, P20, P30, BAD), with monotonicity forced afterwards by `p30 = min(p20, min(p10, ·))`. A trade is taken when the qualification stack passes, one position at a time, managed by any combination of fixed TP / break-even / trailing / three partials / velocity exit / time stop.

**No lookahead, confirmed.** `h4Shift = iBarShift(H4, m5CloseTime, false) + 1` steps back to the last *fully closed* H4 bar, and `h4AgeHours ∈ [0, 12]` bounds staleness (`GVCalculate:246-305`). Signals will not repaint. This is the part most retail EAs get wrong and this one gets right.

---

## Blockers

### H1 — A position can end up live with no stop loss, and the EA reports success

`SendEntry` (`803-913`) has an ECN fallback: if `OrderSend` with stops attached fails with `ERR_INVALID_STOPS`, it resends **with `sl=0.0, tp=0.0`** and then re-attaches the stop via `OrderModify`. Two paths through that recovery leave the position naked:

```
line 870:  if(!OrderSelect(ticket,SELECT_BY_TICKET))
           {
              g_lastAction="ENTRY OPENED; SELECT FAILED";
              return(true);                    // <- skips the OrderModify entirely
           }
```
If `usedFallback` was true, the order carries no stop, this early return skips the anchoring step, and `SendEntry` returns **true**.

```
line 891:  if(OrderSelect(ticket,SELECT_BY_TICKET)) CloseSelectedOrder("PROTECTIVE STOP COULD NOT BE SET");
           g_lastAction="ENTRY ABORTED: STOP SET FAILED";
           return(false);
```
If that `OrderSelect` fails, the emergency close never runs. The panel says `ENTRY ABORTED`; the position is open and unprotected.

Nothing downstream repairs this. `ApplyStopManagement` (`953-1008`) only ever produces a stop once break-even or trailing activates, and both default to conditions that may never be met. With `UseBreakEven=false` and price never reaching `TrailingActivationMovement=10.0`, the position rides to the `MaximumHoldingMinutes` time stop with unbounded risk.

**Fix.** Add an unconditional reconciler at the top of `ManagePositionEveryTick`:

```mq4
if(InitialStopLossMovement>0.0 && OrderStopLoss()==0.0)
{
   double repair=(OrderType()==OP_BUY ? OrderOpenPrice()-InitialStopLossMovement
                                      : OrderOpenPrice()+InitialStopLossMovement);
   if(!OrderModify(OrderTicket(),OrderOpenPrice(),NormalizeDouble(repair,Digits),
                   OrderTakeProfit(),0,clrNONE))
      if(++g_stopRepairFailures>=5) CloseSelectedOrder("UNPROTECTED POSITION");
}
```
Retrying every tick is the point — it closes both holes above and any future one, without needing to enumerate them.

### H2 — `SlippagePoints` means different things on different gold feeds

`SlippagePoints = 50` is passed straight to `OrderSend`/`OrderClose`. Points are digit-dependent:

| Gold feed | `Point` | 50 points |
|---|---|---|
| 2-digit (XAUUSD 1234.56) | 0.01 | **$0.50** |
| 3-digit (XAUUSD 1234.567) | 0.001 | **$0.05** |

Five cents is tighter than a normal gold spread. On a 3-digit broker every market order bounces with 138 (requote) or 136 (off quotes), and the EA logs `ENTRY FAILED 138` and moves on. Every *other* tolerance in this EA is expressed in dollars of gold movement — `InitialStopLossMovement`, `MaximumSpreadMovement`, `MaximumEntryDeviationMovement`. This one input silently breaks that convention.

**Fix.** Take `SlippageMovement` as a double in price units and convert at use: `(int)MathRound(SlippageMovement/Point)`.

### H3 — Full order-history scan on every tick, plus an O(n²) inner loop

`UpdatePanel()` runs unconditionally at the end of every `OnTick`. Its call graph:

| Call | Cost | Times per tick |
|---|---|---|
| `OperationalEntryStatus` → `LatestEntryTime()` | full history walk | 1 |
| `OperationalEntryStatus` → `TradesOpenedToday()` | full history walk + O(n²) dedupe | 1 |
| `OperationalEntryStatus` → `ClosedPnLToday()` | full history walk | 1 |
| line 1317 `TradesOpenedToday()` again | full history walk + O(n²) dedupe | 1 |
| `FindManagedTicket()` | `OrdersTotal()` walk | ~7 across the tick |
| `ChartRedraw(0)` + ~15 object writes | chart repaint | 1 |

The dedupe in `TradesOpenedToday` (`645-653`, `660-668`) compares each candidate against every previously seen open time — quadratic in trades-per-day, on top of a linear history walk it performs twice.

Live, on an account with a long history, this stalls the terminal. In the Strategy Tester it is worse: history grows monotonically through the run, so total cost is O(bars × trades²) and a multi-year backtest effectively will not finish. Optimization is out of the question.

**Fix.** Cache `tradesToday` / `closedPnLToday` / `latestEntryTime`, recompute only on a day rollover or an `OrdersHistoryTotal()` change, and gate `UpdatePanel()` to once per second or per bar rather than per tick.

### H4 — Partial-profit state lives in terminal GlobalVariables and is never deleted

`SendEntry:900-904` writes four globals keyed `XVG.<account>.<magic>.<OrderOpenTime>` — `.LOT`, `.P1`, `.P2`, `.P3`. `ProcessPartialLevel` reads and sets them. **`GlobalVariableDel` is never called anywhere in the file.**

Two consequences:

1. **Live:** four variables accumulate per trade forever (MT4 expires them only after four weeks without access). Cosmetic but unbounded.
2. **Backtest — this one matters.** GlobalVariables persist across Strategy Tester passes. The key contains `OrderOpenTime()`, which *repeats exactly* when you re-run the same date range. So pass 2 reads pass 1's `.P1/.P2/.P3` flags, sees them set, and silently skips every partial close. **Backtests are not reproducible and optimization results are meaningless** for any configuration with `UsePartialProfits=true`.

The keying by open time rather than ticket was a deliberate and correct choice — MT4 partial closes mint a new ticket while preserving open time, so the flags survive the reissue. The problem is only persistence.

**Fix.** Simplest robust version: drop the globals and derive level completion from remaining volume (`OrderLots()` vs the initial lot recorded in the order comment), which is self-cleaning and tester-safe. Minimum viable version: `GlobalVariableDel` all four keys when the position closes, plus an `IsTesting()` branch using an in-memory struct.

---

## The model

This is the part that most changes how the EA should be used.

### One feature carries the model

Influence per one standard deviation of each feature (that is, the raw weights — the fair basis for comparison, since the features are standardized):

| feature | P10 | P30 | BAD |
|---|---:|---:|---:|
| **h4Body** — last closed H4 body ÷ H4 ATR14, signed toward trade | **0.947** | **1.007** | **−0.931** |
| vel_48 — 4h M5 velocity | −0.303 | −0.397 | 0.290 |
| h4Slope | 0.288 | 0.354 | −0.281 |
| vel_24 — 2h M5 velocity | −0.302 | −0.302 | 0.253 |
| eff12 | −0.050 | −0.199 | −0.056 |
| h4Gap | −0.047 | −0.184 | 0.083 |
| shock | 0.099 | 0.090 | −0.014 |
| \|composite\| | −0.087 | −0.052 | 0.123 |
| accel, coherence, vel_1/3/6/12, eff3, persist12, volRatio, pullback | ≤ 0.09 | ≤ 0.09 | ≤ 0.15 |

`h4Body` is 2.5× the next-largest term and carries the same sign structure across all four heads. The twelve M5 velocity and efficiency features that give the EA its name contribute |w| ≤ 0.09 on P30 — indistinguishable from noise at any realistic feature value.

### At default inputs, one number decides everything

With every other feature held at its training mean, the gates reduce to a threshold on `h4Body` alone:

| gate | default | reduces to |
|---|---|---|
| `MinimumProbability10Percent` | 70 | **h4Body ≥ 0.909** ← binding |
| `MinimumProbability30Percent` | 20 | h4Body ≥ 0.690 — shadowed by the above |
| `MaximumBadBefore10Percent` | 100 | `pBad ≤ 1.00` — tautology |
| `MinimumProbabilityEdgePct` | −30 | holds from h4Body ≥ −0.05 up — never binds |
| `MinimumH1PathEfficiencyPct` | 5 | `eff12 ≥ 0.05` vs training mean 0.141 |
| `MaximumShockRatio` | 2.5 | `shock` mean 1.00, SD 0.45 → +3.4 SD outlier guard |
| `MaximumVelocityStrength` | 2.5 | `\|composite\|` mean 0.37, SD 0.31 → +6.9 SD guard |
| `RequireClosedH4Alignment` | true | `EMA8 > EMA21` in trade direction ← binding |

Sweeping `h4Body` with all else at the mean:

| h4Body | p10 | p30 | pBad | qualifies |
|---:|---:|---:|---:|:--:|
| 0.00 | 0.368 | 0.075 | 0.350 | no |
| 0.60 | 0.593 | 0.178 | 0.180 | no |
| 0.69 | 0.626 | 0.200 | 0.161 | no |
| **0.91** | **0.700** | **0.263** | **0.121** | **yes** |
| 1.50 | 0.852 | 0.482 | 0.054 | yes |

**So the shipped strategy is: enter when the last closed H4 candle has a directional body of at least ~0.91 × H4 ATR(14), the H4 EMA8/EMA21 agree, and M5 velocity points the same way.** That threshold sits at +1.16 SD in `h4Body`'s own training distribution — roughly the **top 12% of H4 bars**, before the direction and EMA conditions cut it further.

Practical consequences:
> **Corrected 2026-08-08 after backtesting** (see `backtest/BACKTEST.md` §9). The reduction above is
> right in isolation and misleading in practice: the features co-vary, so `h4Slope` and the 2h/4h
> velocity terms push z up at the same time `h4Body` does. Measured on 12.4 months of real data,
> **36% of qualified signals have `h4Body` below 0.909** (median 1.070, minimum −0.327). The three
> conclusions that stood here were wrong:
>
> - "a handful of trades per month" → actually **30.7 per month**, ~1.4 per trading day.
> - "`MaximumTradesPerBrokerDay=3` will never bind" → it is the **largest entry block, 483 signals rejected**.
> - "six of eight filters are decoration" → **four bind clearly** (H4 alignment uniquely blocks 914
>   signals, path efficiency 793, velocity-strength band 595, P10 547); two are near-inert (shock 19,
>   P30 10); **two are genuinely inert** — `MaximumBadBefore10Percent` and `MinimumProbabilityEdgePct`.
>
> What survives: the P30 gate really is shadowed by P10, two inputs really are dead, and `h4Body`
> really does dominate the model by weight.

### The model penalizes velocity

`vel_24` and `vel_48` (2h and 4h M5 velocity, signed toward the trade) enter **negatively** on all three probability heads and positively on BAD. `|composite|` does too. The model's real preference is a *fresh* push: a large H4 candle in the direction, with the preceding 2–4 hours of M5 **not** yet extended.

That is a coherent strategy — it is early-stage breakout, not momentum continuation — but it is the opposite of what the product name implies, and the EA's own labelling fights it. `GV_STATE_ACCELERATING` (`acceleration > 0.15 && coherence >= 0.833`, line 350) highlights precisely the condition the model mildly *penalizes* (`accel` weight on P30 is −0.027). A user reading the panel will infer the EA wants acceleration; the coefficients say otherwise.

### The coefficients cannot be verified from this file

No training window, sample size, instrument, broker feed, out-of-sample split, walk-forward result, or calibration curve. `p10 ≥ 0.70` is a **calibrated-probability** threshold applied to a model whose calibration is unknowable from what is here. The four heads are trained independently and their outputs are not naturally ordered — the `min()` clamping at `329-330` patches that, which means P20 and P30 are frequently not the model's own outputs but P10's, and the "$20" / "$30" probabilities on the panel are then the same number as the "$10" one.

`tradeableReach = 10·(p10+p20+p30)` and `stopRiskMovement = 15·pBad` are computed and **never read anywhere**. The comment at `370-371` correctly disclaims them as not being profit targets. Delete them.

Before this trades real money: re-derive or re-validate the coefficients out-of-sample on the actual execution broker's feed, and publish a reliability diagram for P10 — that one threshold is the entire strategy.

> **Answered by the backtest.** Over 380 executed trades the probability output shows **no
> discriminative power**: expectancy by `p10` quartile runs +$1.02 / +$0.10 / +$2.87 / **−$0.79**, with
> correlation(`p10`, P/L) = **−0.036**. The highest-confidence quartile is the only losing one. `p30`
> (−0.017) and `h4Body` (−0.061) behave the same way, and relaxing `MinimumProbability10Percent` from
> 70 to 50 **raises** net profit from $304 to $421 while lowering drawdown.

---

## Medium

| # | Finding | Location |
|---|---|---|
| M1 | **Default risk geometry needs a very high strike rate.** SL $15, no TP, trail arms at +$10 with a $5 distance and a $1 step. A move that stalls just past activation exits near +$5. A flat 5:15 payoff breaks even at a 75% win rate; winners can run further, but `MaximumHoldingMinutes=240` caps how far. Users should be told this explicitly. | `411-428` |
| M2 | **ATR trail reads the forming bar.** `iATR(Symbol(),PERIOD_M1,TrailingATRPeriod,0)` — shift 0. The trail distance jitters intra-bar and contradicts the EA's own closed-bar discipline. Use shift 1. | `978` |
| M3 | `minimumStop=(STOPLEVEL+FREEZELEVEL)*Point`. Stop level and freeze level are separate broker constraints; **summing** them holds the trail further from price than required. `MathMax` is correct. | `990` |
| M4 | **`ValidateInputs()` rejects silently from six branches** (`545-556`, `562-567`) with no `Print`. The user gets `INIT_PARAMETERS_INCORRECT` and must bisect ~40 inputs by hand. Name the offending input in every reject. | `530-597` |
| M5 | **Failed closes are not retried.** `ProcessVelocityExit` runs only on an M5 bar change; if `OrderClose` hits 135/136/138/146, the exit is dropped for up to five minutes with no retry. `CloseSelectedOrder` should retry ~3× with `RefreshRates()` between attempts. | `742-759`, `1028-1040` |
| M6 | `MaximumDailyLossCurrency` counts **closed** P/L only, and only blocks the next entry — it never closes anything. An open position deep underwater does not trip it. Defensible, but the name promises a loss stop. | `673-685`, `1065` |
| M7 | **Monday dead zone.** `h4AgeHours > 12.0` rejects. After the weekend the last closed H4 bar is Friday's, so age ≫ 12 and no signal is produced until the first H4 bar of the week closes — 4–8 hours into Monday. Correct behaviour, undocumented; users will report the EA as broken. | `304-305` |
| M8 | `deviation = MathAbs(executionPrice - referenceEntry)` is **symmetric**, so it blocks a $3 favourable move as readily as a $3 adverse one. And $3 of adverse chase against a $15 stop gives away 20% of the risk budget before entry. Consider an asymmetric limit. | `788` |
| M9 | **Execution guards are loose for gold as shipped.** `MaximumSpreadMovement = 2.0` ($2.00, against a typical $0.15–$0.40 gold spread) and `MaximumEntryDeviationMovement = 3.0`. Neither will fire outside a news dislocation. | `449-450` |

---

## Low / hygiene

- **Dead code.** `ClampValue()` defined and never called (`497`). `GV_TARGET_MOVEMENT`, `GV_TARGET_HORIZON_MIN` defined and never used. Ten `GVResult` fields assigned and never read: `tradeableReach`, `stopRiskMovement`, `confidence`, `atrM5`, `velocityM5`, `velocityM15`, `velocityH1`, `pathQuality`, `velocityStrength`, `shockRatio`. `ArrayInitialize(velocity,0.0)` at `259` is overwritten on the next line.
- **Naming drift between engine and UI.** `thresholds.minimumContinuation` is commented "P($10 before $15 stop)" and gates `p10`, but the panel's "CONTINUATION" reads `result.continuationProbability = 1 − pBad` — two different quantities under one name. `minimumEfficiencyM15` is fed by `MinimumH1PathEfficiencyPct` and gates `efficiency12` (12 M5 bars = 1 hour); the H1 label is right, the M15 field name is wrong. `GV_STATE_EXHAUSTING` renders as "STOP RISK".
- **State/label disagreement.** `GV_STATE_H4_CONFLICT` is unreachable when `RequireClosedH4Alignment=false` (`334`, `345`), yet the panel prints "H4 CONFLICT" independently from `h4Alignment > 0.0` (`1264`).
- **A single flat bar kills the signal.** `GVTrueRange` returns 0.0 on a degenerate bar and `GVATR` propagates that to 0.0, aborting the whole calculation (`223-233`). Quiet rollover or a feed gap silently skips the bar. Fails safe, but silently.
- `PositionKey()` (`704-707`) depends on an order already being selected, with nothing enforcing it. Pass the ticket in.
- `UpdatePanel` selects the same order twice to build one string (`1256-1260`).
- `NormaliseLots` caps at `MODE_MAXLOT` with no warning (`520`) — in risk-percent mode on a large account, realized risk quietly falls below the configured percent.
- `EnableEntryPopupAlert = true` by default fires a **modal** `Alert()` on every entry on a live account (`910`).

---

## What is done well

Worth stating, because these are the things retail EAs usually get wrong:

- **No lookahead, no repaint.** Closed-bar discipline is real and correctly implemented, including the H4 back-step and the staleness bound.
- **`NormaliseLots` refuses to round *up*.** `if(requested < minimum-1e-10) return(0.0)` (`518`) — it will not silently inflate a sub-minimum request to the broker minimum. `CalculateLots` does the same (`728`). Most EAs quietly over-risk here.
- **`GetLastError()` captured once** into `firstError` before reuse (`844`), rather than being re-read after it has been cleared.
- **`EnableAutomaticEntries` defaults to false.** Ships in signal-only mode.
- **No hidden dependencies.** Verified: no `#import`, no DLL, no `FileOpen`/`FileWrite`, no `WebRequest`, no obfuscation, no account-number check, no expiry logic. The only outbound call is `SendNotification` (MT4-native push, off by default). The header's "No DLL, file, network or Python dependency" claim is accurate.

---

## Recommended order of work

1. **H1** — stop-loss reconciler in `ManagePositionEveryTick`. Blocks live use.
2. **H2** — slippage in price units. Blocks live use on 3-digit feeds.
3. **H3 + H4** — cache the day counters, throttle the panel, remove the GlobalVariable dependency. Blocks any credible backtest.
4. **M4** — named validation errors, so the next four items are diagnosable at all.
5. **M2, M3, M5** — trailing and close-retry correctness.
6. Re-validate the model coefficients out-of-sample, then revisit the default thresholds knowing that `MinimumProbability10Percent` is the only one that does anything.
7. Delete the dead fields and fix the naming drift.

**Not yet done:** the file has not been compiled or run. After the fixes above, it needs a MetaEditor build under `#property strict`, then a tick-data backtest on the target broker's gold feed, then forward testing on demo.
