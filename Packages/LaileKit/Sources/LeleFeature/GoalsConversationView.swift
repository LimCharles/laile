import AppCore
import DesignSystem
import LaileCore
import SwiftUI

/// Lele asks what you want from Laile, a few questions at a time, then builds your plan.
/// Used at onboarding and whenever someone asks for a new plan. `onFinish` gets the new program
/// when the person wants to start its check-in now (the caller opens it once it's safe to).
public struct GoalsConversationView: View {
    enum Step: Int, CaseIterable { case goals, minutes, experience, areas, safety, notes, building, done }

    @Bindable var app: AppModel
    let onFinish: (Enrollment?) -> Void
    @State private var step: Step = .goals
    @State private var profile: HealthProfile
    @State private var notes = ""
    @State private var safetyConcern: Bool?
    @State private var result: API.PlanResponse?
    @State private var error: String?

    public init(app: AppModel, onFinish: @escaping (Enrollment?) -> Void) {
        self.app = app
        self.onFinish = onFinish
        _profile = State(initialValue: app.today?.health ?? HealthProfile())
    }

    private var firstName: String { app.callName ?? "there" }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Step.allCases.filter { $0.rawValue <= step.rawValue }, id: \.self) { s in
                            VStack(alignment: .leading, spacing: 10) { turn(s) }.id(s)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: step) { _, s in withAnimation { proxy.scrollTo(s, anchor: .top) } }
            }
            .screenBackground()
            .navigationTitle("Your plan with Lele")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step != .done { Button("Later") { onFinish(nil) } }
                }
            }
        }
    }

    // MARK: Turns

    @ViewBuilder private func turn(_ s: Step) -> some View {
        switch s {
        case .goals:
            lele("Hi \(firstName)! I'm Lele, your coach here at Laile. What would you like to get out of moving with me? Pick as many as you like.")
            if step == .goals {
                chips(HealthProfile.Goal.allCases, selected: Set(profile.goals), label: \.label) { toggle(&profile.goals, $0) }
                next(enabled: !profile.goals.isEmpty) { step = .minutes }
            } else {
                mine(profile.goals.map(\.label).joined(separator: ", "))
            }
        case .minutes:
            lele("How much time can you give most days? Little and often beats one long session.")
            if step == .minutes {
                chips([5, 10, 15, 20, 30], selected: [profile.minutesPerDay], label: { "\($0) min" }) { profile.minutesPerDay = $0; step = .experience }
            } else {
                mine("\(profile.minutesPerDay) minutes")
            }
        case .experience:
            lele("And how much do you move at the moment?")
            if step == .experience {
                chips(HealthProfile.Experience.allCases, selected: [profile.experience], label: \.label) { profile.experience = $0; step = .areas }
            } else {
                mine(profile.experience.label)
            }
        case .areas:
            lele("Is there anywhere that hurts, or that someone has told you to be careful with? I'll keep your plan away from anything that could aggravate it.")
            if step == .areas {
                chips(HealthProfile.BodyArea.allCases, selected: Set(profile.sensitiveAreas), label: \.label) { toggle(&profile.sensitiveAreas, $0) }
                HStack {
                    Button("Nothing, I'm fine") { profile.sensitiveAreas = []; step = .safety }.buttonStyle(SecondaryButtonStyle())
                    if !profile.sensitiveAreas.isEmpty { Button("Next") { step = .safety }.buttonStyle(PrimaryButtonStyle()) }
                }
            } else {
                mine(profile.sensitiveAreas.isEmpty ? "Nothing, I'm fine" : profile.sensitiveAreas.map(\.label).joined(separator: ", "))
            }
        case .safety:
            lele("One safety question. Has a doctor told you to only exercise with medical advice, or do you get chest pain, faintness or dizziness when you're active?")
            if step == .safety {
                HStack {
                    Button("No") { safetyConcern = false; step = .notes }.buttonStyle(SecondaryButtonStyle())
                    Button("Yes") { safetyConcern = true; step = .notes }.buttonStyle(SecondaryButtonStyle())
                }
            } else if let safetyConcern {
                mine(safetyConcern ? "Yes" : "No")
                if safetyConcern {
                    lele("Thanks for telling me. I'll keep things gentle and low-impact, and please check with your doctor before anything harder.")
                }
            }
        case .notes:
            lele("Anything else I should know? An old injury, a goal like \"play with my grandkids\", or something you'd rather avoid. You can skip this.")
            if step == .notes {
                TextField("In your own words", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                Button { Task { await build() } } label: { Label("Build my plan", systemImage: "sparkles") }
                    .buttonStyle(PrimaryButtonStyle())
            } else if !notes.trimmingCharacters(in: .whitespaces).isEmpty {
                mine(notes)
            }
        case .building:
            if step == .building {
                HStack(spacing: 10) {
                    LeleAvatar()
                    ProgressView()
                    Text("Putting your plan together…").font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
                Button("Try again") { Task { await build() } }.buttonStyle(SecondaryButtonStyle())
            }
        case .done:
            if let result { planResult(result) }
        }
    }

    private func planResult(_ result: API.PlanResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The big button below starts the check-in, so Lele's own start chip would be a duplicate.
            ForEach(result.messages.map { m in var m = m; m.actions.removeAll { $0.kind == .startSession }; return m }) { message in
                LeleBubble(message: message) { action in
                    onFinish(nil)
                    app.afterSheetCloses { await app.perform(action, on: message) }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label(result.enrollment.title, systemImage: "sparkles").font(.laileHeadline).foregroundStyle(Theme.accent)
                    if !result.enrollment.subtitle.isEmpty {
                        Text(result.enrollment.subtitle).font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    ForEach(result.enrollment.program.items) { item in
                        if let spec = ExerciseLibrary.standard.spec(item.exerciseId) {
                            HStack {
                                Image(systemName: spec.symbol).frame(width: 24).foregroundStyle(spec.category.color)
                                Text(spec.name).foregroundStyle(Theme.text)
                                Spacer()
                                Text(item.dose.shortDescription).font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    Text("Your first session is a short check-in. I'll watch how far you comfortably go and set your targets from that.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Button {
                onFinish(result.enrollment)
            } label: { Label("Start my check-in", systemImage: "play.fill") }
                .buttonStyle(PrimaryButtonStyle())
            Button("Later") { onFinish(nil) }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private func build() async {
        error = nil
        step = .building
        var profile = self.profile
        profile.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.updatedAt = Date()
        if safetyConcern == true { app.settings.gentleOnly = true }
        do {
            result = try await app.plan(profile)
            step = .done
            Haptics.success()
        } catch {
            self.error = "I couldn't build your plan just now (\(error.localizedDescription))."
        }
    }

    // MARK: Pieces

    private func lele(_ text: String) -> some View {
        LeleBubble(message: LeleMessage(createdAt: Date(), kind: .chat, text: text)) { _ in }
    }

    private func mine(_ text: String) -> some View {
        LeleBubble(message: LeleMessage(createdAt: Date(), kind: .chat, author: .person, text: text)) { _ in }
    }

    private func next(enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button("Next", action: action)
            .buttonStyle(PrimaryButtonStyle(color: enabled ? Theme.accent : Theme.muted))
            .disabled(!enabled)
    }

    private func chips<T: Hashable>(_ options: [T], selected: Set<T>, label: @escaping (T) -> String, onTap: @escaping (T) -> Void) -> some View {
        FlowRow(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let on = selected.contains(option)
                Button { onTap(option) } label: {
                    Text(label(option))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(on ? Theme.accent : Theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(on ? Color.clear : Theme.surface2, lineWidth: 1))
                        .foregroundStyle(on ? .white : Theme.text)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 40)
    }

    private func toggle<T: Equatable>(_ list: inout [T], _ value: T) {
        if let i = list.firstIndex(of: value) { list.remove(at: i) } else { list.append(value) }
    }
}
