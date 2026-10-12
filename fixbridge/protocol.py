"""Line protocol between the EA and the engine.

One message per line, fields separated by '|', each field key=value.
ASCII only. Example: NEW|id=a1|sym=EURUSD|side=B|qty=100000|type=M
"""
from __future__ import annotations


def clean(v):
    return str(v).replace("|", " ").replace("\r", " ").replace("\n", " ")


def mkline(cmd, **kv):
    parts = [cmd]
    for k, v in kv.items():
        if v is None or v == "":
            continue
        parts.append("%s=%s" % (k, clean(v)))
    return "|".join(parts) + "\n"


def parse_line(line):
    parts = line.strip().split("|")
    cmd = parts[0].strip().upper()
    kv = {}
    for p in parts[1:]:
        k, sep, v = p.partition("=")
        if sep:
            kv[k.strip()] = v.strip()
    return cmd, kv


def fmt_num(x):
    s = ("%.8f" % float(x)).rstrip("0").rstrip(".")
    return s or "0"
