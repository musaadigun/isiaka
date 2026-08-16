# Research — EMA50 cross on GOLD M5

Scripts that measured the bare EMA50 close-cross on the supplied GOLD M5 export
(66,274 bars, 2025-07-24 → 2026-08-07, price 3269 → 5589).

```
00_ema_proof.py      proves the EMA matches MT4's own recursion, bit for bit
01_cross_stats.py    cross counts, forward returns vs baseline, hold time, MFE/MAE
02_cost_and_oos.py   spread sensitivity, first-half vs second-half split, SL/TP grid
03_filters.py        persistence filter, H1 trend alignment, buy-and-hold sanity check
04_cross_frequency.py  per-session cross counts, worked example day, reconciliation
```

Point the `CSV` constant at the export and run with pandas + numpy.

## Is the EMA right?

`00_ema_proof.py` answers this, because the whole study rests on it.

MT4's `Moving Average.mq4` computes `EMA[i] = Price[i]*a + EMA[i+1]*(1-a)` with
`a = 2/(N+1)`. For N=50 that is `a = 2/51 = 0.0392156863`. Running that recursion
longhand against `pandas.ewm(span=50, adjust=False)` over all 66,274 bars gives a
**maximum difference of 0.000e+00** — the two are the same calculation.

The starting value does not matter either. Seeded three ways (MT4's first-price
seed, an SMA(50) seed, and a deliberately absurd seed $500 off), all three agree
to under a cent by bar 200 and produce **identical cross counts**. The study drops
the first 200 bars for exactly this reason.

Cross count by period, as a sanity check that the counter responds sensibly:

| EMA period | Crosses | Per session |
|---|---|---|
| 20 | 9,239 | 40.5 |
| 50 | 5,719 | 25.1 |
| 100 | 3,887 | 17.0 |
| 200 | 2,863 | 12.6 |

## Findings

**The bare cross is not tradeable.**

| Measure | Result |
|---|---|
| Crosses | 5,719 (~23 per trading session) |
| Reverse within 1 bar / 3 bars | 29% / 50% |
| Median MFE ÷ median MAE | 0.91–1.04 (symmetric) |
| Long cross, **zero** cost | −$0.09 per trade |
| Short cross, zero cost | +$0.28 per trade (t = 1.36, not significant) |
| Short cross, $0.30 spread | −$0.02 per trade |
| Spread on all 5,719 crosses | $1,716 vs $919 for buying and holding |

No SL/TP combination in a 5×5 ATR grid was meaningfully positive. Every filter
tried (EMA slope, cross size, ATR regime, hour, k-bar persistence, H1 alignment)
either lost outright or **flipped sign between the first and second half of the
sample** — the signature of curve-fitting, not edge.

## Methodology notes

- Entry at the *next* bar's open, never the signal bar's close.
- Forward windows spanning a gap > 60 min (weekends) are excluded.
- First 200 bars dropped so the EMA can settle.
- When both stop and target fall inside one bar, the stop is assumed to fill
  first.
- H1 trend context is resampled from the same M5 data and shifted one bar to
  avoid lookahead.

## Frequency: two correct answers

Counting per **calendar day** (378, weekends included) gives 15.1/day. That
denominator is wrong — gold does not trade at weekends. Over the **244 real
trading sessions** in the file it is **23.4 per session**; over the 228 full
sessions (≥250 bars) it is 25.1. Median 24, quietest day 5, busiest 51.

The eye counts far fewer because most crosses are invisible at chart zoom. On
2025-07-28 four crosses landed between 14:45 and 15:05 with price sitting $0.09
to $1.28 from the EMA — one pixel on a two-day chart, but four real signals to
an EA. Requiring a cross to eventually travel 2×ATR past the EMA cuts 5,719 down
to 1,347 (5.5/session), which is roughly what a chart reader counts.

That margin filter is **descriptive only**. It asks how far price went *after*
the cross, so it cannot be used to select entries in real time.

## Bug worth remembering

The first run reported 35,520 up-crosses against 2,866 down-crosses — impossible,
since the two must alternate. Cause: in pandas, `Series.shift()` on a boolean
column returns **object** dtype, and `~` on Python bools does arithmetic negation
(`~True == -2`, `~False == -1`), both truthy. The "not previously above" mask was
always `True` and the signal silently became "close is above the EMA". Cross
detection here uses numpy boolean arrays instead. Always assert that up-crosses
and down-crosses differ by at most one.
