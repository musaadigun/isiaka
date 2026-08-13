# isiaka — GoldScalper M1/M5

An MT4 Expert Advisor that scalps XAUUSD on the 1-minute chart with
5-minute context, built for many trades a day with losses engineered
small: every trade must confirm within seconds or it is scratched by
software long before the broker-side stop is touched.

## Repository layout

| Path | What it is |
|---|---|
| `mt4/GoldScalperM1M5.mq4` | The EA. Compile in MetaEditor, attach to XAUUSD M1. |
| `backtest/` | Tick-replay backtester + free Dukascopy data downloader. |
| `reference/` | The five prior builds this EA was mined from. |

## How the EA works

**Entries** (evaluated once per closed M1 bar, M1/M5 data only):

- A five-mode regime engine (noise / drift / impulse / exhaustion /
  shock, from GoldSeekAdaptive v3) plus an efficiency-ratio gate routes
  between modules and stands the EA down in hostile conditions.
- The **momentum module** (primary): a CUSUM changepoint detector fires
  on genuine M1 bursts, then the trigger must survive vetoes — M1
  velocity strength and coherence, trigger-bar body alignment, no
  oversized bars, no mature moves (never chase), M5 velocity + EMA20/30
  ribbon agreement.
- The **fade module** (Keltner reversion, **off by default**): fading
  gold failed stability tests in the prior research cycle; it stays off
  until the tick backtest earns it a place.

**Exits** — the near-zero-loss machinery, in firing order:

1. Fast cut at −$0.80 (software, tick-speed)
2. Confirm-or-scratch: not +$0.30 within 90 s → out
3. Breakeven lock at +$0.60, partial bank at +$0.70, M1-ATR trail from +$0.90
4. Max hold 12 min; opposite qualified signal → out
5. Broker-side hard stop at −$2.50 — disconnect insurance only

**Rails**: spread ceiling, no-chase cap, cooldown, session windows,
news blackout windows, Friday cutoff, daily trade cap, daily loss brake
(percent of balance and/or absolute), consecutive-loss pause. One
position at a time. Sizing risks a fixed percent at the *hard* stop, so
the typical scratch loses a small fraction of that.

**Instrumentation**: an on-chart panel that always names the exact gate
currently blocking entry, and a CSV trade ledger in `MQL4/Files`.

## Deploying

1. Copy `mt4/GoldScalperM1M5.mq4` to `MQL4/Experts`, compile (F7),
   attach to a **XAUUSD M1** chart.
2. The EA attaches **disarmed** (`EnableTrading=false`): it shows every
   signal and blocker without trading. Watch it, then arm deliberately.
3. Set `SessionWindows` in **broker time** (defaults assume a GMT+2/+3
   broker: London morning + NY session).
4. Order of operations: backtest → demo → small live. Numbers come from
   the backtester (see `backtest/README.md`), not from hope.

All `*_USD` inputs are absolute gold price movements ($0.80 = 80 cents
of XAUUSD price). Defaults assume a raw-spread account; on a standard
account with $0.30+ spreads, widen the targets or the spread ceiling
will (correctly) keep the EA out of the market.
