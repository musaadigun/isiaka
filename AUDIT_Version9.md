# Audit — GoldScalperM1M5_Version9.mq4

Third full audit. v8 added the per-trade dataset and excursion
tracking; v9 added the M5 trend filter. Both touched state that
persists across restarts and across a ticket change, so the audit
concentrated there, then re-checked the machinery earlier audits
cleared.

**Six bugs found, all six fixed in Version 10.** No trading rule was
altered — every fix restores intended behaviour or corrects a claim I
made that the code did not honour.

Severity: **M** = affects live behaviour or the data you tune from ·
**L** = cosmetic or tooling.

---

## B1 (M) — An armed trend filter can sit silently blocked

`OnTick` gates all evaluation behind `iBars(M5) > 40`. A 50-period EMA
needs at least 50 M5 bars before `iMA` returns anything. Between 41 and
55 M5 bars, `UpdateTrend()` bails, `g_trendDir` stays 0, and with
`TrendFilterMode = 1` **every entry is refused** with `no M5 trend`.

It fails safe, but silently: on a fresh chart, after a history gap, or
on a symbol whose M5 history is thin, the EA looks alive and simply
never trades, and the panel gives no hint that history is the cause.

**Fixed.** The M5 requirement now scales with `M5TrendEMAPeriod` when
the filter is armed, and the panel reports the shortfall directly —
`history M1 412/81, M5 47/56` — instead of a bare gate name.

---

## B2 (M) — The adverse excursion was carried by accident

v7 made a ticket change (MT4 re-tickets the remainder of a partial
close) carry the favourable excursion forward explicitly. v8 added the
adverse one but never added it to that carry.

It appeared to work only because `AdoptTicket()` finds no stored
values for a brand-new ticket, so the feature array still happened to
hold the previous trade's MAE, which `MathMin` then picked up. That is
incidental, not designed: it breaks the moment the ordering changes or
the ticket carries stale state — and the `mae` column for any
partially-closed trade is exactly the number the excursion diagnostic
depends on.

**Fixed.** Both excursions cross explicitly, and the persistence write
happens only if something actually carried.

---

## B3 (M) — Documentation contradicted the shipped default

I wrote, in the README and to you directly, that "a flat EMA in chop
reports no side, so the filter refuses rather than flipping on every
touch."

With the shipped default `TrendSlopeMinATR = 0.00` the test is
`slope >= 0`, so a flat — or barely rising — EMA **does** report a
side. The behaviour I described requires a positive slope threshold.

**Fixed** by correcting the claim rather than silently changing how it
trades: the input now documents that 0 means side-of-line only, and
that raising it is what makes chop report no side.

---

## B4 (L) — The panel lost ATR M5 and expansion

v9 repurposed the ATR row for the trend readout, so `atr_m5` and the
volatility expansion ratio disappeared from the panel entirely. ATR M5
is the unit that both the maturity figure and the trend distance are
quoted in, so losing it made those two numbers hard to interpret.

**Fixed.** The row now carries trend, distance, ATR M1, ATR M5 and
expansion together.

---

## B5 (L) — The analyser could not read the columns v9 added

`trend_dir` and `trend_dist_atr` were missing from the numeric list, so
they stayed strings: `--bucket trend_dist_atr` failed and trend
outcomes could not be split at all.

**Fixed**, and a dedicated breakdown added — trades **with** the trend
versus **against** it versus **no trend** — which is the specific table
that decides whether `TrendFilterMode = 1` is worth arming.

---

## B6 (L) — Backtester trend warm-up

`ema_close` seeds from `period × 4` bars back and silently falls back
to the oldest available bar when there are fewer. Before ~204 M5 bars
accumulate, the shift-1 and shift-2 EMAs could seed from different
points, making the early slope reading noise rather than signal.

**Fixed.** The engine reports no trend until the EMA has genuinely
warmed up, mirroring the EA.

---

## Re-verified, still correct

- The dataset schema is sound: 31 header fields, 31 row fields, in the
  same order, verified field by field.
- `SnapshotEntryFeatures` runs before `AdoptTicket` on every entry
  path, so a new ticket keeps the conditions it was opened in while an
  adopted one restores its own.
- The trend gate's else-if chain is correct, and the mode-2 distance
  test only runs once direction already agrees.
- Every gate still honours its off switch; the evaluator still returns
  a direction only when the failure list is empty.
- Stops still only tighten, clamped to the broker minimum, rate-limited
  by hysteresis.
- Braces and parentheses balance; no non-ASCII; 1,959 lines.

---

## Not a bug, but know it

The synthetic tick set used for smoke tests is only ~96 M5 bars long —
shorter than a 50-period EMA needs. With the filter armed it correctly
produces zero trades. That set can verify code paths but cannot
evaluate the trend filter; only real tick data can.
