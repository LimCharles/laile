import Foundation
import LaileCore
import Observation
import SwiftUI

/// User preferences kept in UserDefaults.
public struct AppSettings: Codable, Equatable {
    public var onboardingComplete = false
    public var serverURL = ""
    public var speakCues = true
    public var listenForFeedback = true
    public var useCloudCoach = true
    /// Set when the readiness screen suggested checking with a doctor first.
    public var gentleOnly = false
    public var preferFrontCamera = true

    public init() {}

    static let key = "laile.settings.v1"

    static func load() -> AppSettings {
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
    public private(set) var backend: any LaileBackend
    public var settings: AppSettings { didSet { settings.save() } }

    public var user: API.UserProfile?
    public var rewards: RewardsSummary?
    public var today: API.TodayPlan?
    public var progress: API.ProgressOverview?
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

    public init() {
        let settings = AppSettings.load()
        self.settings = settings
        if let url = URL(string: settings.serverURL), !settings.serverURL.isEmpty {
            let remote = RemoteBackend(baseURL: url)
            backend = remote.isSignedIn ? remote : DemoBackend()
        } else {
            backend = DemoBackend()
        }
    }

    /// For previews and tests.
    public init(backend: any LaileBackend, settings: AppSettings = AppSettings()) {
        self.backend = backend
        self.settings = settings
    }

    public var mode: AppMode { user?.mode ?? .move }
    public var now: Date { Date().addingTimeInterval(serverOffset) }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let user = backend.currentUser()
            async let rewards = backend.rewards()
            async let today = backend.today()
            async let progress = backend.progress()
            async let streams = backend.streams()
            self.user = try await user
            self.rewards = try await rewards
            self.today = try await today
            self.progress = try await progress
            self.streams = try await streams
            self.serverOffset = await backend.serverTimeOffset()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
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

    public func start(_ launch: SessionLaunch) {
        activeSession = launch
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

    // MARK: Backend switching

    public func useDemoBackend() async {
        settings.serverURL = ""
        backend = DemoBackend()
        await refresh()
    }

    public func connect(serverURL: String, email: String, password: String, register: Bool, name: String) async throws {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            throw BackendError.http(0, "Enter a full server URL, e.g. https://laile.example.com")
        }
        let remote = RemoteBackend(baseURL: url)
        if register {
            _ = try await remote.register(email: email, password: password, name: name)
        } else {
            _ = try await remote.signIn(email: email, password: password)
        }
        settings.serverURL = url.absoluteString
        backend = remote
        await refresh()
    }

    public func signOut() async {
        (backend as? RemoteBackend)?.signOut()
        await useDemoBackend()
    }

    public func resetDemo() async {
        (backend as? DemoBackend)?.resetDemo()
        await refresh()
    }

    public func graduateFromRehab() async {
        (backend as? DemoBackend)?.graduate()
        await refresh()
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
