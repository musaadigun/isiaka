"""
Can acceleration detect and track a spike inside the forming candle?

Three tests:
  1. Within a forming bar, c1/c3/c4 are frozen. Is A(0) then just the live
     price, rescaled?
  2. Does a spike leave an echo? A = [(c1-c2)-(c4-c5)]/0.75, so a single-bar
     move enters the second term three bars later with the opposite sign.
  3. Can A tell a fast spike from a slow drift covering the same distance?
"""
import pandas as pd, numpy as np

M5="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/f7e662b4-new_GOLD5.csv"
d5=pd.read_csv(M5,header=None,names=["date","time","open","high","low","close","vol"])
d5["dt"]=pd.to_datetime(d5.date+" "+d5.time,format="%Y.%m.%d %H:%M")
d5=d5.sort_values("dt").reset_index(drop=True)
d5["slot"]=d5.dt.dt.floor("30min")
g=d5.groupby("slot")
full=g.agg(close=("close","last"),cnt=("close","size"))
full=full[full.cnt==6]
c30=full.close.to_numpy(); slots=full.index.to_numpy(); n=len(c30)
part=(d5[d5.slot.isin(full.index)].assign(step=lambda x:x.groupby("slot").cumcount()+1)
      .pivot_table(index="slot",columns="step",values="close")).loc[full.index].to_numpy()

A=np.full(n,np.nan); A[4:]=((c30[4:]-c30[3:-1])-(c30[1:-3]-c30[:-4]))/0.75

print("="*80)
print("1. INSIDE A FORMING BAR, IS A(0) ANYTHING MORE THAN THE PRICE?")
print("="*80)
print("   A(0) = [c0 - c1 - c3 + c4] / 0.75, and c1,c3,c4 are already closed.")
print("   So within the bar only c0 moves:  dA/dc0 = 1/0.75 = 1.3333\n")
sl=[]
for t in range(4,n):
    V0=(part[t,:]-c30[t-3])/1.5
    V1=(c30[t-1]-c30[t-4])/1.5
    A0=(V0-V1)/0.5
    if np.isfinite(A0).all() and part[t,:].std()>1e-9:
        sl.append(np.polyfit(part[t,:],A0,1)[0])
sl=np.array(sl)
print(f"   measured slope of A(0) vs live price, over {len(sl):,} bars:")
print(f"     mean {sl.mean():.4f}   min {sl.min():.4f}   max {sl.max():.4f}   "
      f"std {sl.std():.2e}")
print("   -> exactly linear. Live acceleration IS the live price, rescaled,")
print("      plus a constant that is fixed for the whole bar.")

print("\n"+"="*80)
print("2. THE ECHO: does a spike come back with the opposite sign?")
print("="*80)
a=A[np.isfinite(A)]
print("   autocorrelation of acceleration:")
for lag in range(1,7):
    r=np.corrcoef(a[:-lag],a[lag:])[0,1]
    mark="  <-- the echo" if lag==3 else ""
    print(f"     lag {lag}: {r:+.3f}{mark}")

chg=np.full(n,np.nan); chg[1:]=c30[1:]-c30[:-1]
big=np.flatnonzero(np.abs(chg)>np.nanpercentile(np.abs(chg),99))
big=big[(big>6)&(big<n-8)]
print(f"\n   event study: {len(big)} single-bar moves in the top 1% "
      f"(>${np.nanpercentile(np.abs(chg),99):.2f})")
print(f"   {'bars after spike':>18} {'median signed A':>17}")
for k in range(0,7):
    vals=[np.sign(chg[i])*A[i+k] for i in big if np.isfinite(A[i+k])]
    mark="  <-- opposite sign" if k==3 else ""
    print(f"   {k:>16}  {np.median(vals):>16.2f}{mark}")

print("\n"+"="*80)
print("3. FAST SPIKE vs SLOW DRIFT OF THE SAME SIZE")
print("="*80)
disp=np.full(n,np.nan); disp[1:]=c30[1:]-c30[:-1]
conc=np.full(n,np.nan)                      # share of the bar's move in its biggest M5 step
for t in range(1,n):
    steps=np.diff(np.concatenate(([c30[t-1]],part[t,:])))
    tot=np.abs(steps).sum()
    if tot>0: conc[t]=np.abs(steps).max()/tot
m=np.isfinite(A)&np.isfinite(disp)&np.isfinite(conc)&(np.abs(disp)>5)
print(f"   bars moving more than $5, n={m.sum():,}")
print(f"   {'move concentration':>20} {'n':>6} {'median |move|':>14} {'median |A|':>12}")
for lo,hi,lbl in [(0,0.35,"spread out (slow)"),(0.35,0.55,"mixed"),(0.55,1.01,"concentrated (spike)")]:
    k=m&(conc>=lo)&(conc<hi)
    if k.sum()<50: continue
    print(f"   {lbl:>20} {k.sum():>6} {np.median(np.abs(disp[k])):>13.2f} "
          f"{np.median(np.abs(A[k])):>11.2f}")
print("\n   correlation of |A| with:")
print(f"     bar displacement |c_t - c_t-1| : {np.corrcoef(np.abs(A[m]),np.abs(disp[m]))[0,1]:+.3f}")
print(f"     how concentrated the move was  : {np.corrcoef(np.abs(A[m]),conc[m])[0,1]:+.3f}")
