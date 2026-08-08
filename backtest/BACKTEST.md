# Profitability backtest — XVISION_Gold_Velocity_AI_EA_V4.mq4

**Date:** 2026-08-08
**Data:** the five supplied MT4 gold exports (M1/M5/M15/M30/H1)
**Method:** independent Python re-implementation of the EA. **This is not MetaTrader's Strategy Tester** — no MetaEditor exists on the review machine. Every number below comes from a port whose validation is documented in §2.

---

## Verdict

**The EA is close to break-even, and this data cannot establish that it is profitable.**

Under the shipped defaults it returns **+$304 on a $10,000 account over 12.4 months** (380 trades, PF 1.15, 58.7% win rate, 2.15% max drawdown). But:

- Changing one unresolvable modelling assumption — the order in which price touches the bar's extremes — moves the result to **−$85**. The sign of the answer is not determined by the data.
- The result is **not statistically distinguishable from zero** (t = 1.21; bootstrap 95% CI −$182 to +$797; 11% of resamples are losses).
- **All of the profit is in the first half.** First 190 trades +$303; second 190 trades +$0.70.
- **The model's own probability output does not rank outcomes.** Trades in the highest `p10` quartile lose money; the lowest quartile makes money. Loosening the flagship filter from 0.70 to 0.50 *increases* net profit.
- Buy-and-hold on the same 0.01 lot returned **+$927** over the same window.

The management layer is sound and the entry engine is correctly implemented. What is missing is evidence that the entry signal is better than a coin flip.

---

## 1. Setup

| | |
|---|---|
| Instrument | Gold, 2-decimal feed (so `Point` = 0.01 and `SlippagePoints=50` = $0.50 — the audit's H2 bug is not triggered by this broker) |
| Engine window | M5 bars, 2025-07-24 → 2026-08-07 (377 days, 66,274 bars) |
| H4 confirmation | rebuilt from the 10-year H1 series (30,499 bars back to 2016), bucketed 00/04/08/12/16/20 as MT4 does |
| Intrabar path | M1 bars where available (2026-04-06 →, 113 of 380 trades); M5 bars before that |
| Contract | 100 oz/lot, 0.01 fixed lots, $10,000 start |
| Costs | spread $0.30 default, swept $0.00–$0.80; commission and entry slippage swept separately |
| Inputs | shipped defaults throughout, **except `EnableAutomaticEntries` forced true** (it ships false, so the EA as delivered takes no trades at all) |

**Two holes in the M5 feed.** 2026-04-13 → 2026-05-06 (22.7 days) and 2025-10-21 → 2025-11-03 (13.3 days). 11,740 M5 bars were excluded because their 49-bar lookback window spans a hole; MT4 would happily compute velocity features across the gap and produce garbage, so excluding them is the more favourable treatment, not the harsher one.

---

## 2. Validating the port

A backtest is only as good as its engine. Four checks:

1. **H4 reconstruction is exact.** Comparing H4 built from H1 against H4 built from M5, restricted to the 1,192 buckets complete in both feeds: open, high, low and close all agree to **$0.000**. The only three mismatching buckets straddle the M5 feed's own gaps, where H1 is the better source.
2. **Feeds are mutually consistent.** Aggregating M5 → H1 and comparing to the H1 file over 5,531 overlapping bars: mean close difference $0.007, only 3 bars above $0.05 (all at gap edges).
3. **Data is clean.** No duplicate timestamps, no OHLC violations, no zero-range bars in any of the five files.
4. **A harness bug was found and fixed before any result was reported.** The first version of the qualification helper wrote `~require_h4` on a Python `bool`, which evaluates to `-2` (truthy) rather than `False`, silently disabling the H4-alignment gate. It was caught by cross-checking the qualified-signal count two different ways (3,054 vs 2,140). Every number in this document is post-fix.

Engine output: **54,507 valid signal bars, 2,140 qualified** (3.93% of valid bars).

---

## 3. Baseline result

| Ordering assumption | Trades | Net | PF | Win | Max DD | Expectancy |
|---|---:|---:|---:|---:|---:|---:|
| Stop checked before trail advances | 380 | **+$303.93** | 1.150 | 58.7% | $214.66 | +$0.80 |
| Trail advances before stop is checked | 382 | **−$85.27** | 0.958 | 59.2% | $299.08 | −$0.22 |

Both are legitimate readings of the same OHLC bars. Real price touches the extremes in *some* order that neither assumption knows, and the true result lies between them. **The bracket straddles zero, so the backtest does not answer the profitability question** — it bounds it.

M1 data narrows but does not close the gap. On the window where M1 exists (2026-04-06 →, 113 trades), both orderings are losses: −$125 (stop-first) and −$203 (trail-first). The coarser M5 path model is optimistic by $0.33/trade there under stop-first, which is roughly $88 of the headline $304 once applied to the 267 pre-M1 trades.

Exits: 191 trailing stop, 126 initial stop, 63 time stop. Entry blocks: **483 by the 3-trades-per-day cap**, 27 by cooldown, 3 by the deviation guard.
30.7 trades/month. 230 long, 150 short. Time in market 12.0%.

---

## 4. The result is inside the noise

| | |
|---|---|
| Per-trade expectancy | +$0.80 on $13.07 standard deviation |
| t-statistic | **1.208** |
| Bootstrap 95% CI on net P/L | **[−$182, +$797]** |
| Share of bootstrap resamples that lose money | 11.0% |
| Spread actually paid | $114 of a $418 gross edge |

**Split-half:**

| Half | Trades | Net | PF | Win | Expectancy |
|---|---:|---:|---:|---:|---:|
| 2025-07-25 → 2026-01-26 | 190 | +$303.23 | 1.387 | 61.6% | +$1.60 |
| 2026-01-27 → 2026-08-06 | 190 | **+$0.70** | 1.001 | 55.8% | +$0.00 |

The entire result is the first six months. The second six months are break-even to the cent. That is what an unstable edge looks like.

**Random-direction control** — same entry times, same management, direction replaced by a coin flip, 300 runs: mean +$60, sd $235. The real model's +$304 sits at the **84th percentile** of that distribution. Better than a coin flip, but not by a margin that survives scrutiny (p ≈ 0.16 one-tailed).

---

## 5. The model does not rank outcomes

This is the most important finding, and it is independent of every costing assumption.

If the probability heads were informative, trade quality would rise with `p10`. Quartiles of the 380 executed trades:

| Quartile | n | Expectancy | Win rate |
|---|---:|---:|---:|
| Q1 (lowest p10) | 95 | **+$1.02** | 60.0% |
| Q2 | 95 | +$0.10 | 57.9% |
| Q3 | 95 | +$2.87 | 65.3% |
| Q4 (highest p10) | 95 | **−$0.79** | 51.6% |

correlation(p10, trade P/L) = **−0.036**. Flat and slightly inverted. The same holds for `p30` (Q4 −$0.51, corr −0.017) and for `h4Body`, the feature the audit identified as carrying the whole model (Q1 +$1.11, Q4 −$0.13, corr −0.061).

The parameter sweep says the same thing from the other direction:

| `MinimumProbability10Percent` | Trades | Net | PF | Max DD |
|---|---:|---:|---:|---:|
| 50 | 458 | **+$420.54** | 1.175 | $196.95 |
| 60 | 456 | +$402.61 | 1.168 | $196.95 |
| 70 *(shipped)* | 380 | +$303.93 | 1.150 | $214.66 |
| 80 | 222 | +$166.65 | 1.143 | $123.81 |

**Filtering harder makes the result worse and the drawdown no better.** A threshold that selects for quality should do the opposite. This is the concrete form of the audit's warning that the coefficients are unverifiable: on this data they carry no demonstrated discriminative power.

---

## 6. Cost sensitivity

| Spread | Net | PF |
|---|---:|---:|
| $0.00 | +$399.65 | 1.203 |
| $0.15 | +$351.27 | 1.175 |
| $0.30 | +$303.93 | 1.150 |
| $0.50 | +$260.29 | 1.128 |
| $0.80 | +$114.88 | 1.055 |

Adding $0.20 of entry slippage costs $66. Commission at $14/lot round turn costs $36. The strategy survives realistic gold spreads under the stop-first assumption but has no margin: the gross edge is $418 over 380 trades, or **$1.10 per trade — 1.1 cents of gold movement**.

---

## 7. Every default is beatable

Held to the same stop-first assumption and $0.30 spread:

| Variant | Trades | Net | PF | Max DD |
|---|---:|---:|---:|---:|
| **Shipped default** (SL 15, trail 10/5) | 380 | +$303.93 | 1.150 | $214.66 |
| No time stop | 373 | **+$583.25** | 1.280 | $181.76 |
| No 3-per-day cap | 520 | **+$663.75** | 1.245 | $219.73 |
| SL 15, fixed TP 30, no trailing | 360 | +$492.06 | 1.201 | $277.99 |
| SL 10, trail 10/5 | 396 | +$397.61 | 1.229 | **$126.88** |
| SL 15, trail 5/3 | 402 | +$375.61 | **1.265** | $122.26 |
| SL 20, trail 10/5 | 369 | +$372.41 | 1.184 | $251.62 |
| Sells only | 151 | +$238.19 | 1.294 | $117.99 |
| Buys only | 231 | +$56.32 | 1.046 | $235.96 |

Both shipped throttles — `MaximumHoldingMinutes=240` and `MaximumTradesPerBrokerDay=3` — **cost money** in this sample. So does the trailing configuration: a tighter trail (5/3) produces a higher profit factor, a 73% win rate and *half* the drawdown. A tighter initial stop (SL 10) does the same.

Read this cautiously in both directions. These are 380-trade samples inside a result that is already indistinguishable from zero, so the differences between rows are not significant either. The honest conclusion is not "use trail 5/3" — it is that **the shipped defaults are not a tuned configuration**, and nothing in the sample suggests they were chosen against this instrument's behaviour.

---

## 8. Benchmark and risk framing

Lot size is arbitrary, so the return percentage is meaningless on its own. In units of R (the $15 initial stop):

- **+0.053 R per trade**, +20.3 R over 380 trades, 14.3 R maximum drawdown.
- Sized at 1% risk per trade that is **+20.3% over 377 days with a 14.3% peak-to-trough drawdown** — a respectable ratio *if the edge were real*, which §4 and §5 say it is not established to be.
- Gold moved 3366.50 → 4293.90 over the window. **Buy-and-hold on the same 0.01 lot: +$927.40**, versus the EA's +$304, with the EA in the market only 12% of the time.

---

## 9. Corrections to the audit

The backtest contradicts three claims in my earlier audit. The ceteris-paribus method I used there — solving each gate with all other features at their training mean — was misleading, because the features co-vary: when `h4Body` is large, `h4Slope` is also large (same sign weight) and the 2h/4h velocity features sit below their means (opposite sign weight), so the required `h4Body` in live data is far below the isolated figure.

| Audit claim | Actual |
|---|---|
| "Expect a handful of trades per month, not per day" | **30.7 trades/month** (~1.4 per trading day) |
| "`MaximumTradesPerBrokerDay=3` will effectively never bind" | It is the **single largest entry block — 483 signals rejected** |
| "Six of the eight model filters are decoration as shipped" | **Four bind clearly**, two are near-inert, two are fully inert (see below) |
| "reduces to `h4Body` ≥ 0.909" | Correct in isolation, but **36% of qualified signals have `h4Body` < 0.909** (median 1.070, minimum −0.327) |

Measured marginally — signals that pass every other gate but fail this one:

| Gate | Uniquely blocks | Verdict |
|---|---:|---|
| `RequireClosedH4Alignment` | 914 | binds |
| `MinimumH1PathEfficiencyPct` | 793 | binds |
| velocity-strength band | 595 | binds |
| `MinimumProbability10Percent` | 547 | binds |
| `MaximumShockRatio` | 19 | near-inert |
| `MinimumProbability30Percent` | 10 | near-inert (shadowed by the P10 gate, as the audit said) |
| `MaximumBadBefore10Percent` | 0 | **inert** |
| `MinimumProbabilityEdgePct` | 0 | **inert** |

What survives from the audit unchanged: `h4Body` dominates the model by weight; two inputs are genuinely inert; and the coefficients cannot be validated from the source. §5 now supplies the empirical version of that last point — they do not rank outcomes on this data.

---

## 10. Limitations

Stated plainly, because they bound what this exercise can claim:

1. **Not MetaTrader.** An independent port, validated as in §2, but not the Strategy Tester. Differences in `iMA` seeding, `iBarShift` edge cases, or broker-specific `MODE_STOPLEVEL` behaviour would move the numbers.
2. **No tick data.** The intrabar ordering assumption is the largest single source of uncertainty and it flips the sign of the result. Real tick data would collapse the bracket in §3 and is the *single highest-value next step*.
3. **No real spread series.** Spread is modelled as constant. Real gold spreads widen at rollover and on news — exactly when `shock` is high and this EA is willing to trade. A time-varying spread would hurt more than the flat sweep in §6 suggests.
4. **12.4 months, one instrument, one regime** — a strong gold bull market. 380 trades is a small sample for a per-trade edge this size.
5. **Two feed holes** totalling 36 days, ~10% of the window.
6. **Swap/financing ignored.** Median hold is 1.25 hours, so this is immaterial except for the 18 trades held across weekends (whose net contribution is +$1.74).

---

## 11. What to do next

1. **Get tick data for the same window and re-run.** Until the §3 bracket collapses, no configuration decision is supportable. This is the only step that changes what is knowable.
2. **Fix audit H1 and H3 before any MT4 tester run.** The per-tick history scans make a multi-year backtest in MT4 impractical, and the naked-stop path is a live-trading blocker regardless.
3. **Re-derive the model, or drop it.** §5 shows the probability heads add nothing on this data. Either retrain on this broker's feed with a proper out-of-sample split and a reliability diagram for P10, or strip the model and trade the H4-body condition directly — it is what the coefficients are already doing, and it would be testable.
4. **Do not tune on this sample.** §7 shows several variants beating the default, but every one of them sits inside the same noise band. Re-tuning here is curve-fitting a 380-trade sample.
5. **If it is traded at all, trade it small and forward.** The measured edge is +0.05 R/trade with no demonstrated stability across halves.

---

*Reproduction: `engine.py` (GVCalculate port), `sim.py` (execution/management), `final.py`, `discrim.py`. Trade-by-trade output in `trades_final.csv`.*
