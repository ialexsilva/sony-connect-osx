import Foundation
import SonyConnectCore

final class HeadphonesController {
    typealias NCMode = SonyNoiseControlMode
    typealias EqPreset = SonyEqualizerPreset

    struct State {
        var isConnected = false       // protocol session negotiated and ready
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
    private let session: SonyProtocolSession
    private let autoOff = AutoPowerOff()
    private let media = MediaController()
    private let audioMonitor = AudioActivityMonitor(
        nameHints: SupportedDevices.nameHints
    )
    private let policy: ConnectionPolicy

    private var transportConnected = false
    private var connectedEndpoint: SonyServiceEndpoint?
    private var deviceName = "headphones"

    init(session: SonyProtocolSession = SonyProtocolSession()) {
        self.session = session
        policy = ConnectionPolicy(audio: audioMonitor)

        bluetooth.onStatus = { [weak self] status in
            self?.handleStatus(status)
        }
        bluetooth.onData = { [weak self] data in
            self?.session.receive(data)
        }
        bluetooth.onReachabilityChange = { [weak self] reachable, name in
            self?.handleReachability(reachable, name: name)
        }
        session.onOutput = { [weak self] output in
            self?.handleSessionOutput(output)
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
        guard session.state.isReady else { return }
        sendPowerOff()
    }

    func connect() {
        if transportConnected, let connectedEndpoint {
            FileLogger.shared.log(
                "session",
                "manual protocol renegotiation requested"
            )
            session.open(endpoint: connectedEndpoint)
        } else {
            policy.userActivity()
        }
    }

    // Opening the menu counts as activity: connect on demand if the control
    // channel is idle and postpone the next battery-saving disconnect.
    func userActivity() {
        policy.userActivity()
    }

    func toggleTouchSensor() {
        guard session.state.isReady else {
            FileLogger.shared.log("cmd", "toggle ignored: session not ready")
            return
        }

        let enabled = !(state.touchSensorEnabled ?? false)
        session.submit(.setTouchSensor(enabled))
        state.touchSensorEnabled = enabled
        session.submit(.getTouchSensor, after: 0.3)
    }

    func setNCMode(_ mode: NCMode) {
        guard session.state.isReady else { return }

        sendNoiseControl(mode: mode)
        state.ncMode = mode
        session.submit(.getNoiseControl, after: 0.3)
    }

    func setAmbientLevel(_ level: Int) {
        guard session.state.isReady else { return }

        let clamped = min(
            max(level, Self.ambientLevelRange.lowerBound),
            Self.ambientLevelRange.upperBound
        )
        state.ambientLevel = clamped
        guard state.ncMode == .ambient else { return }

        sendNoiseControl(mode: .ambient)
        session.submit(.getNoiseControl, after: 0.3)
    }

    func setAmbientFocusOnVoice(_ enabled: Bool) {
        guard session.state.isReady else { return }

        state.ambientFocusOnVoice = enabled
        guard state.ncMode == .ambient else { return }

        sendNoiseControl(mode: .ambient)
        session.submit(.getNoiseControl, after: 0.3)
    }

    func toggleSpeakToChat() {
        guard session.state.isReady else { return }

        let enabled = !(state.speakToChatEnabled ?? false)
        session.submit(.setSpeakToChat(enabled))
        state.speakToChatEnabled = enabled
        session.submit(.getSpeakToChat, after: 0.3)
    }

    func setEqPreset(_ id: UInt8) {
        guard session.state.isReady else { return }

        session.submit(.setEqualizerPreset(id))
        state.eqCurrentPresetId = id
        session.submit(.getEqualizer, after: 0.3)
    }

    func setEqBands(_ bands: [Int]) {
        guard session.state.isReady, !bands.isEmpty else { return }

        session.submit(.setEqualizerBands(bands))
        state.eqCurrentPresetId = SonyEqualizerPreset.customID
        state.eqBands = bands
    }

    private func handleReachability(_ reachable: Bool, name: String?) {
        if let name {
            deviceName = name
        }
        state.deviceReachable = reachable

        if !transportConnected {
            state.statusDescription = reachable
                ? "\(deviceName) (idle)"
                : "Disconnected"
        }
    }

    private func sendNoiseControl(mode: NCMode) {
        session.submit(
            .setNoiseControl(
                SonyNoiseControlSettings(
                    mode: mode,
                    ambientLevel: state.ambientLevel,
                    focusOnVoice: state.ambientFocusOnVoice
                )
            )
        )
    }

    private func sendPowerOff() {
        // Avoid a brief switch to the Mac speakers when A2DP disappears.
        media.pause()
        session.submit(.powerOff)
    }

    private func handleStatus(_ status: BluetoothClient.Status) {
        switch status {
        case .disconnected:
            transportConnected = false
            connectedEndpoint = nil
            session.close()
            autoOff.disarm()
            policy.setCurrentlyConnected(false)
            clearReportedDeviceState()
            state.statusDescription = state.deviceReachable
                ? "\(deviceName) (idle)"
                : "Disconnected"

        case .searching:
            transportConnected = false
            connectedEndpoint = nil
            session.close()
            state.isConnected = false
            state.statusDescription = "Searching for Sony headphones..."

        case .connecting(let name):
            transportConnected = false
            connectedEndpoint = nil
            session.close()
            state.isConnected = false
            deviceName = name
            state.statusDescription = "Connecting to \(name)..."

        case .connected(let name, let endpoint):
            transportConnected = true
            connectedEndpoint = endpoint
            deviceName = name
            policy.setCurrentlyConnected(true)
            state.isConnected = false
            state.deviceReachable = true
            state.statusDescription =
                "Negotiating Sony \(endpoint.rawValue.uppercased()) with \(name)..."
            session.open(endpoint: endpoint)

        case .failed(let reason):
            transportConnected = false
            connectedEndpoint = nil
            session.close()
            autoOff.disarm()
            policy.setCurrentlyConnected(false)
            clearReportedDeviceState()
            state.statusDescription = "Connection failed: \(reason)"
        }
    }

    private func handleSessionOutput(
        _ output: SonyProtocolSessionOutput
    ) {
        switch output {
        case .write(let data, let label):
            guard transportConnected else {
                FileLogger.shared.log(
                    "cmd",
                    "skip \(label): transport disconnected"
                )
                return
            }
            FileLogger.shared.log("cmd", label)
            bluetooth.send(data)

        case .event(let event):
            applyProtocolEvent(event)

        case .state(let sessionState):
            handleSessionState(sessionState)

        case .issue(let issue):
            FileLogger.shared.log(
                "session",
                describe(issue: issue)
            )
        }
    }

    private func handleSessionState(
        _ sessionState: SonyProtocolSessionState
    ) {
        switch sessionState {
        case .idle:
            state.isConnected = false

        case .negotiating(let endpoint):
            state.isConnected = false
            state.statusDescription =
                "Negotiating Sony \(endpoint.rawValue.uppercased())..."

        case .ready(let version):
            guard transportConnected else { return }

            state.isConnected = true
            state.statusDescription =
                "Connected: \(deviceName) (\(version.rawValue.uppercased()))"
            FileLogger.shared.log(
                "state",
                "protocol \(version.rawValue.uppercased()) ready; discovering features"
            )
            enqueueInitialDiscovery()
            autoOff.arm(deviceName: deviceName)

        case .unsupported(let version):
            state.isConnected = false
            autoOff.disarm()
            state.statusDescription =
                "Sony \(version.rawValue.uppercased()) detected — adapter not implemented"
            FileLogger.shared.log(
                "session",
                "unsupported protocol \(version.rawValue.uppercased()); no feature commands sent"
            )

        case .failed(let failure):
            state.isConnected = false
            autoOff.disarm()
            state.statusDescription =
                "Protocol error: \(describe(failure: failure))"
            FileLogger.shared.log(
                "session",
                describe(failure: failure)
            )
        }
    }

    private func enqueueInitialDiscovery() {
        session.submit(.discoverGeneralSettings)
        session.submit(.getNoiseControl)
        session.submit(.getSpeakToChat)
        session.submit(.getBattery)
        session.submit(.getEqualizerCapabilities)
        session.submit(.getEqualizer)
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

    private func describe(
        issue: SonyProtocolSessionIssue
    ) -> String {
        switch issue {
        case .ignoredIntent(let intent):
            return "ignored intent while session was not ready: \(intent)"
        case .protocolHintMismatch(let endpoint, let detected):
            return
                "service \(endpoint.rawValue.uppercased()) replied as \(detected.rawValue.uppercased()); using reply"
        case .retrying(let label, let attempt, let maximumAttempts):
            return
                "retry \(attempt)/\(maximumAttempts) waiting for ACK: \(label)"
        case .unexpectedAcknowledgement(let expected, let received):
            let expectedDescription = expected.map(String.init) ?? "none"
            return
                "unexpected ACK seq=\(received), expected=\(expectedDescription)"
        }
    }

    private func describe(
        failure: SonyProtocolSessionFailure
    ) -> String {
        switch failure {
        case .acknowledgementTimedOut(let label):
            return "ACK timed out for \(label)"
        case .negotiationTimedOut(let endpoint):
            return
                "\(endpoint.rawValue.uppercased()) initialization timed out"
        }
    }

    private func hex(_ byte: UInt8) -> String {
        String(format: "0x%02X", byte)
    }
}
