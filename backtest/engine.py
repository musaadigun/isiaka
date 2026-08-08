"""Faithful Python port of the XVISION Gold Velocity V2 core (GVCalculate).

Mirrors XVISION_Gold_Velocity_AI_EA_V4.mq4 lines 17-385 exactly, including the
MT4 indexing convention (shift 0 = most recent bar) mapped onto chronological
numpy arrays.
"""
import numpy as np, pandas as pd

FEATURE_COUNT = 18
REQUIRED_M5_BARS = 80

MEAN = np.array([0.374181123796594,0.350330800400409,0.424263222321453,0.41614406597278,
0.368859749477103,0.298510679954531,0.242475490091068,0.277889161672146,0.141485127523914,
0.743233233868746,0.184659574426205,1.00161698586867,1.01009428321479,-0.946420422883488,
0.751243307303245,0.0862128675148545,0.0552027853267929,0.185915108565955])
SCALE = np.array([0.310848596415106,0.555723499527384,0.487189391734892,0.468673138239048,
0.48275072739271,0.537955510647334,0.623531488982057,0.189951073101989,0.103637703828047,
0.116066490605106,0.386000932938842,0.44574724815579,0.284534020101779,0.683320796659603,
0.198243871360218,0.896188210101405,0.23678597286172,0.620764392355243])
W_P10 = np.array([-0.0871162160325488,0.0138523014478107,-0.00824790409587448,0.0099908332607123,
-0.0449774950154227,-0.301687141439503,-0.303112718684833,0.0111775578817596,-0.0502977735553706,
-0.00326921236262372,0.0092850324728807,0.098956742803495,-0.00397388687080714,
-0.00211674822448152,0.030244739550231,-0.0465826023025315,0.288026598161509,0.947157952956155])
W_P20 = np.array([-0.0763434113399279,0.0186244397461443,-0.0121386459238844,0.0294602178157844,
-0.00320756675009526,-0.306624654456992,-0.348801280877247,-0.00136387039248372,
-0.0820778164026169,0.0157983796503911,-0.00827991616524101,0.0963928039276705,
-0.0249031387409481,-0.0385191522692936,0.0229945752764106,-0.103902485137147,
0.314621975091277,0.989186994212931])
W_P30 = np.array([-0.0515894547911208,0.0216703433579721,0.0140912030303844,0.0162253175301388,
0.0875924885777673,-0.302169073793308,-0.396829467131808,0.0105576909985007,-0.198796523127003,
0.0536553876026269,-0.0270173179219084,0.089822900424633,-0.0693287391399023,-0.112781387074275,
0.0217320691438533,-0.184270801739023,0.353636873149091,1.00701379829479])
W_BAD = np.array([0.123309780587141,0.0135168122496239,0.0348849047154786,-0.00980593571445967,
0.144772768027678,0.252551025818724,0.290395632530969,-0.029905068070795,-0.0558959396015299,
-0.0177364131345675,-0.0329645652553512,-0.0138605738090414,0.142437896559029,
-0.0950582000720443,-0.00555806923429172,0.0831733906377258,-0.281128025206671,
-0.931010112614693])
B_P10, B_P20, B_P30, B_BAD = -0.25566355641265, -1.37079235407647, -2.2043970118605, -0.895915987192757


def load_mt4_csv(path):
    df = pd.read_csv(path, header=None, names=["date","time","o","h","l","c","v"])
    t = pd.to_datetime(df["date"] + " " + df["time"], format="%Y.%m.%d %H:%M")
    df = df.assign(t=t)[["t","o","h","l","c"]].sort_values("t").reset_index(drop=True)
    return df


def build_h4(h1):
    """MT4 anchors H4 buckets at 00:00 broker time: [0,4) [4,8) ... [20,24)."""
    b = h1.assign(bucket=h1.t.dt.floor("D") + pd.to_timedelta((h1.t.dt.hour // 4) * 4, unit="h"))
    g = b.groupby("bucket").agg(o=("o","first"), h=("h","max"), l=("l","min"), c=("c","last"))
    return g.reset_index().rename(columns={"bucket":"t"}).sort_values("t").reset_index(drop=True)


def ema(values, period):
    """MT4 iMA MODE_EMA: recursive, seeded with the SMA of the first `period` bars."""
    k = 2.0 / (period + 1.0)
    out = np.full(len(values), np.nan)
    if len(values) < period:
        return out
    out[period-1] = values[:period].mean()
    for i in range(period, len(values)):
        out[i] = values[i] * k + out[i-1] * (1.0 - k)
    return out


def true_range(h, l, c):
    """GVTrueRange: 0.0 when any input is non-positive (mirrors the MQL guard)."""
    prev = np.roll(c, 1); prev[0] = 0.0
    tr = np.maximum(h - l, np.maximum(np.abs(h - prev), np.abs(l - prev)))
    tr[(h <= 0) | (l <= 0) | (prev <= 0)] = 0.0
    return tr


def rolling_atr(tr, period):
    """GVATR: mean of `period` true ranges ending at index i; 0.0 if ANY member is <= 0."""
    n = len(tr)
    csum = np.concatenate([[0.0], np.cumsum(tr)])
    out = np.full(n, 0.0)
    idx = np.arange(n)
    ok = idx >= period - 1
    s = np.where(ok, csum[idx+1] - csum[np.maximum(idx+1-period, 0)], 0.0)
    out = np.where(ok, s / period, 0.0)
    zero = (tr <= 0).astype(np.int64)
    zsum = np.concatenate([[0], np.cumsum(zero)])
    anyzero = np.where(ok, zsum[idx+1] - zsum[np.maximum(idx+1-period, 0)], 1) > 0
    out[anyzero] = 0.0
    return out


def sigmoid_clamped(z):
    return 1.0 / (1.0 + np.exp(-np.clip(z, -35.0, 35.0)))


def compute_signals(m5, h4, require_contiguous=True):
    """Vectorised GVCalculate over every M5 bar.

    Row i of the result is the signal the EA would hold after M5 bar i closes,
    i.e. GVCalculate(shift=1) evaluated on the tick that opens bar i+1.
    """
    n = len(m5)
    o, h, l, c = (m5[x].to_numpy(float) for x in "ohlc")
    t = m5.t.to_numpy("datetime64[s]").astype(np.int64)

    tr = true_range(h, l, c)
    atr12 = rolling_atr(tr, 12)
    atr48 = rolling_atr(tr, 48)

    def net(window, i):
        """GVNet: close[shift] - open[shift+window-1], shift == chronological i."""
        j = i - (window - 1)
        return np.where(j >= 0, c[i] - o[np.maximum(j, 0)], np.nan)

    idx = np.arange(n)
    windows = [1, 3, 6, 12, 24, 48]
    vel = np.full((6, n), np.nan)
    with np.errstate(invalid="ignore", divide="ignore"):
        for wi, w in enumerate(windows):
            vel[wi] = net(w, idx) / (atr12 * np.sqrt(w))
    composite = (0.25*vel[0] + 0.25*vel[1] + 0.20*vel[2] + 0.15*vel[3] + 0.10*vel[4] + 0.05*vel[5])
    direction = np.where(composite >= 0.0, 1, -1)

    # 12-bar window statistics (bars i-11 .. i)
    range12 = np.full(n, np.nan); range3 = np.full(n, np.nan)
    aligned = np.zeros(n); high12 = np.full(n, np.nan); low12 = np.full(n, np.nan)
    trc = np.concatenate([[0.0], np.cumsum(tr)])
    valid12 = idx >= 11
    range12 = np.where(valid12, trc[idx+1] - trc[np.maximum(idx-11, 0)], np.nan)
    range3  = np.where(idx >= 2, trc[idx+1] - trc[np.maximum(idx-2, 0)], np.nan)
    body = c - o
    up = (body > 0).astype(float); dn = (body < 0).astype(float)
    upc = np.concatenate([[0.0], np.cumsum(up)]); dnc = np.concatenate([[0.0], np.cumsum(dn)])
    nup = np.where(valid12, upc[idx+1] - upc[np.maximum(idx-11, 0)], np.nan)
    ndn = np.where(valid12, dnc[idx+1] - dnc[np.maximum(idx-11, 0)], np.nan)
    aligned = np.where(direction > 0, nup, ndn)
    sw = np.lib.stride_tricks.sliding_window_view
    high12[11:] = sw(h, 12).max(axis=1)
    low12[11:]  = sw(l, 12).min(axis=1)

    range3 = np.maximum(range3, 0.01); range12 = np.maximum(range12, 0.01)
    with np.errstate(invalid="ignore", divide="ignore"):
        eff3 = np.abs(net(3, idx)) / range3
        eff12 = np.abs(net(12, idx)) / range12
        persist12 = aligned / 12.0
        recent3 = net(3, idx) / 3.0
        j11 = idx - 11; j3 = idx - 3
        prior9 = np.where(j11 >= 0, (c[np.maximum(j3, 0)] - o[np.maximum(j11, 0)]) / 9.0, np.nan)
        accel = direction * (recent3 - prior9) / atr12
        shock = tr / atr12
        volratio = atr12 / np.maximum(atr48, 0.01)
        pullback = np.where(direction > 0, (c - high12) / atr12, (low12 - c) / atr12)
        coherence = (direction * vel > 0.0).sum(axis=0) / 6.0

    # ---- H4 leg -------------------------------------------------------------
    h4t = h4.t.to_numpy("datetime64[s]").astype(np.int64)
    h4o, h4h, h4l, h4c = (h4[x].to_numpy(float) for x in "ohlc")
    h4tr = true_range(h4h, h4l, h4c)
    h4atr14 = rolling_atr(h4tr, 14)
    e8 = ema(h4c, 8); e21 = ema(h4c, 21)

    decision_close = t + 300                      # close time of the signal M5 bar
    k = np.searchsorted(h4t, decision_close, side="right") - 1   # iBarShift(exact=false)
    hs = k - 1                                    # h4Shift = containingH4 + 1
    h4_ok = (k >= 0) & (hs >= 22)                 # mirrors h4Shift+22 < iBars(H4)

    safe = np.clip(hs, 0, len(h4t) - 1); safe1 = np.clip(hs - 1, 0, len(h4t) - 1)
    h4atr = np.where(h4_ok, h4atr14[safe], 0.0)
    with np.errstate(invalid="ignore", divide="ignore"):
        h4gap   = direction * (e8[safe] - e21[safe]) / h4atr
        h4slope = direction * (e8[safe] - e8[safe1]) / h4atr
        h4body  = direction * (h4c[safe] - h4o[safe]) / h4atr
    age_h = (decision_close - (h4t[safe] + 4*3600)) / 3600.0

    F = np.vstack([np.abs(composite), direction*vel[0], direction*vel[1], direction*vel[2],
                   direction*vel[3], direction*vel[4], direction*vel[5], eff3, eff12,
                   persist12, accel, shock, volratio, pullback, coherence,
                   h4gap, h4slope, h4body]).T

    Z = (F - MEAN) / SCALE
    p10 = sigmoid_clamped(Z @ W_P10 + B_P10)
    p20 = np.minimum(p10, sigmoid_clamped(Z @ W_P20 + B_P20))
    p30 = np.minimum(p20, sigmoid_clamped(Z @ W_P30 + B_P30))
    pbad = sigmoid_clamped(Z @ W_BAD + B_BAD)

    valid = (idx >= REQUIRED_M5_BARS) & h4_ok & (atr12 > 0) & (atr48 > 0) & (h4atr > 0) \
            & (age_h >= 0.0) & (age_h <= 12.0) & np.isfinite(F).all(axis=1)

    if require_contiguous:
        # The MQL code reads bars i-48..i and H4 bars hs-22..hs. MT4 would happily
        # span a data hole; we exclude those windows and count them separately.
        gap5 = np.full(n, False)
        dt = np.diff(t, prepend=t[0])
        bad = (dt != 300)
        badc = np.cumsum(bad)
        span = np.where(idx >= 48, badc[idx] - badc[np.maximum(idx-48, 0)], 1)
        gap5 = span > 0
        valid = valid & ~gap5
    else:
        gap5 = np.zeros(n, bool)

    return pd.DataFrame({
        "t": m5.t, "valid": valid, "direction": direction, "ref_entry": c,
        "p10": p10, "p20": p20, "p30": p30, "pbad": pbad,
        "eff12": eff12, "strength": np.abs(composite), "shock": shock,
        "accel": accel, "coherence": coherence,
        "h4gap": h4gap, "h4slope": h4slope, "h4body": h4body,
        "atr12": atr12, "h4age": age_h, "spans_gap": gap5,
    })


def qualify(sig, min_p30=0.20, min_p10=0.70, max_bad=1.00, min_edge=-0.30,
            min_eff=0.05, max_shock=2.50, max_strength=2.50, require_h4=True):
    h4ok = (sig.h4gap > 0.0) if require_h4 else pd.Series(True, index=sig.index)
    return (sig.valid
            & (sig.p30 >= min_p30) & (sig.p10 >= min_p10)
            & (sig.pbad <= max_bad) & ((sig.p30 - sig.pbad) >= min_edge)
            & h4ok & (sig.eff12 >= min_eff)
            & (sig.strength >= 0.10) & (sig.strength <= max_strength)
            & (sig.shock <= max_shock))
