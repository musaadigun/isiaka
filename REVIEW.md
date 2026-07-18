# XVISION Gold News Straddle — V7 review and V8 fixes

Code review of `XVISION_Gold_NewsStraddle_EA_Version7.mq4` (committed here as
`XVISION_Gold_NewsStraddle_EA.mq4`, first commit) and the fixes applied in V8
(second commit). Compare the two commits to see exactly what changed.

## Critical bugs found in V7

### 1. Panel LOT override was silently ignored (money bug)
`PlaceNewsStraddle()` computed `lots = NormalizeLots(g_workLot)` from the
panel value, but `SendPendingOrder()` discarded it and sent
`NormalizeLots(LotSize)` — the original input — in both of its `OrderSend`
calls (including the ECN error-130 fallback). Changing the lot on the panel
before a news event had no effect on the size actually traded.

**V8 fix:** `SendPendingOrder()` takes the lot size as a parameter and both
call sites pass the working lot. The panel status line also now displays
`g_workLot` instead of the raw input.

### 2. CANCEL SETUP could silently re-arm (money bug)
`PanelCancelSetup()` recorded the cancellation as `STATE_EXPIRED`. But the
V3 "stale state" cleaner in `SynchroniseState()` deletes any stored state
`>= STATE_PENDING` when there are no live orders, no history, and
`TimeGMT() < g_placeGMT`. So cancelling **before the placement window
opened** — e.g. news postponed — was wiped as "stale residue" on the next
tick, and the EA re-armed and traded the event the user had cancelled,
despite the panel promising "will not re-arm for this event".

**V8 fix:** a dedicated `STATE_CANCELLED` (6) that the stale-state cleaner
explicitly preserves, `CanPlaceNow()` vetoes, and the panel shows as
`CANCELLED`. RESET still clears it, as documented in the cancel alert.

### 3. Per-side TP/SL inputs were averaged, not used
`OnInit` collapsed the four inputs into shared values:
`g_workTP = (BuyTakeProfitMovement + SellTakeProfitMovement) / 2` (same for
SL). Configure Buy SL 20 / Sell SL 30 and both legs silently traded with 25.

**V8 fix:** separate working values (`g_workBuyTP/SL`, `g_workSellTP/SL`)
flow through validation, placement, fill re-anchoring, persistence
(new `BTP/STP/BSL/SSL` override tags; legacy `TP/SL` tags are still cleared
on RESET), and the panel display. The single panel TP/SL edit fields apply
to both sides, and the hint line says so.

### 4. "Strict" GMT parsing wasn't strict
`ParseStrictGMT()` was a direct `StringToTime()` call, which is lenient: an
empty or mangled string resolves to a plausible datetime for *today* instead
of failing, so a typo in the panel time field could silently reschedule the
event. **V8 fix:** the parsed value is round-tripped through
`TimeToString()` and must reproduce the cleaned input, so only a complete
`YYYY.MM.DD HH:MI` is accepted.

## Smaller improvements in V8

- `CanPlaceNow()` now reports `autotrading disabled in terminal` as a block
  reason, so the existing ARM BLOCKED alert fires when the AutoTrading
  button is off — previously the straddle just failed to arm with no
  specific diagnostic until the WINDOW MISSED alarm.
- Ticket-validity checks made consistent (`>= 0` everywhere, matching
  `SendPendingOrder`'s success contract) so a broker returning ticket 0
  can't break the require-both-orders rollback.
- Removed dead function `ExitModeText()` (never called; also mixed
  `g_workMode` and the `ExitMode` input inconsistently).
- Panel status line now shows true per-side SL and TP values.

## What V7 already did well (kept as-is)

GMT-anchored scheduling with broker time display-only; crash-safe event
state in terminal global variables keyed by account + magic + event time;
pre-arm heartbeat and one-shot block-reason alerts; ECN fallback with
protective-stop attach and rollback on failure; survivor selection and
opposite-leg cancellation on trigger; break-even stage before trailing.

## Note on verification

This environment has no MetaTrader compiler, so V8 was desk-checked
(reference audit of every renamed symbol, brace/paren balance) but not
compiled. Compile it in MetaEditor and run it on a demo account through at
least one scheduled event before using it live.
