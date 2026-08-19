"""
Resolve the +$5/-$5 race on M5 bars instead of M30.

M30 candles hide the order of events: 9.9% of trades (17% in the volatile half)
contain both the target and the stop in one candle. Walking the same trades on
M5 bars from the same feed cuts that ambiguity by ~6x and gives a real answer.
"""
import pandas as pd, numpy as np

M30="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/2863850e-1908_GOLD30.csv"
M5 ="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/f7e662b4-new_GOLD5.csv"
TP=SL=5.0

def load(p):
    d=pd.read_csv(p,header=None,names=["date","time","open","high","low","close","vol"])
    d["dt"]=pd.to_datetime(d.date+" "+d.time,format="%Y.%m.%d %H:%M")
    return d.sort_values("dt").reset_index(drop=True)

d30,d5=load(M30),load(M5)
d30["ema"]=d30.close.ewm(span=20,adjust=False).mean()
tr=pd.concat([d30.high-d30.low,(d30.high-d30.close.shift()).abs(),
              (d30.low-d30.close.shift()).abs()],axis=1).max(axis=1)
d30["atr"]=tr.ewm(alpha=1/14,adjust=False).mean()

o,h,l,c=(d30[x].to_numpy() for x in ("open","high","low","close"))
ema,atr,t30=d30.ema.to_numpy(),d30.atr.to_numpy(),d30.dt.to_numpy()
n=len(d30)
H5,L5,T5=d5.high.to_numpy(),d5.low.to_numpy(),d5.dt.to_numpy()

above=c>ema
cu=np.zeros(n,bool); cu[1:]=above[1:]&~above[:-1]
cd=np.zeros(n,bool); cd[1:]=~above[1:]&above[:-1]
cu[:60]=cd[:60]=False

lo5,hi5=T5.min(),T5.max()
vel=np.full(n,np.nan); vel[3:]=(c[3:]-c[:-3])/1.5

def walk(bars_hi,bars_lo,start,e,s,limit):
    tp,sl=e+s*TP,e-s*SL
    for j in range(start,min(start+limit,len(bars_hi))):
        hitT=(bars_hi[j]>=tp) if s>0 else (bars_lo[j]<=tp)
        hitS=(bars_lo[j]<=sl) if s>0 else (bars_hi[j]>=sl)
        if hitT and hitS: return (0,True)
        if hitT: return (1,False)
        if hitS: return (0,False)
    return (-1,False)

rows=[]
for i in np.flatnonzero(cu|cd):
    if i+1>=n or atr[i]<=0 or not np.isfinite(vel[i]): continue
    et=t30[i+1]
    if et<lo5 or et>hi5: continue                 # only where M5 exists
    k=np.searchsorted(T5,et)
    if k>=len(T5) or T5[k]!=et: continue          # entry bar must line up
    s=1 if cu[i] else -1
    e=o[i+1]
    o30,a30=walk(h,l,i+1,e,s,96)                  # 48h on M30 bars
    o5, a5 =walk(H5,L5,k,e,s,96*6)                # same 48h on M5 bars
    rows.append(dict(i=i,sign=s,v=s*vel[i],atr=atr[i],
                     w30=o30,a30=a30,w5=o5,a5=a5))
ev=pd.DataFrame(rows)
print(f"crossings with M5 coverage: {len(ev)}   "
      f"{pd.Timestamp(ev.i.map(lambda x: t30[x]).min()):%Y-%m} -> "
      f"{pd.Timestamp(ev.i.map(lambda x: t30[x]).max()):%Y-%m}")

def band(w,a,label):
    d=(w>=0)
    pess=w[d].mean()
    opt=((w[d]==1)|a[d]).mean()
    print(f"  {label:<22} n={d.sum():>4}  ambiguous {a[d].mean()*100:>5.1f}%   "
          f"P(+5 before -5) = {pess*100:>5.1f}% .. {opt*100:>5.1f}%")
    return pess,opt

print("\n"+"="*80)
print("SAME TRADES, DIFFERENT BAR RESOLUTION")
print("="*80)
band(ev.w30.to_numpy(),ev.a30.to_numpy(),"resolved on M30")
p5,o5_=band(ev.w5.to_numpy(),ev.a5.to_numpy(),"resolved on M5")

d=ev[ev.w5>=0]
mid_est=(d.w5==1).mean()+d.a5.mean()*0.5
print(f"\n  M5 midpoint estimate: {mid_est*100:.1f}%   (ambiguous split 50/50)")

print("\n"+"="*80)
print("EXPECTANCY at 0.01 lots, M5-resolved")
print("="*80)
mid=(d.w5==1).mean()+d.a5.mean()*0.5
print(f"  {'cost':>8} {'break-even':>11} {'win rate':>9} {'$ per trade':>13} {'per 100 trades':>15}")
for cost in (0.00,0.15,0.30,0.50):
    be=(5.0+cost)/10.0
    exp=mid*5-(1-mid)*5-cost
    print(f"  {('$%.2f'%cost):>8} {be*100:>10.1f}% {mid*100:>8.1f}% "
          f"{('$%+.3f'%exp):>13} {('$%+.1f'%(exp*100)):>15}")

print("\n  by velocity (M5-resolved, ambiguous split 50/50):")
print(f"    {'velocity ($/h)':>18} {'n':>5} {'win%':>7}")
for lo,hi in zip([-1e9,-4,-2,0,2,4,8],[-4,-2,0,2,4,8,1e9]):
    m=d[(d.v>=lo)&(d.v<hi)]
    if len(m)<30: continue
    w=(m.w5==1).mean()+m.a5.mean()*0.5
    lbl=f"{lo:g} .. {hi:g}".replace("-1e+09","-inf").replace("1e+09","inf")
    print(f"    {lbl:>18} {len(m):>5} {w*100:>6.1f}%")
