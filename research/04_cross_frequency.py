import pandas as pd, numpy as np

CSV = "/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/f7e662b4-new_GOLD5.csv"
df = pd.read_csv(CSV, header=None,
                 names=["date", "time", "open", "high", "low", "close", "vol"])
df["dt"] = pd.to_datetime(df["date"] + " " + df["time"], format="%Y.%m.%d %H:%M")
df = df.sort_values("dt").reset_index(drop=True)
df["ema"] = df["close"].ewm(span=50, adjust=False).mean()

tr = pd.concat([df["high"] - df["low"],
                (df["high"] - df["close"].shift()).abs(),
                (df["low"] - df["close"].shift()).abs()], axis=1).max(axis=1)
df["atr"] = tr.ewm(alpha=1/14, adjust=False).mean()

c, ema = df["close"].to_numpy(), df["ema"].to_numpy()
n = len(df)
above = c > ema
cross = np.zeros(n, bool)
cross[1:] = above[1:] != above[:-1]
cross[:200] = False
df["cross"] = cross

# --- denominator check -----------------------------------------------------
df["day"] = df["dt"].dt.date
per_day = df.groupby("day").agg(bars=("close", "size"), crosses=("cross", "sum"))
trading_days = (per_day.bars >= 50).sum()          # ignore stub sessions
cal_days = (df.dt.iloc[-1] - df.dt.iloc[0]).days

print("DENOMINATOR CHECK")
print(f"  total crosses      : {cross.sum():,}")
print(f"  calendar days      : {cal_days}   -> {cross.sum()/cal_days:.1f}/day")
print(f"  days with any bars : {len(per_day)}")
print(f"  real trading days  : {trading_days}   -> {cross.sum()/trading_days:.1f}/day")
print(f"  bars per trading day (median): {per_day[per_day.bars>=50].bars.median():.0f}"
      f"  (a full M5 session is 288)")

full = per_day[per_day.bars >= 250]
print(f"\nCROSSES PER FULL SESSION  (n={len(full)} days with >=250 bars)")
print(f"  mean {full.crosses.mean():.1f}   median {full.crosses.median():.0f}")
for p in (5, 25, 50, 75, 95):
    print(f"  {p:>2}th pct: {np.percentile(full.crosses, p):>4.0f}", end="")
print()
print("\n  distribution:")
bins = [0, 5, 10, 15, 20, 30, 100]
for lo, hi in zip(bins[:-1], bins[1:]):
    m = (full.crosses >= lo) & (full.crosses < hi)
    if m.sum():
        print(f"    {lo:>3}-{hi-1:<3} crosses: {m.sum():>4} days  "
              f"{'#' * int(m.sum()/2)}")

print(f"\n  quietest day: {full.crosses.idxmin()}  {full.crosses.min()} crosses")
print(f"  busiest  day: {full.crosses.idxmax()}  {full.crosses.max()} crosses")

# --- worked example: print every cross on one ordinary day -----------------
target = full.crosses.sub(full.crosses.median()).abs().idxmin()
print("\n" + "=" * 74)
print(f"WORKED EXAMPLE — every close-vs-EMA50 cross on {target}")
print("=" * 74)
d = df[df.day == target].reset_index(drop=True)
cx = d.index[d.cross].tolist()
print(f"{len(cx)} crosses that day. Bars either side of each:\n")
print(f"  {'time':>6} {'close':>9} {'EMA50':>9} {'diff':>7}  side")
for k in cx:
    for j in range(max(0, k - 1), min(len(d), k + 2)):
        r = d.iloc[j]
        stamp = r["dt"].strftime("%H:%M")
        side = "above" if r["close"] > r["ema"] else "below"
        mark = "  <== CROSS" if j == k else ""
        print(f"  {stamp:>6} {r['close']:>9.2f} {r['ema']:>9.2f} "
              f"{r['close'] - r['ema']:>+7.2f}  {side}{mark}")
    print()

# --- reconciliation: how many crosses are visible at chart scale? ----------
print("=" * 74)
print("RECONCILIATION — crosses that actually GO somewhere")
print("=" * 74)
print("A cross counts only if price then extends past the EMA by the given")
print("margin before crossing back. Small margins = every wiggle counts.\n")
print(f"  {'margin':>22} {'crosses':>9} {'per session':>13}")

cross_idx = np.flatnonzero(cross)
atr = df["atr"].to_numpy()
for label_, margin_fn in [
    ("any wiggle ($0)",        lambda i: 0.0),
    ("$1.00",                  lambda i: 1.0),
    ("$2.00",                  lambda i: 2.0),
    ("$5.00",                  lambda i: 5.0),
    ("0.5 x ATR",              lambda i: 0.5 * atr[i]),
    ("1.0 x ATR",              lambda i: 1.0 * atr[i]),
    ("2.0 x ATR",              lambda i: 2.0 * atr[i]),
]:
    kept = 0
    for pos, i in enumerate(cross_idx):
        nxt = cross_idx[pos + 1] if pos + 1 < len(cross_idx) else n
        seg = slice(i, min(nxt, n))
        excursion = np.max(np.abs(c[seg] - ema[seg])) if nxt > i else 0.0
        if excursion >= margin_fn(i):
            kept += 1
    print(f"  {label_:>22} {kept:>9,} {kept/trading_days:>13.1f}")
