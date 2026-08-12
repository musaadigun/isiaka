# Product Report — GoldSeek Adaptive EA v3

**Product:** GoldSeek Adaptive EA v3 ("XVISION | GOLD SEEK ADAPTIVE V3")
**Platform:** MetaTrader 4 · **Instrument:** XAUUSD · **Timeframes:** M5 structure, M1 tracking
**Assessed:** 2026-08-12, from source only — no backtest, forward test, or performance data was supplied.

---

## 1. Verdict

| | |
|---|---|
| **Engineering quality** | Strong. Clean state machine, real crash recovery, no repainting, disciplined numerics. |
| **Signal quality** | Unproven, and simpler than it presents. |
| **Risk controls** | **The weakest part of the product.** Four independent paths to a loss larger than the configured stop. |
| **Ready to sell?** | **No.** |
| **Ready to forward-test on a demo?** | Yes, after four small fixes (P0-1, P0-2, P0-3, P0-4 in `AUDIT.md`). |

The build reads like a serious piece of work by someone who knows MQL4 well. The gap is not
competence — it is that the risk layer was left as an exercise and the model layer is carrying
more presentation than mechanism.

---

## 2. What the product actually is

Stripped to what drives decisions, the EA is:

> **An EMA20/EMA30 ribbon trend filter on M5, gated by ATR expansion, requiring three-way
> agreement between ribbon slope, price-to-EMA gap, and 3-bar velocity — entering with a fixed
> $20 stop, no take-profit, and exiting on an evidence-decay rule.**

That is a legitimate, recognisable strategy. It is not what the file presents itself as.

**Everything that decides direction** flows through `structuralScore` (line 426): an equal-weight
average of four winsorized z-scores (EMA gap, structural location, ribbon velocity, 3-bar
velocity). It selects the side, gates the entry, and carries the largest weight in every
downstream score (0.88 of `directionalLogit`, 0.46 of `instantEvidence`).

**Everything else is a modifier or is inert:**

| Component | Presented as | Actual influence on the trade decision |
|---|---|---|
| Two-sided barrier probability, first-passage-by-horizon, Abramowitz–Stegun CDF | Core probability engine | **≤ 3.7% of the entry threshold** (see §3) |
| 5-mode IMM regime classifier (noise/drift/impulse/exhaustion/shock) | Regime awareness | Real but modest — damping and score adjustments |
| Dual-direction tracker scoring | "Dual-direction pursuit engine" | **Dead for direction selection** (AUDIT P2-1); live only as an entry filter |
| Online Bayesian calibration | Learns from live outcomes | **Provably stops learning** (AUDIT P1-1) |
| CUSUM change detection | Regime break detection | Small: 0.05 coefficient in the logit, 0.07 in evidence |

None of this makes the strategy bad. It makes the *description* of the strategy inaccurate, which
is a commercial liability the moment a customer with quant literacy reads the code.

---

## 3. The sophistication is decorative — quantified

The EA computes eight `DestinationProbability` values every M1 bar (lines 777–784). Each one runs
two first-passage formulas, a normal CDF, and several exponentials.

**Six of the eight are never read.** `DirectionRawProbability` is only ever called with
`target = 30` (lines 609, 674), so the 10/20/50-dollar probabilities are computed and discarded.

The two that *are* read enter the decision through a single coefficient:

```c
offline = 0.055 + 0.050*structuralQuality + 0.025*energyQuality
        + 0.012*Clamp(rawP30,0,1) + 0.008*max(0,m1Tracking) - 0.020*chaseRisk;   // line 619
```

Tracing `rawP30`'s maximum possible influence through to the entry gate:

| Step | Bound |
|---|---|
| Contribution to `offline` | ≤ 0.012 |
| → `probabilityQuality` = `(cal − 0.04)/0.13` | ≤ 0.092 |
| → `opportunityScore` (weight 0.12) | ≤ 0.011 |
| → as a share of `MIN_OPPORTUNITY_SCORE` = 0.30 | **≤ 3.7%** |

The entire stochastic-process layer can move the entry decision by less than four percent of the
threshold it feeds. A customer paying for "causal probability modelling" is paying for a rounding
term.

**Related:** the "frozen train-only standardization" at lines 420–427 has no learned weights. It
is a plain unweighted mean of four standardized inputs. The only fitted artifacts in the entire
file are eight winsorization bounds, four means, and four standard deviations.

---

## 4. Overfitting signals

**`STRUCTURAL_SCORE_THRESHOLD = 0.7629589434`** (line 99). Ten significant figures on a threshold
applied to a four-term average. Nothing about this problem supports precision past the second
decimal; the digits are an artifact of a fitting procedure copied verbatim. In a commercial
product this reads as a number tuned until a backtest looked right.

For scale: on the mean of four unit-variance inputs, 0.763 sits between **0.76σ** (if the four
features were perfectly correlated) and **1.53σ** (if independent). The truth is nearer the
correlated end — EMA gap, ribbon velocity and 3-bar velocity all measure the same underlying
move — so the gate is roughly a **one-sigma trend filter**, dressed as a calibrated threshold.

The code's own comments reference *"the supplied GOLD M5 data"* and *"the supplied holdout"*
(lines 420, 616–618). That the author held out data is a good sign. **None of that evidence
accompanies the product**, so none of it can be claimed to a customer.

---

## 5. Risk and payoff geometry

**The advertised benchmark is not implemented.** `BENCHMARK_QUALIFYING_MOVE_USD = 50.0` and
`BENCHMARK_REVERSAL_USD = 15.0` (lines 95–96) appear nowhere else in the file. The panel's
`"BENCHMARK $50 LEG | $15 REVERSAL"` (line 2018) is a hardcoded display string. No code path
targets a $50 leg or enforces a $15 reversal rule.

**The entry bar is well below the risk taken.** The EA will accept a trade whose own model says
only **$7.50** of travel remains (`MIN_REMAINING_TRAVEL_USD`, line 102) while risking **$20**
(default `StopLoss_PriceUSD`, line 12). At that margin the geometry is roughly 2.7:1 against,
requiring a ~73% hit rate merely to break even before costs. Typical qualifying trades will sit
better than the margin — but the margin is where a threshold system spends much of its time.

**There is no take-profit by default** (line 13). Exits are entirely model-driven. This is a
coherent trend-following choice: losses are bounded near $20 (or the model's $8–20 adverse
boundary, line 1675) and the payoff depends on a right tail. Credit where due — the exit rules are
built to *protect* that tail: the stale-horizon exit only fires when MFE < $15 (line 1712), and
failure-to-launch requires three invalidation bars plus weak evidence (lines 1689–1691). Winners
are not cut short by design.

**But the cost structure is unbounded**, which is exactly what kills a thin trend-following edge:
unlimited slippage on entry ($10,000 tolerance on 2-digit gold, line 90) and no maximum-spread
veto anywhere. The panel displays the spread; nothing acts on it.

**And "UNCAPPED" is printed as a feature.** The panel renders the day's entry count followed by
the literal string `" (UNCAPPED)"` (lines 2074, 2094). There is no daily loss limit, no
consecutive-loss cooldown, and no maximum trades per day — while the code re-arms the entry state
machine on the same tick as a close (lines 1796–1801, 2185). Any prospective buyer who asks "what
stops it losing ten times in a chop?" has no answer in this build.

---

## 6. Expected live behaviour

**Trade frequency will be low, and will fall over time.** Entry requires the simultaneous
satisfaction of roughly eight conditions: structural score ≥ 0.763, structural direction match,
ATR expansion ≥ 0.90, ATR acceleration > 0, three-way motion alignment, remaining travel ≥ $7.50,
opportunity score ≥ 0.30, exhaustion risk ≤ 0.78, and no strong contradiction.

Then the calibration ratchet tightens it further. Because the calibration target ($30 MFE) is
structurally unreachable under a $20 stop, nearly every trade is labelled MISS, and the resulting
posterior decay removes up to 0.12 of an `opportunityScore` that only clears its 0.30 gate by
≈0.085 in the first place (see `AUDIT.md` P1-2, with a reproducer in
`calibration_reproducer.py`).

**Practical consequence for a customer:** the EA gets quieter the longer it runs, for reasons
invisible from the panel, and the only way to reset it is to hand-delete terminal global
variables. Expect support tickets reading *"it stopped taking trades."*

---

## 7. Claims you can and cannot make

**Defensible today:**
- MT4 EA for XAUUSD, M5 structure with M1 tracking, one position at a time.
- Trend-following entries on an EMA20/30 ribbon with ATR-expansion confirmation.
- Fixed-dollar stop, optional profit lock and trailing, user-owned exit settings.
- Survives terminal restarts and reconciles its state against the broker.
- Uses only closed bars — **no repainting**. This one is worth saying out loud; it is verifiable
  in the source and most competitors cannot claim it.
- Writes a per-trade telemetry CSV for independent auditing.

**Not defensible without evidence you do not currently have:**
- Any win rate, drawdown, profit factor, or return figure.
- "Adaptive" / "learns from live outcomes" — the learning loop is broken (P1-1).
- "$50 leg / $15 reversal benchmark" — not implemented.
- "Probability-calibrated" / "causal probability engine" — the probability layer moves the
  decision by under 4%.
- "Dual-direction pursuit engine" — direction selection is a single structural sign test.
- Anything implying capped or known risk per day.

---

## 8. Path to a sellable product

**Stage 1 — make it safe (est. 1 day).** AUDIT items P0-1 through P0-4: send stops with the order,
add a daily loss cap and post-loss cooldown, cap entry slippage and add a max-spread gate, and
guard the instrument. Nothing here touches the model.

**Stage 2 — make it honest (est. 2–3 days).** Fix the calibration bin mismatch (one line), give the
counters a decay and a reset, redefine the calibration label to something reachable, and delete the
inert probability computations or wire them in properly. Then rewrite the product description to
match what the code does. A clear "EMA ribbon + ATR expansion trend system with evidence-based
exits" is an easier product to sell honestly than a "causal probability engine" that a technical
customer can disprove in twenty minutes.

**Stage 3 — make it provable (est. 4–8 weeks, and this is the real gate).**
- Tick-data backtest with realistic spread and commission, over ≥ 3 years including 2020 and 2022
  gold regimes. Modelling quality 99% — with unlimited slippage in the code, any backtest at lower
  quality is meaningless.
- Walk-forward validation. Re-derive the standardization constants and the structural threshold on
  each in-sample window rather than reusing `0.7629589434`; if performance survives that, the
  threshold is real, and if it doesn't, you have learned something important cheaply.
- **90 days minimum of demo forward-testing** on the intended broker, with the telemetry CSV as
  the record. Given the low expected trade frequency, a shorter window will not produce a
  meaningful sample.
- Publish the resulting statistics — trade count, win rate, average win/loss, max drawdown,
  profit factor — alongside the exact build they came from.

Stage 3 is not optional. Everything before it is engineering; only Stage 3 produces a claim that
survives contact with a customer.

---

## 9. One-line summary

**Well-built infrastructure and a reasonable trend-following core, wrapped in probability
machinery that does almost nothing, with no daily loss limit, no spread control, no instrument
guard, and a learning loop that shuts itself off — fix the four safety items and forward-test it
before any of it is sold.**

---

*Companion document: `AUDIT.md` (21 findings, line-referenced). Reproducer for the calibration
findings: `calibration_reproducer.py`. Audited source: `GoldSeekAdaptiveEA_v3.mq4`.*
