# Isiaka EA

MetaTrader 4 expert advisor scaffold. The trading rules live in one file;
everything else is plumbing that does not change when the strategy changes.

Requires MT4 build 600 or later (the scaffold uses classes and structs in
include files).

## Layout

```
MQL4/
  Experts/Isiaka/IsiakaEA.mq4      Main expert: inputs, tick loop, wiring
  Include/Isiaka/Signal.mqh        >>> THE STRATEGY GOES HERE <<<
  Include/Isiaka/Risk.mqh          Position sizing (fixed lot or % risk)
  Include/Isiaka/Execution.mqh     Orders, breakeven, trailing, broker limits
  Include/Isiaka/Defs.mqh          Shared enums and settings structs
```

## Install

Open the terminal's data folder (MetaEditor → *File → Open Data Folder*) and copy
the `MQL4` tree in so it merges with the existing `MQL4/Experts` and
`MQL4/Include` directories. Then compile `IsiakaEA.mq4` in MetaEditor (F7) and
refresh the Navigator.

## Current state

The plumbing is complete and configurable. `CSignal::Check()` is a stub that
returns `SIGNAL_NONE`, so the EA compiles and runs but will not open trades until
the entry rules are filled in.

## What the scaffold already handles

- **Sizing** — `LOT_RISK_PERCENT` derives volume from the stop distance and the
  symbol's real tick value rescaled to points, so it is correct on FX, indices,
  metals and CFDs rather than assuming a fixed value per pip. Volume is snapped
  to the broker's lot step, and a size below the broker minimum returns 0 (entry
  skipped) instead of being rounded up into more risk than you asked for.
- **Stops** — fixed points or ATR multiple, with take profit as an R multiple.
  A strategy can override both per setup by assigning them inside `Check()`.
- **Broker constraints** — stop level checked on entry and on every modify,
  freeze level respected, spread filter, slippage cap.
- **Order errors** — requotes, off-quotes, busy context and timeouts are retried
  with backoff; genuine rejections are not retried. If the server refuses stops
  attached to a market order (common on ECN/STP accounts), the EA opens the
  position and attaches SL/TP immediately afterwards, logging loudly if that
  second step fails.
- **Trade management** — breakeven and trailing stop, both point-based, and both
  only sending a modify when the stop genuinely improves.
- **Bar timing** — signals evaluate on bar close by default. `Signal.mqh`
  documents the reason: reading the forming bar (shift 0) is the usual cause of a
  backtest that cannot be reproduced live.

All distances are in **points**, not pips. On a 5-digit broker 1 pip = 10 points,
so a 30-pip stop is `300`.

## Testing

Strategy Tester settings that keep the results honest:

- Model: **Every tick**. *Open prices only* will flatter any intrabar logic.
- Check that the modelling quality is around 90%; below that the tick generation
  is guesswork and so are the results.
- Set spread to your broker's realistic value rather than the default.
- Watch the *Journal* tab for skipped entries — the EA logs why each one was
  dropped (spread, volume, ATR, stop level, order error).
