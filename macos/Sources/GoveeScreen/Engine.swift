import AppKit
import ScreenCaptureKit

/// What to show when the capture is pure black, e.g. DRM-protected Netflix/Prime video.
enum Fallback: String, Codable, CaseIterable {
    case warm, drift, off

    var title: String {
        switch self {
        case .warm: "Warm glow"
        case .drift: "Slow colour drift"
        case .off: "Stay dark"
        }
    }

    func colours(count n: Int) -> [SIMD3<Float>]? {
        switch self {
        case .off:
            return nil
        case .warm:
            return Array(repeating: SIMD3(150, 80, 28), count: n)
        case .drift:
            let t = Date().timeIntervalSinceReferenceDate / 120  // one hue cycle per two minutes
            return (0..<n).map { i in
                let c = NSColor(calibratedHue: CGFloat((t + Double(i) * 0.02).truncatingRemainder(dividingBy: 1)),
                                saturation: 0.7, brightness: 0.6, alpha: 1)
                return 255 * SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
            }
        }
    }
}

struct Settings: Codable {
    var enabled = true
    var brightness = 100       // device brightness, 1–100
    var smoothing = 0.25       // fraction moved toward the target per tick
    var centerMix = 0.3
    var saturation = 1.3
    var gamma = 1.6
    var reverse = false
    var monitorSegments = 7    // segments 0..<n follow the screen; the rest get the average
    var displayID: UInt32?
    var blackFallback: Fallback?  // optional so settings saved by older builds still decode

    var fallback: Fallback {
        get { blackFallback ?? .warm }
        set { blackFallback = newValue }
    }

    static func load() -> Settings {
        UserDefaults.standard.data(forKey: "settings").flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "settings") }
}

/// Capture and Bluetooth run as separate loops sharing only the latest target colours,
/// so a slow link drops intermediate frames instead of queueing them.
final class Engine {
    let strip = Strip()
    let capturer = Capturer()
    var settings = Settings.load() { didSet { settings.save() } }
    var onChange: (() -> Void)?
    private(set) var captureStatus = "Idle" { didSet { if captureStatus != oldValue { onChange?() } } }

    static let captureInterval: UInt64 = 100_000_000  // 10 fps
    static let tickInterval = 0.05                    // 20 BLE ticks/s: smaller fade steps
    static let frameBudget = 3                        // frames per tick; measured ceiling ~50/s
    static let threshold = 2                          // skip changes smaller than this per channel
    static let merge = 12                             // segments within this distance share a frame
    static let blackDelay = 3.0                       // seconds of pure black before the fallback kicks in

    private var blackSince: Date?

    private var target: [SIMD3<Float>] = []
    private var smoothed: [SIMD3<Float>] = []
    private var sent: [RGB8?] = []
    private var lastWrite = Date.distantPast
    private var captureTask: Task<Void, Never>?
    private var timer: Timer?

    init() {
        strip.onStatus = { [weak self] _ in self?.onChange?() }
        strip.onReady = { [weak self] in self?.stripReady() }
        resetBuffers()
        if settings.enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        settings.enabled = on
        on ? start() : stop()
    }

    func applyBrightness() { strip.send(Govee.brightness(settings.brightness)) }

    func selectDisplay(_ id: CGDirectDisplayID?) {
        settings.displayID = id
        if settings.enabled { stop(); start() }
    }

    func layoutChanged() {
        resetBuffers()
        if settings.enabled { stop(); start() }
    }

    private func resetBuffers() {
        let n = settings.monitorSegments + 1
        target = Array(repeating: .zero, count: n)
        smoothed = target
        sent = Array(repeating: nil, count: n)
    }

    private func start() {
        guard captureTask == nil else { return }
        captureTask = Task { @MainActor [weak self] in await self?.captureLoop() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        stripReady()
    }

    private func stop() {
        captureTask?.cancel()
        captureTask = nil
        timer?.invalidate()
        timer = nil
        captureStatus = "Paused"
    }

    private func stripReady() {
        guard strip.isReady else { return }
        sent = Array(repeating: nil, count: sent.count)  // force a full resend
        strip.send(Govee.power(true))
        applyBrightness()
    }

    @MainActor
    private func captureLoop() async {
        while !Task.isCancelled {
            do {
                if capturer.display == nil { try await capturer.select(settings.displayID) }
                let frame = try await capturer.grab()
                let s = settings
                blackSince = Self.isBlack(frame) ? (blackSince ?? Date()) : nil
                if let since = blackSince, Date().timeIntervalSince(since) > Self.blackDelay,
                   let colours = s.fallback.colours(count: target.count) {
                    target = colours
                    captureStatus = "Screen black (DRM?): \(s.fallback.title.lowercased())"
                } else {
                    target = Extractor.colours(frame, bands: s.monitorSegments, saturation: Float(s.saturation),
                                               gamma: Float(s.gamma), centerMix: Float(s.centerMix))
                    if let d = capturer.display { captureStatus = "Capturing \(d.width)×\(d.height)" }
                }
            } catch is NoDisplay {
                captureStatus = "Waiting for external display"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                let declined = (error as? SCStreamError)?.code == .userDeclined || (error as NSError).code == -3801
                captureStatus = declined ? "Screen Recording permission needed" : "Capture failed, retrying…"
                capturer.reset()  // display may have been unplugged; reselect next time
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            try? await Task.sleep(nanoseconds: Self.captureInterval)
        }
    }

    /// Protected video captures as exact black; allow a little noise.
    private static func isBlack(_ f: Capturer.Frame) -> Bool {
        var i = 0
        while i < f.pixels.count {
            if f.pixels[i] > 16 || f.pixels[i + 1] > 16 || f.pixels[i + 2] > 16 { return false }
            i += 4
        }
        return true
    }

    private func segmentMask(_ i: Int) -> UInt16 {
        let n = settings.monitorSegments
        if i < n { return 1 << UInt16(settings.reverse ? n - 1 - i : i) }
        return Govee.allSegments & ~UInt16((1 << n) - 1)
    }

    private func tick() {
        guard strip.isReady else { return }
        // `smoothing` is defined per 0.1s; rescale so fade speed doesn't depend on the tick rate.
        let k = 1 - powf(1 - Float(settings.smoothing), Float(Self.tickInterval / 0.1))
        for i in smoothed.indices { smoothed[i] += (target[i] - smoothed[i]) * k }
        let rgb = smoothed.map(RGB8.init)

        // Biggest changes first; merge near-identical colours into one frame.
        let diff = rgb.indices.map { i in sent[i].map { rgb[i].distance($0) } ?? 999 }
        let todo = rgb.indices.filter { diff[$0] > Self.threshold }.sorted { diff[$0] > diff[$1] }
        var groups: [(colour: RGB8, mask: UInt16, members: [Int])] = []
        for i in todo {
            if let g = groups.firstIndex(where: { $0.colour.distance(rgb[i]) <= Self.merge }) {
                groups[g].mask |= segmentMask(i)
                groups[g].members.append(i)
            } else {
                groups.append((rgb[i], segmentMask(i), [i]))
            }
        }
        for g in groups.prefix(Self.frameBudget) {
            guard strip.send(Govee.segmentColor(g.colour, mask: g.mask)) else { break }
            for m in g.members { sent[m] = g.colour }
            lastWrite = Date()
        }
        if Date().timeIntervalSince(lastWrite) > 2, strip.send(Govee.keepalive) { lastWrite = Date() }
    }
}
