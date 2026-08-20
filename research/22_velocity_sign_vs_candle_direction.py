"""
Does velocity carry the same sign as the candle's own direction?

adjusted = (price - open[0]) / barHours, and barHours > 0 always, so the sign
is sign(price - open[0]) - identical to the candle's body by construction.

The EA's PriceVelocityPerHour spans 3 bars, so it has no such guarantee. This
measures how often it disagrees, and how unsettled the adjusted sign is while
the candle is still forming.
"""
import pandas as pd, numpy as np

M5="/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/f7e662b4-new_GOLD5.csv"
d=pd.read_csv(M5,header=None,names=["date","time","open","high","low","close","vol"])
d["dt"]=pd.to_datetime(d.date+" "+d.time,format="%Y.%m.%d %H:%M")
d=d.sort_values("dt").reset_index(drop=True)
d["slot"]=d.dt.dt.floor("30min")
g=d.groupby("slot")
f=g.agg(o=("open","first"),c=("close","last"),k=("close","size")); f=f[f.k==6]
o30,c30=f.o.to_numpy(),f.c.to_numpy(); n=len(f)
part=(d[d.slot.isin(f.index)].assign(s=lambda x:x.groupby("slot").cumcount()+1)
      .pivot_table(index="slot",columns="s",values="close")).loc[f.index].to_numpy()

body=c30-o30
adj=(c30-o30)/0.5
V_ea=np.full(n,np.nan); V_ea[3:]=(c30[3:]-c30[:-3])/1.5
ok=np.isfinite(V_ea)&(body!=0)

print(f"M30 candles with a non-zero body: {ok.sum():,}\n")
print("="*70); print("DOES THE SIGN MATCH THE CANDLE'S DIRECTION?"); print("="*70)
print(f"  adjusted velocity  : {(np.sign(adj[ok])==np.sign(body[ok])).mean()*100:5.1f}%"
      "   <- identical by construction")
print(f"  EA PriceVelocity   : {(np.sign(V_ea[ok])==np.sign(body[ok])).mean()*100:5.1f}%"
      "   <- spans 3 bars, so it often disagrees")
bull=ok&(body>0); bear=ok&(body<0)
print(f"\n  of {bull.sum():,} BULLISH candles, EA velocity was negative on "
      f"{(V_ea[bull]<0).mean()*100:.1f}%")
print(f"  of {bear.sum():,} BEARISH candles, EA velocity was positive on "
      f"{(V_ea[bear]>0).mean()*100:.1f}%")

print("\n"+"="*70)
print("INTRABAR: the sign is not settled until the candle closes")
print("="*70)
S=np.sign(part-o30[:,None])
flips=(np.diff(S,axis=1)!=0).sum(axis=1)
print(f"    never flips {np.mean(flips==0)*100:5.1f}%   once {np.mean(flips==1)*100:5.1f}%"
      f"   twice or more {np.mean(flips>=2)*100:5.1f}%")
agree=(S[:,:5]==np.sign(body)[:,None])
for k in range(5):
    print(f"    sign at {(k+1)*5:>2} min matches the finished candle: "
          f"{agree[:,k].mean()*100:5.1f}%")
