import AVFoundation
import Foundation
import Speech

/// Asks for everything a session needs up front, so no system prompt interrupts a workout.
public enum Permissions {
    public struct Status: Equatable {
        public var camera: Bool
        public var microphone: Bool
        public var speech: Bool
        public var all: Bool { camera && microphone && speech }
    }

    public static var current: Status {
        Status(camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
               microphone: AVAudioApplication.shared.recordPermission == .granted,
               speech: SFSpeechRecognizer.authorizationStatus() == .authorized)
    }

    @discardableResult
    public static func requestAll() async -> Status {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVAudioApplication.requestRecordPermission()
        _ = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        return current
    }
}
