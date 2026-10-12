"""FIX 4.4 initiator session (logon, heartbeats, sequence numbers, resend)."""
from __future__ import annotations

import asyncio
import logging
import os
import ssl
import time
from datetime import datetime, timezone

from .fixcodec import Parser, encode, pretty

log = logging.getLogger("fixbridge.session")


def utc_ts():
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H:%M:%S.%f")[:-3]


class FixSession(object):
    def __init__(self, cfg, on_app, on_state):
        self.cfg = cfg
        self.on_app = on_app      # async callable(msg) for application messages
        self.on_state = on_state  # async callable(bool) logged on / down
        self.out_seq = 1
        self.in_seq = 1
        self.logged_on = False
        self._writer = None
        self._last_rx = 0.0
        self._last_tx = 0.0
        self._test_sent = False
        self._resend_until = 0
        self._logout_sent = False
        self._stop = False
        self._dirty = False

    # ---- persistence (only used when reset_on_logon = false)
    def _seq_file(self):
        name = "%s_%s.seq" % (self.cfg.sender, self.cfg.target)
        return os.path.join(self.cfg.store_dir, name)

    def _load_seq(self):
        try:
            with open(self._seq_file()) as fh:
                a, b = fh.read().split()
            self.out_seq, self.in_seq = int(a), int(b)
        except (OSError, ValueError):
            self.out_seq, self.in_seq = 1, 1

    def _flush(self):
        if self.cfg.reset_on_logon or not self._dirty:
            return
        try:
            os.makedirs(self.cfg.store_dir, exist_ok=True)
            with open(self._seq_file(), "w") as fh:
                fh.write("%d %d\n" % (self.out_seq, self.in_seq))
            self._dirty = False
        except OSError as e:
            log.error("cannot save sequence numbers: %s", e)

    # ---- sending
    async def send(self, mtype, fields, seq=None, extra_hdr=None):
        if self._writer is None:
            raise ConnectionError("no socket")
        c = self.cfg
        use = self.out_seq if seq is None else seq
        hdr = [(49, c.sender), (56, c.target), (34, use), (52, utc_ts())]
        if extra_hdr:
            hdr += extra_hdr
        raw = encode(mtype, hdr + list(fields), c.begin_string)
        if seq is None:
            self.out_seq += 1
            self._dirty = True
        self._writer.write(raw)
        self._last_tx = time.monotonic()
        log.debug("TX %s", pretty(raw))
        await self._writer.drain()

    async def send_app(self, mtype, fields):
        if not self.logged_on or self._writer is None:
            raise ConnectionError("FIX session not logged on")
        await self.send(mtype, fields)

    def _close(self):
        if self._writer is not None:
            try:
                self._writer.close()
            except Exception:
                pass

    async def _fatal(self, text):
        log.error("closing session: %s", text)
        try:
            await self.send("5", [(58, text)])
        except Exception:
            pass
        self._close()

    # ---- receiving
    async def _handle(self, m):
        t = m.type
        try:
            seq = int(m.get(34, "0"))
        except ValueError:
            seq = 0
        possdup = m.get(43) == "Y"

        if t == "4":  # SequenceReset (gap fill or reset)
            try:
                new = int(m.get(36, "0"))
            except ValueError:
                new = 0
            if new > self.in_seq:
                self.in_seq = new
                self._dirty = True
            elif new < self.in_seq:
                log.warning("SequenceReset to a lower number ignored (%d < %d)", new, self.in_seq)
            return

        if t == "A" and m.get(141) == "Y":
            self.in_seq = seq
        if seq < self.in_seq:
            if possdup:
                return
            await self._fatal("MsgSeqNum too low, expecting %d got %d" % (self.in_seq, seq))
            return

        if t == "A" and not self.logged_on:
            self.logged_on = True
            log.info("FIX logon OK (%s -> %s)", self.cfg.sender, self.cfg.target)
            await self.on_state(True)

        if seq > self.in_seq:
            if self.in_seq > self._resend_until:
                log.warning("gap: expected %d got %d, requesting resend", self.in_seq, seq)
                await self.send("2", [(7, self.in_seq), (16, 0)])
                self._resend_until = seq
            return

        self.in_seq += 1
        self._dirty = True
        if t == "0" or t == "A":
            return
        if t == "1":
            await self.send("0", [(112, m.get(112, ""))])
        elif t == "2":
            try:
                begin = int(m.get(7, "1"))
            except ValueError:
                begin = 1
            log.warning("ResendRequest from venue: no message store, gap-filling")
            await self.send("4", [(123, "Y"), (36, self.out_seq)], seq=begin,
                            extra_hdr=[(43, "Y"), (122, utc_ts())])
        elif t == "5":
            log.info("venue logout: %s", m.get(58, ""))
            if not self._logout_sent:
                self._logout_sent = True
                try:
                    await self.send("5", [])
                except Exception:
                    pass
            self._close()
        else:
            try:
                await self.on_app(m)
            except Exception:
                log.exception("on_app failed for 35=%s", t)

    async def _heartbeat_loop(self, started):
        hb = self.cfg.heartbeat
        try:
            while True:
                await asyncio.sleep(1)
                now = time.monotonic()
                if not self.logged_on:
                    if now - started > 15:
                        log.error("logon timeout")
                        self._close()
                        return
                    continue
                if now - self._last_tx >= hb:
                    await self.send("0", [])
                idle = now - self._last_rx
                if idle >= hb * 2.5:
                    log.error("no data from venue for %.0fs, closing", idle)
                    self._close()
                    return
                if idle >= hb * 1.5 and not self._test_sent:
                    await self.send("1", [(112, "TEST")])
                    self._test_sent = True
                if idle < hb:
                    self._test_sent = False
                self._flush()
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.error("heartbeat loop: %s", e)
            self._close()

    # ---- lifecycle
    async def _connect_once(self):
        c = self.cfg
        ctx = None
        if c.tls:
            ctx = ssl.create_default_context()
            if not c.tls_verify:
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
        log.info("connecting to %s:%d", c.host, c.port)
        reader, writer = await asyncio.open_connection(c.host, c.port, ssl=ctx)
        self._writer = writer
        self.logged_on = False
        self._test_sent = False
        self._logout_sent = False
        self._resend_until = 0
        now = time.monotonic()
        self._last_rx = now
        self._last_tx = now
        if c.reset_on_logon:
            self.out_seq, self.in_seq = 1, 1
        else:
            self._load_seq()
        parser = Parser()
        fields = [(98, 0), (108, c.heartbeat)]
        if c.reset_on_logon:
            fields.append((141, "Y"))
        if c.username:
            fields.append((553, c.username))
        if c.password:
            fields.append((554, c.password))
        hb_task = None
        try:
            await self.send("A", fields)
            hb_task = asyncio.create_task(self._heartbeat_loop(now))
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                self._last_rx = time.monotonic()
                for m in parser.feed(data):
                    log.debug("RX %r", m)
                    await self._handle(m)
        finally:
            if hb_task is not None:
                hb_task.cancel()
            was = self.logged_on
            self.logged_on = False
            self._flush()
            self._close()
            self._writer = None
            if was:
                try:
                    await self.on_state(False)
                except Exception:
                    log.exception("on_state(False) failed")

    async def run(self):
        while not self._stop:
            try:
                await self._connect_once()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.error("session error: %s", e)
            if self._stop:
                break
            log.info("reconnecting in %ds", self.cfg.reconnect_delay)
            await asyncio.sleep(self.cfg.reconnect_delay)

    async def stop(self):
        self._stop = True
        if self._writer is not None:
            try:
                if self.logged_on and not self._logout_sent:
                    self._logout_sent = True
                    await self.send("5", [])
                    await asyncio.sleep(0.3)
            except Exception:
                pass
            self._close()
