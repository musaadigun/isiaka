# Research — EMA50 cross on GOLD M5

Scripts that measured the bare EMA50 close-cross on the supplied GOLD M5 export
(66,274 bars, 2025-07-24 → 2026-08-07, price 3269 → 5589).

```
01_cross_stats.py    cross counts, forward returns vs baseline, hold time, MFE/MAE
02_cost_and_oos.py   spread sensitivity, first-half vs second-half split, SL/TP grid
03_filters.py        persistence filter, H1 trend alignment, buy-and-hold sanity check
```

Point the `CSV` constant at the export and run with pandas + numpy.

## Findings

**The bare cross is not tradeable.**

| Measure | Result |
|---|---|
| Crosses | 5,719 (~15 per day) |
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

## Bug worth remembering

The first run reported 35,520 up-crosses against 2,866 down-crosses — impossible,
since the two must alternate. Cause: in pandas, `Series.shift()` on a boolean
column returns **object** dtype, and `~` on Python bools does arithmetic negation
(`~True == -2`, `~False == -1`), both truthy. The "not previously above" mask was
always `True` and the signal silently became "close is above the EMA". Cross
detection here uses numpy boolean arrays instead. Always assert that up-crosses
and down-crosses differ by at most one.
