import Foundation

public enum SetupIssue: Sendable, Hashable {
    case noPerson
    case partsNotVisible([BodyPart])
    case tooClose
    case tooFar
    case offCenter
    case needSideView
    case needFrontView

    public var guidance: CueLine {
        switch self {
        case .noPerson:
            return CueLine("I can't see anyone yet. Step into the frame.", key: "setup.no-person")
        case .partsNotVisible(let parts):
            return CueCatalog.missing(parts)
        case .tooClose:
            return CueLine("You're a bit close. Move the phone further away.", key: "setup.too-close")
        case .tooFar:
            return CueLine("You're quite far away. Bring the phone a little closer.", key: "setup.too-far")
        case .offCenter:
            return CueLine("Shift over so you're in the middle of the screen.", key: "setup.off-center")
        case .needSideView:
            return CueLine("Turn so your side faces the phone.", key: "setup.side-view")
        case .needFrontView:
            return CueLine("Turn to face the phone.", key: "setup.front-view")
        }
    }
}

public struct SetupStatus: Sendable, Equatable {
    public var isReady: Bool
    public var issues: [SetupIssue]
    /// Side chosen for tracking (affected side, or the side the camera sees best).
    public var side: Side

    public init(isReady: Bool, issues: [SetupIssue], side: Side) {
        self.isReady = isReady
        self.issues = issues
        self.side = side
    }
}

/// Checks whether the camera can see what an exercise needs, and says how to fix it if not.
public enum SetupCheck {
    public static func evaluate(_ frame: PoseFrame, spec: ExerciseSpec, preferredSide: Side?, minConfidence: Double = PoseFrame.defaultMinConfidence) -> SetupStatus {
        let parts = spec.requiredParts
        let visible = frame.landmarks.filter { $0.value.confidence >= minConfidence }
        guard visible.count >= 4 else {
            return SetupStatus(isReady: false, issues: [.noPerson], side: preferredSide ?? .left)
        }

        let side: Side = preferredSide ?? (
            frame.meanConfidence(of: parts, side: .left) >= frame.meanConfidence(of: parts, side: .right) ? .left : .right
        )

        var issues: [SetupIssue] = []
        let missing = parts.filter { frame.landmark(Joint($0, side), minConfidence: minConfidence) == nil }

        // Framing from the bounding box of confident landmarks.
        let xs = visible.map(\.value.position.x), ys = visible.map(\.value.position.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1, minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        let width = maxX - minX, height = maxY - minY
        let centerX = (minX + maxX) / 2
        let touchesEdge = minX < 0.02 || maxX > 0.98 || minY < 0.02 || maxY > 0.98

        if !missing.isEmpty {
            issues.append(touchesEdge ? .tooClose : .partsNotVisible(missing))
        } else if max(width, height) < 0.3 {
            issues.append(.tooFar)
        }
        if centerX < 0.22 || centerX > 0.78 { issues.append(.offCenter) }

        if let orientation = viewOrientation(frame, minConfidence: minConfidence) {
            switch (spec.cameraView, orientation) {
            case (.side, .front): issues.append(.needSideView)
            case (.front, .side): issues.append(.needFrontView)
            default: break
            }
        }

        return SetupStatus(isReady: issues.isEmpty, issues: issues, side: side)
    }

    enum Orientation { case side, front }

    /// Side-on bodies have shoulders that overlap in the image; front-on bodies don't.
    static func viewOrientation(_ frame: PoseFrame, minConfidence: Double) -> Orientation? {
        let ls = frame.metricPoint(.leftShoulder, minConfidence: minConfidence)
        let rs = frame.metricPoint(.rightShoulder, minConfidence: minConfidence)
        let lh = frame.metricPoint(.leftHip, minConfidence: minConfidence)
        let rh = frame.metricPoint(.rightHip, minConfidence: minConfidence)

        guard let shoulder = ls ?? rs, let hip = lh ?? rh else { return nil }
        let torso = Geometry.distance(shoulder, hip)
        guard torso > 0.02 else { return nil }
        // Only one shoulder visible is itself a strong side-on signal.
        guard let l = ls, let r = rs else { return .side }
        let ratio = Geometry.distance(l, r) / torso
        if ratio < 0.3 { return .side }
        if ratio > 0.45 { return .front }
        return nil
    }
}
