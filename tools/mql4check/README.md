# MQL4 check harness

Optional developer tooling. It lets the EA be checked on a machine without
MetaTrader by compiling the `.mq4` source as C++ against a stand-in for the
MQL4 API, and then running the EA's real engine against a simulated terminal
with a controllable clock, order book and history.

It is a static/behavioural check, **not** a substitute for compiling in
MetaEditor or running in the Strategy Tester before going live.

## Usage

Syntax and type check only:

```
cd tools/mql4check
python3 check.py ../../XVISION_Gold_NewsStraddle_EA.mq4 gen.cpp
```

Build and run the behavioural tests:

```
cd tools/mql4check
python3 check.py ../../XVISION_Gold_NewsStraddle_EA.mq4 gen.cpp testmain.inc && ./eatest
```

Exit status is non-zero if anything fails.

## What is here

| File | Purpose |
| --- | --- |
| `check.py` | Rewrites the MQL4-only syntax (`input`, `#property`, `C'r,g,b'`, `D'...'`, `string x[]`) into C++, generates the forward declarations MQL4 does not need, then invokes `g++` |
| `mql4shim.h` | Declarations for the MQL4 built-ins the EA uses |
| `mql4shim.cpp` | A simulated terminal: clock, order book, history, global variables, chart objects |
| `testmain.inc` | The behavioural tests, appended into the generated translation unit so they can see the EA's own globals |

## Coverage

The tests drive the EA's own `OnInit` / `RunEngine` / panel actions and cover
the multi-event scheduling introduced in V10: two events in one day, an open
trade surviving into the next event's window, daily rollover, weekend skip,
per-event cancel, cancelled state surviving a reload, stale-state clearing,
history attribution across day boundaries and schedule reorders, and schedule
validation.
