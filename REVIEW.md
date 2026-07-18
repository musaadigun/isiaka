# XVISION Gold News Straddle — review and change history

Code review of `XVISION_Gold_NewsStraddle_EA_Version7.mq4` (committed here as
`XVISION_Gold_NewsStraddle_EA.mq4`, first commit), the bug fixes applied in V8
(second commit), and the V9 interface redesign (third commit). Compare the
commits to see exactly what changed at each step.

## V9 — interface redesign (config moved to F7, read-only panel)

This round is a design change requested by the user, not a bug fix. Behaviour
of the trading engine is unchanged; how you configure and read it changed.

- **All configuration moved to the native F7 "Inputs" tab.** The on-chart
  edit fields, the MODE/APPLY/RESET buttons, and the entire global-variable
  override layer (`SaveOverrides`/`RestoreOverrides`/`ClearOverrides`) were
  removed. F7 inputs are the single source of truth; the override layer only
  existed to persist panel edits, so with panel edits gone it would only have
  created a way for stale stored values to silently shadow the F7 inputs.
- **Primary trade-setup inputs declared first**, so they head the F7 list:
  news time, lot, exit mode, distances, per-side TP/SL, trailing, break-even.
  The `TradeExitMode` enum moved above them (it must precede its first use)
  and its members carry inline comments, which MT4 shows as the dropdown
  labels.
- **`NewsDateTimeGMT` is now a native `datetime` input.** F7 renders a
  calendar/clock picker, so the old dotted `YYYY.MM.DD` string — which was
  easy to mistype — is gone, along with the `ParseStrictGMT` string parser.
  The picked value is still treated as GMT.
- **Comprehensive input validation.** Because F7 enforces each field's *type*
  (a numeric field can't hold letters; the datetime field is a picker),
  `ValidateInputs()` now focuses on *range* and *contradiction* checks:
  lot within broker min/max, positive distances/SL, positive TP in fixed-TP
  modes, positive trailing triple, non-negative break-even, positive
  placement lead and cancel window, non-negative spread/slippage, positive
  magic, sane panel size. Each failure aborts the load with a specific
  `Validation: ...` line in the Experts log.
- **The panel is now read-only status**, rebuilt as a sectioned, spaced,
  colour-accented layout (STATUS / COUNTDOWN header, then EVENT, ORDERS,
  PLAN, CLOCK groups with divider rules and a two-column label/value grid)
  instead of the old seven cramped pipe-delimited lines.
- **CLOSE NOW and CANCEL SETUP are kept** — they are live actions with no F7
  equivalent (F7 cannot close a trade or cancel resting pendings). They sit
  in their own button row beneath the panel and dim when not applicable. A
  cancelled event is now re-enabled via the existing `ForceResetEventState`
  input in F7 (the old RESET button is gone).

## Bug fixes (V8) — carried into V9

These four bugs were found in V7 and fixed in V8. Note that fix #1 and #2
concern the panel LOT field and CANCEL button; in V9 the lot is set in F7 and
the numbers still flow through the same corrected engine paths, and CANCEL
behaves identically. The fixes remain valid and relevant.

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

This environment has no MetaTrader compiler, so every version here was
desk-checked (reference audit of each renamed/removed symbol, brace/paren
balance, no dangling calls) but not compiled. This matters most for V9,
which is a large refactor: compile it in MetaEditor first, confirm the F7
Inputs tab shows the trade-setup group at the top with a working datetime
picker, then run it on a demo account through at least one scheduled event —
watching the panel arm, trigger, and the CLOSE/CANCEL buttons — before using
it live.
