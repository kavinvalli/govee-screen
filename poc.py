"""Phase 1 proof of concept: drive a Govee H617A over BLE from macOS.

    uv run poc.py scan
    uv run poc.py on | off
    uv run poc.py color ff0000
    uv run poc.py segment 3 00ff00          # one segment
    uv run poc.py rainbow                   # 15 different colours
    uv run poc.py walk                      # light segments one at a time, to count/locate them
    uv run poc.py bench                     # update-rate benchmarks
    uv run poc.py diy-rainbow               # experimental multi-colour upload

The strip is found by name (Govee_H617A_xxxx / ihoment_H617A_xxxx) unless
--address is given. Close the Govee phone app first: the controller accepts
only one connection.
"""

from __future__ import annotations

import argparse
import asyncio
import colorsys
import statistics
import sys
import time
from pathlib import Path

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice

import govee_protocol as gp

ADDRESS_CACHE = Path(__file__).with_name(".govee_address")


def is_h617a(name: str | None) -> bool:
    return bool(name) and "H617A" in name.upper()


async def scan(timeout: float = 8.0) -> None:
    print(f"Scanning {timeout:.0f}s...")
    found = await BleakScanner.discover(timeout=timeout, return_adv=True)
    rows = sorted(found.values(), key=lambda da: -da[1].rssi)
    for dev, adv in rows:
        name = dev.name or adv.local_name or ""
        govee = "govee" in name.lower() or "ihoment" in name.lower() or gp.SERVICE_UUID in adv.service_uuids
        if govee:
            mfr = {hex(k): v.hex() for k, v in adv.manufacturer_data.items()}
            print(f"  {'*' if is_h617a(name) else ' '} {dev.address}  rssi={adv.rssi:4}  {name}  {mfr}")
    if not any(is_h617a(d.name or a.local_name) for d, a in rows):
        print("No H617A seen. Is the strip powered and the Govee app closed?")


async def find_device(address: str | None) -> BLEDevice:
    address = address or (ADDRESS_CACHE.read_text().strip() if ADDRESS_CACHE.exists() else None)
    if address:
        dev = await BleakScanner.find_device_by_address(address, timeout=10)
        if dev:
            return dev
        print(f"{address} not seen, falling back to name scan")
    dev = await BleakScanner.find_device_by_filter(
        lambda d, adv: is_h617a(d.name or adv.local_name), timeout=15
    )
    if not dev:
        raise ConnectionError("No H617A found. Power-cycle the strip and close the Govee app.")
    ADDRESS_CACHE.write_text(dev.address)
    return dev


class Strip:
    def __init__(self, client: BleakClient):
        self.client = client
        self.notifications: asyncio.Queue[bytes] = asyncio.Queue()

    async def start(self) -> None:
        await self.client.start_notify(gp.STATUS_UUID, lambda _, data: self.notifications.put_nowait(bytes(data)))

    async def send(self, *frames: bytes, response: bool = False) -> None:
        for f in frames:
            await self.client.write_gatt_char(gp.CONTROL_UUID, f, response=response)

    async def ping(self, timeout: float = 2.0) -> float:
        """Round trip of a power query → notification, in ms."""
        while not self.notifications.empty():
            self.notifications.get_nowait()
        t0 = time.perf_counter()
        await self.send(gp.query(gp.POWER))
        while True:
            data = await asyncio.wait_for(self.notifications.get(), timeout)
            if data[:2] == bytes([gp.QUERY, gp.POWER]):
                return (time.perf_counter() - t0) * 1000


def parse_rgb(s: str) -> gp.RGB:
    s = s.lstrip("#")
    return int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16)


def rainbow(offset: float = 0.0) -> list[gp.RGB]:
    out = []
    for i in range(gp.SEGMENT_COUNT):
        r, g, b = colorsys.hsv_to_rgb((i / gp.SEGMENT_COUNT + offset) % 1.0, 1, 1)
        out.append((int(r * 255), int(g * 255), int(b * 255)))
    return out


async def bench(strip: Strip, seconds: float) -> None:
    print("\n[1] Query round trip (aa01 → notify), 20 samples")
    rtts = []
    for _ in range(20):
        try:
            rtts.append(await strip.ping())
        except TimeoutError:
            print("  timeout")
        await asyncio.sleep(0.05)
    if rtts:
        print(f"  median {statistics.median(rtts):.1f} ms, min {min(rtts):.1f}, max {max(rtts):.1f}")

    # macOS returns from write-without-response immediately, so throughput must be
    # paced by us. A query is interleaved every ~0.5s; if its round trip grows while
    # streaming, frames are queueing somewhere and latency is building up.
    async def run(label: str, make_frames, fps: float) -> None:
        interval = 1 / fps
        rtts: list[float] = []
        lost = 0
        pending: float | None = None
        n = 0
        t0 = time.perf_counter()
        next_query = t0 + 0.5
        while (now := time.perf_counter()) - t0 < seconds:
            while not strip.notifications.empty():
                data = strip.notifications.get_nowait()
                if pending and data[:2] == bytes([gp.QUERY, gp.POWER]):
                    rtts.append((time.perf_counter() - pending) * 1000)
                    pending = None
            if now >= next_query:
                if pending:
                    lost += 1
                pending = time.perf_counter()
                await strip.send(gp.query(gp.POWER))
                next_query = now + 0.5
            await strip.send(*make_frames(n))
            n += 1
            await asyncio.sleep(max(0, t0 + n * interval - time.perf_counter()))
        dt = time.perf_counter() - t0
        rtt = f"query RTT median {statistics.median(rtts):5.0f} ms, max {max(rtts):5.0f}" if rtts else "no query replies"
        print(f"  {label:>28}: {n / dt:5.1f} updates/s | {rtt} | {lost} unanswered")
        await asyncio.sleep(1)

    rb = [gp.segment_color((255, 0, 0)), gp.segment_color((0, 0, 255))]
    print(f"\n[2] Whole strip alternating red/blue (1 frame/update), {seconds:.0f}s per rate")
    for fps in (10, 20, 30, 50):
        print(f"  -> {fps}/s now")
        await run(f"whole strip @ {fps}/s", lambda i: [rb[i % 2]], fps)

    print("\n[3] Scrolling rainbow on segments 0-6 (7 frames/update)")
    for fps in (5, 10, 15):
        print(f"  -> {fps}/s now")
        await run(f"7 segments @ {fps}/s", lambda i: gp.segments_frames(rainbow(i / 40)[:7]), fps)
    print("\nReport what you saw: at which rates did flashing stay crisp vs. lag, smear or freeze?")


async def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--address", help="CoreBluetooth UUID of the strip (cached in .govee_address after first find)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan")
    sub.add_parser("on")
    sub.add_parser("off")
    sub.add_parser("color").add_argument("rgb")
    sp = sub.add_parser("brightness")
    sp.add_argument("percent", type=int)
    sp = sub.add_parser("segment")
    sp.add_argument("index", type=int, help="0-based; 15 probes for a 16th segment")
    sp.add_argument("rgb")
    sub.add_parser("rainbow")
    sp = sub.add_parser("walk")
    sp.add_argument("--delay", type=float, default=1.5)
    sp = sub.add_parser("bench")
    sp.add_argument("--seconds", type=float, default=5)
    sub.add_parser("diy-rainbow")
    args = p.parse_args()

    if args.cmd == "scan":
        return await scan()

    dev = await find_device(args.address)
    print(f"Connecting to {dev.name} ({dev.address})...")
    t0 = time.perf_counter()
    async with BleakClient(dev, timeout=20) as client:
        print(f"Connected in {(time.perf_counter() - t0):.1f}s")
        strip = Strip(client)
        await strip.start()

        if args.cmd in ("on", "off"):
            await strip.send(gp.power(args.cmd == "on"))
        elif args.cmd == "color":
            await strip.send(gp.power(True), gp.segment_color(parse_rgb(args.rgb)))
        elif args.cmd == "brightness":
            await strip.send(gp.brightness(args.percent))
        elif args.cmd == "segment":
            await strip.send(gp.segment_color(parse_rgb(args.rgb), 1 << args.index))
        elif args.cmd == "rainbow":
            await strip.send(gp.power(True), *gp.segments_frames(rainbow()))
        elif args.cmd == "walk":
            await strip.send(gp.power(True))
            for i in range(gp.SEGMENT_COUNT + 1):  # +1 probes bit 15
                await strip.send(gp.segment_color((0, 0, 0)), gp.segment_color((255, 255, 255), 1 << i))
                print(f"  segment {i} lit (bit {i}){'  <- beyond expected 15' if i >= gp.SEGMENT_COUNT else ''}")
                await asyncio.sleep(args.delay)
        elif args.cmd == "bench":
            await strip.send(gp.power(True))
            await bench(strip, args.seconds)
        elif args.cmd == "diy-rainbow":
            frames = gp.diy_frames(rainbow())
            print(f"Uploading DIY pattern in {len(frames)} frames")
            for f in frames:
                await strip.send(f)
                await asyncio.sleep(0.05)

        # Let queued write-without-response frames drain before disconnecting.
        await asyncio.sleep(0.3)
        try:
            print(f"Controller responsive, query RTT {await strip.ping():.0f} ms")
        except TimeoutError:
            print("No query response (frames may still have been applied)")


if __name__ == "__main__":
    asyncio.run(main())
