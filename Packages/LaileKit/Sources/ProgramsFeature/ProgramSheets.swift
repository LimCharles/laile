import AppCore
import DesignSystem
import LaileCore
import SwiftUI

/// A catalog program before joining: what's in it, anything your limits leave out, and Join.
struct CatalogDetailSheet: View {
    @Bindable var app: AppModel
    let template: SessionTemplate
    let onClose: () -> Void
    @State private var working = false
    @State private var error: String?

    private var enrollment: Enrollment? {
        app.activeEnrollments.first { $0.catalogId == template.id }
    }

    var body: some View {
        let check = ContraindicationChecker.filter(template.plan(), precautions: app.precautions)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Pill(template.category.label, color: Theme.accent, background: Theme.accentSoft)
                        Pill("\(template.minutes) min")
                        IntensityDots(template.level)
                    }
                    Text(template.title).font(.laileTitle).foregroundStyle(Theme.text)
                    Text(template.about.isEmpty ? template.subtitle : template.about).foregroundStyle(Theme.muted)
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(check.kept, id: \.spec.id) { planned in
                                HStack {
                                    Image(systemName: planned.spec.symbol).frame(width: 24).foregroundStyle(planned.spec.category.color)
                                    Text(planned.spec.name).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(planned.dose.shortDescription).font(.subheadline).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                    }
                    if !check.removed.isEmpty {
                        Label("Left out to protect you: " + check.removed.map(\.message).joined(separator: " "), systemImage: "shield.lefthalf.filled")
                            .font(.footnote).foregroundStyle(Theme.warn)
                    }
                    Label("Your first session is a check-in. Lele watches how far you comfortably go and sets your reps, holds and range from it.",
                          systemImage: "ruler")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                    if let enrollment {
                        Button {
                            onClose()
                            app.afterSheetCloses { app.start(enrollment) }
                        } label: {
                            Label(enrollment.needsCalibration ? "Start check-in" : "Start today's session", systemImage: "play.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    } else if let supervisor = app.supervisorName {
                        physioGate(supervisor)
                    } else {
                        Button {
                            Task {
                                working = true
                                defer { working = false }
                                if await app.join(catalogId: template.id) == nil { error = app.lastError ?? "Couldn't join just now." }
                            }
                        } label: {
                            Label(working ? "Joining…" : "Join program", systemImage: "plus")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(working || check.kept.isEmpty)
                    }
                }
                .padding(20)
            }
            .screenBackground()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
        }
        .presentationDetents([.large])
    }

    /// While a physio supervises, they approve anything added. Lele asks for you.
    @ViewBuilder private func physioGate(_ supervisor: String) -> some View {
        let request = app.request(for: template.id)
        switch request?.status {
        case .pending?:
            Label("Asked \(supervisor) \(request!.createdAt.formatted(.relative(presentation: .named))). Lele will tell you their answer.",
                  systemImage: "hourglass")
                .font(.footnote).foregroundStyle(Theme.text)
        default:
            if request?.status == .declined {
                Label("\(supervisor) said not yet\(request?.note.map { ": \u{201C}\($0)\u{201D}" } ?? ".")", systemImage: "hand.raised")
                    .font(.footnote).foregroundStyle(Theme.warn)
            }
            Label("You're in \(supervisor)'s program. Lele will send them your request and tell you their answer.", systemImage: "stethoscope")
                .font(.footnote).foregroundStyle(Theme.text)
            Button {
                Task {
                    working = true
                    defer { working = false }
                    error = await app.requestProgram(template)
                }
            } label: { Label(working ? "Asking…" : "Ask \(supervisor)", systemImage: "paperplane") }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(working)
        }
    }
}

/// One of your programs: today's session, the targets your check-in set, and who can end it.
struct EnrollmentDetailSheet: View {
    @Bindable var app: AppModel
    let enrollment: Enrollment
    let onClose: () -> Void
    @State private var confirmLeave = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if enrollment.isActive {
                        EnrollmentCard(enrollment: enrollment, precautions: app.precautions, careNotes: app.today?.careNotes ?? []) {
                            onClose()
                            app.afterSheetCloses { app.start(enrollment) }
                        }
                        if let calibration = enrollment.calibration { targets(calibration) }
                        ownership
                    } else {
                        finished
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle(enrollment.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
            .confirmationDialog("Leave \(enrollment.title)?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave program", role: .destructive) {
                    Task {
                        if let message = await app.leave(enrollment) { error = message } else { onClose() }
                    }
                }
            } message: {
                Text("Your history stays in Progress. You can join again any time.")
            }
        }
    }

    private func targets(_ calibration: Calibration) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("What your check-in measured", systemImage: "ruler").font(.laileHeadline).foregroundStyle(Theme.text)
                Text(calibration.measuredAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Theme.muted)
                ForEach(calibration.exercises, id: \.exerciseId) { measured in
                    if let spec = ExerciseLibrary.standard.spec(measured.exerciseId) {
                        HStack {
                            Text(spec.name).foregroundStyle(Theme.text)
                            if measured.stoppedForSymptom { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn) }
                            Spacer()
                            Text(describe(measured)).font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }
                }
                Button {
                    onClose()
                    app.afterSheetCloses { app.start(enrollment, recheck: true) }
                } label: { Label("Re-check my targets", systemImage: "camera.viewfinder") }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func describe(_ m: ExerciseCalibration) -> String {
        var parts: [String] = []
        if let reps = m.maxReps { parts.append(reps == 1 ? "1 rep" : "\(reps) reps") }
        if let hold = m.bestHoldSeconds { parts.append("\(Int(hold))s hold") }
        if let angle = m.angleDescription { parts.append(angle) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var ownership: some View {
        if enrollment.isSupervised {
            Label("\(enrollment.supervisorName ?? "Your physio") ends this program when you're ready, and Lele will suggest what to do next.",
                  systemImage: "lock.fill")
                .font(.footnote).foregroundStyle(Theme.muted)
        } else {
            Button("Leave program", role: .destructive) { confirmLeave = true }
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var finished: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Finished", systemImage: "checkmark.seal.fill").font(.laileHeadline).foregroundStyle(Theme.accent)
                if let date = enrollment.completedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Theme.muted)
                }
                if let note = enrollment.completionNote, !note.isEmpty {
                    Text("\u{201C}\(note)\u{201D}").italic().foregroundStyle(Theme.text)
                    if let name = enrollment.supervisorName { Text(name).font(.caption).foregroundStyle(Theme.muted) }
                }
            }
        }
        if let next = enrollment.followOnCatalogId.flatMap({ SessionTemplate.builtIn($0) }),
           !app.activeEnrollments.contains(where: { $0.catalogId == next.id }) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Keep going with").font(.laileHeadline).foregroundStyle(Theme.text)
                CatalogRow(template: next, joined: false)
                Button {
                    Task { if await app.join(catalogId: next.id) != nil { onClose() } }
                } label: { Label("Join \(next.title)", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

/// Joining a physio's program with the code they gave you.
struct JoinWithCodeSheet: View {
    @Bindable var app: AppModel
    let onClose: () -> Void
    @State private var code = ""
    @State private var working = false
    @State private var error: String?
    @State private var joined: Enrollment?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let joined {
                    Label("You're in", systemImage: "checkmark.seal.fill").font(.laileTitle).foregroundStyle(Theme.accent)
                    Text("\(joined.title), \(joined.sourceLabel.lowercased()). Your first session is a check-in so Lele can set targets that fit you, and \(joined.supervisorName ?? "your clinician") can see how it went.")
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Button {
                        onClose()
                        app.afterSheetCloses { app.start(joined) }
                    } label: { Label("Start check-in", systemImage: "play.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Later", action: onClose).buttonStyle(SecondaryButtonStyle())
                } else {
                    Text("Join your physio's program").font(.laileTitle)
                    Text("Enter the code from your physiotherapist or doctor. Your program, limits and medicines come from them, and they see your sessions and how you're feeling.")
                        .foregroundStyle(Theme.muted)
                    TextField("LAI-XXXXXX", text: $code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.title3.monospaced())
                        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                    Spacer()
                    Button(working ? "Joining…" : "Join") { Task { await join() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(code.trimmingCharacters(in: .whitespaces).count < 6 || working)
                }
            }
            .padding(24)
            .screenBackground()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
        }
    }

    private func join() async {
        working = true
        defer { working = false }
        do {
            try await app.link(inviteCode: code.trimmingCharacters(in: .whitespaces))
            joined = app.activeEnrollments.first(where: \.isSupervised)
            error = nil
            if joined == nil { onClose() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
