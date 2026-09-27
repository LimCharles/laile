import Foundation

public enum RepEvent: Sendable, Equatable {
    /// A full rep: start → target → start. `peakAngle` is the extreme angle reached.
    case rep(count: Int, peakAngle: Double)
    /// Moved a meaningful part of the way but didn't reach the target.
    case partial(peakAngle: Double, progress: Double)
}

/// Direction-agnostic rep counter with hysteresis.
///
/// Progress is 0 at the rest position and 1 at the target, whichever way the angle moves,
/// so the same logic counts heel slides (angle shrinks) and bridges (angle grows).
public struct RepCounter: Sendable {
    enum State: Sendable, Equatable {
        case waitingForStart
        case atStart
        case inRep(peakProgress: Double, peakAngle: Double, reachedTarget: Bool)
    }

    public let rule: RepRule
    public private(set) var count = 0
    public private(set) var partials = 0
    public private(set) var currentProgress: Double = 0
    var state: State = .waitingForStart

    /// Progress below this is "back at the start".
    static let startBand = 0.12
    /// Progress above this means a rep has begun.
    static let leaveStartBand = 0.2

    public init(rule: RepRule) {
        self.rule = rule
    }

    public func progress(for angle: Double) -> Double {
        let span = rule.target - rule.start
        guard abs(span) > 1e-6 else { return 0 }
        return (angle - rule.start) / span
    }

    public var isAtStart: Bool { state == .atStart }

    @discardableResult
    public mutating func update(angle: Double) -> RepEvent? {
        let p = progress(for: angle)
        currentProgress = p
        switch state {
        case .waitingForStart:
            if p <= Self.startBand { state = .atStart }
            return nil

        case .atStart:
            if p > Self.leaveStartBand {
                state = .inRep(peakProgress: p, peakAngle: angle, reachedTarget: p >= 1)
            }
            return nil

        case .inRep(var peakProgress, var peakAngle, var reachedTarget):
            if p > peakProgress {
                peakProgress = p
                peakAngle = angle
            }
            if p >= 1 { reachedTarget = true }

            if p <= Self.startBand {
                state = .atStart
                if reachedTarget {
                    count += 1
                    return .rep(count: count, peakAngle: peakAngle)
                }
                if peakProgress >= rule.partialFraction {
                    partials += 1
                    return .partial(peakAngle: peakAngle, progress: peakProgress)
                }
                return nil
            }
            state = .inRep(peakProgress: peakProgress, peakAngle: peakAngle, reachedTarget: reachedTarget)
            return nil
        }
    }

    /// Call when tracking is lost for a while so a half-finished rep isn't counted later.
    public mutating func interrupt() {
        if case .inRep = state { state = .waitingForStart }
    }
}

/// Accumulates time while a hold condition is met. Brief dropouts (tracking jitter)
/// inside the grace window don't stop the clock; longer ones pause it.
public struct HoldTimer: Sendable {
    public let targetSeconds: Double
    public private(set) var heldSeconds: Double = 0
    public private(set) var isHolding = false
    var lastTimestamp: TimeInterval?
    var lastSatisfiedAt: TimeInterval?

    public static let grace: TimeInterval = 0.5
    static let maxStep: TimeInterval = 0.25

    public init(targetSeconds: Double) {
        self.targetSeconds = targetSeconds
    }

    public var isComplete: Bool { heldSeconds >= targetSeconds }
    public var wholeSeconds: Int { Int(heldSeconds) }

    public struct Update: Sendable, Equatable {
        /// Whole seconds crossed during this update (e.g. [3] when 2.9 → 3.1).
        public var crossedSeconds: [Int]
        public var completed: Bool
        public var startedHolding: Bool
        public var stoppedHolding: Bool
    }

    public mutating func update(satisfied: Bool, at t: TimeInterval) -> Update {
        defer { lastTimestamp = t }
        let before = heldSeconds
        let wasHolding = isHolding
        let wasComplete = isComplete

        if satisfied { lastSatisfiedAt = t }
        let withinGrace = lastSatisfiedAt.map { t - $0 <= Self.grace } ?? false
        isHolding = satisfied || (wasHolding && withinGrace)

        if isHolding, let last = lastTimestamp, !isComplete {
            let step = min(max(0, t - last), Self.maxStep)
            heldSeconds = min(targetSeconds, heldSeconds + step)
        }

        let crossed = Int(before) < Int(heldSeconds) ? Array((Int(before) + 1)...Int(heldSeconds)) : []
        return Update(
            crossedSeconds: crossed,
            completed: !wasComplete && isComplete,
            startedHolding: !wasHolding && isHolding,
            stoppedHolding: wasHolding && !isHolding
        )
    }
}
