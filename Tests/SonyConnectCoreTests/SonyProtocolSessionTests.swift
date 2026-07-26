import Foundation
import Testing
import SonyConnectCore

@Suite
struct SonyProtocolSessionTests {
    @Test
    func testServiceEndpointsExposeBothKnownUUIDsInSafePriorityOrder() {
        #expect(SonyServiceEndpoint.connectionPriority == [.v1, .v2])
        #expect(
            SonyServiceEndpoint.v1.uuidString
                == "96CC203E-5068-46AD-B32D-E316F5E069BA"
        )
        #expect(
            SonyServiceEndpoint.v2.uuidString
                == "956C7B26-D49A-4BA8-B03F-B17D393CB6E2"
        )
        #expect(SonyServiceEndpoint.v1.uuidBytes.count == 16)
        #expect(SonyServiceEndpoint.v2.uuidBytes.count == 16)
        #expect(SonyServiceEndpoint.v1.protocolVersion == .v1)
        #expect(SonyServiceEndpoint.v2.protocolVersion == .v2)
    }

    @Test
    func testSessionNegotiatesV1AndSerializesRequestsByAcknowledgement() {
        let scheduler = ManualSessionScheduler()
        let session = SonyProtocolSession(
            configuration: longRunningConfiguration,
            scheduler: scheduler
        )
        var outputs: [SonyProtocolSessionOutput] = []
        session.onOutput = { outputs.append($0) }

        session.open(endpoint: .v1)

        #expect(session.state == .negotiating(endpoint: .v1))
        #expect(
            commandPackets(in: outputs)
                == [
                    SonyPacket(
                        dataType: .command1,
                        sequence: 0,
                        payload: [0x00, 0x00]
                    ),
                ]
        )

        session.receive(frame(.ack, sequence: 1))
        session.receive(
            frame(
                .command1,
                sequence: 0,
                payload: [0x01, 0x00, 0x40, 0x10]
            )
        )

        #expect(session.state == .ready(version: .v1))
        #expect(
            outputs.contains(.state(.ready(version: .v1)))
        )
        #expect(
            acknowledgementPackets(in: outputs).last?.sequence == 1
        )

        outputs.removeAll()
        session.submit(.getBattery)
        session.submit(.getNoiseControl)

        #expect(
            commandPackets(in: outputs)
                == [
                    SonyPacket(
                        dataType: .command1,
                        sequence: 1,
                        payload: [0x10, 0x00]
                    ),
                ]
        )

        session.receive(frame(.ack, sequence: 0))

        #expect(
            commandPackets(in: outputs).last
                == SonyPacket(
                    dataType: .command1,
                    sequence: 0,
                    payload: [0x66, 0x02]
                )
        )
    }

    @Test
    func testUnexpectedAcknowledgementDoesNotAdvanceTheQueue() {
        let scheduler = ManualSessionScheduler()
        let session = SonyProtocolSession(
            configuration: longRunningConfiguration,
            scheduler: scheduler
        )
        var outputs: [SonyProtocolSessionOutput] = []
        session.onOutput = { outputs.append($0) }

        session.open(endpoint: .v1)
        session.receive(frame(.ack, sequence: 0))

        #expect(
            outputs.contains(
                .issue(
                    .unexpectedAcknowledgement(
                        expected: 1,
                        received: 0
                    )
                )
            )
        )
        #expect(commandPackets(in: outputs).count == 1)

        session.receive(frame(.ack, sequence: 1))
        scheduler.advance(by: 20)

        #expect(
            !outputs.contains {
                if case .state(
                    .failed(.acknowledgementTimedOut)
                ) = $0 {
                    return true
                }
                return false
            }
        )
    }

    @Test
    func testMissingAcknowledgementRetriesSameFrameThenFailsClosed() {
        let scheduler = ManualSessionScheduler()
        let configuration = SonyProtocolSessionConfiguration(
            acknowledgementTimeout: 1,
            maximumSendAttempts: 3,
            negotiationTimeout: 100,
            v1SecondaryInitializationDelay: 100
        )
        let session = SonyProtocolSession(
            configuration: configuration,
            scheduler: scheduler
        )
        var outputs: [SonyProtocolSessionOutput] = []
        session.onOutput = { outputs.append($0) }

        session.open(endpoint: .v1)
        scheduler.advance(by: 3)

        let writes = commandPackets(in: outputs)
        #expect(writes.count == 3)
        #expect(Set(writes.map(\.sequence)) == [0])
        #expect(Set(writes.map(\.payload)) == [[0x00, 0x00]])
        #expect(
            outputs.contains(
                .issue(
                    .retrying(
                        label: "INIT_REQUEST",
                        attempt: 2,
                        maximumAttempts: 3
                    )
                )
            )
        )
        #expect(
            session.state
                == .failed(
                    .acknowledgementTimedOut(label: "INIT_REQUEST")
                )
        )
    }

    @Test
    func testSynchronousAcknowledgementsDoNotLeaveStaleTimeouts() {
        let scheduler = ManualSessionScheduler()
        let session = SonyProtocolSession(
            configuration: longRunningConfiguration,
            scheduler: scheduler
        )
        var outputs: [SonyProtocolSessionOutput] = []
        session.onOutput = { output in
            outputs.append(output)
            guard case .write(let data, _) = output,
                  let packet = SonyFrameParser().feed(data).first,
                  packet.dataType != .ack else {
                return
            }
            session.receive(
                SonyFraming.encode(
                    SonyPacket(
                        dataType: .ack,
                        sequence: packet.sequence ^ 1,
                        payload: []
                    )
                )
            )
        }

        session.open(endpoint: .v1)
        session.receive(
            frame(
                .command1,
                sequence: 0,
                payload: [0x01, 0x00, 0x40, 0x10]
            )
        )
        outputs.removeAll()

        session.submit(.discoverGeneralSettings)
        scheduler.advance(by: 200)

        #expect(session.state == .ready(version: .v1))
        #expect(
            commandPackets(in: outputs)
                .filter { $0.payload.first == 0xD0 }
                .count == 3
        )
        #expect(
            !outputs.contains {
                if case .state(
                    .failed(.acknowledgementTimedOut)
                ) = $0 {
                    return true
                }
                return false
            }
        )
    }

    @Test
    func testV2ReplyNeverFallsThroughToV1WhenAdapterIsUnavailable() {
        let scheduler = ManualSessionScheduler()
        let session = SonyProtocolSession(
            configuration: longRunningConfiguration,
            scheduler: scheduler
        )
        var outputs: [SonyProtocolSessionOutput] = []
        session.onOutput = { outputs.append($0) }

        session.open(endpoint: .v2)
        session.receive(
            frame(
                .command1,
                sequence: 0,
                payload: [
                    0x01, 0x00, 0x03, 0x00,
                    0x00, 0x00, 0x00, 0x00,
                ]
            )
        )

        #expect(session.state == .unsupported(version: .v2))
        #expect(
            outputs.contains(.state(.unsupported(version: .v2)))
        )
        #expect(commandPackets(in: outputs).count == 1)
        #expect(acknowledgementPackets(in: outputs).count == 1)

        session.submit(.getBattery)
        #expect(commandPackets(in: outputs).count == 1)
        #expect(
            outputs.contains(.issue(.ignoredIntent(.getBattery)))
        )
    }

    @Test
    func testCanonicalReplyOverridesServiceHintWhenAdapterExists() {
        let scheduler = ManualSessionScheduler()
        let v2Adapter = StubV2Adapter()
        let session = SonyProtocolSession(
            configuration: longRunningConfiguration,
            scheduler: scheduler,
            adapterFactory: { version in
                switch version {
                case .v1: return SonyProtocolV1()
                case .v2: return v2Adapter
                }
            }
        )
        var outputs: [SonyProtocolSessionOutput] = []
        session.onOutput = { outputs.append($0) }

        session.open(endpoint: .v1)
        session.receive(
            frame(
                .command1,
                sequence: 0,
                payload: [
                    0x01, 0x00, 0x03, 0x00,
                    0x00, 0x00, 0x00, 0x00,
                ]
            )
        )

        #expect(session.state == .ready(version: .v2))
        #expect(
            outputs.contains(
                .issue(
                    .protocolHintMismatch(
                        endpoint: .v1,
                        detected: .v2
                    )
                )
            )
        )

        session.receive(frame(.ack, sequence: 1))
        outputs.removeAll()
        session.submit(.getBattery)
        #expect(commandPackets(in: outputs).first?.payload == [0x22, 0x00])
    }

    @Test
    func testV1StateDumpCanCompleteNegotiationAndEmitTypedState() {
        let scheduler = ManualSessionScheduler()
        let session = SonyProtocolSession(
            configuration: longRunningConfiguration,
            scheduler: scheduler
        )
        var outputs: [SonyProtocolSessionOutput] = []
        session.onOutput = { outputs.append($0) }

        session.open(endpoint: .v1)
        session.receive(frame(.ack, sequence: 1))
        session.receive(
            frame(
                .command1,
                sequence: 0,
                payload: [0x11, 0x00, 0x54, 0x01]
            )
        )

        #expect(session.state == .ready(version: .v1))
        #expect(
            outputs.contains(
                .event(.battery(level: 84, charging: true))
            )
        )

        let eventIndex = outputs.firstIndex(
            of: .event(.battery(level: 84, charging: true))
        )
        let readyIndex = outputs.firstIndex(
            of: .state(.ready(version: .v1))
        )
        #expect(eventIndex != nil)
        #expect(readyIndex != nil)
        if let eventIndex, let readyIndex {
            #expect(eventIndex < readyIndex)
        }
    }

    @Test
    func testCloseCancelsDelayedIntentsFromPreviousGeneration() {
        let scheduler = ManualSessionScheduler()
        let session = SonyProtocolSession(
            configuration: longRunningConfiguration,
            scheduler: scheduler
        )
        var outputs: [SonyProtocolSessionOutput] = []
        session.onOutput = { outputs.append($0) }

        makeV1Ready(session)
        session.submit(.getBattery, after: 1)
        session.close()
        session.open(endpoint: .v1)
        outputs.removeAll()

        scheduler.advance(by: 1)

        #expect(
            !commandPackets(in: outputs)
                .contains { $0.payload == [0x10, 0x00] }
        )
    }

    @Test
    func testV1NegotiationTimeoutKeepsLegacyFallback() {
        let scheduler = ManualSessionScheduler()
        let configuration = SonyProtocolSessionConfiguration(
            acknowledgementTimeout: 100,
            maximumSendAttempts: 3,
            negotiationTimeout: 2,
            v1SecondaryInitializationDelay: 100
        )
        let session = SonyProtocolSession(
            configuration: configuration,
            scheduler: scheduler
        )

        session.open(endpoint: .v1)
        session.receive(frame(.ack, sequence: 1))
        scheduler.advance(by: 2)

        #expect(session.state == .ready(version: .v1))
    }

    private var longRunningConfiguration:
        SonyProtocolSessionConfiguration
    {
        SonyProtocolSessionConfiguration(
            acknowledgementTimeout: 100,
            maximumSendAttempts: 3,
            negotiationTimeout: 100,
            v1SecondaryInitializationDelay: 100
        )
    }

    private func makeV1Ready(_ session: SonyProtocolSession) {
        session.open(endpoint: .v1)
        session.receive(frame(.ack, sequence: 1))
        session.receive(
            frame(
                .command1,
                sequence: 0,
                payload: [0x01, 0x00, 0x40, 0x10]
            )
        )
    }

    private func frame(
        _ dataType: SonyDataType,
        sequence: UInt8,
        payload: [UInt8] = []
    ) -> Data {
        SonyFraming.encode(
            SonyPacket(
                dataType: dataType,
                sequence: sequence,
                payload: payload
            )
        )
    }

    private func commandPackets(
        in outputs: [SonyProtocolSessionOutput]
    ) -> [SonyPacket] {
        packets(in: outputs).filter { $0.dataType != .ack }
    }

    private func acknowledgementPackets(
        in outputs: [SonyProtocolSessionOutput]
    ) -> [SonyPacket] {
        packets(in: outputs).filter { $0.dataType == .ack }
    }

    private func packets(
        in outputs: [SonyProtocolSessionOutput]
    ) -> [SonyPacket] {
        outputs.compactMap { output in
            guard case .write(let data, _) = output else {
                return nil
            }
            return SonyFrameParser().feed(data).first
        }
    }
}

private final class StubV2Adapter: SonyProtocolAdapter {
    let version: SonyProtocolVersion = .v2

    func reset() {}

    func makeRequests(
        for intent: SonyProtocolIntent
    ) -> [SonyProtocolRequest] {
        switch intent {
        case .startSession:
            return [
                SonyProtocolRequest(
                    payload: [0x00, 0x00],
                    label: "V2 INIT"
                ),
            ]
        case .getBattery:
            return [
                SonyProtocolRequest(
                    payload: [0x22, 0x00],
                    label: "V2 BATTERY GET"
                ),
            ]
        default:
            return []
        }
    }

    func decode(_ packet: SonyPacket) -> SonyProtocolOutput {
        SonyProtocolOutput()
    }
}

private final class ManualSessionScheduler:
    SonyProtocolSessionScheduler
{
    private final class Task: SonyProtocolSessionScheduledTask {
        let deadline: TimeInterval
        let order: Int
        private var action: (() -> Void)?

        init(
            deadline: TimeInterval,
            order: Int,
            action: @escaping () -> Void
        ) {
            self.deadline = deadline
            self.order = order
            self.action = action
        }

        var isPending: Bool {
            action != nil
        }

        func run() {
            let pendingAction = action
            action = nil
            pendingAction?()
        }

        func cancel() {
            action = nil
        }
    }

    private var now: TimeInterval = 0
    private var nextOrder = 0
    private var tasks: [Task] = []

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> any SonyProtocolSessionScheduledTask {
        nextOrder += 1
        let task = Task(
            deadline: now + max(0, delay),
            order: nextOrder,
            action: action
        )
        tasks.append(task)
        return task
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval

        while let nextIndex = nextRunnableTaskIndex(upTo: target) {
            let task = tasks.remove(at: nextIndex)
            now = task.deadline
            task.run()
        }

        now = target
    }

    private func nextRunnableTaskIndex(
        upTo target: TimeInterval
    ) -> Int? {
        tasks.indices
            .filter {
                tasks[$0].isPending
                    && tasks[$0].deadline <= target
            }
            .min {
                let left = tasks[$0]
                let right = tasks[$1]
                if left.deadline == right.deadline {
                    return left.order < right.order
                }
                return left.deadline < right.deadline
            }
    }
}
