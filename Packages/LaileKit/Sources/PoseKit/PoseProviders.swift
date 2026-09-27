@preconcurrency import AVFoundation
import Foundation
import LaileCore
import Vision

/// Anything that produces pose frames: the real camera (Apple Vision), or a simulator.
@MainActor
public protocol PoseProvider: AnyObject {
    var onFrame: ((PoseFrame) -> Void)? { get set }
    /// Non-nil for the camera provider; used by the preview layer.
    var captureSession: AVCaptureSession? { get }
    var isFrontCamera: Bool { get }
    func start() async throws
    func stop()
    /// Tells simulated providers what to act out. Camera providers ignore it.
    func perform(_ exercise: PlannedExercise?)
}

/// Monotonic clock shared by frames, timers and the conductor.
public enum PoseClock {
    public static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public enum PoseProviderFactory {
    /// Camera on devices, simulator where there's no camera (Simulator, previews).
    @MainActor public static func make(preferFront: Bool) -> any PoseProvider {
        #if targetEnvironment(simulator)
        return SimulatedPoseProvider()
        #else
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: preferFront ? .front : .back) != nil {
            return CameraPoseProvider(position: preferFront ? .front : .back)
        }
        return SimulatedPoseProvider()
        #endif
    }
}

public enum PoseError: LocalizedError {
    case cameraDenied, noCamera

    public var errorDescription: String? {
        switch self {
        case .cameraDenied: return "Camera access is off. Turn it on in Settings → Laile so I can count your reps."
        case .noCamera: return "No camera is available on this device."
        }
    }
}

// MARK: - Camera + Apple Vision

/// Runs Vision's human body pose request on every camera frame. Video stays on the phone:
/// only joint positions leave this class.
@MainActor
public final class CameraPoseProvider: NSObject, PoseProvider {
    public var onFrame: ((PoseFrame) -> Void)?
    public let session = AVCaptureSession()
    public var captureSession: AVCaptureSession? { session }
    public let position: AVCaptureDevice.Position
    public var isFrontCamera: Bool { position == .front }
    private let analyzer: FrameAnalyzer
    private let queue = DispatchQueue(label: "app.laile.camera", qos: .userInteractive)
    private var configured = false

    public init(position: AVCaptureDevice.Position = .front) {
        self.position = position
        self.analyzer = FrameAnalyzer()
        super.init()
        analyzer.deliver = { [weak self] frame in
            Task { @MainActor in self?.onFrame?(frame) }
        }
    }

    public func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw PoseError.cameraDenied }
        default: throw PoseError.cameraDenied
        }
        if !configured { try configure() }
        let session = self.session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    public func stop() {
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    public func perform(_ exercise: PlannedExercise?) {}

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else { throw PoseError.noCamera }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(analyzer, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let connection = output.connection(with: .video) {
            // Portrait buffers; never mirrored, so Vision's left/right match the person's anatomy.
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        session.commitConfiguration()
        configured = true
    }
}

/// Sample-buffer delegate living on the camera queue.
final class FrameAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var deliver: ((PoseFrame) -> Void)?
    private let request = VNDetectHumanBodyPoseRequest()

    static let jointMap: [VNHumanBodyPoseObservation.JointName: LaileCore.Joint] = [
        .nose: .nose, .neck: .neck, .root: .root,
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow, .rightElbow: .rightElbow,
        .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
    ]

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = Double(CVPixelBufferGetWidth(pixelBuffer)), height = Double(CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        var landmarks: [LaileCore.Joint: Landmark] = [:]
        if (try? handler.perform([request])) != nil,
           let observation = request.results?.max(by: { $0.confidence < $1.confidence }),
           let points = try? observation.recognizedPoints(.all) {
            for (name, point) in points {
                guard let joint = Self.jointMap[name], point.confidence > 0 else { continue }
                // Vision: origin bottom-left. LaileCore: origin top-left.
                landmarks[joint] = Landmark(Point2(point.location.x, 1 - point.location.y), confidence: Double(point.confidence))
            }
        }
        deliver?(PoseFrame(timestamp: PoseClock.now, landmarks: landmarks, imageAspect: height > 0 ? width / height : 9.0 / 16.0))
    }
}

// MARK: - Simulator

/// Acts out the current exercise with a synthetic skeleton, so the whole pipeline — setup
/// checks, rep counting, hold timers, cues — runs in the iOS Simulator and in demos.
@MainActor
public final class SimulatedPoseProvider: PoseProvider {
    public var onFrame: ((PoseFrame) -> Void)?
    public var captureSession: AVCaptureSession? { nil }
    public var isFrontCamera: Bool { false }
    private var timer: Timer?
    private var exercise: PlannedExercise?
    private var startedAt: TimeInterval = PoseClock.now
    private let aspect = 9.0 / 16.0

    public init() {}

    public func start() async throws {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func perform(_ exercise: PlannedExercise?) {
        if exercise?.spec.id != self.exercise?.spec.id { startedAt = PoseClock.now }
        self.exercise = exercise
    }

    private func emit() {
        let t = PoseClock.now
        let elapsed = t - startedAt
        var body = SyntheticBody(posture: exercise?.spec.posture ?? .standing, frontView: exercise?.spec.cameraView == .front)
        if let exercise, let definition = exercise.spec.kind.trackedAngle {
            body.set(definition, to: targetAngle(for: exercise, elapsed: elapsed))
        }
        onFrame?(PoseFrame(timestamp: t, landmarks: body.landmarks(aspect: aspect), imageAspect: aspect))
    }

    /// Smooth reps with a pause at the top; holds sit comfortably inside their condition.
    private func targetAngle(for exercise: PlannedExercise, elapsed: TimeInterval) -> Double {
        switch exercise.spec.kind {
        case .reps:
            guard let rule = exercise.repRule else { return 170 }
            let period = 2.8, restAtStart = 0.8
            let phase = elapsed.truncatingRemainder(dividingBy: period + restAtStart)
            let span = rule.target - rule.start
            let restAngle = rule.start - span * 0.15
            guard phase > restAtStart, elapsed > 6 else { return restAngle }
            let x = (phase - restAtStart) / period
            let depth = (1 - cos(x * 2 * .pi)) / 2
            return restAngle + (span * 1.2) * depth
        case .hold(let rule):
            switch rule.condition {
            case .atLeast(let v)?: return min(179, v + 8)
            case .atMost(let v)?: return v - 10
            case .between(let lo, let hi)?: return (lo + hi) / 2
            case nil: return 170
            }
        }
    }
}

/// A 2D stick figure built from joint angles (forward kinematics), then fitted to the frame.
struct SyntheticBody {
    var posture: Posture
    var frontView: Bool
    var torsoDirection: Double
    var hipAngle: Double
    var kneeAngle: Double
    var shoulderAngle: Double
    var elbowAngle: Double

    init(posture: Posture, frontView: Bool) {
        self.posture = posture
        self.frontView = frontView
        switch posture {
        case .standing: (torsoDirection, hipAngle, kneeAngle, shoulderAngle, elbowAngle) = (-90, 176, 176, 12, 165)
        case .seated: (torsoDirection, hipAngle, kneeAngle, shoulderAngle, elbowAngle) = (-90, 95, 100, 15, 150)
        case .supine: (torsoDirection, hipAngle, kneeAngle, shoulderAngle, elbowAngle) = (180, 176, 176, 15, 170)
        case .plank: (torsoDirection, hipAngle, kneeAngle, shoulderAngle, elbowAngle) = (190, 176, 178, 80, 165)
        case .kneeling: (torsoDirection, hipAngle, kneeAngle, shoulderAngle, elbowAngle) = (-90, 150, 90, 12, 165)
        }
    }

    mutating func set(_ definition: AngleDefinition, to value: Double) {
        switch (definition.from, definition.vertex, definition.to) {
        case (.hip, .knee, .ankle):
            kneeAngle = value
            // Bend the hip with the knee so the figure squats / slides its heel realistically.
            switch posture {
            case .standing: hipAngle = min(176, value + 12)
            case .supine: hipAngle = 180 - (180 - value) * 0.55
            default: break
            }
        case (.shoulder, .hip, .knee): hipAngle = value
        case (.shoulder, .elbow, .wrist): elbowAngle = value
        case (.shoulder, .hip, .ankle): hipAngle = value; kneeAngle = 178
        case (.hip, .shoulder, .wrist): shoulderAngle = value; elbowAngle = 175
        default: break
        }
    }

    func landmarks(aspect: Double) -> [LaileCore.Joint: Landmark] {
        func dir(_ degrees: Double) -> (Double, Double) { (cos(degrees * .pi / 180), sin(degrees * .pi / 180)) }
        func move(_ p: Point2, _ length: Double, _ degrees: Double) -> Point2 {
            let d = dir(degrees)
            return Point2(p.x + d.0 * length, p.y + d.1 * length)
        }
        var pts: [BodyPart: Point2] = [:]
        let hip = Point2(0, 0)
        pts[.hip] = hip
        pts[.shoulder] = move(hip, 0.26, torsoDirection)
        let thigh = torsoDirection + hipAngle
        pts[.knee] = move(hip, 0.22, thigh)
        pts[.ankle] = move(pts[.knee]!, 0.22, thigh + 180 - kneeAngle)
        let upperArm = torsoDirection + 180 - shoulderAngle
        pts[.elbow] = move(pts[.shoulder]!, 0.15, upperArm)
        pts[.wrist] = move(pts[.elbow]!, 0.14, upperArm + 180 - elbowAngle)

        // Fit into the frame (uniform scale keeps every angle intact).
        let xs = pts.values.map(\.x), ys = pts.values.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let width = max(maxX - minX, 0.01), height = max(maxY - minY, 0.01)
        // Keep the figure in the upper-middle of the frame, clear of the on-screen HUD.
        let scale = min(0.42 / height, (0.7 * aspect) / width)
        func fit(_ p: Point2) -> Point2 {
            let x = (p.x - (minX + maxX) / 2) * scale + aspect / 2
            let y = (p.y - (minY + maxY) / 2) * scale + 0.38
            return Point2(x / aspect, y)
        }

        var result: [LaileCore.Joint: Landmark] = [:]
        for (part, point) in pts {
            let near = fit(point)
            if frontView {
                // Mirror the chain for the other side, spread apart like a front-facing body.
                let spread = 0.07 / aspect
                result[LaileCore.Joint(part, .left)] = Landmark(Point2(near.x + spread, near.y), confidence: 0.9)
                let mirrored = Point2(1 - near.x - spread, near.y)
                result[LaileCore.Joint(part, .right)] = Landmark(mirrored, confidence: 0.9)
            } else {
                result[LaileCore.Joint(part, .left)] = Landmark(near, confidence: 0.92)
                result[LaileCore.Joint(part, .right)] = Landmark(Point2(near.x + 0.012, near.y + 0.004), confidence: 0.45)
            }
        }
        if let s = result[.leftShoulder] { result[.nose] = Landmark(Point2(s.position.x, s.position.y - 0.06), confidence: 0.8) }
        return result
    }
}
