from __future__ import annotations

import configparser
import os


def _new_parser():
    cp = configparser.ConfigParser(interpolation=None)
    cp.optionxform = str  # keep symbol case
    return cp


class Config(object):
    @classmethod
    def load(cls, path):
        cp = _new_parser()
        if not cp.read(path):
            raise SystemExit("config file not found: " + path)
        return cls(cp)

    @classmethod
    def from_dict(cls, d):
        cp = _new_parser()
        cp.read_dict(d)
        return cls(cp)

    def __init__(self, cp):
        def sec(name):
            return cp[name] if cp.has_section(name) else cp["DEFAULT"]

        f, b, r = sec("fix"), sec("bridge"), sec("risk")
        self.host = f.get("host", "127.0.0.1")
        self.port = f.getint("port", 9878)
        self.sender = f.get("sender_comp_id", "MT5BRIDGE")
        self.target = f.get("target_comp_id", "VENUE")
        self.begin_string = f.get("begin_string", "FIX.4.4")
        self.heartbeat = f.getint("heartbeat", 30)
        self.reset_on_logon = f.getboolean("reset_on_logon", True)
        self.tls = f.getboolean("tls", False)
        self.tls_verify = f.getboolean("tls_verify", True)
        self.username = f.get("username", "")
        self.password = os.environ.get("FIX_PASSWORD") or f.get("password", "")
        self.account = f.get("account", "")
        self.reconnect_delay = f.getint("reconnect_delay", 5)
        self.store_dir = f.get("store_dir", "./store")

        self.listen_host = b.get("listen_host", "127.0.0.1")
        self.listen_port = b.getint("listen_port", 9100)
        self.dry_run = b.getboolean("dry_run", True)
        self.token = os.environ.get("FIX_BRIDGE_TOKEN") or b.get("auth_token", "")
        self.md_update_type = b.get("md_update_type", "0")
        self.md_depth = b.get("md_depth", "1")

        self.max_qty = r.getfloat("max_qty", 100000.0)
        self.kill_file = r.get("kill_file", "./KILL")
        mapping = dict(cp.items("symbols")) if cp.has_section("symbols") else {}
        allowed = [s.strip() for s in r.get("allowed_symbols", "").split(",") if s.strip()]
        for s in mapping:
            if s not in allowed:
                allowed.append(s)
        self.symbol_map = dict((s, mapping.get(s, s)) for s in allowed)
