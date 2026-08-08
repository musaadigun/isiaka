import engine, engine_v6, sim, pandas as pd, numpy as np
D='/root/.claude/uploads/a50d8688-03b5-5d0d-9782-3a7a29ea13fc/'
m1=engine.load_mt4_csv(D+'6887b622-new_GOLD1.csv'); m5=engine.load_mt4_csv(D+'7b120122-new_GOLD5.csv')
h1=engine.load_mt4_csv(D+'17124d93-new_GOLD60.csv')
def v6cfg(**kw):
    b=dict(initial_sl=25.0,use_tp=False,use_trailing=False,use_breakeven=False,max_hold_min=120,
           min_minutes_between=15,max_entry_deviation=3.0,max_spread_input=0.80,
           max_trades_per_day=3,fixed_lots=0.01,spread=0.30); b.update(kw); return sim.Cfg(**b)
def prep(s):
    s=s.copy(); s['p10']=s.confidence; s['p30']=s.m1_strength; s['h4body']=s.h1_gap; return s
sig=prep(engine_v6.compute_signals_v6(m1,m5,h1)); q=sig.qualified

print('='*96); print('A. DO THE SHIPPED VALUES SIT ON THE PEAK OF THEIR OWN SWEEP?'); print('='*96)
print('  InitialStopLossMovement (shipped = 25):')
for v in [10,15,20,25,30,35,40,50]:
    c=v6cfg(initial_sl=float(v)); tr,_=sim.run(m1,sig,q,c,m1=None); st=sim.stats(tr,c)
    mark=' <-- SHIPPED' if v==25 else ''
    print(f'     SL {v:>3}   net ${st["net"]:>7.2f}  PF {st["profit_factor"]:>5.3f}  n={st["trades"]}{mark}')
print('  MaximumHoldingMinutes (shipped = 120):')
for v in [30,60,90,120,150,180,240,360]:
    c=v6cfg(max_hold_min=v); tr,_=sim.run(m1,sig,q,c,m1=None); st=sim.stats(tr,c)
    mark=' <-- SHIPPED' if v==120 else ''
    print(f'     hold {v:>3}  net ${st["net"]:>7.2f}  PF {st["profit_factor"]:>5.3f}  n={st["trades"]}{mark}')

print(); print('='*96); print('B. SPLIT-HALF WITHIN THE 101 TRADES'); print('='*96)
tr,_=sim.run(m1,sig,q,v6cfg(),m1=None)
mid=tr.t_in.quantile(0.5)
for lab,x in [('first half ',tr[tr.t_in<mid]),('second half',tr[tr.t_in>=mid])]:
    pf=x[x.pnl>0].pnl.sum()/max(-x[x.pnl<=0].pnl.sum(),1e-9)
    print(f'  {lab} {x.t_in.min():%Y-%m-%d}..{x.t_in.max():%Y-%m-%d}  n={len(x):>3}  net ${x.pnl.sum():>7.2f}  PF {pf:.3f}  win {100*(x.pnl>0).mean():.1f}%')
print('  by data segment (M1 has a 56-day hole):')
for lab,mask in [('Apr 06-14',tr.t_in<pd.Timestamp('2026-05-01')),('Jun 09-Aug 07',tr.t_in>=pd.Timestamp('2026-05-01'))]:
    x=tr[mask]
    if not len(x): print(f'    {lab}: no trades'); continue
    pf=x[x.pnl>0].pnl.sum()/max(-x[x.pnl<=0].pnl.sum(),1e-9)
    print(f'    {lab:<14} n={len(x):>3}  net ${x.pnl.sum():>7.2f}  PF {pf:.3f}')
print('  by month:')
for d,r in tr.set_index('t_out').pnl.resample('ME').agg(['sum','count']).iterrows():
    if r['count']==0: continue
    print(f'    {d:%Y-%m}  n={int(r["count"]):>3}  ${r["sum"]:>8.2f}')

print(); print('='*96)
print('C. OUT-OF-WINDOW TEST — H1 gate + M5 setup only, over the FULL 12.4 months of M5 data')
print('   (drops the M1 trigger, which needs M1 data; tests whether the H1/M5 core generalises)')
print('='*96)
h1e=h1
t5=m5.t.to_numpy('datetime64[s]').astype(np.int64)
# reuse the V6 engine but drive it off M5 bars as the trigger timeframe
s2=engine_v6.compute_signals_v6(m5.assign(), m5, h1e)   # M1-role played by M5 itself
s2=prep(s2)
core=s2.valid & s2.h1_gate & s2.m5_setup
print(f'  qualified (H1 gate + M5 setup) on M5 bars: {int(core.sum())} of {int(s2.valid.sum())} valid')
for lab,mask in [('FULL 12.4 months', s2.t>=s2.t.min()),
                 ('OUTSIDE the M1 window', s2.t<pd.Timestamp('2026-04-06')),
                 ('INSIDE the M1 window',  s2.t>=pd.Timestamp('2026-04-06'))]:
    qq=core & mask
    if qq.sum()==0: continue
    c=v6cfg(); t2,_=sim.run(m5,s2,qq,c,m1=m1); st=sim.stats(t2,c)
    if not st.get('trades'): print(f'  {lab:<24} no trades'); continue
    print(f'  {lab:<24} n={st["trades"]:>4}  net ${st["net"]:>8.2f}  PF {st["profit_factor"]:>5.3f}  '
          f'win {st["win_rate"]:>4.1f}%  DD ${st["max_dd"]:>7.2f}  exp ${st["expectancy"]:>6.2f}')
