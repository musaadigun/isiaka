# Code Audit — XVISION_EURUSD_Adaptive_EA_v1.mq4

| | |
|---|---|
| **File** | `XVISION_EURUSD_Adaptive_EA_v1.mq4` (579 lines, ASCII) |
| **SHA-256** | `68140a3fdfecac10b019c45a2c7a967635e57e51e12d43b3e72add912db53c60` |
| **Platform** | MetaTrader 4 / MQL4, `#property strict` |
| **Archive note** | The submitted zip contains a nested zip holding a byte-identical copy of the same file. No test harness, backtest report, or data accompanies the code. |
| **Scope** | Static review. The code was not compiled in MetaEditor and was not run in the Strategy Tester. |

## Verdict

The architecture is sound and the design intent is unusually disciplined for a retail EA — two engines, an explicit stand-aside regime gate, a written journal, and `SignalOnly` defaulting to `true`. The problems are not in the concept; they are in the execution layer and in the measurement layer.

Two conclusions matter most:

1. **Do not set `SignalOnly = false` in its current state.** Six defects can cause wrong trades, silently rejected orders, or corrupted state — several of them triggered by something as ordinary as changing an input or restarting the terminal.
2. **The adaptive layer cannot do the job it claims.** At roughly 10 signals per engine per year, with `MinTradesBeforeAdapt = 8` and `EwmaAlpha = 0.10` (a ~20-trade memory), the self-monitor needs years of live data to react. It is padded out by shadow trades, but shadow trades are measured on a different basis than live ones and are fed into the same average — so the number the EA acts on is a blend of two incompatible things.

Findings: **6 blocking**, **8 measurement integrity**, **10 robustness/hygiene**.

---

## Blocking defects

### B1 — A new bar is detected on attach, so the EA acts on a stale signal every time it loads
`g_lastH4` is initialised to `0` (line 77). On the first tick after loading, `iTime(NULL,TF,0)` is never `0`, so lines 128–133 treat the *current, partially formed* H4 bar as new and run `OnNewH4Bar()` immediately.

Signals are computed from bar 1, so on attach the EA evaluates whatever bar closed most recently — possibly hours ago — and can enter at a price far from where the signal was generated. This fires on every attach, recompile, input change, terminal restart, and reconnect. Chart-swap or a parameter tweak mid-session is enough to open a position on a setup that is already three hours old.

**Fix:** set `g_lastH4 = iTime(NULL,TF,0);` in `OnInit()` so the first genuine bar close is the first evaluation.

### B2 — The divergence "freshness" flag is destroyed by `MathMax`, discarding valid signals
`ScanDivergence` encodes freshness as `1 = confirmed on bar 1`, `2 = older but still within the window` (lines 220 and 233):

```mql4
bear = (i==1) ? 1 : MathMax(bear,2);
```

The loop runs `i = 1 … DivConfluenceBars` and does not stop once a divergence is found. If a divergence is confirmed at `i = 1` (`bear = 1`) and a second, older one exists at, say, `i = 4`, the second iteration computes `MathMax(1, 2) = 2` and overwrites the fresh flag with the stale one. Freshness is encoded on a scale where the better value is numerically *lower*, so `MathMax` always picks the worse one.

`DivergenceSignal` then requires `freshB = (mb==1 || sb==1)` (lines 193–196). With both flags clobbered to `2`, the function returns `0` and a genuine confluence signal is silently dropped. This makes the live engine trade a strictly smaller set than whatever was backtested, in a way that is invisible from the journal.

**Fix:** track freshness in a separate variable, or reverse the encoding, or `break` out of the outer loop on the first match at `i == 1`.

### B3 — Orders are submitted with no broker-level validation
`OpenLive` (lines 315–333) calls `OrderSend` once, with SL and TP attached, and gives up on failure. Missing entirely:

- **`MODE_STOPLEVEL` / freeze-level check.** Nothing verifies the stop and target clear the broker's minimum distance → error 130.
- **Stop/target side validation.** `BuildLevels` derives the stop from bar 1's extreme while `entry` is the *current* Ask/Bid (line 297). If price has already moved through that level during bar 0, a BUY can be submitted with the stop above entry. `risk = MathAbs(entry - stop)` (line 273) stays positive, so nothing catches it, and the order is either rejected or is nonsense if accepted.
- **`RefreshRates()`.** `Ask`/`Bid` are read in `BuildLevels`, then used again at line 321 after divergence scanning, ATR calls and lot maths → errors 129/138 on a moving market.
- **ECN handling.** Brokers that reject SL/TP on the opening order require `OrderSend` then `OrderModify`. As written, this EA cannot open a position at all on those accounts.
- **Retry / error triage.** No handling of 146 (trade context busy), 136 (off quotes), 138 (requote) — all routine on MT4.
- **`IsTradeAllowed()`, `IsConnected()`, free-margin check.** None present (verified by grep).

### B4 — A rejected order vanishes from the adaptive record entirely
`HandleSignal` routes to either `OpenLive` or `OpenShadow` (lines 291–292) — never both. But `OpenLive` can fail after that decision: lots resolve to zero (line 319) or `OrderSend` returns negative (line 326). In both cases it prints a message and returns, and no shadow trade is opened.

The signal is then absent from live results *and* from shadow results. Because failures correlate with market conditions — wide spreads, fast moves, low balance — the EWMA ends up measuring a biased subset of each engine's signals, and the bias runs in the direction of removing the hardest trades. Given that the EWMA governs position sizing and stand-down, this quietly corrupts the control loop.

**Fix:** fall through to `OpenShadow` whenever the live path does not result in a confirmed ticket.

### B5 — Lost global variables cause a fabricated `R = 0.0` to be recorded as a real result
`RecoverLiveTicket` (lines 402–415) restores `g_liveRisk` and `g_liveEntry` from terminal global variables. MT4 global variables are deleted after four weeks without access and are lost if the terminal does not shut down cleanly. If they are gone, `GlobalVariableGet` returns `0`, and `ManageLive` computes:

```mql4
double R = (g_liveRisk>0) ? (exit - g_liveEntry)*d / g_liveRisk : 0.0;   // line 389
```

`R = 0.0` is then passed to `RecordResult` as if it were a genuine breakeven outcome: it moves the EWMA toward zero, increments the trade count, and is written to the journal. A real loss can be recorded as a scratch.

**Fix:** persist trade context to a file next to the journal, and when it cannot be recovered, mark the result as unknown and exclude it from the EWMA rather than scoring it zero.

### B6 — The Keltner time stop resets on restart
`g_liveBarsHeld` is incremented only in `OnNewH4Bar` (line 144) and is never written to a global variable. `RecoverLiveTicket` restores ticket, engine, risk and entry — but not the bar count, so it stays at its default `0`.

After any restart, a Keltner position that has already run 20 of its 24 bars starts counting again from zero, and the 24-bar time stop — which the header describes as load-bearing for that engine — can extend to 48 bars or more. Repeated restarts extend it indefinitely.

---

## Measurement integrity

These do not crash anything. They determine whether the EWMA the EA acts on means what the code assumes it means.

### M1 — Live and shadow results are not comparable, but share one average
Shadow trades pay no spread on exit, no commission and no swap, and are filled at exact theoretical prices. Live results (line 389) are computed from raw price and also exclude commission and swap. The two are averaged together into a single EWMA per engine. An engine can be measured as healthy on shadow fills while losing money live, and the stand-down logic will never see it.

At minimum, track live and shadow expectancy separately and let stand-down consider both.

### M2 — Live and shadow use different exit rules for the same engine
Shadow divergence trades are force-closed at 120 bars with a mark-to-market R (lines 359–360). Live divergence trades have **no** time stop — only SL and TP. The same engine is therefore measured under two different exit policies, and the results are pooled. The Keltner engine is consistent (24 bars in both paths); the divergence engine is not.

### M3 — One live slot shared by both engines means the live sample is not the backtested sample
`goLive` requires `g_liveTicket < 0` (line 280), so the EA holds at most one position across *both* engines. Any signal arriving while another is open is demoted to shadow. With H4 holds of up to 24 bars (Keltner) and open-ended holds (divergence), collisions are likely. The backtest that produced the quoted +0.40R and +0.27R figures almost certainly took every signal, so the live series is a different, capacity-constrained strategy.

### M4 — Shadow state is wiped on every restart, and stood-down engines depend on it
`OnInit` sets `s_active[e] = false` for both engines (line 100). Any in-flight shadow trade is discarded without being recorded. Results therefore survive only if no restart occurs during the trade — which biases the sample toward short-lived trades.

This compounds with the stand-down design: an engine below `StandDownBelow` places no live orders and can only recover through shadow results (lines 461–468). Restarts repeatedly discard exactly the evidence that engine needs to come back, and with ~10 signals a year it may never accumulate enough to re-enable.

### M5 — No cooldown on the divergence engine, so one setup can generate a cluster of signals
The Keltner engine has a de-duplication guard — `wasInside` (line 258) requires the prior bar to have been inside the bands, giving one signal per excursion. The divergence engine has no equivalent. A divergence stays inside the `DivConfluenceBars = 8` window for eight bars, so the same underlying setup can fire on several consecutive bars as freshness rotates between the two oscillators.

Only one can go live; the rest become shadows. Highly correlated near-duplicates then dominate the EWMA sample, and since they share an outcome, the "rolling expectancy over N results" is far less independent than the count implies.

### M6 — Adaptation latency exceeds any useful horizon
`MinTradesBeforeAdapt = 8` gates adaptation, and `EwmaAlpha = 0.10` gives roughly a 20-trade memory. At the header's own estimate of ~10 trades per engine per year, the self-monitor takes about a year to switch on and about two years to respond meaningfully — using live counts alone. Shadow trades inflate the count, but per M1 and M5 they are not the same measurement and are not independent. The headline "self-monitoring" feature is effectively dormant over any horizon on which a trader would want it.

### M7 — The spread gate fires precisely when spreads are structurally widest
`goLive` requires `SpreadPips() <= MaxSpreadPips` (line 281), and the check runs on the first tick of a new H4 bar. On most brokers, H4 bars open at 01:00 / 05:00 / … / 21:00 server time, and one of those opens sits on or near the rollover window where EURUSD spreads routinely blow past 2.0 pips.

The result is a systematic, time-of-day-correlated demotion of live signals to shadow, plus worse-than-backtest fills on the ones that do pass. Neither is visible in the journal, which records no spread.

### M8 — The journal cannot support the reconciliation it exists for
`RecordResult` writes `RegimeName(Regime())` — the regime **at close time**, not at entry (line 447). For a trade held 24 bars, that field describes a different market than the one that produced the signal, which makes the column actively misleading for exactly the "which regime works" analysis it invites.

Also absent: lot size, ticket number, entry timestamp, spread at entry, commission, swap, and MAE/MFE. The header states the journal exists "so live results can be compared to the backtest" — as written it cannot support that comparison.

---

## Robustness and hygiene

### H1 — `EngineState()` mutates state and sends push notifications, and is called from `Panel()` on every tick
`EngineState` writes the `DOWN_` global variable and calls `Say()` (lines 461–475), which fires `Alert()` and `SendNotification()`. `Panel()` calls it for both engines on every tick (line 566). Transitions are latched by the `DOWN_` flag, so it behaves under default inputs — but a query function that alerts and writes state is a trap for any future edit.

### H2 — No validation that `ReEnableAbove > StandDownBelow`; inverting them creates an unbounded alert loop
Defaults (`-0.15` and `-0.25`) leave a healthy gap. Set `ReEnableAbove` below `StandDownBelow` and an EWMA between them satisfies both: `EngineState` clears `DOWN`, alerts, then on the very next call re-triggers stand-down and alerts again — **once per tick**, each one an `Alert()` plus a `SendNotification()`. Nothing in `OnInit` validates input relationships.

### H3 — Alerts and push notifications are unguarded in the Strategy Tester
`Say()` (lines 546–551) always calls `Alert()` and `SendNotification()`. There is no `IsTesting()` / `IsOptimization()` guard, so the first backtest — the obvious way to validate this EA — spams alerts and hits MT4's notification limits (2/second, 10/minute). Multi-line `Announce` messages also exceed the 255-character notification cap and get truncated.

### H4 — `Announce`'s per-bar guard suppresses the second engine's alert while still trading it
`Announce` returns early if it has already fired on the current bar (lines 484–485). The guard is global, not per engine. If both engines signal on the same H4 bar, the second is announced nowhere — but `HandleSignal` still opens the trade. A position appears with no corresponding alert.

### H5 — `NormalizeDouble(lots, 2)` breaks brokers with a 0.001 lot step
`LotsForRisk` correctly floors to `MODE_LOTSTEP` (line 511), then hardcodes two decimals at line 513. On cent and ECN accounts with a 0.001 step, that silently re-rounds off the step grid. Normalise to the digit count implied by `MODE_LOTSTEP` instead.

### H6 — No minimum stop distance, so a small `risk` can produce an oversized position
`LotsForRisk` sizes purely from `money / perLot` with no cap. There is no floor on `slDist` and no free-margin check. In the Keltner path the stop is at least ~1 ATR beyond the bar extreme, which usually protects you — but a momentary collapse in ATR or an unusually tight swing on the divergence path removes that protection, and nothing else stands in the way.

### H7 — `ManageLive` discards the result whenever `OrderSelect` fails
Line 393: `else ClearLive();`. If `OrderSelect` fails for any transient reason — history not yet loaded after reconnect, for instance — the trade is dropped without ever calling `RecordResult`. The result is lost from both the EWMA and the journal, with no log line.

### H8 — Terminal global variables are the wrong store for adaptive state
MT4 global variables are terminal-wide, not per account. Running this EA on demo and live in the same terminal makes both write the same `EWMA_`/`CNT_`/`DOWN_` keys for EURUSD, so demo results drive live sizing. They also expire after four weeks unused and are only flushed to disk at clean shutdown. Since these variables *are* the adaptive layer's entire memory, they deserve file-backed storage. Worth verifying separately how your build handles global variables under the Strategy Tester before running a backtest with live state present.

### H9 — The EURUSD check warns but does not restrict
`OnInit` alerts if the symbol is not EURUSD (lines 95–97) and then proceeds to trade normally. Given that the file's own mandate is "engines validated on EURUSD only", a non-matching symbol should force `SignalOnly` behaviour rather than emit a dialog the user clicks past.

### H10 — Minor
- `bear = MathMax(bear,2)` assigns a `double` to an `int`; under `#property strict` this is a type-conversion warning at lines 220 and 233.
- `Regime()` and `EfficiencyRatio()` (a 24-iteration loop, ~48 `iClose` calls) run on every tick via `Panel()`, plus every 5s via the timer. Cache per bar.
- Shadow stop/target checks use bar high/low, which are **bid** prices. For a short, the real stop triggers on Ask, so shadow shorts are stopped out later than reality — a small optimistic bias on top of M1.
- `RecordResult` calls `EngineState()` while building its own alert string (line 435), so a stand-down notification can nest inside a trade-closed notification and arrive first.
- The journal is opened without `FILE_SHARE_READ`; if the CSV is open in Excel, `FileOpen` fails and the row is dropped with no log line.
- Header performance claims (+0.40R, PF ~1.5, split-half figures) cannot be verified from the archive — no data, harness, or report was included.

---

## What is well built

Worth stating plainly, because it is the reason the rest is worth fixing:

- `SignalOnly = true` as the default is the right call and is honoured correctly throughout the routing logic.
- The history guard `iBars < AtrPeriod*11 + 70` (line 141) correctly bounds every lookback in the file — divergence scanning reaches bar 72, the long ATR needs 242, and the guard clears both, and it scales with `AtrPeriod`.
- No indicator or price call reads bar 0 in any signal path; `ScanDivergence`'s pivot confirmation bottoms out at bar 1 exactly. There is no repainting.
- Shadow trade timing is genuinely correct: entry lands at the open of bar 0, and evaluation begins when that bar becomes bar 1, so the entry bar's full range is used with no lookahead.
- Stop and target sign conventions in `BuildLevels` are correct for both directions on both engines.
- Stop-before-target resolution in `UpdateShadows` (line 355) is the conservative choice.
- The regime gate genuinely gates: panic volatility returns before any engine is consulted (line 147).

---

## Suggested order of work

1. **B1** — one line, removes the largest source of unintended entries.
2. **B3** — order validation, `RefreshRates`, stop-level check, error triage, ECN fallback. This is the difference between an EA that trades and one that logs error 130.
3. **B5 + B6 + H8** — move adaptive state and live-trade context to a file. Fixes fabricated zero-R results and the resetting time stop together.
4. **B2** — restores signals the divergence engine is currently discarding.
5. **B4** — makes the adaptive sample complete.
6. **M1 + M2** — separate live and shadow expectancy, and give the live divergence engine the same time stop its shadow uses. Until this is done, the EWMA is not a trustworthy control input.
7. **M8** — record entry regime, lots, spread and costs, or accept that backtest reconciliation is not possible.
8. **M6** — decide what the adaptive layer is really for. At ~10 trades/engine/year it cannot be a fast safety mechanism; either accept it as a slow structural check and add a separate hard drawdown circuit-breaker, or drive it from a faster signal.

A hard equity/drawdown stop is absent entirely and is not on the above list because it is new work rather than a fix — but it is the one control that would actually protect the account on the timescale the EWMA cannot.
