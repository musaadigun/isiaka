"""
Which measure actually tracks how fast the CURRENT candle is moving?

The EA's velocity spans 3 bars (90 min on M30), so it is the average speed of
the last hour and a half - not of this candle. Tested against three honest
definitions of a single candle's speed, all computed from M1/M5 sub-bars:

  net speed   |close - open| / barHours      where it ended up
  range speed (high - low)  / barHours       ground covered vertically
  path speed  sum|sub-bar steps| / barHours  distance actually travelled
"""
import pandas as pd, numpy as np

M5="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/f7e662b4-new_GOLD5.csv"
d5=pd.read_csv(M5,header=None,names=["date","time","open","high","low","close","vol"])
d5["dt"]=pd.to_datetime(d5.date+" "+d5.time,format="%Y.%m.%d %H:%M")
d5=d5.sort_values("dt").reset_index(drop=True)
d5["slot"]=d5.dt.dt.floor("30min")
g=d5.groupby("slot")
f=g.agg(o=("open","first"),h=("high","max"),l=("low","min"),c=("close","last"),k=("close","size"))
f=f[f.k==6]
o30,h30,l30,c30=(f[x].to_numpy() for x in "ohlc")
n=len(f)
part=(d5[d5.slot.isin(f.index)].assign(s=lambda x:x.groupby("slot").cumcount()+1)
      .pivot_table(index="slot",columns="s",values="close")).loc[f.index].to_numpy()

BH=0.5
net   = np.abs(c30-o30)/BH
rng   = (h30-l30)/BH
path  = np.full(n,np.nan)
path[1:] = np.abs(np.diff(np.c_[c30[:-1],part[1:]],axis=1)).sum(axis=1)/BH

# the EA's two measures (3-bar window)
V=np.full(n,np.nan); V[3:]=(c30[3:]-c30[:-3])/1.5
A=np.full(n,np.nan); A[1:]=(V[1:]-V[:-1])/0.5
# a velocity scoped to ONE candle
V1=np.full(n,np.nan); V1[1:]=(c30[1:]-c30[:-1])/BH

m=np.isfinite(V)&np.isfinite(A)&np.isfinite(path)
print(f"M30 bars {n:,}   usable {m.sum():,}\n")
print("="*80)
print("CORRELATION WITH THE CURRENT CANDLE'S OWN SPEED")
print("="*80)
print(f"  {'measure':>34} {'net':>9} {'range':>9} {'path':>9}")
for nm,x in [("EA velocity  |V|, 3-bar window",np.abs(V)),
             ("EA acceleration |A|, 3-bar",np.abs(A)),
             ("1-bar velocity |V1|",np.abs(V1))]:
    k=m&np.isfinite(x)
    print(f"  {nm:>34} {np.corrcoef(x[k],net[k])[0,1]:>9.3f} "
          f"{np.corrcoef(x[k],rng[k])[0,1]:>9.3f} {np.corrcoef(x[k],path[k])[0,1]:>9.3f}")

print("\n"+"="*80)
print("HOW MUCH OF THE EA's VELOCITY IS EVEN ABOUT THIS CANDLE?")
print("="*80)
print("  V spans 3 bars, so the current bar contributes roughly a third of it.")
for lag,lbl in [(0,"this candle"),(1,"one bar ago"),(2,"two bars ago")]:
    x=np.roll(np.abs(V1),lag); x[:lag]=np.nan
    k=m&np.isfinite(x)
    print(f"    corr(|V|, |1-bar move {lbl:>12}|) = {np.corrcoef(np.abs(V[k]),x[k])[0,1]:.3f}")

print("\n"+"="*80)
print("VARIANCE DECOMPOSITION: what does each measure actually respond to?")
print("="*80)
k=m
for nm,x in [("EA velocity V",V),("EA acceleration A",A),("1-bar velocity V1",V1)]:
    r_now=np.corrcoef(np.abs(x[k]),net[k])[0,1]**2
    print(f"  {nm:>20}: {r_now*100:5.1f}% of its variance is explained by "
          f"this candle's net move")

print("\n"+"="*80)
print("SANITY CHECK ON THE 2026-08-19 SPIKE CANDLE")
print("="*80)
M1="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/3608804c-GOLD1.csv"
m1=pd.read_csv(M1,header=None,names=["date","time","open","high","low","close","vol"])
m1["dt"]=pd.to_datetime(m1.date+" "+m1.time,format="%Y.%m.%d %H:%M")
b=m1[(m1.dt>=pd.Timestamp('2026-08-19 15:30'))&(m1.dt<pd.Timestamp('2026-08-19 16:00'))]
o,cl=b.open.iloc[0],b.close.iloc[-1]
print(f"  net speed   {abs(cl-o)/BH:8.1f} $/h")
print(f"  range speed {(b.high.max()-b.low.min())/BH:8.1f} $/h")
print(f"  path speed  {np.abs(np.diff(np.r_[o,b.close.to_numpy()])).sum()/BH:8.1f} $/h")
print(f"  peak minute {np.abs(np.diff(np.r_[o,b.close.to_numpy()])).max()*60:8.1f} $/h")
print(f"  EA velocity      +45.2 $/h   <- averaged over 90 min, understates it 3x")
print(f"  EA acceleration  +87.8 $/h2  <- different units, not a speed at all")
