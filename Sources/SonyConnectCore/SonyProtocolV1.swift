import Foundation

/// Encoder and decoder for Sony's MDR protocol V1.
///
/// The adapter owns only wire-level session knowledge learned from capability
/// replies (for example, which general-setting slot controls the touch panel).
/// Bluetooth lifecycle, retries, request timing, and UI state remain outside.
public final class SonyProtocolV1: SonyProtocolAdapter {
    public let version: SonyProtocolVersion = .v1

    private enum Opcode {
        static let initRequest: UInt8 = 0x00
        static let init2Request: UInt8 = 0x06
        static let batteryGet: UInt8 = 0x10
        static let batteryRet: UInt8 = 0x11
        static let batteryNotify: UInt8 = 0x13
        static let batterySingleInquiredType: UInt8 = 0x00
        static let commonSetPowerOff: UInt8 = 0x22
        static let powerOffFixedValue: UInt8 = 0x00
        static let powerOffUserOff: UInt8 = 0x01
        static let eqGetCapability: UInt8 = 0x50
        static let eqRetCapability: UInt8 = 0x51
        static let eqGetParam: UInt8 = 0x56
        static let eqRetParam: UInt8 = 0x57
        static let eqSetParam: UInt8 = 0x58
        static let eqNotifyParam: UInt8 = 0x59
        static let eqPresetInquiredType: UInt8 = 0x01
        static let eqPresetCustom: UInt8 = 0xA0
        static let eqPresetUnspecified: UInt8 = 0xFF
        static let ncasmGet: UInt8 = 0x66
        static let ncasmRet: UInt8 = 0x67
        static let ncasmSet: UInt8 = 0x68
        static let ncasmNotify: UInt8 = 0x69
        static let ncasmCombinedInquiredType: UInt8 = 0x02
        static let gsGetCapability: UInt8 = 0xD0
        static let gsRetCapability: UInt8 = 0xD1
        static let touchSensorGet: UInt8 = 0xD6
        static let touchSensorRet: UInt8 = 0xD7
        static let touchSensorSet: UInt8 = 0xD8
        static let touchSensorNotify: UInt8 = 0xD9
        static let gs1SubId: UInt8 = 0xD1
        static let gs2SubId: UInt8 = 0xD2
        static let gs3SubId: UInt8 = 0xD3
        static let systemGet: UInt8 = 0xF6
        static let systemRet: UInt8 = 0xF7
        static let systemSet: UInt8 = 0xF8
        static let systemNotify: UInt8 = 0xF9
        static let smartTalkingMode: UInt8 = 0x05
        static let smartTalkingParamModeOnOff: UInt8 = 0x01
    }

    private var touchPanelSlot: UInt8?
    private var touchPanelIsListType = false
    private var ncSettingType: UInt8 = 0x02
    private var ambientSettingType: UInt8 = 0x01
    private var ambientId: UInt8 = 0x00
    private var currentAmbientLevel = UInt8(SonyNoiseControlSettings.ambientLevelRange.upperBound)

    public init() {}

    public func reset() {
        touchPanelSlot = nil
        touchPanelIsListType = false
        ncSettingType = 0x02
        ambientSettingType = 0x01
        ambientId = 0x00
        currentAmbientLevel = UInt8(SonyNoiseControlSettings.ambientLevelRange.upperBound)
    }

    public func makeRequests(for intent: SonyProtocolIntent) -> [SonyProtocolRequest] {
        switch intent {
        case .startSession:
            return [request([Opcode.initRequest, 0x00], label: "INIT_REQUEST")]

        case .continueSessionInitialization:
            return [
                request(
                    [Opcode.init2Request, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00],
                    label: "INIT_2_REQUEST"
                ),
            ]

        case .discoverGeneralSettings:
            return [Opcode.gs1SubId, Opcode.gs2SubId, Opcode.gs3SubId].map { slot in
                request(
                    [Opcode.gsGetCapability, slot, 0x00],
                    label: "GS GET_CAPABILITY slot=\(hex(slot))"
                )
            }

        case .getBattery:
            return [
                request(
                    [Opcode.batteryGet, Opcode.batterySingleInquiredType],
                    label: "BATTERY GET"
                ),
            ]

        case .getNoiseControl:
            return [
                request(
                    [Opcode.ncasmGet, Opcode.ncasmCombinedInquiredType],
                    label: "NCASM GET"
                ),
            ]

        case .getSpeakToChat:
            return [
                request(
                    [Opcode.systemGet, Opcode.smartTalkingMode],
                    label: "SpeakToChat GET"
                ),
            ]

        case .getTouchSensor:
            let slot = touchPanelSlot ?? Opcode.gs1SubId
            return [
                request(
                    [Opcode.touchSensorGet, slot],
                    label: "TouchSensor GET slot=\(hex(slot))"
                ),
            ]

        case .getEqualizerCapabilities:
            return [
                request(
                    [Opcode.eqGetCapability, Opcode.eqPresetInquiredType, 0x00],
                    label: "EQ GET_CAPABILITY"
                ),
            ]

        case .getEqualizer:
            return [
                request(
                    [Opcode.eqGetParam, Opcode.eqPresetInquiredType],
                    label: "EQ GET"
                ),
            ]

        case .setTouchSensor(let enabled):
            let slot = touchPanelSlot ?? Opcode.gs1SubId
            let settingType: UInt8 = touchPanelIsListType ? 0x02 : 0x01
            return [
                request(
                    [
                        Opcode.touchSensorSet,
                        slot,
                        settingType,
                        enabled ? 0x01 : 0x00,
                    ],
                    label: "TouchSensor SET=\(enabled ? "ON" : "OFF") slot=\(hex(slot))"
                ),
            ]

        case .setNoiseControl(let settings):
            let clampedLevel = min(
                max(
                    settings.ambientLevel,
                    SonyNoiseControlSettings.ambientLevelRange.lowerBound
                ),
                SonyNoiseControlSettings.ambientLevelRange.upperBound
            )
            currentAmbientLevel = UInt8(clampedLevel)
            ambientId = settings.focusOnVoice ? 0x01 : 0x00

            let effect: UInt8 = settings.mode == .off ? 0x00 : 0x11
            let ncValue: UInt8 = settings.mode == .noiseCancelling ? 0x02 : 0x00
            let ambientLevel: UInt8 = settings.mode == .ambient ? currentAmbientLevel : 0x00
            return [
                request(
                    [
                        Opcode.ncasmSet,
                        Opcode.ncasmCombinedInquiredType,
                        effect,
                        ncSettingType,
                        ncValue,
                        ambientSettingType,
                        ambientId,
                        ambientLevel,
                    ],
                    label: "NCASM SET=\(settings.mode.rawValue)"
                ),
            ]

        case .setSpeakToChat(let enabled):
            return [
                request(
                    [
                        Opcode.systemSet,
                        Opcode.smartTalkingMode,
                        Opcode.smartTalkingParamModeOnOff,
                        enabled ? 0x01 : 0x00,
                    ],
                    label: "SpeakToChat SET=\(enabled ? "ON" : "OFF")"
                ),
            ]

        case .setEqualizerPreset(let id):
            return [
                request(
                    [Opcode.eqSetParam, Opcode.eqPresetInquiredType, id, 0x00],
                    label: "EQ SET preset=\(hex(id))"
                ),
            ]

        case .setEqualizerBands(let bands):
            let encodableBands = Array(bands.prefix(Int(UInt8.max)))
            guard !encodableBands.isEmpty else { return [] }

            var payload: [UInt8] = [
                Opcode.eqSetParam,
                Opcode.eqPresetInquiredType,
                Opcode.eqPresetUnspecified,
                UInt8(encodableBands.count),
            ]
            payload.append(contentsOf: encodableBands.map { UInt8(clamping: $0) })
            return [
                request(payload, label: "EQ SET custom bands=\(encodableBands)"),
            ]

        case .powerOff:
            return [
                request(
                    [
                        Opcode.commonSetPowerOff,
                        Opcode.powerOffFixedValue,
                        Opcode.powerOffUserOff,
                    ],
                    label: "POWER_OFF"
                ),
            ]
        }
    }

    public func decode(_ packet: SonyPacket) -> SonyProtocolOutput {
        guard packet.dataType == .command1,
              let opcode = packet.payload.first else {
            return SonyProtocolOutput()
        }

        switch opcode {
        case Opcode.gsRetCapability:
            return decodeGeneralSettingCapability(packet.payload)
        case Opcode.batteryRet, Opcode.batteryNotify:
            return decodeBattery(packet.payload)
        case Opcode.eqRetCapability:
            return decodeEqualizerCapabilities(packet.payload)
        case Opcode.eqRetParam, Opcode.eqNotifyParam:
            return decodeEqualizer(packet.payload)
        case Opcode.ncasmRet, Opcode.ncasmNotify:
            return decodeNoiseControl(packet.payload)
        case Opcode.systemRet, Opcode.systemNotify:
            return decodeSystem(packet.payload)
        case Opcode.touchSensorRet, Opcode.touchSensorNotify:
            return decodeTouchSensor(packet.payload)
        default:
            return SonyProtocolOutput()
        }
    }

    private func decodeGeneralSettingCapability(_ payload: [UInt8]) -> SonyProtocolOutput {
        guard payload.count >= 5 else { return SonyProtocolOutput() }

        let slot = payload[1]
        let nameFormat = payload[2]
        let nameLength = Int(payload[3])
        let nameEnd = 4 + nameLength
        guard nameEnd < payload.count else { return SonyProtocolOutput() }

        let name = String(bytes: payload[4..<nameEnd], encoding: .ascii) ?? "<bad>"
        let descriptionLengthIndex = nameEnd
        let descriptionLength = Int(payload[descriptionLengthIndex])
        let settingTypeIndex = descriptionLengthIndex + 1 + descriptionLength
        guard settingTypeIndex < payload.count else { return SonyProtocolOutput() }

        let valueType = SonyGeneralSettingValueType(rawValue: payload[settingTypeIndex])
        let capability = SonyGeneralSettingCapability(
            slot: slot,
            nameFormat: nameFormat,
            name: name,
            valueType: valueType
        )

        var requests: [SonyProtocolRequest] = []
        if nameFormat == 0x02 && name == "TOUCH_PANEL_SETTING" {
            touchPanelSlot = slot
            touchPanelIsListType = valueType == .list
            requests = makeRequests(for: .getTouchSensor)
        }

        return SonyProtocolOutput(
            events: [.generalSettingCapability(capability)],
            requests: requests
        )
    }

    private func decodeBattery(_ payload: [UInt8]) -> SonyProtocolOutput {
        guard payload.count >= 4,
              payload[1] == Opcode.batterySingleInquiredType else {
            return SonyProtocolOutput()
        }

        return SonyProtocolOutput(
            events: [
                .battery(level: Int(payload[2]), charging: payload[3] == 0x01),
            ]
        )
    }

    private func decodeNoiseControl(_ payload: [UInt8]) -> SonyProtocolOutput {
        guard payload.count >= 8,
              payload[1] == Opcode.ncasmCombinedInquiredType else {
            return SonyProtocolOutput()
        }

        let effect = payload[2]
        ncSettingType = payload[3]
        let ncValue = payload[4]
        ambientSettingType = payload[5]
        ambientId = payload[6]
        let reportedAmbientLevel = payload[7]

        let mode: SonyNoiseControlMode
        if effect == 0x00 {
            mode = .off
        } else if ncValue != 0x00 {
            mode = .noiseCancelling
        } else {
            mode = .ambient
        }

        if mode == .ambient,
           SonyNoiseControlSettings.ambientLevelRange.contains(Int(reportedAmbientLevel)) {
            currentAmbientLevel = reportedAmbientLevel
        }

        return SonyProtocolOutput(
            events: [
                .noiseControl(
                    SonyNoiseControlSettings(
                        mode: mode,
                        ambientLevel: Int(currentAmbientLevel),
                        focusOnVoice: ambientId == 0x01
                    )
                ),
            ]
        )
    }

    private func decodeEqualizerCapabilities(_ payload: [UInt8]) -> SonyProtocolOutput {
        guard payload.count >= 5,
              payload[1] == Opcode.eqPresetInquiredType else {
            return SonyProtocolOutput()
        }

        let presetCount = Int(payload[4])
        var presets: [SonyEqualizerPreset] = []
        var index = 5

        for _ in 0..<presetCount {
            guard index + 1 < payload.count else { break }

            let id = payload[index]
            let nameLength = Int(payload[index + 1])
            let nameStart = index + 2
            let nameEnd = nameStart + nameLength
            guard nameEnd <= payload.count else { break }

            let reportedName = nameLength > 0
                ? String(bytes: payload[nameStart..<nameEnd], encoding: .utf8)
                : nil
            let name = reportedName.flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.fallbackPresetName(id)
            presets.append(SonyEqualizerPreset(id: id, name: name))
            index = nameEnd
        }

        presets.removeAll { (0xA1...0xA5).contains($0.id) }
        if let customIndex = presets.firstIndex(where: { $0.id == Opcode.eqPresetCustom }) {
            presets.append(presets.remove(at: customIndex))
        }

        return SonyProtocolOutput(events: [.equalizerCapabilities(presets)])
    }

    private func decodeEqualizer(_ payload: [UInt8]) -> SonyProtocolOutput {
        guard payload.count >= 4,
              payload[1] == Opcode.eqPresetInquiredType else {
            return SonyProtocolOutput()
        }

        let presetId = payload[2]
        let bandCount = Int(payload[3])
        let bands: [Int]
        if 4 + bandCount <= payload.count {
            bands = payload[4..<(4 + bandCount)].map(Int.init)
        } else {
            bands = []
        }

        return SonyProtocolOutput(
            events: [.equalizer(presetId: presetId, bands: bands)]
        )
    }

    private func decodeSystem(_ payload: [UInt8]) -> SonyProtocolOutput {
        guard payload.count >= 4,
              payload[1] == Opcode.smartTalkingMode else {
            return SonyProtocolOutput()
        }

        return SonyProtocolOutput(events: [.speakToChat(payload[3] != 0x00)])
    }

    private func decodeTouchSensor(_ payload: [UInt8]) -> SonyProtocolOutput {
        guard payload.count >= 4,
              payload[1] == touchPanelSlot else {
            return SonyProtocolOutput()
        }

        return SonyProtocolOutput(events: [.touchSensor(payload[3] != 0x00)])
    }

    private func request(_ payload: [UInt8], label: String) -> SonyProtocolRequest {
        SonyProtocolRequest(payload: payload, label: label)
    }

    private func hex(_ byte: UInt8) -> String {
        String(format: "0x%02X", byte)
    }

    private static func fallbackPresetName(_ id: UInt8) -> String {
        switch id {
        case 0x00: return "Off"
        case 0x01: return "Rock"
        case 0x02: return "Pop"
        case 0x03: return "Jazz"
        case 0x04: return "Dance"
        case 0x05: return "EDM"
        case 0x06: return "R&B / Hip-Hop"
        case 0x07: return "Acoustic"
        case 0x10: return "Bright"
        case 0x11: return "Excited"
        case 0x12: return "Mellow"
        case 0x13: return "Relaxed"
        case 0x14: return "Vocal"
        case 0x15: return "Treble Boost"
        case 0x16: return "Bass Boost"
        case 0x17: return "Speech"
        case SonyEqualizerPreset.customID: return "Custom"
        case 0xA1: return "User 1"
        case 0xA2: return "User 2"
        case 0xA3: return "User 3"
        case 0xA4: return "User 4"
        case 0xA5: return "User 5"
        default: return String(format: "Preset 0x%02X", id)
        }
    }
}
