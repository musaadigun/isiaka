"""
Head-to-head: velocity vs acceleration, at MATCHED selectivity.

Comparing "v >= 10" against "a >= 24" is meaningless - they keep different
numbers of signals. Instead, take the top X% of crossings by each measure and
compare like for like, against a random-selection baseline that shows what no
information at all looks like at that sample size.
"""
import pandas as pd, numpy as np
rng=np.random.default_rng(7)

M30="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/2863850e-1908_GOLD30.csv"
M5 ="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/f7e662b4-new_GOLD5.csv"

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
n=len(d30); half=n//2
H5,L5,T5=d5.high.to_numpy(),d5.low.to_numpy(),d5.dt.to_numpy()
lo5,hi5=T5.min(),T5.max()

vel=np.full(n,np.nan); vel[3:]=(c[3:]-c[:-3])/1.5
acc=np.full(n,np.nan); acc[1:]=(vel[1:]-vel[:-1])/0.5
above=c>ema
cu=np.zeros(n,bool); cu[1:]=above[1:]&~above[:-1]
cd=np.zeros(n,bool); cd[1:]=~above[1:]&above[:-1]
cu[:60]=cd[:60]=False

def walk5(k,e,s,TP,SL,limit=576):
    tp,sl=e+s*TP,e-s*SL
    for j in range(k,min(k+limit,len(H5))):
        hT=(H5[j]>=tp) if s>0 else (L5[j]<=tp)
        hS=(L5[j]<=sl) if s>0 else (H5[j]>=sl)
        if hT and hS: return 0.5
        if hT: return 1.0
        if hS: return 0.0
    return np.nan

H=16; rows=[]
for i in np.flatnonzero(cu|cd):
    if i+1>=n or atr[i]<=0 or not np.isfinite(acc[i]): continue
    s=1 if cu[i] else -1; e=o[i+1]
    end=min(i+1+H,n-1); sh,sl_=h[i+1:end+1],l[i+1:end+1]
    if len(sh)==0: continue
    mfe=(sh.max()-e) if s>0 else (e-sl_.min())
    r55=np.nan
    et=t30[i+1]
    if lo5<=et<=hi5:
        k=np.searchsorted(T5,et)
        if k<len(T5) and T5[k]==et: r55=walk5(k,e,s,5,5)
    rows.append(dict(i=i,v=s*vel[i],a=s*acc[i],atr=atr[i],
                     hit10=int(mfe>=10),hitATR=int(mfe>=1.5*atr[i]),r55=r55))
ev=pd.DataFrame(rows)
print(f"crossings {len(ev)}   with M5 outcome {ev.r55.notna().sum()}")
print(f"corr(velocity, acceleration) = {np.corrcoef(ev.v,ev.a)[0,1]:+.3f}\n")

def boot(pool,k,col,reps=4000):
    vals=pool[col].dropna().to_numpy()
    if len(vals)<k: k=len(vals)
    s=rng.choice(vals,size=(reps,k),replace=True).mean(axis=1)
    return np.percentile(s,5),np.percentile(s,95)

print("="*100)
print("TOP X% BY EACH MEASURE  -  same number of signals, so directly comparable")
print("="*100)
for pct in (50,30,20,10):
    k=int(len(ev)*pct/100)
    print(f"\n  top {pct}%  (n={k})")
    print(f"    {'measure':>14} {'hit +$10':>10} {'hit 1.5ATR':>12} "
          f"{'+5 b4 -5 (M5)':>15} {'1st half':>10} {'2nd half':>10}")
    for name,col in (("velocity","v"),("acceleration","a")):
        m=ev.nlargest(k,col)
        a1,b1=m[m.i<half],m[m.i>=half]
        r=m.r55.dropna()
        print(f"    {name:>14} {m.hit10.mean()*100:>9.1f}% {m.hitATR.mean()*100:>11.1f}% "
              f"{(r.mean()*100 if len(r)>40 else float('nan')):>14.1f}% "
              f"{(a1.hit10.mean()*100 if len(a1)>20 else float('nan')):>9.1f}% "
              f"{(b1.hit10.mean()*100 if len(b1)>20 else float('nan')):>9.1f}%")
    lo10,hi10=boot(ev,k,"hit10"); loA,hiA=boot(ev,k,"hitATR"); lo55,hi55=boot(ev,k,"r55")
    print(f"    {'RANDOM 5-95%':>14} {lo10*100:>5.1f}-{hi10*100:<4.1f}% "
          f"{loA*100:>6.1f}-{hiA*100:<4.1f}% {lo55*100:>9.1f}-{hi55*100:<4.1f}%")

print("\n"+"="*100)
print("VERDICT PER METRIC (top 10%, vs what random selection produces)")
print("="*100)
k=int(len(ev)*0.10)
for name,col in (("velocity","v"),("acceleration","a")):
    m=ev.nlargest(k,col)
    for metric,label in (("hit10","fixed $10 target"),("hitATR","1.5 ATR target"),
                         ("r55","+5 before -5")):
        vals=m[metric].dropna()
        lo,hi=boot(ev,len(vals),metric)
        obs=vals.mean()
        tag="ABOVE random" if obs>hi else ("below random" if obs<lo else "inside random band")
        print(f"  {name:>13} / {label:<18} {obs*100:>5.1f}%   random {lo*100:.1f}-{hi*100:.1f}%   -> {tag}")
