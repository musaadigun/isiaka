import engine, sim, pandas as pd, numpy as np
D='/root/.claude/uploads/a50d8688-03b5-5d0d-9782-3a7a29ea13fc/'
h1=engine.load_mt4_csv(D+'17124d93-new_GOLD60.csv'); m5=engine.load_mt4_csv(D+'7b120122-new_GOLD5.csv')
m1=engine.load_mt4_csv(D+'6887b622-new_GOLD1.csv'); h4=engine.build_h4(h1)
sig=engine.compute_signals(m5,h4); q=engine.qualify(sig)

print("="*98)
print("A. INTRABAR ORDERING BRACKET — full period, hybrid path (M1 after 2026-04-06, else M5)")
print("="*98)
res={}
for pess in (True,False):
    c=sim.Cfg(spread=0.30,pessimistic=pess); tr,bl=sim.run(m5,sig,q,c,m1=m1); s=sim.stats(tr,c)
    res[pess]=(tr,s)
    tag="stop checked before trail advances" if pess else "trail advances before stop is checked"
    print(f"  {tag:<42} n={s['trades']}  net ${s['net']:>8.2f}  PF {s['profit_factor']:.3f}  win {s['win_rate']:.1f}%  DD ${s['max_dd']:.2f}")
print("  -> the true path lies between these two. Neither is 'conservative'; they bracket it.")

print()
print("="*98)
print("B. WHAT THE M1 WINDOW SAYS ABOUT THE M5 APPROXIMATION")
print("="*98)
cut=pd.Timestamp('2026-04-06 06:29')
m5s=m5[m5.t>=cut].reset_index(drop=True)
sigs=sig[sig.t>=cut].reset_index(drop=True); qs=q[sig.t>=cut].reset_index(drop=True)
for pess in (True,False):
    a=sim.stats(sim.run(m5s,sigs,qs,sim.Cfg(spread=.30,pessimistic=pess),m1=m1)[0],sim.Cfg())
    b=sim.stats(sim.run(m5s,sigs,qs,sim.Cfg(spread=.30,pessimistic=pess),m1=None)[0],sim.Cfg())
    bias=(b['net']-a['net'])/a['trades']
    tag="stop-first" if pess else "trail-first"
    print(f"  {tag:<12} M1 path ${a['net']:>8.2f}   M5 path ${b['net']:>8.2f}   "
          f"M5 bias {bias:+.3f}/trade  -> over 513 trades: {bias*513:+.0f}")

print()
print("="*98)
print("C. CORRECTING THE AUDIT: which filters actually bind on real data?")
print("   'marginal' = signals that pass ALL other gates but fail this one.")
print("="*98)
v=sig[sig.valid].copy()
gates={
 'p10>=0.70':      v.p10>=0.70,
 'p30>=0.20':      v.p30>=0.20,
 'pbad<=1.00':     v.pbad<=1.00,
 'edge>=-0.30':    (v.p30-v.pbad)>=-0.30,
 'h4gap>0':        v.h4gap>0.0,
 'eff12>=0.05':    v.eff12>=0.05,
 'strength 0.1-2.5':(v.strength>=0.10)&(v.strength<=2.50),
 'shock<=2.50':    v.shock<=2.50,
}
allpass=np.logical_and.reduce([g.to_numpy() for g in gates.values()])
print(f"   qualified bars: {allpass.sum()} of {len(v)} valid ({100*allpass.mean():.2f}%)")
print(f"   {'gate':<19}{'passes':>9}{'marginal (uniquely blocks)':>29}")
for name,g in gates.items():
    others=np.logical_and.reduce([x.to_numpy() for k,x in gates.items() if k!=name])
    marg=(others & ~g.to_numpy()).sum()
    print(f"   {name:<19}{100*g.mean():>8.2f}%{marg:>20}   {'<- BINDS' if marg>0 else '<- no effect'}")

print()
print("="*98)
print("D. CORRECTING THE AUDIT: h4Body among qualified signals vs the ceteris-paribus estimate")
print("="*98)
qb=sig.loc[q,'h4body']
print(f"   audit predicted the gate reduces to h4Body >= 0.909 (all else at training mean)")
print(f"   actual h4Body of qualified signals:  min {qb.min():.3f}  p05 {qb.quantile(.05):.3f}  "
      f"median {qb.median():.3f}  p95 {qb.quantile(.95):.3f}  max {qb.max():.3f}")
print(f"   share of qualified signals with h4Body < 0.909: {100*(qb<0.909).mean():.1f}%")
vq=sig[q]
print(f"   because the features co-vary: among qualified signals, mean h4Slope={vq.h4slope.mean():.3f} "
      f"(training mean 0.055), mean 4h-velocity feature is below its mean, both of which add to z.")
print(f"   => the audit's 'handful of trades per month' was WRONG. Actual: 41 trades/month.")
