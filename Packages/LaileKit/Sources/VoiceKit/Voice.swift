@preconcurrency import AVFoundation
import Foundation
import LaileCore
import Speech

public enum VoiceAudioSession {
    /// Play + record with the speaker as the default route (the phone is propped up across the room).
    public static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
        try? session.setActive(true, options: [])
    }

    public static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// Speaks coaching cues, best voice first:
/// 1. The chosen coach voice's audio from `VoiceStore` — bundled or already fetched — instant.
/// 2. `remoteVoice` — the server renders the line in that voice (ElevenLabs), then it's cached.
/// 3. The best on-device voice installed (premium/enhanced if available).
///
/// Counting cues (low priority) are never queued: a count that would play late is dropped,
/// because a late "seven" is worse than none. Safety lines (high priority) interrupt.
@MainActor
public final class CueSpeaker: NSObject {
    public var isEnabled = true
    public var onSpeakingChanged: ((Bool, CueLine.Priority) -> Void)?
    /// Called when a line's audio actually starts, so captions show what is being heard
    /// (not what was queued, fetched late, or dropped).
    public var onLineStarted: ((CueLine) -> Void)?
    /// The coach voice the user picked.
    public var voice: CoachVoice = .default
    /// Fetches MP3 audio for text in a voice (the server's `/v1/voice/speak`).
    public var remoteVoice: (@Sendable (String, CoachVoice) async -> Data?)?
    public private(set) var isSpeaking = false
    public private(set) var lastLine: CueLine?

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var queue: [(line: CueLine, at: Date)] = []
    /// A queued line older than this is stale (the moment has passed), so it's skipped.
    private let maxQueueAge: TimeInterval = 6
    private var current: CueLine?
    private let store: VoiceStore
    private let deviceVoice: AVSpeechSynthesisVoice?

    public init(store: VoiceStore = .shared) {
        self.store = store
        self.deviceVoice = Self.bestOnDeviceVoice()
        super.init()
        synthesizer.delegate = self
    }

    /// Highest-quality English voice installed (users can download "Premium" voices in
    /// Settings → Accessibility → Spoken Content → Voices).
    static func bestOnDeviceVoice() -> AVSpeechSynthesisVoice? {
        let preferred = ["en-GB", "en-AU", "en-US", "en-IE", "en-IN"]
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return english.max { a, b in
            if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
            let ra = preferred.firstIndex(of: a.language) ?? preferred.count
            let rb = preferred.firstIndex(of: b.language) ?? preferred.count
            return ra > rb
        } ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    /// Fetch the lines a session or stream will use, while the user gets ready.
    public func prefetch(_ lines: [CueLine]) async {
        guard let remoteVoice else { return }
        await store.prefetch(lines, voice: voice, fetch: remoteVoice)
    }

    public func say(_ line: CueLine) {
        lastLine = line
        guard isEnabled else { return }
        if line.priority == .high {
            queue.removeAll()
            stopPlayback()
        } else if isSpeaking {
            guard line.priority > .low else { return }
            queue.removeAll { $0.line.priority == .low }
            if queue.count < 3 { queue.append((line, Date())) }
            return
        }
        play(line)
    }

    public func stop() {
        queue.removeAll()
        stopPlayback()
        current = nil // a line still being fetched must not start playing later
    }

    private func play(_ line: CueLine) {
        current = line
        setSpeaking(true, line.priority)
        let voice = self.voice
        if let url = store.url(for: line, voice: voice), let player = try? AVAudioPlayer(contentsOf: url) {
            playAudio(player, line)
            return
        }
        // Counts must never lag: speak them on-device now and fetch the real voice for next time.
        if let remoteVoice, line.priority > .low {
            Task { @MainActor in
                let data = await remoteVoice(line.text, voice)
                if let data { self.store.store(data, for: line, voice: voice) }
                guard self.current == line else { return }
                if let data, let player = try? AVAudioPlayer(data: data) {
                    self.playAudio(player, line)
                } else {
                    self.speakOnDevice(line)
                }
            }
            return
        }
        if let remoteVoice {
            let store = self.store
            Task { if let data = await remoteVoice(line.text, voice) { store.store(data, for: line, voice: voice) } }
        }
        speakOnDevice(line)
    }

    private func playAudio(_ player: AVAudioPlayer, _ line: CueLine) {
        self.player = player
        player.delegate = self
        player.play()
        onLineStarted?(line)
    }

    private func speakOnDevice(_ line: CueLine) {
        onLineStarted?(line)
        let utterance = AVSpeechUtterance(string: line.text)
        utterance.voice = deviceVoice
        utterance.rate = line.priority == .low ? 0.55 : 0.5
        utterance.preUtteranceDelay = 0
        synthesizer.speak(utterance)
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if isSpeaking { setSpeaking(false, current?.priority ?? .normal) }
    }

    fileprivate func finished() {
        player = nil
        let priority = current?.priority ?? .normal
        current = nil
        queue.removeAll { Date().timeIntervalSince($0.at) > maxQueueAge && $0.line.priority < .high }
        if let next = queue.first {
            queue.removeFirst()
            play(next.line)
        } else {
            setSpeaking(false, priority)
        }
    }

    private func setSpeaking(_ speaking: Bool, _ priority: CueLine.Priority) {
        guard isSpeaking != speaking else { return }
        isSpeaking = speaking
        onSpeakingChanged?(speaking, priority)
    }
}

extension CueSpeaker: AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished() }
    }
}

/// Continuous on-device speech recognition that turns speech into utterances
/// ("sharp pain on the inside of my knee") by waiting for a short pause.
@MainActor
public final class SpeechListener {
    public var onUtterance: ((String) -> Void)?
    public var onPartial: ((String) -> Void)?
    public private(set) var isListening = false
    public private(set) var isMuted = false

    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private let sink = BufferSink()
    private var task: SFSpeechRecognitionTask?
    private var latestText = ""
    private var silenceWork: DispatchWorkItem?
    private var generation = 0

    /// Pause length that ends an utterance.
    public var utteranceGap: TimeInterval = 1.0

    public init(locale: Locale = Locale(identifier: "en-US")) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    public static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    public func start() throws {
        guard !isListening, let recognizer, recognizer.isAvailable else { return }
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true) // echo cancellation for our own cues
        let format = input.outputFormat(forBus: 0)
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        engine.prepare()
        try engine.start()
        isListening = true
        beginTask()
    }

    public func stop() {
        guard isListening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        endTask()
        isListening = false
    }

    /// Mute while the coach is saying something longer than a count, so it can't hear itself.
    public func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        if muted {
            endTask()
        } else if isListening {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isMuted, self.isListening, self.task == nil else { return }
                    self.beginTask()
                }
            }
        }
    }

    private func beginTask() {
        guard let recognizer, !isMuted else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.contextualStrings = ["sharp", "pulling", "stretch", "clicked", "calf", "knee", "pain", "hurts", "tingling"]
        sink.request = request
        latestText = ""
        generation += 1
        let myGeneration = generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in self?.handle(text: text, isFinal: isFinal, failed: failed, generation: myGeneration) }
        }
    }

    private func endTask() {
        silenceWork?.cancel()
        sink.request?.endAudio()
        sink.request = nil
        task?.cancel()
        task = nil
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool, generation: Int) {
        guard generation == self.generation, !isMuted else { return }
        if let text, !text.isEmpty, text != latestText {
            latestText = text
            onPartial?(text)
            silenceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finalize() } }
            silenceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + utteranceGap, execute: work)
        }
        if isFinal { finalize() } else if failed { restart() }
    }

    private func finalize() {
        let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        latestText = ""
        if !text.isEmpty && !isMuted { onUtterance?(text) }
        restart()
    }

    private func restart() {
        endTask()
        if isListening && !isMuted { beginTask() }
    }
}

/// Hands microphone buffers from the audio thread to the current recognition request.
final class BufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }
}
