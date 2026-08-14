# Audit — GoldScalperM1M5_Version6.mq4

Second full audit, run on the v6 build. The v5/v6 changes were large —
the entry evaluator was rewritten, eleven gates became inputs, and
diagnostics logging was added — so the audit concentrated there, then
re-checked the machinery the earlier audit had cleared.

**Six bugs found, all six fixed in Version 7.** None of them is a
trading-rule change; every fix restores behaviour that was already
intended. Two would have cost you real behaviour on a live account.

Severity: **M** = affects live behaviour · **L** = cosmetic or
instrumentation.

---

## B1 (M) — The orphan sweep deleted the persisted cooldown

`CleanOrphanedTicketState()` scans GlobalVariables matching
`GS1.<account>.<magic>.` and deletes anything whose ticket segment does
not resolve to a live order. The cooldown key added in v4 is
`GS1.<account>.<magic>.LASTENTRY` — it has **no ticket segment at all**,
so it fell into the `dot < 0` branch and was deleted on every attach.

Traced precisely:

```
name   = "GS1.123456.26082601.LASTENTRY"
rest   = "LASTENTRY"
dot    = -1                       -> treated as malformed -> deleted
```

**Effect:** the v4 fix for "cooldown resets on restart" worked only
until the next attach. The value is read before the sweep runs, so the
live session was fine, but a second restart lost it again — the bug
quietly undid the fix it was shipped alongside.

**Fixed:** a key with no ticket segment is account-level, not an
orphan. The sweep now skips it, and skips any unparseable segment
rather than deleting it.

---

## B2 (M) — A ticket change lost the high-water mark and the journal row

MT4 re-tickets the remainder of a partially closed position. When that
happened, `ManagePosition()` ran `if(ticket != g_posTicket)
AdoptTicket(ticket);` — which does two harmful things:

1. **The closed leg is never journalled.** The EA only writes an EXIT
   row when the ticket disappears entirely, so a partial close produced
   an ENTRY with no matching record.
2. **`g_posMaxFav` resets** to the *current* excursion. The profit lock
   and the trailing stop both measure from that high-water mark, so
   after a partial close they stop advancing until the excursion climbs
   back to its old peak. Stops never loosen (that check held), but a
   winner that pulls back after a partial would sit with a stop that
   refuses to trail.

The old ticket's GlobalVariables were also left behind as orphans.

**Fixed:** on a ticket change the EA journals the closed leg, drops its
state, re-selects the live ticket, adopts it, and carries the
high-water mark forward if it was higher.

A latent hazard was fixed with it: `AdoptTicket()` reads the excursion
from the *currently selected* order, and `JournalClosedTicket()`
selects a history order. Calling them in sequence without re-selecting
would have adopted the wrong prices. The re-selection is now explicit
and the precondition documented on the function.

---

## B3 (L) — Dead signal state

`g_signalFadeTarget` was assigned every bar and never read; `SendEntry`
receives the local `fadeTarget` instead. Harmless, but it invites a
future reader to trust a variable nothing maintains. Removed.

---

## B4 (L) — Coherence computed twice per blocked bar

`M1Coherence(1, dir)` ran once to test the gate and again to format the
failure text — a full recomputation over four windows on every bar the
gate rejects. Computed once and reused.

---

## B5 (L) — A failed send left no diagnostic trail

With `LogGateDiagnostics` on, a bar blocked by a gate or by a rail
wrote a BLOCKED row, but a signal that passed everything and then
failed inside `SendEntry` (spread, margin, lot size, no quote) wrote a
SIGNAL row with no outcome. The log implied an entry that never
happened.

**Fixed:** a failed send now writes `BLOCKED … send: <reason>`.

---

## B6 (L) — Diagnostics could be misread

When no CUSUM burst has fired, the evaluator infers a direction from
the M1 composite so the remaining gates can still be reported. Tokens
like `ER +0.16` are then measured against a *presumed* direction. That
is not wrong — no entry is possible on such a bar because the burst
gate already failed — but it is easy to misread. Documented in the
code where the fallback happens.

---

## Re-verified, still correct

Re-checked rather than assumed, because v5 touched so much:

- The v5 gate rewrite is sound: every gate honours its off switch,
  every failure is accumulated instead of short-circuited, and the
  function returns a direction only when the failure list is empty.
- v6's `0 = off` conversion is complete — the gate test, the fade
  module's copy of it, the panel warning colour and the startup summary
  all key off "greater than zero". No path still compares against 1.0.
- The partial-close merge in the loss-streak counter is correct: legs
  are summed into whole trades, the trade takes its last leg's close
  time, merged rows are compacted away, and the survivors sort cleanly.
- Stops still only ever tighten, are clamped to the broker's minimum
  distance, and are rate-limited by the hysteresis step.
- The broker stop-distance handling from v4 holds on both the entry
  path and the repair path.
- Braces and parentheses balance; no non-ASCII characters; 1,706 lines.

---

## Not bugs — consequences of your rules, listed so they are not a surprise

- With every contradictory gate off, the EA will take trades that a
  tighter stack would have refused. That is the intended starting point.
- `LogGateDiagnostics` writes one CSV row per blocked M1 bar — up to
  ~1,400 rows a day. Fine for a few days of tuning; turn it off after.
- The fade module's re-arm only updates on bars where the momentum
  module returns no signal. It is off by default, so this is dormant.
