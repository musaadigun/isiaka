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

o, h, l, c = (df[x].to_numpy() for x in ("open", "high", "low", "close"))
ema, atr, dt = df["ema"].to_numpy(), df["atr"].to_numpy(), df["dt"].to_numpy()
n = len(df)

above = c > ema
cu = np.zeros(n, bool); cu[1:] = above[1:] & ~above[:-1]
cd = np.zeros(n, bool); cd[1:] = ~above[1:] & above[:-1]
cu[:200] = cd[:200] = False

slope = np.full(n, np.nan)
slope[12:] = (ema[12:] - ema[:-12]) / np.maximum(atr[12:], 1e-9)


def simulate(idx, sign, sl_atr, tp_atr, max_bars, cost):
    """Bar-by-bar walk. Entry next bar open. If both SL and TP are inside the
    same bar, assume the stop filled first (pessimistic, and honest)."""
    pnl, hit_sl, hit_tp, timeout = [], 0, 0, 0
    for i in idx:
        if i + 1 >= n:
            continue
        e = o[i + 1]
        a = atr[i]
        if not np.isfinite(a) or a <= 0:
            continue
        sl = e - sign * sl_atr * a
        tp = e + sign * tp_atr * a
        end = min(i + 1 + max_bars, n - 1)
        out = None
        for j in range(i + 1, end + 1):
            if sign > 0:
                if l[j] <= sl: out = sl - e; hit_sl += 1; break
                if h[j] >= tp: out = tp - e; hit_tp += 1; break
            else:
                if h[j] >= sl: out = e - sl; hit_sl += 1; break
                if l[j] <= tp: out = e - tp; hit_tp += 1; break
        if out is None:
            out = sign * (c[end] - e); timeout += 1
        pnl.append(out - cost)
    p = np.array(pnl)
    return dict(n=len(p), mean=p.mean(), total=p.sum(),
                win=(p > 0).mean() * 100,
                t=p.mean() / (p.std(ddof=1) / np.sqrt(len(p))) if len(p) > 1 else 0,
                sl=hit_sl, tp=hit_tp, to=timeout)


print("=" * 78)
print("5. COST REALITY   raw cross, SL 1.5xATR / TP 2xATR, 48-bar cap")
print("=" * 78)
print("Gold spreads vary by broker; shown across a realistic retail range.")
print(f"\n  {'signal':>18} {'cost/trade':>11} {'n':>6} {'mean $':>9} "
      f"{'total $':>10} {'win %':>7} {'t':>6}")
for name, idx, sign in [("LONG raw", np.flatnonzero(cu), 1),
                        ("SHORT raw", np.flatnonzero(cd), -1)]:
    for cost in (0.00, 0.15, 0.30, 0.50):
        r = simulate(idx, sign, 1.5, 2.0, 48, cost)
        tag = "zero cost" if cost == 0 else f"${cost:.2f}"
        print(f"  {name:>18} {tag:>11} {r['n']:>6} {r['mean']:>9.3f} "
              f"{r['total']:>10.0f} {r['win']:>7.1f} {r['t']:>6.2f}")

print("\n" + "=" * 78)
print("6. THE SLOPE FILTER, IN vs OUT OF SAMPLE")
print("=" * 78)
half = n // 2
split_date = pd.Timestamp(dt[half])
print(f"first half : {pd.Timestamp(dt[0]):%Y-%m-%d} -> {split_date:%Y-%m-%d}")
print(f"second half: {split_date:%Y-%m-%d} -> {pd.Timestamp(dt[-1]):%Y-%m-%d}")

COST = 0.30
print(f"\ncost ${COST:.2f}/trade, SL 1.5xATR, TP 2xATR, 48-bar cap")
print(f"\n  {'variant':>34} {'period':>8} {'n':>5} {'mean $':>9} "
      f"{'total $':>9} {'win %':>7} {'t':>6}")

variants = [
    ("long, any slope",        np.flatnonzero(cu), 1, None),
    ("long, slope > 0",        np.flatnonzero(cu & (slope > 0)), 1, None),
    ("long, slope > 0.1",      np.flatnonzero(cu & (slope > 0.1)), 1, None),
    ("short, any slope",       np.flatnonzero(cd), -1, None),
    ("short, slope < 0",       np.flatnonzero(cd & (slope < 0)), -1, None),
    ("short, slope < -0.1",    np.flatnonzero(cd & (slope < -0.1)), -1, None),
]
for name, idx, sign, _ in variants:
    for per, sel in [("1st", idx[idx < half]), ("2nd", idx[idx >= half]),
                     ("all", idx)]:
        if len(sel) < 20:
            continue
        r = simulate(sel, sign, 1.5, 2.0, 48, COST)
        print(f"  {name:>34} {per:>8} {r['n']:>5} {r['mean']:>9.3f} "
              f"{r['total']:>9.0f} {r['win']:>7.1f} {r['t']:>6.2f}")

print("\n" + "=" * 78)
print("7. SL/TP GRID   long + slope>0.1, cost $0.30 — is ANY combination positive?")
print("=" * 78)
idx = np.flatnonzero(cu & (slope > 0.1))
print(f"\n  {'SL(ATR)':>8} " + "".join(f"{f'TP {t}':>10}" for t in (1.0, 1.5, 2.0, 3.0, 4.0)))
for s in (0.5, 1.0, 1.5, 2.0, 3.0):
    row = f"  {s:>8.1f} "
    for t in (1.0, 1.5, 2.0, 3.0, 4.0):
        r = simulate(idx, 1, s, t, 48, 0.30)
        row += f"{r['mean']:>10.3f}"
    print(row)
print("\n  (cell = mean $ per trade after cost)")
