# Backtest harness

Independent Python re-implementation of the EA, used to produce `BACKTEST.md`.
This is **not** MetaTrader's Strategy Tester.

| File | Role |
|---|---|
| `engine.py` | Port of `GVCalculate` (EA lines 17–385): features, four logistic heads, qualification |
| `sim.py`    | Execution and management layer: entry filters, SL/TP, trailing, break-even, partials, time stop |
| `final.py`  | Baseline run, cost sweep, parameter sensitivity, monthly breakdown |
| `discrim.py`| Quartile analysis, random-direction control, benchmark, risk framing |
| `charts.py` | Emits the data behind `backtest-report.html` |
| `qa.py`     | Data-quality and cross-feed consistency checks |

Run order: `qa.py` → `final.py` → `discrim.py` → `charts.py`.
Requires `pandas`, `numpy`. Input CSVs are the five supplied MT4 exports.
