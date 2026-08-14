# isiaka — GoldScalper M1/M5

An MT4 Expert Advisor that finds XAUUSD entries on the 1-minute chart
with 5-minute context. It decides **when to enter**; you own the trade
once it is open. The EA closes nothing on its own — every exit comes
from your stop loss, take profit, profit lock or trailing stop.

Current build: **Version 5**.

## Repository layout

| Path | What it is |
|---|---|
| `mt4/GoldScalperM1M5_Version5.mq4` | The EA. Compile in MetaEditor, attach to XAUUSD M1. |
| `mt4/panel_preview.svg` | Pixel-accurate mock of the on-chart panel. |
| `backtest/` | Tick-replay backtester + free Dukascopy data downloader. |
| `reference/` | The five prior builds this EA was mined from. |

## Versioning

Every change ships as a new numbered file — `..._Version3.mq4`,
`..._Version4.mq4`, and so on — with `#property version` and the panel
title stepped to match. Old versions stay in the repository so any
build can be recompiled or compared.

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

**Exits — entirely yours.** There is no time stop, no fast cut, no
confirm-or-scratch and no reversal exit. A position ends on:

1. Your profit lock (`LockTrigger_PriceUSD` / `LockedProfit_PriceUSD`)
2. Your trailing stop (`TrailingStart_PriceUSD` / `TrailingDistance_PriceUSD`)
3. Your take profit (`TakeProfit_PriceUSD`)
4. Your stop loss (`StopLoss_PriceUSD`)
5. You, closing it by hand

Set all of those to zero and nothing but you will ever close a trade.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `LotSize` | 0.01 | fixed lot per trade |
| `StopLoss_PriceUSD` | 2.50 | broker-side SL; 0 = none |
| `TakeProfit_PriceUSD` | 0.00 | fixed TP; 0 = off |
| `LockTrigger_PriceUSD` | 0.60 | profit at which the lock arms; 0 = off |
| `LockedProfit_PriceUSD` | 0.10 | SL moves to entry ± this once armed |
| `TrailingStart_PriceUSD` | 0.90 | profit at which trailing begins; 0 = off |
| `TrailingDistance_PriceUSD` | 0.60 | gap the stop trails behind price |
| `MaxSpread_PriceUSD` | 0.35 | no entry above this spread; 0 = no ceiling |
| `MaxTradesPerDay` | 15 | 0 = uncapped |
| `MaxConsecutiveLosses` | 3 | pause after this streak; 0 = off |
| `LossPauseMinutes` | 90 | length of that pause; 0 = down for the day |

All `*_PriceUSD` values are absolute gold price movements ($0.80 = 80
cents of XAUUSD price).

**Frozen in the source** (edit the const block to change): 120-second
cooldown between entries, one position at a time, the regime and signal
gates, news blackout windows (empty by default), close-if-the-broker-
rejects-the-stop, and the gold-symbol lock.

**Instrumentation**: an on-chart panel that always names the exact gate
currently blocking entry, and a CSV trade ledger in `MQL4/Files`.

## Deploying

1. Copy `mt4/GoldScalperM1M5_Version5.mq4` to `MQL4/Experts`, compile
   (F7), attach to a **XAUUSD M1** chart.
2. Arming is MT4's own switch: with AutoTrading OFF the EA runs in
   standby, showing every signal and blocker without trading. Turn
   AutoTrading ON to trade.
3. Set your exits. The defaults are scalp-scale ($0.60 lock, $0.90
   trail); if you are trading for $10–50 moves, widen them to match or
   the trail will close winners early.
4. Order of operations: backtest → demo → small live. Numbers come from
   the backtester (see `backtest/README.md`), not from hope.

Defaults assume a raw-spread account. On a standard account with $0.30+
spreads, either widen your targets or raise `MaxSpread_PriceUSD` — at a
$0.35 ceiling a wide-spread account will (correctly) keep the EA out of
the market most of the time.
