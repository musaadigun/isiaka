"""Bar-by-bar simulation of the XVISION EA's execution and management layer.

Mirrors OnTick order: ManagePositionEveryTick (time stop -> partials -> stop
management) runs first, then on an M5 bar change the engine recalculates and
the velocity-exit / entry block runs.

Price convention: MT4 CSV exports are BID. Ask = Bid + spread.
  BUY  enters at Ask, exits at Bid, SL/TP evaluated on Bid.
  SELL enters at Bid, exits at Ask, SL/TP evaluated on Ask.
Contract 100 oz/lot, so P/L = movement * 100 * lots.
"""
import numpy as np, pandas as pd
from dataclasses import dataclass, field


@dataclass
class Cfg:
    # --- EA inputs, at shipped defaults except EnableAutomaticEntries ---
    allow_buy: bool = True
    allow_sell: bool = True
    fixed_lots: float = 0.01
    risk_percent: float = 0.0          # 0 => fixed lots
    initial_sl: float = 15.0
    use_tp: bool = False
    tp_move: float = 30.0
    use_breakeven: bool = False
    be_activate: float = 10.0
    be_lock: float = 1.0
    use_trailing: bool = True
    trail_activate: float = 10.0
    trail_distance: float = 5.0
    trail_step: float = 1.0
    max_hold_min: int = 240
    min_minutes_between: int = 15
    max_entry_deviation: float = 3.0
    max_spread_input: float = 2.0
    max_trades_per_day: int = 3
    max_daily_loss: float = 0.0
    # --- market / cost model (NOT EA inputs) ---
    spread: float = 0.30
    commission_per_lot_roundturn: float = 0.0
    entry_slippage: float = 0.0        # adverse, price units
    stoplevel: float = 0.0
    pessimistic: bool = True           # adverse extreme reached before favourable
    start_balance: float = 10000.0


def build_path(m5, m1):
    """Finest-resolution price path, tagged with its parent M5 bar."""
    m5t = m5.t.to_numpy("datetime64[s]").astype(np.int64)
    rows_t, rows_o, rows_h, rows_l, rows_c, rows_bar, rows_first = [], [], [], [], [], [], []
    if m1 is not None and len(m1):
        m1t = m1.t.to_numpy("datetime64[s]").astype(np.int64)
        m1o, m1h, m1l, m1c = (m1[x].to_numpy(float) for x in "ohlc")
        lo = np.searchsorted(m1t, m5t, "left")
        hi = np.searchsorted(m1t, m5t + 300, "left")
    else:
        lo = hi = np.zeros(len(m5t), int)
    o, h, l, c = (m5[x].to_numpy(float) for x in "ohlc")
    for i in range(len(m5t)):
        a, b = lo[i], hi[i]
        if b - a >= 1:
            for j in range(a, b):
                rows_t.append(m1t[j]); rows_o.append(m1o[j]); rows_h.append(m1h[j])
                rows_l.append(m1l[j]); rows_c.append(m1c[j])
                rows_bar.append(i); rows_first.append(j == a)
        else:
            rows_t.append(m5t[i]); rows_o.append(o[i]); rows_h.append(h[i])
            rows_l.append(l[i]); rows_c.append(c[i])
            rows_bar.append(i); rows_first.append(True)
    return (np.array(rows_t), np.array(rows_o), np.array(rows_h), np.array(rows_l),
            np.array(rows_c), np.array(rows_bar), np.array(rows_first, bool))


def run(m5, sig, qualified, cfg: Cfg, m1=None):
    pt, po, ph, pl, pc, pbar, pfirst = build_path(m5, m1)
    sig_dir = sig.direction.to_numpy(); sig_ref = sig.ref_entry.to_numpy()
    sig_p10 = sig.p10.to_numpy(); sig_p30 = sig.p30.to_numpy()
    sig_body = sig.h4body.to_numpy()
    qual = qualified.to_numpy()
    m5t = m5.t.to_numpy("datetime64[s]").astype(np.int64)

    sp, comm = cfg.spread, cfg.commission_per_lot_roundturn
    pos = None
    trades = []
    balance = cfg.start_balance
    last_entry_t = 0
    day_key = None; day_trades = 0; day_pnl = 0.0
    blocked = {"cooldown": 0, "daily_limit": 0, "deviation": 0, "spread": 0, "position_open": 0}

    def close(px_bid, when, reason):
        nonlocal pos, balance, day_pnl
        if pos["dir"] > 0:
            move = px_bid - pos["entry"]
        else:
            move = pos["entry"] - (px_bid + sp)
        pnl = move * 100.0 * pos["lots"] - comm * pos["lots"]
        balance += pnl; day_pnl += pnl
        trades.append(dict(dir=pos["dir"], t_in=pos["t_in"], t_out=when, entry=pos["entry"],
                           exit=(px_bid if pos["dir"] > 0 else px_bid + sp), lots=pos["lots"],
                           move=move, pnl=pnl, reason=reason, bal=balance,
                           p10=pos["p10"], p30=pos["p30"], h4body=pos["h4body"],
                           mfe=pos["mfe"], mae=pos["mae"]))
        pos = None

    def manage(o_, h_, l_, c_, when):
        """One 'tick sweep' over a sub-bar. Returns True if the position closed."""
        nonlocal pos
        if pos is None:
            return False
        d = pos["dir"]
        # excursion bookkeeping (in movement terms, net of spread)
        if d > 0:
            pos["mfe"] = max(pos["mfe"], h_ - pos["entry"]); pos["mae"] = min(pos["mae"], l_ - pos["entry"])
        else:
            pos["mfe"] = max(pos["mfe"], pos["entry"] - (l_ + sp)); pos["mae"] = min(pos["mae"], pos["entry"] - (h_ + sp))

        # 1. time stop, checked before anything else (ManagePositionEveryTick order)
        if cfg.max_hold_min > 0 and when - pos["t_in"] >= cfg.max_hold_min * 60:
            close(o_, when, "TIME"); return True

        seq = [(l_, h_) if d > 0 else (h_, l_)]        # (adverse, favourable)
        adverse, favourable = seq[0]
        legs = [(adverse, True), (favourable, False)] if cfg.pessimistic \
               else [(favourable, False), (adverse, True)]

        for px, is_adverse in legs:
            # --- stop / target evaluation at this excursion ---
            if pos["sl"] > 0:
                if d > 0 and px <= pos["sl"]:
                    close(pos["sl"], when, pos["sl_kind"]); return True
                if d < 0 and px + sp >= pos["sl"]:
                    close(pos["sl"] - sp, when, pos["sl_kind"]); return True
            if pos["tp"] > 0:
                if d > 0 and px >= pos["tp"]:
                    close(pos["tp"], when, "TP"); return True
                if d < 0 and px + sp <= pos["tp"]:
                    close(pos["tp"] - sp, when, "TP"); return True
            if is_adverse:
                continue
            # --- stop management at the favourable excursion ---
            bid = px
            move = (bid - pos["entry"]) if d > 0 else (pos["entry"] - (bid + sp))
            desired = pos["sl"]; have = desired > 0
            kind = pos["sl_kind"]
            if cfg.use_breakeven and move >= cfg.be_activate:
                be = pos["entry"] + cfg.be_lock if d > 0 else pos["entry"] - cfg.be_lock
                if not have or (d > 0 and be > desired) or (d < 0 and be < desired):
                    desired, have, kind = be, True, "BREAKEVEN"
            if cfg.use_trailing and move >= cfg.trail_activate:
                tr = bid - cfg.trail_distance if d > 0 else (bid + sp) + cfg.trail_distance
                if not have or (d > 0 and tr > desired) or (d < 0 and tr < desired):
                    desired, have, kind = tr, True, "TRAIL"
            if not have:
                continue
            minstop = cfg.stoplevel
            desired = min(desired, bid - minstop) if d > 0 else max(desired, bid + sp + minstop)
            old = pos["sl"]
            improves = old <= 0 or (d > 0 and desired > old) or (d < 0 and desired < old)
            if not improves:
                continue
            step = cfg.trail_step if cfg.use_trailing else 0.01
            if old > 0 and abs(desired - old) < step:
                continue
            pos["sl"] = desired; pos["sl_kind"] = kind
        return False

    for k in range(len(pt)):
        when = int(pt[k]); i = int(pbar[k])
        d_key = (when // 86400)
        if d_key != day_key:
            day_key, day_trades, day_pnl = d_key, 0, 0.0

        if pfirst[k]:
            # --- tick at the open of M5 bar i: manage first, then the bar-change block ---
            manage(po[k], po[k], po[k], po[k], when)
            s = i - 1                       # GVCalculate(shift=1)
            if s >= 0 and qual[s] and pos is None:
                d = int(sig_dir[s])
                ok = (cfg.allow_buy if d > 0 else cfg.allow_sell)
                if ok and cfg.min_minutes_between > 0 and last_entry_t > 0 \
                   and when - last_entry_t < cfg.min_minutes_between * 60:
                    blocked["cooldown"] += 1; ok = False
                if ok and cfg.max_trades_per_day > 0 and day_trades >= cfg.max_trades_per_day:
                    blocked["daily_limit"] += 1; ok = False
                if ok and cfg.max_daily_loss > 0 and day_pnl <= -cfg.max_daily_loss:
                    ok = False
                if ok:
                    bid = po[k]; ask = bid + sp
                    exec_px = ask if d > 0 else bid
                    if cfg.max_spread_input > 0 and sp > cfg.max_spread_input:
                        blocked["spread"] += 1; ok = False
                    elif cfg.max_entry_deviation > 0 and abs(exec_px - sig_ref[s]) > cfg.max_entry_deviation:
                        blocked["deviation"] += 1; ok = False
                if ok:
                    fill = exec_px + (cfg.entry_slippage if d > 0 else -cfg.entry_slippage)
                    lots = cfg.fixed_lots
                    if cfg.risk_percent > 0 and cfg.initial_sl > 0:
                        raw = (balance * cfg.risk_percent / 100.0) / (cfg.initial_sl * 100.0)
                        lots = np.floor(raw / 0.01) * 0.01
                        if lots < 0.01: lots = 0.0
                    if lots > 0:
                        sl = 0.0
                        if cfg.initial_sl > 0:
                            sl = fill - cfg.initial_sl if d > 0 else fill + cfg.initial_sl
                        tp = 0.0
                        if cfg.use_tp:
                            tp = fill + cfg.tp_move if d > 0 else fill - cfg.tp_move
                        pos = dict(dir=d, entry=fill, lots=lots, sl=sl, tp=tp, sl_kind="SL",
                                   t_in=when, mfe=0.0, mae=0.0,
                                   p10=sig_p10[s], p30=sig_p30[s], h4body=sig_body[s])
                        last_entry_t = when; day_trades += 1
                        manage(po[k], po[k], po[k], po[k], when)
        manage(po[k], ph[k], pl[k], pc[k], when)

    tr = pd.DataFrame(trades)
    if len(tr):
        tr["t_in"] = pd.to_datetime(tr.t_in, unit="s"); tr["t_out"] = pd.to_datetime(tr.t_out, unit="s")
    return tr, blocked


def stats(tr, cfg: Cfg):
    if not len(tr):
        return {"trades": 0}
    w = tr[tr.pnl > 0]; l = tr[tr.pnl <= 0]
    eq = cfg.start_balance + tr.pnl.cumsum()
    peak = eq.cummax(); dd = peak - eq
    gross_w = w.pnl.sum(); gross_l = -l.pnl.sum()
    days = max((tr.t_out.max() - tr.t_in.min()).days, 1)
    return {
        "trades": len(tr),
        "net": tr.pnl.sum(),
        "return_pct": 100.0 * tr.pnl.sum() / cfg.start_balance,
        "win_rate": 100.0 * len(w) / len(tr),
        "profit_factor": (gross_w / gross_l) if gross_l > 0 else float("inf"),
        "expectancy": tr.pnl.mean(),
        "avg_win": w.pnl.mean() if len(w) else 0.0,
        "avg_loss": l.pnl.mean() if len(l) else 0.0,
        "max_dd": dd.max(),
        "max_dd_pct": 100.0 * dd.max() / cfg.start_balance,
        "best": tr.pnl.max(), "worst": tr.pnl.min(),
        "days": days, "trades_per_month": len(tr) / (days / 30.44),
        "gross_win": gross_w, "gross_loss": gross_l,
    }
