from __future__ import annotations

import argparse
import asyncio
import logging

from .bridge import Bridge
from .config import Config

log = logging.getLogger("fixbridge")


async def _run(cfg):
    bridge = Bridge(cfg)
    await bridge.start()
    try:
        await asyncio.Event().wait()
    finally:
        await bridge.stop()


def main():
    ap = argparse.ArgumentParser(prog="fixbridge", description="MT5 <-> FIX bridge engine")
    ap.add_argument("-c", "--config", default="config.ini")
    ap.add_argument("-v", "--verbose", action="store_true", help="debug logs (credentials masked)")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cfg = Config.load(args.config)
    if cfg.dry_run:
        log.info("DRY-RUN is ON: orders are simulated, nothing is sent to the venue")
    else:
        log.warning("DRY-RUN is OFF: orders go to the FIX venue")
    try:
        asyncio.run(_run(cfg))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
