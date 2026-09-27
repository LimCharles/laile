import Foundation
import LaileCore

/// Full-duplex cloud voice via Tencent TRTC Conversational AI (milestone M3).
///
/// The server starts an AI agent in a TRTC room (`POST /v1/voice/sessions`); the phone joins
/// the same room, publishes its microphone and plays the agent's speech. The agent does
/// streaming ASR + TTS with barge-in and calls our Vapor endpoint for each turn, which runs
/// the safety rules and pushes structured symptom reports back over the events WebSocket.
///
/// This file compiles only once the TRTC iOS SDK is added to the app
/// (`TXLiteAVSDK_TRTC`). Until then the app uses `SpeechListener` + `CueSpeaker`
/// with the same cloud coach via `POST /v1/voice/turn`.
#if canImport(TXLiteAVSDK_TRTC)
import TXLiteAVSDK_TRTC

@MainActor
public final class TRTCVoiceLink: NSObject, TRTCCloudDelegate {
    public var onCaption: ((String, String) -> Void)?
    public var onSymptom: ((SymptomReport) -> Void)?
    private let cloud = TRTCCloud.sharedInstance()
    private var events: URLSessionWebSocketTask?

    public func join(_ session: API.VoiceSessionResponse, eventsURL: URL) {
        cloud.delegate = self
        let params = TRTCParams()
        params.sdkAppId = UInt32(session.sdkAppId)
        params.userId = session.userId
        params.userSig = session.userSig
        params.strRoomId = session.roomId
        params.role = .anchor
        cloud.enterRoom(params, appScene: .audioCall)
        cloud.startLocalAudio(.speech)

        let socket = URLSession.shared.webSocketTask(with: eventsURL)
        events = socket
        socket.resume()
        receive()
    }

    public func send(context: API.VoiceContext) {
        guard let data = try? LaileJSON.encoder().encode(API.VoiceSocketMessage.context(context)) else { return }
        events?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    public func leave() {
        cloud.stopLocalAudio()
        cloud.exitRoom()
        events?.cancel(with: .normalClosure, reason: nil)
    }

    private func receive() {
        events?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .success(.string(let text)) = result,
                   let message = try? LaileJSON.decoder().decode(API.VoiceSocketMessage.self, from: Data(text.utf8)) {
                    switch message {
                    case .symptom(let report): self.onSymptom?(report)
                    case .caption(let speaker, let text): self.onCaption?(speaker, text)
                    case .context: break
                    }
                }
                if case .success = result { self.receive() }
            }
        }
    }
}
#endif
