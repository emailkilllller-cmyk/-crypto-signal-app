
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const SignalApp());

class SignalApp extends StatelessWidget {
  const SignalApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'سیگنال‌یار کریپتو',
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xFF10141C),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF36C99A), brightness: Brightness.dark),
    ),
    home: const SignalHome(),
  );
}

class Candle {
  final double open, high, low, close;
  Candle(this.open, this.high, this.low, this.close);
  factory Candle.fromJson(Map<String,dynamic> j) => Candle(
    double.parse('${j['open']}'), double.parse('${j['high']}'),
    double.parse('${j['low']}'), double.parse('${j['close']}'));
}

class SignalResult {
  final String side, reason;
  final double entry, sl, tp1, tp2, rsi, emaFast, emaSlow, atr;
  final int score;
  SignalResult(this.side,this.reason,this.entry,this.sl,this.tp1,this.tp2,
      this.rsi,this.emaFast,this.emaSlow,this.atr,this.score);
}

class SignalHome extends StatefulWidget {
  const SignalHome({super.key});
  @override State<SignalHome> createState()=>_SignalHomeState();
}

class _SignalHomeState extends State<SignalHome> {
  String symbol='BTC-USDT', interval='15m';
  bool loading=false;
  String error='';
  SignalResult? result;
  final symbols=['BTC-USDT','ETH-USDT','SOL-USDT','XRP-USDT'];
  final intervals=['5m','15m','1h','4h'];

  Future<void> analyze() async {
    setState(()=>{loading=true,error=''});
    try {
      final uri=Uri.https('open-api.bingx.com','/openApi/swap/v3/quote/klines',
        {'symbol':symbol,'interval':interval,'limit':'120'});
      final response=await http.get(uri).timeout(const Duration(seconds:15));
      if(response.statusCode!=200) throw Exception('خطای API: ${response.statusCode}');
      final decoded=jsonDecode(response.body);
      final raw=decoded['data'];
      if(raw is! List || raw.length<40) throw Exception('داده کافی دریافت نشد: ${decoded['msg'] ?? ''}');
      final candles=raw.map((e)=>Candle.fromJson(Map<String,dynamic>.from(e))).toList();
      result=buildSignal(candles);
    } catch(e) {
      error='دریافت داده ناموفق بود. اینترنت یا دسترسی به BingX را بررسی کن.\\n$e';
    } finally { if(mounted) setState(()=>loading=false); }
  }

  double ema(List<double> values,int period) {
    final k=2/(period+1); double v=values.take(period).reduce((a,b)=>a+b)/period;
    for(int i=period;i<values.length;i++) v=values[i]*k+v*(1-k);
    return v;
  }
  double rsi(List<double> c,int period) {
    double gains=0,losses=0;
    for(int i=c.length-period;i<c.length;i++){
      final d=c[i]-c[i-1]; if(d>=0) gains+=d; else losses-=d;
    }
    if(losses==0) return 100;
    final rs=(gains/period)/(losses/period);
    return 100-(100/(1+rs));
  }
  double atr(List<Candle> c,int period) {
    double sum=0;
    for(int i=c.length-period;i<c.length;i++){
      final prev=c[i-1].close;
      sum += [c[i].high-c[i].low,(c[i].high-prev).abs(),(c[i].low-prev).abs()].reduce((a,b)=>a>b?a:b);
    }
    return sum/period;
  }
  SignalResult buildSignal(List<Candle> candles) {
    final closes=candles.map((e)=>e.close).toList();
    final price=closes.last, fast=ema(closes,9), slow=ema(closes,21);
    final r=rsi(closes,14), a=atr(candles,14);
    int score=0;
    if(fast>slow) score+=2; else score-=2;
    if(price>fast) score+=1; else score-=1;
    if(r>52 && r<70) score+=1;
    if(r<48 && r>30) score-=1;
    String side=score>=3?'LONG':score<=-3?'SHORT':'WAIT';
    double sl,tp1,tp2;
    if(side=='LONG'){sl=price-1.5*a; tp1=price+1.5*(price-sl); tp2=price+2.5*(price-sl);}
    else if(side=='SHORT'){sl=price+1.5*a; tp1=price-1.5*(sl-price); tp2=price-2.5*(sl-price);}
    else {sl=price;tp1=price;tp2=price;}
    final reason='EMA9/21: ${fast>slow?'صعودی':'نزولی'} | RSI(14): ${r.toStringAsFixed(1)} | ATR: ${a.toStringAsFixed(2)}';
    return SignalResult(side,reason,price,sl,tp1,tp2,r,fast,slow,a,score);
  }

  String fmt(double n)=>n.toStringAsFixed(n>=100?2:4);
  @override Widget build(BuildContext context) {
    final s=result;
    return Scaffold(
      appBar: AppBar(title: const Text('سیگنال‌یار کریپتو',style:TextStyle(fontWeight:FontWeight.bold)),centerTitle:true),
      body: ListView(padding:const EdgeInsets.all(16),children:[
        const Text('فیوچرز BingX • تحلیل تکنیکال • حساب مجازی',textAlign:TextAlign.center,style:TextStyle(color:Colors.white70)),
        const SizedBox(height:18),
        Row(children:[
          Expanded(child: DropdownButtonFormField<String>(value:symbol,decoration:const InputDecoration(labelText:'جفت‌ارز',border:OutlineInputBorder()),items:symbols.map((v)=>DropdownMenuItem(value:v,child:Text(v))).toList(),onChanged:(v)=>setState(()=>symbol=v!))),
          const SizedBox(width:10),
          Expanded(child: DropdownButtonFormField<String>(value:interval,decoration:const InputDecoration(labelText:'تایم‌فریم',border:OutlineInputBorder()),items:intervals.map((v)=>DropdownMenuItem(value:v,child:Text(v))).toList(),onChanged:(v)=>setState(()=>interval=v!))),
        ]),
        const SizedBox(height:12),
        FilledButton.icon(onPressed:loading?null:analyze,icon:loading?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.analytics),label:Text(loading?'در حال دریافت داده...':'تحلیل بازار و تولید سیگنال')),
        if(error.isNotEmpty) Padding(padding:const EdgeInsets.only(top:12),child:Text(error,style:const TextStyle(color:Colors.orangeAccent))),
        if(s!=null) ...[
          const SizedBox(height:18),
          Card(color:const Color(0xFF1B2330),child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
            Text('$symbol  •  $interval',textAlign:TextAlign.center,style:const TextStyle(fontSize:18)),
            const SizedBox(height:10),
            Text(s.side=='LONG'?'سیگنال خرید (LONG)':s.side=='SHORT'?'سیگنال فروش (SHORT)':'عدم ورود (WAIT)',textAlign:TextAlign.center,style:TextStyle(fontSize:24,fontWeight:FontWeight.bold,color:s.side=='LONG'?Colors.greenAccent:s.side=='SHORT'?Colors.redAccent:Colors.amber)),
            Text('امتیاز الگوریتم: ${s.score}',textAlign:TextAlign.center),
            const Divider(height:24),
            info('قیمت ورود تقریبی',fmt(s.entry)),
            info('حد ضرر (SL)',s.side=='WAIT'?'—':fmt(s.sl)),
            info('حد سود ۱ (TP1)',s.side=='WAIT'?'—':fmt(s.tp1)),
            info('حد سود ۲ (TP2)',s.side=='WAIT'?'—':fmt(s.tp2)),
            const SizedBox(height:8),
            Text(s.reason,textAlign:TextAlign.center,style:const TextStyle(color:Colors.white70)),
          ]))),
        ],
        const SizedBox(height:18),
        const Card(child:Padding(padding:EdgeInsets.all(14),child:Text(
          '⚠️ نسخه اولیه و آزمایشی است. این سیگنال‌ها الگوریتمی‌اند و هنوز مدل هوش مصنوعی آموزش‌دیده یا اتصال به API هوش مصنوعی ندارند. هیچ سفارش واقعی ارسال نمی‌شود. ابتدا فقط با حساب مجازی و بک‌تست استفاده کن؛ حد ضرر/سود تضمین اجرا یا سود نیست.',
          textDirection:TextDirection.rtl,style:TextStyle(height:1.5)))),
      ]),
    );
  }
  Widget info(String label,String value)=>Padding(padding:const EdgeInsets.symmetric(vertical:5),child:Row(children:[Expanded(child:Text(label)),Text(value,style:const TextStyle(fontWeight:FontWeight.bold))]));
}
