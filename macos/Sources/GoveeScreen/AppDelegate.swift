import AppKit
import ScreenCaptureKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var engine: Engine!
    private let menu = NSMenu()
    private let stripStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let captureStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Open Screen Recording Settings…", action: #selector(openPermissions), keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Sync Enabled", action: #selector(toggleEnabled), keyEquivalent: "e")
    private let reverseItem = NSMenuItem(title: "Reverse Direction", action: #selector(toggleReverse), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let displayMenu = NSMenu()
    private let fallbackMenu = NSMenu()

    func applicationDidFinishLaunching(_ note: Notification) {
        engine = Engine()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        buildMenu()
        engine.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func buildMenu() {
        menu.delegate = self
        stripStatus.isEnabled = false
        captureStatus.isEnabled = false
        for i in [permissionItem, enabledItem, reverseItem, loginItem] { i.target = self }

        menu.addItem(stripStatus)
        menu.addItem(captureStatus)
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(enabledItem)
        menu.addItem(.separator())
        let s = engine.settings
        addSlider("Brightness", Double(s.brightness), 1...100, continuous: false, format: { "\(Int($0))%" }) {
            [unowned self] v in engine.settings.brightness = Int(v); engine.applyBrightness()
        }
        addSlider("Fade", s.smoothing, 0.05...0.6, format: { $0 < 0.15 ? "slow" : $0 < 0.35 ? "medium" : "fast" }) {
            [unowned self] v in engine.settings.smoothing = v
        }
        addSlider("Centre mix", s.centerMix, 0...1, format: { "\(Int($0 * 100))%" }) { [unowned self] v in engine.settings.centerMix = v }
        addSlider("Saturation", s.saturation, 0.5...2.5, format: { String(format: "%.1f×", $0) }) { [unowned self] v in engine.settings.saturation = v }
        addSlider("Dark-scene dimming", s.gamma, 1...3, format: { String(format: "γ %.1f", $0) }) { [unowned self] v in engine.settings.gamma = v }
        menu.addItem(.separator())
        let displays = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        displays.submenu = displayMenu
        menu.addItem(displays)
        menu.addItem(reverseItem)
        let fallback = NSMenuItem(title: "When Screen Is Black (DRM)", action: nil, keyEquivalent: "")
        fallback.submenu = fallbackMenu
        for f in Fallback.allCases {
            let mi = NSMenuItem(title: f.title, action: #selector(pickFallback(_:)), keyEquivalent: "")
            mi.representedObject = f.rawValue
            mi.target = self
            fallbackMenu.addItem(mi)
        }
        menu.addItem(fallback)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit Govee Screen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    private func addSlider(_ title: String, _ value: Double, _ range: ClosedRange<Double>, continuous: Bool = true,
                           format: @escaping (Double) -> String, onChange: @escaping (Double) -> Void) {
        let row = SliderRow(title: title, value: value, range: range, continuous: continuous, format: format, onChange: onChange)
        let mi = NSMenuItem()
        mi.view = row
        menu.addItem(mi)
    }

    private func refresh() {
        stripStatus.title = engine.strip.status
        captureStatus.title = engine.captureStatus
        permissionItem.isHidden = !engine.captureStatus.contains("permission")
        enabledItem.state = engine.settings.enabled ? .on : .off
        reverseItem.state = engine.settings.reverse ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for mi in fallbackMenu.items { mi.state = mi.representedObject as? String == engine.settings.fallback.rawValue ? .on : .off }
        let symbol = engine.settings.enabled ? (engine.strip.isReady ? "lightbulb.led.fill" : "lightbulb.led") : "lightbulb.slash"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Govee Screen")
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        guard menu === self.menu else { return }
        Task { @MainActor in
            let ds = (try? await Capturer.displays()) ?? []
            displayMenu.removeAllItems()
            let auto = NSMenuItem(title: "Automatic (first external)", action: #selector(pickDisplay(_:)), keyEquivalent: "")
            auto.state = engine.settings.displayID == nil ? .on : .off
            displayMenu.addItem(auto)
            for d in ds {
                let mi = NSMenuItem(title: "\(d.width)×\(d.height)\(Capturer.isBuiltin(d) ? " (built-in)" : "")",
                                    action: #selector(pickDisplay(_:)), keyEquivalent: "")
                mi.tag = Int(d.displayID)
                mi.state = engine.settings.displayID == d.displayID ? .on : .off
                displayMenu.addItem(mi)
            }
            for mi in displayMenu.items { mi.target = self }
        }
    }

    @objc private func toggleEnabled() { engine.setEnabled(!engine.settings.enabled); refresh() }

    @objc private func toggleReverse() { engine.settings.reverse.toggle(); engine.layoutChanged(); refresh() }

    @objc private func pickDisplay(_ sender: NSMenuItem) {
        engine.selectDisplay(sender.tag == 0 ? nil : CGDirectDisplayID(sender.tag))
    }

    @objc private func pickFallback(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let f = Fallback(rawValue: raw) { engine.settings.fallback = f }
        refresh()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Launch at login failed: \(error)")
        }
        refresh()
    }

    @objc private func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

/// A labelled slider usable as a menu item's view.
final class SliderRow: NSView {
    private let label = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private let title: String
    private let format: (Double) -> String
    private let onChange: (Double) -> Void

    init(title: String, value: Double, range: ClosedRange<Double>, continuous: Bool,
         format: @escaping (Double) -> String, onChange: @escaping (Double) -> Void) {
        self.title = title
        self.format = format
        self.onChange = onChange
        slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 46))
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: 24, width: 220, height: 16)
        slider.frame = NSRect(x: 18, y: 4, width: 224, height: 20)
        slider.isContinuous = continuous
        slider.target = self
        slider.action = #selector(changed)
        addSubview(label)
        addSubview(slider)
        updateLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateLabel() { label.stringValue = "\(title): \(format(slider.doubleValue))" }

    @objc private func changed() {
        updateLabel()
        onChange(slider.doubleValue)
    }
}
