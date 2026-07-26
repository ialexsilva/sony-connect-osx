import Testing
import SonyConnectCore

@Suite
struct SonyProtocolV1Tests {
    @Test
    func testSessionAndDiscoveryRequestsUseV1Payloads() {
        let adapter = SonyProtocolV1()

        #expect(
            payloads(adapter.makeRequests(for: .startSession)) ==
            [[0x00, 0x00]]
        )
        #expect(
            payloads(adapter.makeRequests(for: .continueSessionInitialization)) ==
            [[0x06, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00]]
        )
        #expect(
            payloads(adapter.makeRequests(for: .discoverGeneralSettings)) ==
            [
                [0xD0, 0xD1, 0x00],
                [0xD0, 0xD2, 0x00],
                [0xD0, 0xD3, 0x00],
            ]
        )
    }

    @Test
    func testNoiseControlEncodingUsesV1CombinedLayout() {
        let adapter = SonyProtocolV1()
        let settings = SonyNoiseControlSettings(
            mode: .ambient,
            ambientLevel: 7,
            focusOnVoice: true
        )

        #expect(
            payloads(adapter.makeRequests(for: .setNoiseControl(settings))) ==
            [[0x68, 0x02, 0x11, 0x02, 0x00, 0x01, 0x01, 0x07]]
        )
    }

    @Test
    func testNoiseControlReplyUpdatesDeviceSpecificEncodingFields() {
        let adapter = SonyProtocolV1()
        let output = adapter.decode(
            packet([0x67, 0x02, 0x11, 0x03, 0x00, 0x02, 0x01, 0x0F])
        )

        #expect(
            output.events ==
            [
                .noiseControl(
                    SonyNoiseControlSettings(
                        mode: .ambient,
                        ambientLevel: 15,
                        focusOnVoice: true
                    )
                ),
            ]
        )

        let nextSettings = SonyNoiseControlSettings(
            mode: .ambient,
            ambientLevel: 9,
            focusOnVoice: false
        )
        #expect(
            payloads(adapter.makeRequests(for: .setNoiseControl(nextSettings))) ==
            [[0x68, 0x02, 0x11, 0x03, 0x00, 0x02, 0x00, 0x09]]
        )
    }

    @Test
    func testTouchCapabilitySelectsReportedSlotAndValueType() {
        let adapter = SonyProtocolV1()
        let name = Array("TOUCH_PANEL_SETTING".utf8)
        let capabilityPayload =
            [UInt8(0xD1), 0xD3, 0x02, UInt8(name.count)]
            + name
            + [0x00, 0x02]

        let output = adapter.decode(packet(capabilityPayload))

        #expect(
            output.events ==
            [
                .generalSettingCapability(
                    SonyGeneralSettingCapability(
                        slot: 0xD3,
                        nameFormat: 0x02,
                        name: "TOUCH_PANEL_SETTING",
                        valueType: .list
                    )
                ),
            ]
        )
        #expect(payloads(output.requests) == [[0xD6, 0xD3]])
        #expect(
            payloads(adapter.makeRequests(for: .setTouchSensor(true))) ==
            [[0xD8, 0xD3, 0x02, 0x01]]
        )
    }

    @Test
    func testBatteryReplyProducesTypedEvent() {
        let output = SonyProtocolV1().decode(
            packet([0x11, 0x00, 0x54, 0x01])
        )

        #expect(output.events == [.battery(level: 84, charging: true)])
    }

    @Test
    func testEqualizerCapabilitiesFilterUserSlotsAndMoveCustomLast() {
        let output = SonyProtocolV1().decode(
            packet([
                0x51, 0x01, 0x05, 0x15, 0x04,
                0xA0, 0x00,
                0x01, 0x00,
                0xA1, 0x00,
                0x00, 0x00,
            ])
        )

        #expect(
            output.events ==
            [
                .equalizerCapabilities([
                    SonyEqualizerPreset(id: 0x01, name: "Rock"),
                    SonyEqualizerPreset(id: 0x00, name: "Off"),
                    SonyEqualizerPreset(id: 0xA0, name: "Custom"),
                ]),
            ]
        )
    }

    @Test
    func testCustomEqualizerUsesUnspecifiedPresetForPersistence() {
        let requests = SonyProtocolV1().makeRequests(
            for: .setEqualizerBands([0, 5, 10])
        )

        #expect(
            payloads(requests) ==
            [[0x58, 0x01, 0xFF, 0x03, 0x00, 0x05, 0x0A]]
        )
    }

    @Test
    func testPowerOffKeepsV1OpcodeMeaning() {
        #expect(
            payloads(SonyProtocolV1().makeRequests(for: .powerOff)) ==
            [[0x22, 0x00, 0x01]]
        )
    }

    @Test
    func testFeatureRequestsKeepV1SubtypesAndMessageType() {
        let adapter: any SonyProtocolAdapter = SonyProtocolV1()
        let requests = [
            adapter.makeRequests(for: .getBattery).first,
            adapter.makeRequests(for: .getEqualizer).first,
            adapter.makeRequests(for: .getSpeakToChat).first,
            adapter.makeRequests(for: .setSpeakToChat(true)).first,
        ].compactMap { $0 }

        #expect(
            payloads(requests) ==
            [
                [0x10, 0x00],
                [0x56, 0x01],
                [0xF6, 0x05],
                [0xF8, 0x05, 0x01, 0x01],
            ]
        )
        #expect(requests.allSatisfy { $0.dataType == .command1 })
    }

    @Test
    func testMalformedAndNonV1PacketsAreIgnored() {
        let adapter = SonyProtocolV1()

        #expect(adapter.decode(packet([0x67, 0x02])).events == [])
        #expect(
            adapter.decode(
                SonyPacket(
                    dataType: .command2,
                    sequence: 0,
                    payload: [0x67, 0x02, 0x11, 0x02, 0x00, 0x01, 0x00, 0x14]
                )
            ) ==
            SonyProtocolOutput()
        )
    }

    private func packet(_ payload: [UInt8]) -> SonyPacket {
        SonyPacket(dataType: .command1, sequence: 0, payload: payload)
    }

    private func payloads(_ requests: [SonyProtocolRequest]) -> [[UInt8]] {
        requests.map(\.payload)
    }
}
