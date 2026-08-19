"""
1. Why is acceleration numerically bigger than velocity?
2. Which of the two is more directional?
"""
import pandas as pd, numpy as np

CSV="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/2863850e-1908_GOLD30.csv"
d=pd.read_csv(CSV,header=None,names=["date","time","open","high","low","close","vol"])
d["dt"]=pd.to_datetime(d.date+" "+d.time,format="%Y.%m.%d %H:%M")
d=d.sort_values("dt").reset_index(drop=True)
c=d.close.to_numpy(); n=len(c)

V=np.full(n,np.nan); V[3:]=(c[3:]-c[:-3])/1.5      # $/hour
A=np.full(n,np.nan); A[1:]=(V[1:]-V[:-1])/0.5      # $/hour^2
m=np.isfinite(A)&np.isfinite(V)

print("="*82)
print("1. WHY IS |A| BIGGER THAN |V|?  It is the time unit, not the market.")
print("="*82)
print(f"  median |V| = {np.median(np.abs(V[m])):8.3f}  $/hour")
print(f"  median |A| = {np.median(np.abs(A[m])):8.3f}  $/hour^2")
print(f"  ratio      = {np.median(np.abs(A[m]))/np.median(np.abs(V[m])):8.2f}x\n")
print("  Two structural causes, no market content in either:\n")
print("  (a) the divisor is 0.5, so dividing by it DOUBLES the difference:")
print("        A = (V_t - V_t-1) / 0.5  =  2 x (V_t - V_t-1)")
dv=np.abs(np.diff(V[np.isfinite(V)]))
print(f"      median |V_t - V_t-1| = {np.median(dv):.3f}, doubled = {np.median(dv)*2:.3f}"
      f"  vs median |A| = {np.median(np.abs(A[m])):.3f}\n")
print("  (b) the units differ, so the comparison is meaningless as stated.")
print("      $/hour vs $/hour^2 is like comparing 60 mph with 10 mph^2 -")
print("      the ratio is set by whether you chose hours, minutes or seconds.\n")
print("      the SAME data, expressed per minute instead of per hour:")
Vm=V/60.0; Am=A/3600.0
print(f"        median |V| = {np.median(np.abs(Vm[m])):9.5f}  $/min")
print(f"        median |A| = {np.median(np.abs(Am[m])):9.5f}  $/min^2")
print(f"        ratio      = {np.median(np.abs(Am[m]))/np.median(np.abs(Vm[m])):9.4f}x"
      "   <- now acceleration is far SMALLER")
print("\n      per second:")
Vs=V/3600.0; As=A/(3600.0**2)
print(f"        ratio      = {np.median(np.abs(As[m]))/np.median(np.abs(Vs[m])):9.7f}x")

print("\n"+"="*82)
print("2. WHICH IS MORE DIRECTIONAL?")
print("="*82)
print("  Information coefficient = corr(measure now, forward return).")
print("  Sign agreement = how often the measure's sign matches the forward move.\n")
print(f"  {'horizon':>9} {'IC velocity':>13} {'IC accel':>10} "
      f"{'sign V':>9} {'sign A':>9} {'random':>9}")
for k in (1,2,4,8,16,32):
    fwd=np.full(n,np.nan); fwd[:-k]=c[k:]-c[:-k]
    g=m&np.isfinite(fwd)
    icv=np.corrcoef(V[g],fwd[g])[0,1]
    ica=np.corrcoef(A[g],fwd[g])[0,1]
    sv=(np.sign(V[g])==np.sign(fwd[g])).mean()
    sa=(np.sign(A[g])==np.sign(fwd[g])).mean()
    se=np.sqrt(0.25/g.sum())
    print(f"  {k:>7} bar {icv:>13.4f} {ica:>10.4f} {sv*100:>8.1f}% {sa*100:>8.1f}% "
          f"{50-1.96*se*100:>4.1f}-{50+1.96*se*100:.1f}%")

print("\n  PERSISTENCE - a directional measure should hold its sign a while:")
for nm,x in (("velocity",V),("acceleration",A)):
    a=x[np.isfinite(x)]
    r1=np.corrcoef(a[:-1],a[1:])[0,1]
    flip=(np.sign(a[:-1])!=np.sign(a[1:])).mean()
    print(f"    {nm:>13}: lag-1 autocorr {r1:+.3f}   sign flips bar to bar {flip*100:.1f}%")

print("\n  SAME TEST, but on the sign of the EMA20 GRADIENT for reference:")
ema=d.close.ewm(span=20,adjust=False).mean().to_numpy()
G=np.full(n,np.nan); G[2:]=ema[2:]-ema[:-2]
for k in (4,16):
    fwd=np.full(n,np.nan); fwd[:-k]=c[k:]-c[:-k]
    g=np.isfinite(G)&np.isfinite(fwd)
    print(f"    {k:>2}-bar: IC {np.corrcoef(G[g],fwd[g])[0,1]:+.4f}   "
          f"sign agreement {(np.sign(G[g])==np.sign(fwd[g])).mean()*100:.1f}%")
