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
            self.user = try await user
            self.rewards = try await rewards
            self.today = try await today
            self.progress = try await progress
            self.streams = try await streams
            self.careNotes = (try? await careNotes) ?? []
            self.serverOffset = await backend.serverTimeOffset()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isSignedIn = backend.isSignedIn
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
        backend.signOut()
        isSignedIn = false
        user = nil
        rewards = nil
        today = nil
        progress = nil
        careNotes = []
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
