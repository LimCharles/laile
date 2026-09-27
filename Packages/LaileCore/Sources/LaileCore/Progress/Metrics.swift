import Foundation

public enum MetricKind: String, Codable, Sendable, CaseIterable, Hashable {
    case kneeFlexion
    case kneeExtensionDeficit
    case straightLegRaiseReps
    case sitToStandReps
    case squatReps
    case pushUpReps
    case gluteBridgeReps
    case jumpingJackReps
    case plankHoldSeconds
    case wallSitSeconds
    case painAtRest

    public var displayName: String {
        switch self {
        case .kneeFlexion: return "Knee bend"
        case .kneeExtensionDeficit: return "Knee straightening gap"
        case .straightLegRaiseReps: return "Straight-leg raises"
        case .sitToStandReps: return "Sit-to-stands"
        case .squatReps: return "Squats"
        case .pushUpReps: return "Push-ups"
        case .gluteBridgeReps: return "Glute bridges"
        case .jumpingJackReps: return "Jumping jacks"
        case .plankHoldSeconds: return "Plank hold"
        case .wallSitSeconds: return "Wall sit"
        case .painAtRest: return "Pain at rest"
        }
    }

    public var unit: String {
        switch self {
        case .kneeFlexion, .kneeExtensionDeficit: return "°"
        case .plankHoldSeconds, .wallSitSeconds: return "s"
        case .painAtRest: return "/10"
        default: return "reps"
        }
    }

    public var higherIsBetter: Bool {
        switch self {
        case .kneeExtensionDeficit, .painAtRest: return false
        default: return true
        }
    }

    /// Smallest change that counts as real progress (below this is measurement noise).
    public var meaningfulChange: Double {
        switch self {
        case .kneeFlexion: return 3
        case .kneeExtensionDeficit: return 2
        case .plankHoldSeconds, .wallSitSeconds: return 5
        case .painAtRest: return 1
        default: return 1
        }
    }

    /// Drop from the best value that counts as a regression worth flagging.
    public var regressionThreshold: Double {
        switch self {
        case .kneeFlexion: return 8
        case .kneeExtensionDeficit: return 5
        case .plankHoldSeconds, .wallSitSeconds: return 15
        case .painAtRest: return 2
        default: return 4
        }
    }

    public func format(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        switch unit {
        case "°": return "\(rounded)°"
        case "s": return rounded >= 60 ? "\(rounded / 60):\(String(format: "%02d", rounded % 60))" : "\(rounded)s"
        case "/10": return "\(rounded)/10"
        default: return "\(rounded)"
        }
    }
}

public struct MetricSample: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: MetricKind
    public var value: Double
    public var date: Date
    public var isBaseline: Bool
    public var exerciseId: String?
    public var sessionId: UUID?

    public init(id: UUID = UUID(), kind: MetricKind, value: Double, date: Date, isBaseline: Bool = false, exerciseId: String? = nil, sessionId: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.value = value
        self.date = date
        self.isBaseline = isBaseline
        self.exerciseId = exerciseId
        self.sessionId = sessionId
    }
}

public struct Milestone: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: MetricKind
    public var threshold: Double
    public var title: String

    public init(id: String, kind: MetricKind, threshold: Double, title: String) {
        self.id = id
        self.kind = kind
        self.threshold = threshold
        self.title = title
    }

    public func isReached(by value: Double) -> Bool {
        kind.higherIsBetter ? value >= threshold : value <= threshold
    }

    public static let rehabDefaults: [Milestone] = [
        Milestone(id: "knee-70", kind: .kneeFlexion, threshold: 70, title: "Knee bends to 70°"),
        Milestone(id: "knee-90", kind: .kneeFlexion, threshold: 90, title: "Knee bends to 90° — chairs get easier"),
        Milestone(id: "knee-110", kind: .kneeFlexion, threshold: 110, title: "Knee bends to 110° — stairs territory"),
        Milestone(id: "knee-120", kind: .kneeFlexion, threshold: 120, title: "Knee bends to 120°"),
        Milestone(id: "ext-10", kind: .kneeExtensionDeficit, threshold: 10, title: "Knee straightens to within 10°"),
        Milestone(id: "ext-5", kind: .kneeExtensionDeficit, threshold: 5, title: "Knee almost fully straight"),
        Milestone(id: "sts-8", kind: .sitToStandReps, threshold: 8, title: "8 sit-to-stands in a set"),
        Milestone(id: "sts-12", kind: .sitToStandReps, threshold: 12, title: "12 sit-to-stands in a set"),
    ]

    public static let moveDefaults: [Milestone] = [
        Milestone(id: "pushup-10", kind: .pushUpReps, threshold: 10, title: "10 push-ups in a set"),
        Milestone(id: "pushup-20", kind: .pushUpReps, threshold: 20, title: "20 push-ups in a set"),
        Milestone(id: "plank-60", kind: .plankHoldSeconds, threshold: 60, title: "One-minute plank"),
        Milestone(id: "plank-120", kind: .plankHoldSeconds, threshold: 120, title: "Two-minute plank"),
        Milestone(id: "squat-20", kind: .squatReps, threshold: 20, title: "20 squats in a set"),
        Milestone(id: "squat-40", kind: .squatReps, threshold: 40, title: "40 squats in a set"),
        Milestone(id: "wallsit-60", kind: .wallSitSeconds, threshold: 60, title: "One-minute wall sit"),
    ]

    public static func defaults(for mode: AppMode) -> [Milestone] {
        mode == .rehab ? rehabDefaults + moveDefaults : moveDefaults
    }
}
