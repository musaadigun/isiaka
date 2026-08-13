# Backtest harness

Tick-replay validation for `mt4/GoldScalperM1M5.mq4`. The engine mirrors
the EA's decision logic function-for-function and replays it over real
bid/ask ticks, so spread — the gold scalper's #1 opponent — is inside
every number it prints. MT4's own strategy tester interpolates M1 ticks
and will flatter a scalper; do not trust it for this strategy.

## 1. Get tick data (free, no account)

```bash
python3 download_dukascopy.py --start 2025-01-01 --end 2025-06-30 --out data/
```

One CSV per trading day (`time_ms,bid,ask`, UTC). Six months of XAUUSD
is roughly 2–4 GB and takes a while — let it run. Re-runs skip days
already downloaded.

## 2. Run

```bash
python3 engine.py --data 'data/XAUUSD_*.csv' \
    --balance 10000 --risk 0.5 \
    --commission 7.0 --slippage 0.03 \
    --trades-out trades.csv
```

Set `--commission` to what your broker actually charges per lot round
trip, and use `--spread-add 0.05` as a stress test (results should
degrade gracefully, not collapse — a strategy that dies from +$0.05
spread has no real edge).

`--no-sessions` trades around the clock; the default restricts entries
to London/NY hours (UTC). The EA's session inputs are **broker time** —
translate before comparing runs.

## 3. Read results honestly

The summary prints expectancy per trade, profit factor, max drawdown,
worst day, and two diagnostic maps: `exit_reasons` (how trades end —
a healthy scalper shows many small FAST CUT / FAILURE TO LAUNCH exits
and fewer, larger TRAIL STOP wins) and `blocked` (why signals didn't
fire — this is the tuning map).

Rules of the road, in order:

1. **Split the data in half.** Tune only on the first half. A setting
   that only works on the half you tuned it on is curve fit, not edge.
2. **Expectancy must clear zero after costs** on BOTH halves.
3. **Change one parameter at a time** and keep notes. The `blocked`
   counters tell you which gate to loosen; loosen the one that blocks
   the most, re-run, compare.
4. The fade module stays off (`--enable-fade` to test it) until it
   proves itself here. Fading gold failed stability tests on H4 in the
   prior research cycle — M1 is a new hypothesis, not a free pass.
