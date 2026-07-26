import Dispatch
import Foundation

public protocol SonyProtocolSessionScheduledTask: AnyObject {
    func cancel()
}

/// Internal time seam used by the session for retries and generation-safe
/// delayed intents. Production uses Dispatch; tests use a manual scheduler.
public protocol SonyProtocolSessionScheduler: AnyObject {
    @discardableResult
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> any SonyProtocolSessionScheduledTask
}

public final class SonyDispatchProtocolSessionScheduler:
    SonyProtocolSessionScheduler
{
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func schedule(
        after delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> any SonyProtocolSessionScheduledTask {
        let task = DispatchScheduledTask(action: action)
        queue.asyncAfter(deadline: .now() + max(0, delay)) { [weak task] in
            task?.run()
        }
        return task
    }
}

private final class DispatchScheduledTask: SonyProtocolSessionScheduledTask {
    private var action: (() -> Void)?

    init(action: @escaping () -> Void) {
        self.action = action
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

public struct SonyProtocolSessionConfiguration: Equatable {
    public var acknowledgementTimeout: TimeInterval
    public var maximumSendAttempts: Int
    public var negotiationTimeout: TimeInterval
    public var v1SecondaryInitializationDelay: TimeInterval

    public init(
        acknowledgementTimeout: TimeInterval = 1.0,
        maximumSendAttempts: Int = 3,
        negotiationTimeout: TimeInterval = 2.0,
        v1SecondaryInitializationDelay: TimeInterval = 0.6
    ) {
        self.acknowledgementTimeout = max(0.01, acknowledgementTimeout)
        self.maximumSendAttempts = max(1, maximumSendAttempts)
        self.negotiationTimeout = max(0.01, negotiationTimeout)
        self.v1SecondaryInitializationDelay = max(
            0,
            v1SecondaryInitializationDelay
        )
    }
}

public enum SonyProtocolSessionFailure: Equatable {
    case acknowledgementTimedOut(label: String)
    case negotiationTimedOut(endpoint: SonyServiceEndpoint)
}

public enum SonyProtocolSessionState: Equatable {
    case idle
    case negotiating(endpoint: SonyServiceEndpoint)
    case ready(version: SonyProtocolVersion)
    case unsupported(version: SonyProtocolVersion)
    case failed(SonyProtocolSessionFailure)

    public var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}

public enum SonyProtocolSessionIssue: Equatable {
    case ignoredIntent(SonyProtocolIntent)
    case protocolHintMismatch(
        endpoint: SonyServiceEndpoint,
        detected: SonyProtocolVersion
    )
    case retrying(label: String, attempt: Int, maximumAttempts: Int)
    case unexpectedAcknowledgement(expected: UInt8?, received: UInt8)
}

public enum SonyProtocolSessionOutput: Equatable {
    case write(data: Data, label: String)
    case event(SonyProtocolEvent)
    case state(SonyProtocolSessionState)
    case issue(SonyProtocolSessionIssue)
}

public typealias SonyProtocolAdapterFactory =
    (SonyProtocolVersion) -> (any SonyProtocolAdapter)?

/// Owns one Sony control-channel session.
///
/// The interface deliberately hides framing, sequence numbers, ACK
/// correlation, retries, request serialization, negotiation, and stale-timer
/// cancellation. Call every method from the same serial executor used by the
/// injected scheduler (the main queue by default).
public final class SonyProtocolSession {
    public var onOutput: ((SonyProtocolSessionOutput) -> Void)?

    public private(set) var state: SonyProtocolSessionState = .idle

    private struct InFlightRequest {
        let identifier: UInt64
        let request: SonyProtocolRequest
        let sequence: UInt8
        let encodedData: Data
        var attempt: Int
    }

    private let configuration: SonyProtocolSessionConfiguration
    private let scheduler: any SonyProtocolSessionScheduler
    private let adapterFactory: SonyProtocolAdapterFactory
    private let parser = SonyFrameParser()

    private var generation: UInt64 = 0
    private var hintedAdapter: (any SonyProtocolAdapter)?
    private var adapter: (any SonyProtocolAdapter)?
    private var nextSequence: UInt8 = 0
    private var nextRequestIdentifier: UInt64 = 0
    private var requestQueue: [SonyProtocolRequest] = []
    private var inFlight: InFlightRequest?

    private var acknowledgementTask:
        (any SonyProtocolSessionScheduledTask)?
    private var negotiationTask:
        (any SonyProtocolSessionScheduledTask)?
    private var secondaryInitializationTask:
        (any SonyProtocolSessionScheduledTask)?
    private var delayedIntentTasks:
        [UUID: any SonyProtocolSessionScheduledTask] = [:]

    public init(
        configuration: SonyProtocolSessionConfiguration = .init(),
        scheduler: any SonyProtocolSessionScheduler =
            SonyDispatchProtocolSessionScheduler(),
        adapterFactory: @escaping SonyProtocolAdapterFactory = {
            version in
            switch version {
            case .v1: return SonyProtocolV1()
            case .v2: return nil
            }
        }
    ) {
        self.configuration = configuration
        self.scheduler = scheduler
        self.adapterFactory = adapterFactory
    }

    public func open(endpoint: SonyServiceEndpoint) {
        invalidateCurrentGeneration()

        hintedAdapter = adapterFactory(endpoint.protocolVersion)
        hintedAdapter?.reset()
        transition(to: .negotiating(endpoint: endpoint))

        scheduleNegotiationTimeout()
        if endpoint == .v1 {
            scheduleV1SecondaryInitialization()
        }

        let startRequests = hintedAdapter?
            .makeRequests(for: .startSession) ?? []
        enqueue(
            startRequests.isEmpty
                ? [Self.universalInitializationRequest]
                : startRequests
        )
    }

    public func close() {
        let shouldEmitIdle = state != .idle
        invalidateCurrentGeneration()
        if shouldEmitIdle {
            transition(to: .idle)
        }
    }

    public func submit(
        _ intent: SonyProtocolIntent,
        after delay: TimeInterval = 0
    ) {
        guard state.isReady else {
            emit(.issue(.ignoredIntent(intent)))
            return
        }

        if delay <= 0 {
            submitNow(intent)
            return
        }

        let scheduledGeneration = generation
        let taskIdentifier = UUID()
        delayedIntentTasks[taskIdentifier] = scheduler.schedule(
            after: delay
        ) { [weak self] in
            guard let self else {
                return
            }
            self.delayedIntentTasks[taskIdentifier] = nil
            guard self.generation == scheduledGeneration,
                  self.state.isReady else {
                return
            }
            self.submitNow(intent)
        }
    }

    public func receive(_ data: Data) {
        guard state != .idle else { return }

        for packet in parser.feed(data) {
            let packetGeneration = generation

            if packet.dataType == .ack {
                handleAcknowledgement(packet)
                guard generation == packetGeneration else { return }
                continue
            }

            emitAcknowledgement(for: packet)
            guard generation == packetGeneration else { return }
            guard !packet.payload.isEmpty else { continue }

            var activatedVersion: SonyProtocolVersion?
            if adapter == nil {
                guard let version = negotiatedVersion(using: packet),
                      selectAdapter(version: version) else {
                    continue
                }
                activatedVersion = version
            }

            guard let adapter else { continue }
            let output = adapter.decode(packet)
            for event in output.events {
                emit(.event(event))
                guard generation == packetGeneration else { return }
            }
            enqueue(output.requests)
            guard generation == packetGeneration else { return }

            if let activatedVersion,
               case .negotiating = state {
                transition(to: .ready(version: activatedVersion))
            }
        }
    }

    private static let universalInitializationRequest = SonyProtocolRequest(
        payload: [0x00, 0x00],
        label: "INIT_REQUEST"
    )

    private func submitNow(_ intent: SonyProtocolIntent) {
        guard let adapter, state.isReady else {
            emit(.issue(.ignoredIntent(intent)))
            return
        }
        enqueue(adapter.makeRequests(for: intent))
    }

    private func enqueue(_ requests: [SonyProtocolRequest]) {
        guard !requests.isEmpty else { return }
        requestQueue.append(contentsOf: requests)
        drainRequestQueue()
    }

    private func drainRequestQueue() {
        guard inFlight == nil,
              !requestQueue.isEmpty,
              canWriteQueuedRequests else {
            return
        }

        let request = requestQueue.removeFirst()
        let packet = SonyPacket(
            dataType: request.dataType,
            sequence: nextSequence,
            payload: request.payload
        )
        let pending = InFlightRequest(
            identifier: nextRequestIdentifier,
            request: request,
            sequence: nextSequence,
            encodedData: SonyFraming.encode(packet),
            attempt: 1
        )
        nextRequestIdentifier &+= 1
        let scheduledGeneration = generation
        inFlight = pending
        emit(.write(data: pending.encodedData, label: request.label))
        guard generation == scheduledGeneration,
              inFlight?.identifier == pending.identifier else {
            return
        }
        scheduleAcknowledgementTimeout(for: pending)
    }

    private var canWriteQueuedRequests: Bool {
        switch state {
        case .negotiating, .ready:
            return true
        case .idle, .unsupported, .failed:
            return false
        }
    }

    private func emitAcknowledgement(for packet: SonyPacket) {
        let acknowledgement = SonyPacket(
            dataType: .ack,
            sequence: packet.sequence ^ 1,
            payload: []
        )
        emit(
            .write(
                data: SonyFraming.encode(acknowledgement),
                label: "ACK seq=\(acknowledgement.sequence)"
            )
        )
    }

    private func handleAcknowledgement(_ packet: SonyPacket) {
        guard canWriteQueuedRequests else { return }

        guard let pending = inFlight else {
            emit(
                .issue(
                    .unexpectedAcknowledgement(
                        expected: nil,
                        received: packet.sequence
                    )
                )
            )
            return
        }

        let expectedSequence = pending.sequence ^ 1
        guard packet.sequence == expectedSequence else {
            emit(
                .issue(
                    .unexpectedAcknowledgement(
                        expected: expectedSequence,
                        received: packet.sequence
                    )
                )
            )
            return
        }

        acknowledgementTask?.cancel()
        acknowledgementTask = nil
        nextSequence = packet.sequence
        inFlight = nil
        drainRequestQueue()
    }

    private func scheduleAcknowledgementTimeout(
        for pending: InFlightRequest
    ) {
        acknowledgementTask?.cancel()
        let scheduledGeneration = generation
        acknowledgementTask = scheduler.schedule(
            after: configuration.acknowledgementTimeout
        ) { [weak self] in
            self?.handleAcknowledgementTimeout(
                generation: scheduledGeneration,
                requestIdentifier: pending.identifier
            )
        }
    }

    private func handleAcknowledgementTimeout(
        generation scheduledGeneration: UInt64,
        requestIdentifier: UInt64
    ) {
        guard generation == scheduledGeneration,
              var pending = inFlight,
              pending.identifier == requestIdentifier else {
            return
        }

        if pending.attempt < configuration.maximumSendAttempts {
            pending.attempt += 1
            inFlight = pending
            emit(
                .issue(
                    .retrying(
                        label: pending.request.label,
                        attempt: pending.attempt,
                        maximumAttempts:
                            configuration.maximumSendAttempts
                    )
                )
            )
            guard generation == scheduledGeneration,
                  inFlight?.identifier == pending.identifier else {
                return
            }
            emit(
                .write(
                    data: pending.encodedData,
                    label: pending.request.label
                )
            )
            guard generation == scheduledGeneration,
                  inFlight?.identifier == pending.identifier else {
                return
            }
            scheduleAcknowledgementTimeout(for: pending)
            return
        }

        fail(
            .acknowledgementTimedOut(label: pending.request.label)
        )
    }

    private func negotiatedVersion(
        using packet: SonyPacket
    ) -> SonyProtocolVersion? {
        guard case .negotiating(let serviceEndpoint) = state else {
            return nil
        }

        if let detectedVersion = Self.detectProtocolVersion(in: packet) {
            if detectedVersion != serviceEndpoint.protocolVersion {
                emit(
                    .issue(
                        .protocolHintMismatch(
                            endpoint: serviceEndpoint,
                            detected: detectedVersion
                        )
                    )
                )
            }
            return detectedVersion
        }

        if packet.dataType == .command1
            || packet.dataType == .command2
        {
            return serviceEndpoint.protocolVersion
        }

        return nil
    }

    private static func detectProtocolVersion(
        in packet: SonyPacket
    ) -> SonyProtocolVersion? {
        guard packet.dataType == .command1,
              packet.payload.first == 0x01 else {
            return nil
        }

        switch packet.payload.count {
        case 4: return .v1
        case 8: return .v2
        default: return nil
        }
    }

    private func activate(version: SonyProtocolVersion) {
        guard selectAdapter(version: version) else { return }
        transition(to: .ready(version: version))
    }

    private func selectAdapter(version: SonyProtocolVersion) -> Bool {
        guard case .negotiating(let serviceEndpoint) = state else {
            return false
        }

        let selectedAdapter: (any SonyProtocolAdapter)?
        if version == serviceEndpoint.protocolVersion {
            selectedAdapter = hintedAdapter
        } else {
            selectedAdapter = adapterFactory(version)
            selectedAdapter?.reset()
        }

        guard let selectedAdapter else {
            enterUnsupported(version: version)
            return false
        }

        adapter = selectedAdapter
        hintedAdapter = nil
        negotiationTask?.cancel()
        negotiationTask = nil
        secondaryInitializationTask?.cancel()
        secondaryInitializationTask = nil
        return true
    }

    private func scheduleNegotiationTimeout() {
        let scheduledGeneration = generation
        negotiationTask = scheduler.schedule(
            after: configuration.negotiationTimeout
        ) { [weak self] in
            guard let self,
                  self.generation == scheduledGeneration,
                  case .negotiating(let endpoint) = self.state else {
                return
            }

            if endpoint == .v1, self.hintedAdapter != nil {
                // Preserves the XM3/XM4 fallback for firmware that ACKs INIT
                // but never emits the canonical four-byte reply.
                self.activate(version: .v1)
            } else if self.hintedAdapter == nil {
                self.enterUnsupported(version: endpoint.protocolVersion)
            } else {
                self.fail(.negotiationTimedOut(endpoint: endpoint))
            }
        }
    }

    private func scheduleV1SecondaryInitialization() {
        let scheduledGeneration = generation
        secondaryInitializationTask = scheduler.schedule(
            after: configuration.v1SecondaryInitializationDelay
        ) { [weak self] in
            guard let self,
                  self.generation == scheduledGeneration,
                  case .negotiating = self.state,
                  let adapter = self.hintedAdapter else {
                return
            }
            self.enqueue(
                adapter.makeRequests(
                    for: .continueSessionInitialization
                )
            )
        }
    }

    private func enterUnsupported(version: SonyProtocolVersion) {
        cancelPendingWork()
        adapter = nil
        hintedAdapter = nil
        transition(to: .unsupported(version: version))
    }

    private func fail(_ failure: SonyProtocolSessionFailure) {
        cancelPendingWork()
        adapter = nil
        hintedAdapter = nil
        transition(to: .failed(failure))
    }

    private func transition(to newState: SonyProtocolSessionState) {
        guard state != newState else { return }
        state = newState
        emit(.state(newState))
    }

    private func emit(_ output: SonyProtocolSessionOutput) {
        onOutput?(output)
    }

    private func invalidateCurrentGeneration() {
        generation &+= 1
        cancelPendingWork()
        parser.reset()
        adapter?.reset()
        hintedAdapter?.reset()
        adapter = nil
        hintedAdapter = nil
        nextSequence = 0
    }

    private func cancelPendingWork() {
        acknowledgementTask?.cancel()
        negotiationTask?.cancel()
        secondaryInitializationTask?.cancel()
        for task in delayedIntentTasks.values {
            task.cancel()
        }

        acknowledgementTask = nil
        negotiationTask = nil
        secondaryInitializationTask = nil
        delayedIntentTasks.removeAll(keepingCapacity: true)
        requestQueue.removeAll(keepingCapacity: true)
        inFlight = nil
    }
}
