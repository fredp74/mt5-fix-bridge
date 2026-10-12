import asyncio
import unittest

from fixbridge import mock_venue
from fixbridge.bridge import Bridge
from fixbridge.config import Config


class E2E(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        mock_venue.QUOTE_INTERVAL = 0.2
        self.venue = await mock_venue.serve("127.0.0.1", 0)
        vport = self.venue.sockets[0].getsockname()[1]
        cfg = Config.from_dict({
            "fix": {"host": "127.0.0.1", "port": str(vport), "reset_on_logon": "true",
                    "heartbeat": "30", "reconnect_delay": "1"},
            "bridge": {"listen_host": "127.0.0.1", "listen_port": "0", "dry_run": "false"},
            "risk": {"allowed_symbols": "EURUSD", "max_qty": "1000000",
                     "kill_file": "./KILL_DOES_NOT_EXIST"},
        })
        self.bridge = Bridge(cfg)
        await self.bridge.start()
        for _ in range(100):
            if self.bridge.session.logged_on:
                break
            await asyncio.sleep(0.05)
        self.assertTrue(self.bridge.session.logged_on)
        self.r, self.w = await asyncio.open_connection("127.0.0.1", self.bridge.listen_port)

    async def asyncTearDown(self):
        self.w.close()
        await self.bridge.stop()
        self.venue.close()

    async def read_until(self, prefix, timeout=5.0):
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while True:
            left = end - loop.time()
            if left <= 0:
                self.fail("timeout waiting for " + prefix)
            line = await asyncio.wait_for(self.r.readline(), left)
            s = line.decode().strip()
            if s.startswith(prefix):
                return s

    def send(self, line):
        self.w.write((line + "\n").encode())

    async def test_order_roundtrip(self):
        await self.read_until("HELLO")
        self.send("NEW|id=t1|sym=EURUSD|side=B|qty=100000|type=M")
        first = await self.read_until("EXEC")
        self.assertIn("etype=0", first)
        second = await self.read_until("EXEC")
        self.assertIn("etype=F", second)
        self.assertIn("cum=100000", second)

    async def test_symbol_refused(self):
        await self.read_until("HELLO")
        self.send("NEW|id=t2|sym=XXXXXX|side=B|qty=1000|type=M")
        self.assertIn("symbol not allowed", await self.read_until("REJECT"))

    async def test_qty_above_max(self):
        await self.read_until("HELLO")
        self.send("NEW|id=t3|sym=EURUSD|side=B|qty=99999999|type=M")
        self.assertIn("max_qty", await self.read_until("REJECT"))

    async def test_quotes(self):
        await self.read_until("HELLO")
        self.send("SUB|sym=EURUSD")
        self.assertIn("bid=", await self.read_until("QUOTE"))

    async def test_positions(self):
        await self.read_until("HELLO")
        self.send("POS")
        self.assertIn("long=100000", await self.read_until("POSITION"))


if __name__ == "__main__":
    unittest.main()
