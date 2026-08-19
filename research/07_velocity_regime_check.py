import pandas as pd, numpy as np
CSV="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/2863850e-1908_GOLD30.csv"
df=pd.read_csv(CSV,header=None,names=["date","time","open","high","low","close","vol"])
df["dt"]=pd.to_datetime(df["date"]+" "+df["time"],format="%Y.%m.%d %H:%M")
df=df.sort_values("dt").reset_index(drop=True)
df["ema"]=df["close"].ewm(span=20,adjust=False).mean()
tr=pd.concat([df["high"]-df["low"],(df["high"]-df["close"].shift()).abs(),
              (df["low"]-df["close"].shift()).abs()],axis=1).max(axis=1)
df["atr"]=tr.ewm(alpha=1/14,adjust=False).mean()
o,h,l,c=(df[x].to_numpy() for x in ("open","high","low","close"))
ema,atr,dt=df["ema"].to_numpy(),df["atr"].to_numpy(),df["dt"].to_numpy()
n=len(df); half=n//2

print("IS $10 THE SAME TRADE IN BOTH HALVES?")
for lbl,sl in [("1st half",slice(0,half)),("2nd half",slice(half,n))]:
    print(f"  {lbl}: price {c[sl].mean():7.0f}   median ATR(M30) ${np.median(atr[sl]):5.2f}"
          f"   $10 = {10/np.median(atr[sl]):4.2f} ATR   = {10/c[sl].mean()*100:.3f}% of price")

vel=np.full(n,np.nan); vel[3:]=(c[3:]-c[:-3])/1.5
above=c>ema
cu=np.zeros(n,bool); cu[1:]=above[1:]&~above[:-1]
cd=np.zeros(n,bool); cd[1:]=~above[1:]&above[:-1]
cu[:60]=cd[:60]=False

rows=[]
for i in np.flatnonzero(cu|cd):
    if i+1>=n or not np.isfinite(vel[i]) or atr[i]<=0: continue
    s=1 if cu[i] else -1
    rows.append(dict(i=i,sign=s,entry=o[i+1],v=s*vel[i],atr=atr[i]))
ev=pd.DataFrame(rows)
# velocity per ATR-hour: strips out the volatility regime
ev["vn"]=ev.v/(ev.atr/0.5)

H=16
def mfe_mae(r):
    end=min(r.i+1+H,n-1)
    sh,sl_=h[r.i+1:end+1],l[r.i+1:end+1]
    if len(sh)==0: return 0.0,0.0
    return ((sh.max()-r.entry),(r.entry-sl_.min())) if r.sign>0 else ((r.entry-sl_.min()),(sh.max()-r.entry))
mm=[mfe_mae(r) for r in ev.itertuples()]
ev["mfe"]=[x[0] for x in mm]; ev["mae"]=[x[1] for x in mm]
ev["hit10"]=(ev.mfe>=10).astype(int)
ev["hitATR"]=(ev.mfe>=1.5*ev.atr).astype(int)      # regime-neutral equivalent

print("\n" + "="*78)
print("SIGNED vs ABSOLUTE velocity - does velocity predict DIRECTION or just SIZE?")
print("="*78)
print(f"  {'normalised velocity':>22} {'n':>5} {'hit $10':>8} {'hit 1.5ATR':>11} {'med MFE':>8} {'med MAE':>8}")
for lo,hi in zip([-9,-1.5,-0.75,-0.25,0.25,0.75,1.5],[-1.5,-0.75,-0.25,0.25,0.75,1.5,9]):
    m=ev[(ev.vn>=lo)&(ev.vn<hi)]
    if len(m)<25: continue
    print(f"  {f'{lo:g} .. {hi:g}':>22} {len(m):>5} {m.hit10.mean()*100:>7.1f}% "
          f"{m.hitATR.mean()*100:>10.1f}% {m.mfe.median():>7.2f} {m.mae.median():>7.2f}")

print("\n  by ABSOLUTE normalised velocity (direction discarded):")
print(f"  {'|velocity|':>22} {'n':>5} {'hit $10':>8} {'hit 1.5ATR':>11} {'med MFE':>8} {'med MAE':>8}")
ev["av"]=ev.vn.abs()
for lo,hi in zip([0,0.25,0.75,1.5],[0.25,0.75,1.5,9]):
    m=ev[(ev.av>=lo)&(ev.av<hi)]
    if len(m)<25: continue
    print(f"  {f'{lo:g} .. {hi:g}':>22} {len(m):>5} {m.hit10.mean()*100:>7.1f}% "
          f"{m.hitATR.mean()*100:>10.1f}% {m.mfe.median():>7.2f} {m.mae.median():>7.2f}")

print("\n  regime-neutral target, split by half (does the ranking survive?):")
print(f"  {'|velocity|':>22} {'1st hit1.5ATR':>14} {'2nd hit1.5ATR':>14}")
for lo,hi in zip([0,0.25,0.75,1.5],[0.25,0.75,1.5,9]):
    m=ev[(ev.av>=lo)&(ev.av<hi)]
    a,b=m[m.i<half],m[m.i>=half]
    if len(a)<15 or len(b)<15: continue
    print(f"  {f'{lo:g} .. {hi:g}':>22} {a.hitATR.mean()*100:>13.1f}% {b.hitATR.mean()*100:>13.1f}%")
