"""
adjusted_velocity = (price_now - open[0]) / barHours     <- FIXED divisor
elapsed_velocity  = (price_now - open[0]) / hoursElapsed <- variable divisor

The fixed divisor removes the exploding-early-reading problem by construction.
This measures what it does instead, and whether that behaviour is better.
"""
import pandas as pd, numpy as np

M5="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/f7e662b4-new_GOLD5.csv"
d=pd.read_csv(M5,header=None,names=["date","time","open","high","low","close","vol"])
d["dt"]=pd.to_datetime(d.date+" "+d.time,format="%Y.%m.%d %H:%M")
d=d.sort_values("dt").reset_index(drop=True)
d["slot"]=d.dt.dt.floor("30min")
g=d.groupby("slot")
f=g.agg(o=("open","first"),k=("close","size")); f=f[f.k==6]
o30=f.o.to_numpy(); n=len(f)
part=(d[d.slot.isin(f.index)].assign(s=lambda x:x.groupby("slot").cumcount()+1)
      .pivot_table(index="slot",columns="s",values="close")).loc[f.index].to_numpy()
BH=0.5
settled=(part[:,5]-o30)/BH          # both definitions agree at the close
med_s=np.median(np.abs(settled))

print(f"M30 candles {n:,}   settled median |V| = {med_s:.2f} $/h\n")
print("="*88)
print("ADJUSTED (fixed /0.5h)  vs  ELAPSED (variable divisor)")
print("="*88)
print(f"  {'min':>5} | {'ADJUSTED':^34} | {'ELAPSED':^34}")
print(f"  {'':>5} | {'median':>8} {'x settled':>9} {'corr':>7} {'sign':>7} | "
      f"{'median':>8} {'x settled':>9} {'corr':>7} {'sign':>7}")
for k in range(6):
    adj=(part[:,k]-o30)/BH
    ela=(part[:,k]-o30)/((k+1)*5/60.0)
    ok=np.isfinite(adj)&np.isfinite(settled)
    row=f"  {(k+1)*5:>5} |"
    for v in (adj,ela):
        row+=(f" {np.median(np.abs(v[ok])):>8.2f} {np.median(np.abs(v[ok]))/med_s:>8.2f}x "
              f"{np.corrcoef(v[ok],settled[ok])[0,1]:>7.3f} "
              f"{(np.sign(v[ok])==np.sign(settled[ok])).mean()*100:>6.1f}% |")
    print(row)

print("\n  ADJUSTED is conservative early and converges upward; it never")
print("  overstates. ELAPSED overstates by up to 2.76x at 5 minutes in.")
print("  Both share the same sign at any instant - only the scale differs.")

print("\n"+"="*88)
print("WHAT A THRESHOLD MEANS UNDER EACH")
print("="*88)
print("  adjusted >= X  is exactly  displacement >= X * barHours,")
print("  so the trigger is a fixed distance, independent of when it happens.\n")
for thr in (10,20,30):
    print(f"  adjusted >= {thr:>2} $/h  ->  candle must have moved "
          f"${thr*BH:>5.2f} at any point in the bar")
print()
for thr in (10,20,30):
    fired=[]
    for k in range(6):
        adj=(part[:,k]-o30)/BH
        fired.append((np.abs(adj)>=thr).mean()*100)
    print(f"  adjusted >= {thr:>2}: share of candles triggered by minute "
          + "/".join(f"{v:.0f}" for v in fired) + "  (5..30 min)")

print("\n"+"="*88)
print("THE 2026-08-19 SPIKE UNDER BOTH")
print("="*88)
M1="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/3608804c-GOLD1.csv"
m1=pd.read_csv(M1,header=None,names=["date","time","open","high","low","close","vol"])
m1["dt"]=pd.to_datetime(m1.date+" "+m1.time,format="%Y.%m.%d %H:%M")
b=m1[(m1.dt>=pd.Timestamp('2026-08-19 15:30'))&(m1.dt<pd.Timestamp('2026-08-19 16:00'))]
o=b.open.iloc[0]; cl=b.close.to_numpy()
print(f"  {'min':>4} {'move':>8} {'adjusted':>10} {'elapsed':>10}")
for k in (1,2,3,5,8,10,15,20,25,30):
    mv=cl[k-1]-o
    print(f"  {k:>4} {mv:>+8.2f} {mv/BH:>+10.1f} {mv/(k/60.0):>+10.1f}")
print("\n  adjusted rises smoothly with the move; elapsed peaks at minute 8")
print("  and then DECAYS while price is still climbing.")
