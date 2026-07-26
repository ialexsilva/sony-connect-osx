import Foundation
import IOBluetooth
import OSLog
import SonyConnectCore

private let log = Logger(subsystem: "com.tanat.sonyconnect", category: "bluetooth")

final class BluetoothClient: NSObject {
    enum Status {
        case disconnected
        case searching
        case connecting(deviceName: String)
        case connected(
            deviceName: String,
            endpoint: SonyServiceEndpoint
        )
        case failed(reason: String)
    }

    private enum ServiceOpenResult {
        case opened
        case notFound
        case failed(reason: String)
    }

    private enum ServiceCandidateOpenResult {
        case opened
        case exhausted(reason: String)
    }

    private struct ServiceCandidate {
        let endpoint: SonyServiceEndpoint
        let channelID: BluetoothRFCOMMChannelID
    }

    var onStatus: ((Status) -> Void)?
    var onData: ((Data) -> Void)?
    // Fires when the headphones' baseband (ACL) link to the Mac comes or
    // goes — independent of whether our SPP control channel is open.
    // Passes (reachable, deviceName?).
    var onReachabilityChange: ((Bool, String?) -> Void)?

    private var channel: IOBluetoothRFCOMMChannel?
    private var device: IOBluetoothDevice?
    private var activeEndpoint: SonyServiceEndpoint?
    private var pendingServiceCandidates: [ServiceCandidate] = []
    private var lastServiceOpenFailure: String?
    private var reconnectTimer: Timer?
    private var suppressAutoReconnect = false
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?
    private static let reconnectInterval: TimeInterval = 5
    private(set) var status: Status = .disconnected {
        didSet {
            FileLogger.shared.log("bt", "status -> \(status)")
            onStatus?(status)
            switch status {
            case .connected:
                cancelReconnect()
            case .failed:
                scheduleReconnect()
            case .disconnected:
                if !suppressAutoReconnect {
                    scheduleReconnect()
                }
            case .searching, .connecting:
                break
            }
        }
    }

    // Begin watching the paired headphones' baseband connection so the UI
    // can reflect "device present" vs. "device off/out of range" even while
    // our SPP channel is intentionally closed for battery saving.
    func startReachabilityMonitoring() {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(aclDeviceConnected(_:device:))
        )
        if let target = targetPairedDevice(), target.isConnected() {
            registerDisconnect(for: target)
            onReachabilityChange?(true, target.name)
        } else {
            onReachabilityChange?(false, nil)
        }
    }

    func isTargetDeviceConnected() -> Bool {
        targetPairedDevice()?.isConnected() ?? false
    }

    private func targetPairedDevice() -> IOBluetoothDevice? {
        guard let raw = IOBluetoothDevice.pairedDevices() else { return nil }
        let devices = raw.compactMap { $0 as? IOBluetoothDevice }
        return devices.first { isTargetDevice($0) }
    }

    private func isTargetDevice(_ device: IOBluetoothDevice) -> Bool {
        let name = device.name ?? ""
        return SupportedDevices.nameHints.contains { name.contains($0) }
    }

    private func registerDisconnect(for device: IOBluetoothDevice) {
        disconnectNotification?.unregister()
        disconnectNotification = device.register(
            forDisconnectNotification: self,
            selector: #selector(aclDeviceDisconnected(_:device:))
        )
    }

    @objc private func aclDeviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard isTargetDevice(device) else { return }
        FileLogger.shared.log("bt", "ACL connected: \(device.name ?? "?")")
        registerDisconnect(for: device)
        onReachabilityChange?(true, device.name)
    }

    @objc private func aclDeviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard isTargetDevice(device) else { return }
        FileLogger.shared.log("bt", "ACL disconnected: \(device.name ?? "?")")
        onReachabilityChange?(false, device.name)
    }

    func connect() {
        suppressAutoReconnect = false
        cancelReconnect()
        if case .connected = status { return }
        if case .connecting = status { return }
        activeEndpoint = nil
        pendingServiceCandidates.removeAll(keepingCapacity: true)
        lastServiceOpenFailure = nil
        status = .searching

        guard let target = targetPairedDevice() else {
            status = .failed(reason: "No supported Sony headphones paired")
            return
        }

        device = target
        let name = target.name ?? target.addressString ?? "Sony headphones"
        status = .connecting(deviceName: name)

        switch findServiceAndOpen(device: target) {
        case .opened:
            return
        case .failed(let reason):
            status = .failed(reason: reason)
            return
        case .notFound:
            break
        }

        log.info("Sony service records not cached; performing SDP query")
        if target.performSDPQuery(self) != kIOReturnSuccess {
            status = .failed(reason: "SDP query failed to start")
        }
    }

    func disconnect() {
        suppressAutoReconnect = true
        cancelReconnect()
        channel?.close()
        channel = nil
        device = nil
        activeEndpoint = nil
        pendingServiceCandidates.removeAll(keepingCapacity: true)
        lastServiceOpenFailure = nil
        status = .disconnected
    }

    private func scheduleReconnect() {
        guard reconnectTimer == nil else { return }
        let t = Timer(timeInterval: Self.reconnectInterval, repeats: false) { [weak self] _ in
            self?.reconnectTimer = nil
            self?.attemptReconnect()
        }
        reconnectTimer = t
        RunLoop.main.add(t, forMode: .common)
        FileLogger.shared.log("bt", "reconnect scheduled in \(Int(Self.reconnectInterval))s")
    }

    private func cancelReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func attemptReconnect() {
        switch status {
        case .connected, .connecting, .searching:
            return
        case .disconnected, .failed:
            FileLogger.shared.log("bt", "reconnect attempt")
            connect()
        }
    }

    func send(_ data: Data) {
        guard let channel = channel else {
            FileLogger.shared.log("bt", "send: NO CHANNEL")
            return
        }
        FileLogger.shared.hex("tx", data)
        var bytes = [UInt8](data)
        let result = bytes.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            guard let base = buffer.baseAddress else { return kIOReturnNoMemory }
            return channel.writeSync(base, length: UInt16(buffer.count))
        }
        if result != kIOReturnSuccess {
            FileLogger.shared.log("bt", "writeSync failed: \(result)")
        }
    }

    private func findServiceAndOpen(
        device: IOBluetoothDevice
    ) -> ServiceOpenResult {
        var foundKnownService = false
        pendingServiceCandidates.removeAll(keepingCapacity: true)
        lastServiceOpenFailure = nil

        for endpoint in SonyServiceEndpoint.connectionPriority {
            let bytes = endpoint.uuidBytes
            let uuid = IOBluetoothSDPUUID(
                bytes: bytes,
                length: bytes.count
            )
            guard let record = device.getServiceRecord(for: uuid) else {
                continue
            }

            foundKnownService = true
            FileLogger.shared.log(
                "bt",
                "Sony \(endpoint.rawValue.uppercased()) service found: \(record.getServiceName() ?? "?")"
            )

            var channelID: BluetoothRFCOMMChannelID = 0
            let channelResult = record.getRFCOMMChannelID(&channelID)
            guard channelResult == kIOReturnSuccess else {
                lastServiceOpenFailure =
                    "Sony \(endpoint.rawValue.uppercased()) service has no RFCOMM channel"
                continue
            }
            FileLogger.shared.log(
                "bt",
                "\(endpoint.rawValue.uppercased()) RFCOMM channel id = \(channelID)"
            )

            pendingServiceCandidates.append(
                ServiceCandidate(
                    endpoint: endpoint,
                    channelID: channelID
                )
            )
        }

        if !pendingServiceCandidates.isEmpty {
            switch openNextService(on: device) {
            case .opened:
                return .opened
            case .exhausted(let reason):
                return .failed(reason: reason)
            }
        }

        if foundKnownService {
            return .failed(
                reason: lastServiceOpenFailure
                    ?? "Known Sony services could not be opened"
            )
        }

        logCachedServices(for: device)
        return .notFound
    }

    private func openNextService(
        on device: IOBluetoothDevice
    ) -> ServiceCandidateOpenResult {
        while !pendingServiceCandidates.isEmpty {
            let candidate = pendingServiceCandidates.removeFirst()
            var openedChannel: IOBluetoothRFCOMMChannel?
            activeEndpoint = candidate.endpoint
            let openResult = device.openRFCOMMChannelAsync(
                &openedChannel,
                withChannelID: candidate.channelID,
                delegate: self
            )
            guard openResult == kIOReturnSuccess else {
                activeEndpoint = nil
                lastServiceOpenFailure =
                    "Opening Sony \(candidate.endpoint.rawValue.uppercased()) RFCOMM failed: \(openResult)"
                continue
            }

            channel = openedChannel
            return .opened
        }

        return .exhausted(
            reason: lastServiceOpenFailure
                ?? "Known Sony services could not be opened"
        )
    }

    private func logCachedServices(for device: IOBluetoothDevice) {
        FileLogger.shared.log(
            "bt",
            "Neither Sony V1 nor V2 UUID found in cached SDP records"
        )
        guard let records =
            device.services as? [IOBluetoothSDPServiceRecord] else {
            return
        }

        for record in records {
            var channelID: BluetoothRFCOMMChannelID = 0
            let hasChannel =
                record.getRFCOMMChannelID(&channelID)
                == kIOReturnSuccess
            FileLogger.shared.log(
                "bt",
                "  service: \(record.getServiceName() ?? "?") rfcomm=\(hasChannel ? String(channelID) : "no")"
            )
        }
    }
}

extension BluetoothClient {
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard case .connecting = self.status,
              self.device?.addressString == device?.addressString else {
            return
        }
        guard status == kIOReturnSuccess, let device = device else {
            self.status = .failed(reason: "SDP query failed: \(status)")
            return
        }
        switch findServiceAndOpen(device: device) {
        case .opened:
            break
        case .notFound:
            self.status = .failed(
                reason: "Neither Sony V1 nor V2 service is advertised"
            )
        case .failed(let reason):
            self.status = .failed(reason: reason)
        }
    }
}

extension BluetoothClient: IOBluetoothRFCOMMChannelDelegate {
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard case .connecting = status else {
            rfcommChannel?.close()
            return
        }
        if let channel,
           let callbackChannel = rfcommChannel,
           channel !== callbackChannel {
            callbackChannel.close()
            return
        }
        if error != kIOReturnSuccess {
            if let activeEndpoint {
                lastServiceOpenFailure =
                    "Opening Sony \(activeEndpoint.rawValue.uppercased()) RFCOMM failed asynchronously: \(error)"
            }
            channel = nil
            activeEndpoint = nil
            guard let device else {
                status = .failed(
                    reason: lastServiceOpenFailure
                        ?? "RFCOMM open failed: \(error)"
                )
                return
            }
            switch openNextService(on: device) {
            case .opened:
                FileLogger.shared.log(
                    "bt",
                    "trying the next Sony RFCOMM endpoint"
                )
            case .exhausted(let reason):
                status = .failed(reason: reason)
            }
            return
        }
        guard let endpoint = activeEndpoint else {
            status = .failed(reason: "RFCOMM opened without a Sony endpoint")
            rfcommChannel.close()
            channel = nil
            return
        }
        channel = rfcommChannel
        pendingServiceCandidates.removeAll(keepingCapacity: true)
        lastServiceOpenFailure = nil
        let name = rfcommChannel.getDevice()?.name ?? "Sony headphones"
        status = .connected(deviceName: name, endpoint: endpoint)
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!,
                           length dataLength: Int) {
        guard channel === rfcommChannel else { return }
        let data = Data(bytes: dataPointer, count: dataLength)
        FileLogger.shared.hex("rx", data)
        onData?(data)
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard channel === rfcommChannel else { return }
        channel = nil
        activeEndpoint = nil
        pendingServiceCandidates.removeAll(keepingCapacity: true)
        lastServiceOpenFailure = nil
        status = .disconnected
    }
}
