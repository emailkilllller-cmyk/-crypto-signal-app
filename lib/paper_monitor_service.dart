import 'dart:convert';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

@pragma('vm:entry-point')
void startPaperMonitorCallback() {
  FlutterForegroundTask.setTaskHandler(PaperMonitorTaskHandler());
}

class PaperMonitorTaskHandler extends TaskHandler {
  bool _busy = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    _tick();
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString('paperMonitorOwner') != 'background') return;
      final raw = prefs.getString('paperTrades') ?? '[]';
      final List<dynamic> rows = jsonDecode(raw) as List<dynamic>;
      final balance = prefs.getDouble('paperBalance') ?? 10000.0;
      var nextBalance = balance;
      var changed = false;
      for (var i = 0; i < rows.length; i++) {
        final t = Map<String, dynamic>.from(rows[i] as Map);
        if (t['status'] != 'OPEN') continue;
        final symbol = (t['symbol'] ?? '').toString();
        final price = await _lastPrice(symbol);
        if (price == null || !price.isFinite || price <= 0) continue;
        final side = (t['side'] ?? '').toString();
        final entry = (t['entry'] as num).toDouble();
        final sl = (t['sl'] as num).toDouble();
        final tp = (t['tp1'] as num).toDouble();
        final qty = (t['qty'] as num).toDouble();
        final entryFee = (t['entryFee'] as num?)?.toDouble() ?? 0.0;
        const feeRate = 0.0004;
        final hitSl = side == 'LONG' ? price <= sl : price >= sl;
        final hitTp = side == 'LONG' ? price >= tp : price <= tp;
        final closed = hitSl || hitTp;
        final gross = (side == 'LONG' ? price - entry : entry - price) * qty;
        final exitFee = closed ? price * qty * feeRate : 0.0;
        final net = gross - entryFee - exitFee;
        t['pnl'] = net;
        if (closed) {
          t['status'] = hitSl ? 'SL' : 'TP';
          nextBalance += gross - exitFee;
        }
        rows[i] = t;
        changed = true;
      }
      if (changed && prefs.getString('paperMonitorOwner') == 'background') {
        await prefs.setString('paperTrades', jsonEncode(rows));
        await prefs.setDouble('paperBalance', nextBalance);
        await prefs.setInt('paperLastUpdatedMs', DateTime.now().millisecondsSinceEpoch);
      }
    } catch (_) {
      // Keep the foreground service alive; a later tick retries network/storage work.
    } finally {
      _busy = false;
    }
  }

  Future<double?> _lastPrice(String symbol) async {
    final pair = symbol.replaceAll('-', '');
    try {
      final r = await http.get(Uri.https('fapi.binance.com', '/fapi/v1/ticker/price', {'symbol': pair})).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        final v = double.tryParse('${jsonDecode(r.body)['price']}');
        if (v != null && v > 0) return v;
      }
    } catch (_) {}
    try {
      final r = await http.get(Uri.https('www.okx.com', '/api/v5/market/ticker', {'instId': '$symbol-SWAP'})).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        final data = j['data'];
        if (j['code'] == '0' && data is List && data.isNotEmpty) {
          final v = double.tryParse('${data.first['last']}');
          if (v != null && v > 0) return v;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
