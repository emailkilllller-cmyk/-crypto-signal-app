"""Train a small logistic-regression classifier on historical Binance Futures candles.
This is a research pipeline, not financial advice. It uses time-ordered splits.

Run: python train_model.py --symbols BTCUSDT ETHUSDT SOLUSDT --interval 1h --limit 1500
Dependencies: requests, numpy, pandas, scikit-learn
Output: ../assets/model_weights.json (Dart-compatible raw-feature coefficients)
"""
import argparse, json, os, time
import numpy as np
import pandas as pd
import requests
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, precision_score, recall_score, roc_auc_score

FEATURES = ['ema_gap_pct','rsi_centered','macd_hist_pct','return_3_pct','return_10_pct','atr_pct','volume_z']

def fetch(symbol, interval, limit):
    rows=[]; end=None
    while len(rows)<limit:
        params={'symbol':symbol,'interval':interval,'limit':min(1500,limit-len(rows))}
        if end is not None: params['endTime']=end
        r=requests.get('https://fapi.binance.com/fapi/v1/klines',params=params,timeout=20); r.raise_for_status()
        batch=r.json()
        if not batch: break
        rows=batch+rows; end=batch[0][0]-1
        if len(batch)<2: break
        time.sleep(.15)
    rows=rows[-limit:]
    return pd.DataFrame(rows,columns=['time','open','high','low','close','volume','close_time','qvol','trades','tb_base','tb_quote','ignore'])

def features(df):
    c=df.close.astype(float); h=df.high.astype(float); l=df.low.astype(float); v=df.volume.astype(float)
    ema9=c.ewm(span=9,adjust=False).mean(); ema21=c.ewm(span=21,adjust=False).mean()
    d=c.diff(); gain=d.clip(lower=0).rolling(14).mean(); loss=(-d.clip(upper=0)).rolling(14).mean(); rs=gain/(loss.replace(0,np.nan))
    rsi=100-100/(1+rs); rsi=rsi.fillna(100)
    macd=c.ewm(span=12,adjust=False).mean()-c.ewm(span=26,adjust=False).mean(); sig=macd.ewm(span=9,adjust=False).mean()
    prev=c.shift(1); tr=pd.concat([h-l,(h-prev).abs(),(l-prev).abs()],axis=1).max(axis=1); atr=tr.rolling(14).mean()
    volstd=v.rolling(30).std().replace(0,np.nan); volz=(v-v.rolling(30).mean())/volstd
    x=pd.DataFrame({'ema_gap_pct':(ema9-ema21)/c*100,'rsi_centered':(rsi-50)/50,'macd_hist_pct':(macd-sig)/c*100,
      'return_3_pct':(c/c.shift(3)-1)*100,'return_10_pct':(c/c.shift(10)-1)*100,'atr_pct':atr/c*100,'volume_z':volz})
    return x

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--symbols',nargs='+',default=['BTCUSDT','ETHUSDT','SOLUSDT','BNBUSDT']); ap.add_argument('--interval',default='1h'); ap.add_argument('--limit',type=int,default=1500); ap.add_argument('--horizon',type=int,default=12); ap.add_argument('--threshold',type=float,default=0.5); args=ap.parse_args()
    frames=[]
    for sym in args.symbols:
        try:
            df=fetch(sym,args.interval,args.limit); x=features(df); c=df.close.astype(float)
            future=(c.shift(-args.horizon)/c-1)*100
            # Binary target: price rose beyond threshold over the forward horizon.
            y=(future>args.threshold).astype(int)
            z=x.copy(); z['target']=y; z['time']=df.time.astype('int64'); z['symbol']=sym; z=z.dropna(); z=z.iloc[:-args.horizon]
            frames.append(z); print(f'{sym}: {len(z)} usable rows')
        except Exception as e: print(f'{sym} failed: {e}')
    if not frames: raise SystemExit('No usable data downloaded. Check API/network.')
    data=pd.concat(frames,ignore_index=True).sort_values('time'); X=data[FEATURES].values; y=data.target.values
    n=len(data); a=int(n*.70); b=int(n*.85); Xtr,ytr=X[:a],y[:a]; Xval,yval=X[a:b],y[a:b]; Xtest,ytest=X[b:],y[b:]
    scaler=StandardScaler(); XtrS=scaler.fit_transform(Xtr); XvalS=scaler.transform(Xval); XtestS=scaler.transform(Xtest)
    model=LogisticRegression(max_iter=2000,class_weight='balanced'); model.fit(XtrS,ytr)
    pred=model.predict(XtestS); prob=model.predict_proba(XtestS)[:,1]
    print('Temporal holdout metrics (not a trading backtest):')
    print('accuracy=',round(accuracy_score(ytest,pred),4),'precision=',round(precision_score(ytest,pred,zero_division=0),4),'recall=',round(recall_score(ytest,pred,zero_division=0),4))
    try: print('ROC-AUC=',round(roc_auc_score(ytest,prob),4))
    except Exception: pass
    w=model.coef_[0]/scaler.scale_; bias=model.intercept_[0]-float(np.sum(model.coef_[0]*scaler.mean_/scaler.scale_))
    out={'status':'trained','model':'logistic_regression','features':FEATURES,'bias':float(bias),'weights':[float(v) for v in w],
      'training_symbols':args.symbols,'interval':args.interval,'rows':int(n),'horizon_candles':args.horizon,'label_threshold_pct':args.threshold,
      'temporal_split':'70% train / 15% validation / 15% test','test_accuracy':float(accuracy_score(ytest,pred)),
      'test_precision':float(precision_score(ytest,pred,zero_division=0)),'test_recall':float(recall_score(ytest,pred,zero_division=0))}
    target=os.path.join(os.path.dirname(__file__),'..','assets','model_weights.json'); os.makedirs(os.path.dirname(target),exist_ok=True)
    with open(target,'w',encoding='utf-8') as f: json.dump(out,f,ensure_ascii=False,indent=2)
    print('Saved trained weights to',os.path.abspath(target)); print('Rebuild app after replacing the asset. Validate with paper trading before real use.')
if __name__=='__main__': main()
