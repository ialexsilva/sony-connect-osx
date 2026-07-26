import Foundation
import SonyConnectCore

final class HeadphonesController {
    typealias NCMode = SonyNoiseControlMode
    typealias EqPreset = SonyEqualizerPreset

    struct State {
        var isConnected = false       // SPP control channel is open
        var deviceReachable = false   // headphones present at the BT (ACL) level
        var touchSensorEnabled: Bool?
        var ncMode: NCMode?
        var speakToChatEnabled: Bool?
        var batteryLevel: Int?
        var batteryCharging = false
        var eqPresets: [EqPreset] = []
        var eqCurrentPresetId: UInt8?
        var eqBands: [Int] = []
        var autoOffEnabled = false
        var statusDescription = "Disconnected"
        var ambientLevel = SonyNoiseControlSettings.ambientLevelRange.upperBound
        var ambientFocusOnVoice = false
    }

    static let ambientLevelRange = SonyNoiseControlSettings.ambientLevelRange

    private(set) var state = State() {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?

    private let bluetooth = BluetoothClient()
    private let parser = SonyFrameParser()
    private let protocolAdapter: any SonyProtocolAdapter
    private let autoOff = AutoPowerOff()
    private let media = MediaController()
    private let audioMonitor = AudioActivityMonitor(nameHints: SupportedDevices.nameHints)
    private let policy: ConnectionPolicy
    private var outgoingSequence: UInt8 = 0
    private var initialized = false
    private var awaitingInitResponse = false
    private var deviceName = "headphones"

    init(protocolAdapter: any SonyProtocolAdapter = SonyProtocolV1()) {
        self.protocolAdapter = protocolAdapter
        policy = ConnectionPolicy(audio: audioMonitor)

        bluetooth.onStatus = { [weak self] status in
            self?.handleStatus(status)
        }
        bluetooth.onData = { [weak self] data in
            self?.handleIncoming(data)
        }
        bluetooth.onReachabilityChange = { [weak self] reachable, name in
            self?.handleReachability(reachable, name: name)
        }
        autoOff.onShouldPowerOff = { [weak self] in
            self?.sendPowerOff()
        }
        autoOff.onEnabledChanged = { [weak self] _ in
            guard let self else { return }
            self.state.autoOffEnabled = self.autoOff.isEnabled
        }
        policy.onShouldConnect = { [weak self] in
            self?.bluetooth.connect()
        }
        policy.onShouldDisconnect = { [weak self] in
            FileLogger.shared.log(
                "policy",
                "disconnecting RFCOMM to save headphones battery"
            )
            self?.bluetooth.disconnect()
        }

        state.autoOffEnabled = autoOff.isEnabled
        bluetooth.startReachabilityMonitoring()
        policy.start()
    }

    var autoOffEnabled: Bool {
        get { autoOff.isEnabled }
        set { autoOff.isEnabled = newValue }
    }

    func powerOff() {
        guard initialized else { return }
        sendPowerOff()
    }

    func connect() {
        policy.userActivity()
    }

    // Opening the menu counts as activity: connect on demand if the control
    // channel is idle and postpone the next battery-saving disconnect.
    func userActivity() {
        policy.userActivity()
    }

    func toggleTouchSensor() {
        guard initialized else {
            FileLogger.shared.log("cmd", "toggle ignored: not initialized")
            return
        }

        let enabled = !(state.touchSensorEnabled ?? false)
        sendProtocolIntent(.setTouchSensor(enabled))
        state.touchSensorEnabled = enabled
        schedule(.getTouchSensor, after: 0.3)
    }

    func setNCMode(_ mode: NCMode) {
        guard initialized else { return }

        sendNoiseControl(mode: mode)
        state.ncMode = mode
        schedule(.getNoiseControl, after: 0.3)
    }

    func setAmbientLevel(_ level: Int) {
        guard initialized else { return }

        let clamped = min(
            max(level, Self.ambientLevelRange.lowerBound),
            Self.ambientLevelRange.upperBound
        )
        state.ambientLevel = clamped
        guard state.ncMode == .ambient else { return }

        sendNoiseControl(mode: .ambient)
        schedule(.getNoiseControl, after: 0.3)
    }

    func setAmbientFocusOnVoice(_ enabled: Bool) {
        guard initialized else { return }

        state.ambientFocusOnVoice = enabled
        guard state.ncMode == .ambient else { return }

        sendNoiseControl(mode: .ambient)
        schedule(.getNoiseControl, after: 0.3)
    }

    func toggleSpeakToChat() {
        guard initialized else { return }

        let enabled = !(state.speakToChatEnabled ?? false)
        sendProtocolIntent(.setSpeakToChat(enabled))
        state.speakToChatEnabled = enabled
        schedule(.getSpeakToChat, after: 0.3)
    }

    func setEqPreset(_ id: UInt8) {
        guard initialized else { return }

        sendProtocolIntent(.setEqualizerPreset(id))
        state.eqCurrentPresetId = id
        schedule(.getEqualizer, after: 0.3)
    }

    func setEqBands(_ bands: [Int]) {
        guard initialized, !bands.isEmpty else { return }

        sendProtocolIntent(.setEqualizerBands(bands))
        state.eqCurrentPresetId = SonyEqualizerPreset.customID
        state.eqBands = bands
    }

    private func handleReachability(_ reachable: Bool, name: String?) {
        if let name {
            deviceName = name
        }
        state.deviceReachable = reachable

        if !state.isConnected {
            state.statusDescription = reachable
                ? "\(deviceName) (idle)"
                : "Disconnected"
        }
    }

    private func sendNoiseControl(mode: NCMode) {
        let settings = SonyNoiseControlSettings(
            mode: mode,
            ambientLevel: state.ambientLevel,
            focusOnVoice: state.ambientFocusOnVoice
        )
        sendProtocolIntent(.setNoiseControl(settings))
    }

    private func sendPowerOff() {
        // Avoid a brief switch to the Mac speakers when A2DP disappears.
        media.pause()
        sendProtocolIntent(.powerOff)
    }

    private func resetSessionState() {
        initialized = false
        awaitingInitResponse = false
        outgoingSequence = 0
        parser.reset()
        protocolAdapter.reset()
    }

    private func sendInit() {
        awaitingInitResponse = true
        sendProtocolIntent(.startSession)

        // Some V1 firmware needs a second handshake before accepting SETs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.awaitingInitResponse else { return }
            self.sendProtocolIntent(.continueSessionInitialization)
        }

        // A few revisions send a state dump instead of the canonical reply.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self,
                  self.awaitingInitResponse,
                  !self.initialized else {
                return
            }
            FileLogger.shared.log("state", "INIT timeout — completing anyway")
            self.completeInit()
        }
    }

    private func completeInit() {
        guard !initialized else { return }

        initialized = true
        awaitingInitResponse = false
        state.isConnected = true
        state.statusDescription = "Connected: \(deviceName)"
        FileLogger.shared.log(
            "state",
            "INIT complete with \(protocolAdapter.version.rawValue.uppercased()), discovering features"
        )

        queryGeneralSettingCapabilities()
        schedule(.getNoiseControl, after: 1.5)
        schedule(.getSpeakToChat, after: 1.7)
        schedule(.getBattery, after: 1.9)
        schedule(.getEqualizerCapabilities, after: 2.1)
        schedule(.getEqualizer, after: 2.3)
        autoOff.arm(deviceName: deviceName)
    }

    private func queryGeneralSettingCapabilities() {
        let requests = protocolAdapter.makeRequests(for: .discoverGeneralSettings)
        for (index, request) in requests.enumerated() {
            let delay = 0.3 + Double(index) * 0.4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sendProtocolRequest(request)
            }
        }
    }

    private func schedule(_ intent: SonyProtocolIntent, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.sendProtocolIntent(intent)
        }
    }

    private func sendProtocolIntent(_ intent: SonyProtocolIntent) {
        sendProtocolRequests(protocolAdapter.makeRequests(for: intent))
    }

    private func sendProtocolRequests(_ requests: [SonyProtocolRequest]) {
        requests.forEach(sendProtocolRequest)
    }

    private func sendProtocolRequest(_ request: SonyProtocolRequest) {
        guard case .connected = bluetooth.status else {
            FileLogger.shared.log("cmd", "skip \(request.label): not connected")
            return
        }

        let packet = SonyPacket(
            dataType: request.dataType,
            sequence: outgoingSequence,
            payload: request.payload
        )
        outgoingSequence ^= 1

        let hex = request.payload
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
        FileLogger.shared.log("cmd", "\(request.label) payload=[\(hex)]")
        bluetooth.send(SonyFraming.encode(packet))
    }

    private func handleStatus(_ status: BluetoothClient.Status) {
        switch status {
        case .disconnected:
            resetSessionState()
            autoOff.disarm()
            policy.setCurrentlyConnected(false)
            clearReportedDeviceState()
            state.statusDescription = state.deviceReachable
                ? "\(deviceName) (idle)"
                : "Disconnected"

        case .searching, .connecting:
            // Do not advertise a successful connection while IOBluetooth is
            // still timing out an unreachable device.
            state.isConnected = false
            if case .connecting(let name) = status {
                deviceName = name
            }

        case .connected(let name):
            resetSessionState()
            deviceName = name
            policy.setCurrentlyConnected(true)
            state.isConnected = false
            state.deviceReachable = true
            state.statusDescription = "Initializing \(name)..."
            sendInit()

        case .failed:
            resetSessionState()
            autoOff.disarm()
            policy.setCurrentlyConnected(false)
            clearReportedDeviceState()
            state.statusDescription = state.deviceReachable
                ? "\(deviceName) (idle)"
                : "Disconnected"
        }
    }

    private func clearReportedDeviceState() {
        state.isConnected = false
        state.touchSensorEnabled = nil
        state.ncMode = nil
        state.speakToChatEnabled = nil
        state.batteryLevel = nil
        state.batteryCharging = false
        state.eqPresets = []
        state.eqCurrentPresetId = nil
        state.eqBands = []
    }

    private func handleIncoming(_ data: Data) {
        for packet in parser.feed(data) {
            let payload = packet.payload
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
            FileLogger.shared.log(
                "packet",
                "RX type=\(hex(packet.dataType.rawValue)) seq=\(packet.sequence) payload=[\(payload)]"
            )

            if packet.dataType != .ack {
                let ack = SonyPacket(
                    dataType: .ack,
                    sequence: packet.sequence ^ 1,
                    payload: []
                )
                bluetooth.send(SonyFraming.encode(ack))
            }

            interpret(packet)
        }
    }

    private func interpret(_ packet: SonyPacket) {
        guard packet.dataType == .command1,
              !packet.payload.isEmpty else {
            return
        }

        // A canonical reply or an early state dump both prove the V1 device
        // is ready. Session negotiation will own this rule once V2 is added.
        if awaitingInitResponse {
            completeInit()
        }

        let output = protocolAdapter.decode(packet)
        output.events.forEach(applyProtocolEvent)
        sendProtocolRequests(output.requests)
    }

    private func applyProtocolEvent(_ event: SonyProtocolEvent) {
        switch event {
        case .battery(let level, let charging):
            state.batteryLevel = level
            state.batteryCharging = charging
            FileLogger.shared.log(
                "state",
                "Battery = \(level)% charging=\(charging)"
            )

        case .noiseControl(let settings):
            state.ncMode = settings.mode
            state.ambientLevel = settings.ambientLevel
            state.ambientFocusOnVoice = settings.focusOnVoice
            FileLogger.shared.log(
                "state",
                "NCASM = \(settings.mode.rawValue), level=\(settings.ambientLevel), focus=\(settings.focusOnVoice)"
            )

        case .speakToChat(let enabled):
            state.speakToChatEnabled = enabled
            FileLogger.shared.log(
                "state",
                "SpeakToChat = \(enabled ? "ON" : "OFF")"
            )

        case .touchSensor(let enabled):
            state.touchSensorEnabled = enabled
            FileLogger.shared.log(
                "state",
                "TouchSensor = \(enabled ? "ON" : "OFF")"
            )

        case .equalizerCapabilities(let presets):
            state.eqPresets = presets
            let description = presets
                .map { "\($0.name)=\(hex($0.id))" }
                .joined(separator: ", ")
            FileLogger.shared.log("state", "EQ presets: \(description)")

        case .equalizer(let presetId, let bands):
            state.eqCurrentPresetId = presetId
            state.eqBands = bands
            FileLogger.shared.log(
                "state",
                "EQ current=\(hex(presetId)) bands=\(bands)"
            )

        case .generalSettingCapability(let capability):
            let typeName: String
            switch capability.valueType {
            case .boolean:
                typeName = "BOOLEAN"
            case .list:
                typeName = "LIST"
            case .unknown(let value):
                typeName = "UNKNOWN(\(hex(value)))"
            }
            FileLogger.shared.log(
                "state",
                "GS slot=\(hex(capability.slot)) name='\(capability.name)' nameFormat=\(capability.nameFormat) settingType=\(typeName)"
            )
            if capability.name == "TOUCH_PANEL_SETTING" {
                FileLogger.shared.log(
                    "state",
                    "→ Touch panel discovered at slot \(hex(capability.slot)), type=\(typeName)"
                )
            }
        }
    }

    private func hex(_ byte: UInt8) -> String {
        String(format: "0x%02X", byte)
    }
}
