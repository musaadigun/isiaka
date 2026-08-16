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
ema, atr = df["ema"].to_numpy(), df["atr"].to_numpy()
dt = df["dt"].to_numpy()
n = len(df)

# Bars where the forward window would jump a weekend/holiday gap.
gap_after = np.zeros(n, bool)
gap_after[:-1] = (np.diff(dt).astype("timedelta64[m]").astype(int) > 60)

above = (c > ema)
cross_up = np.zeros(n, bool); cross_up[1:] = above[1:] & ~above[:-1]
cross_dn = np.zeros(n, bool); cross_dn[1:] = ~above[1:] & above[:-1]

WARM = 200                      # let the EMA settle
cross_up[:WARM] = cross_dn[:WARM] = False

days = (df.dt.iloc[-1] - df.dt.iloc[0]).days
print(f"bars {n:,}   {df.dt.iloc[0]:%Y-%m-%d} -> {df.dt.iloc[-1]:%Y-%m-%d}   "
      f"price {c.min():.0f}..{c.max():.0f}")
print(f"cross up {cross_up.sum():,}   cross dn {cross_dn.sum():,}   "
      f"total {cross_up.sum()+cross_dn.sum():,}  "
      f"({(cross_up.sum()+cross_dn.sum())/days:.1f}/day)")

def clean(idx, hbars):
    """Drop events whose forward window runs off the end or over a gap."""
    keep = []
    for i in idx:
        if i + hbars + 1 >= n:
            continue
        if gap_after[i:i + hbars + 1].any():
            continue
        keep.append(i)
    return np.array(keep, int)

up_idx = np.flatnonzero(cross_up)
dn_idx = np.flatnonzero(cross_dn)

# ===========================================================================
print("\n" + "=" * 78)
print("1. FORWARD MOVE AFTER CROSS   entry = next bar open, $/oz, gap-free windows")
print("=" * 78)
HZ = [1, 3, 6, 12, 24, 48, 96]

def label(b):
    return f"{b*5}m" if b * 5 < 60 else f"{b*5//60}h"

for name, idx, sign in [("LONG  (close crosses above EMA50)", up_idx, 1),
                        ("SHORT (close crosses below EMA50)", dn_idx, -1)]:
    print(f"\n{name}")
    print(f"  {'horizon':>8} {'n':>6} {'mean $':>9} {'median $':>9} {'win %':>7} "
          f"{'std $':>8} {'t-stat':>7}")
    for hb in HZ:
        ii = clean(idx, hb)
        r = (c[ii + hb + 1] - o[ii + 1]) * sign
        t = r.mean() / (r.std(ddof=1) / np.sqrt(len(r)))
        print(f"  {label(hb):>8} {len(r):>6} {r.mean():>9.3f} {np.median(r):>9.3f} "
              f"{(r > 0).mean()*100:>7.1f} {r.std(ddof=1):>8.2f} {t:>7.2f}")

print("\nBASELINE  (every bar, no signal — this is gold's drift, not an edge)")
print(f"  {'horizon':>8} {'n':>6} {'mean $':>9} {'median $':>9} {'win %':>7}")
for hb in HZ:
    ii = clean(np.arange(WARM, n), hb)
    r = c[ii + hb + 1] - o[ii + 1]
    print(f"  {label(hb):>8} {len(r):>6} {r.mean():>9.3f} {np.median(r):>9.3f} "
          f"{(r > 0).mean()*100:>7.1f}")

# ===========================================================================
print("\n" + "=" * 78)
print("2. HOW LONG DOES THE CROSS HOLD?  (bars until price crosses back)")
print("=" * 78)
flip = cross_up | cross_dn
flip_pos = np.flatnonzero(flip)

for name, idx in [("after cross up", up_idx), ("after cross down", dn_idx)]:
    life = []
    for i in idx:
        nxt = flip_pos[np.searchsorted(flip_pos, i, side="right")
                       :np.searchsorted(flip_pos, i, side="right") + 1]
        if len(nxt):
            life.append(nxt[0] - i)
    life = np.array(life)
    print(f"\n{name}:  n={len(life)}")
    print(f"  median {np.median(life):.0f} bars ({np.median(life)*5:.0f} min)   "
          f"mean {life.mean():.1f} bars")
    for p in (25, 50, 75, 90):
        print(f"  {p}th pct: {np.percentile(life, p):>5.0f} bars", end="")
    print()
    for thr in (1, 2, 3, 6, 12):
        print(f"  re-crosses within {thr:>2} bars: {(life <= thr).mean()*100:>5.1f}%")

# ===========================================================================
print("\n" + "=" * 78)
print("3. MFE / MAE AFTER ENTRY  (best and worst excursion, $/oz)")
print("=" * 78)
for name, idx, sign in [("LONG", up_idx, 1), ("SHORT", dn_idx, -1)]:
    print(f"\n{name}")
    print(f"  {'horizon':>8} {'n':>6} {'med MFE':>9} {'med MAE':>9} "
          f"{'MFE/MAE':>8} {'MAE>MFE %':>10}")
    for hb in [6, 12, 24, 48]:
        ii = clean(idx, hb)
        mfe, mae = [], []
        for i in ii:
            e = o[i + 1]
            hi, lo = h[i + 1:i + hb + 2].max(), l[i + 1:i + hb + 2].min()
            if sign > 0:
                mfe.append(hi - e); mae.append(e - lo)
            else:
                mfe.append(e - lo); mae.append(hi - e)
        mfe, mae = np.array(mfe), np.array(mae)
        print(f"  {label(hb):>8} {len(ii):>6} {np.median(mfe):>9.2f} "
              f"{np.median(mae):>9.2f} {np.median(mfe)/np.median(mae):>8.2f} "
              f"{(mae > mfe).mean()*100:>10.1f}")

# ===========================================================================
print("\n" + "=" * 78)
print("4. DOES A FILTER HELP?  long crosses, 24-bar (2h) forward move")
print("=" * 78)
HB = 24
ii = clean(up_idx, HB)
ret = c[ii + HB + 1] - o[ii + 1]

slope = (ema[ii] - ema[ii - 12]) / atr[ii]          # EMA slope in ATR units
dist  = (c[ii] - ema[ii]) / atr[ii]                 # cross size in ATR units
hour  = pd.to_datetime(dt[ii]).hour
vol   = atr[ii]

def bucket(name, vals, edges):
    print(f"\n  by {name}")
    print(f"    {'bucket':>16} {'n':>6} {'mean $':>9} {'win %':>7}")
    for lo_, hi_ in zip(edges[:-1], edges[1:]):
        m = (vals >= lo_) & (vals < hi_)
        if m.sum() < 30:
            continue
        print(f"    {f'{lo_:g} .. {hi_:g}':>16} {m.sum():>6} "
              f"{ret[m].mean():>9.3f} {(ret[m] > 0).mean()*100:>7.1f}")

bucket("EMA slope (ATR units)", slope, [-np.inf, -0.5, -0.1, 0.1, 0.5, np.inf])
bucket("cross size (ATR units)", dist, [0, 0.1, 0.25, 0.5, 1.0, np.inf])
bucket("ATR ($)", vol, [0, 1, 2, 3, 5, np.inf])
bucket("hour (server)", hour, [0, 4, 8, 12, 14, 16, 20, 24])
