"""
Velocity of the running candle from ITS OWN data only:

    V0 = (price_now - open[0]) / elapsedHours

No close[3], no prior bar. The one hazard is the divisor: early in the bar
elapsedHours is tiny, so an ordinary tick produces an enormous number. This
measures how bad that is, to choose a minimum-elapsed guard from data.
"""
import pandas as pd, numpy as np

M1="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/3608804c-GOLD1.csv"
m1=pd.read_csv(M1,header=None,names=["date","time","open","high","low","close","vol"])
m1["dt"]=pd.to_datetime(m1.date+" "+m1.time,format="%Y.%m.%d %H:%M")
m1=m1.sort_values("dt").reset_index(drop=True)
m1["slot"]=m1.dt.dt.floor("30min")
grp=m1.groupby("slot")
full=grp.filter(lambda x: len(x)==30).groupby("slot")
slots=[s for s,_ in full]
print(f"complete M30 candles: {len(slots)}  ({slots[0]:%H:%M} -> {slots[-1]:%H:%M})\n")

rows=[]
for s,b in full:
    o=b.open.iloc[0]; cl=b.close.to_numpy()
    for k in range(30):                      # minute 1..30
        el=(k+1)/60.0
        rows.append(dict(slot=s,minute=k+1,v=(cl[k]-o)/el,
                         settled=(cl[-1]-o)/0.5))
r=pd.DataFrame(rows)

print("="*74)
print("HOW EXPLOSIVE IS IT EARLY?  |V0| by minute into the bar")
print("="*74)
print(f"  {'minute':>7} {'median |V0|':>12} {'90th pct':>10} {'max':>10} "
      f"{'corr w/ settled':>16} {'sign agrees':>12}")
for k in (1,2,3,5,8,10,15,20,25,30):
    g=r[r.minute==k]
    print(f"  {k:>7} {g.v.abs().median():>12.1f} {g.v.abs().quantile(.9):>10.1f} "
          f"{g.v.abs().max():>10.1f} {np.corrcoef(g.v,g.settled)[0,1]:>16.3f} "
          f"{(np.sign(g.v)==np.sign(g.settled)).mean()*100:>11.1f}%")

settled_med=r[r.minute==30].v.abs().median()
print(f"\n  settled median |V0| at bar close = {settled_med:.1f} $/h")
print("  the early readings are inflated purely by the small divisor.")

print("\n"+"="*74)
print("CHOOSING THE GUARD: how much does waiting buy?")
print("="*74)
for k in (1,2,3,5,8):
    g=r[r.minute==k]
    ratio=g.v.abs().median()/settled_med
    print(f"  wait {k:>2} min: median reading is {ratio:>5.2f}x the settled value, "
          f"sign right {(np.sign(g.v)==np.sign(g.settled)).mean()*100:.0f}% of the time")

print("\n"+"="*74)
print("THE 15:30 SPIKE, self-contained velocity minute by minute")
print("="*74)
b=m1[m1.slot==pd.Timestamp('2026-08-19 15:30')]
o=b.open.iloc[0]; cl=b.close.to_numpy()
print(f"  open {o:.2f}\n")
print(f"  {'min':>4} {'price':>9} {'move':>8} {'V0 $/h':>9}")
for k in (1,2,3,5,8,10,15,20,25,30):
    print(f"  {k:>4} {cl[k-1]:>9.2f} {cl[k-1]-o:>+8.2f} {(cl[k-1]-o)/((k)/60.0):>+9.1f}")
