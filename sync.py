"""Ambilight: mirror the external monitor's colours onto the H617A.

    uv run sync.py
    uv run sync.py --smoothing 0.15 --saturation 1.5 --reverse

Layout (measured on this setup): segments 0-6 run left->right behind the
monitor and follow 7 vertical bands of the screen; segments 7-14 run down
behind the bed and get the whole-screen average.

Capture and Bluetooth run as separate loops sharing only the latest target
colours, so a slow link drops intermediate frames instead of queueing them.
"""

from __future__ import annotations

import argparse
import asyncio
import time

import numpy as np
from bleak import BleakClient
from bleak.exc import BleakError

import govee_protocol as gp
from capture import Capturer
from poc import find_device

# Measured: ~50 frames/s before the controller starts queueing.
FRAME_BUDGET = 40


def extract(frame: np.ndarray, bands: int, saturation: float, gamma: float, center_mix: float = 0.0) -> np.ndarray:
    """Return (bands + 1, 3) float colours: one per vertical band, then the whole-screen average."""
    img = frame.astype(np.float32)
    lum = img.max(axis=2)
    # Trim letterbox/pillarbox bars so they don't drag colours toward black.
    rows = np.flatnonzero(lum.max(axis=1) > 24)
    cols = np.flatnonzero(lum.max(axis=0) > 24)
    if rows.size and cols.size:
        img = img[rows[0] : rows[-1] + 1, cols[0] : cols[-1] + 1]
    # A plain mean of a whole band averages toward grey. Weight pixels by
    # chroma so the vivid parts of the picture set the hue.
    chroma = img.max(axis=2) - img.min(axis=2)
    weight = 0.05 + (chroma / 255) ** 2

    def wmean(px: np.ndarray, w: np.ndarray) -> np.ndarray:
        return (px * w[..., None]).sum(axis=(0, 1)) / w.sum()

    colours = np.array(
        [wmean(b, w) for b, w in zip(np.array_split(img, bands, axis=1), np.array_split(weight, bands, axis=1))]
        + [wmean(img, weight)]
    )
    # Blend the middle of the picture into every band so the main subject
    # tints the whole strip, not just the segment it happens to sit behind.
    h, w = weight.shape
    center = wmean(img[h // 4 : 3 * h // 4, w // 4 : 3 * w // 4], weight[h // 4 : 3 * h // 4, w // 4 : 3 * w // 4])
    colours[:bands] = (1 - center_mix) * colours[:bands] + center_mix * center
    grey = colours.mean(axis=1, keepdims=True)
    colours = np.clip(grey + (colours - grey) * saturation, 0, 255)
    # LEDs look much brighter than the screen for dim colours; gamma > 1 tames that.
    return 255 * (colours / 255) ** gamma


class State:
    def __init__(self, n: int):
        self.target = np.zeros((n, 3), np.float32)
        self.fps = 0.0


async def capture_loop(cap: Capturer, state: State, args) -> None:
    interval = 1 / args.capture_fps
    n, t_report = 0, time.perf_counter()
    while True:
        t0 = time.perf_counter()
        try:
            state.target = extract(await cap.grab(), args.monitor_segments, args.saturation, args.gamma, args.center_mix)
            n += 1
        except RuntimeError as e:
            print(f"capture failed: {e}")
            await asyncio.sleep(1)
        if (now := time.perf_counter()) - t_report >= 5:
            state.fps, n, t_report = n / (now - t_report), 0, now
        await asyncio.sleep(max(0, interval - (time.perf_counter() - t0)))


def plan_frames(smoothed: np.ndarray, sent: np.ndarray | None, args, segment_of) -> tuple[list[bytes], list[int]]:
    """Pick which outputs to update this tick, merging near-identical colours into one frame."""
    rgb = np.round(smoothed).astype(int)
    diff = np.full(len(rgb), 999) if sent is None else np.abs(rgb - sent).max(axis=1)
    todo = [i for i in np.argsort(-diff) if diff[i] > args.threshold]
    groups: list[tuple[tuple[int, int, int], int, list[int]]] = []
    for i in todo:
        for g, (colour, mask, members) in enumerate(groups):
            if np.abs(rgb[i] - colour).max() <= args.merge:
                groups[g] = (colour, mask | segment_of[i], members + [i])
                break
        else:
            groups.append((tuple(int(v) for v in rgb[i]), segment_of[i], [i]))
    groups = groups[: args.max_frames]
    frames = [gp.segment_color(c, m) for c, m, _ in groups]
    return frames, [i for *_, members in groups for i in members]


async def send_loop(client: BleakClient, state: State, disconnected: asyncio.Event, args) -> None:
    mon = args.monitor_segments
    order = list(range(mon))[::-1] if args.reverse else list(range(mon))
    # Output i -> segment mask. Last output (screen average) drives all remaining segments.
    segment_of = [1 << s for s in order] + [gp.ALL_SEGMENTS & ~((1 << mon) - 1)]
    smoothed = state.target.copy()
    sent: np.ndarray | None = None  # None forces a full resend after (re)connect
    interval = 1 / args.rate
    last_write = time.perf_counter()
    frames_total, t_report = 0, time.perf_counter()

    await client.write_gatt_char(gp.CONTROL_UUID, gp.power(True), response=False)
    while not disconnected.is_set():
        t0 = time.perf_counter()
        smoothed += (state.target - smoothed) * args.smoothing
        frames, updated = plan_frames(smoothed, sent, args, segment_of)
        if frames:
            sent = np.round(smoothed).astype(int) if sent is None else sent
            for f in frames:
                await client.write_gatt_char(gp.CONTROL_UUID, f, response=False)
            sent[updated] = np.round(smoothed[updated]).astype(int)
            frames_total += len(frames)
            last_write = t0
        elif t0 - last_write > 2:
            await client.write_gatt_char(gp.CONTROL_UUID, gp.query(gp.POWER), response=False)  # keepalive
            last_write = t0
        if t0 - t_report >= 5:
            colours = " ".join("#%02x%02x%02x" % tuple(c) for c in sent) if sent is not None else "-"
            print(f"capture {state.fps:4.1f} fps | ble {frames_total / (t0 - t_report):4.1f} frames/s | {colours}")
            frames_total, t_report = 0, t0
        await asyncio.sleep(max(0, interval - (time.perf_counter() - t0)))


async def ble_loop(state: State, args) -> None:
    while True:
        try:
            dev = await find_device(args.address)
            disconnected = asyncio.Event()
            async with BleakClient(dev, timeout=20, disconnected_callback=lambda _: disconnected.set()) as client:
                print(f"Connected to {dev.name}")
                await send_loop(client, state, disconnected, args)
            print("Disconnected, reconnecting...")
        except (BleakError, ConnectionError, TimeoutError, OSError) as e:
            print(f"BLE error: {e}; retrying in 3s")
            await asyncio.sleep(3)


async def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--address")
    p.add_argument("--display", type=int, help="CGDirectDisplayID (see `uv run capture.py`); default: first external")
    p.add_argument("--monitor-segments", type=int, default=7, help="segments behind the monitor, starting at 0")
    p.add_argument("--reverse", action="store_true", help="segment 0 is on the right of the screen")
    p.add_argument("--capture-fps", type=float, default=10)
    p.add_argument("--rate", type=float, default=10, help="BLE update ticks per second")
    p.add_argument("--smoothing", type=float, default=0.25, help="0-1, fraction moved toward target per tick (lower = slower fade)")
    p.add_argument("--saturation", type=float, default=1.3)
    p.add_argument("--gamma", type=float, default=1.6)
    p.add_argument("--center-mix", type=float, default=0.3, help="0-1, how much of the screen centre blends into every segment")
    p.add_argument("--threshold", type=int, default=4, help="skip updates smaller than this (0-255 per channel)")
    p.add_argument("--merge", type=int, default=12, help="segments within this distance share one frame")
    args = p.parse_args()
    args.max_frames = max(1, FRAME_BUDGET // int(args.rate))

    cap = await Capturer.for_external(args.display)
    state = State(args.monitor_segments + 1)
    await asyncio.gather(capture_loop(cap, state, args), ble_loop(state, args))


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
