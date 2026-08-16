# Isiaka EA

MetaTrader 5 expert advisor scaffold. The trading rules live in one file; everything
else is plumbing that does not change when the strategy changes.

## Layout

```
MQL5/
  Experts/Isiaka/IsiakaEA.mq5      Main expert: inputs, tick loop, wiring
  Include/Isiaka/Signal.mqh        >>> THE STRATEGY GOES HERE <<<
  Include/Isiaka/Risk.mqh          Position sizing (fixed lot or % risk)
  Include/Isiaka/Execution.mqh     Orders, breakeven, trailing, broker limits
  Include/Isiaka/Defs.mqh          Shared enums and settings structs
```

## Install

Copy the `MQL5` tree into your terminal's data folder (MetaEditor → *File → Open
Data Folder*), so that the paths merge with the existing `MQL5/Experts` and
`MQL5/Include` directories. Then compile `IsiakaEA.mq5` in MetaEditor (F7).

## Current state

The plumbing is complete and configurable. `CSignal::Check()` is a stub that
returns `SIGNAL_NONE`, so the EA compiles and runs but will not open trades until
the entry rules are filled in.

## What the scaffold already handles

- **Sizing** — `LOT_RISK_PERCENT` derives volume from the stop distance and the
  symbol's real tick value, so it is correct on FX, indices, metals and crypto
  rather than assuming $10 per pip. Volume is snapped to the broker's lot step,
  and a size below the broker minimum returns 0 (entry skipped) instead of being
  silently rounded up into more risk than you asked for.
- **Stops** — fixed points or ATR multiple, with take profit as an R multiple.
  A strategy can override both per setup by setting them inside `Check()`.
- **Broker constraints** — filling mode detected per symbol, stops level respected
  on both entry and modification, spread filter, slippage cap.
- **Trade management** — breakeven and trailing stop, both point-based, and both
  only sending a modify when the stop genuinely improves.
- **Bar timing** — signals evaluate on bar close by default. `Signal.mqh` documents
  the reason: reading the forming bar (index 0) is the usual cause of a backtest
  that cannot be reproduced live.

## Testing

Strategy Tester settings that keep the results honest:

- Modelling: **Every tick based on real ticks** where the broker provides them.
- Set the tester's spread to **realistic or actual**, not the default fixed value.
- Check the *Journal* tab for skipped entries; the EA logs why each one was
  dropped (spread, volume, ATR, broker stops level).
