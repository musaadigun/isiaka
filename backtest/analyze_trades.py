#!/usr/bin/env python3
"""Read the EA's per-trade dataset and say what it implies.

Input: MQL4/Files/GoldScalperTrades_<symbol>_<account>.csv, written by
GoldScalperM1M5 v8+ (one row per completed trade, carrying the maximum
favourable/adverse excursion and the engine readings at entry).

The first question it answers is the decisive one: were the losers
wrong calls, or right calls stopped out by noise? If most losers first
travelled a long way in your favour, the entries work and the exit is
mispriced. If they went straight against you, the entries are the
problem and no exit tuning will save them.

Usage:
  python3 analyze_trades.py GoldScalperTrades_GOLD_12345.csv
  python3 analyze_trades.py trades.csv --bucket er --bins 5
"""

import argparse
import csv
import statistics
import sys

NUMERIC = ("lots", "entry_price", "exit_price", "profit", "hold_seconds",
           "hour", "mfe", "mae", "er", "cusum_up", "cusum_dn", "m1_strength",
           "coherence", "maturity_m5atr", "atr_m1", "atr_m5", "expansion",
           "spread_at_entry", "noise", "drift", "impulse", "exhaustion", "shock")


def load(path):
    rows = []
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            try:
                for k in NUMERIC:
                    if k in row and row[k] not in (None, ""):
                        row[k] = float(row[k])
                rows.append(row)
            except ValueError:
                continue          # skip malformed / partial lines
    return rows


def pct(n, d):
    return 0.0 if d == 0 else 100.0 * n / d


def summarize(rows):
    wins = [r for r in rows if r["profit"] > 0]
    losses = [r for r in rows if r["profit"] <= 0]
    gross_win = sum(r["profit"] for r in wins)
    gross_loss = -sum(r["profit"] for r in losses)
    print(f"trades              {len(rows)}")
    print(f"wins / losses       {len(wins)} / {len(losses)}  "
          f"({pct(len(wins), len(rows)):.1f}% win rate)")
    print(f"net profit          {sum(r['profit'] for r in rows):+.2f}")
    if wins:
        print(f"average win         {gross_win / len(wins):+.2f}")
    if losses:
        print(f"average loss        {-gross_loss / len(losses):+.2f}")
    if gross_loss > 0:
        print(f"profit factor       {gross_win / gross_loss:.2f}")
    print(f"expectancy / trade  {sum(r['profit'] for r in rows) / max(len(rows), 1):+.2f}")
    if rows:
        holds = sorted(r["hold_seconds"] for r in rows)
        print(f"median hold         {holds[len(holds) // 2]:.0f}s")
    return wins, losses


def excursion_verdict(losses):
    """The core diagnostic: how far did the losers travel our way first?"""
    if not losses:
        print("\nno losing trades to diagnose")
        return
    mfes = sorted(r["mfe"] for r in losses)
    median = mfes[len(mfes) // 2]
    print("\n--- were the losers wrong, or just stopped out? ---")
    print(f"losers                     {len(losses)}")
    print(f"median MFE of a loser      {median:+.2f}")
    print(f"best MFE of a loser        {mfes[-1]:+.2f}")
    for threshold in (0.5, 1.0, 2.0, 3.0, 5.0):
        n = sum(1 for m in mfes if m >= threshold)
        print(f"  reached +{threshold:<4}        {n:>4}  ({pct(n, len(losses)):.0f}% of losers)")

    never = sum(1 for m in mfes if m < 0.2)
    share = pct(never, len(losses))
    print()
    if share >= 60:
        print(f"VERDICT: {share:.0f}% of losers never went 0.20 in your favour.")
        print("The entries are the problem, not the stop. Tightening or")
        print("widening the exit will not fix a directional call that is")
        print("wrong from the first tick - work on the gate stack.")
    elif median >= 1.0:
        print(f"VERDICT: the median loser first travelled {median:+.2f} your way.")
        print("These were not wrong calls - they were right calls given back.")
        print("The stop and the profit lock are mispriced relative to the")
        print("noise; work on exits before touching the entry gates.")
    else:
        print(f"VERDICT: mixed. Median loser MFE {median:+.2f}, and {share:.0f}%")
        print("never moved your way at all. Neither entries nor exits")
        print("dominate - bucket by a feature below to find the split.")


def adverse_verdict(wins):
    if not wins:
        return
    maes = sorted(r["mae"] for r in wins)
    print("\n--- how much heat did the winners take? ---")
    print(f"median MAE of a winner     {maes[len(maes) // 2]:+.2f}")
    print(f"worst MAE of a winner      {maes[0]:+.2f}")
    print("A stop tighter than the worst figure above would have cut")
    print("this winner before it paid.")


def bucket(rows, field, bins):
    values = [r[field] for r in rows if field in r]
    if not values:
        print(f"\nno data for field {field!r}")
        return
    lo, hi = min(values), max(values)
    if hi <= lo:
        print(f"\n{field}: every trade has the same value ({lo:.3f})")
        return
    width = (hi - lo) / bins
    print(f"\n--- outcome by {field} ---")
    print(f"{'range':>22}  {'n':>4}  {'win%':>6}  {'net':>9}  {'avg':>8}")
    for i in range(bins):
        a = lo + i * width
        b = hi if i == bins - 1 else a + width
        group = [r for r in rows if a <= r[field] <= b] if i == bins - 1 \
            else [r for r in rows if a <= r[field] < b]
        if not group:
            continue
        w = sum(1 for r in group if r["profit"] > 0)
        net = sum(r["profit"] for r in group)
        print(f"{a:>10.3f}..{b:<10.3f} {len(group):>4}  "
              f"{pct(w, len(group)):>5.0f}%  {net:>+9.2f}  {net / len(group):>+8.2f}")


def by_category(rows, field):
    keys = sorted({str(r.get(field, "")) for r in rows})
    if len(keys) <= 1:
        return
    print(f"\n--- outcome by {field} ---")
    print(f"{field:>12}  {'n':>4}  {'win%':>6}  {'net':>9}  {'avg':>8}")
    for k in keys:
        group = [r for r in rows if str(r.get(field, "")) == k]
        w = sum(1 for r in group if r["profit"] > 0)
        net = sum(r["profit"] for r in group)
        print(f"{k:>12}  {len(group):>4}  {pct(w, len(group)):>5.0f}%  "
              f"{net:>+9.2f}  {net / len(group):>+8.2f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", help="GoldScalperTrades_*.csv from MQL4/Files")
    ap.add_argument("--bucket", default=None,
                    help="numeric field to bucket outcomes by (er, maturity_m5atr, "
                         "atr_m1, cusum_up, spread_at_entry, hour, ...)")
    ap.add_argument("--bins", type=int, default=5)
    args = ap.parse_args()

    rows = load(args.csv)
    if not rows:
        sys.exit("no usable rows - has the EA closed any trades yet?")

    print(f"=== {args.csv} ===")
    wins, losses = summarize(rows)
    excursion_verdict(losses)
    adverse_verdict(wins)
    by_category(rows, "dir")
    by_category(rows, "reason")
    if args.bucket:
        bucket(rows, args.bucket, args.bins)
    else:
        for field in ("er", "maturity_m5atr", "atr_m1"):
            if field in rows[0]:
                bucket(rows, field, args.bins)
    print("\nNote: buckets on a few dozen trades are suggestive, not proof.")
    print("Treat a split as real only once it survives a few hundred trades")
    print("or reproduces in the tick backtest.")


if __name__ == "__main__":
    main()
