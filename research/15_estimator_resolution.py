"""
Same quantity, different sampling: does estimating M30 acceleration from
sub-bar data beat the EA's 4-point M30 difference?

IMPORTANT: the window is held constant at 90 minutes throughout. This is not
"M1 acceleration vs M30 acceleration" - those are different quantities (study
13 measured them at corr -0.033). This is the SAME 90-minute motion, estimated
from 4 samples versus from 18.

  EA      : A = [(c1-c2) - (c4-c5)] / 0.75          4 M30 closes
  FIT     : quadratic least-squares fit of price on time over the trailing
            90 minutes, using M5 closes; acceleration = 2*a coefficient
  (M1 would give 90 samples and be better still; only M5 is available here.)
"""
import pandas as pd, numpy as np

M5="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/f7e662b4-new_GOLD5.csv"
d5=pd.read_csv(M5,header=None,names=["date","time","open","high","low","close","vol"])
d5["dt"]=pd.to_datetime(d5.date+" "+d5.time,format="%Y.%m.%d %H:%M")
d5=d5.sort_values("dt").reset_index(drop=True)
d5["slot"]=d5.dt.dt.floor("30min")
g=d5.groupby("slot")
f=g.agg(h=("high","max"),l=("low","min"),c=("close","last"),k=("close","size"))
f=f[f.k==6]
h30,l30,c30=(f[x].to_numpy() for x in "hlc")
slots=f.index.to_numpy(); n=len(c30)

tr=np.maximum.reduce([h30[1:]-l30[1:],np.abs(h30[1:]-c30[:-1]),np.abs(l30[1:]-c30[:-1])])
atr=pd.Series(np.r_[np.nan,tr]).ewm(alpha=1/14,adjust=False).mean().to_numpy()

# --- estimator 1: the EA's 4-point M30 difference ---------------------------
V=np.full(n,np.nan); V[3:]=(c30[3:]-c30[:-3])/1.5
A_ea=np.full(n,np.nan); A_ea[4:]=(V[4:]-V[3:-1])/0.5

# --- estimator 2: quadratic fit over the same 90 minutes, M5 samples --------
c5=d5.close.to_numpy(); t5=d5.dt.to_numpy()
pos=pd.Series(np.arange(len(d5)),index=d5.dt)
end_idx=np.array([pos.get(pd.Timestamp(s)+pd.Timedelta(minutes=25),-1) for s in slots])
W=18                                   # 18 M5 bars = 90 minutes
x=np.arange(W)*(5/60.0)                # hours
Vd=np.vander(x,3)                      # [t^2, t, 1]
pinv=np.linalg.pinv(Vd)
A_fit=np.full(n,np.nan); V_fit=np.full(n,np.nan)
for i,e in enumerate(end_idx):
    if e<W-1: continue
    y=c5[e-W+1:e+1]
    if len(y)<W or not np.isfinite(y).all(): continue
    a,b,_=pinv@y
    A_fit[i]=2.0*a                     # d2p/dt2 in $/h^2
    V_fit[i]=2.0*a*x[-1]+b             # instantaneous velocity at window end

m=np.isfinite(A_ea)&np.isfinite(A_fit)
print(f"M30 bars {n:,}   comparable {m.sum():,}")
print(f"correlation between the two estimators: {np.corrcoef(A_ea[m],A_fit[m])[0,1]:+.3f}")
print(f"median |A|  EA {np.median(np.abs(A_ea[m])):7.2f}   FIT {np.median(np.abs(A_fit[m])):7.2f}")

print("\n"+"="*78)
print("NOISE: autocorrelation. The echo should show as a negative spike.")
print("="*78)
print(f"  {'lag':>5} {'EA 4-point':>13} {'quadratic fit':>15}")
for lag in range(1,7):
    a1=A_ea[m]; a2=A_fit[m]
    r1=np.corrcoef(a1[:-lag],a1[lag:])[0,1]
    r2=np.corrcoef(a2[:-lag],a2[lag:])[0,1]
    mark="  <-- echo" if lag==3 else ""
    print(f"  {lag:>5} {r1:>13.3f} {r2:>15.3f}{mark}")

print("\n"+"="*78)
print("STABILITY: how much does the reading jump bar to bar?")
print("="*78)
for nm,a in (("EA 4-point",A_ea[m]),("quadratic fit",A_fit[m])):
    d=np.abs(np.diff(a))
    print(f"  {nm:>14}: median |change| {np.median(d):7.2f}   "
          f"as % of median |A| {np.median(d)/np.median(np.abs(a))*100:5.0f}%")

print("\n"+"="*78)
print("SPIKE SENSITIVITY: same-size bars, slow drift vs fast burst")
print("="*78)
part=(d5[d5.slot.isin(f.index)].assign(s=lambda x:x.groupby("slot").cumcount()+1)
      .pivot_table(index="slot",columns="s",values="close")).loc[f.index].to_numpy()
S=np.full((n,6),np.nan); S[1:]=np.diff(np.c_[c30[:-1],part[1:]],axis=1)
peak=np.nanmax(np.abs(S),axis=1); tot=np.nansum(np.abs(S),axis=1)
conc=np.where(tot>0,peak/tot,np.nan)
disp=np.full(n,np.nan); disp[1:]=c30[1:]-c30[:-1]
band=m&np.isfinite(conc)&(np.abs(disp)>=8)&(np.abs(disp)<=15)
slow,fast=band&(conc<0.35),band&(conc>=0.55)
print(f"  {'estimator':>14} {'slow':>9} {'fast':>9} {'ratio':>8}")
for nm,a in (("EA 4-point",np.abs(A_ea)),("quadratic fit",np.abs(A_fit))):
    p,q=np.nanmedian(a[slow]),np.nanmedian(a[fast])
    print(f"  {nm:>14} {p:>9.2f} {q:>9.2f} {q/p:>7.2f}x")
print(f"  n = {slow.sum()} slow, {fast.sum()} fast")

print("\n"+"="*78)
print("DOES THE BETTER ESTIMATOR PREDICT BETTER? (top decile, 1.5 ATR reached)")
print("="*78)
H=16
mfe=np.full(n,np.nan)
for i in range(n-H-1):
    seg_h,seg_l=h30[i+1:i+1+H],l30[i+1:i+1+H]
    if len(seg_h)==0: continue
    mfe[i]=max(seg_h.max()-c30[i],c30[i]-seg_l.min())
ok=m&np.isfinite(mfe)&np.isfinite(atr)
hit=(mfe>=1.5*atr).astype(float)
base=hit[ok].mean()
print(f"  baseline, all bars: {base*100:.1f}%")
for nm,a in (("EA 4-point",A_ea),("quadratic fit",A_fit)):
    idx=np.flatnonzero(ok)
    top=idx[np.argsort(np.abs(a[idx]))[-int(ok.sum()*0.10):]]
    print(f"  {nm:>14} top decile by |A|: {hit[top].mean()*100:.1f}%  (n={len(top)})")
