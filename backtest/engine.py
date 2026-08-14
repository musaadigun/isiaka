#!/usr/bin/env python3
"""Tick-replay backtester for GoldScalperM1M5 (mirrors EA Version 8).

Mirrors the EA's decision logic - same velocity composites, efficiency
ratio, CUSUM burst detector, five-mode regime posterior - and the same
exit set: the user's stop loss, take profit, profit lock and trailing
stop, and nothing else. Replays it over real bid/ask ticks, so every
result is net of spread. MT4's strategy tester interpolates M1 ticks
and will overstate a scalper's edge; this harness exists so thresholds
are set from evidence.

Input tick CSVs: time_ms,bid,ask   (UTC, as produced by
download_dukascopy.py). Timestamps here are UTC; the EA runs on broker
time, which matters only if you switch the optional session filter on.

Usage:
  python3 engine.py --data 'data/XAUUSD_*.csv' --balance 10000 \
      --lots 0.01 --commission 7.0 --trades-out trades.csv
"""

import argparse
import csv
import glob
import json
import math
import sys
from dataclasses import dataclass, field, asdict


# --------------------------------------------------------------------------
# configuration (defaults mirror the EA inputs)
# --------------------------------------------------------------------------
@dataclass
class Config:
    # sizing / stop
    risk_percent: float = 0.5            # used only when fixed_lots is 0
    hard_stop_usd: float = 2.50          # EA: StopLoss_PriceUSD
    # Exit engine. Mirrors EA v8: the ONLY exits are the user's SL, TP,
    # profit lock and trailing stop. The scratch mechanisms below were
    # removed from the EA and default to off; they remain here so the
    # effect of re-adding one can be measured before it is written back
    # into the EA.
    scratch_adverse_usd: float = 0.0     # EA v3+: removed
    launch_window_seconds: int = 0       # EA v3+: removed
    launch_progress_usd: float = 0.30
    take_profit_usd: float = 0.0
    breakeven_at_usd: float = 0.60       # EA: LockTrigger_PriceUSD
    breakeven_lock_usd: float = 0.10     # EA: LockedProfit_PriceUSD
    use_partial_bank: bool = False
    partial_at_usd: float = 0.70
    partial_percent: float = 50.0
    trail_start_usd: float = 0.90        # EA: TrailingStart_PriceUSD
    trailing_distance_usd: float = 0.60  # EA: TrailingDistance_PriceUSD
    max_hold_minutes: int = 0            # EA v2+: removed
    exit_on_opposite: bool = False        # EA v3+: removed
    fixed_lots: float = 0.01             # EA: LotSize (0 = risk-based sizing instead)
    # entry rails
    max_spread_usd: float = 0.35         # EA: MaxSpread_PriceUSD
    max_chase_usd: float = 0.0           # EA v3+: removed
    cooldown_seconds: int = 120          # EA: frozen constant
    max_trades_per_day: int = 15         # EA: MaxTradesPerDay
    max_daily_loss_percent: float = 0.0  # EA v3+: removed
    max_consecutive_losses: int = 3      # EA: MaxConsecutiveLosses
    loss_pause_minutes: int = 90         # EA: LossPauseMinutes
    sessions_utc: tuple = ((7 * 60, 10 * 60), (12 * 60 + 30, 18 * 60))
    use_session_filter: bool = False     # EA v3+: removed
    friday_cutoff_hour_utc: int = 0      # EA v3+: removed (0 = off)
    # momentum module - mirrors EA v8 defaults (permissive; 0 = gate off)
    use_momentum: bool = True
    cusum_allowance: float = 0.18
    cusum_decay: float = 0.94
    cusum_trigger: float = 2.0
    cusum_fresh_bars: int = 5
    min_m1_strength: float = 0.05
    min_m1_coherence: float = 0.50
    big_bar_max_atr: float = 0.0
    max_maturity_m5_atr: float = 0.0
    require_m5_alignment: bool = False
    # fade module (off by default: gold fades failed H4 stability tests)
    use_fade: bool = False
    fade_ma_period: int = 50
    fade_atr_period: int = 24
    fade_band_atr: float = 2.5
    fade_max_er: float = 0.15
    fade_max_expansion: float = 2.0
    # regime router
    er_period: int = 20
    momentum_min_er: float = 0.10
    min_impulse_drift: float = 0.0
    min_fade_noise: float = 0.40
    max_shock_exhaust: float = 0.0   # 0 = off, matching the EA
    # cost model
    commission_per_lot: float = 7.0        # round trip, account currency
    slippage_usd: float = 0.03             # applied to every fill
    spread_add_usd: float = 0.0            # widen recorded spreads (stress test)
    contract_size: float = 100.0           # XAUUSD: 1 lot = 100 oz
    balance: float = 10000.0
    min_lot: float = 0.01
    lot_step: float = 0.01


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


# --------------------------------------------------------------------------
# incremental bars
# --------------------------------------------------------------------------
class BarSeries:
    """Closed OHLC bars built from bid ticks; index -1 = last closed."""

    def __init__(self, period_seconds, keep=400):
        self.period = period_seconds
        self.keep = keep
        self.bars = []          # (open_time_s, o, h, l, c)
        self._cur = None

    def add(self, t_s, bid):
        slot = int(t_s // self.period) * self.period
        closed = False
        if self._cur is None:
            self._cur = [slot, bid, bid, bid, bid]
        elif slot != self._cur[0]:
            self.bars.append(tuple(self._cur))
            if len(self.bars) > self.keep:
                del self.bars[: len(self.bars) - self.keep]
            self._cur = [slot, bid, bid, bid, bid]
            closed = True
        else:
            c = self._cur
            c[2] = max(c[2], bid)
            c[3] = min(c[3], bid)
            c[4] = bid
        return closed

    def closed(self, shift):
        """shift=1 is the last closed bar (MQL convention)."""
        idx = len(self.bars) - shift
        return self.bars[idx] if idx >= 0 else None

    def count(self):
        return len(self.bars)


def atr(series, period, shift=1):
    n = series.count()
    if n < shift + period + 1:
        return 0.0
    total = 0.0
    for i in range(period):
        b = series.closed(shift + i)
        prev = series.closed(shift + i + 1)
        tr = max(b[2] - b[3], abs(b[2] - prev[4]), abs(b[3] - prev[4]))
        total += tr
    return total / period


def composite(series, windows, weights, atr_val, shift=1):
    if atr_val <= 0.0:
        return 0.0
    c = 0.0
    for w, wt in zip(windows, weights):
        newest = series.closed(shift)
        oldest = series.closed(shift + w - 1)
        if newest is None or oldest is None:
            return 0.0
        c += wt * (newest[4] - oldest[1]) / (atr_val * math.sqrt(w))
    return c


def coherence(series, windows, direction, shift=1):
    if direction == 0:
        return 0.0
    aligned = 0
    for w in windows:
        newest = series.closed(shift)
        oldest = series.closed(shift + w - 1)
        if newest is None or oldest is None:
            return 0.0
        if direction * (newest[4] - oldest[1]) > 0.0:
            aligned += 1
    return aligned / len(windows)


def efficiency_ratio(series, period, shift=1):
    a = series.closed(shift)
    b = series.closed(shift + period)
    if a is None or b is None:
        return 0.0
    net = a[4] - b[4]
    path = 0.0
    for k in range(period):
        x = series.closed(shift + k)
        y = series.closed(shift + k + 1)
        path += abs(x[4] - y[4])
    return net / path if path > 0.0 else 0.0


def return_sigma(series, shift=1, bars=48, alpha=0.10):
    variance, seeded = 0.0, False
    for s in range(shift + bars, shift - 1, -1):
        c = series.closed(s)
        p = series.closed(s + 1)
        if c is None or p is None:
            continue
        r = c[4] - p[4]
        if not seeded:
            variance, seeded = r * r, True
        else:
            variance = (1.0 - alpha) * variance + alpha * r * r
    return max(math.sqrt(max(variance, 0.0)), 1e-6)


def sma_close(series, period, shift=1):
    total = 0.0
    for i in range(period):
        b = series.closed(shift + i)
        if b is None:
            return 0.0
        total += b[4]
    return total / period


def ema_close(series, period, shift=1):
    span = period * 4
    start = shift + span
    b = series.closed(start)
    if b is None:
        start = series.count() - 1
        b = series.closed(start)
        if b is None or start <= shift:
            return 0.0
    value = b[4]
    k = 2.0 / (period + 1.0)
    for s in range(start - 1, shift - 1, -1):
        value = k * series.closed(s)[4] + (1.0 - k) * value
    return value


# --------------------------------------------------------------------------
# strategy state
# --------------------------------------------------------------------------
@dataclass
class Position:
    direction: int
    lots: float
    entry: float
    entry_time: float
    module: str
    hard_stop: float
    fade_target: float = 0.0
    max_fav: float = 0.0
    max_adv: float = 0.0
    launched: bool = False
    partial_done: bool = False
    stop: float = 0.0
    realized: float = 0.0        # banked partial PnL
    adverse_hits: int = 0        # fast-cut debounce (mirrors the EA)


@dataclass
class Trade:
    entry_time: float
    exit_time: float
    direction: int
    lots: float
    entry: float
    exit: float
    pnl: float
    reason: str
    module: str
    max_fav: float
    max_adv: float


class Backtester:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.m1 = BarSeries(60)
        self.m5 = BarSeries(300)
        self.balance = cfg.balance
        self.pos = None
        self.trades = []
        # regime state
        self.cusum_up = self.cusum_down = 0.0
        self.cross_up = self.cross_down = None
        self.modes = [0.2] * 5           # noise drift impulse exhaustion shock
        self.m1_comp = self.m1_comp_prev = 0.0
        self.m5_comp = self.er = 0.0
        self.expansion = 1.0
        self.atr_m1 = self.atr_m5 = 0.0
        self.fade_armed = True
        self.signal = 0
        self.signal_module = ""
        self.signal_ref = 0.0
        self.signal_fade_target = 0.0
        self.pending_entry = False
        # rails state
        self.last_entry_time = None
        self.day_key = None
        self.trades_today = 0
        self.closed_pnl_today = 0.0
        self.day_start_balance = cfg.balance
        self.consec_losses = 0
        self.last_loss_time = None
        self.blocked = {}

    # ---------------- regime ----------------
    def update_regime(self):
        cfg = self.cfg
        self.atr_m1 = atr(self.m1, 14)
        self.atr_m5 = atr(self.m5, 12)
        self.m1_comp_prev = self.m1_comp
        self.m1_comp = composite(self.m1, (1, 3, 5, 15),
                                 (0.35, 0.30, 0.20, 0.15), self.atr_m1)
        self.m5_comp = composite(self.m5, (1, 3, 6, 12),
                                 (0.30, 0.30, 0.25, 0.15), self.atr_m5)
        self.er = efficiency_ratio(self.m1, cfg.er_period)
        slow = atr(self.m1, 48)
        fast = atr(self.m1, 6)
        self.expansion = clamp(fast / slow, 0.25, 4.0) if slow > 0 else 1.0

        # CUSUM on standardized M1 returns
        c1, c2 = self.m1.closed(1), self.m1.closed(2)
        if c1 and c2:
            z = (c1[4] - c2[4]) / return_sigma(self.m1)
            prev_up, prev_dn = self.cusum_up, self.cusum_down
            self.cusum_up = clamp(max(0.0, cfg.cusum_decay * self.cusum_up
                                      + z - cfg.cusum_allowance), 0.0, 12.0)
            self.cusum_down = clamp(max(0.0, cfg.cusum_decay * self.cusum_down
                                        - z - cfg.cusum_allowance), 0.0, 12.0)
            if prev_up < cfg.cusum_trigger <= self.cusum_up:
                self.cross_up = c1[0]
            if prev_dn < cfg.cusum_trigger <= self.cusum_down:
                self.cross_down = c1[0]
            self.update_modes(z)

    def update_modes(self, last_z):
        speed = 0.40 * abs(self.m1_comp) + 0.60 * abs(self.m5_comp)
        accel = abs(self.m1_comp - self.m1_comp_prev)
        eff = abs(self.er)
        agree = ((1.0 if self.m1_comp * self.m5_comp > 0 else -1.0)
                 * min(abs(self.m1_comp), abs(self.m5_comp)))
        ll = [
            1.35 * (1.0 - eff) - 0.45 * speed - 0.25 * abs(self.expansion - 1.0),
            1.20 * eff + 0.45 * speed + 0.35 * max(agree, 0.0) - 0.35 * accel,
            0.90 * eff + 0.75 * speed + 0.70 * max(accel, 0.0)
            + 0.35 * max(self.expansion - 1.0, 0.0),
            0.65 * speed + 0.90 * max(-agree, 0.0) + 0.65 * (1.0 - eff)
            + 0.30 * accel,
            1.15 * max(self.expansion - 1.65, 0.0)
            + 0.55 * max(abs(last_z) - 2.0, 0.0),
        ]
        mx = max(ll)
        like = [math.exp(clamp(v - mx, -50.0, 50.0)) for v in ll]
        total = sum(like) or 1.0
        upd = []
        for m in range(5):
            prior = 0.72 * self.modes[m] + 0.28 * (1.0 - self.modes[m]) / 4.0
            upd.append(prior * like[m] / total)
        s = sum(upd) or 1.0
        self.modes = [u / s for u in upd]

    # ---------------- signals ----------------
    def block(self, key):
        self.blocked[key] = self.blocked.get(key, 0) + 1
        return 0

    def evaluate_momentum(self):
        cfg = self.cfg
        if not cfg.use_momentum:
            return 0
        noise, drift, impulse, exhaust, shock = self.modes
        if cfg.max_shock_exhaust > 0 and shock + exhaust > cfg.max_shock_exhaust:
            return self.block("shock/exhaust")
        if cfg.min_impulse_drift > 0 and impulse + drift < cfg.min_impulse_drift:
            return self.block("impulse+drift low")

        direction, cross = 0, None
        if (self.cusum_up >= cfg.cusum_trigger
                and self.cusum_up - self.cusum_down >= cfg.cusum_trigger * 0.5):
            direction, cross = 1, self.cross_up
        elif (self.cusum_down >= cfg.cusum_trigger
                and self.cusum_down - self.cusum_up >= cfg.cusum_trigger * 0.5):
            direction, cross = -1, self.cross_down
        if direction == 0:
            return self.block("no burst")
        bar = self.m1.closed(1)
        if cross is None or (cfg.cusum_fresh_bars > 0
                            and bar[0] - cross > cfg.cusum_fresh_bars * 60):
            return self.block("burst stale")

        if cfg.momentum_min_er > 0 and (direction * self.er <= 0.0
                                        or abs(self.er) < cfg.momentum_min_er):
            return self.block("ER low")
        if cfg.min_m1_strength > 0 and direction * self.m1_comp < cfg.min_m1_strength:
            return self.block("M1 strength")
        if (cfg.min_m1_coherence > 0
                and coherence(self.m1, (1, 3, 5, 15), direction) < cfg.min_m1_coherence):
            return self.block("M1 coherence")
        if direction * (bar[4] - bar[1]) <= 0.0:
            return self.block("bar body against")
        if (cfg.big_bar_max_atr > 0 and self.atr_m1 > 0
                and bar[2] - bar[3] > cfg.big_bar_max_atr * self.atr_m1):
            return self.block("oversized bar")

        if cfg.max_maturity_m5_atr > 0 and self.atr_m5 > 0:
            lo = min(self.m1.closed(k)[3] for k in range(1, 32) if self.m1.closed(k))
            hi = max(self.m1.closed(k)[2] for k in range(1, 32) if self.m1.closed(k))
            maturity = bar[4] - lo if direction > 0 else hi - bar[4]
            if maturity / self.atr_m5 > cfg.max_maturity_m5_atr:
                return self.block("move mature")

        if cfg.require_m5_alignment:
            if direction * self.m5_comp <= 0.0:
                return self.block("M5 velocity against")
            e20 = ema_close(self.m5, 20)
            e30 = ema_close(self.m5, 30)
            if self.atr_m5 > 0 and direction * (e20 - e30) / self.atr_m5 < -0.05:
                return self.block("M5 ribbon against")
        return direction

    def evaluate_fade(self):
        cfg = self.cfg
        if not cfg.use_fade:
            return 0, 0.0
        noise, drift, impulse, exhaust, shock = self.modes
        if ((cfg.max_shock_exhaust > 0 and shock + exhaust > cfg.max_shock_exhaust)
                or noise < cfg.min_fade_noise):
            return self.block("fade regime"), 0.0
        if abs(self.er) > cfg.fade_max_er or self.expansion > cfg.fade_max_expansion:
            return self.block("fade gates"), 0.0
        mid = sma_close(self.m1, cfg.fade_ma_period)
        a = atr(self.m1, cfg.fade_atr_period)
        if mid <= 0 or a <= 0:
            return 0, 0.0
        close1 = self.m1.closed(1)[4]
        up, dn = mid + cfg.fade_band_atr * a, mid - cfg.fade_band_atr * a
        if dn < close1 < up:
            self.fade_armed = True
            return 0, 0.0
        if not self.fade_armed:
            return self.block("excursion faded"), 0.0
        self.fade_armed = False
        return (-1 if close1 > up else 1), mid

    # ---------------- rails ----------------
    def entry_allowed(self, t_s):
        cfg = self.cfg
        if self.pos is not None:
            return self.block_entry("position open")
        tm = int(t_s // 60) % 1440
        dow = (int(t_s // 86400) + 4) % 7          # epoch day 0 = Thursday
        if cfg.use_session_filter and not any(
                a <= tm < b if a <= b else (tm >= a or tm < b)
                for a, b in cfg.sessions_utc):
            return self.block_entry("outside session")
        if (cfg.friday_cutoff_hour_utc > 0 and dow == 5
                and tm // 60 >= cfg.friday_cutoff_hour_utc):
            return self.block_entry("friday cutoff")
        if (cfg.cooldown_seconds > 0 and self.last_entry_time is not None
                and t_s - self.last_entry_time < cfg.cooldown_seconds):
            return self.block_entry("cooldown")
        if cfg.max_trades_per_day > 0 and self.trades_today >= cfg.max_trades_per_day:
            return self.block_entry("daily trade cap")
        if cfg.max_daily_loss_percent > 0:
            limit = self.day_start_balance * cfg.max_daily_loss_percent / 100.0
            if self.closed_pnl_today <= -limit:
                return self.block_entry("DAILY LOSS BRAKE")
        if (cfg.max_consecutive_losses > 0
                and self.consec_losses >= cfg.max_consecutive_losses):
            if cfg.loss_pause_minutes <= 0:
                return self.block_entry("streak: down for day")
            if (self.last_loss_time is not None
                    and t_s - self.last_loss_time < cfg.loss_pause_minutes * 60):
                return self.block_entry("streak pause")
        return True

    def block_entry(self, key):
        self.blocked[key] = self.blocked.get(key, 0) + 1
        return False

    # ---------------- execution ----------------
    def size_lots(self):
        cfg = self.cfg
        if cfg.fixed_lots > 0:
            return cfg.fixed_lots if cfg.fixed_lots >= cfg.min_lot else 0.0
        risk = self.balance * cfg.risk_percent / 100.0
        per_lot = cfg.hard_stop_usd * cfg.contract_size
        if per_lot <= 0:
            return 0.0
        lots = math.floor(risk / per_lot / cfg.lot_step) * cfg.lot_step
        return round(lots, 2) if lots >= cfg.min_lot else 0.0

    def try_enter(self, t_s, bid, ask):
        cfg = self.cfg
        direction, module = self.signal, self.signal_module
        spread = ask - bid + cfg.spread_add_usd
        if cfg.max_spread_usd > 0 and spread > cfg.max_spread_usd:
            return self.block_entry("spread")
        entry = (ask + cfg.spread_add_usd if direction > 0 else bid) \
            + direction * cfg.slippage_usd
        if cfg.max_chase_usd > 0 and abs(entry - self.signal_ref) > cfg.max_chase_usd:
            return self.block_entry("no chase")
        lots = self.size_lots()
        if lots <= 0:
            return self.block_entry("lot calc")
        self.pos = Position(
            direction=direction, lots=lots, entry=entry, entry_time=t_s,
            module=module, fade_target=self.signal_fade_target,
            hard_stop=entry - direction * cfg.hard_stop_usd)
        self.last_entry_time = t_s
        self.trades_today += 1
        return True

    def close_position(self, t_s, price, reason, lots=None):
        cfg = self.cfg
        pos = self.pos
        lots = pos.lots if lots is None else lots
        fill = price - pos.direction * cfg.slippage_usd
        gross = pos.direction * (fill - pos.entry) * cfg.contract_size * lots
        pnl = gross - cfg.commission_per_lot * lots
        partial = lots < pos.lots
        if partial:
            pos.lots = round(pos.lots - lots, 2)
            pos.realized += pnl
            pos.partial_done = True
            self.balance += pnl
            return
        total = pnl + pos.realized
        self.balance += pnl
        self.closed_pnl_today += total
        if total < 0:
            self.consec_losses += 1
            self.last_loss_time = t_s
        else:
            self.consec_losses = 0
        self.trades.append(Trade(
            entry_time=pos.entry_time, exit_time=t_s, direction=pos.direction,
            lots=lots, entry=pos.entry, exit=fill, pnl=total, reason=reason,
            module=pos.module, max_fav=pos.max_fav, max_adv=pos.max_adv))
        self.pos = None

    def manage(self, t_s, bid, ask):
        cfg = self.cfg
        pos = self.pos
        move = pos.direction * ((bid if pos.direction > 0 else ask) - pos.entry)
        pos.max_fav = max(pos.max_fav, move)
        pos.max_adv = min(pos.max_adv, move)
        if not pos.launched and pos.max_fav >= cfg.launch_progress_usd:
            pos.launched = True
        exit_px = bid if pos.direction > 0 else ask

        # broker-side stop: the trailed stop once set, else the catastrophe stop
        stop = pos.stop if pos.stop != 0.0 else pos.hard_stop
        label = "HARD STOP" if pos.stop == 0.0 else "TRAIL STOP"
        if pos.direction > 0 and bid <= stop:
            self.close_position(t_s, min(stop, bid), label)
            return
        if pos.direction < 0 and ask >= stop:
            self.close_position(t_s, max(stop, ask), label)
            return
        # fixed take profit (user TP wins over the fade mean target)
        tp = 0.0
        if cfg.take_profit_usd > 0.0:
            tp = pos.entry + pos.direction * cfg.take_profit_usd
        elif pos.fade_target > 0.0:
            tp = pos.fade_target
        if tp > 0.0:
            if pos.direction > 0 and bid >= tp:
                self.close_position(t_s, bid, "TAKE PROFIT")
                return
            if pos.direction < 0 and ask <= tp:
                self.close_position(t_s, ask, "TAKE PROFIT")
                return
        # software fast cut: two consecutive breaches, so a one-tick
        # spread blip cannot scratch a healthy trade (mirrors the EA)
        if cfg.scratch_adverse_usd > 0 and move <= -cfg.scratch_adverse_usd:
            pos.adverse_hits += 1
            if pos.adverse_hits >= 2:
                self.close_position(t_s, exit_px, "FAST CUT")
                return
        else:
            pos.adverse_hits = 0
        # confirm-or-scratch
        if (cfg.launch_window_seconds > 0 and not pos.launched
                and t_s - pos.entry_time >= cfg.launch_window_seconds):
            self.close_position(t_s, exit_px, "FAILURE TO LAUNCH")
            return
        # time stop
        if (cfg.max_hold_minutes > 0
                and t_s - pos.entry_time >= cfg.max_hold_minutes * 60):
            self.close_position(t_s, exit_px, "MAX HOLD")
            return
        # partial bank
        if (cfg.use_partial_bank and not pos.partial_done
                and pos.max_fav >= cfg.partial_at_usd
                and move >= cfg.partial_at_usd * 0.5):
            bank = math.floor(pos.lots * cfg.partial_percent / 100.0
                              / cfg.lot_step) * cfg.lot_step
            bank = round(bank, 2)
            if bank >= cfg.min_lot and pos.lots - bank >= cfg.min_lot:
                self.close_position(t_s, exit_px, "PARTIAL", lots=bank)
            else:
                pos.partial_done = True
        # breakeven + trail (software mirror of the EA's OrderModify path)
        desired = None
        if cfg.breakeven_at_usd > 0 and pos.max_fav >= cfg.breakeven_at_usd:
            desired = pos.entry + pos.direction * cfg.breakeven_lock_usd
        if (cfg.trail_start_usd > 0 and cfg.trailing_distance_usd > 0
                and pos.max_fav >= cfg.trail_start_usd):
            trail = exit_px - pos.direction * cfg.trailing_distance_usd
            if desired is None or pos.direction * (trail - desired) > 0:
                desired = trail
        if desired is not None:
            current = pos.stop if pos.stop != 0.0 else pos.hard_stop
            if pos.direction * (desired - current) > 0:
                pos.stop = desired

    # ---------------- main loop ----------------
    def on_tick(self, t_s, bid, ask):
        cfg = self.cfg
        day = int(t_s // 86400)
        if day != self.day_key:
            self.day_key = day
            self.trades_today = 0
            self.closed_pnl_today = 0.0
            self.day_start_balance = self.balance

        if self.pos is not None:
            self.manage(t_s, bid, ask)

        m1_closed = self.m1.add(t_s, bid)
        self.m5.add(t_s, bid)

        if m1_closed and self.m1.count() > cfg.er_period + 60 and self.m5.count() > 40:
            self.update_regime()
            direction = self.evaluate_momentum()
            module, fade_target = "momentum", 0.0
            if direction == 0:
                direction, fade_target = self.evaluate_fade()
                module = "fade"
            self.signal = direction
            self.signal_module = module if direction else ""
            self.signal_ref = self.m1.closed(1)[4]
            self.signal_fade_target = fade_target
            self.pending_entry = direction != 0

            if direction != 0 and self.pos is not None and cfg.exit_on_opposite:
                if self.pos.direction != direction:
                    self.close_position(
                        t_s, bid if self.pos.direction > 0 else ask,
                        "OPPOSITE SIGNAL")

        if self.pending_entry:
            self.pending_entry = False
            if self.signal != 0 and self.entry_allowed(t_s) is True:
                self.try_enter(t_s, bid, ask)

    def finish(self, t_s, bid, ask):
        if self.pos is not None:
            self.close_position(t_s, bid if self.pos.direction > 0 else ask,
                                "END OF DATA")


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------
def summarize(bt: Backtester):
    trades = bt.trades
    if not trades:
        return {"trades": 0, "note": "no trades - inspect blocked counters",
                "blocked": bt.blocked}
    wins = [t for t in trades if t.pnl > 0]
    losses = [t for t in trades if t.pnl <= 0]
    gross_win = sum(t.pnl for t in wins)
    gross_loss = -sum(t.pnl for t in losses)
    equity, peak, max_dd = bt.cfg.balance, bt.cfg.balance, 0.0
    for t in trades:
        equity += t.pnl
        peak = max(peak, equity)
        max_dd = max(max_dd, peak - equity)
    days = {}
    for t in trades:
        days.setdefault(int(t.entry_time // 86400), 0.0)
        days[int(t.entry_time // 86400)] += t.pnl
    reasons = {}
    for t in trades:
        reasons[t.reason] = reasons.get(t.reason, 0) + 1
    return {
        "trades": len(trades),
        "trades_per_day": round(len(trades) / max(len(days), 1), 2),
        "win_rate_pct": round(100.0 * len(wins) / len(trades), 1),
        "avg_win": round(gross_win / len(wins), 2) if wins else 0.0,
        "avg_loss": round(-gross_loss / len(losses), 2) if losses else 0.0,
        "profit_factor": round(gross_win / gross_loss, 2) if gross_loss > 0 else float("inf"),
        "expectancy_per_trade": round(sum(t.pnl for t in trades) / len(trades), 2),
        "net_pnl": round(sum(t.pnl for t in trades), 2),
        "final_balance": round(bt.balance, 2),
        "max_drawdown": round(max_dd, 2),
        "worst_day": round(min(days.values()), 2),
        "best_day": round(max(days.values()), 2),
        "losing_days": sum(1 for v in days.values() if v < 0),
        "trading_days": len(days),
        "exit_reasons": reasons,
        "blocked": dict(sorted(bt.blocked.items(), key=lambda kv: -kv[1])),
    }


def run(files, cfg: Config, trades_out=None):
    bt = Backtester(cfg)
    last = None
    n_ticks = 0
    for path in files:
        with open(path, newline="") as fh:
            reader = csv.reader(fh)
            for row in reader:
                if not row or row[0].startswith(("time", "#")):
                    continue
                t_s = int(row[0]) / 1000.0
                bid, ask = float(row[1]), float(row[2])
                if bid <= 0 or ask <= 0 or ask < bid:
                    continue
                bt.on_tick(t_s, bid, ask)
                last = (t_s, bid, ask)
                n_ticks += 1
    if last:
        bt.finish(*last)
    summary = summarize(bt)
    summary["ticks"] = n_ticks
    summary["files"] = len(files)
    if trades_out and bt.trades:
        with open(trades_out, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["entry_time", "exit_time", "dir", "lots", "entry",
                        "exit", "profit", "reason", "module", "mfe", "mae",
                        "hold_seconds"])
            for t in bt.trades:
                w.writerow([int(t.entry_time), int(t.exit_time),
                            "BUY" if t.direction > 0 else "SELL",
                            t.lots, round(t.entry, 3), round(t.exit, 3),
                            round(t.pnl, 2), t.reason, t.module,
                            round(t.max_fav, 2), round(t.max_adv, 2),
                            int(t.exit_time - t.entry_time)])
    return summary


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True,
                    help="glob for tick CSVs (time_ms,bid,ask), e.g. 'data/XAUUSD_*.csv'")
    ap.add_argument("--balance", type=float, default=10000.0)
    ap.add_argument("--risk", type=float, default=0.5,
                    help="risk %% per trade (only used when --lots 0)")
    ap.add_argument("--lots", type=float, default=0.01,
                    help="fixed lot size, mirroring the EA's LotSize; 0 = risk-based")
    ap.add_argument("--commission", type=float, default=7.0,
                    help="round-trip commission per lot")
    ap.add_argument("--slippage", type=float, default=0.03,
                    help="slippage in USD applied to every fill")
    ap.add_argument("--spread-add", type=float, default=0.0,
                    help="widen recorded spreads by this many USD (stress test)")
    ap.add_argument("--enable-fade", action="store_true")
    ap.add_argument("--sessions", action="store_true",
                    help="apply a London/NY session filter (the EA has none)")
    ap.add_argument("--trades-out", default=None, help="write per-trade CSV here")
    ap.add_argument("--json", action="store_true", help="print summary as JSON only")
    args = ap.parse_args()

    files = sorted(glob.glob(args.data))
    if not files:
        sys.exit(f"no files match {args.data!r} - run download_dukascopy.py first")

    cfg = Config(balance=args.balance, risk_percent=args.risk,
                 fixed_lots=args.lots,
                 commission_per_lot=args.commission, slippage_usd=args.slippage,
                 spread_add_usd=args.spread_add, use_fade=args.enable_fade,
                 use_session_filter=args.sessions)
    summary = run(files, cfg, trades_out=args.trades_out)
    if args.json:
        print(json.dumps(summary, indent=2))
        return
    print(json.dumps(summary, indent=2))
    if summary.get("trades", 0) > 0:
        print("\nRead this honestly: expectancy_per_trade must clear zero AFTER")
        print("the commission and slippage you actually pay, across BOTH halves")
        print("of your data, before any parameter touches a live terminal.")


if __name__ == "__main__":
    main()
