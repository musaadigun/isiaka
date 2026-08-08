import engine, engine_v6, sim, pandas as pd, numpy as np
D='/root/.claude/uploads/a50d8688-03b5-5d0d-9782-3a7a29ea13fc/'
m1=engine.load_mt4_csv(D+'6887b622-new_GOLD1.csv'); m5=engine.load_mt4_csv(D+'7b120122-new_GOLD5.csv')
h1=engine.load_mt4_csv(D+'17124d93-new_GOLD60.csv')

def v6cfg(**kw):
    base=dict(initial_sl=25.0, use_tp=False, use_trailing=False, use_breakeven=False,
              max_hold_min=120, min_minutes_between=15, max_entry_deviation=3.0,
              max_spread_input=0.80, max_trades_per_day=3, fixed_lots=0.01, spread=0.30)
    base.update(kw); return sim.Cfg(**base)

def prep(s):
    s=s.copy(); s['p10']=s.confidence; s['p30']=s.m1_strength; s['h4body']=s.h1_gap
    return s

def L(tag,tr,c,w=38):
    st=sim.stats(tr,c)
    if not st.get('trades'): print(f'  {tag:<{w}} no trades'); return st
    print(f"  {tag:<{w}} n={st['trades']:>3}  net ${st['net']:>8.2f}  PF {st['profit_factor']:>5.3f}  "
          f"win {st['win_rate']:>4.1f}%  DD ${st['max_dd']:>7.2f}  exp ${st['expectancy']:>6.2f}")
    return st

sig=prep(engine_v6.compute_signals_v6(m1,m5,h1))
q=sig.qualified

print('='*98); print('1. BASELINE — V6 shipped defaults (SL 25, no TP, no trail, 120-min stop)'); print('='*98)
out={}
for pess in (True,False):
    c=v6cfg(pessimistic=pess); tr,bl=sim.run(m1,sig,q,c,m1=None)
    out[pess]=(tr,L('stop-first' if pess else 'trail/target-first',tr,c),bl)
tr0,s0,bl0=out[True]
print('  exits: '+'  '.join(f'{k} {v}' for k,v in tr0.reason.value_counts().items()))
print('  entry blocks: '+'  '.join(f'{k} {v}' for k,v in bl0.items() if v))
print(f"  buys {(tr0.dir>0).sum()}  sells {(tr0.dir<0).sum()}")
dur=(tr0.t_out-tr0.t_in).dt.total_seconds()/60
print(f'  hold: median {dur.median():.0f} min  mean {dur.mean():.0f}  max {dur.max():.0f}  '
      f'({int((dur>125).sum())} spanned a data/weekend gap)')
tdays=tr0.t_in.dt.date.nunique()
print(f'  {tdays} distinct trading days -> {len(tr0)/tdays:.2f} trades/day')

print(); print('='*98); print('2. IS IT DISTINGUISHABLE FROM ZERO?'); print('='*98)
x=tr0.pnl.to_numpy(); n=len(x)
t=x.mean()/(x.std(ddof=1)/np.sqrt(n))
rng=np.random.default_rng(0); boot=np.array([rng.choice(x,n,replace=True).sum() for _ in range(20000)])
print(f'  n={n}  mean ${x.mean():.3f}  sd ${x.std(ddof=1):.2f}  t={t:.3f}')
print(f'  bootstrap 95% CI on net: [${np.percentile(boot,2.5):.2f}, ${np.percentile(boot,97.5):.2f}]   P(net<=0)={100*(boot<=0).mean():.1f}%')
print(f'  bracket from intrabar ordering: ${min(out[True][1]["net"],out[False][1]["net"]):.2f} .. ${max(out[True][1]["net"],out[False][1]["net"]):.2f}')

print(); print('='*98); print('3. COST SENSITIVITY'); print('='*98)
for sp in [0.00,0.15,0.30,0.50,0.80]:
    c=v6cfg(spread=sp); L(f'spread ${sp:.2f}',sim.run(m1,sig,q,c,m1=None)[0],c)
for sl in [0.05,0.15]:
    c=v6cfg(spread=0.30,entry_slippage=sl); L(f'spread $0.30 + ${sl:.2f} slippage',sim.run(m1,sig,q,c,m1=None)[0],c)

print(); print('='*98); print('4. DOES V6\'s OWN CONFIDENCE SCORE RANK OUTCOMES?'); print('='*98)
for col,lab in [('p10','V6 confidence'),('p30','M1 strength'),('h4body','H1 gap')]:
    tr0['_b']=pd.qcut(tr0[col],4,labels=['Q1 low','Q2','Q3','Q4 high'],duplicates='drop')
    g=tr0.groupby('_b',observed=True).agg(n=('pnl','size'),exp=('pnl','mean'),win=('pnl',lambda s:100*(s>0).mean()))
    print(f'  {lab}:  '+'   '.join(f'{k} ${r.exp:+.2f} (n={int(r.n)})' for k,r in g.iterrows()))
    print(f'      correlation with trade P/L = {np.corrcoef(tr0[col],tr0.pnl)[0,1]:+.4f}')

print(); print('='*98); print('5. RANDOM-DIRECTION CONTROL (200 runs)'); print('='*98)
rng=np.random.default_rng(3); nets=[]
for _ in range(200):
    s2=sig.copy(); f=rng.random(len(s2))<0.5
    s2['direction']=np.where(f,-s2['direction'],s2['direction'])
    t2,_=sim.run(m1,s2,q,v6cfg(),m1=None); nets.append(t2.pnl.sum() if len(t2) else 0.0)
nets=np.array(nets); real=x.sum()
print(f'  real ${real:.2f}  vs coin-flip mean ${nets.mean():.2f} sd ${nets.std():.2f} '
      f'-> {100*(nets<real).mean():.0f}th percentile')

print(); print('='*98); print('6. PARAMETER / STRUCTURE SENSITIVITY'); print('='*98)
for name,kw in [('shipped default',{}),('+ trailing 10/5',dict(use_trailing=True)),
                ('+ fixed TP 30',dict(use_tp=True)),('+ TP 30, no time stop',dict(use_tp=True,max_hold_min=0)),
                ('SL 15 (V4 value)',dict(initial_sl=15.0)),('SL 40',dict(initial_sl=40.0)),
                ('hold 60 min',dict(max_hold_min=60)),('hold 240 min',dict(max_hold_min=240)),
                ('no daily cap',dict(max_trades_per_day=0)),
                ('buys only',dict(allow_sell=False)),('sells only',dict(allow_buy=False))]:
    c=v6cfg(**kw); L(name,sim.run(m1,sig,q,c,m1=None)[0],c)

print(); print('='*98); print('7. STALENESS REGRESSION — effect of restoring V4\'s guard'); print('='*98)
sg=prep(engine_v6.compute_signals_v6(m1,m5,h1,max_stale_hours=12.0))
c=v6cfg(); L('as shipped (no staleness bound)',sim.run(m1,sig,q,c,m1=None)[0],c)
L('with H1 <= 12h guard restored',sim.run(m1,sg,sg.qualified,c,m1=None)[0],c)
tr0.to_csv('trades_v6.csv',index=False)
