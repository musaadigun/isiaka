#!/usr/bin/env python3
"""Download free XAUUSD tick data from Dukascopy for the backtester.

Fetches hourly .bi5 tick archives, decodes them, and writes one CSV per
day in the format the engine consumes: time_ms,bid,ask (UTC).

Dukascopy prices are integers scaled by a per-symbol factor
(XAUUSD: 1000, i.e. a point of 0.001). Months in the URL are 0-based.

Usage:
  python3 download_dukascopy.py --start 2025-01-01 --end 2025-06-30 --out data/

Weekends return empty archives; those hours are skipped silently.
"""

import argparse
import datetime as dt
import lzma
import os
import struct
import sys
import time
import urllib.error
import urllib.request

BASE = "https://datafeed.dukascopy.com/datafeed/{sym}/{y}/{m:02d}/{d:02d}/{h:02d}h_ticks.bi5"
RECORD = struct.Struct(">IIIff")   # ms offset, ask, bid, ask vol, bid vol


def fetch_hour(symbol, day, hour, factor, retries=3):
    url = BASE.format(sym=symbol, y=day.year, m=day.month - 1, d=day.day, h=hour)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
            break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return []
            if attempt == retries - 1:
                raise
            time.sleep(2 ** attempt)
        except (urllib.error.URLError, TimeoutError):
            if attempt == retries - 1:
                raise
            time.sleep(2 ** attempt)
    if not raw:
        return []
    try:
        data = lzma.decompress(raw)
    except lzma.LZMAError:
        return []
    base_ms = int(dt.datetime(day.year, day.month, day.day, hour,
                              tzinfo=dt.timezone.utc).timestamp() * 1000)
    ticks = []
    for ms, ask, bid, _av, _bv in RECORD.iter_unpack(data[: len(data) - len(data) % RECORD.size]):
        ticks.append((base_ms + ms, bid / factor, ask / factor))
    return ticks


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--symbol", default="XAUUSD")
    ap.add_argument("--start", required=True, help="YYYY-MM-DD (UTC)")
    ap.add_argument("--end", required=True, help="YYYY-MM-DD inclusive (UTC)")
    ap.add_argument("--out", default="data")
    ap.add_argument("--factor", type=float, default=1000.0,
                    help="price scale divisor (XAUUSD=1000, EURUSD=100000)")
    args = ap.parse_args()

    start = dt.date.fromisoformat(args.start)
    end = dt.date.fromisoformat(args.end)
    if end < start:
        sys.exit("end before start")
    os.makedirs(args.out, exist_ok=True)

    day = start
    total = 0
    while day <= end:
        if day.weekday() == 5:          # Saturday: market closed all day
            day += dt.timedelta(days=1)
            continue
        path = os.path.join(args.out, f"{args.symbol}_{day:%Y%m%d}.csv")
        if os.path.exists(path):
            print(f"{day} exists, skipping")
            day += dt.timedelta(days=1)
            continue
        rows = []
        for hour in range(24):
            try:
                rows.extend(fetch_hour(args.symbol, day, hour, args.factor))
            except Exception as e:      # keep the run alive; report and move on
                print(f"  {day} {hour:02d}h failed: {e}", file=sys.stderr)
        if rows:
            rows.sort()
            with open(path, "w") as fh:
                fh.write("time_ms,bid,ask\n")
                for t, bid, ask in rows:
                    fh.write(f"{t},{bid:.3f},{ask:.3f}\n")
            total += len(rows)
            print(f"{day}: {len(rows):,} ticks")
        else:
            print(f"{day}: no data")
        day += dt.timedelta(days=1)
    print(f"done: {total:,} ticks in {args.out}/")


if __name__ == "__main__":
    main()
