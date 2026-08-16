# Isiaka EA

MetaTrader 4 expert advisor scaffold. The trading rules live in one file;
everything else is plumbing that does not change when the strategy changes.

Requires MT4 build 600 or later (the scaffold uses classes and structs in
include files).

## Layout

```
MQL4/
  Experts/Isiaka/IsiakaEA.mq4      Main expert: inputs, tick loop, wiring
  Indicators/Isiaka/IsiakaEMA.mq4  EMA with a free period input
  Include/Isiaka/Signal.mqh        >>> THE STRATEGY GOES HERE <<<
  Include/Isiaka/Risk.mqh          Position sizing (fixed lot or % risk)
  Include/Isiaka/Execution.mqh     Orders, breakeven, trailing, broker limits
  Include/Isiaka/Defs.mqh          Shared enums and settings structs

research/                          Data study of the EMA50 cross on GOLD M5
```

## IsiakaEMA indicator

`EMA[i] = Price[i] * a + EMA[i+1] * (1 - a)` with `a = 2 / (period + 1)` — the
same recursion MT4 uses for `MODE_EMA`, so the line sits exactly on top of the
built-in EMA.

| Input | Default | Notes |
|---|---|---|
| `InpPeriod` | 50 | Any period ≥ 1 |
| `InpAppliedPrice` | `PRICE_CLOSE` | Close, Open, High, Low, Median, Typical, Weighted |
| `InpShift` | 0 | Horizontal shift in bars |
| `InpTimeframe` | `PERIOD_CURRENT` | Set higher to draw e.g. the H1 EMA on an M5 chart |
| `InpColor` / `InpWidth` | Red / 2 | Appearance |
| `InpSelfCheck` | true | Compares every bar against MT4's `iMA()` and prints the largest deviation to the Experts log |
| `InpShowStats` | false | On-chart count of how often price closes across the EMA |

Nothing in it is tied to a timeframe or symbol — it works on GOLD M1 through MN,
and on any other instrument.

`InpSelfCheck` exists so you never have to take the maths on trust: it prints a
line like `max deviation from MT4 built-in EMA(50) across 5000 bars = 0.0000000000`.
Anything under 0.0000001 is floating-point noise rather than a real difference.

`InpShowStats` counts how often the applied price closes on the opposite side of
the EMA — what an EA actually fires on, which is normally far more often than a
chart reader would guess.

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
