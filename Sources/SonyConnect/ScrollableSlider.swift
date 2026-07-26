import AppKit

// NSSlider ignores the scroll wheel by default. This adds discrete stepping
// while coalescing actions so a high-frequency trackpad gesture cannot flood
// the Bluetooth transport with commands.
final class ScrollableSlider: NSSlider {
    private static let precisePointsPerStep: CGFloat = 10
    private static let actionDelay: TimeInterval = 0.08

    private var preciseDelta: CGFloat = 0
    private var pendingAction: DispatchWorkItem?

    deinit {
        pendingAction?.cancel()
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else {
            super.scrollWheel(with: event)
            return
        }

        if event.phase.contains(.began) {
            preciseDelta = 0
        }
        defer {
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) ||
                event.momentumPhase.contains(.ended) {
                preciseDelta = 0
            }
        }

        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }

        let steps: Int
        if event.hasPreciseScrollingDeltas {
            preciseDelta += delta
            steps = Int(preciseDelta / Self.precisePointsPerStep)
            preciseDelta -= CGFloat(steps) * Self.precisePointsPerStep
        } else {
            steps = delta > 0 ? 1 : -1
        }
        guard steps != 0 else { return }

        let newValue = min(maxValue, max(minValue, doubleValue + Double(steps)))
        guard newValue != doubleValue else { return }
        doubleValue = newValue
        scheduleAction()
    }

    private func scheduleAction() {
        pendingAction?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sendAction(self.action, to: self.target)
        }
        pendingAction = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.actionDelay, execute: work)
    }
}
