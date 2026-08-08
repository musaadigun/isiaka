import engine, sim, pandas as pd, numpy as np, sys
D='/root/.claude/uploads/a50d8688-03b5-5d0d-9782-3a7a29ea13fc/'
h1=engine.load_mt4_csv(D+'17124d93-new_GOLD60.csv')
m5=engine.load_mt4_csv(D+'7b120122-new_GOLD5.csv')
m1=engine.load_mt4_csv(D+'6887b622-new_GOLD1.csv')
h4=engine.build_h4(h1)
sig=engine.compute_signals(m5,h4)
q=engine.qualify(sig)

def show(name,tr,st,blocked=None):
    if not st.get("trades"):
        print(f"{name}: NO TRADES"); return
    print(f"\n=== {name} ===")
    print(f"  trades {st['trades']:>4}   net ${st['net']:>9.2f}   return {st['return_pct']:>6.2f}%   "
          f"PF {st['profit_factor']:.3f}   win {st['win_rate']:.1f}%")
    print(f"  expectancy ${st['expectancy']:>6.2f}/trade   avg win ${st['avg_win']:.2f}   avg loss ${st['avg_loss']:.2f}")
    print(f"  max DD ${st['max_dd']:.2f} ({st['max_dd_pct']:.2f}%)   best ${st['best']:.2f}   worst ${st['worst']:.2f}")
    print(f"  {st['days']} days, {st['trades_per_month']:.1f} trades/month")
    print("  exits: "+"  ".join(f"{k} {v}" for k,v in tr.reason.value_counts().items()))
    if blocked: print("  entry blocks: "+"  ".join(f"{k} {v}" for k,v in blocked.items() if v))

print("qualified signal bars:",int(q.sum()))
cfg=sim.Cfg(spread=0.30)
tr,bl=sim.run(m5,sig,q,cfg,m1=m1)
show("BASELINE - shipped defaults, spread $0.30, pessimistic intrabar",tr,sim.stats(tr,cfg),bl)
tr.to_csv('trades_baseline.csv',index=False)
print("\nfirst 5 and last 5 trades:")
cols=['t_in','t_out','dir','entry','exit','move','pnl','reason','h4body']
print(tr[cols].head().to_string(index=False))
print(tr[cols].tail().to_string(index=False))
