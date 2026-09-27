import AppCore
import DesignSystem
import LaileCore
import SwiftUI

public struct TodayModule: FeatureModule {
    public init() {}
    public var id: String { "today" }
    public var tab: FeatureTab? { FeatureTab(title: "Today", systemImage: "sun.max.fill", order: 0) }
    public func makeRootView(app: AppModel) -> AnyView { AnyView(TodayView(app: app)) }
}

struct TodayView: View {
    @Bindable var app: AppModel
    @State private var claimedOutcome: CheckInOutcome?
    @State private var showConfetti = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    greeting
                    if let rewards = app.rewards {
                        DailyCheckInCard(rewards: rewards, claimed: claimedOutcome) { await claim() }
                        StreakCard(streak: rewards.moveStreak, movedToday: rewards.movedToday)
                    }
                    if app.mode == .rehab { rehabSection }
                    snacks
                    if let next = nextStream { NextStreamCard(stream: next, now: app.now) { app.streamToOpen = next; app.selectedTab = "streams" } }
                    if app.settings.gentleOnly {
                        Card {
                            Label("Gentle mode is on because of your readiness answers. Check with a doctor before harder workouts.", systemImage: "heart.text.square")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .refreshable { await app.refresh() }
            .navigationTitle("Today")
            .toolbar {
                if let level = app.rewards?.level {
                    ToolbarItem(placement: .topBarTrailing) { LevelBadge(level: level) }
                }
            }
            .overlay { if showConfetti { Confetti().id(claimedOutcome?.dayNumber ?? 0) } }
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingText).font(.laileTitle).foregroundStyle(Theme.text)
            Text(app.mode == .rehab ? "Small, steady sessions get your knee back." : "No time? Two minutes still counts.")
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        let name = app.user?.displayName.components(separatedBy: " ").first ?? ""
        return name.isEmpty || name == "You" ? part : "\(part), \(name)"
    }

    private func claim() async {
        guard let outcome = await app.checkIn() else { return }
        claimedOutcome = outcome
        if !outcome.alreadyCheckedIn {
            Haptics.success()
            showConfetti = true
            try? await Task.sleep(for: .seconds(1.6))
            showConfetti = false
        }
    }

    @ViewBuilder private var rehabSection: some View {
        if let plan = app.today, let program = plan.program {
            ProgramCard(program: program, clinician: plan.clinicianName) { app.start(.program(program)) }
            if !plan.medicationDoses.isEmpty {
                MedicationsCard(doses: plan.medicationDoses) { dose in Task { await app.markTaken(dose) } }
            }
        } else {
            Card {
                Label("Waiting for your clinician to sign your program.", systemImage: "hourglass").foregroundStyle(Theme.muted)
            }
        }
    }

    private var snacks: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Quick sessions", subtitle: "Camera-counted. Pick one and go.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(templates) { template in
                        SnackCard(template: template) { app.start(.template(template, gentleOnly: app.settings.gentleOnly)) }
                    }
                }
            }
        }
    }

    private var templates: [SessionTemplate] {
        let all = app.today?.templates ?? SessionTemplate.builtIn.filter { $0.mode == .move }
        return all.filter { $0.mode == app.mode || $0.mode == .move }.sorted { ($0.isSnack ? 0 : 1, $0.minutes) < ($1.isSnack ? 0 : 1, $1.minutes) }
    }

    private var nextStream: StreamEvent? {
        app.streams.first { stream in
            switch StreamClock.phase(of: stream, at: app.now) {
            case .live, .lobby, .upcoming: return true
            case .ended: return false
            }
        }
    }
}

struct LevelBadge: View {
    let level: LevelInfo
    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                RingProgress(progress: level.progress, lineWidth: 3, color: Theme.reward)
                Text("\(level.level)").font(.caption.weight(.heavy))
            }
            .frame(width: 28, height: 28)
            Text("\(level.totalXP) XP").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Level \(level.level), \(level.totalXP) XP")
    }
}

struct DailyCheckInCard: View {
    let rewards: RewardsSummary
    let claimed: CheckInOutcome?
    let onClaim: () async -> Void
    @State private var working = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Daily check-in", systemImage: "gift.fill").font(.laileHeadline).foregroundStyle(Theme.reward)
                    Spacer()
                    Text("\(rewards.loginStreak.current)-day run").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 6) {
                    ForEach(rewards.dailyCalendar) { slot in
                        VStack(spacing: 4) {
                            ZStack {
                                Circle().fill(fill(slot)).frame(width: 38, height: 38)
                                if slot.state == .claimed {
                                    Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(.white)
                                } else {
                                    Text("\(slot.xp)").font(.caption2.weight(.heavy)).foregroundStyle(slot.state == .today ? .white : Theme.muted)
                                }
                            }
                            .overlay(Circle().stroke(Theme.reward, lineWidth: slot.state == .today ? 2 : 0).padding(-3))
                            Text(slot.dayNumber == 7 ? "Day 7" : "D\(slot.dayNumber)").font(.caption2).foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Day \(slot.dayNumber), \(slot.xp) XP, \(slot.state.rawValue)")
                    }
                }
                if rewards.checkedInToday {
                    let next = rewards.dailyCalendar.first { $0.state == .upcoming }
                    Text(claimed.map { "+\($0.xpAwarded) XP claimed! " } ?? "Checked in today. " )
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    + Text(next.map { "Come back tomorrow for +\($0.xp)." } ?? "Come back tomorrow to keep your run.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                } else {
                    Button {
                        working = true
                        Task { await onClaim(); working = false }
                    } label: {
                        Label("Claim today's +\(rewards.dailyCalendar.first { $0.state == .today }?.xp ?? 10) XP", systemImage: "sparkles")
                    }
                    .buttonStyle(PrimaryButtonStyle(color: Theme.reward))
                    .disabled(working)
                }
            }
        }
    }

    private func fill(_ slot: DailyRewardSlot) -> Color {
        switch slot.state {
        case .claimed: return Theme.reward
        case .today: return Theme.reward.opacity(0.75)
        case .upcoming: return Theme.surface2
        }
    }
}

struct StreakCard: View {
    let streak: StreakState
    let movedToday: Bool

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: movedToday ? "flame.fill" : "flame")
                    .font(.system(size: 40))
                    .foregroundStyle(movedToday ? Theme.flame : Theme.muted)
                    .symbolEffect(.bounce, value: movedToday)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(streak.current)-day move streak").font(.laileHeadline).foregroundStyle(Theme.text)
                    Text(message).font(.subheadline).foregroundStyle(Theme.muted)
                }
                Spacer()
                if streak.shields > 0 {
                    VStack(spacing: 2) {
                        Image(systemName: "shield.fill").foregroundStyle(Theme.accent)
                        Text("×\(streak.shields)").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel("\(streak.shields) streak shields")
                }
            }
        }
    }

    private var message: String {
        switch streak.status {
        case .activeToday: return "Done for today. Best: \(streak.best) days."
        case .pendingToday: return "Move today to make it \(streak.current + 1)."
        case .shieldPending: return "You missed yesterday — a shield covers it if you move today."
        case .broken, .none: return "Any session today starts a new streak."
        }
    }
}

struct ProgramCard: View {
    let program: Program
    let clinician: String?
    let onStart: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Your program", systemImage: "cross.case.fill").font(.laileHeadline).foregroundStyle(Theme.accent)
                    Spacer()
                    Pill("v\(program.version) · signed", color: Theme.accent, background: Theme.accentSoft)
                }
                Text(program.title).font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                if let clinician { Text("Prescribed by \(clinician)").font(.caption).foregroundStyle(Theme.muted) }
                ForEach(program.items) { item in
                    if let spec = ExerciseLibrary.standard.spec(item.exerciseId) {
                        HStack {
                            Image(systemName: spec.symbol).frame(width: 24).foregroundStyle(spec.category.color)
                            Text(spec.name).foregroundStyle(Theme.text)
                            Spacer()
                            Text(item.dose.shortDescription + (item.timesPerDay > 1 ? " · \(item.timesPerDay)×/day" : ""))
                                .font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }
                }
                Button(action: onStart) { Label("Start today's session", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

struct MedicationsCard: View {
    let doses: [MedicationDose]
    let onTaken: (MedicationDose) -> Void
    @State private var expanded: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Medications today", systemImage: "pills.fill").font(.laileHeadline).foregroundStyle(Theme.text)
                ForEach(doses) { dose in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(dose.medication.name) · \(dose.medication.doseText)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                Text(dose.scheduled.label).font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if dose.taken {
                                Label("Taken", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                            } else {
                                Button("Mark taken") { onTaken(dose) }.font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(Theme.accent)
                            }
                        }
                        Button {
                            expanded = expanded == dose.id ? nil : dose.id
                        } label: {
                            Label("What's this for?", systemImage: "questionmark.circle").font(.caption)
                        }
                        .tint(Theme.accent)
                        if expanded == dose.id {
                            Text("\(dose.medication.purpose) \(dose.medication.howToTake)").font(.caption).foregroundStyle(Theme.muted)
                            Text("Questions about doses? Ask your doctor or pharmacist — Laile never changes medication advice.")
                                .font(.caption2).foregroundStyle(Theme.muted)
                        }
                    }
                    if dose.id != doses.last?.id { Divider() }
                }
            }
        }
    }
}

struct SnackCard: View {
    let template: SessionTemplate
    let onStart: () -> Void

    var body: some View {
        Button(action: onStart) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(template.minutes) min").font(.caption.weight(.heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.accent, in: Capsule())
                    Spacer()
                    if let first = template.items.first, let spec = ExerciseLibrary.standard.spec(first.exerciseId) {
                        Image(systemName: spec.symbol).foregroundStyle(Theme.accent)
                    }
                }
                Text(template.title).font(.headline).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                Text(template.subtitle).font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.leading).lineLimit(2)
                Spacer(minLength: 0)
                Text("\(template.items.count) moves").font(.caption2).foregroundStyle(Theme.muted)
            }
            .padding(14)
            .frame(width: 170, height: 150, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.surface2, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct NextStreamCard: View {
    let stream: StreamEvent
    let now: Date
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "person.3.fill").font(.title2).foregroundStyle(Theme.live)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status).font(.caption.weight(.bold)).foregroundStyle(Theme.live)
                        Text(stream.title).font(.headline).foregroundStyle(Theme.text)
                        Text("with \(stream.hostName) · \(stream.minutes) min").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var status: String {
        switch StreamClock.phase(of: stream, at: now) {
        case .live: return "● LIVE NOW — JOIN"
        case .lobby(let s): return "LOBBY OPEN · STARTS IN \(Int(s / 60)):\(String(format: "%02d", Int(s) % 60))"
        case .upcoming(let s): return "NEXT STREAM IN \(Int(s / 60)) MIN"
        case .ended: return "ENDED"
        }
    }
}
