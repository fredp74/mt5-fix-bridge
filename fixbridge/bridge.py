"""Bridge: EA line protocol <-> FIX application messages."""
from __future__ import annotations

import asyncio
import hmac
import logging
import math
import os
import time
from datetime import datetime, timezone

from .protocol import fmt_num, mkline, parse_line
from .session import FixSession, utc_ts

log = logging.getLogger("fixbridge.bridge")

SIDE_OUT = {"B": "1", "S": "2"}
SIDE_IN = {"1": "B", "2": "S"}
TYPE_OUT = {"M": "1", "L": "2", "S": "3", "SL": "4"}
TIF_OK = ("0", "1", "3", "4")  # day, GTC, IOC, FOK


class BridgeError(Exception):
    pass


class Bridge(object):
    def __init__(self, cfg):
        self.cfg = cfg
        self.to_fix = dict(cfg.symbol_map)
        self.to_mt5 = dict((v, k) for k, v in self.to_fix.items())
        self.session = FixSession(cfg, self.on_app, self.on_state)
        self.clients = set()
        self.subs = set()
        self.quotes = {}
        self.seen_ids = set()
        self.listen_port = cfg.listen_port
        self._server = None
        self._task = None

    # ---- lifecycle
    async def start(self):
        if not self.to_fix:
            log.warning("no allowed symbols configured: every order will be refused")
        self._server = await asyncio.start_server(
            self._client, self.cfg.listen_host, self.cfg.listen_port)
        self.listen_port = self._server.sockets[0].getsockname()[1]
        log.info("EA socket listening on %s:%d (dry_run=%s)",
                 self.cfg.listen_host, self.listen_port, self.cfg.dry_run)
        self._task = asyncio.create_task(self.session.run())

    async def stop(self):
        await self.session.stop()
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except BaseException:
                pass
        for w in list(self.clients):
            try:
                w.close()
            except Exception:
                pass
        if self._server is not None:
            self._server.close()
            try:
                await asyncio.wait_for(self._server.wait_closed(), 2)
            except Exception:
                pass

    # ---- EA side
    def _killed(self):
        return os.path.exists(self.cfg.kill_file)

    async def _write(self, writer, line):
        writer.write(line.encode("ascii", "replace"))
        await writer.drain()

    async def _broadcast(self, line):
        data = line.encode("ascii", "replace")
        for w in list(self.clients):
            try:
                w.write(data)
                await w.drain()
            except Exception:
                self.clients.discard(w)

    async def _emit(self, cmd, **kv):
        await self._broadcast(mkline(cmd, **kv))

    async def _hello(self, writer):
        await self._write(writer, mkline(
            "HELLO", ver=1, fix="up" if self.session.logged_on else "down",
            dry=int(self.cfg.dry_run), kill=int(self._killed())))

    async def _client(self, reader, writer):
        peer = writer.get_extra_info("peername")
        authed = not self.cfg.token
        try:
            if authed:
                self.clients.add(writer)
                await self._hello(writer)
            while True:
                raw = await reader.readline()
                if not raw:
                    break
                cmd, kv = parse_line(raw.decode("ascii", "replace"))
                if not cmd:
                    continue
                if not authed:
                    ok = cmd == "AUTH" and hmac.compare_digest(
                        kv.get("token", "").encode(), self.cfg.token.encode())
                    if not ok:
                        log.warning("client %s refused (bad token)", peer)
                        break
                    authed = True
                    self.clients.add(writer)
                    await self._hello(writer)
                    continue
                await self._dispatch(cmd, kv)
        except (ConnectionError, asyncio.IncompleteReadError, ValueError):
            pass
        finally:
            self.clients.discard(writer)
            try:
                writer.close()
            except Exception:
                pass

    async def _dispatch(self, cmd, kv):
        handlers = {"NEW": self._new, "CANCEL": self._cancel, "REPLACE": self._replace,
                    "SUB": self._sub, "UNSUB": self._unsub, "POS": self._pos,
                    "PING": self._ping}
        try:
            h = handlers.get(cmd)
            if h is None:
                raise BridgeError("unknown command " + cmd)
            await h(kv)
        except (BridgeError, ConnectionError) as e:
            await self._emit("REJECT", id=kv.get("id", ""), reason=str(e))
        except Exception:
            log.exception("command %s failed", cmd)
            await self._emit("REJECT", id=kv.get("id", ""), reason="internal error")

    # ---- validation helpers
    def _sym(self, kv):
        s = kv.get("sym", "").strip()
        if s not in self.to_fix:
            raise BridgeError("symbol not allowed: " + s)
        return s

    @staticmethod
    def _num(kv, key, required=True):
        v = kv.get(key)
        if v in (None, ""):
            if required:
                raise BridgeError("missing " + key)
            return None
        try:
            x = float(v)
        except ValueError:
            raise BridgeError("bad " + key)
        if not math.isfinite(x) or x <= 0:
            raise BridgeError("bad " + key)
        return x

    def _mid(self, sym):
        q = self.quotes.get(sym)
        try:
            if q and q.get("bid") and q.get("ask"):
                return (float(q["bid"]) + float(q["ask"])) / 2.0
        except ValueError:
            pass
        return None

    # ---- commands
    async def _new(self, kv):
        if self._killed():
            raise BridgeError("kill switch active")
        cid = kv.get("id", "")
        if not cid:
            raise BridgeError("missing id")
        if cid in self.seen_ids:
            raise BridgeError("duplicate id")
        sym = self._sym(kv)
        side = kv.get("side", "")
        if side not in SIDE_OUT:
            raise BridgeError("bad side")
        qty = self._num(kv, "qty")
        if qty > self.cfg.max_qty:
            raise BridgeError("qty above max_qty")
        typ = kv.get("type", "M")
        if typ not in TYPE_OUT:
            raise BridgeError("bad type")
        px = self._num(kv, "px", required=typ in ("L", "SL"))
        stop = self._num(kv, "stop", required=typ in ("S", "SL"))
        tif = kv.get("tif", "0")
        if tif not in TIF_OK:
            raise BridgeError("bad tif")
        self.seen_ids.add(cid)
        if self.cfg.dry_run:
            await self._dry_fill(cid, sym, side, qty, px)
            return
        fields = [(11, cid), (21, 1), (55, self.to_fix[sym]), (54, SIDE_OUT[side]),
                  (60, utc_ts()), (38, fmt_num(qty)), (40, TYPE_OUT[typ]), (59, tif)]
        if px:
            fields.append((44, fmt_num(px)))
        if stop:
            fields.append((99, fmt_num(stop)))
        try:
            await self.session.send_app("D", fields)
        except Exception:
            self.seen_ids.discard(cid)
            raise

    async def _dry_fill(self, cid, sym, side, qty, px):
        price = px or self._mid(sym) or 0.0
        oid = "DRY-" + cid
        await self._emit("EXEC", id=cid, oid=oid, etype="0", status="0", sym=sym, side=side,
                         lastqty="0", lastpx="0", cum="0", leaves=fmt_num(qty), avgpx="0",
                         text="DRY-RUN accepted")
        await self._emit("EXEC", id=cid, oid=oid, etype="F", status="2", sym=sym, side=side,
                         lastqty=fmt_num(qty), lastpx=fmt_num(price), cum=fmt_num(qty),
                         leaves="0", avgpx=fmt_num(price), text="DRY-RUN fill")

    async def _cancel(self, kv):
        cid, orig = kv.get("id", ""), kv.get("orig", "")
        if not cid or not orig:
            raise BridgeError("missing id or orig")
        sym = self._sym(kv)
        side = kv.get("side", "")
        if side not in SIDE_OUT:
            raise BridgeError("bad side")
        qty = self._num(kv, "qty")
        if self.cfg.dry_run:
            await self._emit("EXEC", id=cid, orig=orig, etype="4", status="4", sym=sym,
                             side=side, text="DRY-RUN cancel")
            return
        await self.session.send_app("F", [
            (41, orig), (11, cid), (55, self.to_fix[sym]), (54, SIDE_OUT[side]),
            (60, utc_ts()), (38, fmt_num(qty))])

    async def _replace(self, kv):
        if self._killed():
            raise BridgeError("kill switch active")
        cid, orig = kv.get("id", ""), kv.get("orig", "")
        if not cid or not orig:
            raise BridgeError("missing id or orig")
        sym = self._sym(kv)
        side = kv.get("side", "")
        if side not in SIDE_OUT:
            raise BridgeError("bad side")
        qty = self._num(kv, "qty")
        if qty > self.cfg.max_qty:
            raise BridgeError("qty above max_qty")
        typ = kv.get("type", "L")
        if typ not in TYPE_OUT:
            raise BridgeError("bad type")
        px = self._num(kv, "px", required=typ in ("L", "SL"))
        stop = self._num(kv, "stop", required=typ in ("S", "SL"))
        if self.cfg.dry_run:
            await self._emit("EXEC", id=cid, orig=orig, etype="5", status="5", sym=sym,
                             side=side, text="DRY-RUN replace")
            return
        fields = [(41, orig), (11, cid), (21, 1), (55, self.to_fix[sym]), (54, SIDE_OUT[side]),
                  (60, utc_ts()), (38, fmt_num(qty)), (40, TYPE_OUT[typ])]
        if px:
            fields.append((44, fmt_num(px)))
        if stop:
            fields.append((99, fmt_num(stop)))
        await self.session.send_app("G", fields)

    async def _md_request(self, sym, subscribe):
        fields = [(262, "md_" + sym), (263, "1" if subscribe else "2"),
                  (264, self.cfg.md_depth)]
        if subscribe:
            fields.append((265, self.cfg.md_update_type))
        fields += [(267, 2), (269, 0), (269, 1), (146, 1), (55, self.to_fix[sym])]
        await self.session.send_app("V", fields)

    async def _sub(self, kv):
        sym = self._sym(kv)
        if sym in self.subs:
            if sym in self.quotes:
                await self._emit_quote(sym)
            return
        self.subs.add(sym)
        if self.session.logged_on:
            await self._md_request(sym, True)

    async def _unsub(self, kv):
        sym = self._sym(kv)
        self.subs.discard(sym)
        self.quotes.pop(sym, None)
        if self.session.logged_on:
            await self._md_request(sym, False)

    async def _pos(self, kv):
        rid = "pos_" + str(int(time.time() * 1000))
        today = datetime.now(timezone.utc).strftime("%Y%m%d")
        fields = [(710, rid), (724, 0), (263, 0)]
        if self.cfg.account:
            fields.append((1, self.cfg.account))
        fields += [(581, 1), (715, today), (60, utc_ts())]
        await self.session.send_app("AN", fields)

    async def _ping(self, kv):
        await self._emit("PONG", ts=utc_ts())

    # ---- FIX side
    async def on_state(self, up):
        await self._emit("STATE", fix="up" if up else "down")
        if up:
            for sym in sorted(self.subs):
                try:
                    await self._md_request(sym, True)
                except Exception:
                    log.exception("resubscribe %s failed", sym)

    async def on_app(self, m):
        t = m.type
        if t == "8":
            await self._exec(m)
        elif t == "9":
            await self._emit("REJECT", id=m.get(11, ""), orig=m.get(41, ""),
                             reason="cancel/replace rejected code=%s %s" % (m.get(102, ""), m.get(58, "")))
        elif t == "W":
            await self._snapshot(m)
        elif t == "X":
            await self._incremental(m)
        elif t == "Y":
            await self._emit("REJECT", id=m.get(262, ""),
                             reason="market data rejected code=%s %s" % (m.get(281, ""), m.get(58, "")))
        elif t == "AP":
            await self._position(m)
        elif t == "AO":
            await self._emit("POSACK", id=m.get(710, ""), result=m.get(728, ""), status=m.get(729, ""))
        elif t == "3":
            await self._emit("REJECT", reason="session reject refseq=%s %s" % (m.get(45, ""), m.get(58, "")))
        elif t == "j":
            await self._emit("REJECT", id=m.get(379, ""),
                             reason="business reject reason=%s %s" % (m.get(380, ""), m.get(58, "")))
        else:
            log.debug("unhandled application message 35=%s", t)

    async def _exec(self, m):
        fx = m.get(55, "")
        sym = self.to_mt5.get(fx, fx)
        await self._emit(
            "EXEC", id=m.get(11, ""), orig=m.get(41, ""), oid=m.get(37, ""),
            etype=m.get(150, ""), status=m.get(39, ""), sym=sym,
            side=SIDE_IN.get(m.get(54, ""), ""), lastqty=m.get(32, "0"), lastpx=m.get(31, "0"),
            cum=m.get(14, "0"), leaves=m.get(151, "0"), avgpx=m.get(6, "0"),
            text=m.get(58, ""), rej=m.get(103, ""))

    @staticmethod
    def _entries(m):
        entries, cur, in_group = [], None, False
        for t, v in m.fields:
            if t == 268:
                in_group = True
                continue
            if not in_group:
                continue
            if t == 279 or (t == 269 and (cur is None or 269 in cur)):
                cur = {}
                entries.append(cur)
            if cur is None:
                continue
            cur[t] = v
        return entries

    def _sym_from_md(self, m):
        fx = m.get(55)
        sym = self.to_mt5.get(fx) if fx else None
        if sym is None:
            rid = m.get(262, "")
            if rid.startswith("md_"):
                sym = rid[3:]
        return sym

    async def _snapshot(self, m):
        sym = self._sym_from_md(m)
        if sym is None:
            return
        bid = ask = bsz = asz = None
        for e in self._entries(m):
            kind = e.get(269)
            if kind == "0" and bid is None:
                bid, bsz = e.get(270), e.get(271)
            elif kind == "1" and ask is None:
                ask, asz = e.get(270), e.get(271)
        await self._set_quote(sym, {"bid": bid, "ask": ask, "bsz": bsz, "asz": asz})

    async def _incremental(self, m):
        header_fx = m.get(55)
        touched = {}
        for e in self._entries(m):
            fx = e.get(55) or header_fx
            sym = self.to_mt5.get(fx) if fx else None
            if sym is None or e.get(290, "1") != "1":
                continue
            kind = e.get(269)
            if kind not in ("0", "1"):
                continue
            key, sz = ("bid", "bsz") if kind == "0" else ("ask", "asz")
            q = touched.setdefault(sym, dict(self.quotes.get(sym, {})))
            if e.get(279, "0") == "2":
                q[key], q[sz] = None, None
            else:
                q[key], q[sz] = e.get(270), e.get(271)
        for sym, q in touched.items():
            await self._set_quote(sym, q)

    async def _set_quote(self, sym, q):
        if self.quotes.get(sym) == q:
            return
        self.quotes[sym] = q
        await self._emit_quote(sym)

    async def _emit_quote(self, sym):
        q = self.quotes.get(sym, {})
        await self._emit("QUOTE", sym=sym, bid=q.get("bid"), ask=q.get("ask"),
                         bsz=q.get("bsz"), asz=q.get("asz"), ts=utc_ts())

    async def _position(self, m):
        fx = m.get(55, "")
        sym = self.to_mt5.get(fx, fx)
        long_q = short_q = None
        for t, v in m.fields:
            if t == 704 and long_q is None:
                long_q = v
            elif t == 705 and short_q is None:
                short_q = v
        await self._emit("POSITION", sym=sym, long=long_q or "0", short=short_q or "0",
                         rid=m.get(710, ""), total=m.get(727, ""), result=m.get(728, ""))
