"""
What actually detects a spike?

A spike is DISTANCE / TIME-IT-TOOK. The EA's acceleration divides by a fixed
1.5h window, so it cannot see how long a move took - study 13 measured its
correlation with move concentration at +0.046.

Candidates tested here, all computable live from closed sub-bars:
  R   range/ATR      (high[0]-low[0]) / ATR                     - crude, no clock
  P   peak sub-move  largest single M5 close-to-close step / ATR
  C   concentration  largest step / sum of |steps|              - pure shape
  IV  peak velocity  largest step converted to $/hour           - true rate
  VR  velocity ratio peak velocity / median peak of last 20 bars - regime-relative
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
slots=f.index.to_numpy(); n=len(c30)
part=(d5[d5.slot.isin(f.index)].assign(s=lambda x:x.groupby("slot").cumcount()+1)
      .pivot_table(index="slot",columns="s",values="close")).loc[f.index].to_numpy()

tr=np.maximum.reduce([h30[1:]-l30[1:],np.abs(h30[1:]-c30[:-1]),np.abs(l30[1:]-c30[:-1])])
atr=pd.Series(np.r_[np.nan,tr]).ewm(alpha=1/14,adjust=False).mean().to_numpy()

# EA acceleration for comparison
V=np.full(n,np.nan); V[3:]=(c30[3:]-c30[:-3])/1.5
A=np.full(n,np.nan); A[4:]=(V[4:]-V[3:-1])/0.5

steps=np.diff(np.c_[c30[:-1],part[1:]],axis=1)          # 6 M5 steps per bar
S=np.full((n,6),np.nan); S[1:]=steps
peak=np.nanmax(np.abs(S),axis=1)
tot =np.nansum(np.abs(S),axis=1)
disp=np.full(n,np.nan); disp[1:]=c30[1:]-c30[:-1]

R  = (h30-l30)/atr
P  = peak/atr
C  = np.where(tot>0,peak/tot,np.nan)
IV = peak/(5/60.0)                                       # $/hour over the fast step
VR = IV/pd.Series(IV).rolling(20,min_periods=10).median().to_numpy()

m=np.isfinite(A)&np.isfinite(C)&np.isfinite(VR)&np.isfinite(R)
print(f"complete M30 bars: {n:,}   usable: {m.sum():,}")

print("\n"+"="*80)
print("WHICH MEASURES SPEED, AND WHICH JUST MEASURES DISTANCE?")
print("="*80)
print(f"  {'detector':>28} {'corr w/ CONCENTRATION':>22} {'corr w/ DISPLACEMENT':>21}")
for nm,x in [("EA acceleration |A|",np.abs(A)),
             ("R  range / ATR",R),
             ("P  peak sub-move / ATR",P),
             ("C  concentration",C),
             ("IV peak velocity $/h",IV),
             ("VR velocity ratio",VR)]:
    k=m&np.isfinite(x)
    print(f"  {nm:>28} {np.corrcoef(x[k],C[k])[0,1]:>21.3f} "
          f"{np.corrcoef(x[k],np.abs(disp[k]))[0,1]:>20.3f}")

print("\n  A detector for SPIKES should score high on concentration.")
print("  A detector for BIG MOVES scores high on displacement. They are not the same.")

print("\n"+"="*80)
print("SAME-SIZE TEST: bars moving $8-$15, split by how the move arrived")
print("="*80)
band=m&(np.abs(disp)>=8)&(np.abs(disp)<=15)
slow=band&(C<0.35); fast=band&(C>=0.55)
print(f"  {'detector':>28} {'slow drift':>12} {'fast spike':>12} {'ratio':>8}")
for nm,x in [("EA acceleration |A|",np.abs(A)),("R  range / ATR",R),
             ("P  peak sub-move / ATR",P),("IV peak velocity $/h",IV),
             ("VR velocity ratio",VR)]:
    a,b=np.nanmedian(x[slow]),np.nanmedian(x[fast])
    print(f"  {nm:>28} {a:>12.2f} {b:>12.2f} {b/a:>8.2f}x")
print(f"\n  n = {slow.sum()} slow, {fast.sum()} fast, comparable displacement")

print("\n"+"="*80)
print("WHEN WOULD IT FIRE? largest bars, VR read at each 5-minute step")
print("="*80)
big=np.argsort(np.where(m,np.abs(disp),-1))[-6:][::-1]
base=pd.Series(IV).rolling(20,min_periods=10).median().to_numpy()
print(f"  {'bar':>17} {'move':>8}   VR after 5/10/15/20/25/30 min")
for i in big:
    run=[]
    for k in range(6):
        st=np.abs(S[i,:k+1]); pk=np.nanmax(st) if len(st) else np.nan
        run.append((pk/(5/60.0))/base[i] if base[i]>0 else np.nan)
    print(f"  {pd.Timestamp(slots[i]):%Y-%m-%d %H:%M} {disp[i]:>+8.2f}   "
          +"  ".join(f"{v:4.1f}" for v in run))
