# MT5 FIX Bridge

Send orders from a MetaTrader 5 account to any FIX 4.4 venue, and get executions,
market data and positions back. An MQL5 library/EA talks over a local TCP socket to a
small Python engine that speaks FIX. Pure standard library, no DLL, MIT licensed.

```
MT5 strategy -> FixBridge.mqh (EA) <-> TCP 127.0.0.1:9100 <-> Python engine <-> FIX 4.4 <-> venue
```

MT5 has no FIX client (its FIX API is a broker-side product), hence this bridge.

## Features
- Orders: NewOrderSingle, Cancel, Cancel/Replace; market, limit, stop, stop-limit; DAY/GTC/IOC/FOK
- Execution reports mapped back to the EA
- Market data: subscribe / unsubscribe, snapshot and incremental refresh, top of book
- Positions: RequestForPositions / PositionReport (venue support varies)
- FIX session: logon, heartbeats, TestRequest, sequence numbers, resend (gap fill), reconnect
- Safety: dry-run by default, symbol allow-list, max order size, kill-switch file, optional token
- Mirror mode: copy every MT5 deal to the venue as a market order
- Built-in fake venue and tests, so you can try everything without a counterparty

## Quick start (no venue needed)
Python 3.9+ required.

```bash
python -m unittest discover -s tests -v          # codec + end-to-end tests
python -m fixbridge.mock_venue --port 9878       # terminal 1: fake venue
cp config.example.ini config.ini                 # keep reset_on_logon = true
python -m fixbridge -c config.ini -v             # terminal 2: engine
```

MT5 side:
1. Copy `mql5/FixBridge.mqh` and `mql5/FixBridgeEA.mq5` to the same folder, for example
   `MQL5/Experts/FixBridge/`, then compile the EA in MetaEditor or use `mql5/FixBridgeEA.ex5`.
2. Tools > Options > Expert Advisors: add `127.0.0.1` to the allowed URL list (needed for sockets).
3. Attach the EA to a chart. Press `B` or `S` for a demo order, `P` for positions.

## Going live
1. Fill `[fix]` with your venue details (host, port, CompIDs, credentials, TLS).
   Prefer the `FIX_PASSWORD` environment variable over writing the password in the file.
2. Keep `dry_run = true` first and check market data and positions.
3. Set `dry_run = false` only when you are ready. Start with tiny sizes.
4. `touch KILL` stops new orders immediately (cancels still pass). Delete the file to resume.

## EA <-> engine protocol
One line per message, `CMD|key=value|...`, ASCII.

| EA to engine | Fields |
|---|---|
| `NEW` | id, sym, side (B/S), qty (units), type (M/L/S/SL), px, stop, tif (0/1/3/4) |
| `CANCEL` | id, orig, sym, side, qty |
| `REPLACE` | id, orig, sym, side, qty, type, px, stop |
| `SUB` / `UNSUB` | sym |
| `POS` | none |
| `AUTH` | token (first line, only if `auth_token` is set) |

| Engine to EA | Fields |
|---|---|
| `HELLO` | ver, fix (up/down), dry, kill |
| `EXEC` | id, orig, oid, etype, status, sym, side, lastqty, lastpx, cum, leaves, avgpx, text |
| `QUOTE` | sym, bid, ask, bsz, asz, ts |
| `POSITION` | sym, long, short, rid, total, result |
| `STATE` | fix (up/down) |
| `REJECT` | id, reason |

Quantities are FIX units, not MT5 lots: the library converts with `FixLotsToUnits()`.

## Two modes
| Mode | How | Orders executed |
|---|---|---|
| **Mirror** | `FixBridgeEA` with `InpMirror=true`: every MT5 deal is copied to the FIX venue | At the MT5 broker, then copied to FIX |
| **Routing** | `CFixTrade` replaces `CTrade` in your EA | Only at the FIX venue |

Both modes can run together on the same engine.

## Routing mode: use FIX instead of CTrade
`mql5/FixTrade.mqh` gives `CFixTrade`, a CTrade-like class that sends orders to the FIX venue
instead of the MT5 broker. See `mql5/FixTradeExample.mq5`.

To adapt an existing EA:
1. Put `FixBridge.mqh` and `FixTrade.mqh` next to the EA.
2. `#include <Trade\Trade.mqh>` becomes `#include "FixTrade.mqh"`, `CTrade trade;` becomes `CFixTrade trade;`.
3. In `OnInit`: `trade.Init(host, port, token, magic)`, `trade.Track(symbol)`, `EventSetMillisecondTimer(100)`.
   In `OnTimer`: `trade.Process()`.
4. Replace every read of MT5 positions or orders (`PositionSelect`, `PositionsTotal`, `OrdersTotal`,
   history) with `trade.NetLots(sym)`, `trade.HasPosition(sym)`, `trade.IsLong(sym)`:
   no MT5 position exists, the orders live at the venue.
5. SL/TP: FIX orders carry none. Call `trade.EmulateStops(true)` for a client-side SL/TP.
   It only works while the EA and the engine run, and does not guarantee the fill price.

Limits: tickets are internal, `PositionClose` works per symbol, the net position is tracked per EA
instance from its own fills, no stop-limit, no GTD, no hedging. MT5 balance and equity do not move.
Buy/Sell wait up to 2 s for a fill (`SetAsyncMode(true)` disables the wait); an accepted order still
pending returns true with `TRADE_RETCODE_PLACED`.

## Limitations (v0.1)
- FIX 4.4 only. No message store: a venue ResendRequest is answered with a gap fill.
- Position messages (AN/AP) differ between venues; the first position type of each report is used.
- Dry-run fills every order instantly at its price or the last mid, which is not a market simulation.
- The engine keeps order ids in memory only.
- Not affiliated with MetaQuotes or any venue.

## Risk warning
Trading is risky and this software is provided as is, without warranty. Test on a demo
venue first. You are responsible for every order it sends.

## License

MIT — see LICENSE.

---

*A research project by [Algotradingresearch.com](https://algotradingresearch.com)*

