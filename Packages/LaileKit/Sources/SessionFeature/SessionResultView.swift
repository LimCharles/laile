import AppCore
import DesignSystem
import LaileCore
import SwiftUI

/// After a session: what was verified, what you earned, and — if something was wrong — what to do.
struct SessionResultView: View {
    let model: SessionViewModel
    let onDone: () -> Void
    @State private var celebrate = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let escalation = model.escalation {
                    EscalationCard(level: escalation, number: model.emergencyNumber, mode: model.launch.mode)
                }
                header
                if let summary = model.summary { stats(summary) }
                if let result = model.result { rewards(result) }
                if let summary = model.summary, !summary.symptoms.filter({ $0.category.needsClinicianReview }).isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Noted for your records", systemImage: "note.text").font(.laileHeadline)
                            ForEach(summary.symptoms.filter { $0.category.needsClinicianReview }) { report in
                                Text(report.clinicalSummary).font(.subheadline)
                            }
                            if model.launch.mode == .rehab {
                                Text("Your clinician will see these with the exact exercise and moment they happened.")
                                    .font(.footnote).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                if let notes = model.result?.careNotes, !notes.isEmpty { LeleRemembers(notes: notes) }
                Button("Done", action: onDone).buttonStyle(PrimaryButtonStyle())
            }
            .padding(20)
        }
        .screenBackground()
        .overlay { if celebrate { Confetti() } }
        .onAppear { celebrate = model.escalation == nil && model.result != nil }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: model.escalation == nil ? "checkmark.seal.fill" : "hand.raised.fill")
                .font(.system(size: 54))
                .foregroundStyle(model.escalation == nil ? Theme.accent : Theme.danger)
            Text(model.escalation == nil ? "Session complete" : "Session stopped").font(.laileTitle)
            Text(model.launch.title).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func stats(_ summary: SessionSummary) -> some View {
        HStack(spacing: 12) {
            stat("\(summary.verifiedReps)", "verified reps", "checkmark.circle")
            stat("\(summary.holdSeconds)s", "held", "timer")
            stat(summary.durationSeconds >= 60 ? "\(summary.durationSeconds / 60)m" : "\(summary.durationSeconds)s", "total", "clock")
        }
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                Text(value).font(.title2.weight(.heavy)).foregroundStyle(Theme.text)
                Text(label).font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private func rewards(_ result: API.SessionSubmitResponse) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("+\(result.movement.xpAwarded) XP", systemImage: "sparkles").font(.title3.weight(.heavy)).foregroundStyle(Theme.reward)
                    Spacer()
                    Label("\(result.movement.moveStreak.current)-day streak", systemImage: "flame.fill").font(.headline).foregroundStyle(Theme.flame)
                }
                ForEach(Array(result.achievements.enumerated()), id: \.offset) { _, achievement in
                    Label(achievement.title, systemImage: "trophy.fill").foregroundStyle(Theme.text)
                }
                ForEach(result.movement.newBadges) { badge in
                    Label("Badge unlocked: \(badge.title)", systemImage: badge.symbol).foregroundStyle(Theme.accent)
                }
                if let milestone = result.movement.streakMilestone {
                    Label("\(milestone)-day streak bonus!", systemImage: "flame.circle.fill").foregroundStyle(Theme.flame)
                }
            }
        }
    }
}

struct EscalationCard: View {
    let level: EscalationLevel
    let number: String
    let mode: AppMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(level == .emergency ? "This could be serious" : "Please get this checked today", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.bold))
            Text(level == .emergency
                 ? "Stop exercising. Call \(number) for an ambulance now, or ask someone nearby to call for you."
                 : (mode == .rehab ? "Stop exercising for today and contact your care team. What you told me has been saved for them."
                                   : "Stop exercising for today and see a doctor."))
            if level == .emergency, let url = URL(string: "tel://\(number)") {
                Link(destination: url) {
                    Label("Call \(number)", systemImage: "phone.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(color: Theme.danger))
            }
        }
        .foregroundStyle(Theme.danger)
        .padding(16)
        .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: Theme.corner))
    }
}

/// What Lele will do differently next time because of this session.
struct LeleRemembers: View {
    let notes: [CareNote]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Lele will remember", systemImage: "heart.text.square").font(.laileHeadline)
                ForEach(notes) { note in
                    Text(line(for: note)).font(.subheadline)
                }
                Text("See Lele's notes in the Progress tab.").font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }

    private func line(for note: CareNote) -> String {
        let name = note.exerciseName ?? "This exercise"
        guard note.isActive else { return "\(name) felt comfortable again, so it's back to normal." }
        if let adjustment = note.adjustment, !adjustment.isNeutral, let spec = note.exerciseId.flatMap({ ExerciseLibrary.standard.spec($0) }) {
            return "\(name) will be a little easier next time: \(adjustment.summary(for: spec))."
        }
        return "\(name): \(note.plainSummary)."
    }
}
