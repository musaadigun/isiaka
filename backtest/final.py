import engine, sim, pandas as pd, numpy as np
D='/root/.claude/uploads/a50d8688-03b5-5d0d-9782-3a7a29ea13fc/'
h1=engine.load_mt4_csv(D+'17124d93-new_GOLD60.csv'); m5=engine.load_mt4_csv(D+'7b120122-new_GOLD5.csv')
m1=engine.load_mt4_csv(D+'6887b622-new_GOLD1.csv'); h4=engine.build_h4(h1)
sig=engine.compute_signals(m5,h4); q=engine.qualify(sig)
np.save('_cache.npy',np.array([0]))

def L(tag,tr,c,w=40):
    s=sim.stats(tr,c)
    if not s.get('trades'): print(f"  {tag:<{w}} no trades"); return s
    print(f"  {tag:<{w}} n={s['trades']:>4}  net ${s['net']:>8.2f}  PF {s['profit_factor']:>5.3f}  "
          f"win {s['win_rate']:>4.1f}%  DD ${s['max_dd']:>7.2f}  exp ${s['expectancy']:>6.2f}")
    return s

print("="*104); print("1. BASELINE — shipped defaults (auto-entry forced ON), hybrid M1/M5 path, spread $0.30"); print("="*104)
out={}
for pess in (True,False):
    c=sim.Cfg(spread=0.30,pessimistic=pess)
    tr,bl=sim.run(m5,sig,q,c,m1=m1)
    tag="stop checked before trail advances" if pess else "trail advances before stop check"
    out[pess]=(tr,L(tag,tr,c),bl)
tr0,s0,bl0=out[True]
print(f"  exits: "+"  ".join(f"{k} {v}" for k,v in tr0.reason.value_counts().items()))
print(f"  entry blocks: "+"  ".join(f"{k} {v}" for k,v in bl0.items() if v))
print(f"  {s0['days']} days -> {s0['trades_per_month']:.1f} trades/month;  buys {(tr0.dir>0).sum()}  sells {(tr0.dir<0).sum()}")
tr0.to_csv('trades_baseline.csv',index=False)

print(); print("="*104); print("2. THE BRACKET IS WIDER THAN THE RESULT"); print("="*104)
lo=min(out[True][1]['net'],out[False][1]['net']); hi=max(out[True][1]['net'],out[False][1]['net'])
print(f"  intrabar-ordering bracket on net P/L: ${lo:.2f} .. ${hi:.2f}   (result sign is not determined)")
x=tr0.pnl.to_numpy(); n=len(x)
t=x.mean()/(x.std(ddof=1)/np.sqrt(n))
rng=np.random.default_rng(0); boot=np.array([rng.choice(x,n,replace=True).sum() for _ in range(20000)])
print(f"  t-stat on per-trade P/L: {t:.3f}   bootstrap 95% CI: [${np.percentile(boot,2.5):.2f}, ${np.percentile(boot,97.5):.2f}]")
print(f"  P(net<=0): {100*(boot<=0).mean():.1f}%     spread paid ${0.30*n:.2f}   gross before spread ${x.sum()+0.30*n:.2f}")

print(); print("="*104); print("3. COST SENSITIVITY (stop-first ordering)"); print("="*104)
for spread in [0.00,0.15,0.20,0.30,0.50,0.80]:
    c=sim.Cfg(spread=spread); L(f"spread ${spread:.2f}",sim.run(m5,sig,q,c,m1=m1)[0],c)
for slip in [0.05,0.10,0.20]:
    c=sim.Cfg(spread=0.30,entry_slippage=slip); L(f"spread $0.30 + {slip:.2f} entry slippage",sim.run(m5,sig,q,c,m1=m1)[0],c)

print(); print("="*104); print("4. M1-VALIDATED WINDOW ONLY (2026-04-06 -> 2026-08-07)"); print("="*104)
cut=pd.Timestamp('2026-04-06 06:29')
m5s=m5[m5.t>=cut].reset_index(drop=True); sigs=sig[sig.t>=cut].reset_index(drop=True); qs=q[sig.t>=cut].reset_index(drop=True)
for pess in (True,False):
    for mm,lab in [(m1,"M1 path"),(None,"M5 path")]:
        c=sim.Cfg(spread=0.30,pessimistic=pess)
        L(f"{lab}, {'stop-first' if pess else 'trail-first'}",sim.run(m5s,sigs,qs,c,m1=mm)[0],c)

print(); print("="*104); print("5. PARAMETER SENSITIVITY (stop-first, spread $0.30)"); print("="*104)
print(" -- MinimumProbability10Percent (the audit's 'only frequency lever') --")
for p in [0.50,0.60,0.65,0.70,0.75,0.80]:
    qq=engine.qualify(sig,min_p10=p); c=sim.Cfg(spread=0.30)
    L(f"min p10 = {p:.2f}",sim.run(m5,sig,qq,c,m1=m1)[0],c)
print(" -- exit structure --")
variants=[("default: SL15 trail 10/5",dict()),
          ("SL15, fixed TP 30, no trail",dict(use_tp=True,use_trailing=False)),
          ("SL15, TP30 + trail",dict(use_tp=True)),
          ("SL15, breakeven at 10",dict(use_breakeven=True)),
          ("SL15, no trail, time-only",dict(use_trailing=False)),
          ("SL10, trail 10/5",dict(initial_sl=10.0)),
          ("SL20, trail 10/5",dict(initial_sl=20.0)),
          ("SL15, trail 5/3",dict(trail_activate=5.0,trail_distance=3.0)),
          ("SL15, trail 15/8",dict(trail_activate=15.0,trail_distance=8.0)),
          ("no time stop",dict(max_hold_min=0)),
          ("no daily cap",dict(max_trades_per_day=0)),
          ("buys only",dict(allow_sell=False)),
          ("sells only",dict(allow_buy=False))]
for name,kw in variants:
    c=sim.Cfg(spread=0.30,**kw); L(name,sim.run(m5,sig,q,c,m1=m1)[0],c)

print(); print("="*104); print("6. MONTHLY P/L (stop-first, spread $0.30)"); print("="*104)
mth=tr0.set_index('t_out').pnl.resample('ME').agg(['sum','count'])
run_=0.0
for d,r in mth.iterrows():
    run_+=r['sum']
    bar='+'*int(max(0,r['sum'])/6) or ('-'*int(max(0,-r['sum'])/6))
    print(f"   {d:%Y-%m}  n={int(r['count']):>3}  ${r['sum']:>8.2f}   cum ${run_:>8.2f}  {bar}")
print(f"   positive months: {(mth['sum']>0).sum()} of {len(mth)}")
