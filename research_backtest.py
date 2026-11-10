#!/usr/bin/env python3
"""BTC-USDT perpetual research backtest: ML vs MACD+Ichimoku vs combined.

Uses chronological train/validation/test splits. The test segment is never used
for fitting or threshold selection. Research only; no orders are sent.
"""
import argparse
import json
import time
from pathlib import Path

import numpy as np
import pandas as pd
import requests
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, balanced_accuracy_score, classification_report

BASE = "https://fapi.binance.com"
FEATURES = ["ema_gap_pct", "rsi_centered", "macd_hist_pct", "return_3_pct",
            "return_10_pct", "atr_pct", "volume_z", "ichi_distance_pct",
            "tenkan_kijun_pct"]
CLASSES = [-1, 0, 1]  # DOWN, NEUTRAL, UP


def get_json(path, params):
    r = requests.get(BASE + path, params=params, timeout=30)
    r.raise_for_status()
    data = r.json()
    if isinstance(data, dict) and data.get("code"):
        raise RuntimeError(f"Binance API: {data}")
    return data


def fetch_klines(symbol, interval, years):
    end = int(time.time() * 1000)
    start = end - int(years * 365.25 * 24 * 60 * 60 * 1000)
    cursor, rows = start, []
    while cursor < end:
        batch = get_json("/fapi/v1/klines", {
            "symbol": symbol, "interval": interval, "startTime": cursor,
            "endTime": end, "limit": 1500})
        if not batch:
            break
        rows.extend(batch)
        nxt = int(batch[-1][0]) + 1
        if nxt <= cursor:
            break
        cursor = nxt
        if len(batch) < 1500:
            break
        time.sleep(0.12)
    if not rows:
        raise RuntimeError("No historical candles received")
    cols = ["time", "open", "high", "low", "close", "volume", "close_time",
            "quote_volume", "trades", "taker_base", "taker_quote", "ignore"]
    df = pd.DataFrame(rows, columns=cols)
    df = df.drop_duplicates("time").sort_values("time").reset_index(drop=True)
    for c in ["open", "high", "low", "close", "volume"]:
        df[c] = df[c].astype(float)
    df["time"] = pd.to_datetime(df["time"], unit="ms", utc=True)
    return df[["time", "open", "high", "low", "close", "volume"]]


def fetch_funding(symbol, start_ms, end_ms):
    cursor, rows = start_ms, []
    while cursor < end_ms:
        batch = get_json("/fapi/v1/fundingRate", {
            "symbol": symbol, "startTime": cursor, "endTime": end_ms, "limit": 1000})
        if not batch:
            break
        rows.extend(batch)
        nxt = int(batch[-1]["fundingTime"]) + 1
        if nxt <= cursor:
            break
        cursor = nxt
        if len(batch) < 1000:
            break
        time.sleep(0.12)
    if not rows:
        return pd.DataFrame({"time": pd.Series(dtype="datetime64[ns, UTC]"), "rate": pd.Series(dtype=float)})
    f = pd.DataFrame(rows)
    f["time"] = pd.to_datetime(f["fundingTime"].astype("int64"), unit="ms", utc=True)
    f["rate"] = f["fundingRate"].astype(float)
    return f[["time", "rate"]].drop_duplicates("time").sort_values("time")


def mid(high, low, period):
    return (high.rolling(period).max() + low.rolling(period).min()) / 2


def make_features(df, horizon, threshold):
    c, h, l, v = df.close, df.high, df.low, df.volume
    ema9, ema21 = c.ewm(span=9, adjust=False).mean(), c.ewm(span=21, adjust=False).mean()
    delta = c.diff()
    gain = delta.clip(lower=0).rolling(14).mean()
    loss = (-delta.clip(upper=0)).rolling(14).mean()
    rs = gain / loss.replace(0, np.nan)
    rsi = (100 - 100 / (1 + rs)).fillna(50)
    macd = c.ewm(span=12, adjust=False).mean() - c.ewm(span=26, adjust=False).mean()
    macd_signal = macd.ewm(span=9, adjust=False).mean()
    tr = pd.concat([h-l, (h-c.shift()).abs(), (l-c.shift()).abs()], axis=1).max(axis=1)
    atr = tr.rolling(14).mean()
    vol_std = v.rolling(30).std().replace(0, np.nan)
    tenkan, kijun = mid(h, l, 9), mid(h, l, 26)
    span_a = ((tenkan + kijun) / 2).shift(26)
    span_b = mid(h, l, 52).shift(26)
    cloud_top = pd.concat([span_a, span_b], axis=1).max(axis=1)
    cloud_bottom = pd.concat([span_a, span_b], axis=1).min(axis=1)
    x = pd.DataFrame({
        "ema_gap_pct": (ema9-ema21)/c*100,
        "rsi_centered": (rsi-50)/50,
        "macd_hist_pct": (macd-macd_signal)/c*100,
        "return_3_pct": (c/c.shift(3)-1)*100,
        "return_10_pct": (c/c.shift(10)-1)*100,
        "atr_pct": atr/c*100,
        "volume_z": (v-v.rolling(30).mean())/vol_std,
        "ichi_distance_pct": (c-(cloud_top+cloud_bottom)/2)/c*100,
        "tenkan_kijun_pct": (tenkan-kijun)/c*100,
    })
    # Ichimoku/MACD rule signals are known at candle close, executed next open.
    ichi = np.where((c > cloud_top) & (tenkan > kijun), 1,
           np.where((c < cloud_bottom) & (tenkan < kijun), -1, 0))
    macd_dir = np.sign(macd-macd_signal)
    rule = np.where((ichi == 1) & (macd_dir > 0), 1,
           np.where((ichi == -1) & (macd_dir < 0), -1, 0))
    future = (c.shift(-horizon)/c-1)*100
    y = np.where(future > threshold, 1, np.where(future < -threshold, -1, 0))
    out = df.copy()
    out[FEATURES] = x
    out["label"] = y
    out["rule_signal"] = rule
    out["atr"] = atr
    out["valid_future"] = future.notna()
    out = out.replace([np.inf, -np.inf], np.nan)
    out = out.dropna(subset=FEATURES + ["atr"]).reset_index(drop=True)
    return out


def signals_ml(model, x, threshold):
    probs = model.predict_proba(x)
    classes = list(model.classes_)
    result = np.zeros(len(x), dtype=int)
    for i, row in enumerate(probs):
        best = int(np.argmax(row))
        cls = int(classes[best])
        if cls != 0 and float(row[best]) >= threshold:
            result[i] = cls
    return result


def run_backtest(frame, signals, funding, horizon, fee, slippage, initial, label):
    # Single concurrent position; entry next candle open; conservative stop-first
    # if SL and TP are both touched within one OHLC candle.
    trades, equity, peak, max_dd = [], float(initial), float(initial), 0.0
    i, n = 0, len(frame)
    while i < n-1:
        side = int(signals[i])
        if side == 0:
            i += 1
            continue
        entry_i = i + 1
        entry_bar = frame.iloc[entry_i]
        raw_entry = float(entry_bar.open)
        direction = 1 if side > 0 else -1
        entry = raw_entry * (1 + direction*slippage)
        atr = float(frame.iloc[i].atr)
        risk_dist = max(1.6*atr, entry*0.003)
        stop = entry - direction*risk_dist
        target = entry + direction*1.5*risk_dist
        # 1x notional exposure; position size is fixed from current equity.
        notional = equity
        qty = notional / entry
        exit_i = min(entry_i+horizon, n-1)
        exit_price, reason = float(frame.iloc[exit_i].close), "TIME"
        for j in range(entry_i, min(entry_i+horizon+1, n)):
            bar = frame.iloc[j]
            if direction > 0:
                hit_sl, hit_tp = float(bar.low) <= stop, float(bar.high) >= target
            else:
                hit_sl, hit_tp = float(bar.high) >= stop, float(bar.low) <= target
            if hit_sl:
                exit_i, exit_price, reason = j, stop, "SL"
                break
            if hit_tp:
                exit_i, exit_price, reason = j, target, "TP"
                break
        exit_price *= (1 - direction*slippage)
        gross = (exit_price-entry)*qty*direction
        fees = (entry*qty + exit_price*qty)*fee
        entry_time, exit_time = frame.iloc[entry_i].time, frame.iloc[exit_i].time
        fr = funding[(funding.time > entry_time) & (funding.time <= exit_time)]
        # Positive funding: longs pay, shorts receive. Approximate funding notional
        # with entry notional; exact exchange mark-price reconstruction is unavailable.
        funding_pnl = float((-direction * fr.rate * notional).sum()) if len(fr) else 0.0
        net = gross - fees + funding_pnl
        equity += net
        peak = max(peak, equity)
        dd = (peak-equity)/peak if peak else 0.0
        max_dd = max(max_dd, dd)
        trades.append({"strategy": label, "side": "LONG" if direction > 0 else "SHORT",
                       "entry_time": entry_time.isoformat(), "exit_time": exit_time.isoformat(),
                       "entry": entry, "exit": exit_price, "exit_reason": reason,
                       "gross_pnl_usdt": gross, "fees_usdt": fees,
                       "funding_pnl_usdt": funding_pnl, "net_pnl_usdt": net,
                       "equity_usdt": equity})
        i = exit_i + 1
    pnl = [t["net_pnl_usdt"] for t in trades]
    wins = sum(x > 0 for x in pnl)
    gross_profit = sum(x for x in pnl if x > 0)
    gross_loss = -sum(x for x in pnl if x < 0)
    return {"strategy": label, "trades": len(trades), "wins": wins,
            "win_rate_pct": 100*wins/len(trades) if trades else 0.0,
            "net_profit_usdt": sum(pnl), "return_pct": (equity/initial-1)*100,
            "profit_factor": gross_profit/gross_loss if gross_loss else (None if not gross_profit else "Infinity"),
            "max_drawdown_pct": max_dd*100, "ending_equity_usdt": equity,
            "fees_usdt": sum(t["fees_usdt"] for t in trades),
            "funding_pnl_usdt": sum(t["funding_pnl_usdt"] for t in trades)}, trades


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="BTCUSDT")
    ap.add_argument("--interval", default="1h")
    ap.add_argument("--years", type=float, default=3.0)
    ap.add_argument("--horizon", type=int, default=12)
    ap.add_argument("--label-threshold", type=float, default=0.5)
    ap.add_argument("--initial", type=float, default=10000.0)
    ap.add_argument("--fee", type=float, default=0.0004, help="taker fee per side, 0.0004 = 0.04%")
    ap.add_argument("--slippage", type=float, default=0.0002, help="adverse slippage per side, 0.0002 = 0.02%")
    ap.add_argument("--out", default="research_output")
    args = ap.parse_args()

    print(f"Downloading {args.symbol} {args.interval}, approximately {args.years} years...")
    raw = fetch_klines(args.symbol, args.interval, args.years)
    start_ms, end_ms = int(raw.time.iloc[0].timestamp()*1000), int(raw.time.iloc[-1].timestamp()*1000)
    funding = fetch_funding(args.symbol, start_ms, end_ms)
    data = make_features(raw, args.horizon, args.label_threshold)
    data = data[data.valid_future].reset_index(drop=True)
    if len(data) < 3000:
        raise RuntimeError(f"Only {len(data)} usable rows. Increase --years or check API access.")

    n = len(data)
    train_end, val_end = int(n*0.70), int(n*0.85)
    # Purge the final horizon bars from train/validation so their forward labels
    # cannot reach into the next chronological partition.
    train = data.iloc[:train_end-args.horizon]
    val = data.iloc[train_end:val_end-args.horizon]
    test = data.iloc[val_end:]
    model = RandomForestClassifier(n_estimators=400, max_depth=8, min_samples_leaf=12,
                                   max_features="sqrt", class_weight="balanced_subsample",
                                   random_state=42, n_jobs=-1)
    model.fit(train[FEATURES], train.label.astype(int))
    val_pred = model.predict(val[FEATURES])
    thresholds = [0.38, 0.42, 0.46, 0.50, 0.54, 0.58]
    best_threshold, best_score = 0.50, -float("inf")
    val_funding = funding[(funding.time >= val.time.iloc[0]) & (funding.time <= val.time.iloc[-1])]
    for th in thresholds:
        val_sig = signals_ml(model, val[FEATURES], th)
        stats, _ = run_backtest(val, val_sig, val_funding, args.horizon, args.fee,
                                args.slippage, args.initial, "ML-validation")
        score = stats["net_profit_usdt"]
        if stats["trades"] >= 5 and score > best_score:
            best_threshold, best_score = th, score

    test_funding = funding[(funding.time >= test.time.iloc[0]) & (funding.time <= test.time.iloc[-1])]
    ml_sig = signals_ml(model, test[FEATURES], best_threshold)
    rule_sig = test.rule_signal.to_numpy(dtype=int)
    combo_sig = np.where((ml_sig != 0) & (ml_sig == rule_sig), ml_sig, 0)
    strategies = [("ML", ml_sig), ("MACD + Ichimoku", rule_sig),
                  ("ML + MACD + Ichimoku", combo_sig)]
    reports, all_trades = [], []
    for name, sig in strategies:
        stats, trades = run_backtest(test, sig, test_funding, args.horizon,
                                     args.fee, args.slippage, args.initial, name)
        reports.append(stats)
        all_trades.extend(trades)

    yhat = model.predict(test[FEATURES])
    output = {
        "title": "BTC-USDT out-of-sample strategy comparison",
        "symbol": args.symbol, "interval": args.interval,
        "data_rows": n, "train_rows": len(train), "validation_rows": len(val),
        "test_rows": len(test), "train_start": train.time.iloc[0].isoformat(),
        "train_end": train.time.iloc[-1].isoformat(),
        "validation_start": val.time.iloc[0].isoformat(),
        "validation_end": val.time.iloc[-1].isoformat(),
        "test_start": test.time.iloc[0].isoformat(), "test_end": test.time.iloc[-1].isoformat(),
        "split": "70% train / 15% validation / 15% untouched test (chronological)",
        "label": f"{args.horizon}-bar forward return: UP > +{args.label_threshold}%, DOWN < -{args.label_threshold}%, otherwise NEUTRAL",
        "model": "RandomForestClassifier, 400 trees, max_depth=8",
        "ml_confidence_threshold_selected_on_validation": best_threshold,
        "test_accuracy": float(accuracy_score(test.label.astype(int), yhat)),
        "test_balanced_accuracy": float(balanced_accuracy_score(test.label.astype(int), yhat)),
        "cost_assumptions": {"taker_fee_each_side_pct": args.fee*100,
                             "slippage_each_side_pct": args.slippage*100,
                             "funding": "historical Binance fundingRate events; positive rate costs longs and pays shorts",
                             "funding_notional": "approximated using entry notional"},
        "execution_assumptions": {"entry": "next candle open, adverse slippage",
                                  "exit": "SL/TP or max holding horizon; stop first if both touched",
                                  "take_profit": "1.5R", "stop_loss": "1R",
                                  "max_holding_bars": args.horizon,
                                  "exposure": "1x current equity, one position at a time",
                                  "initial_equity_usdt": args.initial},
        "strategies": reports,
        "test_classification_report": classification_report(test.label.astype(int), yhat,
            labels=CLASSES, target_names=["DOWN", "NEUTRAL", "UP"], output_dict=True, zero_division=0)
    }
    outdir = Path(args.out); outdir.mkdir(parents=True, exist_ok=True)
    (outdir/"backtest_report.json").write_text(json.dumps(output, indent=2, ensure_ascii=False), encoding="utf-8")
    pd.DataFrame(all_trades).to_csv(outdir/"backtest_trades.csv", index=False)
    print(json.dumps({"report": str(outdir/"backtest_report.json"), "trades": str(outdir/"backtest_trades.csv"),
                      "strategies": reports}, indent=2, ensure_ascii=False))

if __name__ == "__main__":
    main()
