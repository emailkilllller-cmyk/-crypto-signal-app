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
    title: 'سیگنال‌یار کریپتو',
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

class PaperTrade {
  final String id, symbol, side, status;
  final DateTime opened;
  final double entry, sl, tp1, qty, pnl;
  PaperTrade({required this.id,required this.symbol,required this.side,required this.status,required this.opened,
    required this.entry,required this.sl,required this.tp1,required this.qty,required this.pnl});
  Map<String,dynamic> toJson()=>{'id':id,'symbol':symbol,'side':side,'status':status,'opened':opened.toIso8601String(),
    'entry':entry,'sl':sl,'tp1':tp1,'qty':qty,'pnl':pnl};
  factory PaperTrade.fromJson(Map<String,dynamic> j)=>PaperTrade(id:j['id'],symbol:j['symbol'],side:j['side'],status:j['status'],
    opened:DateTime.tryParse(j['opened']??'')??DateTime.now(),entry:(j['entry'] as num).toDouble(),sl:(j['sl'] as num).toDouble(),
    tp1:(j['tp1'] as num).toDouble(),qty:(j['qty'] as num).toDouble(),pnl:(j['pnl'] as num).toDouble());
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
      if(r.statusCode==200){final rows=jsonDecode(r.body) as List; if(rows.length>30) return rows.map<Candle>((e)=>Candle((e[0] as num).toInt(),double.parse('${e[1]}'),double.parse('${e[2]}'),double.parse('${e[3]}'),double.parse('${e[4]}'),double.parse('${e[5]}'))).toList();}
    } catch (_) {}
    final inst='$symbol-SWAP';
    final r=await http.get(Uri.https('www.okx.com','/api/v5/market/candles',{'instId':inst,'bar':_okxBar(tf),'limit':'$limit'})).timeout(const Duration(seconds:15));
    if(r.statusCode!=200) throw Exception('OKX HTTP ${r.statusCode}');
    final j=jsonDecode(r.body); final rows=j['data'];
    if(j['code']!='0'||rows is! List||rows.length<30) throw Exception('No candles / API ${j['msg']}');
    return rows.map<Candle>((e)=>Candle(int.parse('${e[0]}'),double.parse('${e[1]}'),double.parse('${e[2]}'),double.parse('${e[3]}'),double.parse('${e[4]}'),double.parse('${e[5]}'))).toList().reversed.toList();
  }
}

class Indicators {
  static double ema(List<double> x,int p){if(x.isEmpty)return 0;final k=2/(p+1);double v=x.first;for(int i=1;i<x.length;i++)v=x[i]*k+v*(1-k);return v;}
  static double rsi(List<double> c,int p){if(c.length<=p)return 50; double g=0,l=0; for(int i=c.length-p;i<c.length;i++){final d=c[i]-c[i-1];if(d>=0)g+=d;else l-=d;} if(l==0)return 100;return 100-100/(1+(g/p)/(l/p));}
  static double atr(List<Candle> cs,int p){if(cs.length<=p)return 0;double s=0;for(int i=cs.length-p;i<cs.length;i++){final prev=cs[i-1].close; s+=math.max(cs[i].high-cs[i].low,math.max((cs[i].high-prev).abs(),(cs[i].low-prev).abs())).toDouble();}return s/p;}
  static List<double> emaSeries(List<double> x,int p){final out=List<double>.filled(x.length,0);if(x.isEmpty)return out;final k=2/(p+1);double v=x.first;out[0]=v;for(int i=1;i<x.length;i++){v=x[i]*k+v*(1-k);out[i]=v;}return out;}
  static double macdHist(List<double> c){if(c.length<35)return 0;final f=emaSeries(c,12),s=emaSeries(c,26);final line=List<double>.generate(c.length,(i)=>f[i]-s[i]);final sig=emaSeries(line.sublist(25),9);return line.last-sig.last;}
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
  bool trained=false; double bias=0; List<double> weights=[];
  Future<void> load() async {try{final j=jsonDecode(await rootBundle.loadString('assets/model_weights.json'));trained=j['status']=='trained';bias=(j['bias'] as num).toDouble();weights=(j['weights'] as List).map((x)=>(x as num).toDouble()).toList();}catch(_){trained=false;}}
  double? predict(List<double> features){if(!trained||weights.length!=features.length)return null;double z=bias;for(int i=0;i<features.length;i++)z+=weights[i]*features[i];z=z.clamp(-30,30).toDouble();return 1/(1+math.exp(-z));}
}

class HomePage extends StatefulWidget {const HomePage({super.key});@override State<HomePage> createState()=>_HomePageState();}
class _HomePageState extends State<HomePage> {
  final MLModel model=MLModel(); final FlutterLocalNotificationsPlugin notifications=FlutterLocalNotificationsPlugin(); int tab=0; String symbol='BTC-USDT',tf='1h'; bool loading=false; String error=''; List<String> symbols=['BTC-USDT','ETH-USDT','SOL-USDT','BNB-USDT','XRP-USDT','LINK-USDT','AVAX-USDT']; Signal? current; List<Signal> history=[]; List<PaperTrade> trades=[]; double paperBalance=10000; double riskPercent=1; double maxLeverage=5; bool autoLeverage=true; int mtfScore=0; String mtfSummary='';
  @override void initState(){super.initState();_load();_loadSymbols();model.load();_initNotifications();}
  Future<void> _initNotifications() async {try{const settings=InitializationSettings(android:AndroidInitializationSettings('@mipmap/ic_launcher'));await notifications.initialize(settings);await notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();}catch(_){}}
  Future<void> _notifySignal(Signal s) async {try{await notifications.show(100,'سیگنال ${s.side} • ${s.symbol}','ورود ${fmt(s.entry)} | SL ${fmt(s.sl)} | TP ${fmt(s.tp1)}',const NotificationDetails(android:AndroidNotificationDetails('crypto_signals','Crypto Signals',channelDescription:'Signal alerts',importance:Importance.high,priority:Priority.high)));}catch(_){}}
  Future<void> _load() async {final p=await SharedPreferences.getInstance();setState((){history=(jsonDecode(p.getString('history')??'[]') as List).map((e)=>Signal.fromJson(e)).toList();trades=(jsonDecode(p.getString('paperTrades')??'[]') as List).map((e)=>PaperTrade.fromJson(e)).toList();paperBalance=p.getDouble('paperBalance')??10000;});}
  Future<void> _save() async {final p=await SharedPreferences.getInstance();await p.setString('history',jsonEncode(history.map((x)=>x.toJson()).toList()));await p.setString('paperTrades',jsonEncode(trades.map((x)=>x.toJson()).toList()));await p.setDouble('paperBalance',paperBalance);}
  Future<void> _loadSymbols() async {try{final list=await MarketApi.symbols();if(mounted)setState(()=>symbols=list);}catch(_) {}}
  String fmt(double n)=>n.abs()>=100?n.toStringAsFixed(2):n.toStringAsFixed(5);
  Future<void> _analyze() async {setState(() { loading=true; error=''; });try{
    await model.load(); final cs=await MarketApi.candles(symbol,tf); final prob=model.predict(Indicators.features(cs));
    // Multi-timeframe confirmation: 15m, 1h, 4h. The selected timeframe remains the signal's main frame.
    final tfs=['15m','1h','4h']; final scores=<String,int>{};
    for(final t in tfs){try{final data=t==tf?cs:await MarketApi.candles(symbol,t,limit:150);scores[t]=Indicators.trendScore(data);}catch(_){scores[t]=0;}}
    final total=scores.values.fold<int>(0,(a,b)=>a+b); mtfScore=total; mtfSummary=scores.entries.map((e)=>'${e.key}:${e.value>0?'↑':e.value<0?'↓':'—'}').join('  ');
    final raw=Indicators.analyze(symbol,tf,cs,mlProbability:prob); String side=raw.side;
    // Strong opposing timeframe consensus suppresses the signal instead of forcing a trade.
    if(total>=3 && raw.side!='SHORT') side=raw.side=='WAIT'?'LONG':raw.side;
    else if(total<=-3 && raw.side!='LONG') side=raw.side=='WAIT'?'SHORT':raw.side;
    else if((raw.side=='LONG'&&total<0)||(raw.side=='SHORT'&&total>0)) side='WAIT';
    final risk=math.max(raw.atr*1.6,raw.entry*0.003).toDouble(); final sl=side=='LONG'?raw.entry-risk:side=='SHORT'?raw.entry+risk:raw.entry;
    final tp1=side=='LONG'?raw.entry+risk*1.5:side=='SHORT'?raw.entry-risk*1.5:raw.entry; final tp2=side=='LONG'?raw.entry+risk*2.5:side=='SHORT'?raw.entry-risk*2.5:raw.entry;
    final s=Signal(symbol:raw.symbol,interval:raw.interval,side:side,reason:'${raw.reason} • تایید چندتایم‌فریم: $mtfSummary',time:raw.time,entry:raw.entry,sl:sl,tp1:tp1,tp2:tp2,rsi:raw.rsi,atr:raw.atr,probability:raw.probability,score:raw.score+total);
    setState(()=>current=s); _evaluateHistory(symbol,raw.entry); if(s.side!='WAIT'){await _notifySignal(s);history.insert(0,s);if(history.length>500)history.removeLast();await _save();}
  }catch(e){setState(()=>error='دریافت داده ناموفق بود؛ ممکن است DNS یا دسترسی منطقه‌ای محدود باشد.\n$e');}finally{if(mounted)setState(()=>loading=false);}}
  void _evaluateHistory(String sym,double price){
    bool changed=false; for(int i=0;i<history.length;i++){final h=history[i];if(h.symbol!=sym||h.outcome!='PENDING'||h.side=='WAIT')continue;String result='PENDING';
      if(h.side=='LONG'){if(price<=h.sl)result='SL';else if(price>=h.tp1)result='TP1';}
      else {if(price>=h.sl)result='SL';else if(price<=h.tp1)result='TP1';}
      if(result!='PENDING'){history[i]=Signal(symbol:h.symbol,interval:h.interval,side:h.side,reason:h.reason,time:h.time,entry:h.entry,sl:h.sl,tp1:h.tp1,tp2:h.tp2,rsi:h.rsi,atr:h.atr,probability:h.probability,score:h.score,outcome:result);changed=true;}
    } if(changed)_save();
  }
  void _openPaper(){final s=current;if(s==null||s.side=='WAIT')return;final riskMoney=paperBalance*riskPercent/100;final distance=(s.entry-s.sl).abs();if(distance<=0)return;final qty=math.min(riskMoney/distance,(paperBalance*maxLeverage)/s.entry).toDouble();final t=PaperTrade(id:DateTime.now().microsecondsSinceEpoch.toString(),symbol:s.symbol,side:s.side,status:'OPEN',opened:DateTime.now(),entry:s.entry,sl:s.sl,tp1:s.tp1,qty:qty,pnl:0);setState(()=>trades.insert(0,t));_save();ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('معاملهٔ مجازی ثبت شد؛ سفارش واقعی ارسال نمی‌شود.')));}
  Future<void> _refreshPaper() async {final open=trades.where((x)=>x.status=='OPEN').toList();if(open.isEmpty)return;for(final t in open){try{final c=await MarketApi.candles(t.symbol,'5m',limit:2);final p=c.last.close;final hitSl=t.side=='LONG'?p<=t.sl:p>=t.sl;final hitTp=t.side=='LONG'?p>=t.tp1:p<=t.tp1;if(hitSl||hitTp){final pnl=(t.side=='LONG'?p-t.entry:t.entry-p)*t.qty;final idx=trades.indexWhere((x)=>x.id==t.id);trades[idx]=PaperTrade(id:t.id,symbol:t.symbol,side:t.side,status:hitSl?'SL':'TP',opened:t.opened,entry:t.entry,sl:t.sl,tp1:t.tp1,qty:t.qty,pnl:pnl);paperBalance+=pnl;}}catch(_){} }setState((){});await _save();}
  Future<void> _backtest() async {setState(() { loading=true; error=''; });try{final cs=await MarketApi.candles(symbol,tf,limit:500);int wins=0,loss=0, tradesN=0;double net=0;for(int i=60;i<cs.length-10;i+=3){final s=Indicators.analyze(symbol,tf,cs.sublist(0,i+1));if(s.side=='WAIT')continue;tradesN++;bool done=false;for(int j=i+1;j<math.min(i+11,cs.length);j++){final c=cs[j];if(s.side=='LONG'){if(c.low<=s.sl){loss++;net-=1;done=true;break;}if(c.high>=s.tp1){wins++;net+=1.5;done=true;break;}}else{if(c.high>=s.sl){loss++;net-=1;done=true;break;}if(c.low<=s.tp1){wins++;net+=1.5;done=true;break;}}}if(!done){loss++;net-=0.2;}}if(!mounted)return;showDialog(context:context,builder:(_)=>AlertDialog(title:const Text('نتیجهٔ بک‌تست تقریبی'),content:Text('نماد: $symbol • تایم‌فریم: $tf\nتعداد معاملات: $tradesN\nبرد: $wins • باخت: $loss\nبازده واحد ریسک: ${net.toStringAsFixed(2)}\n\nاین بک‌تست ساده است؛ کارمزد، اسلیپیج و funding را کامل مدل نمی‌کند و تضمین آینده نیست.'),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('باشه'))]));}catch(e){setState(()=>error='Backtest failed: $e');}finally{if(mounted)setState(()=>loading=false);}}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('سیگنال‌یار کریپتو'),centerTitle:true,actions:[IconButton(onPressed:_loadSymbols,icon:const Icon(Icons.refresh),tooltip:'به‌روزرسانی فهرست ارزها')]),body:IndexedStack(index:tab,children:[_analysisView(),_paperView(),_historyView()]),bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(i)=>setState(()=>tab=i),destinations:const [NavigationDestination(icon:Icon(Icons.insights),label:'تحلیل'),NavigationDestination(icon:Icon(Icons.account_balance_wallet),label:'Paper'),NavigationDestination(icon:Icon(Icons.history),label:'تاریخچه') ]));
  Widget _analysisView()=>ListView(padding:const EdgeInsets.all(16),children:[const Text('فیوچرز • داده عمومی • بدون اتصال حساب صرافی',textAlign:TextAlign.center,style:TextStyle(color:Colors.white70)),const SizedBox(height:16),Row(children:[Expanded(child:DropdownButtonFormField<String>(value:symbol,decoration:const InputDecoration(labelText:'ارز / قرارداد',border:OutlineInputBorder()),items:symbols.map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setState(()=>symbol=v??symbol))),const SizedBox(width:10),Expanded(child:DropdownButtonFormField<String>(value:tf,decoration:const InputDecoration(labelText:'تایم‌فریم',border:OutlineInputBorder()),items:MarketApi.intervals.map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setState(()=>tf=v??tf))) ]),const SizedBox(height:12),FilledButton.icon(onPressed:loading?null:_analyze,icon:loading?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.analytics),label:Text(loading?'در حال بررسی...':'تحلیل و دریافت سیگنال')),if(error.isNotEmpty)Padding(padding:const EdgeInsets.only(top:12),child:Text(error,style:const TextStyle(color:Colors.orangeAccent))),if(current!=null)_signalCard(current!),const SizedBox(height:10),OutlinedButton.icon(onPressed:loading?null:_backtest,icon:const Icon(Icons.science),label:const Text('اجرای بک‌تست (تا ۵۰۰ کندل)')),const SizedBox(height:14),const Card(child:Padding(padding:EdgeInsets.all(12),child:Text('⚠️ این اپ پژوهشی است. مدل ML فقط پس از آموزش و جایگزینی فایل model_weights.json فعال می‌شود. بک‌تست تقریبی است و کارمزد/funding/slippage کامل ندارد. فقط حساب مجازی؛ هیچ سفارش واقعی ارسال نمی‌شود.',textDirection:TextDirection.rtl,style:TextStyle(height:1.5))))]);
  Widget _row(String a,String b)=>Padding(padding:const EdgeInsets.symmetric(vertical:4),child:Row(children:[Expanded(child:Text(a)),Text(b,style:const TextStyle(fontWeight:FontWeight.bold))]));
  Widget _paperView()=>ListView(padding:const EdgeInsets.all(16),children:[Text('موجودی مجازی: ${paperBalance.toStringAsFixed(2)} USDT',style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold)),const SizedBox(height:10),Row(children:[const Text('ریسک هر معامله'),Expanded(child:Slider(value:riskPercent,min:0.25,max:3,divisions:11,label:'${riskPercent.toStringAsFixed(2)}%',onChanged:(v)=>setState(()=>riskPercent=v))),Text('${riskPercent.toStringAsFixed(2)}%')]),Row(children:[const Text('حداکثر اهرم'),Expanded(child:Slider(value:maxLeverage,min:1,max:5,divisions:4,label:'${maxLeverage.toStringAsFixed(0)}x',onChanged:(v)=>setState(()=>maxLeverage=v))),Text('${maxLeverage.toStringAsFixed(0)}x')]),FilledButton.icon(onPressed:_refreshPaper,icon:const Icon(Icons.sync),label:const Text('بررسی حد سود/ضرر معاملات باز')),const SizedBox(height:12),if(trades.isEmpty)const Text('هنوز معاملهٔ مجازی ثبت نشده است.'),...trades.map((t)=>Card(child:ListTile(title:Text('${t.symbol} • ${t.side} • ${t.status}'),subtitle:Text('ورود ${fmt(t.entry)} | SL ${fmt(t.sl)} | TP ${fmt(t.tp1)}'),trailing:Text('${t.pnl.toStringAsFixed(2)} USDT',style:TextStyle(color:t.pnl>=0?Colors.greenAccent:Colors.redAccent))))) ]);
  Widget _historyView()=>ListView(padding:const EdgeInsets.all(16),children:[Row(children:[const Expanded(child:Text('سیگنال‌های ذخیره‌شده',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold))),TextButton(onPressed:()async{setState(()=>history.clear());await _save();},child:const Text('پاک کردن'))]),if(history.isEmpty)const Text('تاریخچه خالی است.'),...history.map((s)=>Card(child:ListTile(title:Text('${s.symbol} • ${s.side}'),subtitle:Text('${s.interval} | ${s.time.toLocal()} | entry ${fmt(s.entry)} | نتیجه: ${s.outcome}'),trailing:Text('${(s.probability*100).toStringAsFixed(0)}%'))))]);
}
