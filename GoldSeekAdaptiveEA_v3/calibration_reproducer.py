def clamp(v,lo,hi): return max(lo,min(hi,v))
def prior(b): return [0.08,0.11,0.14,0.17,0.21][b] if b<=4 else 0.21
def bin_of(p):
    if p<0.12: return 0
    if p<0.16: return 1
    if p<0.20: return 2
    if p<0.25: return 3
    return 4

# 1. reachable range of the OFFLINE score
mx = 0.055+0.050+0.025+0.012+0.008
mn = 0.055-0.020
print("offline raw range: [%.4f, %.4f]  -> after Clamp(.,0.03,0.20): [%.4f, %.4f]"
      % (mn,mx,clamp(mn,0.03,0.20),clamp(mx,0.03,0.20)))
print("bins reachable on the READ side:", sorted({bin_of(mn),bin_of(mx),bin_of(0.12),bin_of(0.1599)}))

# 2. ratchet simulation
def apply(offline,hits,misses):
    b=bin_of(offline); n=hits[b]+misses[b]
    post=(20.0*prior(b)+hits[b])/(20.0+n)
    w=clamp(n/60.0,0.0,0.65)
    return clamp((1-w)*offline+w*post,0.02,0.60), b

for off in (0.150,0.130,0.110,0.090):
    hits=[0.0]*5; misses=[0.0]*5
    print("\n--- steady offline=%.3f, every trade labelled MISS30 ---"%off)
    frozen=None
    for t in range(1,201):
        cal,rb = apply(off,hits,misses)
        wb = bin_of(cal)                       # EA writes to bin(calibrated)
        misses[wb]+=1                          # MISS30
        if rb!=wb and frozen is None:
            frozen=(t,rb,wb,cal)
        if t in (1,5,20,50,200):
            pq=clamp((cal-0.04)/0.13,0,1)
            print("  trade %3d: readbin=%d writebin=%d calP30=%.4f probQuality=%.3f (n_read=%d)"
                  %(t,rb,wb,cal,pq,int(hits[rb]+misses[rb])))
    if frozen: print("  >> read/write bins diverge at trade %d (read=%d write=%d, calP30=%.4f)"%frozen)
    print("  final counters per bin:", [int(x) for x in misses])
