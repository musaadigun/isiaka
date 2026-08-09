#!/usr/bin/env python3
"""
backtest_v2_claude.py - offline simulator for XVISION_EURUSD_Intraday_EA_v2_claude.mq4

WHAT THIS IS
    A faithful reimplementation of the EA's two engines, run over historical
    EURUSD bars you supply. It answers the two questions that matter:
    how often does it trade, and does it make money net of cost.

WHAT THIS IS NOT
    MT4's Strategy Tester. This is a SECOND implementation of the same rules,
    so a divergence between the two is possible and is itself a finding worth
    chasing. MT4's tester remains the authority on how the .mq4 will actually
    behave. Use this to reason about the strategy; use MT4 to verify the code.

    It also cannot model YOUR broker: fills, slippage, requotes, variable
    spread and weekend gaps are approximated by a single flat CostPips.

IT WILL NOT INVENT DATA
    There is no bundled price series and no synthetic fallback. Without a real
    data file it refuses to run, because a fabricated equity curve that looks
    authoritative is worse than no answer at all.

GETTING DATA (you already have a source - MT4 itself)
    MT4: Tools -> History Center -> EURUSD -> M15 -> Export -> CSV.
    M1 also works and is better: it resolves stop-vs-target ordering inside
    each M15 bar instead of assuming. Several years is ideal; below ~6 months
    the sample is too thin for the result to mean anything.

USAGE
    python3 backtest_v2_claude.py --data EURUSD_M15.csv
    python3 backtest_v2_claude.py --data EURUSD_M1.csv --cost 1.5 --csv trades.csv
    python3 backtest_v2_claude.py --selftest      # mechanism check, NOT a result
"""

import argparse, csv, math, sys
from collections import defaultdict
from datetime import datetime, timedelta, date

# ---- parameters, mirroring the EA's inputs exactly -------------------------
P = dict(
    ASIAN_START=0, ASIAN_END=7, BREAKOUT_END=11, FLAT_BY=16,
    MIN_ASIAN_BARS=20, MIN_MINUTES_BEFORE_FLAT=60,
    MAX_RANGE_TO_ADR=0.55, MIN_RANGE_TO_ADR=0.12,
    BREAK_BUFFER_ATR=0.25, BREAK_RR=1.5, BREAK_STOP_ATR_CAP=2.0,
    FADE_MID_PERIOD=50, FADE_BAND_ATR=2.2, FADE_STOP_ATR=1.2,
    FADE_MAX_ADR_USED=0.60,
    COST_PIPS=1.0, MAX_TRADES_PER_DAY=4,
)
PIP = 0.0001
BREAK, FADE = "LONDON-BREAKOUT", "ASIAN-FADE"


# ---------------------------------------------------------------- data load
def load_bars(path):
    """MT4 export (2023.01.02,00:00,o,h,l,c,v) or ISO datetime; header optional."""
    out = []
    with open(path, newline="") as fh:
        for row in csv.reader(fh):
            if not row or len(row) < 5:
                continue
            try:
                if "." in row[0] and ":" in str(row[1]):          # MT4: date,time,...
                    dt = datetime.strptime(f"{row[0]} {row[1]}", "%Y.%m.%d %H:%M")
                    o, h, l, c = map(float, row[2:6])
                elif ":" in row[0]:                                # ISO in one field
                    stamp = row[0].replace("T", " ").split("+")[0].strip()
                    fmt = "%Y-%m-%d %H:%M:%S" if stamp.count(":") == 2 else "%Y-%m-%d %H:%M"
                    dt = datetime.strptime(stamp, fmt)
                    o, h, l, c = map(float, row[1:5])
                else:
                    continue
            except (ValueError, IndexError):
                continue                                           # header or junk
            if h < l or min(o, h, l, c) <= 0:
                continue
            out.append((dt, o, h, l, c))
    out.sort(key=lambda b: b[0])
    if len(out) < 200:
        sys.exit(f"ERROR: only {len(out)} usable bars in {path}. Need a real series.")
    return out


def detect_tf(bars):
    deltas = defaultdict(int)
    for a, b in zip(bars[:400], bars[1:401]):
        deltas[int((b[0] - a[0]).total_seconds() // 60)] += 1
    return min((m for m, n in deltas.items() if m > 0 and n > 5), default=15)


def to_m15(bars):
    """Aggregate to M15 on clean 15-minute boundaries."""
    buckets, out = defaultdict(list), []
    for dt, o, h, l, c in bars:
        buckets[dt.replace(minute=(dt.minute // 15) * 15, second=0)].append((dt, o, h, l, c))
    for key in sorted(buckets):
        g = sorted(buckets[key], key=lambda x: x[0])
        out.append((key, g[0][1], max(x[2] for x in g), min(x[3] for x in g), g[-1][4]))
    return out


# ------------------------------------------------------------------ indicators
def atr_series(bars, period):
    """Wilder ATR aligned to bars; None until warm."""
    out, trs, prev_close, acc = [], [], None, None
    for _, o, h, l, c in bars:
        tr = h - l if prev_close is None else max(h - l, abs(h - prev_close), abs(l - prev_close))
        trs.append(tr)
        if len(trs) < period:
            out.append(None)
        elif len(trs) == period:
            acc = sum(trs) / period
            out.append(acc)
        else:
            acc = (acc * (period - 1) + tr) / period
            out.append(acc)
        prev_close = c
    return out


def sma_series(bars, period):
    out, run = [], 0.0
    for i, b in enumerate(bars):
        run += b[4]
        if i >= period:
            run -= bars[i - period][4]
        out.append(run / period if i >= period - 1 else None)
    return out


def daily_adr(bars, period=14):
    """ATR(D1,period) keyed by GMT date, using only COMPLETED prior days."""
    days = defaultdict(lambda: [None, -1e9, 1e9, None])
    for dt, o, h, l, c in bars:
        d = days[dt.date()]
        if d[0] is None:
            d[0] = o
        d[1], d[2], d[3] = max(d[1], h), min(d[2], l), c
    keys = sorted(days)
    adr, trs, prev_close = {}, [], None
    for k in keys:
        o, h, l, c = days[k]
        tr = h - l if prev_close is None else max(h - l, abs(h - prev_close), abs(l - prev_close))
        adr[k] = sum(trs[-period:]) / period if len(trs) >= period else None
        trs.append(tr)
        prev_close = c
    return adr, days


# ------------------------------------------------------------------ the engines
def flat_deadline(dt, eng):
    hour = P["ASIAN_END"] if eng == FADE else P["FLAT_BY"]
    dl = datetime.combine(dt.date(), datetime.min.time()) + timedelta(hours=hour)
    return dl + timedelta(days=1) if dl <= dt else dl


def levels_sane(direction, entry, stop, target, cost_pips):
    if direction > 0 and not (stop < entry < target):
        return False
    if direction < 0 and not (target < entry < stop):
        return False
    risk_pips = abs(entry - stop) / PIP
    return 2.0 * cost_pips <= risk_pips <= 200.0


def run(bars, cost_pips, verbose=False):
    atr14 = atr_series(bars, 14)
    sma = sma_series(bars, P["FADE_MID_PERIOD"])
    adr, dayagg = daily_adr(bars)
    index = {b[0]: i for i, b in enumerate(bars)}

    open_pos, trades = {}, []
    day_done_break, day_trades, sess = set(), defaultdict(int), {}

    def asian_range(d):
        """Completed Asian range for date d, or None. Mirrors BuildSession()."""
        if d in sess:
            return sess[d]
        lo_t = datetime.combine(d, datetime.min.time()) + timedelta(hours=P["ASIAN_START"])
        hi_t = datetime.combine(d, datetime.min.time()) + timedelta(hours=P["ASIAN_END"])
        window = [b for b in bars if lo_t <= b[0] < hi_t]
        sess[d] = None if len(window) < P["MIN_ASIAN_BARS"] else (
            max(b[2] for b in window), min(b[3] for b in window))
        return sess[d]

    def close_pos(eng, i, price, reason):
        p = open_pos.pop(eng)
        gross = (price - p["entry"]) * p["dir"] / p["risk"]
        net = gross - (cost_pips * PIP) / p["risk"]
        trades.append(dict(engine=eng, dir=p["dir"], opened=p["opened"], closed=bars[i][0],
                           entry=p["entry"], exit=price, gross_R=gross, net_R=net,
                           reason=reason, risk_pips=p["risk"] / PIP,
                           entry_hour=p["opened"].hour))

    for i in range(P["FADE_MID_PERIOD"] + 120, len(bars)):
        dt, o, h, l, c = bars[i]
        d, hour = dt.date(), dt.hour

        # ---- exits first, on this bar's range. Stop wins a tie: if both the
        # stop and the target sit inside one bar we cannot know the order, so
        # we always assume the adverse one. Optimism here is how backtests lie.
        for eng in list(open_pos):
            p = open_pos[eng]
            if p["opened"] == dt:
                continue
            hit_stop = l <= p["stop"] if p["dir"] > 0 else h >= p["stop"]
            hit_tgt = h >= p["target"] if p["dir"] > 0 else l <= p["target"]
            if hit_stop:
                close_pos(eng, i, p["stop"], "stop")
            elif hit_tgt:
                close_pos(eng, i, p["target"], "target")
            elif dt >= p["deadline"]:
                close_pos(eng, i, c, "session flat")

        if atr14[i - 1] is None or sma[i - 1] is None or adr.get(d) is None:
            continue
        atr, a = atr14[i - 1], adr[d]

        signals = []
        # ---- ENGINE B, inside the Asian window, needs no range
        if (P["ASIAN_START"] <= hour < P["ASIAN_END"] and FADE not in open_pos
                and sma[i - 2] is not None and atr14[i - 2] is not None):
            dd = dayagg[d]
            if (dd[1] - dd[2]) / a <= P["FADE_MAX_ADR_USED"]:
                band2 = P["FADE_BAND_ATR"] * atr14[i - 2]
                if abs(bars[i - 1][4] - sma[i - 2]) < band2:          # was inside
                    band = P["FADE_BAND_ATR"] * atr
                    if bars[i - 1][4] > sma[i - 1] + band:
                        signals.append((FADE, -1))
                    elif bars[i - 1][4] < sma[i - 1] - band:
                        signals.append((FADE, 1))

        # ---- ENGINE A, after the range completes
        if (P["ASIAN_END"] <= hour < P["BREAKOUT_END"] and BREAK not in open_pos
                and (d, BREAK) not in day_done_break):
            rng = asian_range(d)
            if rng:
                hi, lo = rng
                ratio = (hi - lo) / a
                if P["MIN_RANGE_TO_ADR"] <= ratio <= P["MAX_RANGE_TO_ADR"]:
                    buf = P["BREAK_BUFFER_ATR"] * atr
                    if bars[i - 1][4] > hi + buf:
                        signals.append((BREAK, 1))
                    elif bars[i - 1][4] < lo - buf:
                        signals.append((BREAK, -1))

        for eng, direction in signals:
            dl = flat_deadline(dt, eng)
            if (dl - dt).total_seconds() < P["MIN_MINUTES_BEFORE_FLAT"] * 60:
                continue
            if day_trades[d] >= P["MAX_TRADES_PER_DAY"]:
                continue
            entry = o
            if eng == BREAK:
                hi, lo = asian_range(d)
                opp = lo if direction > 0 else hi
                cap = P["BREAK_STOP_ATR_CAP"] * atr
                if abs(entry - opp) > cap:
                    opp = entry - direction * cap
                stop = opp
                target = entry + direction * P["BREAK_RR"] * abs(entry - stop)
                day_done_break.add((d, BREAK))
            else:
                ext = bars[i - 1][3] if direction > 0 else bars[i - 1][2]
                stop = ext - direction * P["FADE_STOP_ATR"] * atr
                target = sma[i - 1]
            if not levels_sane(direction, entry, stop, target, cost_pips):
                continue
            open_pos[eng] = dict(dir=direction, entry=entry, stop=stop, target=target,
                                 risk=abs(entry - stop), opened=dt, deadline=dl)
            day_trades[d] += 1
            # a trade entered at this bar's open can still resolve inside it
            p = open_pos[eng]
            hit_stop = l <= stop if direction > 0 else h >= stop
            hit_tgt = h >= target if direction > 0 else l <= target
            if hit_stop:
                close_pos(eng, i, stop, "stop")
            elif hit_tgt:
                close_pos(eng, i, target, "target")

    return trades, bars


# ------------------------------------------------------------------- reporting
def drawdown(seq):
    peak = cum = worst = 0.0
    for r in seq:
        cum += r
        peak = max(peak, cum)
        worst = min(worst, cum - peak)
    return worst


def report(trades, bars, cost_pips, risk_pct):
    span_days = {b[0].date() for b in bars}
    sessions = {d for d in span_days if d.weekday() < 5}
    print("=" * 74)
    print("  SIMULATED RESULT - reimplementation of the rules, NOT MT4's tester")
    print(f"  {bars[0][0]:%Y-%m-%d} to {bars[-1][0]:%Y-%m-%d}   "
          f"{len(bars):,} M15 bars   {len(sessions):,} weekday sessions")
    print(f"  cost modelled: {cost_pips:.2f} pips round turn, charged to every trade")
    print("=" * 74)
    if not trades:
        print("\n  NO TRADES. Check the GMT alignment of your data before believing this.")
        return

    net = [t["net_R"] for t in trades]
    gross = [t["gross_R"] for t in trades]
    wins = [r for r in net if r > 0]
    losses = [r for r in net if r <= 0]
    traded_days = {t["opened"].date() for t in trades}

    print(f"\n  FREQUENCY")
    print(f"    trades                 {len(trades):,}")
    print(f"    days with >=1 trade    {len(traded_days):,} of {len(sessions):,} "
          f"({100*len(traded_days)/max(len(sessions),1):.1f}%)")
    print(f"    trades per session     {len(trades)/max(len(sessions),1):.2f}")

    exp = sum(net) / len(net)
    pf = (sum(wins) / abs(sum(losses))) if losses and sum(losses) else float("inf")
    sd = (sum((r - exp) ** 2 for r in net) / len(net)) ** 0.5 if len(net) > 1 else 0.0
    print(f"\n  PROFITABILITY (R = one unit of risk, net of cost)")
    print(f"    total net              {sum(net):+.1f} R")
    print(f"    expectancy / trade     {exp:+.4f} R")
    print(f"    win rate               {100*len(wins)/len(net):.1f}%")
    print(f"    profit factor          {pf:.2f}")
    print(f"    max drawdown           {drawdown(net):.1f} R")
    if sd:
        print(f"    t-stat vs zero         {exp/(sd/math.sqrt(len(net))):.2f}"
              f"   ({'unconvincing' if abs(exp/(sd/math.sqrt(len(net)))) < 2 else 'holds up'} at n={len(net)})")
    print(f"    at {risk_pct:.2f}% risk/trade  {sum(net)*risk_pct:+.1f}% simple return, "
          f"{drawdown(net)*risk_pct:.1f}% max DD")

    drag = sum(gross) - sum(net)
    print(f"\n  WHAT COST TOOK")
    print(f"    gross {sum(gross):+.1f} R  ->  net {sum(net):+.1f} R   "
          f"(friction {drag:.1f} R, {100*drag/abs(sum(gross)) if sum(gross) else 0:.0f}% of gross)")

    print(f"\n  BY ENGINE")
    for eng in (BREAK, FADE):
        e = [t for t in trades if t["engine"] == eng]
        if not e:
            print(f"    {eng:<17} no trades")
            continue
        w = [t for t in e if t["net_R"] > 0]
        print(f"    {eng:<17} {len(e):>4} trades  {sum(t['net_R'] for t in e):+8.1f} R  "
              f"exp {sum(t['net_R'] for t in e)/len(e):+.3f}  win {100*len(w)/len(e):.0f}%")

    print(f"\n  BY YEAR")
    yr = defaultdict(list)
    for t in trades:
        yr[t["opened"].year].append(t["net_R"])
    for y in sorted(yr):
        print(f"    {y}   {len(yr[y]):>4} trades  {sum(yr[y]):+8.1f} R  "
              f"exp {sum(yr[y])/len(yr[y]):+.3f}")

    print(f"\n  COST SENSITIVITY (the binding constraint at this frequency)")
    for c in (0.5, 1.0, 1.5, 2.0, 2.5):
        adj = [t["gross_R"] - (c * PIP) / (t["risk_pips"] * PIP) for t in trades]
        print(f"    {c:.1f} pips -> {sum(adj):+8.1f} R total, {sum(adj)/len(adj):+.4f} R/trade"
              f"{'   <- unprofitable' if sum(adj) < 0 else ''}")
    print()


def selftest():
    """Mechanism check on a deterministic ramp. Proves the harness moves money
    correctly. Says NOTHING about whether the strategy works."""
    print("SELFTEST - mechanism only, NOT a performance result\n")
    bars, t = [], datetime(2024, 1, 1)
    px = 1.1000
    for i in range(4000):
        px += 0.00008 * math.sin(i / 40.0) + 0.00002 * math.sin(i / 7.0)
        bars.append((t, px, px + 0.0004, px - 0.0004, px + 0.00005))
        t += timedelta(minutes=15)
    trades, _ = run(bars, 1.0)
    print(f"  harness produced {len(trades)} trades on a synthetic wave")
    if trades:
        s = trades[0]
        chk = (s["exit"] - s["entry"]) * s["dir"] / (s["risk_pips"] * PIP)
        print(f"  R arithmetic {'OK' if abs(chk - s['gross_R']) < 1e-9 else 'BROKEN'}"
              f"  (recomputed {chk:+.4f} vs reported {s['gross_R']:+.4f})")
        print(f"  cost applied {'OK' if s['gross_R'] > s['net_R'] else 'BROKEN'}"
              f"  (net {s['net_R']:+.4f} below gross {s['gross_R']:+.4f})")
    print("\n  Mechanics only. Feed it real data for anything meaningful.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", help="EURUSD M1 or M15 CSV (MT4 History Center export works)")
    ap.add_argument("--cost", type=float, default=P["COST_PIPS"], help="round-turn cost in pips")
    ap.add_argument("--risk", type=float, default=0.75, help="%% risk per trade, for the %% column")
    ap.add_argument("--csv", help="write the trade-by-trade log here")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest:
        return selftest()
    if not a.data:
        sys.exit("ERROR: --data is required. This tool will not invent a price series.\n"
                 "       Export one from MT4: Tools -> History Center -> EURUSD -> M15 -> Export.")

    raw = load_bars(a.data)
    tf = detect_tf(raw)
    bars = raw if tf == 15 else to_m15(raw)
    print(f"loaded {len(raw):,} bars at ~M{tf}"
          + (f", aggregated to {len(bars):,} M15 bars" if tf != 15 else ""))
    if tf > 15:
        print(f"WARNING: M{tf} is coarser than M15. Results will not reflect the EA.")

    trades, bars = run(bars, a.cost)
    report(trades, bars, a.cost, a.risk)

    if a.csv and trades:
        with open(a.csv, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(trades[0].keys()))
            w.writeheader()
            w.writerows(trades)
        print(f"trade log -> {a.csv}")

    print("Reminder: this is a second implementation of the rules. Before trusting")
    print("any number above, run the .mq4 in MT4's tester and confirm they agree.")


if __name__ == "__main__":
    main()
