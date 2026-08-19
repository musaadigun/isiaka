#!/usr/bin/env python3
"""
Per-candle velocity and acceleration, using the EA's exact formulas.

    V(t) = (close[t] - close[t-3]) / elapsedHours      elapsedHours = 3 x TF/3600
    A(t) = (V(t) - V(t-1)) / barHours                  barHours     =     TF/3600

Equivalently, and identically:
    A(t) = [ (close[t]-close[t-1]) - (close[t-3]-close[t-4]) ] / (elapsed*bar)

Usage:  python3 calc_velocity_acceleration.py <csv> [timeframe_minutes]
CSV is the MT4 export format: date,time,open,high,low,close,volume
"""
import sys, pandas as pd, numpy as np

path = sys.argv[1]
tf_min = int(sys.argv[2]) if len(sys.argv) > 2 else 30
elapsed_h = 3 * tf_min / 60.0
bar_h = tf_min / 60.0

d = pd.read_csv(path, header=None,
                names=["date","time","open","high","low","close","vol"])
d["dt"] = pd.to_datetime(d.date + " " + d.time, format="%Y.%m.%d %H:%M")
d = d.sort_values("dt").reset_index(drop=True)
c = d.close.to_numpy(); n = len(c)

V = np.full(n, np.nan); V[3:] = (c[3:] - c[:-3]) / elapsed_h
A = np.full(n, np.nan); A[4:] = (V[4:] - V[3:-1]) / bar_h

print(f"timeframe M{tf_min}   elapsedHours={elapsed_h}   barHours={bar_h}\n")
print(f"{'#':>3} {'time':>6} {'close':>9} {'d(close)':>9} {'V $/h':>9} {'A $/h2':>10}")
print("-" * 60)
for i in range(n):
    dc = c[i] - c[i-1] if i > 0 else np.nan
    f = lambda x, w: (f"{x:+{w}.3f}" if np.isfinite(x) else " " * (w-1) + "-")
    print(f"{i+1:>3} {d.dt[i]:%H:%M} {c[i]:>9.2f} {f(dc,9)} {f(V[i],9)} {f(A[i],10)}")

fin = A[np.isfinite(A)]
if len(fin):
    print("-" * 60)
    print(f"computable {len(fin)}/{n}   A range {fin.min():+.2f}..{fin.max():+.2f}   "
          f"median |A| {np.median(np.abs(fin)):.2f}")
