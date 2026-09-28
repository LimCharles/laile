import AppCore
import AVFoundation
import DesignSystem
import LaileCore
import SwiftUI
import VoiceKit

/// Pick the coach's voice, with a spoken preview of each.
struct VoicePickerSection: View {
    @Bindable var app: AppModel
    @State private var previewing: CoachVoice?
    @State private var player: AVAudioPlayer?
    @State private var previewError: String?

    var body: some View {
        Section {
            ForEach(CoachVoice.allCases) { voice in
                HStack(spacing: 12) {
                    Button {
                        app.settings.voice = voice
                        app.warmUpVoice()
                        Task { await preview(voice) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.displayName).foregroundStyle(Theme.text)
                                Text(voice.blurb).font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if app.settings.voice == voice {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { Task { await preview(voice) } } label: {
                        if previewing == voice {
                            ProgressView()
                        } else {
                            Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play a sample of \(voice.displayName)")
                }
            }
            if let previewError { Text(previewError).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("Coach voice")
        } footer: {
            Text("Voices are downloaded the first time you use them, then work offline.")
        }
    }

    private func preview(_ voice: CoachVoice) async {
        let line = CoachVoice.sampleLine
        previewing = voice
        defer { previewing = nil }
        let store = VoiceStore.shared
        var url = store.url(for: line, voice: voice)
        if url == nil, let data = await app.backend.speech(line.text, voice: voice) {
            store.store(data, for: line, voice: voice)
            url = store.url(for: line, voice: voice)
        }
        guard let url else {
            previewError = "Couldn't load that voice. Check your connection."
            return
        }
        previewError = nil
        VoiceAudioSession.activate()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}
