# XVISION Gold News Straddle EA

A news-straddle Expert Advisor for MT4 on Gold: it places a buy stop above and
a sell stop below the market a few minutes before a scheduled news release,
keeps whichever side fills, and manages the exit.

## Running more than one event a day

This is what V10 changed. V9 held a single event in `NewsDateTimeGMT`, so a
second event meant retyping that input — which silently broke things (see
"What was wrong with V9" below).

Fill in **`ExtraEventTimesGMT`** instead. Entries are separated by commas or
semicolons, and each may carry an optional label after `=`:

```
12:30=US CPI, 14:00=FOMC
```

Each entry is one of:

| Form | Meaning |
| --- | --- |
| `12:30` | 12:30 GMT. Today if that window is still ahead, otherwise the next occurrence. |
| `12:30:30` | Seconds are allowed. |
| `2026.08.03 12:30` | A specific date and time, one shot. |

Add `=Label` to any of them to name the event on the panel and in alerts, e.g.
`2026.08.03 12:30=NFP`.

Related inputs:

- **`RepeatEventsDaily`** — `HH:MM` entries re-arm every day instead of once.
- **`SkipWeekendEvents`** — daily rollover jumps Saturday and Sunday.
- **`UsePrimaryNewsDateTime`** — set to `false` when scheduling purely through
  `ExtraEventTimesGMT`. Left `true`, the F7 date picker is event 1; if it is
  still on the 2099 placeholder it is skipped automatically.

Up to 12 events can be scheduled at once.

Everything else (lot size, distances, TP/SL, trailing, break-even, the
placement and expiry offsets) is shared by every event in the schedule.

## Magic numbers

Event *N* owns magic number `MagicNumber + N`, so a 12-event schedule reserves
`MagicNumber` through `MagicNumber + 11`. Keep other EAs' magic numbers outside
that range. The reserved range is printed to the Experts log at startup.

Ownership is keyed on the magic number rather than the order comment, because
brokers rewrite or strip comments when a pending order fills.

## Time

All scheduling is in **GMT/UTC**, taken from `TimeGMT()`. Broker time is shown
on the panel for reference only. The broker/GMT offset is measured from live
ticks, rounded to the nearest quarter hour and cached, so it stays right across
weekends and restarts.

## The panel

Read-only status, plus two live actions that F7 cannot perform:

- **CLOSE ALL NOW** — flattens every position and pending this EA owns, and
  disarms every event in the schedule. A panic button.
- **CANCEL hh:mm** — deletes just the named event's un-triggered pendings and
  disarms that one event. The rest of the schedule keeps running.

Both disarm permanently; `ForceResetEventState = true` re-enables them at the
next init. A daily event still rolls to its next occurrence, because that is a
new instance rather than a re-arm of the one that was cancelled.

## What was wrong with V9

Everything identifying an order — the comment token, the state global variable,
the countdown, the panel — came from the single `NewsDateTimeGMT` input.
Running a second event the same day meant editing it, and that:

1. **Orphaned any open trade.** Changing the input re-keyed the comment token,
   so a position still open from the earlier event no longer matched and was
   abandoned mid-flight: no trailing, no break-even, no CLOSE NOW.
2. **Blocked the next event.** The finished event's stored state (`COMPLETE` /
   `EXPIRED` / `CANCELLED`) kept vetoing arming unless `ForceResetEventState`
   was remembered.
3. **Lost trades to comment rewriting.** Order identity depended on the broker
   preserving the comment. Where it did not, the EA lost track of its own
   position and could re-arm on top of it.

V10 gives every event its own times, magic number, state and countdown, and
services all of them on every cycle.

Other fixes carried in the same release:

- Order placement retries on requote / off-quotes / busy errors instead of
  giving up after one attempt, recomputing entry, SL and TP each try.
- The trigger notification reported the wrong fill price, because the order
  context had been clobbered by the calls made just before it.
- Trailing and break-even now cover every event's positions, not just the
  current one.
- The state global variable was rewritten on every tick, several times per
  tick; it is now written only when the value changes.
- History and order scans are single-pass and throttled rather than repeated
  per event.
- Pending-order geometry now also respects the broker freeze level.
- Repeated identical popup alerts are suppressed for 30 seconds.
- Stale event-state globals older than a week are purged at startup.

## Before going live

Compile in MetaEditor and run it in the Strategy Tester on your own broker's
Gold symbol. The check harness in `tools/mql4check` exercises the scheduling
logic but cannot model your broker's fills, spreads, stop levels or slippage.
