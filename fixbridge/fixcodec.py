"""Minimal FIX tag=value codec (stdlib only)."""
from __future__ import annotations

import re

SOH = b"\x01"
_SECRET = re.compile(r"\|(554|96|925)=[^|]*")


class Msg(object):
    __slots__ = ("fields",)

    def __init__(self, fields):
        self.fields = fields

    @property
    def type(self):
        return self.get(35, "")

    def get(self, tag, default=None):
        for t, v in self.fields:
            if t == tag:
                return v
        return default

    def __repr__(self):
        return "Msg(" + "|".join("%d=%s" % f for f in self.fields) + ")"


def encode(msg_type, fields, begin="FIX.4.4"):
    """fields: list of (tag, value) AFTER tag 35 (header 49/56/34/52 included)."""
    body = "35=%s\x01" % msg_type
    body += "".join("%d=%s\x01" % (t, v) for t, v in fields)
    body_b = body.encode("utf-8")
    head = ("8=%s\x019=%d\x01" % (begin, len(body_b))).encode("utf-8")
    raw = head + body_b
    return raw + ("10=%03d\x01" % (sum(raw) % 256)).encode("ascii")


def pretty(raw):
    """Printable form for debug logs, with credentials masked."""
    s = raw.decode("utf-8", "replace").replace("\x01", "|")
    return _SECRET.sub(lambda m: "|" + m.group(1) + "=***", s)


class Parser(object):
    """Stream parser: feed bytes, get complete, checksum-valid messages."""

    def __init__(self):
        self.buf = b""
        self.dropped = 0

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            i = self.buf.find(b"8=FIX")
            if i < 0:
                self.buf = self.buf[-4:]
                break
            if i > 0:
                self.buf = self.buf[i:]
            j = self.buf.find(SOH)
            if j < 0:
                break
            k = self.buf.find(SOH, j + 1)
            if k < 0:
                break
            f9 = self.buf[j + 1:k]
            if not f9.startswith(b"9="):
                self.buf = self.buf[5:]
                self.dropped += 1
                continue
            try:
                blen = int(f9[2:])
            except ValueError:
                self.buf = self.buf[5:]
                self.dropped += 1
                continue
            if blen < 0 or blen > 1000000:
                self.buf = self.buf[5:]
                self.dropped += 1
                continue
            body_end = k + 1 + blen
            end = body_end + 7
            if len(self.buf) < end:
                break
            raw = self.buf[:end]
            self.buf = self.buf[end:]
            msg = self._parse(raw, body_end)
            if msg is None:
                self.dropped += 1
            else:
                out.append(msg)
        return out

    @staticmethod
    def _parse(raw, body_end):
        trailer = raw[body_end:]
        if not trailer.startswith(b"10=") or not trailer.endswith(SOH):
            return None
        try:
            cs = int(trailer[3:-1])
        except ValueError:
            return None
        if cs != sum(raw[:body_end]) % 256:
            return None
        fields = []
        try:
            for part in raw[:-1].split(SOH):
                t, sep, v = part.partition(b"=")
                if not sep:
                    return None
                fields.append((int(t), v.decode("utf-8", "replace")))
        except ValueError:
            return None
        return Msg(fields)
