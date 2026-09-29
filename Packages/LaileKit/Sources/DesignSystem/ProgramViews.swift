import LaileCore
import SwiftUI

public extension Enrollment {
    /// Who the program is from, in a few words.
    var sourceLabel: String {
        switch kind {
        case .clinical: return supervisorName.map { "With \($0)" } ?? "From your clinician"
        case .personal: return "Lele's plan for you"
        case .catalog: return SessionTemplate.builtIn(catalogId ?? "")?.category.label ?? "Laile program"
        }
    }

    var sourceSymbol: String {
        switch kind {
        case .clinical: return "stethoscope"
        case .personal: return "sparkles"
        case .catalog: return "figure.strengthtraining.traditional"
        }
    }
}

/// One of the person's programs, with what today's session holds and a button to start it.
public struct EnrollmentCard: View {
    let enrollment: Enrollment
    let precautions: Precautions
    let careNotes: [CareNote]
    let onStart: () -> Void

    public init(enrollment: Enrollment, precautions: Precautions, careNotes: [CareNote] = [], onStart: @escaping () -> Void) {
        self.enrollment = enrollment
        self.precautions = precautions
        self.careNotes = careNotes
        self.onStart = onStart
    }

    private var plan: (plan: [PlannedExercise], removed: [ProgramViolation]) {
        enrollment.needsCalibration
            ? (enrollment.calibrationPlan(precautions: precautions), [])
            : enrollment.sessionPlan(precautions: precautions)
    }

    public var body: some View {
        let plan = self.plan
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(enrollment.sourceLabel, systemImage: enrollment.sourceSymbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(enrollment.isSupervised ? Theme.reward : Theme.accent)
                    Spacer()
                    if enrollment.needsCalibration {
                        Pill("Check-in first", color: Theme.reward, background: Theme.rewardSoft)
                    } else if enrollment.isSupervised {
                        Pill("v\(enrollment.program.version) · signed", color: Theme.accent, background: Theme.accentSoft)
                    } else {
                        Pill("Targets set", color: Theme.accent, background: Theme.accentSoft)
                    }
                }
                Text(enrollment.title).font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                if enrollment.needsCalibration {
                    Text("Your first session is a check-in: each move once, as far as feels comfortable. Lele sets your targets from it.")
                        .font(.caption).foregroundStyle(Theme.muted)
                } else if !enrollment.subtitle.isEmpty {
                    Text(enrollment.subtitle).font(.caption).foregroundStyle(Theme.muted)
                }
                ForEach(plan.plan, id: \.spec.id) { planned in
                    HStack {
                        Image(systemName: planned.spec.symbol).frame(width: 24).foregroundStyle(planned.spec.category.color)
                        Text(planned.spec.name).foregroundStyle(Theme.text)
                        if careNotes.contains(where: { $0.isEasing && ($0.exerciseId == planned.spec.id || $0.exerciseId == nil) }) {
                            Pill("easier today", color: Theme.reward, background: Theme.rewardSoft)
                                .accessibilityLabel("Lele made this easier today because of what you told it")
                        }
                        Spacer()
                        Text(enrollment.needsCalibration ? "as you can" : planned.dose.shortDescription)
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    }
                }
                if !plan.removed.isEmpty {
                    Label("Left out to protect you: " + plan.removed.compactMap { ExerciseLibrary.standard.spec($0.exerciseId)?.name }.joined(separator: ", "),
                          systemImage: "shield.lefthalf.filled")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                Button(action: onStart) {
                    Label(enrollment.needsCalibration ? "Start check-in" : "Start today's session", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

/// A catalog program in the Explore list.
public struct CatalogRow: View {
    let template: SessionTemplate
    let joined: Bool

    public init(template: SessionTemplate, joined: Bool) {
        self.template = template
        self.joined = joined
    }

    public var body: some View {
        HStack(spacing: 14) {
            Image(systemName: template.items.first.flatMap { ExerciseLibrary.standard.spec($0.exerciseId)?.symbol } ?? "figure.walk")
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 48, height: 48)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(template.title).font(.headline).foregroundStyle(Theme.text)
                Text(template.subtitle).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                HStack(spacing: 8) {
                    Text("\(template.minutes) min").font(.caption2.weight(.bold)).foregroundStyle(Theme.muted)
                    IntensityDots(template.level)
                }
            }
            Spacer()
            if joined {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).accessibilityLabel("Joined")
            } else {
                Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.surface2, lineWidth: 1))
    }
}
