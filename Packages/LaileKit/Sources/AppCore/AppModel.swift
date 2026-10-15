import Foundation
import LaileCore
import Observation
import SwiftUI
import VoiceKit

/// User preferences kept in UserDefaults.
public struct AppSettings: Codable, Equatable {
    public var onboardingComplete = false
    public var speakCues = true
    public var listenForFeedback = true
    /// Set when the readiness screen suggested checking with a doctor first.
    public var gentleOnly = false
    public var preferFrontCamera = true
    /// `CoachVoice` raw value (optional so older saved settings still decode).
    public var coachVoice: String?

    /// Off only when the person turns Lele's reminders off (optional so older settings decode).
    public var leleRemindersOff: Bool?
    public var remindersEnabled: Bool {
        get { leleRemindersOff != true }
        set { leleRemindersOff = !newValue }
    }

    public var voice: CoachVoice {
        get { coachVoice.flatMap(CoachVoice.init(rawValue:)) ?? .default }
        set { coachVoice = newValue.rawValue }
    }

    public init() {}

    static let key = "laile.settings.v2"

    public static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// App-wide state shared by every feature module.
@MainActor
@Observable
public final class AppModel {
    public let backend: any LaileBackend
    public var settings: AppSettings { didSet { settings.save() } }
    /// Mirrors the backend's token state so views update on sign-in / sign-out / expiry.
    public private(set) var isSignedIn: Bool

    public var user: API.UserProfile?
    public var rewards: RewardsSummary?
    public var today: API.TodayPlan?
    public var progress: API.ProgressOverview?
    /// Lele's notes, open ones first (history included).
    public var careNotes: [CareNote] = []
    /// Every program the person has been in, active first.
    public var enrollments: [Enrollment] = []
    /// The conversation with Lele, oldest first.
    public var leleMessages: [LeleMessage] = []
    /// Text to put in the chat box when the Lele tab opens (e.g. from a "help me prepare" action).
    public var leleDraft: String?
    /// Present the voice check-in with Lele.
    public var showLeleCall = false
    /// Present Me (profile and settings).
    public var showMe = false
    public var streams: [StreamEvent] = []
    public var serverOffset: TimeInterval = 0
    public var lastError: String?
    public var isLoading = false

    /// Currently selected tab (a `FeatureModule.id`).
    public var selectedTab = "today"
    /// Stream to open when switching to the Streams tab.
    public var streamToOpen: StreamEvent?

    /// Set to present the full-screen session.
    public var activeSession: SessionLaunch?
    /// Latest session result, shown after the session sheet closes.
    public var lastResult: API.SessionSubmitResponse?

    /// The app's model, talking to the hosted API this build is configured for.
    public convenience init() {
        self.init(backend: RemoteBackend(), settings: .load())
    }

    /// For previews and tests (stub the backend).
    public init(backend: any LaileBackend, settings: AppSettings) {
        self.backend = backend
        self.settings = settings
        self.isSignedIn = backend.isSignedIn
    }

    public var mode: AppMode { user?.mode ?? .move }
    /// How Lele addresses the person ("Mdm Tan", "Sam"); nil before they've given a name.
    public var callName: String? {
        guard let name = user?.displayName, !name.isEmpty, name != "You" else { return nil }
        return CallName.from(name)
    }
    public var now: Date { Date().addingTimeInterval(serverOffset) }

    public func refresh() async {
        guard backend.isSignedIn else { isSignedIn = false; return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let user = backend.currentUser()
            async let rewards = backend.rewards()
            async let today = backend.today()
            async let progress = backend.progress()
            async let streams = backend.streams()
            async let careNotes = backend.careNotes()
            async let enrollments = backend.enrollments()
            async let lele = backend.leleMessages()
            self.user = try await user
            self.rewards = try await rewards
            self.today = try await today
            self.progress = try await progress
            self.streams = try await streams
            self.careNotes = (try? await careNotes) ?? []
            self.enrollments = (try? await enrollments) ?? []
            if let lele = try? await lele { self.leleMessages = lele.sorted { $0.createdAt < $1.createdAt } }
            self.serverOffset = await backend.serverTimeOffset()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isSignedIn = backend.isSignedIn
        await scheduleReminders()
    }

    /// Puts Lele's reminders for the next few days on the phone (or clears them).
    public func scheduleReminders() async {
        guard isSignedIn, settings.remindersEnabled else {
            LeleNotifications.shared.cancelAll()
            return
        }
        let doses = today?.medicationDoses ?? []
        var medications: [Medication] = []
        for dose in doses where !medications.contains(where: { $0.id == dose.medication.id }) { medications.append(dose.medication) }
        let plan = LeleReminders.plan(.init(now: now, timeZone: .current, enrollments: enrollments, medications: medications,
                                            dosesToday: doses, sessionDoneToday: rewards?.movedToday ?? false))
        await LeleNotifications.shared.reschedule(plan)
    }

    @discardableResult
    public func checkIn() async -> CheckInOutcome? {
        do {
            let response = try await backend.checkIn()
            rewards = response.summary
            return response.outcome
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Opens a session. Lele's open notes ease any exercise that was sore last time (baselines
    /// stay unchanged so they remain a fair measurement).
    public func start(_ launch: SessionLaunch) {
        var launch = launch
        if launch.kind != .baseline, let notes = today?.careNotes, !notes.isEmpty {
            launch.plan = CareMemory.adjust(launch.plan, notes: notes)
        }
        activeSession = launch
    }

    // MARK: Programs

    /// Active programs, the clinician's first.
    public var activeEnrollments: [Enrollment] {
        enrollments.filter(\.isActive).sorted { ($0.isSupervised ? 0 : 1) < ($1.isSupervised ? 0 : 1) }
    }
    /// A clinician is supervising one of the person's programs.
    public var isSupervised: Bool { activeEnrollments.contains(where: \.isSupervised) }
    /// The supervising clinician's name, if there is one.
    public var supervisorName: String? {
        activeEnrollments.first(where: \.isSupervised).map { $0.supervisorName.map(CallName.plain) ?? "your physio" }
    }
    /// Limits for every session: the person's own, their clinician's, and gentle mode.
    public var precautions: Precautions {
        let base = today?.precautions ?? .none
        return settings.gentleOnly ? base.merged(with: Precautions(maxImpact: .low)) : base
    }

    public func start(_ enrollment: Enrollment, recheck: Bool = false) {
        start(.enrollment(enrollment, precautions: precautions, recheck: recheck))
    }

    /// Runs `work` once a sheet has had time to close, so the full-screen session can open.
    public func afterSheetCloses(_ work: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            await work()
        }
    }

    public func startSnack(_ template: SessionTemplate) {
        start(.snack(template, precautions: precautions))
    }

    @discardableResult
    public func join(catalogId: String) async -> Enrollment? {
        do {
            let enrollment = try await backend.join(catalogId: catalogId)
            enrollments = try await backend.enrollments()
            today = try? await backend.today()
            return enrollment
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// The latest time the person asked their physio about this catalog program.
    public func request(for catalogId: String) -> ProgramRequest? {
        today?.requests.first { $0.catalogId == catalogId }
    }

    /// Asks the physio to add a catalog program. Returns an error message if it couldn't be sent.
    public func requestProgram(_ template: SessionTemplate) async -> String? {
        do {
            let turn = try await backend.requestProgram(catalogId: template.id)
            merge(turn.messages)
            today = (try? await backend.today()) ?? today
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func leave(_ enrollment: Enrollment) async -> String? {
        do {
            _ = try await backend.leave(enrollmentId: enrollment.id)
            enrollments = try await backend.enrollments()
            today = try? await backend.today()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The goals conversation's result: Lele's personal plan.
    public func plan(_ profile: HealthProfile) async throws -> API.PlanResponse {
        let response = try await backend.plan(profile)
        merge(response.messages)
        enrollments = (try? await backend.enrollments()) ?? enrollments
        today = try? await backend.today()
        return response
    }

    // MARK: Lele

    public func refreshLele() async {
        guard let messages = try? await backend.leleMessages() else { return }
        let known = Set(leleMessages.map(\.id))
        leleMessages = messages.sorted { $0.createdAt < $1.createdAt }
        // Something happened since the last look (e.g. the physio approved a plan): programs and Today may have changed too.
        if messages.contains(where: { !known.contains($0.id) }), !known.isEmpty {
            enrollments = (try? await backend.enrollments()) ?? enrollments
            today = (try? await backend.today()) ?? today
        }
    }

    public func chat(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let question = openQuestion
        // Show their words straight away; the server's copy replaces this one.
        let pending = LeleMessage(createdAt: Date(), kind: .chat, author: .person, text: trimmed)
        leleMessages.append(pending)
        do {
            // If Lele's last message is a question, what they type is their answer to it.
            let turn = if let question {
                try await backend.leleReply(to: question.id, actionId: nil, text: trimmed)
            } else {
                try await backend.leleChat(trimmed)
            }
            leleMessages.removeAll { $0.id == pending.id }
            merge(turn.messages)
            if !turn.careNotes.isEmpty { await refreshNotes() }
        } catch {
            lastError = error.localizedDescription
            leleMessages.append(LeleMessage(createdAt: Date(), kind: .chat,
                                            text: "I couldn't reply just now. Check your connection and try again in a moment."))
        }
    }

    /// Lele's question still waiting for an answer, if it's the latest thing in the conversation.
    public var openQuestion: LeleMessage? {
        guard let last = leleMessages.last(where: { $0.author != .person }), last.isOpenQuestion,
              !leleMessages.contains(where: { $0.author == .person && $0.createdAt > last.createdAt }) else { return nil }
        return last
    }

    /// Something Lele offered: answer its question, start a session, join a program, open chat, or call.
    public func perform(_ action: LeleAction, on message: LeleMessage) async {
        switch action.kind {
        case .reply:
            do {
                let turn = try await backend.leleReply(to: message.id, actionId: action.id, text: nil)
                merge(turn.messages)
                if !turn.careNotes.isEmpty || action.id == "taken" { await refreshNotes() }
            } catch {
                lastError = error.localizedDescription
            }
        case .startSession:
            guard let value = action.value else { return }
            if value.hasPrefix("snack:"), let template = SessionTemplate.builtIn(String(value.dropFirst(6))) {
                startSnack(template)
            } else if let id = UUID(uuidString: value), let enrollment = enrollments.first(where: { $0.id == id && $0.isActive }) {
                start(enrollment)
            }
        case .joinProgram:
            if let id = action.value, let enrollment = await join(catalogId: id) {
                merge([LeleMessage(createdAt: Date(), kind: .chat, text: "You're in! Your first \(enrollment.title) session is a quick check-in to set your targets.",
                                   actions: [LeleAction(id: "start", label: "Start check-in", kind: .startSession, value: enrollment.id.uuidString)])])
            }
        case .openChat:
            leleDraft = action.value
            selectedTab = "lele"
        case .call:
            showLeleCall = true
        }
    }

    private func merge(_ messages: [LeleMessage]) {
        for message in messages {
            if let i = leleMessages.firstIndex(where: { $0.id == message.id }) { leleMessages[i] = message } else { leleMessages.append(message) }
        }
        leleMessages.sort { $0.createdAt < $1.createdAt }
    }

    private func refreshNotes() async {
        careNotes = (try? await backend.careNotes()) ?? careNotes
        today = (try? await backend.today()) ?? today
    }

    /// The person says a sore spot feels better. Returns the reason when it can't be closed.
    public func markBetter(_ note: CareNote) async -> String? {
        do {
            let updated = try await backend.markCareNoteBetter(note.id)
            careNotes = careNotes.map { $0.id == updated.id ? updated : $0 }
            today = try? await backend.today()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func submit(_ summary: SessionSummary) async -> API.SessionSubmitResponse? {
        do {
            let result = try await backend.submit(summary)
            rewards = result.summary
            lastResult = result
            Task { await refresh() }
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func link(inviteCode: String) async throws {
        user = try await backend.link(inviteCode: inviteCode)
        await refresh()
    }

    public func markTaken(_ dose: MedicationDose) async {
        try? await backend.markMedicationTaken(dose.medication.id, scheduled: dose.scheduled)
        today = try? await backend.today()
        await scheduleReminders()
    }

    // MARK: Account

    public func signIn(email: String, password: String) async throws {
        user = try await backend.signIn(email: email, password: password)
        isSignedIn = true
        await refresh()
    }

    public func register(email: String, password: String, name: String) async throws {
        user = try await backend.register(email: email, password: password, name: name)
        isSignedIn = true
        await refresh()
    }

    public func startDemo(_ persona: API.DemoPersona) async throws {
        user = try await backend.startDemo(persona)
        isSignedIn = true
        settings.gentleOnly = false
        await refresh()
    }

    /// Fresh demo data: a brand-new demo account of the same kind.
    public func restartDemo() async throws {
        try await startDemo(mode == .rehab ? .patient : .mover)
    }

    /// Fetches the everyday lines for the chosen voice in the background.
    public func warmUpVoice() {
        let backend = self.backend
        let voice = settings.voice
        Task.detached(priority: .utility) {
            await VoiceStore.shared.prefetch(CueCatalog.core(), voice: voice, fetch: { text, voice in await backend.speech(text, voice: voice) })
        }
    }

    public func signOut() {
        LeleNotifications.shared.cancelAll()
        backend.signOut()
        isSignedIn = false
        user = nil
        rewards = nil
        today = nil
        progress = nil
        careNotes = []
        enrollments = []
        leleMessages = []
        showMe = false
        showLeleCall = false
        settings.onboardingComplete = false
    }
}

/// A tab (or other top-level surface) contributed by a feature module.
public struct FeatureTab {
    public var title: String
    public var systemImage: String
    public var order: Int

    public init(title: String, systemImage: String, order: Int) {
        self.title = title
        self.systemImage = systemImage
        self.order = order
    }
}

/// The plug-in point for features. New features conform to this and are listed in
/// `FeatureRegistry` (AppShell); nothing else needs to change.
@MainActor
public protocol FeatureModule {
    var id: String { get }
    var tab: FeatureTab? { get }
    func makeRootView(app: AppModel) -> AnyView
}
