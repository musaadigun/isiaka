"""
P(+$5 before -$5) after an EMA20 cross - the EA's live configuration.

Bars hide the order of events: when a candle spans both the target and the stop
we cannot know which printed first. Every figure is therefore reported as a
PESSIMISTIC bound (ambiguous bar = stop first), an OPTIMISTIC bound (target
first), and the ambiguous share, so the uncertainty is visible rather than
buried in an assumption.
"""
import pandas as pd, numpy as np

CSV="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/2863850e-1908_GOLD30.csv"
TP=5.0; SL=5.0

df=pd.read_csv(CSV,header=None,names=["date","time","open","high","low","close","vol"])
df["dt"]=pd.to_datetime(df["date"]+" "+df["time"],format="%Y.%m.%d %H:%M")
df=df.sort_values("dt").reset_index(drop=True)
df["ema"]=df["close"].ewm(span=20,adjust=False).mean()
tr=pd.concat([df["high"]-df["low"],(df["high"]-df["close"].shift()).abs(),
              (df["low"]-df["close"].shift()).abs()],axis=1).max(axis=1)
df["atr"]=tr.ewm(alpha=1/14,adjust=False).mean()

o,h,l,c=(df[x].to_numpy() for x in ("open","high","low","close"))
ema,atr,dt=df["ema"].to_numpy(),df["atr"].to_numpy(),df["dt"].to_numpy()
n=len(df); half=n//2

vel=np.full(n,np.nan); vel[3:]=(c[3:]-c[:-3])/1.5
above=c>ema
cu=np.zeros(n,bool); cu[1:]=above[1:]&~above[:-1]
cd=np.zeros(n,bool); cd[1:]=~above[1:]&above[:-1]
cu[:60]=cd[:60]=False

def resolve(i,e,s,horizon):
    """returns (outcome, ambiguous, bars_held); outcome 1=tp 0=sl -1=timeout"""
    tp=e+s*TP; sl=e-s*SL
    end=min(i+1+horizon,n-1)
    for j in range(i+1,end+1):
        hitT=(h[j]>=tp) if s>0 else (l[j]<=tp)
        hitS=(l[j]<=sl) if s>0 else (h[j]>=sl)
        if hitT and hitS: return (0,True,j-i)      # pessimistic default
        if hitT: return (1,False,j-i)
        if hitS: return (0,False,j-i)
    return (-1,False,end-i)

rows=[]
for i in np.flatnonzero(cu|cd):
    if i+1>=n or not np.isfinite(vel[i]) or atr[i]<=0: continue
    s=1 if cu[i] else -1
    rows.append(dict(i=i,sign=s,entry=o[i+1],v=s*vel[i],atr=atr[i]))
ev=pd.DataFrame(rows)
print(f"crossings: {len(ev)}   {pd.Timestamp(dt[0]):%Y-%m}  ->  {pd.Timestamp(dt[-1]):%Y-%m}")

print("\nHOW BIG IS A $5 STOP, REALLY?")
for lbl,sl_ in [("1st half",slice(0,half)),("2nd half",slice(half,n)),("all",slice(0,n))]:
    a=np.median(atr[sl_]); print(f"  {lbl}: median M30 ATR ${a:5.2f}   $5 stop = {5/a:4.2f} ATR")

print("\n"+"="*86)
print("P(+$5 before -$5)")
print("="*86)
print(f"  {'horizon':>12} {'n':>5} {'resolved':>9} {'ambiguous':>10} "
      f"{'PESSIMISTIC':>12} {'OPTIMISTIC':>11}")
for H,lbl in [(16,"8h"),(48,"24h"),(96,"48h"),(400,"~8 days")]:
    res=[resolve(r.i,r.entry,r.sign,H) for r in ev.itertuples()]
    out=np.array([x[0] for x in res]); amb=np.array([x[1] for x in res])
    dec=out>=0
    pess=out[dec].mean()
    opt=((out[dec]==1)|amb[dec]).mean()
    print(f"  {lbl:>12} {len(ev):>5} {dec.mean()*100:>8.1f}% {amb.mean()*100:>9.1f}% "
          f"{pess*100:>11.1f}% {opt*100:>10.1f}%")
    if H==96:
        keep=(out,amb,dec)

out,amb,dec=keep
ev["win"]=out; ev["amb"]=amb; ev["dec"]=dec

print("\n  by half (48h horizon):")
for lbl,m in [("1st half",ev[ev.i<half]),("2nd half",ev[ev.i>=half])]:
    d=m[m.dec]
    print(f"    {lbl}: n={len(d):>4}  pessimistic {d.win.mean()*100:5.1f}%  "
          f"optimistic {((d.win==1)|d.amb).mean()*100:5.1f}%  ambiguous {d.amb.mean()*100:4.1f}%")

print("\n  by crossing velocity (48h horizon, pessimistic):")
print(f"    {'velocity ($/h)':>18} {'n':>5} {'win%':>7}")
for lo,hi in zip([-1e9,-4,-2,0,2,4,8],[-4,-2,0,2,4,8,1e9]):
    m=ev[(ev.v>=lo)&(ev.v<hi)&ev.dec]
    if len(m)<40: continue
    lbl=f"{lo:g} .. {hi:g}".replace("-1e+09","-inf").replace("1e+09","inf")
    print(f"    {lbl:>18} {len(m):>5} {m.win.mean()*100:>6.1f}%")

print("\n"+"="*86)
print("BREAK-EVEN: symmetric $5/$5 needs P = (5 + cost) / 10")
print("="*86)
d=ev[ev.dec]
pess=d.win.mean(); opt=((d.win==1)|d.amb).mean()
print(f"  {'round-trip cost':>17} {'break-even':>11} {'actual (pess)':>14} {'actual (opt)':>13} {'edge':>18}")
for cost in (0.00,0.15,0.30,0.50):
    be=(5.0+cost)/10.0
    exp_p=pess*5-(1-pess)*5-cost
    exp_o=opt*5-(1-opt)*5-cost
    print(f"  {('$%.2f'%cost):>17} {be*100:>10.1f}% {pess*100:>13.1f}% {opt*100:>12.1f}% "
          f"{('$%+.3f .. $%+.3f'%(exp_p,exp_o)):>18}")
print("\n  (edge = expected $ per trade at 0.01 lots, pessimistic .. optimistic)")
