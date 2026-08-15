# Deep audit — GoldScalperM1M5_Version10.mq4

Line-by-line pass over the whole file (1,959 lines) rather than a
targeted check of recent changes, plus the two Python tools. Every
function was read and its effect traced through the states it can be
reached in: fresh entry, adopted position, partial close, restart,
failed close, failed stop repair, and full close.

**Seven findings, all fixed in Version 11.** One of them silently
removed trades from the file we tune from. No trading rule changed.

Severity: **H** = corrupts the data you decide from, or affects live
behaviour · **M** = wasteful or degrades data quality · **L** = cosmetic.

---

## C1 (H) — Trades the EA closes itself never reach the dataset

`CloseSelectedOrder()` writes a ledger EXIT row, then calls
`ForgetPosition()`, which sets `g_posTicket = -1`. On the next
`ManagePosition()` call the ticket is gone **and** `g_posTicket` is
already -1, so the `JournalClosedTicket` branch never fires — and that
function is the only caller of `DatasetWrite()`.

Every position the EA closes on its own initiative is therefore absent
from `GoldScalperTrades_*.csv`:

- stop-repair exhausted → `UNPROTECTED POSITION`
- post-fill stop anchoring failed → `PROTECTIVE STOP COULD NOT BE SET`
- a pending close finally succeeding on a later tick

These are rare, but they are precisely the pathological trades worth
studying, and their absence is invisible: the dataset simply has fewer
rows than the account has trades, with nothing marking the gap.

**Fixed.** `CloseSelectedOrder` now syncs the excursions and writes the
dataset row from the history order it already selects for the profit
figure — before `ForgetPosition()` zeroes those excursions.

---

## C2 (M) — Excursion persistence wrote nineteen keys to save two

`PersistTicketState()` writes all nineteen feature keys, and the hot
path called it every time the peak or dip moved five cents. Seventeen
of those values are entry-time constants that cannot change while the
position is open.

On a tape with M1 ATR above 2.00 that is thousands of redundant
terminal GlobalVariable writes an hour, on every tick batch.

**Fixed.** Split into `PersistExcursions()` (two keys, hot path) and
`PersistTicketState()` (all nineteen, once per adoption).

---

## C3 (M) — Peak and dip stopped updating while a stop repair failed

`ManagePosition()` returned early on `!EnsureStopProtection()`, which
skipped both the excursion update and the stop management. During up to
five repair attempts the position's peak and dip went unrecorded.

Not trading an unprotected position is defensible. Losing the record of
what it did is not — and the same early return also froze the lock and
trail reference.

**Fixed.** Excursions are now recorded before any early return in the
function; the protection gate still guards only the stop management.

---

## C4 (M) — The recorded entry spread could be the pre-fallback quote

`spread` is captured before `OrderSend`. When the ECN fallback re-quotes
and sends again, `SnapshotEntryFeatures(spread)` still recorded the
original figure — so `spread_at_entry` was wrong for exactly the trades
that had execution trouble, which is when you would most want it right.

**Fixed.** The fallback path re-reads the spread it actually pays.

---

## C5 (L) — The properties dialog advertised removed behaviour

`#property description` still read "scratch-first exits", and the
lineage block credited a "failure-to-launch exit" — both removed in v3.
That description is what MT4 shows in the EA properties dialog, so the
first thing you read about the EA was three versions out of date.

**Fixed.**

## C6 (L) — Comment typo

"inside thepanel" — fixed.

## C7 (L) — A vacuous colour test

The exit-ownership row's colour condition read
`StringLen(ownership)>0 && StopLoss_PriceUSD<=0.0`. The first half is
always true, since the string defaults to "MANUAL - no EA exit".
Simplified to the half that means something.

---

## Traced and found correct

Checked by following the state through, not by assumption:

- **Order-selection discipline.** Every function that reads `Order*()`
  is reached with the intended order selected. The two places where a
  history lookup intervenes (`JournalClosedTicket` inside the ticket
  switch, and inside `CloseSelectedOrder`) either re-select afterwards
  or do not read live-order fields again.
- **Feature snapshot ordering.** `SnapshotEntryFeatures` precedes
  `AdoptTicket` on all three entry paths including the unprotected-entry
  branch, so a new ticket keeps its own conditions while an adopted one
  restores from storage.
- **Dataset schema.** 31 header fields, 31 row fields, verified pairwise
  in order.
- **The day cache.** Unique-open-time counting for the cap; partial legs
  merged into whole trades before the streak; both re-derived whenever
  the order counts or the broker day change.
- **Stops.** Only ever tightened, clamped to the broker minimum on both
  the entry and the repair path, rate-limited by hysteresis, and a
  benign "no changes" result is not counted as a failure.
- **Arithmetic bounds.** Every division guards its denominator; ATR,
  sigma and path length all have floors; the regime posterior clamps its
  exponent before `MathExp`.
- **Bar-history requirements.** The deepest reads are `iATR(M1,48)` at
  shift 1 (49 bars), `ReturnSigmaM1` (50), the maturity window (31) and
  the ER loop (21). The guard requires 81 M1 bars, and now scales the M5
  requirement with the trend EMA.
- Braces and parentheses balance; no non-ASCII; 1,990 lines after the
  fixes.

---

## Known and unchanged, by your design

Listed so they are never mistaken for oversights:

- With SL, TP and trailing all zero, nothing but you closes a position.
- The EA may open alongside your manual trades; combined margin is
  yours to watch.
- `MaxTradesPerDay` caps entry *attempts*, not concurrent exposure.
- The lock and trail can only act on excursions the EA was running to
  observe; MQL4 offers no way to recover a spike it did not see.
- MT4's Account History tab must include today, or the daily counters
  and the streak read a filtered view.
