"""
V(0) = (close[0] - close[3]) / 1.5

Inside a forming bar close[3] is already fixed, so only close[0] moves. Is V(0)
therefore just the live price rescaled - the same defect acceleration had?
And how often does its SIGN differ from V(1), which is what a "> 0" gate cares
about?
"""
import pandas as pd, numpy as np

M5="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/f7e662b4-new_GOLD5.csv"
d5=pd.read_csv(M5,header=None,names=["date","time","open","high","low","close","vol"])
d5["dt"]=pd.to_datetime(d5.date+" "+d5.time,format="%Y.%m.%d %H:%M")
d5=d5.sort_values("dt").reset_index(drop=True)
d5["slot"]=d5.dt.dt.floor("30min")
g=d5.groupby("slot")
f=g.agg(c=("close","last"),k=("close","size")); f=f[f.k==6]
c30=f.c.to_numpy(); n=len(f)
part=(d5[d5.slot.isin(f.index)].assign(s=lambda x:x.groupby("slot").cumcount()+1)
      .pivot_table(index="slot",columns="s",values="close")).loc[f.index].to_numpy()

print("="*76)
print("1. INSIDE THE BAR, IS V(0) JUST THE PRICE RESCALED?")
print("="*76)
print("   V(0) = (c0 - c3)/1.5 and c3 is closed, so dV/dc0 = 1/1.5 = 0.6667\n")
sl=[]
for t in range(3,n):
    V0=(part[t,:]-c30[t-3])/1.5
    if part[t,:].std()>1e-9:
        sl.append(np.polyfit(part[t,:],V0,1)[0])
sl=np.array(sl)
print(f"   measured slope over {len(sl):,} bars: mean {sl.mean():.4f}  "
      f"min {sl.min():.4f}  max {sl.max():.4f}  std {sl.std():.1e}")
print("   -> yes. Same defect as acceleration, gentler slope (0.667 vs 1.333).")
print("      Within one bar it is a monotone function of price and nothing more.")

print("\n"+"="*76)
print("2. BUT DOES THAT MATTER? V(0) vs V(1) AS A '> 0' GATE")
print("="*76)
V1=np.full(n,np.nan); V1[4:]=(c30[3:-1]-c30[:-4])/1.5      # last CLOSED bar's V
rows=[]
for k in range(6):
    V0=np.full(n,np.nan); V0[3:]=(part[3:,k]-c30[:-3])/1.5
    rows.append((5*(k+1),V0))
m0=np.isfinite(V1)
print(f"  {'minutes in':>11} {'sign(V0) != sign(V1)':>22} {'corr':>8} {'median |V0-V1|':>16}")
for mins,V0 in rows:
    k=m0&np.isfinite(V0)
    print(f"  {mins:>9}m  {(np.sign(V0[k])!=np.sign(V1[k])).mean()*100:>21.1f}% "
          f"{np.corrcoef(V0[k],V1[k])[0,1]:>8.3f} {np.median(np.abs(V0[k]-V1[k])):>15.2f}")

print("\n  A '> 0' gate on V(0) therefore disagrees with the same gate on V(1)")
print("  on roughly a fifth of bars - it is not a cosmetic change.")

print("\n"+"="*76)
print("3. WHICH SIGN IS RIGHT MORE OFTEN? (forward move over next 4 M30 bars)")
print("="*76)
fwd=np.full(n,np.nan); fwd[:-4]=c30[4:]-c30[:-4]
V0end=rows[-1][1]      # V(0) at bar close == V(1) shifted, sanity anchor
print(f"  {'measure':>26} {'sign agrees with next 4 bars':>30}")
for lbl,x in [("V(1)  last closed bar",V1)]+[(f"V(0)  at {m} min",v) for m,v in rows[:5]]:
    k=np.isfinite(x)&np.isfinite(fwd)&m0
    print(f"  {lbl:>26} {(np.sign(x[k])==np.sign(fwd[k])).mean()*100:>29.1f}%")
se=np.sqrt(0.25/m0.sum())*100
print(f"  {'random band':>26} {50-1.96*se:>24.1f}-{50+1.96*se:.1f}%")
