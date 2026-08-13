# Audit — GoldScalperM1M5_Version3.mq4

Pre-deployment audit of the v3 build (the one produced after stripping
the eight guards). Read line by line, with attention to what the strip
may have broken and to what happens on a live broker.

**Verdict: do not run it live yet.** Nothing is structurally broken —
the strip itself is clean — but four findings below will affect real
money or real decisions, and two of them will show up on the very first
signal with certain brokers.

Severity: **H** = fix before live · **M** = know about it · **L** = note.

---

## H1 — The trade ledger no longer records exits

`LedgerWrite("EXIT", …)` exists only inside `CloseSelectedOrder()`. In
v3 that function is reachable only from failure paths (pending-close
retry, stop-repair failure, stop-anchoring failure). Every *normal*
exit now happens at the broker — your SL, TP or trailed stop — and the
EA never sees it.

**Effect:** `MQL4/Files/GoldScalper_<symbol>_<account>.csv` fills with
SIGNAL and ENTRY rows and almost no EXIT rows. The journal we intended
to tune the strategy from records only half of each trade.

**Fix:** when a managed ticket disappears, look it up in history and
write the EXIT row with the real close price, profit and reason
(SL hit / TP hit / trailed stop / closed by hand).

---

## H2 — Broker minimum stop distance is never checked

`SendEntry()` places the SL at exactly `StopLoss_PriceUSD` from entry
and the TP at exactly `TakeProfit_PriceUSD`, without consulting
`MODE_STOPLEVEL` / `MODE_FREEZELEVEL`.

If your broker's minimum stop distance on gold is wider than your SL
(some brokers use 300+ points = $3.00), this sequence runs on every
signal:

1. `OrderSend` fails with error 130 (invalid stops)
2. the ECN fallback opens the position **naked**
3. the post-fill `OrderModify` fails for the same reason
4. the EA closes the position immediately — "ENTRY OPENED THEN CLOSED"

You would pay the spread on every signal and never hold a trade.

A quieter variant of the same problem: `EnsureStopProtection()` clamps
its repair to `Bid − minDist`, so if the broker distance exceeds your
setting the position ends up with a **wider stop than you asked for**,
silently.

**Fix:** read the broker's stop level at init, print it, and either
refuse to start or clamp with a loud warning when SL/TP are inside it.

---

## H3 — With exits zeroed, nothing closes a losing trade

This follows directly from the v3 strip and is stated for the record,
not as a defect. With `StopLoss_PriceUSD = 0`, `TakeProfit_PriceUSD = 0`
and trailing off, a position has no exit but you. The EA prints a note
at attach and the panel shows `MANUAL - no EA exit`, but nothing
prevents it. Combined with the removed manual-position block, the EA
can also open its own trade alongside your manual ones — the combined
margin is yours to watch.

---

## H4 — The backtester no longer matches the EA

`backtest/engine.py` still applies: fast cut ($0.80), failure-to-launch
(90 s), session filter, Friday cutoff, no-chase ($0.30), daily loss
brake (1.5%) and opposite-signal exit — every one of which was removed
from the EA in v3.

**Effect:** any backtest run today measures a strategy that no longer
exists. Numbers from it cannot be used to judge this EA.

**Fix:** mirror v3 — those seven behaviours off by default, `fixed_lots`
set from `LotSize`, TP/lock/trail as the only exits.

---

## M1 — Lock and trail depend on what the EA observed

Both are measured from `g_posMaxFav`, which is updated only on ticks
while the EA is running. If MT4 is closed, frozen or disconnected
during a favourable spike, that excursion is never recorded, so the
lock may not arm even though price traded through the trigger. The
value is persisted across restarts, but only what was seen while
running.

## M2 — Cooldown resets on restart

`g_lastEntryTime` is not persisted. After a terminal restart the
120-second cooldown starts from zero, so the EA may enter immediately
after a restart even if it entered seconds earlier.

## M3 — Loss streak counts legs, not trades

The streak reads closed orders by close time. A partially closed
position produces two history rows, so one net-positive trade can still
contribute a losing leg to the streak. This makes the pause fire
*earlier* than intended — safe direction, but not what the label says.

## M4 — Fade take-profit is lost on the ECN fallback path

In `SendEntry`, when the fallback is used and `TakeProfit_PriceUSD` is
0, `exactTP` falls back to `OrderTakeProfit()` (which is 0 on a naked
order), so the fade module's mean-reversion target is silently dropped.
Only affects the fade module, which is off by default.

## M5 — The daily cap now limits attempts, not exposure

With no EA exits, one trade can span hours. `MaxTradesPerDay = 15`
caps entry *attempts*; combined with one-position-at-a-time, the real
number of trades per day will usually be far lower than 15. If you
expect 15 scalps a day, that expectation no longer matches the design.

## M6 — Benign modify errors count toward the stop-repair limit

`EnsureStopProtection()` increments its failure counter on any
`OrderModify` failure, including benign ones, and closes the position
after five. The repair path only runs when the SL is missing, so this
is unlikely to fire, but the counter does not distinguish causes.

---

## L — Notes

- `SendEntry`'s `reference` parameter is now dead code (the no-chase
  check that used it was removed).
- The panel's Signal row holds the last closed bar's signal until the
  next bar closes; it is not a live "right now" reading.
- The EA reads M1/M5 explicitly, so attaching it to an M5 chart (as in
  your screenshot) works correctly.
- `NEWS_BLACKOUTS` is empty, so the blackout logic is inactive.
- One ledger file per symbol+account; two instances would interleave.

---

## Verified correct

Checked and found sound, so they are not re-litigated above:

- The v3 strip is clean — no dangling reference to any removed rule
  (grep-verified across all eight), braces and parens balanced, no
  non-ASCII, 1,423 lines.
- Stops are only ever tightened, never loosened; clamped to the broker's
  distance; hysteresis prevents modify spam.
- Restart adoption of an open position works, and orphaned per-ticket
  GlobalVariables are swept at init.
- Closes are retry-aware with a pending-close state that survives to
  the next tick and the 1-second timer.
- Daily counters use unique open times, so partial closes are not
  double-counted (the v1.01 fix still holds).
- Lot sizing floors to the broker step and refuses anything below the
  broker minimum — it never rounds size up.
- The panel rebuilds itself if its objects are deleted, and clears
  cleanly on deinit.

---

## Recommended order of work

1. H2 (broker stop level) — decides whether the EA can trade at all on
   your broker.
2. H1 (ledger exits) — without it there is no record to tune from.
3. H4 (backtester alignment) — without it there is no validation.
4. M1–M6 as time allows.

---

## Resolution — shipped in Version 4

Defects only; no trading rule was added, removed or altered.

| Finding | Status in v4 |
|---|---|
| H1 ledger misses exits | **Fixed.** When the position disappears, the EA recovers it from history and writes the EXIT row with the real close price, profit and an inferred reason (stop/trail hit, take profit hit, or closed manually). |
| H2 broker stop distance | **Fixed.** The broker minimum is read at attach and printed, with a warning if your SL/TP sit inside it. Entries now place stops at the broker minimum when your setting is tighter, instead of being rejected, opening naked and closing immediately. |
| H3 no exit when exits are zeroed | **Left as designed.** Your rule; the startup note and the panel's `MANUAL - no EA exit` remain. |
| H4 backtester mismatch | **Fixed.** engine.py mirrors v4: scratch, launch window, session filter, Friday cutoff, no-chase, daily brake and opposite-signal exit all default off; `--lots` mirrors `LotSize`. |
| M1 lock/trail see only observed ticks | **Inherent**, not fixable in MQL4; documented. |
| M2 cooldown resets on restart | **Fixed.** Last entry time persists in a GlobalVariable. |
| M3 streak counts legs | **Fixed.** Legs sharing an open time are merged into one trade before the streak is measured. |
| M4 fade TP lost on ECN fallback | **Fixed.** The intended target is carried through the fallback. |
| M5 cap limits attempts | **Left as designed.** Consequence of your exit rules. |
| M6 benign modify counted as failure | **Fixed.** A "no changes" result no longer counts toward the stop-repair limit. |
| L1 dead `reference` parameter | **Removed.** |
