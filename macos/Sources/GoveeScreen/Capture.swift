import ScreenCaptureKit

/// Downscaled screenshots of one display. ScreenCaptureKit scales on the GPU,
/// so we only ever touch a 160×90 image.
struct NoDisplay: Error {}

final class Capturer {
    struct Frame { var pixels: [UInt8]; var width: Int; var height: Int }  // RGBX

    private(set) var display: SCDisplay?
    private var filter: SCContentFilter?
    private let config: SCStreamConfiguration = {
        let c = SCStreamConfiguration()
        c.width = 160
        c.height = 90
        c.showsCursor = false
        return c
    }()

    static func displays() async throws -> [SCDisplay] {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
    }

    static func isBuiltin(_ d: SCDisplay) -> Bool { CGDisplayIsBuiltin(d.displayID) != 0 }

    /// Use `wanted` if connected, else the first external display. With no external
    /// display we wait rather than mirror the laptop screen.
    func select(_ wanted: CGDirectDisplayID?) async throws {
        let ds = try await Self.displays()
        guard let d = ds.first(where: { $0.displayID == wanted }) ?? ds.first(where: { !Self.isBuiltin($0) }) else {
            throw NoDisplay()
        }
        display = d
        filter = SCContentFilter(display: d, excludingWindows: [])
    }

    func reset() {
        display = nil
        filter = nil
    }

    func grab() async throws -> Frame {
        guard let filter else { throw CocoaError(.featureUnsupported) }
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Frame(pixels: px, width: w, height: h)
    }
}

/// Port of sync.py extract(): one colour per vertical band, then the whole-screen average.
enum Extractor {
    static func colours(_ f: Capturer.Frame, bands: Int, saturation: Float, gamma: Float, centerMix: Float) -> [SIMD3<Float>] {
        let w = f.width, h = f.height, px = f.pixels
        func pixel(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * w + x) * 4
            return SIMD3(Float(px[i]), Float(px[i + 1]), Float(px[i + 2]))
        }

        // Trim letterbox/pillarbox bars so they don't drag colours toward black.
        var top = h, bottom = -1, left = w, right = -1
        for y in 0..<h {
            for x in 0..<w where pixel(x, y).max() > 24 {
                top = min(top, y); bottom = max(bottom, y); left = min(left, x); right = max(right, x)
            }
        }
        if bottom < 0 { (top, bottom, left, right) = (0, h - 1, 0, w - 1) }
        let cw = right - left + 1, ch = bottom - top + 1

        // A plain mean averages toward grey; weight pixels by chroma so vivid parts set the hue.
        var bandSum = [SIMD3<Float>](repeating: .zero, count: bands), bandW = [Float](repeating: 0, count: bands)
        var all = SIMD3<Float>.zero, allW: Float = 0, mid = SIMD3<Float>.zero, midW: Float = 0
        for y in top...bottom {
            for x in left...right {
                let p = pixel(x, y)
                let chroma = (p.max() - p.min()) / 255
                let wt = 0.05 + chroma * chroma
                let b = (x - left) * bands / cw
                bandSum[b] += p * wt; bandW[b] += wt
                all += p * wt; allW += wt
                let rx = x - left, ry = y - top
                if rx >= cw / 4 && rx < 3 * cw / 4 && ry >= ch / 4 && ry < 3 * ch / 4 { mid += p * wt; midW += wt }
            }
        }
        let average = all / allW
        let center = midW > 0 ? mid / midW : average

        // Blend the middle of the picture into every band so the main subject tints the whole strip.
        let out = (0..<bands).map { b in
            (1 - centerMix) * (bandW[b] > 0 ? bandSum[b] / bandW[b] : average) + centerMix * center
        } + [average]

        return out.map { c in
            let grey = (c.x + c.y + c.z) / 3
            let s = (grey + (c - grey) * saturation).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255)) / 255
            // LEDs look much brighter than the screen for dim colours; gamma > 1 tames that.
            return 255 * SIMD3(powf(s.x, gamma), powf(s.y, gamma), powf(s.z, gamma))
        }
    }
}
