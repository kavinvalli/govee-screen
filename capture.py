"""Downscaled screenshots of one display via ScreenCaptureKit.

SCScreenshotManager scales on the GPU, so we only ever receive a ~160x90
image instead of a 4K frame.

    uv run capture.py          # list displays and time a few captures
"""

from __future__ import annotations

import asyncio
import time

import numpy as np
import Quartz
import ScreenCaptureKit as SC


def _objc_call(start) -> asyncio.Future:
    """Run an ObjC method taking a (result, error) completion handler, as an awaitable."""
    loop = asyncio.get_running_loop()
    fut = loop.create_future()

    def handler(result, error):
        def finish():
            if fut.done():
                return
            if error is not None:
                fut.set_exception(RuntimeError(str(error)))
            else:
                fut.set_result(result)
        loop.call_soon_threadsafe(finish)

    start(handler)
    return fut


async def displays() -> list:
    content = await _objc_call(SC.SCShareableContent.getShareableContentWithCompletionHandler_)
    return list(content.displays())


def describe(display) -> str:
    builtin = Quartz.CGDisplayIsBuiltin(display.displayID())
    return f"id={display.displayID()} {display.width()}x{display.height()}{' (built-in)' if builtin else ''}"


class Capturer:
    def __init__(self, display, width: int = 160, height: int = 90):
        self.filter = SC.SCContentFilter.alloc().initWithDisplay_excludingWindows_(display, [])
        self.config = SC.SCStreamConfiguration.alloc().init()
        self.config.setWidth_(width)
        self.config.setHeight_(height)
        self.config.setShowsCursor_(False)

    @classmethod
    async def for_external(cls, display_id: int | None = None, **kw) -> "Capturer":
        """Pick `display_id`, else the first non-built-in display, else the main one."""
        ds = await displays()
        if not ds:
            raise RuntimeError("No displays. Grant Screen Recording permission to your terminal.")
        chosen = next((d for d in ds if d.displayID() == display_id), None) if display_id else None
        chosen = chosen or next((d for d in ds if not Quartz.CGDisplayIsBuiltin(d.displayID())), ds[0])
        print(f"Capturing display {describe(chosen)}")
        return cls(chosen, **kw)

    async def grab(self) -> np.ndarray:
        """Return an (H, W, 3) uint8 RGB array."""
        img = await _objc_call(
            lambda h: SC.SCScreenshotManager.captureImageWithFilter_configuration_completionHandler_(
                self.filter, self.config, h
            )
        )
        w, h = Quartz.CGImageGetWidth(img), Quartz.CGImageGetHeight(img)
        bpr = Quartz.CGImageGetBytesPerRow(img)
        data = Quartz.CGDataProviderCopyData(Quartz.CGImageGetDataProvider(img))
        # The backing buffer can be padded past the last row, so trim to h * bpr.
        bgra = np.frombuffer(bytes(data), np.uint8)[: h * bpr].reshape(h, bpr)[:, : w * 4].reshape(h, w, 4)
        return bgra[..., 2::-1]  # BGRA -> RGB


async def _demo() -> None:
    for d in await displays():
        print(" ", describe(d))
    cap = await Capturer.for_external()
    times = []
    for _ in range(10):
        t0 = time.perf_counter()
        frame = await cap.grab()
        times.append((time.perf_counter() - t0) * 1000)
    print(f"frame {frame.shape}, capture median {sorted(times)[5]:.1f} ms")
    print("mean RGB of left/middle/right thirds:", [tuple(int(v) for v in b.mean((0, 1))) for b in np.array_split(frame, 3, axis=1)])


if __name__ == "__main__":
    asyncio.run(_demo())
