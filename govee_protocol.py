"""Govee H617A BLE frame construction.

Frames are 20 bytes: [type, command, payload..., zero padding, xor checksum].
Byte layouts are taken from rnodern/govee-h617a-ble (captured from the iOS app)
and Jaano/govee_lights, which agree on every frame used here.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence

SERVICE_UUID = "00010203-0405-0607-0809-0a0b0c0d1910"
CONTROL_UUID = "00010203-0405-0607-0809-0a0b0c0d2b11"  # write without response
STATUS_UUID = "00010203-0405-0607-0809-0a0b0c0d2b10"  # notify

COMMAND = 0x33
QUERY = 0xAA
MULTIPART = 0xA3

POWER = 0x01
BRIGHTNESS = 0x04
COLOR = 0x05
SEGMENT_MODE = 0x15

# The captured whole-strip mask is ff 7f: bits 0-14, i.e. 15 segments.
SEGMENT_COUNT = 15
ALL_SEGMENTS = (1 << SEGMENT_COUNT) - 1

RGB = tuple[int, int, int]


def frame(command: int, payload: Iterable[int] = (), kind: int = COMMAND) -> bytes:
    data = [kind, command, *payload]
    if len(data) > 19:
        raise ValueError("payload too long")
    data += [0] * (19 - len(data))
    checksum = 0
    for b in data:
        checksum ^= b
    return bytes(data + [checksum])


def power(on: bool) -> bytes:
    return frame(POWER, [int(on)])


def brightness(percent: int) -> bytes:
    """H617A uses a 1-100 scale."""
    return frame(BRIGHTNESS, [max(1, min(100, percent))])


def segment_color(rgb: RGB, mask: int = ALL_SEGMENTS) -> bytes:
    """Set every segment whose bit is set in `mask` to one colour.

    33 05 15 01 R G B 00 00 00 00 00 <mask lo> <mask hi>
    """
    r, g, b = rgb
    return frame(COLOR, [SEGMENT_MODE, 0x01, r, g, b, 0, 0, 0, 0, 0, mask & 0xFF, (mask >> 8) & 0xFF])


def segments_frames(colors: Sequence[RGB]) -> list[bytes]:
    """One frame per distinct colour, with segments sharing a colour merged into one mask."""
    masks: dict[RGB, int] = {}
    for i, c in enumerate(colors):
        masks[c] = masks.get(c, 0) | (1 << i)
    return [segment_color(c, m) for c, m in masks.items()]


def query(command: int) -> bytes:
    return frame(command, kind=QUERY)


def diy_frames(colors: Sequence[RGB], brightness_pct: int = 100) -> list[bytes]:
    """Experimental: upload a full 15-colour pattern as a static 'Finger Sketch' DIY.

    Encoding from rnodern/govee-h617a-ble diy.py (animation 'clockwise', speed 0).
    Up to 15 colours fit in ~6 frames instead of 15 segment frames. Whether
    speed 0 is truly static, and how fast it can be re-uploaded, is untested.
    """
    groups: dict[RGB, list[int]] = {}
    for i, c in enumerate(colors):
        groups.setdefault(c, []).append(i)
    payload = [0x09, 0, brightness_pct, 1, 1, 1, len(groups)]
    for c, segs in groups.items():
        payload += [len(segs), *c, *segs]
    chunks = [payload[i:i + 17] for i in range(14, len(payload), 17)] or [[]]
    out = [frame(0x00, [0x01, 1 + len(chunks), 0x03, *payload[:14]], kind=MULTIPART)]
    for i, chunk in enumerate(chunks, start=1):
        out.append(frame(0xFF if i == len(chunks) else i, chunk, kind=MULTIPART))
    out.append(frame(COLOR, [0x0A, 0x20, 0x03]))
    return out
