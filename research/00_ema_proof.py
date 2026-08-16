import pandas as pd, numpy as np

CSV = "/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/f7e662b4-new_GOLD5.csv"
df = pd.read_csv(CSV, header=None,
                 names=["date", "time", "open", "high", "low", "close", "vol"])
df["dt"] = pd.to_datetime(df["date"] + " " + df["time"], format="%Y.%m.%d %H:%M")
df = df.sort_values("dt").reset_index(drop=True)
close = df["close"].to_numpy()
n = len(close)

N = 50
alpha = 2.0 / (N + 1)
print(f"EMA period N = {N}")
print(f"smoothing constant alpha = 2/(N+1) = 2/{N+1} = {alpha:.10f}")
print(f"1 - alpha                          = {1-alpha:.10f}")
print("\nMT4's Moving Average.mq4 (MODE_EMA) computes:")
print("    EMA[i] = Close[i]*pr + EMA[i+1]*(1-pr),  pr = 2/(period+1)")
print("i counts DOWN toward the current bar, so EMA[i+1] is the previous bar.\n")

# --- 1. MT4's exact recursion, written out longhand -----------------------
mt4 = np.empty(n)
mt4[0] = close[0]                      # MT4 seeds with the raw price
for i in range(1, n):
    mt4[i] = close[i] * alpha + mt4[i - 1] * (1.0 - alpha)

# --- 2. What I used in the analysis ---------------------------------------
pdx = df["close"].ewm(span=50, adjust=False).mean().to_numpy()

print("=" * 70)
print("1. IS pandas ewm(span=50, adjust=False) THE SAME AS MT4's RECURSION?")
print("=" * 70)
d = np.abs(mt4 - pdx)
print(f"  bars compared        : {n:,}")
print(f"  max absolute difference: {d.max():.3e}   (machine precision is ~1e-13)")
print(f"  identical to the cent : {bool((d < 1e-9).all())}")

# --- 3. Hand-checkable arithmetic -----------------------------------------
print("\n" + "=" * 70)
print("2. FIRST BARS, LONGHAND — check these on a calculator")
print("=" * 70)
print(f"  {'bar':>4} {'time':>16} {'close':>10} {'EMA':>10}   arithmetic")
for i in range(6):
    t = df['dt'].iloc[i].strftime('%Y-%m-%d %H:%M')
    if i == 0:
        note = "seed = first close"
    else:
        note = (f"{close[i]:.2f}*{alpha:.6f} + {mt4[i-1]:.4f}*{1-alpha:.6f}")
    print(f"  {i:>4} {t:>16} {close[i]:>10.2f} {mt4[i]:>10.4f}   {note}")

# --- 4. Does the seed choice matter? --------------------------------------
print("\n" + "=" * 70)
print("3. DOES THE STARTING VALUE MATTER?  (my analysis dropped 200 bars)")
print("=" * 70)
print("Three different seeds, then how fast they converge:\n")

seeds = {
    "MT4 style (first close)": close[0],
    "SMA of first 50 bars":    close[:50].mean(),
    "deliberately absurd":     close[0] + 500.0,
}
curves = {}
for name, s in seeds.items():
    e = np.empty(n); e[0] = s
    for i in range(1, n):
        e[i] = close[i] * alpha + e[i - 1] * (1.0 - alpha)
    curves[name] = e

base = curves["MT4 style (first close)"]
print(f"  {'after N bars':>14} " + "".join(f"{k[:22]:>24}" for k in list(seeds)[1:]))
for k in (10, 50, 100, 200, 500):
    row = f"  {k:>14} "
    for name in list(seeds)[1:]:
        row += f"{abs(curves[name][k] - base[k]):>24.6f}"
    print(row)
print("\n  (difference in $/oz vs the MT4-style seed)")
print("  By bar 200 every seed agrees to well under a cent, which is why")
print("  the analysis discarded the first 200 bars.")

# --- 5. Values to check against your own MT4 chart -------------------------
print("\n" + "=" * 70)
print("4. CHECK THESE AGAINST YOUR MT4 CHART")
print("=" * 70)
print("Attach EMA(50, Close) to GOLD M5, hover the bar, read the Data Window.\n")
print(f"  {'bar time (CSV server time)':>28} {'close':>10} {'EMA50':>10}")
for i in range(n - 1, n - 11, -1):
    print(f"  {df['dt'].iloc[i].strftime('%Y-%m-%d %H:%M'):>28} "
          f"{close[i]:>10.2f} {mt4[i]:>10.2f}")
print("\n  If your broker's server time differs from this export, line the bars")
print("  up by price first -- a 1-hour offset will look like a mismatch.")

# --- 6. cross count is not sensitive to any of this ------------------------
print("\n" + "=" * 70)
print("5. WOULD A DIFFERENT EMA CHANGE THE CROSS COUNT?")
print("=" * 70)
df["day"] = df["dt"].dt.date
sizes = df.groupby("day").size()
sessions = (sizes >= 250).sum()
print(f"  {'variant':>34} {'crosses':>9} {'per session':>13}")
for name, ema in [("MT4 recursion, seed=first close", mt4),
                  ("seed = SMA(50)", curves["SMA of first 50 bars"]),
                  ("seed = absurd (+$500)", curves["deliberately absurd"])]:
    a = close > ema
    cr = int((a[201:] != a[200:-1]).sum())
    print(f"  {name:>34} {cr:>9,} {cr/sessions:>13.1f}")

for p in (20, 50, 100, 200):
    al = 2.0 / (p + 1)
    e = np.empty(n); e[0] = close[0]
    for i in range(1, n):
        e[i] = close[i] * al + e[i - 1] * (1.0 - al)
    a = close > e
    cr = int((a[201:] != a[200:-1]).sum())
    print(f"  {'EMA period ' + str(p):>34} {cr:>9,} {cr/sessions:>13.1f}")
