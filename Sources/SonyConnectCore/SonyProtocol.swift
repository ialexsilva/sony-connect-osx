import Foundation

public enum SonyProtocolVersion: String, Equatable {
    case v1
    case v2
}

/// Sony's two proprietary RFCOMM service endpoints.
///
/// The endpoint is a strong protocol hint, while the initialization reply is
/// the authoritative version signal whenever it is available.
public enum SonyServiceEndpoint: String, CaseIterable, Equatable {
    case v1
    case v2

    /// Keeps the hardware-verified XM3/XM4 path preferred when a device
    /// advertises both endpoints. Devices exposing only V2 still select V2.
    public static let connectionPriority: [SonyServiceEndpoint] = [.v1, .v2]

    public var protocolVersion: SonyProtocolVersion {
        switch self {
        case .v1: return .v1
        case .v2: return .v2
        }
    }

    public var uuidString: String {
        switch self {
        case .v1: return "96CC203E-5068-46AD-B32D-E316F5E069BA"
        case .v2: return "956C7B26-D49A-4BA8-B03F-B17D393CB6E2"
        }
    }

    public var uuidBytes: [UInt8] {
        switch self {
        case .v1:
            return [
                0x96, 0xCC, 0x20, 0x3E,
                0x50, 0x68,
                0x46, 0xAD,
                0xB3, 0x2D,
                0xE3, 0x16, 0xF5, 0xE0, 0x69, 0xBA,
            ]
        case .v2:
            return [
                0x95, 0x6C, 0x7B, 0x26,
                0xD4, 0x9A,
                0x4B, 0xA8,
                0xB0, 0x3F,
                0xB1, 0x7D, 0x39, 0x3C, 0xB6, 0xE2,
            ]
        }
    }
}

public enum SonyNoiseControlMode: String, Equatable {
    case noiseCancelling
    case ambient
    case off
}

public struct SonyNoiseControlSettings: Equatable {
    public static let ambientLevelRange = 1...20

    public let mode: SonyNoiseControlMode
    public let ambientLevel: Int
    public let focusOnVoice: Bool

    public init(
        mode: SonyNoiseControlMode,
        ambientLevel: Int,
        focusOnVoice: Bool
    ) {
        self.mode = mode
        self.ambientLevel = ambientLevel
        self.focusOnVoice = focusOnVoice
    }
}

public struct SonyEqualizerPreset: Equatable {
    public static let customID: UInt8 = 0xA0

    public let id: UInt8
    public let name: String

    public init(id: UInt8, name: String) {
        self.id = id
        self.name = name
    }
}

public enum SonyGeneralSettingValueType: Equatable {
    case boolean
    case list
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0x01: self = .boolean
        case 0x02: self = .list
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .boolean: return 0x01
        case .list: return 0x02
        case .unknown(let value): return value
        }
    }
}

public struct SonyGeneralSettingCapability: Equatable {
    public let slot: UInt8
    public let nameFormat: UInt8
    public let name: String
    public let valueType: SonyGeneralSettingValueType

    public init(
        slot: UInt8,
        nameFormat: UInt8,
        name: String,
        valueType: SonyGeneralSettingValueType
    ) {
        self.slot = slot
        self.nameFormat = nameFormat
        self.name = name
        self.valueType = valueType
    }
}

/// User- and session-level operations understood by a Sony protocol adapter.
///
/// The cases describe intent, never wire bytes. V1 and V2 are therefore free
/// to encode the same operation with different opcodes and payload layouts.
public enum SonyProtocolIntent: Equatable {
    case startSession
    case continueSessionInitialization
    case discoverGeneralSettings
    case getBattery
    case getNoiseControl
    case getSpeakToChat
    case getTouchSensor
    case getEqualizerCapabilities
    case getEqualizer
    case setTouchSensor(Bool)
    case setNoiseControl(SonyNoiseControlSettings)
    case setSpeakToChat(Bool)
    case setEqualizerPreset(UInt8)
    case setEqualizerBands([Int])
    case powerOff
}

public struct SonyProtocolRequest: Equatable {
    public let dataType: SonyDataType
    public let payload: [UInt8]
    public let label: String

    public init(
        dataType: SonyDataType = .command1,
        payload: [UInt8],
        label: String
    ) {
        self.dataType = dataType
        self.payload = payload
        self.label = label
    }
}

public enum SonyProtocolEvent: Equatable {
    case battery(level: Int, charging: Bool)
    case noiseControl(SonyNoiseControlSettings)
    case speakToChat(Bool)
    case touchSensor(Bool)
    case equalizerCapabilities([SonyEqualizerPreset])
    case equalizer(presetId: UInt8, bands: [Int])
    case generalSettingCapability(SonyGeneralSettingCapability)
}

/// Result of decoding a device packet.
///
/// Some packets produce a typed state event and a follow-up request. For
/// example, discovering which general-setting slot owns the touch panel
/// immediately produces the correctly addressed GET request.
public struct SonyProtocolOutput: Equatable {
    public let events: [SonyProtocolEvent]
    public let requests: [SonyProtocolRequest]

    public init(
        events: [SonyProtocolEvent] = [],
        requests: [SonyProtocolRequest] = []
    ) {
        self.events = events
        self.requests = requests
    }
}

public protocol SonyProtocolAdapter: AnyObject {
    var version: SonyProtocolVersion { get }

    func reset()
    func makeRequests(for intent: SonyProtocolIntent) -> [SonyProtocolRequest]
    func decode(_ packet: SonyPacket) -> SonyProtocolOutput
}
