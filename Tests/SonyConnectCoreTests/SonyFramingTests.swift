import Foundation
import Testing
import SonyConnectCore

@Suite
struct SonyFramingTests {
    @Test
    func testRoundTripEscapesEveryReservedByte() {
        let packet = SonyPacket(
            dataType: .command1,
            sequence: 1,
            payload: [
                SonyFraming.startMarker,
                SonyFraming.escapeByte,
                SonyFraming.endMarker,
                0x00,
            ]
        )

        let encoded = SonyFraming.encode(packet)
        let decoded = SonyFrameParser().feed(encoded)

        #expect(decoded == [packet])
        #expect(encoded.filter { $0 == SonyFraming.escapeByte }.count > 2)
    }

    @Test
    func testParserAcceptsAFrameSplitAcrossArbitraryChunks() {
        let packet = SonyPacket(
            dataType: .command1Response,
            sequence: 0,
            payload: [0x11, 0x00, 0x64, 0x00]
        )
        let encoded = SonyFraming.encode(packet)
        let parser = SonyFrameParser()
        var decoded: [SonyPacket] = []

        for byte in encoded {
            decoded.append(contentsOf: parser.feed(Data([byte])))
        }

        #expect(decoded == [packet])
    }

    @Test
    func testParserAcceptsMultipleFramesInOneChunk() {
        let first = SonyPacket(dataType: .ack, sequence: 1, payload: [])
        let second = SonyPacket(dataType: .command1, sequence: 0, payload: [0x01, 0x00])
        var stream = SonyFraming.encode(first)
        stream.append(SonyFraming.encode(second))

        #expect(SonyFrameParser().feed(stream) == [first, second])
    }

    @Test
    func testParserRejectsBadChecksumAndRecoversForNextFrame() {
        let invalidPacket = SonyPacket(
            dataType: .command1,
            sequence: 0,
            payload: [0x01, 0x02]
        )
        var invalidFrame = SonyFraming.encode(invalidPacket)
        invalidFrame[invalidFrame.index(invalidFrame.endIndex, offsetBy: -2)] ^= 0x01

        let validPacket = SonyPacket(
            dataType: .command1,
            sequence: 1,
            payload: [0x10, 0x00]
        )
        invalidFrame.append(SonyFraming.encode(validPacket))

        #expect(SonyFrameParser().feed(invalidFrame) == [validPacket])
    }

    @Test
    func testParserPreservesUnknownPacketType() {
        let frame = makeUnescapedFrame(
            dataType: 0x77,
            sequence: 1,
            payload: [0x02]
        )

        #expect(
            SonyFrameParser().feed(frame) ==
            [
                SonyPacket(
                    dataType: .unknown(0x77),
                    sequence: 1,
                    payload: [0x02]
                ),
            ]
        )
    }

    @Test
    func testResetDiscardsAPartialFrame() {
        let parser = SonyFrameParser()
        _ = parser.feed(Data([SonyFraming.startMarker, 0x0C, 0x00]))
        parser.reset()

        let packet = SonyPacket(dataType: .ack, sequence: 0, payload: [])
        #expect(parser.feed(SonyFraming.encode(packet)) == [packet])
    }

    @Test
    func testParserBoundsAnUnterminatedFrameAndRecovers() {
        let parser = SonyFrameParser()
        var stream = Data([SonyFraming.startMarker])
        stream.append(Data(repeating: 0x00, count: 1_048_577))

        let packet = SonyPacket(dataType: .ack, sequence: 1, payload: [])
        stream.append(SonyFraming.encode(packet))

        #expect(parser.feed(stream) == [packet])
    }

    private func makeUnescapedFrame(
        dataType: UInt8,
        sequence: UInt8,
        payload: [UInt8]
    ) -> Data {
        let length = UInt32(payload.count)
        var body: [UInt8] = [
            dataType,
            sequence,
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
        ]
        body.append(contentsOf: payload)
        body.append(body.reduce(UInt8(0)) { $0 &+ $1 })
        return Data([SonyFraming.startMarker] + body + [SonyFraming.endMarker])
    }
}
