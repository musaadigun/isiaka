"""
Velocity and acceleration for each M30 candle, estimated from M1 samples.

Window held at 90 minutes throughout - the same span the EA's 3-bar lookback
covers - so this is the SAME quantity, estimated from 90 samples instead of 4.

  V_m1(t) = OLS slope of close on time over the trailing 90 M1 bars   [$/h]
  A_m1(t) = (V_m1(t) - V_m1(t-1)) / 0.5h                              [$/h2]

  V_ea(t) = (c30[t] - c30[t-3]) / 1.5h
  A_ea(t) = (V_ea(t) - V_ea(t-1)) / 0.5h
"""
import pandas as pd, numpy as np

M1="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/3608804c-GOLD1.csv"
m1=pd.read_csv(M1,header=None,names=["date","time","open","high","low","close","vol"])
m1["dt"]=pd.to_datetime(m1.date+" "+m1.time,format="%Y.%m.%d %H:%M")
m1=m1.sort_values("dt").reset_index(drop=True)

bars=m1.set_index("dt").resample("30min").agg(
    o=("open","first"),h=("high","max"),l=("low","min"),
    c=("close","last"),k=("close","size")).dropna()
bars=bars[bars.k==30]                       # completed M30 bars only
c30=bars.c.to_numpy(); slots=bars.index.to_numpy(); n=len(bars)
print(f"completed M30 candles rebuilt from M1: {n}  "
      f"({pd.Timestamp(slots[0]):%H:%M} -> {pd.Timestamp(slots[-1]):%H:%M})\n")

V_ea=np.full(n,np.nan); V_ea[3:]=(c30[3:]-c30[:-3])/1.5
A_ea=np.full(n,np.nan); A_ea[4:]=(V_ea[4:]-V_ea[3:-1])/0.5

cm=m1.close.to_numpy(); tm=m1.dt.to_numpy()
pos=pd.Series(np.arange(len(m1)),index=m1.dt)
W=90; x=np.arange(W)/60.0                    # hours
X=np.c_[x,np.ones(W)]; pinv=np.linalg.pinv(X)
V_m1=np.full(n,np.nan)
peak=np.full(n,np.nan); conc=np.full(n,np.nan)
for i,s in enumerate(slots):
    endt=pd.Timestamp(s)+pd.Timedelta(minutes=29)
    e=pos.get(endt,-1)
    if e>=W-1:
        y=cm[e-W+1:e+1]
        if len(y)==W and np.isfinite(y).all():
            V_m1[i]=(pinv@y)[0]
    b=m1[(m1.dt>=pd.Timestamp(s))&(m1.dt<pd.Timestamp(s)+pd.Timedelta(minutes=30))]
    if len(b)==30:
        prev=c30[i-1] if i>0 else b.open.iloc[0]
        steps=np.diff(np.r_[prev,b.close.to_numpy()])
        peak[i]=np.abs(steps).max()
        tot=np.abs(steps).sum()
        conc[i]=np.abs(steps).max()/tot if tot>0 else np.nan
A_m1=np.full(n,np.nan); A_m1[1:]=(V_m1[1:]-V_m1[:-1])/0.5

print(f"{'#':>3} {'time':>6} {'close':>9} {'V_ea':>9} {'A_ea':>10} | "
      f"{'V_m1':>9} {'A_m1':>10} | {'pk/min':>7} {'pk $/h':>8} {'conc':>6}")
print("-"*95)
def f(v,w,p=2):
    return f"{v:+{w}.{p}f}" if np.isfinite(v) else " "*(w-1)+"-"
for i in range(n):
    print(f"{i+1:>3} {pd.Timestamp(slots[i]):%H:%M} {c30[i]:>9.2f} "
          f"{f(V_ea[i],9,3)} {f(A_ea[i],10,3)} | {f(V_m1[i],9,3)} {f(A_m1[i],10,3)} | "
          f"{f(peak[i],7)} {f(peak[i]*60,8,1)} {conc[i]:>6.2f}")

m=np.isfinite(A_ea)&np.isfinite(A_m1)
print("-"*95)
print(f"correlation  V_ea vs V_m1 = {np.corrcoef(V_ea[m],V_m1[m])[0,1]:+.3f}    "
      f"A_ea vs A_m1 = {np.corrcoef(A_ea[m],A_m1[m])[0,1]:+.3f}")

print("\n" + "="*95)
print("THE 15:30 SPIKE, MINUTE BY MINUTE")
print("="*95)
b=m1[(m1.dt>=pd.Timestamp('2026-08-19 15:30'))&(m1.dt<pd.Timestamp('2026-08-19 16:00'))]
cl=b.close.to_numpy(); st=np.diff(np.r_[c30[list(slots).index(np.datetime64('2026-08-19T15:00'))],cl])
print(f"  bar open {b.open.iloc[0]:.2f}  close {cl[-1]:.2f}  move {cl[-1]-b.open.iloc[0]:+.2f}")
print(f"  fastest minute: {np.abs(st).max():.2f} at "
      f"{b.dt.iloc[int(np.argmax(np.abs(st)))]:%H:%M}  "
      f"= {np.abs(st).max()*60:.0f} $/h")
print(f"  first 10 min covered {cl[9]-b.open.iloc[0]:+.2f} of the {cl[-1]-b.open.iloc[0]:+.2f} total "
      f"({(cl[9]-b.open.iloc[0])/(cl[-1]-b.open.iloc[0])*100:.0f}%)")
run=np.r_[b.open.iloc[0],cl]-b.open.iloc[0]
print("  cumulative move at minute 5/10/15/20/25/30: "
      + "  ".join(f"{run[k]:+6.2f}" for k in (5,10,15,20,25,30)))

print("\n" + "="*95)
print("ECHO CHECK - I predicted A_ea would flip negative at 17:00")
print("="*95)
sp=list(slots).index(np.datetime64('2026-08-19T15:30'))
for k in range(0,5):
    if sp+k<n:
        print(f"  {pd.Timestamp(slots[sp+k]):%H:%M} (+{k} bars):  "
              f"A_ea {f(A_ea[sp+k],9,2)}    A_m1 {f(A_m1[sp+k],9,2)}")
