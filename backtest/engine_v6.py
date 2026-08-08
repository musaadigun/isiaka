"""Port of the XVISION V6 core: closed-H1 regime gate, closed-M5 setup, closed-M1 trigger.

Mirrors XVISION_Gold_Velocity_AI_EA_V6.mq4 lines 15-375. No fitted model in V6 —
the qualification is a deterministic stack of hand-set thresholds.
"""
import numpy as np, pandas as pd
from engine import load_mt4_csv, true_range, rolling_atr, ema


def _last_closed(tf_times, tf_seconds, decision_times, required_older):
    """GVLastFullyClosedShift, in chronological indices.

    Returns the index of the last fully closed bar at each decision time, or -1.
    NOTE: the MQL version applies no staleness bound (see audit V6-M1).
    """
    containing = np.searchsorted(tf_times, decision_times, side="right") - 1
    idx = containing - 1                      # closedShift = containing + 1 (MT4) => one bar older
    ok = (containing >= 0) & (idx >= required_older)
    safe = np.clip(idx, 0, len(tf_times) - 1)
    bar_close = tf_times[safe] + tf_seconds
    ok &= (bar_close <= decision_times)
    return np.where(ok, idx, -1), (decision_times - bar_close) / 3600.0


def compute_signals_v6(m1, m5, h1, thr=None, max_stale_hours=None):
    T = dict(m5_eff=0.15, m5_str_lo=0.10, m5_str_hi=2.50, m5_coh=0.667, m5_shock=2.50,
             m5_pull=1.50, h1_gap=0.00, h1_slope=0.00, h1_eff=0.10, h1_bodies=3,
             h1_shock=2.50, m1_str=0.05, m1_acc=0.00, m1_coh=0.75, m1_shock=2.50,
             m1_chase=1.00, m1_pattern=True)
    if thr: T.update(thr)

    t1 = m1.t.to_numpy("datetime64[s]").astype(np.int64)
    o1, h1h, l1, c1 = (m1[x].to_numpy(float) for x in "ohlc")
    t5 = m5.t.to_numpy("datetime64[s]").astype(np.int64)
    o5, h5, l5, c5 = (m5[x].to_numpy(float) for x in "ohlc")
    tH = h1.t.to_numpy("datetime64[s]").astype(np.int64)
    oH, hH, lH, cH = (h1[x].to_numpy(float) for x in "ohlc")

    n = len(t1)
    idx1 = np.arange(n)
    decision = t1 + 60                                  # close time of the signal M1 bar
    i5, _ = _last_closed(t5, 300, decision, 79)
    iH, staleH = _last_closed(tH, 3600, decision, 30)
    base_ok = (i5 >= 0) & (iH >= 0) & (idx1 >= 80)
    s5 = np.clip(i5, 0, len(t5) - 1); sH = np.clip(iH, 0, len(tH) - 1)

    tr1 = true_range(h1h, l1, c1); tr5 = true_range(h5, l5, c5); trH = true_range(hH, lH, cH)
    atr_m1 = rolling_atr(tr1, 14)
    atr_m5 = rolling_atr(tr5, 12)[s5]
    atr_m5_slow = rolling_atr(tr5, 48)[s5]              # computed & range-checked, never used (V6-L1)
    atr_h1 = rolling_atr(trH, 14)[sH]
    a1 = atr_m1

    def net(c, o, w, i):
        j = i - (w - 1)
        return np.where(j >= 0, c[i] - o[np.maximum(j, 0)], np.nan)

    with np.errstate(invalid="ignore", divide="ignore"):
        # ---- M5 setup ----
        m5w = [1, 3, 6, 12, 24, 48]
        v5 = np.vstack([net(c5, o5, w, s5) / (atr_m5 * np.sqrt(w)) for w in m5w])
        comp5 = 0.25*v5[0] + 0.25*v5[1] + 0.20*v5[2] + 0.15*v5[3] + 0.10*v5[4] + 0.05*v5[5]
        direction = np.where(comp5 >= 0.0, 1, -1)
        m5_strength = np.abs(comp5)
        cs5 = np.concatenate([[0.0], np.cumsum(tr5)])
        range12 = cs5[s5+1] - cs5[np.maximum(s5-11, 0)]
        sw = np.lib.stride_tricks.sliding_window_view
        hi12 = np.full(len(t5), np.nan); lo12 = np.full(len(t5), np.nan)
        hi12[11:] = sw(h5, 12).max(axis=1); lo12[11:] = sw(l5, 12).min(axis=1)
        m5_eff = np.abs(net(c5, o5, 12, s5)) / np.maximum(range12, 0.01)
        m5_shock = tr5[s5] / atr_m5
        m5_coh = (direction * v5 > 0.0).sum(axis=0) / 6.0
        m5_close = c5[s5]
        m5_pull = np.where(direction > 0, (m5_close - hi12[s5]) / atr_m5, (lo12[s5] - m5_close) / atr_m5)
        m5_setup = ((m5_eff >= T['m5_eff']) & (m5_strength >= T['m5_str_lo']) &
                    (m5_strength <= T['m5_str_hi']) & (m5_coh >= T['m5_coh']) &
                    (m5_shock <= T['m5_shock']) & (m5_pull >= -T['m5_pull']))

        # ---- H1 regime gate ----
        e8 = ema(cH, 8); e21 = ema(cH, 21)
        h1_gap = direction * (e8[sH] - e21[sH]) / atr_h1
        h1_slope = direction * (e8[sH] - e8[np.maximum(sH-1, 0)]) / atr_h1
        hv1 = direction * net(cH, oH, 1, sH) / atr_h1
        hv2 = direction * net(cH, oH, 2, sH) / (atr_h1 * np.sqrt(2.0))
        hv4 = direction * net(cH, oH, 4, sH) / (atr_h1 * 2.0)
        csH = np.concatenate([[0.0], np.cumsum(trH)])
        h1_range4 = csH[sH+1] - csH[np.maximum(sH-3, 0)]
        bodyH = cH - oH
        upH = np.concatenate([[0.0], np.cumsum((bodyH > 0).astype(float))])
        dnH = np.concatenate([[0.0], np.cumsum((bodyH < 0).astype(float))])
        nupH = upH[sH+1] - upH[np.maximum(sH-3, 0)]; ndnH = dnH[sH+1] - dnH[np.maximum(sH-3, 0)]
        h1_bodies = np.where(direction > 0, nupH, ndnH)
        h1_eff = np.abs(net(cH, oH, 4, sH)) / np.maximum(h1_range4, 0.01)
        h1_shock = trH[sH] / atr_h1
        h1_gate = ((h1_gap > T['h1_gap']) & (h1_slope > T['h1_slope']) &
                   (hv1 > 0.0) & (hv2 > 0.0) & (hv4 > 0.0) &
                   (h1_bodies >= T['h1_bodies']) & (h1_eff >= T['h1_eff']) &
                   (h1_shock <= T['h1_shock']))

        # ---- M1 trigger ----
        m1w = [1, 3, 5, 15]
        v1 = np.vstack([net(c1, o1, w, idx1) / (a1 * np.sqrt(w)) for w in m1w])
        comp1 = 0.35*v1[0] + 0.30*v1[1] + 0.20*v1[2] + 0.15*v1[3]
        m1_strength = direction * comp1
        m1_coh = (direction * v1 > 0.0).sum(axis=0) / 4.0
        recent = net(c1, o1, 3, idx1) / 3.0
        j3 = np.maximum(idx1-3, 0); j14 = np.maximum(idx1-14, 0)
        prior = np.where(idx1 >= 14, (c1[j3] - o1[j14]) / 12.0, np.nan)
        m1_acc = direction * (recent - prior) / a1
        m1_shock = tr1 / a1
        m1_body = c1 - o1
        aligned_body = (direction * m1_body) > 0.0
        prior_bodies = np.vstack([np.roll(m1_body, p) for p in (1, 2, 3)])
        pullback = ((direction * prior_bodies) < 0.0).any(axis=0)
        prev_hi = np.full(n, -np.inf); prev_lo = np.full(n, np.inf)
        prev_hi[3:] = sw(h1h, 3)[:-1].max(axis=1); prev_lo[3:] = sw(l1, 3)[:-1].min(axis=1)
        breakout = np.where(direction > 0, c1 > prev_hi, c1 < prev_lo)
        pattern_ok = (not T['m1_pattern']) | pullback | breakout
        m1_chase = np.abs(c1 - m5_close) / atr_m5
        m1_trigger = ((m1_strength >= T['m1_str']) & (m1_acc >= T['m1_acc']) &
                      (m1_coh >= T['m1_coh']) & (m1_shock <= T['m1_shock']) &
                      (m1_chase <= T['m1_chase']) & aligned_body & pattern_ok)

    valid = (base_ok & (atr_m5 > 0) & (atr_m5_slow > 0) & (atr_h1 > 0) & (a1 > 0)
             & np.isfinite(comp5) & np.isfinite(comp1) & np.isfinite(m1_acc))
    if max_stale_hours is not None:
        valid &= (staleH <= max_stale_hours)

    qualified = valid & h1_gate & m5_setup & m1_trigger
    return pd.DataFrame({
        "t": m1.t, "valid": valid, "qualified": qualified, "direction": direction,
        "ref_entry": c1, "h1_gate": h1_gate, "m5_setup": m5_setup, "m1_trigger": m1_trigger,
        "h1_gap": h1_gap, "h1_slope": h1_slope, "h1_eff": h1_eff, "h1_bodies": h1_bodies,
        "m5_eff": m5_eff, "m5_strength": m5_strength, "m5_coh": m5_coh, "m5_pull": m5_pull,
        "m1_strength": m1_strength, "m1_acc": m1_acc, "m1_coh": m1_coh, "m1_chase": m1_chase,
        "m1_shock": m1_shock, "breakout": breakout, "pullback": pullback,
        "h1_stale_h": staleH, "atr_m5": atr_m5,
        # V6 confidence score, for the ranking test
        "confidence": 100.0*np.clip((
            (0.25*np.clip(h1_gap/0.50,0,1)+0.25*np.clip(h1_slope/0.20,0,1)
             +0.25*np.clip(h1_eff/0.40,0,1)+0.25*(h1_bodies/4.0))
            + (0.50*np.clip(m5_eff/0.40,0,1)+0.25*np.clip(m5_strength/1.0,0,1)+0.25*m5_coh)
            + (0.40*np.clip(m1_strength/0.50,0,1)+0.30*np.clip(m1_acc/0.50,0,1)+0.30*m1_coh)
        )/3.0, 0, 1),
    })
