import AppCore
import DesignSystem
import LaileCore
import SwiftUI
import VoiceKit

/// A voice check-in with Lele: you talk, Lele answers out loud in your chosen voice, and it takes
/// turns like a call: the mic is off while Lele speaks and back on as soon as it finishes.
public struct LeleCallView: View {
    enum Turn { case greeting, listening, thinking, speaking }

    @Bindable var app: AppModel
    let onEnd: () -> Void
    @State private var turn: Turn = .greeting
    @State private var heard = ""
    @State private var transcript: [(mine: Bool, text: String)] = []
    @State private var speaker = CueSpeaker()
    @State private var listener = SpeechListener()
    @State private var micDenied = false

    public init(app: AppModel, onEnd: @escaping () -> Void) {
        self.app = app
        self.onEnd = onEnd
    }

    public var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 10)
            LeleAvatar(size: 96)
                .scaleEffect(turn == .speaking ? 1.06 : 1)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: turn == .speaking)
            Text("Lele").font(.laileTitle)
            Text(status).font(.subheadline).foregroundStyle(Theme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(transcript.enumerated()), id: \.offset) { _, line in
                        Text(line.text)
                            .font(.subheadline)
                            .foregroundStyle(line.mine ? .white : Theme.text)
                            .padding(10)
                            .background(line.mine ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                            .frame(maxWidth: .infinity, alignment: line.mine ? .trailing : .leading)
                    }
                    if !heard.isEmpty && turn == .listening {
                        Text(heard).font(.subheadline).italic().foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            if micDenied {
                Text("Microphone or speech access is off. You can still chat by text in the Lele tab.").font(.footnote).foregroundStyle(Theme.warn)
            }
            Button(role: .destructive) { end() } label: {
                Label("End", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(color: Theme.danger))
        }
        .padding(24)
        .screenBackground()
        .task { await start() }
        .onDisappear { listener.stop(); speaker.stop() }
    }

    private var status: String {
        switch turn {
        case .greeting: return "Connecting…"
        case .listening: return "Listening. Go ahead."
        case .thinking: return "Thinking…"
        case .speaking: return "Lele is speaking"
        }
    }

    private func start() async {
        VoiceAudioSession.activate()
        let backend = app.backend
        speaker.voice = app.settings.voice
        speaker.remoteVoice = { text, voice in await backend.speech(text, voice: voice) }
        speaker.onSpeakingChanged = { speaking, _ in
            listener.setMuted(speaking)
            if !speaking, turn == .speaking { turn = .listening }
        }
        let name = app.callName ?? "there"
        say("Hi \(name), it's Lele. How are you feeling today?")
        guard await SpeechListener.requestPermissions() else { micDenied = true; return }
        listener.onPartial = { heard = $0 }
        listener.onUtterance = { text in Task { await handle(text) } }
        try? listener.start()
    }

    private func say(_ text: String) {
        transcript.append((false, text))
        turn = .speaking
        speaker.say(CueLine(text))
    }

    private func handle(_ text: String) async {
        guard turn == .listening || turn == .greeting else { return }
        heard = ""
        transcript.append((true, text))
        turn = .thinking
        let before = app.leleMessages.count
        await app.chat(text)
        let reply = app.leleMessages.dropFirst(before).last { $0.author == .lele }?.text
            ?? "Sorry, I didn't catch that. Could you say it again?"
        say(reply)
    }

    private func end() {
        listener.stop()
        speaker.stop()
        VoiceAudioSession.deactivate()
        onEnd()
    }
}
