import CoreBluetooth

/// Finds, connects to and keeps a connection to the H617A. Runs on the main queue.
final class Strip: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onStatus: ((String) -> Void)?
    var onReady: (() -> Void)?
    private(set) var status = "Starting Bluetooth…" { didSet { onStatus?(status) } }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private let savedIDKey = "stripIdentifier"

    var isReady: Bool { control != nil && peripheral?.state == .connected }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Write without response. Returns false instead of queueing when CoreBluetooth's
    /// buffer is full, so callers drop stale frames rather than building latency.
    @discardableResult
    func send(_ data: Data) -> Bool {
        guard let p = peripheral, let c = control, p.state == .connected, p.canSendWriteWithoutResponse else { return false }
        p.writeValue(data, for: c, type: .withoutResponse)
        return true
    }

    private func scan() {
        status = "Searching for strip…"
        central.scanForPeripherals(withServices: nil)
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        status = "Connecting…"
        central.connect(p)
        // A remembered identifier can go stale; fall back to scanning.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.peripheral === p, p.state != .connected else { return }
            self.central.cancelPeripheralConnection(p)
            self.peripheral = nil
            self.scan()
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            control = nil
            status = c.state == .unauthorized ? "Bluetooth permission needed" : "Bluetooth unavailable"
            return
        }
        if let id = UserDefaults.standard.string(forKey: savedIDKey).flatMap(UUID.init(uuidString:)),
           let p = c.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        } else {
            scan()
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard name.uppercased().contains("H617A") else { return }
        c.stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedIDKey)
        connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Discovering…"
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        peripheral = nil
        scan()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        control = nil
        status = "Disconnected, reconnecting…"
        // A pending connect has no timeout: it completes whenever the strip is back.
        c.connect(p)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics([Govee.controlUUID], for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard control == nil, let c = s.characteristics?.first(where: { $0.uuid == Govee.controlUUID }) else { return }
        control = c
        status = "Connected to \(p.name ?? "strip")"
        onReady?()
    }
}
