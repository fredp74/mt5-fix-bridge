"""Tiny FIX 4.4 acceptor to test the bridge locally. NOT a real venue.

Run:  python -m fixbridge.mock_venue --port 9878
Requires reset_on_logon = true in the bridge config.
"""
from __future__ import annotations

import argparse
import asyncio
import random
from datetime import datetime, timezone

from .fixcodec import Parser, encode
from .protocol import fmt_num

QUOTE_INTERVAL = 1.0
START_PX = {"EURUSD": 1.0850, "GBPUSD": 1.2700, "USDJPY": 150.00}
SPREAD = {"USDJPY": 0.010}


def ts():
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H:%M:%S.%f")[:-3]


async def _handle(reader, writer):
    parser = Parser()
    st = {"seq": 1, "me": "VENUE", "peer": "MT5BRIDGE", "hb": 30, "begin": "FIX.4.4"}
    subs = {}
    mids = {}
    counters = {"oid": 0, "exec": 0}
    tasks = []

    def send(mtype, fields):
        hdr = [(49, st["me"]), (56, st["peer"]), (34, st["seq"]), (52, ts())]
        st["seq"] += 1
        writer.write(encode(mtype, hdr + fields, st["begin"]))

    def mid(sym):
        return mids.setdefault(sym, START_PX.get(sym, 1.0))

    def report(etype, status, cid, orig, sym, side, qty, lastqty, lastpx, cum, avg, oid):
        counters["exec"] += 1
        f = [(37, oid), (17, "E%d" % counters["exec"]), (150, etype), (39, status),
             (11, cid), (55, sym), (54, side), (38, fmt_num(qty)),
             (14, fmt_num(cum)), (151, fmt_num(max(qty - cum, 0))), (6, fmt_num(avg))]
        if orig:
            f.append((41, orig))
        if lastqty:
            f += [(32, fmt_num(lastqty)), (31, "%.5f" % lastpx)]
        send("8", f)

    async def quotes():
        try:
            while True:
                await asyncio.sleep(QUOTE_INTERVAL)
                for sym, rid in list(subs.items()):
                    m = mid(sym) * (1 + random.uniform(-0.0002, 0.0002))
                    mids[sym] = m
                    half = SPREAD.get(sym, 0.0001) / 2.0
                    send("W", [(262, rid), (55, sym), (268, 2),
                               (269, 0), (270, "%.5f" % (m - half)), (271, 1000000),
                               (269, 1), (270, "%.5f" % (m + half)), (271, 1000000)])
                await writer.drain()
        except (asyncio.CancelledError, Exception):
            return

    async def hearts():
        try:
            while True:
                await asyncio.sleep(st["hb"])
                send("0", [])
                await writer.drain()
        except (asyncio.CancelledError, Exception):
            return

    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            for m in parser.feed(data):
                t = m.type
                if t == "A":
                    st["begin"] = m.get(8, "FIX.4.4")
                    st["me"] = m.get(56) or st["me"]
                    st["peer"] = m.get(49) or st["peer"]
                    st["hb"] = int(m.get(108, "30"))
                    send("A", [(98, 0), (108, st["hb"])] + ([(141, "Y")] if m.get(141) == "Y" else []))
                    tasks.append(asyncio.create_task(quotes()))
                    tasks.append(asyncio.create_task(hearts()))
                elif t == "1":
                    send("0", [(112, m.get(112, ""))])
                elif t == "5":
                    send("5", [])
                    await writer.drain()
                    writer.close()
                    return
                elif t == "D":
                    sym, side, cid = m.get(55), m.get(54), m.get(11)
                    qty = float(m.get(38, "0"))
                    px = float(m.get(44)) if m.get(44) else mid(sym)
                    counters["oid"] += 1
                    oid = "O%d" % counters["oid"]
                    report("0", "0", cid, None, sym, side, qty, 0, 0, 0, 0, oid)
                    report("F", "2", cid, None, sym, side, qty, qty, px, qty, px, oid)
                elif t == "F":
                    counters["oid"] += 1
                    report("4", "4", m.get(11), m.get(41), m.get(55), m.get(54),
                           float(m.get(38, "0")), 0, 0, 0, 0, "O%d" % counters["oid"])
                elif t == "G":
                    counters["oid"] += 1
                    report("5", "5", m.get(11), m.get(41), m.get(55), m.get(54),
                           float(m.get(38, "0")), 0, 0, 0, 0, "O%d" % counters["oid"])
                elif t == "V":
                    sym, rid = m.get(55), m.get(262)
                    if m.get(263) == "2":
                        subs.pop(sym, None)
                    else:
                        subs[sym] = rid
                elif t == "AN":
                    send("AP", [(721, "P1"), (710, m.get(710, "")), (727, 1), (728, 0),
                                (1, "ACC"), (581, 1), (60, ts()), (55, "EURUSD"),
                                (702, 1), (703, "TQ"), (704, 100000), (705, 0)])
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        for t in tasks:
            t.cancel()
        try:
            writer.close()
        except Exception:
            pass


async def serve(host="127.0.0.1", port=9878):
    return await asyncio.start_server(_handle, host, port)


def main():
    ap = argparse.ArgumentParser(prog="fixbridge.mock_venue")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9878)
    args = ap.parse_args()

    async def run():
        srv = await serve(args.host, args.port)
        print("mock FIX venue listening on %s:%d (Ctrl+C to stop)" % (args.host, args.port))
        await srv.serve_forever()

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
