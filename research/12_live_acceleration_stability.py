"""
How much does live (shift 0) acceleration tell you before the M30 bar closes?

Uses the M5 export to reconstruct what A(0) and V(0) would have read at 5, 10,
15, 20, 25 and 30 minutes into each M30 bar, then compares each reading with the
value the same bar settles on at close.

  V(0) = (partialClose - close30[t-3]) / 1.5
  A(0) = (V(0) - V(1)) / 0.5,   V(1) = (close30[t-1] - close30[t-4]) / 1.5
"""
import pandas as pd, numpy as np

M5="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/f7e662b4-new_GOLD5.csv"
d5=pd.read_csv(M5,header=None,names=["date","time","open","high","low","close","vol"])
d5["dt"]=pd.to_datetime(d5.date+" "+d5.time,format="%Y.%m.%d %H:%M")
d5=d5.sort_values("dt").reset_index(drop=True)
d5["slot"]=d5.dt.dt.floor("30min")

g=d5.groupby("slot")
full=g.agg(close=("close","last"),cnt=("close","size"))
full=full[full.cnt==6]                       # complete M30 bars only
c30=full.close.to_numpy(); slots=full.index.to_numpy()
n=len(c30)
print(f"complete M30 bars reconstructed from M5: {n:,}")

# partial closes at each 5-minute step inside every M30 bar
part=(d5[d5.slot.isin(full.index)]
      .assign(step=lambda x: x.groupby("slot").cumcount()+1)
      .pivot_table(index="slot",columns="step",values="close"))
part=part.loc[full.index].to_numpy()          # shape (n, 6)

V1=np.full(n,np.nan); V1[4:]=(c30[3:-1]-c30[:-4])/1.5      # V(1) for bar t
rows=[]
for k in range(6):
    V0=np.full(n,np.nan); V0[3:]=(part[3:,k]-c30[:-3])/1.5
    A0=(V0-V1)/0.5
    rows.append((5*(k+1),V0,A0))

Vf,Af=rows[-1][1],rows[-1][2]                 # settled values at bar close
ok=np.isfinite(Af)&np.isfinite(Vf)

print("\n" + "="*84)
print("HOW CLOSE IS THE LIVE READING TO WHAT THE BAR SETTLES ON?")
print("="*84)
print(f"  {'minutes in':>11} {'ACCELERATION':>34} {'VELOCITY':>28}")
print(f"  {'':>11} {'corr':>8} {'sign agrees':>13} {'med |err|':>11} "
      f"{'corr':>8} {'sign agrees':>13} {'med |err|':>11}")
for mins,V0,A0 in rows:
    m=ok&np.isfinite(A0)&np.isfinite(V0)
    ca=np.corrcoef(A0[m],Af[m])[0,1]; cv=np.corrcoef(V0[m],Vf[m])[0,1]
    sa=(np.sign(A0[m])==np.sign(Af[m])).mean(); sv=(np.sign(V0[m])==np.sign(Vf[m])).mean()
    ea=np.median(np.abs(A0[m]-Af[m])); evv=np.median(np.abs(V0[m]-Vf[m]))
    print(f"  {mins:>9}m  {ca:>8.3f} {sa*100:>12.1f}% {ea:>10.2f}  "
          f"{cv:>8.3f} {sv*100:>12.1f}% {evv:>10.2f}")

print(f"\n  (settled |A| median = {np.median(np.abs(Af[ok])):.2f} $/h2, "
      f"|V| median = {np.median(np.abs(Vf[ok])):.2f} $/h)")

print("\n" + "="*84)
print("HOW OFTEN DOES THE SIGN FLIP DURING THE BAR?")
print("="*84)
S=np.vstack([np.sign(r[2]) for r in rows])
m=ok&np.isfinite(S).all(axis=0)
flips=(np.diff(S[:,m],axis=0)!=0).sum(axis=0)
print(f"  acceleration sign changes per bar: mean {flips.mean():.2f}   "
      f"never flips {np.mean(flips==0)*100:.1f}%   flips 2+ times {np.mean(flips>=2)*100:.1f}%")
Sv=np.vstack([np.sign(r[1]) for r in rows])
mv=ok&np.isfinite(Sv).all(axis=0)
fv=(np.diff(Sv[:,mv],axis=0)!=0).sum(axis=0)
print(f"  velocity     sign changes per bar: mean {fv.mean():.2f}   "
      f"never flips {np.mean(fv==0)*100:.1f}%   flips 2+ times {np.mean(fv>=2)*100:.1f}%")

print("\n" + "="*84)
print("ALTERNATIVE: compute motion on M5 CLOSED bars instead of a partial M30")
print("="*84)
c5=d5.close.to_numpy()
V5=np.full(len(c5),np.nan); V5[3:]=(c5[3:]-c5[:-3])/0.25     # 3 x M5 = 0.25h
A5=np.full(len(c5),np.nan); A5[1:]=(V5[1:]-V5[:-1])/(1/12)   # M5 bar = 1/12 h
print(f"  updates per M30 bar        : 6 (vs 1)")
print(f"  every reading uses CLOSED bars, so nothing repaints")
print(f"  median |A5| = {np.nanmedian(np.abs(A5)):.1f} $/h2   "
      f"median |V5| = {np.nanmedian(np.abs(V5)):.2f} $/h")
print(f"  corr(M5 acceleration, next M30 settled acceleration) = ", end="")
idx=pd.Series(np.arange(len(d5)),index=d5.dt)
last5=[idx.get(pd.Timestamp(s)+pd.Timedelta(minutes=25),np.nan) for s in slots]
last5=np.array([x if np.isfinite(x) else -1 for x in last5],dtype=int)
good=(last5>=0)&ok
print(f"{np.corrcoef(A5[last5[good]],Af[good])[0,1]:+.3f}")
