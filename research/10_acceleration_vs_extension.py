"""
What crossing ACCELERATION gives the best chance of a $10 extension?

Acceleration exactly as the EA computes it on M30:
    V   = (close[1] - close[4]) / 1.5h          $/hour
    A   = (V[1] - V[2]) / 0.5h                  $/hour^2
sign-adjusted by cross direction.

Extension (MFE) is measured on M30 - a running maximum has no ordering
ambiguity. Races (+X before -Y) are measured on M5, because a $5 stop sits
inside a single M30 candle far too often for bar data to resolve.
"""
import pandas as pd, numpy as np

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

H=16
rows=[]
for i in np.flatnonzero(cu|cd):
    if i+1>=n or atr[i]<=0 or not np.isfinite(acc[i]): continue
    s=1 if cu[i] else -1; e=o[i+1]
    end=min(i+1+H,n-1)
    sh,sl_=h[i+1:end+1],l[i+1:end+1]
    if len(sh)==0: continue
    mfe=(sh.max()-e) if s>0 else (e-sl_.min())
    mae=(e-sl_.min()) if s>0 else (sh.max()-e)
    rows.append(dict(i=i,sign=s,entry=e,v=s*vel[i],a=s*acc[i],atr=atr[i],
                     mfe=mfe,mae=mae))
ev=pd.DataFrame(rows)
ev["hit10"]=(ev.mfe>=10).astype(int)
ev["hitATR"]=(ev.mfe>=1.5*ev.atr).astype(int)
ev["an"]=ev.a/(ev.atr/0.25)      # ATR-normalised acceleration

print(f"crossings: {len(ev)}   {pd.Timestamp(t30[0]):%Y-%m} -> {pd.Timestamp(t30[-1]):%Y-%m}")
print(f"acceleration ($/h^2) percentiles: ",end="")
for p in (5,25,50,75,95): print(f"{p}th {np.percentile(ev.a,p):>7.2f}  ",end="")
print(f"\ncorrelation with velocity: {np.corrcoef(ev.a,ev.v)[0,1]:+.3f}")

print("\n"+"="*92)
print("A. THRESHOLD SWEEP  (acceleration >= X)   extension measured on M30, 8h")
print("="*92)
print(f"  {'a >=':>7} {'n':>5} {'% kept':>7} {'hit +$10':>9} {'hit 1.5ATR':>11} "
      f"{'1st half':>9} {'2nd half':>9}")
for thr in [-1e9,0,2,4,6,8,12,16,24]:
    m=ev[ev.a>=thr]
    if len(m)<40: continue
    a1,b1=m[m.i<half],m[m.i>=half]
    lbl="all" if thr==-1e9 else f"{thr:g}"
    print(f"  {lbl:>7} {len(m):>5} {len(m)/len(ev)*100:>6.0f}% {m.hit10.mean()*100:>8.1f}% "
          f"{m.hitATR.mean()*100:>10.1f}% "
          f"{(a1.hit10.mean()*100 if len(a1)>15 else float('nan')):>8.1f}% "
          f"{(b1.hit10.mean()*100 if len(b1)>15 else float('nan')):>8.1f}%")

print("\n"+"="*92)
print("B. BUCKETS - directional, or another magnitude reading?")
print("="*92)
print(f"  {'acceleration':>18} {'n':>5} {'hit +$10':>9} {'hit 1.5ATR':>11} {'med MFE':>9} {'med MAE':>9}")
for lo,hi in zip([-1e9,-16,-8,-3,0,3,8,16],[-16,-8,-3,0,3,8,16,1e9]):
    m=ev[(ev.a>=lo)&(ev.a<hi)]
    if len(m)<40: continue
    lbl=f"{lo:g} .. {hi:g}".replace("-1e+09","-inf").replace("1e+09","inf")
    print(f"  {lbl:>18} {len(m):>5} {m.hit10.mean()*100:>8.1f}% {m.hitATR.mean()*100:>10.1f}% "
          f"{m.mfe.median():>8.2f} {m.mae.median():>8.2f}")

print("\n  regime-neutral (ATR-normalised acceleration, 1.5 ATR target), split-half:")
print(f"  {'|acc| / ATR':>18} {'n':>5} {'all':>7} {'1st':>7} {'2nd':>7}")
ev["aa"]=ev.an.abs()
for lo,hi in zip([0,0.5,1.5,3],[0.5,1.5,3,1e9]):
    m=ev[(ev.aa>=lo)&(ev.aa<hi)]
    if len(m)<40: continue
    a1,b1=m[m.i<half],m[m.i>=half]
    if len(a1)<15 or len(b1)<15: continue
    print(f"  {f'{lo:g} .. {hi:g}'.replace('1e+09','inf'):>18} {len(m):>5} "
          f"{m.hitATR.mean()*100:>6.1f}% {a1.hitATR.mean()*100:>6.1f}% {b1.hitATR.mean()*100:>6.1f}%")

# ---------- M5-resolved races -----------------------------------------------
def walk5(k,e,s,TP,SL,limit):
    tp,sl=e+s*TP,e-s*SL
    for j in range(k,min(k+limit,len(H5))):
        hitT=(H5[j]>=tp) if s>0 else (L5[j]<=tp)
        hitS=(L5[j]<=sl) if s>0 else (H5[j]>=sl)
        if hitT and hitS: return 0.5
        if hitT: return 1.0
        if hitS: return 0.0
    return np.nan

sub=[]
for r in ev.itertuples():
    et=t30[r.i+1]
    if et<lo5 or et>hi5: continue
    k=np.searchsorted(T5,et)
    if k>=len(T5) or T5[k]!=et: continue
    sub.append(dict(a=r.a,v=r.v,
                    r55=walk5(k,r.entry,r.sign,5,5,576),
                    r1010=walk5(k,r.entry,r.sign,10,10,576)))
sb=pd.DataFrame(sub).dropna()
print("\n"+"="*92)
print(f"C. M5-RESOLVED RACES by acceleration   (n={len(sb)}, ambiguous counted as 0.5)")
print("="*92)
print(f"  {'acceleration':>18} {'n':>5} {'+5 before -5':>14} {'+10 before -10':>16}")
print(f"  {'ALL':>18} {len(sb):>5} {sb.r55.mean()*100:>13.1f}% {sb.r1010.mean()*100:>15.1f}%")
for lo,hi in zip([-1e9,-8,-3,0,3,8],[-8,-3,0,3,8,1e9]):
    m=sb[(sb.a>=lo)&(sb.a<hi)]
    if len(m)<40: continue
    lbl=f"{lo:g} .. {hi:g}".replace("-1e+09","-inf").replace("1e+09","inf")
    print(f"  {lbl:>18} {len(m):>5} {m.r55.mean()*100:>13.1f}% {m.r1010.mean()*100:>15.1f}%")

print("\n"+"="*92)
print("D. DOES ACCELERATION ADD ANYTHING ON TOP OF VELOCITY?  (+5 before -5, M5)")
print("="*92)
print(f"  {'velocity band':>18} {'acc < 0':>17} {'acc >= 0':>17} {'diff':>10}")
for lo,hi in zip([-1e9,0,4],[0,4,1e9]):
    m=sb[(sb.v>=lo)&(sb.v<hi)]
    neg,pos=m[m.a<0],m[m.a>=0]
    if len(neg)<30 or len(pos)<30: continue
    lbl=f"{lo:g} .. {hi:g}".replace("-1e+09","-inf").replace("1e+09","inf")
    print(f"  {lbl:>18} {neg.r55.mean()*100:>7.1f}% (n={len(neg):>3}) "
          f"{pos.r55.mean()*100:>7.1f}% (n={len(pos):>3}) "
          f"{(pos.r55.mean()-neg.r55.mean())*100:>+7.1f}pp")
