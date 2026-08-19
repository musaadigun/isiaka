"""
What crossing velocity gives the best chance of a $10 extension?

Velocity is computed exactly as the EA does on M30:
    V = (close[1] - close[4]) / 1.5h        ($ per hour, 3-bar lookback)
and sign-adjusted by cross direction, so positive = moving with the cross.

Reference price is the NEXT BAR OPEN - what a trade actually gets - not the
crossing price, which is not executable in bar data.
"""
import pandas as pd, numpy as np

CSV = "/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/2863850e-1908_GOLD30.csv"
TARGET = 10.0        # the $10 extension asked about

df = pd.read_csv(CSV, header=None,
                 names=["date","time","open","high","low","close","vol"])
df["dt"] = pd.to_datetime(df["date"]+" "+df["time"], format="%Y.%m.%d %H:%M")
df = df.sort_values("dt").reset_index(drop=True)

df["ema"] = df["close"].ewm(span=20, adjust=False).mean()
tr = pd.concat([df["high"]-df["low"],
                (df["high"]-df["close"].shift()).abs(),
                (df["low"]-df["close"].shift()).abs()],axis=1).max(axis=1)
df["atr"] = tr.ewm(alpha=1/14, adjust=False).mean()

o,h,l,c = (df[x].to_numpy() for x in ("open","high","low","close"))
ema,atr,dt = df["ema"].to_numpy(), df["atr"].to_numpy(), df["dt"].to_numpy()
n=len(df); half=n//2

vel = np.full(n,np.nan); vel[3:] = (c[3:]-c[:-3])/1.5          # $/hour
acc = np.full(n,np.nan); acc[1:] = (vel[1:]-vel[:-1])/0.5      # $/hour^2
grad= np.full(n,np.nan); grad[2:] = (ema[2:]-ema[:-2])/np.maximum(atr[2:],1e-9)

above = c>ema
cu=np.zeros(n,bool); cu[1:] = above[1:] & ~above[:-1]
cd=np.zeros(n,bool); cd[1:] = ~above[1:] & above[:-1]
cu[:60]=cd[:60]=False

print(f"M30 bars {n:,}   {pd.Timestamp(dt[0]):%Y-%m-%d} -> {pd.Timestamp(dt[-1]):%Y-%m-%d}")
print(f"crosses: {cu.sum()} up, {cd.sum()} down, {cu.sum()+cd.sum()} total")

# ---- build the event table -------------------------------------------------
rows=[]
for i in np.flatnonzero(cu|cd):
    if i+1>=n or not np.isfinite(vel[i]) or not np.isfinite(acc[i]):
        continue
    s = 1 if cu[i] else -1
    e = o[i+1]
    rows.append(dict(i=i, sign=s, entry=e,
                     v=s*vel[i], a=s*acc[i], g=s*grad[i], atr=atr[i]))
ev = pd.DataFrame(rows)
print(f"usable events: {len(ev)}")

def race(i, e, s, target, stop, horizon):
    """+target reached before -stop, within horizon bars? 1 win / 0 loss / -1 neither."""
    end=min(i+1+horizon, n-1)
    tp = e + s*target
    sl = e - s*stop
    for j in range(i+1, end+1):
        if s>0:
            if l[j]<=sl: return 0
            if h[j]>=tp: return 1
        else:
            if h[j]>=sl: return 0
            if l[j]<=tp: return 1
    return -1

def mfe_hit(i, e, s, target, horizon):
    end=min(i+1+horizon, n-1)
    seg_h, seg_l = h[i+1:end+1], l[i+1:end+1]
    if len(seg_h)==0: return 0
    mfe = (seg_h.max()-e) if s>0 else (e-seg_l.min())
    return int(mfe>=target)

H=16   # 8 hours
ev["hit10"]      = [mfe_hit(r.i,r.entry,r.sign,TARGET,H) for r in ev.itertuples()]
ev["race_10_10"] = [race(r.i,r.entry,r.sign,TARGET,10.0,H) for r in ev.itertuples()]
ev["race_10_5"]  = [race(r.i,r.entry,r.sign,TARGET,5.0,H)  for r in ev.itertuples()]

base = ev
print(f"\nBASELINE, all crosses, {H} bars (8h)")
print(f"  reach +$10 at any point           : {base.hit10.mean()*100:5.1f}%")
r=base[base.race_10_10>=0]; print(f"  +$10 before -$10 (of decided, n={len(r)}): {r.race_10_10.mean()*100:5.1f}%")
r=base[base.race_10_5>=0];  print(f"  +$10 before -$5  (of decided, n={len(r)}): {r.race_10_5.mean()*100:5.1f}%")

print(f"\nvelocity distribution ($/h, sign-adjusted):")
for p in (5,25,50,75,95):
    print(f"   {p:>2}th pct {np.percentile(ev.v,p):>8.2f}", end="")
print()

# ---- threshold sweep -------------------------------------------------------
print("\n" + "="*94)
print(f"VELOCITY THRESHOLD SWEEP   (v >= X), horizon {H} bars")
print("="*94)
print(f"  {'v >=':>7} {'n':>5} {'% kept':>7} {'hit +$10':>9} {'+10 b4 -10':>11} "
      f"{'+10 b4 -5':>10} {'1st half':>9} {'2nd half':>9}")
for thr in [-99,0,0.5,1,1.5,2,2.5,3,4,5,6,8,10]:
    m = ev[ev.v>=thr]
    if len(m)<25: continue
    d1 = m[m.race_10_10>=0]
    d2 = m[m.race_10_5>=0]
    h1 = m[m.i<half]; h2 = m[m.i>=half]
    lbl = "all" if thr==-99 else f"{thr:g}"
    print(f"  {lbl:>7} {len(m):>5} {len(m)/len(ev)*100:>6.0f}% "
          f"{m.hit10.mean()*100:>8.1f}% "
          f"{(d1.race_10_10.mean()*100 if len(d1)>10 else float('nan')):>10.1f}% "
          f"{(d2.race_10_5.mean()*100 if len(d2)>10 else float('nan')):>9.1f}% "
          f"{(h1.hit10.mean()*100 if len(h1)>10 else float('nan')):>8.1f}% "
          f"{(h2.hit10.mean()*100 if len(h2)>10 else float('nan')):>8.1f}%")

print("\n" + "="*94)
print("VELOCITY BUCKETS (not cumulative) - is the relationship monotonic?")
print("="*94)
print(f"  {'bucket ($/h)':>16} {'n':>5} {'hit +$10':>9} {'+10 b4 -10':>11} {'median MFE':>11}")
edges=[-1e9,-4,-2,0,2,4,6,8,1e9]
for lo,hi in zip(edges[:-1],edges[1:]):
    m=ev[(ev.v>=lo)&(ev.v<hi)]
    if len(m)<25: continue
    d=m[m.race_10_10>=0]
    mfes=[]
    for r in m.itertuples():
        end=min(r.i+1+H,n-1)
        mfes.append((h[r.i+1:end+1].max()-r.entry) if r.sign>0 else (r.entry-l[r.i+1:end+1].min()))
    lbl=f"{lo:g} .. {hi:g}".replace("-1e+09","-inf").replace("1e+09","inf")
    print(f"  {lbl:>16} {len(m):>5} {m.hit10.mean()*100:>8.1f}% "
          f"{(d.race_10_10.mean()*100 if len(d)>10 else float('nan')):>10.1f}% "
          f"{np.median(mfes):>10.2f}")
