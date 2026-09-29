import AppCore
import DesignSystem
import LaileCore
import SwiftUI

/// Lele's notes: what was sore, what Lele eased because of it, and how it's going. The same
/// record the clinician sees in the portal.
struct CareNotesCard: View {
    @Bindable var app: AppModel
    @State private var message: String?

    private var open: [CareNote] { app.careNotes.filter(\.isActive) }
    private var closed: [CareNote] { Array(app.careNotes.filter { !$0.isActive }.prefix(5)) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Lele's notes", systemImage: "heart.text.square").font(.laileHeadline).foregroundStyle(Theme.text)
                Text(app.mode == .rehab
                     ? "When something is sore, I note it and make that exercise easier next time. Your clinician sees these too."
                     : "When something is sore, I note it and make that exercise easier next time.")
                    .font(.footnote).foregroundStyle(Theme.muted)
                if app.careNotes.isEmpty {
                    Text("Nothing to note yet.").font(.subheadline).foregroundStyle(Theme.muted)
                }
                ForEach(open) { note in CareNoteRow(note: note, onBetter: { better(note) }) }
                if !closed.isEmpty {
                    Text("Resolved").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted).padding(.top, 4)
                    ForEach(closed) { note in CareNoteRow(note: note, onBetter: nil) }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.warn) }
            }
        }
    }

    private func better(_ note: CareNote) {
        Task { message = await app.markBetter(note) }
    }
}

struct CareNoteRow: View {
    let note: CareNote
    let onBetter: (() -> Void)?
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(note.isActive ? tint : Theme.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(note.isActive ? Theme.text : Theme.muted)
                    Text(note.plainSummary).font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
            if let status { Text(status).font(.footnote.weight(.medium)).foregroundStyle(tint) }
            if let quote = note.quote, note.isActive { Text("“\(quote)”").font(.footnote).italic().foregroundStyle(Theme.muted) }
            HStack {
                Button(showHistory ? "Hide history" : "History (\(note.events.count))") { withAnimation { showHistory.toggle() } }
                    .font(.footnote)
                Spacer()
                if let onBetter, note.kind != .clinicianNote, !(note.adjustment?.keptByClinician ?? false) {
                    Button("It feels better", action: onBetter).font(.footnote.weight(.semibold))
                }
            }
            if showHistory {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(note.events.reversed().enumerated()), id: \.offset) { _, event in
                        Text("\(event.date.formatted(date: .abbreviated, time: .shortened)) · \(event.text)")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(note.isActive ? tint.opacity(0.08) : Color.clear))
    }

    private var title: String {
        switch note.kind {
        case .clinicianNote: return "From \(note.author ?? "your clinician")"
        case .soreSpot, .feelsWrong: return note.exerciseName ?? note.kind.label
        }
    }

    private var status: String? {
        guard note.isActive else { return nil }
        guard let adjustment = note.adjustment, !adjustment.isNeutral,
              let spec = note.exerciseId.flatMap({ ExerciseLibrary.standard.spec($0) }) else { return nil }
        let eased = "Easier for now: \(adjustment.summary(for: spec))."
        if adjustment.keptByClinician { return eased + " Your clinician is keeping it this way." }
        let left = CareMemory.comfortableSessionsPerStep - note.comfortableSessions
        return eased + " \(left) comfortable session\(left == 1 ? "" : "s") until I ease it back a step."
    }

    private var icon: String {
        switch note.kind {
        case .soreSpot: return "bandage"
        case .feelsWrong: return "exclamationmark.triangle"
        case .clinicianNote: return "stethoscope"
        }
    }

    private var tint: Color {
        switch note.kind {
        case .soreSpot: return Theme.reward
        case .feelsWrong: return Theme.warn
        case .clinicianNote: return Theme.accent
        }
    }
}
