# Experimental Paper Trading changes

Applied only to the experimental MACD + Ichimoku project (`lib/main.dart`).

- Simulated taker fee: 0.04% on entry and 0.04% on exit. Entry fee is deducted when opening; exit fee is charged on close. Displayed PnL includes both fees.
- Leverage and margin: position size is limited by risk sizing and the selected maximum leverage. Used margin is reserved from available balance while a trade is open and released when it closes. The balance display now distinguishes total balance, available balance, and reserved margin.
- Automatic SL/TP: retained and hardened. A 5-minute candle touching both levels is conservatively treated as SL first. Closed trades are realized once and are no longer processed on later refreshes.
- API errors: refresh reports how many trades updated and how many failed, and exposes the actual exception text instead of silently swallowing all errors.
- False success prevention: a success message is shown only if at least one trade received valid market data. If every request fails, the app explicitly reports that refresh failed.
- Fixed small-candle retrieval: Binance/OKX responses with 3 candles are now accepted for the paper refresh path (previously the 30-candle minimum made the 3-candle request fail).

Legacy saved open trades are loaded with a conservative 1x margin assumption and zero historical entry fee, because the old format did not store those values.

## Limitations

This remains a simulation, not exchange execution. Fees are an assumed fixed rate; funding, liquidation, spread, partial fills, and exchange-specific margin rules are not modeled. SL/TP detection uses 5-minute OHLC candles, not tick-by-tick prices. If SL and TP are both inside one candle, SL is assumed first. Network/API failures leave the affected trade unchanged and are shown to the user.
