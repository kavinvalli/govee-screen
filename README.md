# govee-screen

DIY Ambilight for macOS using an existing Govee H617A RGBIC strip over Bluetooth LE. No extra hardware.

The screen is captured with ScreenCaptureKit (downscaled to 160×90 on the GPU), turned into
per-segment colours, smoothed, and streamed to the strip's own Bluetooth controller.

## macOS menu bar app

```sh
cd macos && ./build.sh
open "build/Govee Screen.app"
```

Needs Bluetooth and Screen Recording permission. The app is ad-hoc signed, so macOS asks for
Screen Recording again after each rebuild.

Menu: sync on/off (⌘E), brightness, fade, centre mix, saturation, dark-scene dimming,
display, direction, fallback when the screen is black, launch at login.

## Python prototype

```sh
uv run poc.py scan        # find the strip
uv run poc.py rainbow     # per-segment test
uv run poc.py walk        # light segments one at a time
uv run poc.py bench       # update-rate benchmark
uv run sync.py            # the sync loop
```

## H617A protocol

20-byte frames written without response to `00010203-0405-0607-0809-0a0b0c0d2b11`,
last byte is the XOR of the first 19.

| Frame | Bytes |
|---|---|
| Power | `33 01 <00/01>` |
| Brightness (1–100) | `33 04 <pct>` |
| Segment colour | `33 05 15 01 R G B 00 00 00 00 00 <mask lo> <mask hi>` |
| Keepalive / power query | `aa 01` |

15 segments (mask `ff 7f`). One frame sets one colour on any set of segments, so the app
merges similar colours. The controller sustains roughly 50 frames/s before queueing.
Protocol from [rnodern/govee-h617a-ble](https://github.com/rnodern/govee-h617a-ble) and
[Jaano/govee_lights](https://github.com/Jaano/govee_lights).

## Layout

Configured for this setup: segments 0–6 run left→right behind the monitor and follow the
screen; segments 7–14 get the whole-screen average.

## Limitations

DRM video (Netflix, Prime) captures as black. After 3 s of pure black the app fades to a
fallback (warm glow, slow colour drift, or off).
