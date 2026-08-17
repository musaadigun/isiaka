"""
Does entering on the BREAK OF THE CHOP beat entering on the crossing?

Motivated by the M30 chart where price crossed and re-crossed EMA50 in a tight
cluster, the EA declined every one, and the real move began when price left the
cluster. Resamples the supplied M5 GOLD export to M30 and compares:

  A. bare EMA50 cross                       (what v6/v7 evaluates)
  B. cross + the EA's own range-vote filter (what v6/v7 actually trades)
  C. break of the consolidation box         (the proposed route)

All three pay the same spread and use the same stop/target geometry, so the
comparison is about entry timing only.
"""
import pandas as pd, numpy as np

CSV = "/root/.claude/uploads/dceed96d-259e-5c91-bca6-e59cad72f701/f7e662b4-new_GOLD5.csv"
COST = 0.30          # round-trip, $/oz
BUFFER_ATR = 0.05    # entry buffer beyond the box, matches RetestEntryBufferATR

m5 = pd.read_csv(CSV, header=None,
                 names=["date", "time", "open", "high", "low", "close", "vol"])
m5["dt"] = pd.to_datetime(m5["date"] + " " + m5["time"], format="%Y.%m.%d %H:%M")
m5 = m5.sort_values("dt").set_index("dt")

df = m5.resample("30min").agg({"open": "first", "high": "max",
                               "low": "min", "close": "last"}).dropna().reset_index()

df["ema"] = df["close"].ewm(span=50, adjust=False).mean()
tr = pd.concat([df["high"] - df["low"],
                (df["high"] - df["close"].shift()).abs(),
                (df["low"] - df["close"].shift()).abs()], axis=1).max(axis=1)
df["atr"] = tr.ewm(alpha=1/14, adjust=False).mean()

o, h, l, c = (df[x].to_numpy() for x in ("open", "high", "low", "close"))
ema, atr, dt = df["ema"].to_numpy(), df["atr"].to_numpy(), df["dt"].to_numpy()
n = len(df)
half = n // 2

above = c > ema
cross = np.zeros(n, bool); cross[1:] = above[1:] != above[:-1]
cross_up = np.zeros(n, bool); cross_up[1:] = above[1:] & ~above[:-1]
cross_dn = np.zeros(n, bool); cross_dn[1:] = ~above[1:] & above[:-1]
cross[:200] = cross_up[:200] = cross_dn[:200] = False

slope = np.full(n, np.nan)
slope[3:] = (ema[3:] - ema[:-3]) / np.maximum(atr[3:], 1e-9)   # GradientLookbackBars=3

print(f"M30 bars {n:,}   {pd.Timestamp(dt[0]):%Y-%m-%d} -> {pd.Timestamp(dt[-1]):%Y-%m-%d}")
print(f"crosses  {cross.sum():,}")


def rolling_crossings(i, w):
    """EMA crossings inside the last w closed bars ending at i (RangeLookbackBars)."""
    return int(cross[max(0, i - w + 1):i + 1].sum())


def range_votes(i, w=8):
    """The EA's own three-vote range test, reproduced."""
    votes = 0
    if rolling_crossings(i, w) >= 3:                       # RangeCrossingVoteMinimum
        votes += 1
    if abs(slope[i]) < 0.02:                               # FlatGradientThreshold
        votes += 1
    seg = c[max(0, i - w):i + 1]
    move = np.abs(np.diff(seg)).sum()
    eff = abs(seg[-1] - seg[0]) / move if move > 0 else 0.0
    if eff < 0.25:                                         # MinimumDirectionalEfficiency
        votes += 1
    return votes


def walk(entry_i, entry_px, sign, sl, tp, max_bars):
    """Bar-by-bar from entry_i. Stop assumed to fill first inside a bar."""
    end = min(entry_i + max_bars, n - 1)
    for j in range(entry_i, end + 1):
        if sign > 0:
            if l[j] <= sl: return sl - entry_px
            if h[j] >= tp: return tp - entry_px
        else:
            if h[j] >= sl: return entry_px - sl
            if l[j] <= tp: return entry_px - tp
    return sign * (c[end] - entry_px)


def report(name, trades):
    if len(trades) < 10:
        print(f"  {name:<34} too few trades ({len(trades)})")
        return
    a = np.array([t[1] for t in trades])
    idx = np.array([t[0] for t in trades])
    t1, t2 = a[idx < half], a[idx >= half]
    tstat = a.mean() / (a.std(ddof=1) / np.sqrt(len(a)))
    print(f"  {name:<34} {len(a):>5} {a.mean():>8.3f} {a.sum():>9.0f} "
          f"{(a > 0).mean()*100:>6.1f} {tstat:>6.2f} {t1.mean():>8.3f} {t2.mean():>8.3f}")


# ---------------------------------------------------------------- A and B ---
def cross_trades(use_votes, sl_atr=1.5, tp_atr=2.0, max_bars=16):
    out = []
    for i in np.flatnonzero(cross_up | cross_dn):
        if i + 1 >= n or not np.isfinite(slope[i]) or atr[i] <= 0:
            continue
        if use_votes and range_votes(i) > 1:               # MaximumRangeVotesForContinuation
            continue
        sign = 1 if cross_up[i] else -1
        if use_votes and sign * slope[i] < 0.04:           # ContinuationGradientMinimum
            continue
        e = o[i + 1]
        out.append((i, walk(i + 1, e, sign,
                            e - sign * sl_atr * atr[i],
                            e + sign * tp_atr * atr[i], max_bars) - COST))
    return out


# ------------------------------------------------------------------- C ------
def box_breakout(win=8, min_crossings=2, max_box_atr=2.5, valid_bars=6,
                 tp_atr=2.0, max_bars=16, require_slope=True):
    """
    A consolidation is `win` closed bars containing at least `min_crossings`
    EMA crossings and spanning no more than `max_box_atr` ATR. Arm a stop entry
    beyond the box in the EMA-slope direction, valid for `valid_bars` bars.
    Stop goes on the far side of the box -- the chop defines the invalidation.
    """
    out = []
    i = 200
    while i < n - 1:
        if atr[i] <= 0 or not np.isfinite(slope[i]):
            i += 1; continue
        if rolling_crossings(i, win) < min_crossings:
            i += 1; continue

        seg = slice(i - win + 1, i + 1)
        bx_hi, bx_lo = h[seg].max(), l[seg].min()
        if (bx_hi - bx_lo) > max_box_atr * atr[i]:
            i += 1; continue

        sign = 1 if slope[i] > 0 else -1
        if require_slope and abs(slope[i]) < 0.02:
            i += 1; continue

        buf = BUFFER_ATR * atr[i]
        trigger = bx_hi + buf if sign > 0 else bx_lo - buf
        stop = bx_lo - buf if sign > 0 else bx_hi + buf
        if (trigger - stop) * sign <= 0:
            i += 1; continue

        fired = None
        for j in range(i + 1, min(i + 1 + valid_bars, n)):
            if (sign > 0 and h[j] >= trigger) or (sign < 0 and l[j] <= trigger):
                fired = j; break
        if fired is None:
            i += 1; continue

        e = trigger                       # stop order fills at the trigger
        risk = abs(e - stop)
        tp = e + sign * tp_atr * atr[i]
        out.append((i, walk(fired, e, sign, stop, tp, max_bars) - COST))
        i = fired + 1                     # one trade per consolidation
    return out


hdr = (f"  {'route':<34} {'n':>5} {'mean $':>8} {'total $':>9} "
       f"{'win%':>6} {'t':>6} {'1st half':>8} {'2nd half':>8}")

print("\n" + "=" * 96)
print(f"M30, SL/TP geometry held constant, ${COST:.2f} cost per trade")
print("=" * 96)
print(hdr)
report("A. bare EMA50 cross", cross_trades(False))
report("B. cross + range-vote filter", cross_trades(True))
report("C. consolidation breakout", box_breakout())

print("\n  C variants")
for win in (6, 8, 12):
    for mc in (2, 3):
        report(f"   box {win} bars, >={mc} crossings",
               box_breakout(win=win, min_crossings=mc))

print("\n  C, stop on far side of box vs fixed ATR stop")
report("   box stop (risk = box height)", box_breakout())
