import Foundation

public enum Side: String, Codable, Sendable, CaseIterable, Hashable {
    case left, right

    public var opposite: Side { self == .left ? .right : .left }
}

/// A body part independent of side. Exercise specs are written in terms of body parts;
/// the side is resolved at runtime (affected side, or whichever side the camera sees best).
public enum BodyPart: String, Codable, Sendable, CaseIterable, Hashable {
    case shoulder, elbow, wrist, hip, knee, ankle

    public var spokenName: String { rawValue }
}

/// Joints both Apple Vision (iOS) and MediaPipe (web) can provide.
public enum Joint: String, Codable, Sendable, CaseIterable, Hashable {
    case nose, neck, root
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle

    public init(_ part: BodyPart, _ side: Side) {
        switch (part, side) {
        case (.shoulder, .left): self = .leftShoulder
        case (.shoulder, .right): self = .rightShoulder
        case (.elbow, .left): self = .leftElbow
        case (.elbow, .right): self = .rightElbow
        case (.wrist, .left): self = .leftWrist
        case (.wrist, .right): self = .rightWrist
        case (.hip, .left): self = .leftHip
        case (.hip, .right): self = .rightHip
        case (.knee, .left): self = .leftKnee
        case (.knee, .right): self = .rightKnee
        case (.ankle, .left): self = .leftAnkle
        case (.ankle, .right): self = .rightAnkle
        }
    }

    public var side: Side? {
        switch self {
        case .leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle: return .left
        case .rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle: return .right
        case .nose, .neck, .root: return nil
        }
    }

    /// Bone connections used to draw a skeleton overlay.
    public static let bones: [(Joint, Joint)] = [
        (.leftShoulder, .rightShoulder), (.leftHip, .rightHip),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]
}

/// Three body parts on the same side whose middle one is the vertex of the measured angle.
public struct AngleDefinition: Codable, Sendable, Hashable {
    public var from: BodyPart
    public var vertex: BodyPart
    public var to: BodyPart

    public init(_ from: BodyPart, _ vertex: BodyPart, _ to: BodyPart) {
        self.from = from
        self.vertex = vertex
        self.to = to
    }

    public var parts: [BodyPart] { [from, vertex, to] }

    public static let knee = AngleDefinition(.hip, .knee, .ankle)
    public static let hip = AngleDefinition(.shoulder, .hip, .knee)
    public static let elbow = AngleDefinition(.shoulder, .elbow, .wrist)
    public static let bodyLine = AngleDefinition(.shoulder, .hip, .ankle)
    public static let armRaise = AngleDefinition(.hip, .shoulder, .wrist)
}
