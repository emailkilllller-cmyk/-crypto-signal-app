import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const CryptoSignalApp());

class CryptoSignalApp extends StatelessWidget {
  const CryptoSignalApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Crypto Signal Lab',
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xFF10141C),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF35C99A), brightness: Brightness.dark),
    ),
    home: const HomePage(),
  );
}

class Candle {
  final int time;
  final double open, high, low, close, volume;
  const Candle(this.time, this.open, this.high, this.low, this.close, this.volume);
}
class Signal {
  final String symbol, interval, side, reason;
  final DateTime time;
  final double entry, sl, tp1, tp2, rsi, atr, probability;
  final int score; final String outcome;
  Signal({this.outcome='PENDING',required this.symbol, required this.interval, required this.side, required this.reason,
    required this.time, required this.entry, required this.sl, required this.tp1, required this.tp2,
    required this.rsi, required this.atr, required this.probability, required this.score});
  Map<String, dynamic> toJson() => {
    'symbol':symbol,'interval':interval,'side':side,'reason':reason,'time':time.toIso8601String(),
    'entry':entry,'sl':sl,'tp1':tp1,'tp2':tp2,'rsi':rsi,'atr':atr,'probability':probability,'score':score,'outcome':outcome
  };
  factory Signal.fromJson(Map<String,dynamic> j) => Signal(
    symbol:j['symbol'], interval:j['interval'], side:j['side'], reason:j['reason'] ?? '',
    time:DateTime.tryParse(j['time'] ?? '') ?? DateTime.now(), entry:(j['entry'] as num).toDouble(),
    sl:(j['sl'] as num).toDouble(), tp1:(j['tp1'] as num).toDouble(), tp2:(j['tp2'] as num).toDouble(),
    rsi:(j['rsi'] as num).toDouble(), atr:(j['atr'] as num).toDouble(),
    probability:(j['probability'] as num).toDouble(), score:(j['score'] as num).toInt(), outcome:j['outcome'] ?? 'PENDING');
}


class NoEntryRecord {
  final String symbol, interval;
  final DateTime time;
  final double entry, probability;
  final int score;
  final List<String> reasons;
  NoEntryRecord({required this.symbol,required this.interval,required this.time,
    required this.entry,required this.probability,required this.score,required this.reasons});
  Map<String,dynamic> toJson()=>{'symbol':symbol,'interval':interval,'time':time.toIso8601String(),
    'entry':entry,'probability':probability,'score':score,'reasons':reasons};
  factory NoEntryRecord.fromJson(Map<String,dynamic> j)=>NoEntryRecord(
    symbol:j['symbol']??'',interval:j['interval']??'',
    time:DateTime.tryParse(j['time']??'')??DateTime.now(),
    entry:(j['entry'] as num?)?.toDouble()??0,
    probability:(j['probability'] as num?)?.toDouble()??0.5,
    score:(j['score'] as num?)?.toInt()??0,
    reasons:(j['reasons'] as List? ?? const []).map((e)=>e.toString()).toList());
}

class PaperTrade {
  final String id, symbol, side, status;
  final DateTime opened;
  final double entry, sl, tp1, qty, pnl, margin, entryFee, leverage;
  PaperTrade({required this.id,required this.symbol,required this.side,required this.status,required this.opened,
    required this.entry,required this.sl,required this.tp1,required this.qty,required this.pnl,
    this.margin=0,this.entryFee=0,this.leverage=1});
  Map<String,dynamic> toJson()=>{'id':id,'symbol':symbol,'side':side,'status':status,'opened':opened.toIso8601String(),
    'entry':entry,'sl':sl,'tp1':tp1,'qty':qty,'pnl':pnl,'margin':margin,'entryFee':entryFee,'leverage':leverage};
  factory PaperTrade.fromJson(Map<String,dynamic> j)=>PaperTrade(id:j['id'],symbol:j['symbol'],side:j['side'],status:j['status'],
    opened:DateTime.tryParse(j['opened']??'')??DateTime.now(),entry:(j['entry'] as num).toDouble(),sl:(j['sl'] as num).toDouble(),
    tp1:(j['tp1'] as num).toDouble(),qty:(j['qty'] as num).toDouble(),pnl:(j['pnl'] as num).toDouble(),
    margin:(j['margin'] as num?)?.toDouble()??((j['qty'] as num).toDouble()*(j['entry'] as num).toDouble()),entryFee:(j['entryFee'] as num?)?.toDouble()??0,leverage:(j['leverage'] as num?)?.toDouble()??1);
}

class MarketApi {
  static const intervals=['5m','15m','1h','4h','1d'];
  static String _okxBar(String tf)=>({'5m':'5m','15m':'15m','1h':'1H','4h':'4H','1d':'1D'}[tf] ?? '15m');
  static Future<List<String>> symbols() async {
    // Exchange contracts are dynamically discovered; curated names are fallback only.
    try {
      final r=await http.get(Uri.https('fapi.binance.com','/fapi/v1/exchangeInfo')).timeout(const Duration(seconds:12));
      if(r.statusCode==200){final data=jsonDecode(r.body); final eligible=(data['symbols'] as List)
        .where((x)=>x['status']=='TRADING' && x['contractType']=='PERPETUAL' && x['quoteAsset']=='USDT')
        .map<String>((x)=>'${x['baseAsset']}-USDT').toSet();
        final t=await http.get(Uri.https('fapi.binance.com','/fapi/v1/ticker/24hr')).timeout(const Duration(seconds:12));
        if(t.statusCode==200){final rows=jsonDecode(t.body) as List; rows.sort((a,b)=>double.parse('${b['quoteVolume']}').compareTo(double.parse('${a['quoteVolume']}'))); final liquid=rows.map<String>((x)=>'${x['symbol'].toString().replaceAll('USDT','')}-USDT').where(eligible.contains).take(60).toList(); final preferred=['BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','LINK-USDT','AVAX-USDT','ADA-USDT','DOGE-USDT','TON-USDT']; final combined=[...preferred.where(eligible.contains),...liquid.where((x)=>!preferred.contains(x))]; if(combined.isNotEmpty)return combined;}
        final list=eligible.toList()..sort(); if(list.isNotEmpty)return list;}
    } catch (_) {}
    return ['BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','LINK-USDT','AVAX-USDT','DOGE-USDT','ADA-USDT','TON-USDT'];
  }
  static Future<List<Candle>> candles(String symbol,String tf,{int limit=500}) async {
    final s=symbol.replaceAll('-','');
    try {
      final r=await http.get(Uri.https('fapi.binance.com','/fapi/v1/klines',{'symbol':s,'interval':tf,'limit':'$limit'})).timeout(const Duration(seconds:15));
      if(r.statusCode==200){final rows=jsonDecode(r.body) as List; if(rows.length>=math.min(limit,30)) return rows.map<Candle>((e)=>Candle((e[0] as num).toInt(),double.parse('${e[1]}'),double.parse('${e[2]}'),double.parse('${e[3]}'),double.parse('${e[4]}'),double.parse('${e[5]}'))).toList();}
    } catch (_) {}
    final inst='$symbol-SWAP';
    final r=await http.get(Uri.https('www.okx.com','/api/v5/market/candles',{'instId':inst,'bar':_okxBar(tf),'limit':'$limit'})).timeout(const Duration(seconds:15));
    if(r.statusCode!=200) throw Exception('OKX HTTP ${r.statusCode}');
    final j=jsonDecode(r.body); final rows=j['data'];
    if(j['code']!='0'||rows is! List||rows.length<math.min(limit,30)) throw Exception('No candles / API ${j['msg']}');
    return rows.map<Candle>((e)=>Candle(int.parse('${e[0]}'),double.parse('${e[1]}'),double.parse('${e[2]}'),double.parse('${e[3]}'),double.parse('${e[4]}'),double.parse('${e[5]}'))).toList().reversed.toList();
  }
}

class Indicators {
  static double ema(List<double> x,int p){if(x.isEmpty)return 0;final k=2/(p+1);double v=x.first;for(int i=1;i<x.length;i++)v=x[i]*k+v*(1-k);return v;}
  static double rsi(List<double> c,int p){if(c.length<=p)return 50; double g=0,l=0; for(int i=c.length-p;i<c.length;i++){final d=c[i]-c[i-1];if(d>=0)g+=d;else l-=d;} if(l==0)return 100;return 100-100/(1+(g/p)/(l/p));}
  static double atr(List<Candle> cs,int p){if(cs.length<=p)return 0;double s=0;for(int i=cs.length-p;i<cs.length;i++){final prev=cs[i-1].close; s+=math.max(cs[i].high-cs[i].low,math.max((cs[i].high-prev).abs(),(cs[i].low-prev).abs())).toDouble();}return s/p;}
  static List<double> emaSeries(List<double> x,int p){final out=List<double>.filled(x.length,0);if(x.isEmpty)return out;final k=2/(p+1);double v=x.first;out[0]=v;for(int i=1;i<x.length;i++){v=x[i]*k+v*(1-k);out[i]=v;}return out;}
  static double macdHist(List<double> c){if(c.length<35)return 0;final f=emaSeries(c,12),s=emaSeries(c,26);final line=List<double>.generate(c.length,(i)=>f[i]-s[i]);final sig=emaSeries(line.sublist(25),9);return line.last-sig.last;}
  static double _midpoint(List<Candle> cs,int end,int period){
    if(end+1<period||end<0)return 0;
    double hi=-double.infinity,lo=double.infinity;
    for(int i=end-period+1;i<=end;i++){hi=math.max(hi,cs[i].high).toDouble();lo=math.min(lo,cs[i].low).toDouble();}
    return (hi+lo)/2;
  }
  // Ichimoku cloud at the current candle: spans are calculated 26 candles earlier
  // because Senkou spans are projected 26 candles forward on the chart.
  static int ichimokuScore(List<Candle> cs){
    if(cs.length<78)return 0;
    final last=cs.length-1, cloudAt=last-26, price=cs[last].close;
    final tenkan=_midpoint(cs,last,9), kijun=_midpoint(cs,last,26);
    final spanA=(_midpoint(cs,cloudAt,9)+_midpoint(cs,cloudAt,26))/2;
    final spanB=_midpoint(cs,cloudAt,52);
    final top=math.max(spanA,spanB).toDouble(), bottom=math.min(spanA,spanB).toDouble();
    int score=0;
    if(price>top)score++;else if(price<bottom)score--;
    if(tenkan>kijun)score++;else if(tenkan<kijun)score--;
    if(spanA>spanB)score++;else if(spanA<spanB)score--;
    return score;
  }
  // Experimental conservative filter: MACD must agree and Ichimoku must not oppose.
  static String applyExperimentalFilter(String side,List<Candle> cs){
    if(side!='LONG'&&side!='SHORT')return side;
    final closes=cs.map((x)=>x.close).toList();
    final macd=macdHist(closes), ichi=ichimokuScore(cs);
    if(side=='LONG'&&(macd<=0||ichi<0))return 'WAIT';
    if(side=='SHORT'&&(macd>=0||ichi>0))return 'WAIT';
    return side;
  }
  static int trendScore(List<Candle> cs){
    if(cs.length<35)return 0; final c=cs.map((x)=>x.close).toList(); final e9=ema(c,9),e21=ema(c,21),r=rsi(c,14); int score=0;
    if(e9>e21)score+=2;else if(e9<e21)score-=2;
    if(c.last>e9)score++;else if(c.last<e9)score--;
    if(r>55)score++;else if(r<45)score--;
    final m=macdHist(c); if(m>0)score++;else if(m<0)score--; return score;
  }
  static List<double> features(List<Candle> cs){final c=cs.map((e)=>e.close).toList(); final price=c.last; final e9=ema(c,9),e21=ema(c,21),r=rsi(c,14),a=atr(cs,14); final ret3=(price/c[c.length-4]-1)*100, ret10=(price/c[c.length-11]-1)*100; final vol=cs.skip(cs.length>30?cs.length-30:0).map((x)=>x.volume).toList(); final avg=vol.reduce((x,y)=>x+y)/vol.length; final sd=math.sqrt(vol.map((x)=>(x-avg)*(x-avg)).reduce((x,y)=>x+y)/vol.length); final vz=sd==0?0:(vol.last-avg)/sd;
    return [(e9-e21)/price*100,(r-50)/50,(macdHist(c)/price)*100,ret3,ret10,(a/price)*100,vz.toDouble()];
  }
  static Signal analyze(String symbol,String tf,List<Candle> cs,{double? mlProbability}){final c=cs.map((x)=>x.close).toList(); final price=c.last,e9=ema(c,9),e21=ema(c,21),r=rsi(c,14),a=atr(cs,14); final f=features(cs); int score=0; if(e9>e21)score+=2;else score-=2;if(price>e9)score++;else score--;if(r>52&&r<70)score++;if(r<48&&r>30)score--; if(f[3]>0)score++;else score--;if(f[4]>0)score++;else score--;
    String side=score>=4?'LONG':score<=-4?'SHORT':'WAIT'; if(mlProbability!=null){side=mlProbability>=0.58?'LONG':mlProbability<=0.42?'SHORT':'WAIT';} final risk=math.max(a*1.6,price*0.003).toDouble(); final sl=side=='LONG'?price-risk:side=='SHORT'?price+risk:price; final tp1=side=='LONG'?price+risk*1.5:side=='SHORT'?price-risk*1.5:price; final tp2=side=='LONG'?price+risk*2.5:side=='SHORT'?price-risk*2.5:price;
    // Probability is an indicator score proxy, not a calibrated ML prediction.
    final prob=mlProbability==null?(0.50+score.abs()*0.045).clamp(0.50,0.80).toDouble():(side=='SHORT'?1-mlProbability:mlProbability);
    return Signal(symbol:symbol,interval:tf,side:side,reason:'EMA9/21 ${e9>e21?'صعودی':'نزولی'} • RSI ${r.toStringAsFixed(1)} • ATR ${a.toStringAsFixed(4)} • امتیاز ${score}',time:DateTime.now(),entry:price,sl:sl,tp1:tp1,tp2:tp2,rsi:r,atr:a,probability:prob,score:score);
  }
}


class MLModel {
  bool trained = false;
  List<Map<String, dynamic>> models = [];

  Future<void> load() async {
    try {
      final j = jsonDecode(await rootBundle.loadString('assets/model_weights.json'));
      trained = j['status'] == 'trained' &&
          j['models'] is List && (j['models'] as List).isNotEmpty;
      models = trained
          ? (j['models'] as List).map((e) => Map<String, dynamic>.from(e)).toList()
          : [];
    } catch (_) {
      trained = false;
      models = [];
    }
  }

  double _sigmoid(double z) {
    z = z.clamp(-30.0, 30.0).toDouble();
    return 1.0 / (1.0 + math.exp(-z));
  }

  double _treeValue(Map<String, dynamic> tree, List<double> x) {
    final nodes = (tree['nodes'] as List)
        .map((e) => Map<String, dynamic>.from(e)).toList();
    int idx = 0;
    for (int steps = 0; steps < nodes.length + 2; steps++) {
      if (idx < 0 || idx >= nodes.length) return 0;
      final n = nodes[idx];
      final leaf = n['value'];
      if (leaf != null) return (leaf as num).toDouble();
      final f = (n['feature'] as num).toInt();
      final threshold = (n['threshold'] as num).toDouble();
      final left = (n['left'] as num).toInt();
      final right = (n['right'] as num).toInt();
      if (f < 0 || f >= x.length) return 0;
      idx = (n['lt'] == true ? x[f] < threshold : x[f] <= threshold) ? left : right;
    }
    return 0;
  }

  double? predict(List<double> features) {
    if (!trained || features.length != 7) return null;
    final probs = <double>[];
    for (final m in models) {
      final trees = (m['trees'] as List?) ?? const [];
      double raw = ((m['bias'] as num?) ?? 0).toDouble();
      for (final t in trees) {
        raw += _treeValue(Map<String, dynamic>.from(t), features);
      }
      probs.add(_sigmoid(raw));
    }
    if (probs.isEmpty) return null;
    // Ensemble averages model probabilities, not raw tree scores.
    return probs.reduce((a, b) => a + b) / probs.length;
  }
}

class HomePage extends StatefulWidget {const HomePage({super.key});@override State<HomePage> createState()=>_HomePageState();}
class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  Timer? _monitorTimer; bool _monitorBusy=false; DateTime? _lastMonitorAt;
  final MLModel model=MLModel(); final FlutterLocalNotificationsPlugin notifications=FlutterLocalNotificationsPlugin(); int tab=0; String symbol='BTC-USDT',tf='1h'; bool loading=false; String error=''; List<String> symbols=['BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','LINK-USDT','AVAX-USDT']; Signal? current; List<Signal> history=[]; List<NoEntryRecord> noEntryHistory=[]; List<PaperTrade> trades=[]; double paperBalance=10000; double riskPercent=1; double maxLeverage=5; bool autoLeverage=true; int mtfScore=0; String mtfSummary='';
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);_load().then((_)=>_autoMonitorTick());_loadSymbols();model.load();_initNotifications();_monitorTimer=Timer.periodic(const Duration(seconds:15),(_)=>_autoMonitorTick());}
  @override void didChangeAppLifecycleState(AppLifecycleState state){if(state==AppLifecycleState.resumed){_autoMonitorTick();}}
  @override void dispose(){_monitorTimer?.cancel();WidgetsBinding.instance.removeObserver(this);super.dispose();}
  Future<void> _initNotifications() async {try{const settings=InitializationSettings(android:AndroidInitializationSettings('@mipmap/ic_launcher'));await notifications.initialize(settings);await notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();}catch(_){}}
  Future<void> _notifySignal(Signal s) async {try{await notifications.show(100,'سیگنال ${s.side} • ${s.symbol}','ورود ${fmt(s.entry)} | SL ${fmt(s.sl)} | TP ${fmt(s.tp1)}',const NotificationDetails(android:AndroidNotificationDetails('crypto_signals','Crypto Signals',channelDescription:'Signal alerts',importance:Importance.high,priority:Priority.high)));}catch(_){}}
  Future<void> _load() async {final p=await SharedPreferences.getInstance();setState((){history=(jsonDecode(p.getString('history')??'[]') as List).map((e)=>Signal.fromJson(e)).toList();noEntryHistory=(jsonDecode(p.getString('noEntryHistory')??'[]') as List).map((e)=>NoEntryRecord.fromJson(Map<String,dynamic>.from(e))).toList();trades=(jsonDecode(p.getString('paperTrades')??'[]') as List).map((e)=>PaperTrade.fromJson(e)).toList();paperBalance=p.getDouble('paperBalance')??10000;});}
  Future<void> _save() async {final p=await SharedPreferences.getInstance();await p.setString('history',jsonEncode(history.map((x)=>x.toJson()).toList()));await p.setString('noEntryHistory',jsonEncode(noEntryHistory.map((x)=>x.toJson()).toList()));await p.setString('paperTrades',jsonEncode(trades.map((x)=>x.toJson()).toList()));await p.setDouble('paperBalance',paperBalance);}
  Future<void> _autoMonitorTick() async {
    if(!mounted||_monitorBusy||WidgetsBinding.instance.lifecycleState!=AppLifecycleState.resumed)return;
    final pending=history.where((h)=>h.outcome=='PENDING'&&h.side!='WAIT').map((h)=>h.symbol);
    final open=trades.where((t)=>t.status=='OPEN').map((t)=>t.symbol);
    final watch=<String>{...pending,...open};
    if(watch.isEmpty)return;
    _monitorBusy=true; bool changed=false; final failures=<String>[];
    try{
      for(final sym in watch){
        try{
          final candles=await MarketApi.candles(sym,'5m',limit:3);
          if(candles.isEmpty)throw Exception('کندل خالی');
          final c=candles.last; if(!c.close.isFinite||c.close<=0)throw Exception('قیمت نامعتبر');
          // Historical signals: use candle extremes so intrabar TP/SL touches are not missed.
          for(var i=0;i<history.length;i++){
            final h=history[i]; if(h.symbol!=sym||h.outcome!='PENDING'||h.side=='WAIT')continue;
            final hitSl=h.side=='LONG'?c.low<=h.sl:c.high>=h.sl;
            final hitTp=h.side=='LONG'?c.high>=h.tp1:c.low<=h.tp1;
            if(hitSl||hitTp){
              final outcome=hitSl?'SL':'TP1';
              history[i]=Signal(symbol:h.symbol,interval:h.interval,side:h.side,reason:h.reason,time:h.time,entry:h.entry,sl:h.sl,tp1:h.tp1,tp2:h.tp2,rsi:h.rsi,atr:h.atr,probability:h.probability,score:h.score,outcome:outcome);
              changed=true;
              await _notifyOutcome(h,outcome);
            }
          }
          // Paper positions: conservative SL priority if both levels are touched in one candle.
          for(var i=0;i<trades.length;i++){
            final t=trades[i]; if(t.symbol!=sym||t.status!='OPEN')continue;
            final hitSl=t.side=='LONG'?c.low<=t.sl:c.high>=t.sl;
            final hitTp=t.side=='LONG'?c.high>=t.tp1:c.low<=t.tp1;
            final closed=hitSl||hitTp; final exit=closed?(hitSl?t.sl:t.tp1):c.close;
            final gross=(t.side=='LONG'?exit-t.entry:t.entry-exit)*t.qty;
            final exitFee=closed?exit*t.qty*_paperFeeRate:0.0;
            final net=closed?gross-t.entryFee-exitFee:(t.side=='LONG'?c.close-t.entry:t.entry-c.close)*t.qty-t.entryFee;
            trades[i]=PaperTrade(id:t.id,symbol:t.symbol,side:t.side,status:closed?(hitSl?'SL':'TP'):'OPEN',opened:t.opened,entry:t.entry,sl:t.sl,tp1:t.tp1,qty:t.qty,pnl:net,margin:t.margin,entryFee:t.entryFee,leverage:t.leverage);
            if(closed){paperBalance+=gross-exitFee;await _notifyTradeClose(t,hitSl?'SL':'TP');}
            changed=true;
          }
        }catch(e){failures.add('$sym: $e');}
      }
      if(changed){await _save();if(mounted)setState(()=>_lastMonitorAt=DateTime.now());}
      else if(mounted)setState(()=>_lastMonitorAt=DateTime.now());
      if(failures.isNotEmpty&&mounted)setState(()=>error='خطای پایش خودکار (داده تازه دریافت نشد):\n${failures.join('\n')}');
    }finally{_monitorBusy=false;}
  }
  Future<void> _notifyOutcome(Signal s,String outcome) async {try{await notifications.show(200+s.time.millisecondsSinceEpoch.remainder(100000),'نتیجه سیگنال ${s.symbol}','$outcome • ورود ${fmt(s.entry)}',const NotificationDetails(android:AndroidNotificationDetails('signal_results','Signal Results',channelDescription:'Signal TP/SL results',importance:Importance.high,priority:Priority.high)));}catch(_) {}}
  Future<void> _notifyTradeClose(PaperTrade t,String outcome) async {try{await notifications.show(300+t.id.hashCode.abs().remainder(100000),'معامله مجازی ${t.symbol} بسته شد','$outcome • نتیجه ${t.pnl.toStringAsFixed(2)} USDT',const NotificationDetails(android:AndroidNotificationDetails('paper_results','Paper Results',channelDescription:'Paper trade results',importance:Importance.high,priority:Priority.high)));}catch(_) {}}
  Future<void> _loadSymbols() async {try{final list=await MarketApi.symbols();if(mounted)setState(()=>symbols=list);}catch(_) {}}
  String fmt(double n)=>n.abs()>=100?n.toStringAsFixed(2):n.toStringAsFixed(5);
  List<String> _noEntryReasons({required Signal raw,required String filteredSide,
    required double macd,required int ichi,required int mtfTotal}) {
    final reasons=<String>[];
    if(raw.side=='WAIT') {
      if(model.trained && raw.probability>0.42 && raw.probability<0.58) {
        reasons.add('احتمال ML به حد ورود نرسید (بازه خنثی ۴۲٪ تا ۵۸٪)');
      } else {
        reasons.add('امتیاز/جهت اولیه الگوریتم برای ورود کافی نبود');
      }
    } else {
      if(raw.side=='LONG' && macd<=0) reasons.add('MACD با ورود خرید هم‌جهت نبود');
      if(raw.side=='SHORT' && macd>=0) reasons.add('MACD با ورود فروش هم‌جهت نبود');
      if(raw.side=='LONG' && ichi<0) reasons.add('Ichimoku با ورود خرید مخالفت داشت');
      if(raw.side=='SHORT' && ichi>0) reasons.add('Ichimoku با ورود فروش مخالفت داشت');
      if(raw.side=='LONG' && mtfTotal<=-2) reasons.add('روند تایم‌فریم‌های چندگانه مخالف خرید بود');
      if(raw.side=='SHORT' && mtfTotal>=2) reasons.add('روند تایم‌فریم‌های چندگانه مخالف فروش بود');
    }
    if(reasons.isEmpty && filteredSide=='WAIT') reasons.add('یکی از فیلترهای ترکیبی ورود را رد کرد');
    if(reasons.isEmpty) reasons.add('شرایط ورود کامل نبود');
    return reasons;
  }

  Future<void> _analyze() async {setState(() { loading=true; error=''; });try{
    await model.load(); final cs=await MarketApi.candles(symbol,tf); final prob=model.predict(Indicators.features(cs));
    // Multi-timeframe confirmation: 15m, 1h, 4h. The selected timeframe remains the signal's main frame.
    final tfs=['15m','1h','4h']; final scores=<String,int>{};
    for(final t in tfs){try{final data=t==tf?cs:await MarketApi.candles(symbol,t,limit:150);scores[t]=Indicators.trendScore(data);}catch(_){scores[t]=0;}}
    final total=scores.values.fold<int>(0,(a,b)=>a+b); mtfScore=total; mtfSummary=scores.entries.map((e)=>'${e.key}:${e.value>0?'↑':e.value<0?'↓':'—'}').join('  ');
    final raw=Indicators.analyze(symbol,tf,cs,mlProbability:prob);
    String side=Indicators.applyExperimentalFilter(raw.side,cs);
    final ichi=Indicators.ichimokuScore(cs);
    final macd=Indicators.macdHist(cs.map((x)=>x.close).toList());
    // MTF is a filter only: it may suppress an ML signal, never create one from WAIT.
    if ((raw.side=='LONG' && total<=-2) ||
        (raw.side=='SHORT' && total>=2)) {
      side='WAIT';
    }
    final noEntryReasons=side=='WAIT'
        ? _noEntryReasons(raw:raw,filteredSide:side,macd:macd,ichi:ichi,mtfTotal:total)
        : <String>[];
    final risk=math.max(raw.atr*1.6,raw.entry*0.003).toDouble(); final sl=side=='LONG'?raw.entry-risk:side=='SHORT'?raw.entry+risk:raw.entry;
    final tp1=side=='LONG'?raw.entry+risk*1.5:side=='SHORT'?raw.entry-risk*1.5:raw.entry; final tp2=side=='LONG'?raw.entry+risk*2.5:side=='SHORT'?raw.entry-risk*2.5:raw.entry;
    final s=Signal(symbol:raw.symbol,interval:raw.interval,side:side,reason:'${raw.reason} • MTF: $mtfSummary • Ichimoku: ${ichi>0?'صعودی':ichi<0?'نزولی':'خنثی'} ($ichi) • MACD: ${macd>0?'صعودی':'نزولی'}',time:raw.time,entry:raw.entry,sl:sl,tp1:tp1,tp2:tp2,rsi:raw.rsi,atr:raw.atr,probability:raw.probability,score:raw.score+total+ichi);
    setState(()=>current=s); _evaluateHistory(symbol,raw.entry);
    if(s.side!='WAIT'){
      await _notifySignal(s);history.insert(0,s);if(history.length>500)history.removeLast();await _save();
    } else {
      noEntryHistory.insert(0,NoEntryRecord(symbol:symbol,interval:tf,time:raw.time,
        entry:raw.entry,probability:raw.probability,score:s.score,reasons:noEntryReasons));
      if(noEntryHistory.length>500)noEntryHistory.removeLast();
      await _save();
    }
  }catch(e){setState(()=>error='دریافت داده ناموفق بود؛ ممکن است DNS یا دسترسی منطقه‌ای محدود باشد.\n$e');}finally{if(mounted)setState(()=>loading=false);}}
  void _evaluateHistory(String sym,double price){
    bool changed=false; for(int i=0;i<history.length;i++){final h=history[i];if(h.symbol!=sym||h.outcome!='PENDING'||h.side=='WAIT')continue;String result='PENDING';
      if(h.side=='LONG'){if(price<=h.sl)result='SL';else if(price>=h.tp1)result='TP1';}
      else {if(price>=h.sl)result='SL';else if(price<=h.tp1)result='TP1';}
      if(result!='PENDING'){history[i]=Signal(symbol:h.symbol,interval:h.interval,side:h.side,reason:h.reason,time:h.time,entry:h.entry,sl:h.sl,tp1:h.tp1,tp2:h.tp2,rsi:h.rsi,atr:h.atr,probability:h.probability,score:h.score,outcome:result);changed=true;}
    } if(changed)_save();
  }
  static const double _paperFeeRate=0.0004; // 0.04% per side, simulated taker fee.
  double get _reservedPaperMargin => trades.where((t)=>t.status=='OPEN').fold(0.0,(a,t)=>a+t.margin);
  double get _availablePaperBalance => math.max(0.0,paperBalance-_reservedPaperMargin).toDouble();
  void _openPaper(){
    final s=current;
    if(s==null||s.side=='WAIT')return;
    final distance=(s.entry-s.sl).abs();
    final available=_availablePaperBalance;
    if(distance<=0||s.entry<=0||available<=0){
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('موجودی آزاد یا فاصله حدضرر معتبر نیست.')));
      return;
    }
    final riskMoney=available*riskPercent/100;
    final maxNotional=available/(1/maxLeverage+_paperFeeRate);
    final qty=math.min(riskMoney/distance,maxNotional/s.entry).toDouble();
    final notional=qty*s.entry;
    final margin=notional/maxLeverage;
    final entryFee=notional*_paperFeeRate;
    if(qty<=0||margin+entryFee>available){
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('موجودی آزاد برای ثبت این معامله کافی نیست.')));
      return;
    }
    final now=DateTime.now();
    final t=PaperTrade(id:now.microsecondsSinceEpoch.toString(),symbol:s.symbol,side:s.side,status:'OPEN',opened:now,
      entry:s.entry,sl:s.sl,tp1:s.tp1,qty:qty,pnl:-entryFee,margin:margin,entryFee:entryFee,leverage:maxLeverage);
    setState((){trades.insert(0,t);paperBalance-=entryFee;});
    _save();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('معامله مجازی با اهرم ${maxLeverage.toStringAsFixed(0)}x ثبت شد؛ مارجین ${margin.toStringAsFixed(2)} و کارمزد ورود ${entryFee.toStringAsFixed(4)} USDT. سفارش واقعی ارسال نمی‌شود.')));
  }
  Future<void> _refreshPaper() async {
    final open=trades.where((x)=>x.status=='OPEN').toList();
    if(open.isEmpty){
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('معاملهٔ بازی برای بررسی وجود ندارد.')));
      return;
    }
    int updated=0, failed=0;
    final failures=<String>[];
    for(final t in open){
      try{
        final candles=await MarketApi.candles(t.symbol,'5m',limit:3);
        if(candles.isEmpty) throw Exception('داده کندل خالی است');
        final candle=candles.last;
        final price=candle.close;
        if(!price.isFinite||price<=0) throw Exception('قیمت دریافتی نامعتبر است');
        // اگر SL و TP در یک کندل لمس شوند، برای جلوگیری از خوش‌بینی، SL اولویت دارد.
        final hitSl=t.side=='LONG'?candle.low<=t.sl:candle.high>=t.sl;
        final hitTp=t.side=='LONG'?candle.high>=t.tp1:candle.low<=t.tp1;
        final closed=hitSl||hitTp;
        final exitPrice=closed?(hitSl?t.sl:t.tp1):price;
        final grossPnl=(t.side=='LONG'?exitPrice-t.entry:t.entry-exitPrice)*t.qty;
        final exitFee=exitPrice*t.qty*_paperFeeRate;
        // Entry fee was deducted at opening; include both fees in displayed net PnL.
        final netPnl=grossPnl-t.entryFee-exitFee;
        final idx=trades.indexWhere((x)=>x.id==t.id);
        if(idx<0) continue;
        trades[idx]=PaperTrade(id:t.id,symbol:t.symbol,side:t.side,status:closed?(hitSl?'SL':'TP'):'OPEN',
          opened:t.opened,entry:t.entry,sl:t.sl,tp1:t.tp1,qty:t.qty,pnl:netPnl,
          margin:t.margin,entryFee:t.entryFee,leverage:t.leverage);
        if(closed){
          // Release margin by removing OPEN status; realize gross PnL less exit fee.
          // Entry fee was already deducted from paperBalance at entry.
          paperBalance+=grossPnl-exitFee;
        }
        updated++;
      }catch(e){
        failed++;
        failures.add('${t.symbol}: $e');
      }
    }
    if(mounted){
      setState((){});
      final message=updated>0
        ? 'قیمت $updated معامله به‌روزرسانی شد${failed>0?'؛ خطای دریافت برای $failed معامله':''}.'
        : 'به‌روزرسانی انجام نشد؛ دریافت قیمت ناموفق بود.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(message),duration:const Duration(seconds:5)));
      if(failed>0){
        setState(()=>error='خطای به‌روزرسانی Paper:\n${failures.join('\n')}');
      }
    }
    if(updated>0) await _save();
  }
  Future<void> _backtest() async {
    setState(() { loading=true; error=''; });
    try {
      await model.load();
      if (!model.trained) {
        throw Exception('مدل Ensemble آموزش‌دیده پیدا نشد. ابتدا فایل assets/model_weights.json را از Colab جایگزین کن.');
      }
      final cs=await MarketApi.candles(symbol,tf,limit:500);
      int wins=0, loss=0, tradesN=0;
      double net=0, grossWin=0, grossLoss=0;
      const feePerSide=0.0004;
      const slippagePerSide=0.0002;
      const costPct=2*(feePerSide+slippagePerSide);
      int i=80;
      while(i<cs.length-11){
        final history=cs.sublist(0,i+1);
        final p=model.predict(Indicators.features(history));
        if(p==null){i++;continue;}
        final raw=Indicators.analyze(symbol,tf,history,mlProbability:p);
        final filteredSide=Indicators.applyExperimentalFilter(raw.side,history);
        if(filteredSide=='WAIT'){i++;continue;}
        final s=Signal(symbol:raw.symbol,interval:raw.interval,side:filteredSide,reason:raw.reason,
          time:raw.time,entry:raw.entry,sl:raw.sl,tp1:raw.tp1,tp2:raw.tp2,rsi:raw.rsi,
          atr:raw.atr,probability:raw.probability,score:raw.score);
        final entry=s.entry;
        final risk=(entry-s.sl).abs();
        if(risk<=0){i++;continue;}
        tradesN++;
        bool done=false;
        int exitIndex=i+10;
        double resultR=-0.2;
        for(int j=i+1;j<math.min(i+11,cs.length);j++){
          final c=cs[j];
          // Conservative same-candle assumption: count SL first.
          if(s.side=='LONG'){
            if(c.low<=s.sl){resultR=-1;done=true;exitIndex=j;break;}
            if(c.high>=s.tp1){resultR=1.5;done=true;exitIndex=j;break;}
          }else{
            if(c.high>=s.sl){resultR=-1;done=true;exitIndex=j;break;}
            if(c.low<=s.tp1){resultR=1.5;done=true;exitIndex=j;break;}
          }
        }
        resultR-=(entry*costPct)/risk;
        if(resultR>0){wins++;grossWin+=resultR;}else{loss++;grossLoss+=resultR.abs();}
        net+=resultR;
        // One simulated position at a time; avoid overlapping trades.
        i=done?exitIndex+1:i+11;
      }
      if(!mounted)return;
      final wr=tradesN==0?0:wins/tradesN*100;
      final pf=grossLoss==0?(grossWin>0?'∞':'0'):(grossWin/grossLoss).toStringAsFixed(2);
      showDialog(context:context,builder:(_)=>AlertDialog(
        title:const Text('بک‌تست آزمایشی ML + MACD + Ichimoku'),
        content:Text('نماد: $symbol • تایم‌فریم: $tf\n'
          'مدل: XGBoost + LightGBM\n'
          'معاملات: $tradesN • برد: $wins • باخت: $loss\n'
          'درصد برد: ${wr.toStringAsFixed(1)}٪\n'
          'Profit Factor: $pf\n'
          'نتیجه خالص: ${net.toStringAsFixed(2)}R\n'
          'هزینه فرضی رفت‌وبرگشت: ${(costPct*100).toStringAsFixed(2)}٪\n\n'
          'Funding، spread و اجرای واقعی کامل شبیه‌سازی نشده‌اند؛ نتیجه تضمین آینده نیست.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('باشه'))]));
    }catch(e){
      setState(()=>error='Backtest failed: $e');
    }finally{
      if(mounted)setState(()=>loading=false);
    }
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('سیگنال‌یار کریپتو'),centerTitle:true,actions:[IconButton(onPressed:_loadSymbols,icon:const Icon(Icons.refresh),tooltip:'به‌روزرسانی فهرست ارزها')]),body:IndexedStack(index:tab,children:[_analysisView(),_paperView(),_historyView()]),bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(i)=>setState(()=>tab=i),destinations:const [NavigationDestination(icon:Icon(Icons.insights),label:'تحلیل'),NavigationDestination(icon:Icon(Icons.account_balance_wallet),label:'Paper'),NavigationDestination(icon:Icon(Icons.history),label:'تاریخچه') ]));
  Widget _noEntrySummary()=>Card(
    color:const Color(0xFF202936),
    child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Text('گزارش عدم ورود: ${noEntryHistory.length} مورد',style:const TextStyle(fontWeight:FontWeight.bold)),
      if(noEntryHistory.isEmpty) const Text('هنوز تحلیل عدم ورودی ثبت نشده است.',style:TextStyle(color:Colors.white70))
      else ...[
        Text('آخرین مورد: ${noEntryHistory.first.symbol} • ${noEntryHistory.first.interval} • ${noEntryHistory.first.time.toLocal()}',
          style:const TextStyle(color:Colors.white70)),
        ...noEntryHistory.first.reasons.map((r)=>Text('• $r',style:const TextStyle(color:Colors.orangeAccent))),
      ],
    ])));
  Widget _analysisView()=>ListView(padding:const EdgeInsets.all(16),children:[const Text('فیوچرز • داده عمومی • بدون اتصال حساب صرافی',textAlign:TextAlign.center,style:TextStyle(color:Colors.white70)),const SizedBox(height:16),Row(children:[Expanded(child:DropdownButtonFormField<String>(value:symbol,decoration:const InputDecoration(labelText:'ارز / قرارداد',border:OutlineInputBorder()),items:symbols.map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setState(()=>symbol=v??symbol))),const SizedBox(width:10),Expanded(child:DropdownButtonFormField<String>(value:tf,decoration:const InputDecoration(labelText:'تایم‌فریم',border:OutlineInputBorder()),items:MarketApi.intervals.map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setState(()=>tf=v??tf))) ]),const SizedBox(height:12),FilledButton.icon(onPressed:loading?null:_analyze,icon:loading?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.analytics),label:Text(loading?'در حال بررسی...':'تحلیل و دریافت سیگنال')),if(error.isNotEmpty)Padding(padding:const EdgeInsets.only(top:12),child:Text(error,style:const TextStyle(color:Colors.orangeAccent))),if(current!=null)_signalCard(current!),_noEntrySummary(),const SizedBox(height:10),OutlinedButton.icon(onPressed:loading?null:_backtest,icon:const Icon(Icons.science),label:const Text('اجرای بک‌تست (تا ۵۰۰ کندل)')),const SizedBox(height:14),const Card(child:Padding(padding:EdgeInsets.all(12),child:Text('⚠️ این اپ پژوهشی است. مدل ML فقط پس از آموزش و جایگزینی فایل model_weights.json فعال می‌شود. بک‌تست از ML Ensemble استفاده می‌کند؛ کارمزد و اسلیپیج تقریبی‌اند و funding کامل مدل نشده است. فقط حساب مجازی؛ هیچ سفارش واقعی ارسال نمی‌شود.',textDirection:TextDirection.rtl,style:TextStyle(height:1.5))))]);
  Widget _signalCard(Signal s)=>Card(color:const Color(0xFF1B2330),child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[Text('${s.symbol} • ${s.interval}',textAlign:TextAlign.center),const SizedBox(height:8),Text(s.side=='LONG'?'LONG / خرید':s.side=='SHORT'?'SHORT / فروش':'WAIT / عدم ورود',textAlign:TextAlign.center,style:TextStyle(fontSize:24,fontWeight:FontWeight.bold,color:s.side=='LONG'?Colors.greenAccent:s.side=='SHORT'?Colors.redAccent:Colors.amber)),Text('تایید تایم‌فریم‌ها: $mtfSummary',textAlign:TextAlign.center,style:const TextStyle(color:Colors.white70)),Text('امتیاز ${s.score} • ${model.trained?'احتمال مدل ML':'امتیاز تخمینی الگوریتم'} ${(s.probability*100).toStringAsFixed(0)}٪',textAlign:TextAlign.center),const Divider(height:24),_row('ورود',fmt(s.entry)),_row('حد ضرر',s.side=='WAIT'?'—':fmt(s.sl)),_row('حد سود ۱',s.side=='WAIT'?'—':fmt(s.tp1)),_row('حد سود ۲',s.side=='WAIT'?'—':fmt(s.tp2)),Text(s.reason,textAlign:TextAlign.center,style:const TextStyle(color:Colors.white70)),if(s.side!='WAIT')FilledButton(onPressed:_openPaper,child:const Text('ثبت معاملهٔ مجازی'))] )));
  Widget _row(String a,String b)=>Padding(padding:const EdgeInsets.symmetric(vertical:4),child:Row(children:[Expanded(child:Text(a)),Text(b,style:const TextStyle(fontWeight:FontWeight.bold))]));
  Widget _paperView()=>ListView(padding:const EdgeInsets.all(16),children:[
    Text('موجودی مجازی: ${paperBalance.toStringAsFixed(2)} USDT',style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),
    Text('موجودی آزاد: ${_availablePaperBalance.toStringAsFixed(2)} USDT • مارجین رزروشده: ${_reservedPaperMargin.toStringAsFixed(2)} USDT',style:const TextStyle(color:Colors.white70)),
    const SizedBox(height:6),
    const Text('پایش خودکار هر ۱۵ ثانیه هنگام باز و فعال بودن برنامه؛ در پس‌زمینه/پس از بسته‌شدن تضمین‌شده نیست.',style:TextStyle(color:Colors.greenAccent)),
    if(_lastMonitorAt!=null)Text('آخرین بررسی: ${_lastMonitorAt!.toLocal()}',style:const TextStyle(color:Colors.white54)),
    const SizedBox(height:10),
    Row(children:[const Text('ریسک هر معامله'),Expanded(child:Slider(value:riskPercent,min:0.25,max:3,divisions:11,label:'${riskPercent.toStringAsFixed(2)}%',onChanged:(v)=>setState(()=>riskPercent=v))),Text('${riskPercent.toStringAsFixed(2)}%')]),
    Row(children:[const Text('حداکثر اهرم'),Expanded(child:Slider(value:maxLeverage,min:1,max:5,divisions:4,label:'${maxLeverage.toStringAsFixed(0)}x',onChanged:(v)=>setState(()=>maxLeverage=v))),Text('${maxLeverage.toStringAsFixed(0)}x')]),
    FilledButton.icon(onPressed:_refreshPaper,icon:const Icon(Icons.sync),label:const Text('به‌روزرسانی قیمت و بررسی حد سود/ضرر')),
    const SizedBox(height:12),
    if(error.isNotEmpty)Padding(padding:const EdgeInsets.only(bottom:8),child:Text(error,style:const TextStyle(color:Colors.orangeAccent))),
    if(trades.isEmpty)const Text('هنوز معاملهٔ مجازی ثبت نشده است.'),
    ...trades.map((t)=>Card(child:ListTile(
      title:Text('${t.symbol} • ${t.side} • ${t.status}'),
      subtitle:Text('ورود ${fmt(t.entry)} | SL ${fmt(t.sl)} | TP ${fmt(t.tp1)} | حجم ${t.qty.toStringAsFixed(5)}\nاهرم ${t.leverage.toStringAsFixed(1)}x | مارجین ${t.margin.toStringAsFixed(2)} | کارمزد ورود ${t.entryFee.toStringAsFixed(4)}'),
      trailing:Text('${t.pnl.toStringAsFixed(2)} USDT\n${t.status=='OPEN'?'سود/ضرر شناور':'نتیجه نهایی'}',textAlign:TextAlign.end,style:TextStyle(color:t.pnl>=0?Colors.greenAccent:Colors.redAccent)),
    ))),
  ]);
  Widget _historyView()=>ListView(padding:const EdgeInsets.all(16),children:[
    Row(children:[const Expanded(child:Text('سیگنال‌های ذخیره‌شده',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold))),TextButton(onPressed:()async{setState(()=>history.clear());await _save();},child:const Text('پاک کردن'))]),
    if(history.isEmpty)const Text('تاریخچه سیگنال خالی است.'),
    ...history.map((s)=>Card(child:ListTile(title:Text('${s.symbol} • ${s.side}'),subtitle:Text('${s.interval} | ${s.time.toLocal()} | entry ${fmt(s.entry)} | نتیجه: ${s.outcome}'),trailing:Text('${(s.probability*100).toStringAsFixed(0)}%')))),
    const Divider(height:28),
    Row(children:[Expanded(child:Text('عدم ورودها (${noEntryHistory.length})',style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold))),TextButton(onPressed:()async{setState(()=>noEntryHistory.clear());await _save();},child:const Text('پاک کردن'))]),
    if(noEntryHistory.isEmpty)const Text('هنوز موردی ثبت نشده است.'),
    ...noEntryHistory.map((r)=>Card(child:ListTile(
      title:Text('${r.symbol} • ${r.interval} • عدم ورود'),
      subtitle:Text('${r.time.toLocal()} | قیمت ${fmt(r.entry)} | ML ${(r.probability*100).toStringAsFixed(0)}٪\n${r.reasons.map((x)=>'• $x').join('\n')}'),
      isThreeLine:true,
    ))),
  ]);
}
