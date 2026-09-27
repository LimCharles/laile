import Foundation

/// Normalized image coordinates: (0,0) top-left, (1,1) bottom-right.
public struct Point2: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Landmark: Codable, Sendable, Hashable {
    public var position: Point2
    public var confidence: Double

    public init(_ position: Point2, confidence: Double) {
        self.position = position
        self.confidence = confidence
    }
}

/// One frame of pose output from any provider (Vision, MediaPipe, simulator).
public struct PoseFrame: Sendable {
    public static let defaultMinConfidence = 0.3

    /// Seconds on a monotonic-ish clock shared with the session conductor.
    public var timestamp: TimeInterval
    public var landmarks: [Joint: Landmark]
    /// Image width / height. Normalized coordinates must be rescaled by this before
    /// measuring angles, otherwise a portrait frame squashes every angle.
    public var imageAspect: Double

    public init(timestamp: TimeInterval, landmarks: [Joint: Landmark], imageAspect: Double) {
        self.timestamp = timestamp
        self.landmarks = landmarks
        self.imageAspect = imageAspect
    }

    public func landmark(_ joint: Joint, minConfidence: Double = PoseFrame.defaultMinConfidence) -> Landmark? {
        guard let lm = landmarks[joint], lm.confidence >= minConfidence else { return nil }
        return lm
    }

    /// Position in aspect-corrected space (x scaled by aspect) for geometry.
    public func metricPoint(_ joint: Joint, minConfidence: Double = PoseFrame.defaultMinConfidence) -> Point2? {
        guard let lm = landmark(joint, minConfidence: minConfidence) else { return nil }
        return Point2(lm.position.x * imageAspect, lm.position.y)
    }

    public func angle(_ definition: AngleDefinition, side: Side, minConfidence: Double = PoseFrame.defaultMinConfidence) -> Double? {
        guard
            let a = metricPoint(Joint(definition.from, side), minConfidence: minConfidence),
            let v = metricPoint(Joint(definition.vertex, side), minConfidence: minConfidence),
            let b = metricPoint(Joint(definition.to, side), minConfidence: minConfidence)
        else { return nil }
        return Geometry.angle(a, vertex: v, b)
    }

    /// Mean confidence of the given parts on one side (missing joints count as 0).
    public func meanConfidence(of parts: [BodyPart], side: Side) -> Double {
        guard !parts.isEmpty else { return 0 }
        let total = parts.reduce(0.0) { $0 + (landmarks[Joint($1, side)]?.confidence ?? 0) }
        return total / Double(parts.count)
    }
}

public enum Geometry {
    /// Interior angle at `vertex` in degrees, 0...180.
    public static func angle(_ a: Point2, vertex v: Point2, _ b: Point2) -> Double {
        let v1 = (a.x - v.x, a.y - v.y)
        let v2 = (b.x - v.x, b.y - v.y)
        let m1 = (v1.0 * v1.0 + v1.1 * v1.1).squareRoot()
        let m2 = (v2.0 * v2.0 + v2.1 * v2.1).squareRoot()
        guard m1 > 1e-9, m2 > 1e-9 else { return 0 }
        let cosine = max(-1, min(1, (v1.0 * v2.0 + v1.1 * v2.1) / (m1 * m2)))
        return acos(cosine) * 180 / .pi
    }

    public static func distance(_ a: Point2, _ b: Point2) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    public static func midpoint(_ a: Point2, _ b: Point2) -> Point2 {
        Point2((a.x + b.x) / 2, (a.y + b.y) / 2)
    }
}

/// Exponential moving average to take the jitter out of per-frame joint angles.
public struct AngleSmoother: Sendable {
    public var alpha: Double
    public private(set) var value: Double?

    public init(alpha: Double = 0.35) {
        self.alpha = alpha
    }

    public mutating func update(_ sample: Double) -> Double {
        let next = value.map { $0 + alpha * (sample - $0) } ?? sample
        value = next
        return next
    }

    public mutating func reset() { value = nil }
}
