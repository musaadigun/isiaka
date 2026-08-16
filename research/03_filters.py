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

# --- H1 trend context, built from the M5 data and shifted to avoid lookahead
h1 = df.set_index("dt")["close"].resample("1h").last().dropna()
h1_ema = h1.ewm(span=50, adjust=False).mean()
h1_up = (h1 > h1_ema).shift(1).reindex(df["dt"], method="ffill").to_numpy()
h1_up = np.where(pd.isna(h1_up), False, h1_up).astype(bool)

o, h, l, c = (df[x].to_numpy() for x in ("open", "high", "low", "close"))
ema, atr = df["ema"].to_numpy(), df["atr"].to_numpy()
n = len(df)
half = n // 2

above = c > ema
cu = np.zeros(n, bool); cu[1:] = above[1:] & ~above[:-1]
cd = np.zeros(n, bool); cd[1:] = ~above[1:] & above[:-1]
cu[:200] = cd[:200] = False


def simulate(idx, sign, sl_atr=1.5, tp_atr=2.0, max_bars=48, cost=0.30, delay=1):
    pnl = []
    for i in idx:
        if i + delay >= n:
            continue
        e = o[i + delay]
        a = atr[i]
        if not np.isfinite(a) or a <= 0:
            continue
        sl, tp = e - sign * sl_atr * a, e + sign * tp_atr * a
        end = min(i + delay + max_bars, n - 1)
        out = None
        for j in range(i + delay, end + 1):
            if sign > 0:
                if l[j] <= sl: out = sl - e; break
                if h[j] >= tp: out = tp - e; break
            else:
                if h[j] >= sl: out = e - sl; break
                if l[j] <= tp: out = e - tp; break
        if out is None:
            out = sign * (c[end] - e)
        pnl.append(out - cost)
    p = np.array(pnl)
    if len(p) < 2:
        return None
    return dict(n=len(p), mean=p.mean(), total=p.sum(), win=(p > 0).mean() * 100,
                t=p.mean() / (p.std(ddof=1) / np.sqrt(len(p))))


def report(name, idx, sign, **kw):
    for per, sel in [("1st", idx[idx < half]), ("2nd", idx[idx >= half]), ("all", idx)]:
        r = simulate(sel, sign, **kw)
        if r is None:
            continue
        star = " <-- sign flip" if per == "2nd" and flip_check.get(name) is not None \
               and np.sign(r["mean"]) != np.sign(flip_check[name]) else ""
        if per == "1st":
            flip_check[name] = r["mean"]
        print(f"  {name:>38} {per:>4} {r['n']:>5} {r['mean']:>8.3f} "
              f"{r['total']:>8.0f} {r['win']:>6.1f} {r['t']:>6.2f}{star}")


flip_check = {}
hdr = f"  {'variant':>38} {'per':>4} {'n':>5} {'mean $':>8} {'total':>8} {'win%':>6} {'t':>6}"

print("=" * 84)
print("8. PERSISTENCE FILTER — wait k bars, only enter if the cross HELD")
print("   (motivated by: 50% of crosses reverse within 3 bars)")
print("=" * 84)
print(hdr)
for k in (1, 2, 3, 6):
    held = np.zeros(n, bool)
    src = np.flatnonzero(cu)
    src = src[src + k < n]
    held[src[np.all([c[src + j] > ema[src + j] for j in range(1, k + 1)], axis=0)]] = True
    report(f"long, held {k} bars", np.flatnonzero(held), 1, delay=k + 1)
print()
for k in (1, 2, 3, 6):
    held = np.zeros(n, bool)
    src = np.flatnonzero(cd)
    src = src[src + k < n]
    held[src[np.all([c[src + j] < ema[src + j] for j in range(1, k + 1)], axis=0)]] = True
    report(f"short, held {k} bars", np.flatnonzero(held), -1, delay=k + 1)

print("\n" + "=" * 84)
print("9. HIGHER-TIMEFRAME ALIGNMENT — M5 cross only in the direction of H1 trend")
print("=" * 84)
print(hdr)
report("long, H1 above its EMA50",  np.flatnonzero(cu & h1_up),  1)
report("short, H1 below its EMA50", np.flatnonzero(cd & ~h1_up), -1)
print()
report("long, H1 aligned + held 3",
       np.flatnonzero(cu & h1_up &
                      np.r_[[False]*3, (c[3:] > ema[3:]) & (c[2:-1] > ema[2:-1]) &
                            (c[1:-2] > ema[1:-2])]), 1, delay=4)

print("\n" + "=" * 84)
print("10. SANITY CHECK — how much does the whole thing depend on gold's uptrend?")
print("=" * 84)
print(f"  price {c[0]:.0f} -> {c[-1]:.0f}   ({(c[-1]/c[0]-1)*100:+.1f}% over the sample)")
print(f"  buy and hold 1 oz, whole sample: ${c[-1]-c[0]:+,.0f}")
tot = np.flatnonzero(cu | cd).size
print(f"  total crosses: {tot:,} -> at $0.30 round-trip, "
      f"${tot*0.30:,.0f} paid in spread alone to trade every one")
