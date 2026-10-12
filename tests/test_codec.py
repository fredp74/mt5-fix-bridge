import unittest

from fixbridge.fixcodec import Parser, encode
from fixbridge.protocol import fmt_num, mkline, parse_line

HDR = [(49, "A"), (56, "B"), (34, 1), (52, "20260101-00:00:00.000")]


class CodecTests(unittest.TestCase):
    def test_roundtrip(self):
        raw = encode("D", HDR + [(11, "x1"), (55, "EURUSD")])
        msgs = Parser().feed(raw)
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0].type, "D")
        self.assertEqual(msgs[0].get(55), "EURUSD")
        self.assertEqual(msgs[0].get(34), "1")

    def test_checksum_and_length(self):
        raw = encode("0", HDR)
        idx = raw.rindex(b"10=")
        self.assertEqual(int(raw[idx + 3:idx + 6]), sum(raw[:idx]) % 256)
        parts = raw.split(b"\x01")
        start = len(parts[0]) + 1 + len(parts[1]) + 1
        self.assertEqual(idx - start, int(parts[1][2:]))

    def test_fragmented(self):
        raw = encode("D", HDR + [(11, "x1")])
        p = Parser()
        out = []
        for i in range(len(raw)):
            out += p.feed(raw[i:i + 1])
        self.assertEqual(len(out), 1)

    def test_two_messages_and_garbage(self):
        raw = encode("0", HDR)
        self.assertEqual(len(Parser().feed(b"junk" + raw + raw)), 2)

    def test_bad_checksum_dropped(self):
        raw = encode("0", HDR)
        bad = raw[:-2] + (b"0" if raw[-2:-1] != b"0" else b"1") + b"\x01"
        p = Parser()
        self.assertEqual(p.feed(bad), [])
        self.assertEqual(p.dropped, 1)


class ProtocolTests(unittest.TestCase):
    def test_mkline_cleans_and_skips_empty(self):
        self.assertEqual(mkline("EXEC", id="a|b", sym="EURUSD", x=""), "EXEC|id=a b|sym=EURUSD\n")

    def test_parse_line(self):
        cmd, kv = parse_line("new|id=a1|sym=EURUSD|qty=1000\n")
        self.assertEqual(cmd, "NEW")
        self.assertEqual(kv["qty"], "1000")

    def test_fmt_num(self):
        self.assertEqual(fmt_num(100000.0), "100000")
        self.assertEqual(fmt_num(1.085), "1.085")
        self.assertEqual(fmt_num(0), "0")


if __name__ == "__main__":
    unittest.main()
