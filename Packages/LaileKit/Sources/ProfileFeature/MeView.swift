import AppCore
import DesignSystem
import LaileCore
import SwiftUI

public struct ProfileModule: FeatureModule {
    public init() {}
    public var id: String { "me" }
    public var tab: FeatureTab? { FeatureTab(title: "Me", systemImage: "person.crop.circle", order: 3) }
    public func makeRootView(app: AppModel) -> AnyView { AnyView(MeView(app: app)) }
}

struct MeView: View {
    @Bindable var app: AppModel
    @State private var inviteCode = ""
    @State private var linkError: String?
    @State private var linking = false
    @State private var showServer = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 44)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) {
                            Text(app.user?.displayName ?? "You").font(.headline)
                            Text(app.mode == .rehab ? "Rehab mode · \(app.user?.clinicianName ?? "clinician-linked")" : "Move mode")
                                .font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }
                }

                if app.mode == .move {
                    Section {
                        TextField("Invite code, e.g. LAI-DEMO42", text: $inviteCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button(linking ? "Linking…" : "Link my clinician") {
                            Task {
                                linking = true
                                defer { linking = false }
                                do { try await app.link(inviteCode: inviteCode); linkError = nil } catch { linkError = error.localizedDescription }
                            }
                        }
                        .disabled(inviteCode.count < 6 || linking)
                        if let linkError { Text(linkError).foregroundStyle(Theme.danger).font(.footnote) }
                    } header: {
                        Text("Recovering from surgery or an injury?")
                    } footer: {
                        Text("Your clinician gives you a code. Linking shares your sessions, measurements and pain reports with them only.")
                    }
                } else {
                    Section("Your care team") {
                        LabeledContent("Clinician", value: app.user?.clinicianName ?? "—")
                        if app.backend.isDemo {
                            Button("I've been discharged — back to Move mode") { Task { await app.graduateFromRehab() } }
                        }
                    }
                }

                Section("Coach") {
                    Toggle("Speak cues and counts", isOn: $app.settings.speakCues)
                    Toggle("Listen for how it feels", isOn: $app.settings.listenForFeedback)
                    Toggle("Cloud coach (Hunyuan)", isOn: $app.settings.useCloudCoach)
                        .disabled(app.backend.isDemo)
                    Toggle("Use front camera", isOn: $app.settings.preferFrontCamera)
                }

                Section {
                    LabeledContent("Backend", value: app.backend.isDemo ? "On this phone (demo)" : app.backend.displayName)
                    if app.backend.isDemo {
                        Button("Connect to a Laile server…") { showServer = true }
                        Button("Reset demo data", role: .destructive) { Task { await app.resetDemo() } }
                    } else {
                        Button("Sign out", role: .destructive) { Task { await app.signOut() } }
                    }
                } header: {
                    Text("Account")
                }

                Section("Privacy & safety") {
                    Label("Video never leaves your phone. Only joint angles and counts are saved.", systemImage: "lock.shield")
                    Label("Laile coaches movement. It doesn't diagnose, and it never gives medication or dosing advice.", systemImage: "cross.case")
                    Label("Chest pain, trouble breathing or a swollen, hot calf? Stop and call 995.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.danger)
                }
                .font(.footnote)
            }
            .navigationTitle("Me")
            .sheet(isPresented: $showServer) { ServerSheet(app: app) }
        }
    }
}

struct ServerSheet: View {
    @Bindable var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = "http://localhost:8080"
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var register = false
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://…", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                Section {
                    Picker("", selection: $register) {
                        Text("Sign in").tag(false)
                        Text("Create account").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if register { TextField("Your name", text: $name) }
                    TextField("Email", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                    SecureField("Password (8+ characters)", text: $password)
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle("Connect")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "…" : "Connect") {
                        Task {
                            working = true
                            defer { working = false }
                            do {
                                try await app.connect(serverURL: url, email: email, password: password, register: register, name: name)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(email.isEmpty || password.count < 8 || working)
                }
            }
        }
    }
}

/// First-run: pick a path, and (for Move mode) a short activity-readiness check.
public struct OnboardingView: View {
    @Bindable var app: AppModel
    @State private var step = 0
    @State private var name = ""
    @State private var answers: [Bool?]
    @State private var inviteCode = ""
    @State private var error: String?

    static let questions = [
        "Has a doctor ever said you have a heart condition and should only exercise under medical advice?",
        "Do you get chest pain when you're physically active?",
        "In the past month, have you had chest pain while resting?",
        "Do you lose your balance because of dizziness, or have you ever fainted?",
        "Do you have a bone or joint problem that exercise could make worse?",
        "Are you taking medicine for blood pressure or a heart condition?",
        "Is there any other reason you shouldn't be exercising right now?",
    ]

    public init(app: AppModel) {
        self.app = app
        _answers = State(initialValue: Array(repeating: nil, count: Self.questions.count))
    }

    public var body: some View {
        VStack(spacing: 20) {
            switch step {
            case 0: welcome
            case 1: readiness
            case 2: linkClinician
            default: permissions
            }
        }
        .padding(24)
        .screenBackground()
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("莱乐").font(.system(size: 44, weight: .heavy, design: .rounded)).foregroundStyle(Theme.accent)
            Text("Move a little, every day.").font(.laileTitle)
            Text("Quick camera-counted sessions and stretches, a coach you can talk to, and — if you're recovering — your clinician's plan, verified.")
                .foregroundStyle(Theme.muted)
            TextField("What should I call you?", text: $name)
                .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            Spacer()
            Button("I want quick daily movement") { saveName(); step = 1 }.buttonStyle(PrimaryButtonStyle())
            Button("I'm recovering with a clinician's plan") { saveName(); step = 2 }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick safety check").font(.laileTitle)
            Text("Seven yes/no questions before exercise.").foregroundStyle(Theme.muted)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Self.questions.indices, id: \.self) { i in
                        Card(padding: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Self.questions[i]).font(.subheadline).foregroundStyle(Theme.text)
                                Picker("", selection: Binding(get: { answers[i] }, set: { answers[i] = $0 })) {
                                    Text("No").tag(Bool?.some(false))
                                    Text("Yes").tag(Bool?.some(true))
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }
                }
            }
            if answers.contains(where: { $0 == true }) {
                Text("Thanks for being honest. Please check with a doctor before harder workouts — until then Laile keeps you to gentle, low-impact sessions.")
                    .font(.footnote).foregroundStyle(Theme.warn)
            }
            let unanswered = answers.filter { $0 == nil }.count
            Button(unanswered == 0 ? "Continue" : "Answer \(unanswered) more") {
                app.settings.gentleOnly = answers.contains { $0 == true }
                step = 3
            }
            .buttonStyle(PrimaryButtonStyle(color: unanswered == 0 ? Theme.accent : Theme.muted))
            .disabled(unanswered > 0)
        }
    }

    private var linkClinician: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Link your clinician").font(.laileTitle)
            Text("Enter the code from your physiotherapist or surgeon. Your program, limits and medications come from them.")
                .foregroundStyle(Theme.muted)
            TextField("LAI-XXXXXX", text: $inviteCode)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .font(.title3.monospaced())
                .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            if app.backend.isDemo { Text("Demo code: \(DemoBackend.inviteCode)").font(.footnote).foregroundStyle(Theme.muted) }
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
            Spacer()
            Button("Link and continue") {
                Task {
                    do { try await app.link(inviteCode: inviteCode); step = 3 } catch { self.error = error.localizedDescription }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("I don't have a code yet") { step = 1 }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Camera and voice").font(.laileTitle)
            Label("The camera counts your reps and measures your joints. Video never leaves your phone.", systemImage: "camera.fill")
            Label("The microphone lets you tell your coach how things feel mid-exercise — \"it's pulling\", \"sharp pain\".", systemImage: "mic.fill")
            Label("Speech recognition turns what you say into notes and safety checks.", systemImage: "waveform")
            Spacer()
            Button("Allow camera and microphone") {
                Task {
                    await Permissions.requestAll()
                    finish()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Not now") { finish() }.buttonStyle(SecondaryButtonStyle())
        }
        .foregroundStyle(Theme.text)
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { (app.backend as? DemoBackend)?.setDisplayName(trimmed) }
    }

    private func finish() {
        app.settings.onboardingComplete = true
        Task { await app.refresh() }
    }
}
