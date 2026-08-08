import engine, sim, pandas as pd, numpy as np, json
D='/root/.claude/uploads/a50d8688-03b5-5d0d-9782-3a7a29ea13fc/'
h1=engine.load_mt4_csv(D+'17124d93-new_GOLD60.csv'); m5=engine.load_mt4_csv(D+'7b120122-new_GOLD5.csv')
m1=engine.load_mt4_csv(D+'6887b622-new_GOLD1.csv'); h4=engine.build_h4(h1)
sig=engine.compute_signals(m5,h4); q=engine.qualify(sig)
out={}
curves={}
for pess,name in [(True,'stopfirst'),(False,'trailfirst')]:
    tr,_=sim.run(m5,sig,q,sim.Cfg(spread=0.30,pessimistic=pess),m1=m1)
    eq=tr.pnl.cumsum()
    curves[name]=[[int(t.timestamp()),round(float(v),2)] for t,v in zip(tr.t_out,eq)]
    out[name]=dict(n=len(tr),net=round(float(tr.pnl.sum()),2))
# gold price path, weekly, for context
gp=m5.set_index('t').c.resample('W').last().dropna()
out['gold']=[[int(t.timestamp()),round(float(v),2)] for t,v in gp.items()]
out['curves']=curves
tr,_=sim.run(m5,sig,q,sim.Cfg(spread=0.30),m1=m1)
mth=tr.set_index('t_out').pnl.resample('ME').agg(['sum','count'])
out['monthly']=[[d.strftime('%Y-%m'),round(float(r['sum']),2),int(r['count'])] for d,r in mth.iterrows()]
qd={}
for col in ['p10','p30','h4body']:
    tr['_b']=pd.qcut(tr[col],4,labels=['Q1','Q2','Q3','Q4'],duplicates='drop')
    g=tr.groupby('_b',observed=True).pnl.agg(['size','mean'])
    qd[col]=[[str(k),int(r['size']),round(float(r['mean']),3)] for k,r in g.iterrows()]
out['quartiles']=qd
nets=np.load('random_nets.npy'); out['random']=dict(mean=round(float(nets.mean()),2),sd=round(float(nets.std()),2),
    p5=round(float(np.percentile(nets,5)),2),p95=round(float(np.percentile(nets,95)),2),
    pct=round(float(100*(nets<tr.pnl.sum()).mean()),1))
json.dump(out,open('chartdata.json','w'))
print('curve pts stop-first',len(curves['stopfirst']),'trail-first',len(curves['trailfirst']),'gold',len(out['gold']))
print('net stop-first',out['stopfirst'],'trail-first',out['trailfirst'])
print('quartiles p10:',qd['p10'])
print('random:',out['random'])
