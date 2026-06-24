import CoreBluetooth
import Foundation

/// A main-actor CoreBluetooth central wrapper that bridges the delegate API to async/await and
/// `AsyncStream`. Pinned to `@MainActor` (not an actor) because CoreBluetooth objects are
/// non-Sendable; `CBCentralManager(delegate:queue: nil)` delivers callbacks on the main thread, so
/// the `nonisolated` delegate methods can safely `MainActor.assumeIsolated` back onto this actor.
///
/// Designed for one peripheral session at a time (sufficient for the CLI sniffer and a future
/// single-device biofeedback view).
@MainActor
public final class BLECentral: NSObject {
    private var manager: CBCentralManager!
    private let started = DispatchTime.now()

    // Power-state readiness.
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    // Scanning.
    private var scanContinuation: AsyncStream<DiscoveredPeripheral>.Continuation?

    // Connecting.
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var pendingMatch: ((CBPeripheral, [String: Any]) -> Bool)?
    private var peripheral: CBPeripheral?

    // Discovery steps (continuation per in-flight request).
    private var discoverServicesWaiter: CheckedContinuation<Void, Error>?
    private var discoverCharsWaiters: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var discoverDescWaiters: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var readWaiters: [CBUUID: CheckedContinuation<Data?, Never>] = [:]

    // Live streams.
    private var notificationContinuation: AsyncStream<RawNotification>.Continuation?
    private var measurementContinuation: AsyncStream<PulseOxMeasurement>.Continuation?
    private var activeParser: MeasurementParser?

    public override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    /// Construct from a non-isolated async context (hops onto the main actor).
    public static func make() -> BLECentral { BLECentral() }

    // MARK: - State

    public var isPoweredOn: Bool { manager.state == .poweredOn }
    public var stateDescription: String { Self.describe(manager.state) }
    public var authorizationDescription: String { Self.describe(CBManager.authorization) }

    private func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000_000
    }

    /// Resolve once Bluetooth is powered on; throw on a terminal state (denied/off/unsupported).
    public func waitUntilReady() async throws {
        switch manager.state {
        case .poweredOn: return
        case .unauthorized: throw BLEError.permissionDenied
        case .poweredOff: throw BLEError.poweredOff
        case .unsupported: throw BLEError.unsupported
        default: break // .unknown / .resetting → wait for the next state update
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyWaiters.append(cont)
        }
    }

    private func resolveReady(_ state: CBManagerState) {
        guard !readyWaiters.isEmpty else { return }
        let waiters = readyWaiters
        let resume: (CheckedContinuation<Void, Error>) -> Void
        switch state {
        case .poweredOn: resume = { $0.resume() }
        case .unauthorized: resume = { $0.resume(throwing: BLEError.permissionDenied) }
        case .poweredOff: resume = { $0.resume(throwing: BLEError.poweredOff) }
        case .unsupported: resume = { $0.resume(throwing: BLEError.unsupported) }
        default: return // keep waiting
        }
        readyWaiters.removeAll()
        waiters.forEach(resume)
    }

    // MARK: - Scanning

    /// Stream of discovered peripherals. Allows duplicates so RSSI keeps refreshing. Call
    /// `waitUntilReady()` first. Finishing the stream (or `finishActiveStreams()`) stops the scan.
    public func scan(filterServices: [CBUUID]? = nil) -> AsyncStream<DiscoveredPeripheral> {
        let (stream, continuation) = AsyncStream<DiscoveredPeripheral>.makeStream()
        scanContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stopScanning() }
        }
        manager.scanForPeripherals(
            withServices: filterServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        return stream
    }

    private func stopScanning() {
        if manager.state == .poweredOn { manager.stopScan() }
        scanContinuation = nil
    }

    // MARK: - Connecting

    /// Scan for and connect to the first peripheral matching `match`, or throw on timeout.
    public func connect(matching match: PeripheralMatch, timeout: TimeInterval) async throws {
        try await waitUntilReady()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connectContinuation = cont
            pendingMatch = { peripheral, adv in
                switch match {
                case .id(let uuid):
                    return peripheral.identifier == uuid
                case .name(let needle):
                    let advName = adv[CBAdvertisementDataLocalNameKey] as? String
                    let name = peripheral.name ?? advName ?? ""
                    return name.range(of: needle, options: .caseInsensitive) != nil
                }
            }
            manager.scanForPeripherals(withServices: nil, options: nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let pending = self.connectContinuation else { return }
                self.connectContinuation = nil
                self.pendingMatch = nil
                if self.manager.state == .poweredOn { self.manager.stopScan() }
                pending.resume(throwing: BLEError.deviceNotFound(query: match.description))
            }
        }
    }

    public func disconnect() {
        if manager.state == .poweredOn { manager.stopScan() }
        if let peripheral { manager.cancelPeripheralConnection(peripheral) }
    }

    // MARK: - Discovery / inventory

    /// Discover the full service/characteristic tree, optionally reading every readable value.
    public func inventory(readValues: Bool = true) async throws -> [ServiceInfo] {
        guard let peripheral else { throw BLEError.notConnected }
        try await discoverServices(peripheral)
        var services: [ServiceInfo] = []
        for service in peripheral.services ?? [] {
            try await discoverCharacteristics(peripheral, service)
            var chars: [CharacteristicInfo] = []
            for ch in service.characteristics ?? [] {
                try? await discoverDescriptors(peripheral, ch)
                var value: Data?
                if readValues, ch.properties.contains(.read) {
                    value = await readValue(peripheral, ch)
                }
                chars.append(CharacteristicInfo(
                    uuid: ch.uuid.uuidString,
                    knownName: KnownUUIDs.name(for: ch.uuid),
                    propertiesRaw: ch.properties.rawValue,
                    value: value,
                    descriptors: (ch.descriptors ?? []).map { $0.uuid.uuidString }
                ))
            }
            services.append(ServiceInfo(
                uuid: service.uuid.uuidString,
                knownName: KnownUUIDs.name(for: service.uuid),
                characteristics: chars
            ))
        }
        return services
    }

    private func discoverServices(_ p: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            discoverServicesWaiter = cont
            p.discoverServices(nil)
        }
    }

    private func discoverCharacteristics(_ p: CBPeripheral, _ service: CBService) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            discoverCharsWaiters[service.uuid] = cont
            p.discoverCharacteristics(nil, for: service)
        }
    }

    private func discoverDescriptors(_ p: CBPeripheral, _ ch: CBCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            discoverDescWaiters[ch.uuid] = cont
            p.discoverDescriptors(for: ch)
        }
    }

    private func readValue(_ p: CBPeripheral, _ ch: CBCharacteristic) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            readWaiters[ch.uuid] = cont
            p.readValue(for: ch)
        }
    }

    // MARK: - Subscriptions

    /// Subscribe to notifying/indicating characteristics. Pass `uuids` (uppercased match) to limit
    /// the set, or `nil` to subscribe to every streaming characteristic on the device.
    public func subscribe(characteristics uuids: [String]? = nil) async throws {
        guard let peripheral else { throw BLEError.notConnected }
        try await discoverServices(peripheral)
        let wanted = uuids.map { Set($0.map { $0.uppercased() }) }
        for service in peripheral.services ?? [] {
            try await discoverCharacteristics(peripheral, service)
            for ch in service.characteristics ?? []
            where ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                if let wanted, !wanted.contains(ch.uuid.uuidString.uppercased()) { continue }
                peripheral.setNotifyValue(true, for: ch)
            }
        }
    }

    /// Raw timestamped notifications for capture (`raw` command).
    public func notifications() -> AsyncStream<RawNotification> {
        let (stream, continuation) = AsyncStream<RawNotification>.makeStream()
        notificationContinuation = continuation
        return stream
    }

    /// Parsed measurements for live decoding (`decode` command). Set before `subscribe`.
    public func measurements(using parser: MeasurementParser) -> AsyncStream<PulseOxMeasurement> {
        activeParser = parser
        let (stream, continuation) = AsyncStream<PulseOxMeasurement>.makeStream()
        measurementContinuation = continuation
        return stream
    }

    /// Finish all live streams (called from a SIGINT handler so capture loops fall through to cleanup).
    public func finishActiveStreams() {
        scanContinuation?.finish()
        notificationContinuation?.finish()
        measurementContinuation?.finish()
    }

    // MARK: - Helpers

    private static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    private static func describe(_ auth: CBManagerAuthorization) -> String {
        switch auth {
        case .allowedAlways: return "allowedAlways"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
}

// CoreBluetooth is created with `queue: nil`, so it delivers these on the main thread. `@preconcurrency`
// lets these `@MainActor` methods satisfy the (nonisolated) delegate requirements; the compiler inserts
// a runtime assertion that each call really is on the main actor, which `queue: nil` guarantees. The
// non-Sendable CB parameters are therefore used directly on the main actor — no cross-domain sending.
extension BLECentral: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        resolveReady(central.state)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        scanContinuation?.yield(DiscoveredPeripheral(
            id: peripheral.identifier,
            name: peripheral.name ?? advName,
            rssi: RSSI.intValue,
            advertisedServices: services.map { $0.uuidString },
            isConnectable: connectable
        ))

        if let match = pendingMatch, match(peripheral, advertisementData) {
            pendingMatch = nil
            self.peripheral = peripheral
            peripheral.delegate = self
            manager.stopScan()
            manager.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        let cont = connectContinuation
        connectContinuation = nil
        cont?.resume()
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let cont = connectContinuation
        connectContinuation = nil
        cont?.resume(throwing: BLEError.connectionFailed(reason: error?.localizedDescription ?? "unknown"))
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        finishActiveStreams()
    }
}

extension BLECentral: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let cont = discoverServicesWaiter
        discoverServicesWaiter = nil
        if let error {
            cont?.resume(throwing: BLEError.connectionFailed(reason: error.localizedDescription))
        } else {
            cont?.resume()
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let cont = discoverCharsWaiters.removeValue(forKey: service.uuid)
        if let error {
            cont?.resume(throwing: BLEError.connectionFailed(reason: error.localizedDescription))
        } else {
            cont?.resume()
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let cont = discoverDescWaiters.removeValue(forKey: characteristic.uuid)
        cont?.resume() // descriptor errors are non-fatal for our purposes
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        let data = characteristic.value ?? Data()

        // A pending read takes precedence; otherwise it's a subscription notification.
        if let waiter = readWaiters.removeValue(forKey: uuid) {
            waiter.resume(returning: characteristic.value)
            return
        }

        notificationContinuation?.yield(RawNotification(
            characteristicUUID: uuid.uuidString,
            data: data,
            monotonicSeconds: monotonicSeconds(),
            wallClock: Date()
        ))

        if let parser = activeParser,
           let measurement = parser.parse(characteristic: uuid, value: data) {
            measurementContinuation?.yield(measurement)
        }
    }
}
