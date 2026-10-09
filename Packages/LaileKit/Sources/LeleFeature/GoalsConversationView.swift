import AppCore
import DesignSystem
import LaileCore
import SwiftUI

/// Lele asks what you want from Laile, a few questions at a time, then builds your plan.
/// Used at onboarding and whenever someone asks for a new plan. `onFinish` gets the new program
/// when the person wants to start its check-in now (the caller opens it once it's safe to).
public struct GoalsConversationView: View {
    enum Step: Int, CaseIterable { case goals, minutes, experience, areas, safety, notes, building, done }

    /// A line said between a question and its answer: an answer Lele couldn't read, and its follow-up.
    struct Aside: Hashable { var mine: Bool; var text: String }

    @Bindable var app: AppModel
    let onFinish: (Enrollment?) -> Void
    @State private var step: Step = .goals
    @State private var profile: HealthProfile
    @State private var notes = ""
    @State private var safetyConcern: Bool?
    @State private var result: API.PlanResponse?
    @State private var error: String?
    /// What they typed for each answered question (shown instead of the chip summary).
    @State private var typed: [Step: String] = [:]
    @State private var asides: [Step: [Aside]] = [:]
    /// Their own words, kept for the plan builder.
    @State private var said: [String] = []
    @State private var input = ""
    @FocusState private var focused: Bool

    public init(app: AppModel, onFinish: @escaping (Enrollment?) -> Void) {
        self.app = app
        self.onFinish = onFinish
        _profile = State(initialValue: app.today?.health ?? HealthProfile())
    }

    private var firstName: String { app.callName ?? "there" }
    private var isAsking: Bool { step.rawValue <= Step.notes.rawValue }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Step.allCases.filter { $0.rawValue <= step.rawValue }, id: \.self) { s in
                            VStack(alignment: .leading, spacing: 10) { turn(s) }.id(s)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                }
                .onChange(of: step) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: asides) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .safeAreaInset(edge: .bottom) { if isAsking { inputBar } }
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
            lele("Hi \(firstName)! I'm Lele, your coach here at Laile. What would you like to get out of moving with me? Tell me in your own words, or pick any of these.")
            followUps(s)
            if step == .goals {
                chips(HealthProfile.Goal.allCases, selected: Set(profile.goals), label: \.label) { toggle(&profile.goals, $0) }
                next(enabled: !profile.goals.isEmpty) { step = .minutes }
            } else {
                answer(s, profile.goals.map(\.label).joined(separator: ", "))
            }
        case .minutes:
            lele("How much time can you give most days? Little and often beats one long session.")
            followUps(s)
            if step == .minutes {
                chips([5, 10, 15, 20, 30], selected: [profile.minutesPerDay], label: { "\($0) min" }) { profile.minutesPerDay = $0; step = .experience }
            } else {
                answer(s, "\(profile.minutesPerDay) minutes")
            }
        case .experience:
            lele("And how much do you move at the moment?")
            followUps(s)
            if step == .experience {
                chips(HealthProfile.Experience.allCases, selected: [profile.experience], label: \.label) { profile.experience = $0; step = .areas }
            } else {
                answer(s, profile.experience.label)
            }
        case .areas:
            lele("Is there anywhere that hurts, or that someone has told you to be careful with? I'll keep your plan away from anything that could aggravate it.")
            followUps(s)
            if step == .areas {
                chips(HealthProfile.BodyArea.allCases, selected: Set(profile.sensitiveAreas), label: \.label) { toggle(&profile.sensitiveAreas, $0) }
                HStack {
                    Button("Nothing, I'm fine") { profile.sensitiveAreas = []; step = .safety }.buttonStyle(SecondaryButtonStyle())
                    if !profile.sensitiveAreas.isEmpty { Button("Next") { step = .safety }.buttonStyle(PrimaryButtonStyle()) }
                }
            } else {
                answer(s, profile.sensitiveAreas.isEmpty ? "Nothing, I'm fine" : profile.sensitiveAreas.map(\.label).joined(separator: ", "))
            }
        case .safety:
            lele("One safety question. Has a doctor told you to only exercise with medical advice, or do you get chest pain, faintness or dizziness when you're active?")
            followUps(s)
            if step == .safety {
                HStack {
                    Button("No") { safetyConcern = false; step = .notes }.buttonStyle(SecondaryButtonStyle())
                    Button("Yes") { safetyConcern = true; step = .notes }.buttonStyle(SecondaryButtonStyle())
                }
            } else if let safetyConcern {
                answer(s, safetyConcern ? "Yes" : "No")
                if safetyConcern {
                    lele("Thanks for telling me. I'll keep things gentle and low-impact, and please check with your doctor before anything harder.")
                }
            }
        case .notes:
            lele("Anything else I should know? An old injury, a goal like \"play with my grandkids\", or something you'd rather avoid.")
            followUps(s)
            if step == .notes {
                Button { Task { await build() } } label: {
                    Label(input.trimmingCharacters(in: .whitespaces).isEmpty ? "Nothing else, build my plan" : "Build my plan", systemImage: "sparkles")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else if !notes.isEmpty {
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

    /// Their answer: their own words if they typed it, with what Lele took from it underneath.
    @ViewBuilder private func answer(_ s: Step, _ summary: String) -> some View {
        if let words = typed[s] {
            mine(words)
            Text("Lele heard: \(summary)")
                .font(.caption).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            mine(summary)
        }
    }

    @ViewBuilder private func followUps(_ s: Step) -> some View {
        ForEach(Array((asides[s] ?? []).enumerated()), id: \.offset) { _, aside in
            if aside.mine { mine(aside.text) } else { lele(aside.text) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(step == .notes ? "In your own words" : "Type your answer, or tap one above", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(submit)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.surface2, lineWidth: 1))
            Button(action: submit) {
                Image(systemName: "arrow.up").font(.title3.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(input.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.muted : Theme.accent, in: Circle())
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    /// Reads a typed answer for the current question. Whatever they say is kept for the plan builder;
    /// if Lele can't tell which option they mean, it asks again.
    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        func took(_ next: Step, keep: Bool = false) {
            typed[step] = text
            if keep { said.append(text) }
            step = next
        }
        func unclear(_ reply: String, keep: Bool = false) {
            if keep { said.append(text) }
            asides[step, default: []] += [Aside(mine: true, text: text), Aside(mine: false, text: reply)]
        }
        switch step {
        case .goals:
            let found = GoalsReader.goals(in: text)
            if found.isEmpty {
                unclear("Thanks, I'll keep that in mind. Which of these is closest? Tap any, or tell me another way.", keep: true)
            } else {
                profile.goals = found
                took(.minutes, keep: true)
            }
        case .minutes:
            if let minutes = GoalsReader.minutes(in: text) {
                profile.minutesPerDay = minutes
                took(.experience)
            } else {
                unclear("Roughly how many minutes? Even 5 is plenty to start.")
            }
        case .experience:
            if let experience = GoalsReader.experience(in: text) {
                profile.experience = experience
                took(.areas, keep: true)
            } else {
                unclear("Got it. Would you say you're new to exercise, move now and then, or train regularly?", keep: true)
            }
        case .areas:
            if let areas = GoalsReader.areas(in: text) {
                profile.sensitiveAreas = areas
                took(.safety, keep: !areas.isEmpty)
            } else {
                unclear("I'll note that. Is it one of these areas, or nothing at all?", keep: true)
            }
        case .safety:
            if let concern = GoalsReader.safetyConcern(in: text) {
                safetyConcern = concern
                took(.notes, keep: concern)
            } else {
                unclear("Just to be safe, is that a yes or a no?")
            }
        case .notes:
            notes = text
            Task { await build() }
        case .building, .done:
            break
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
        if notes.isEmpty, !input.trimmingCharacters(in: .whitespaces).isEmpty {
            notes = input.trimmingCharacters(in: .whitespacesAndNewlines)
            input = ""
        }
        error = nil
        step = .building
        var profile = self.profile
        profile.notes = (said + [notes]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ". ")
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
