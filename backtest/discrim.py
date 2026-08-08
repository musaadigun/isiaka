import engine, sim, pandas as pd, numpy as np
D='/root/.claude/uploads/a50d8688-03b5-5d0d-9782-3a7a29ea13fc/'
h1=engine.load_mt4_csv(D+'17124d93-new_GOLD60.csv'); m5=engine.load_mt4_csv(D+'7b120122-new_GOLD5.csv')
m1=engine.load_mt4_csv(D+'6887b622-new_GOLD1.csv'); h4=engine.build_h4(h1)
sig=engine.compute_signals(m5,h4); q=engine.qualify(sig)
c=sim.Cfg(spread=0.30); tr,_=sim.run(m5,sig,q,c,m1=m1)

print("="*100); print("A. DOES p10 RANK OUTCOMES?  (the model's flagship filter)"); print("="*100)
for col,lab in [('p10','p10'),('p30','p30'),('h4body','h4Body')]:
    tr['_b']=pd.qcut(tr[col],4,labels=['Q1 low','Q2','Q3','Q4 high'],duplicates='drop')
    g=tr.groupby('_b',observed=True).agg(n=('pnl','size'),exp=('pnl','mean'),
                                         win=('pnl',lambda s:100*(s>0).mean()),net=('pnl','sum'))
    print(f"\n  by {lab} quartile:")
    for k,r in g.iterrows():
        print(f"    {k:<8} n={int(r.n):>4}  expectancy ${r.exp:>6.2f}  win {r.win:>4.1f}%  net ${r.net:>8.2f}")
    rho=np.corrcoef(tr[col],tr.pnl)[0,1]
    print(f"    correlation({lab}, trade P/L) = {rho:+.4f}")

print()
print("="*100); print("B. RANDOM-DIRECTION CONTROL"); print("="*100)
print("  Same entry times, same management, direction replaced by a coin flip.")
rng=np.random.default_rng(7); nets=[]
for k in range(300):
    s2=sig.copy()
    flip=rng.random(len(s2))<0.5
    s2['direction']=np.where(flip,-s2['direction'],s2['direction'])
    t2,_=sim.run(m5,s2,q,sim.Cfg(spread=0.30),m1=m1)
    nets.append(t2.pnl.sum() if len(t2) else 0.0)
nets=np.array(nets)
real=tr.pnl.sum()
print(f"  real model net:        ${real:>8.2f}")
print(f"  random-direction net:  mean ${nets.mean():>8.2f}   sd ${nets.std():.2f}   "
      f"5-95pct [${np.percentile(nets,5):.2f}, ${np.percentile(nets,95):.2f}]")
print(f"  percentile of the real result within the random distribution: {100*(nets<real).mean():.1f}%")

print()
print("="*100); print("C. BENCHMARK: what did simply holding gold do over the same window?"); print("="*100)
first=m5.c.iloc[80]; last=m5.c.iloc[-1]
print(f"  gold {first:.2f} -> {last:.2f} = ${last-first:+.2f} per oz")
print(f"  buy & hold 0.01 lot (= 1 oz), no leverage cost: ${last-first:+.2f}")
print(f"  EA net (stop-first, spread $0.30):              ${real:+.2f}")
dur=(tr.t_out-tr.t_in).dt.total_seconds()/3600
span=(m5.t.iloc[-1]-m5.t.iloc[80]).total_seconds()/3600
print(f"  EA time in market: {dur.sum():.0f}h of {span:.0f}h = {100*dur.sum()/span:.1f}%")
print(f"  median hold {dur.median():.2f}h   mean {dur.mean():.2f}h   max {dur.max():.1f}h "
      f"({int((dur>4.2).sum())} trades exceeded the 240-min stop, i.e. held across a data/weekend gap)")

print()
print("="*100); print("D. RISK-NORMALISED VIEW (lot size is arbitrary; R = the $15 initial stop)"); print("="*100)
R=15.0
print(f"  expectancy {tr.pnl.mean()/R:+.4f} R/trade over {len(tr)} trades = {tr.pnl.sum()/R:+.1f} R total")
print(f"  max drawdown {sim.stats(tr,c)['max_dd']/R:.1f} R")
print(f"  at 1% risk per trade this is {100*tr.pnl.sum()/R*0.01:.1f}% over {sim.stats(tr,c)['days']} days,")
print(f"  with a {sim.stats(tr,c)['max_dd']/R*1.0:.1f}% peak-to-trough drawdown.")
tr.to_csv('trades_final.csv',index=False)
np.save('random_nets.npy',nets)
