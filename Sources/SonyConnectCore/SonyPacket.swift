import Foundation

/// Packet types used by Sony's framed RFCOMM protocol.
///
/// Unknown values are deliberately preserved. Treating an unknown packet as a
/// V1 command can make a newer protocol revision look valid while decoding it
/// with the wrong opcode table.
public enum SonyDataType: Equatable {
    case ack
    case command1
    case command1Response
    case command2
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0x01: self = .ack
        case 0x0C: self = .command1
        case 0x0D: self = .command1Response
        case 0x0E: self = .command2
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .ack: return 0x01
        case .command1: return 0x0C
        case .command1Response: return 0x0D
        case .command2: return 0x0E
        case .unknown(let value): return value
        }
    }
}

public struct SonyPacket: Equatable {
    public let dataType: SonyDataType
    public let sequence: UInt8
    public let payload: [UInt8]

    public init(dataType: SonyDataType, sequence: UInt8, payload: [UInt8]) {
        self.dataType = dataType
        self.sequence = sequence
        self.payload = payload
    }
}

/// Sony "Headphones Connect" byte framing.
///
/// Frame layout after unescaping:
/// `[dataType:1][sequence:1][payloadLength:4 BE][payload][checksum:1]`.
public enum SonyFraming {
    public static let startMarker: UInt8 = 0x3E
    public static let endMarker: UInt8 = 0x3C
    public static let escapeByte: UInt8 = 0x3D
    public static let escapeMask: UInt8 = 0xEF

    public static func encode(_ packet: SonyPacket) -> Data {
        var body: [UInt8] = [
            packet.dataType.rawValue,
            packet.sequence,
        ]
        let length = UInt32(packet.payload.count)
        body.append(UInt8((length >> 24) & 0xFF))
        body.append(UInt8((length >> 16) & 0xFF))
        body.append(UInt8((length >> 8) & 0xFF))
        body.append(UInt8(length & 0xFF))
        body.append(contentsOf: packet.payload)
        body.append(body.reduce(UInt8(0)) { $0 &+ $1 })

        var frame: [UInt8] = [startMarker]
        for byte in body {
            if byte == startMarker || byte == endMarker || byte == escapeByte {
                frame.append(escapeByte)
                frame.append(byte & escapeMask)
            } else {
                frame.append(byte)
            }
        }
        frame.append(endMarker)
        return Data(frame)
    }
}

/// Incremental parser for an RFCOMM byte stream.
///
/// A parser instance belongs to one transport session. It tolerates fragmented
/// and coalesced frames, rejects invalid checksums, and resynchronizes at the
/// next start marker.
public final class SonyFrameParser {
    private static let maximumBodyLength = 1_048_576

    private enum State {
        case waitingForStart
        case readingBody
    }

    private var state: State = .waitingForStart
    private var buffer: [UInt8] = []
    private var escapeNext = false

    public init() {}

    public func reset() {
        state = .waitingForStart
        buffer.removeAll(keepingCapacity: true)
        escapeNext = false
    }

    public func feed(_ data: Data) -> [SonyPacket] {
        var packets: [SonyPacket] = []

        for byte in data {
            switch state {
            case .waitingForStart:
                if byte == SonyFraming.startMarker {
                    state = .readingBody
                    buffer.removeAll(keepingCapacity: true)
                    escapeNext = false
                }

            case .readingBody:
                if byte == SonyFraming.endMarker {
                    if let packet = decodeBody(buffer) {
                        packets.append(packet)
                    }
                    state = .waitingForStart
                    buffer.removeAll(keepingCapacity: true)
                    escapeNext = false
                } else if escapeNext {
                    appendBodyByte(byte | ~SonyFraming.escapeMask)
                    escapeNext = false
                } else if byte == SonyFraming.escapeByte {
                    escapeNext = true
                } else if byte == SonyFraming.startMarker {
                    buffer.removeAll(keepingCapacity: true)
                    escapeNext = false
                } else {
                    appendBodyByte(byte)
                }
            }
        }

        return packets
    }

    private func appendBodyByte(_ byte: UInt8) {
        buffer.append(byte)
        if buffer.count > Self.maximumBodyLength {
            state = .waitingForStart
            buffer.removeAll(keepingCapacity: true)
            escapeNext = false
        }
    }

    private func decodeBody(_ body: [UInt8]) -> SonyPacket? {
        guard body.count >= 7 else { return nil }

        let length = (UInt32(body[2]) << 24)
            | (UInt32(body[3]) << 16)
            | (UInt32(body[4]) << 8)
            | UInt32(body[5])
        guard body.count == 7 + Int(length) else {
            return nil
        }

        let checksumIndex = 6 + Int(length)
        let checksum = body[checksumIndex]
        let computed = body.prefix(checksumIndex).reduce(UInt8(0)) { $0 &+ $1 }
        guard computed == checksum else { return nil }

        return SonyPacket(
            dataType: SonyDataType(rawValue: body[0]),
            sequence: body[1],
            payload: Array(body[6..<checksumIndex])
        )
    }
}
