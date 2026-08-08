import engine, sim, pandas as pd, numpy as np
D='/root/.claude/uploads/a50d8688-03b5-5d0d-9782-3a7a29ea13fc/'
h1=engine.load_mt4_csv(D+'17124d93-new_GOLD60.csv'); m5=engine.load_mt4_csv(D+'7b120122-new_GOLD5.csv')
m1=engine.load_mt4_csv(D+'6887b622-new_GOLD1.csv'); h4=engine.build_h4(h1)
sig=engine.compute_signals(m5,h4); q=engine.qualify(sig)

def S(tr,cfg): return sim.stats(tr,cfg)
def line(tag,tr,cfg):
    s=S(tr,cfg)
    if not s.get('trades'): print(f"  {tag:<34} no trades"); return
    print(f"  {tag:<34} n={s['trades']:>4}  net ${s['net']:>8.2f}  PF {s['profit_factor']:>5.3f}  "
          f"win {s['win_rate']:>4.1f}%  DD ${s['max_dd']:>7.2f}  exp ${s['expectancy']:>5.2f}")

print("="*100)
print("1. INTRABAR RESOLUTION — does the M5-only path model distort results?")
print("   Restricted to 2026-04-06 onward, the only window where M1 exists.")
print("="*100)
cut=pd.Timestamp('2026-04-06 06:29')
m5s=m5[m5.t>=cut].reset_index(drop=True)
sigs=sig[sig.t>=cut].reset_index(drop=True); qs=q[sig.t>=cut].reset_index(drop=True)
for label,mm in [("M1 path (5x finer)",m1),("M5 path only",None)]:
    for pess in (True,False):
        c=sim.Cfg(spread=0.30,pessimistic=pess)
        tr,_=sim.run(m5s,sigs,qs,c,m1=mm)
        line(f"{label}, {'pessimistic' if pess else 'optimistic'}",tr,c)

print()
print("="*100)
print("2. COST SENSITIVITY — full period, shipped defaults")
print("="*100)
for spread in [0.00,0.15,0.30,0.50,0.80]:
    c=sim.Cfg(spread=spread)
    tr,_=sim.run(m5,sig,q,c,m1=m1)
    line(f"spread ${spread:.2f}",tr,c)
print()
for slip in [0.0,0.05,0.10,0.20]:
    c=sim.Cfg(spread=0.30,entry_slippage=slip)
    tr,_=sim.run(m5,sig,q,c,m1=m1)
    line(f"spread $0.30 + slippage ${slip:.2f}",tr,c)
print()
for comm in [0.0,7.0,14.0]:
    c=sim.Cfg(spread=0.20,commission_per_lot_roundturn=comm)
    tr,_=sim.run(m5,sig,q,c,m1=m1)
    line(f"raw $0.20 + ${comm:.0f}/lot commission",tr,c)

print()
print("="*100)
print("3. IS THE EDGE DISTINGUISHABLE FROM ZERO?")
print("="*100)
c=sim.Cfg(spread=0.30); tr,_=sim.run(m5,sig,q,c,m1=m1)
x=tr.pnl.to_numpy(); n=len(x); mu=x.mean(); sd=x.std(ddof=1)
t=mu/(sd/np.sqrt(n))
print(f"   n={n}  mean=${mu:.4f}  sd=${sd:.3f}  t={t:.3f}")
rng=np.random.default_rng(0)
boot=np.array([rng.choice(x,n,replace=True).sum() for _ in range(20000)])
print(f"   bootstrap 95% CI on net P/L: [${np.percentile(boot,2.5):.2f}, ${np.percentile(boot,97.5):.2f}]")
print(f"   P(net <= 0) under bootstrap: {100*(boot<=0).mean():.1f}%")
print(f"   spread cost actually paid: ${0.30*100*0.01*n:.2f}  (vs net ${x.sum():.2f})")
print(f"   gross P/L before spread:   ${x.sum()+0.30*100*0.01*n:.2f}")
