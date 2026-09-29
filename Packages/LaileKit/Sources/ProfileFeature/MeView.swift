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
    @State private var restartingDemo = false
    @State private var demoError: String?

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
                        TextField("Invite code, e.g. LAI-7KQ2MX", text: $inviteCode)
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
                    }
                }

                if app.user?.isDemo == true {
                    Section {
                        Button(restartingDemo ? "Starting fresh…" : "Restart demo with fresh data") {
                            Task {
                                restartingDemo = true
                                defer { restartingDemo = false }
                                do { try await app.restartDemo(); demoError = nil } catch { demoError = error.localizedDescription }
                            }
                        }
                        .disabled(restartingDemo)
                        if let demoError { Text(demoError).font(.footnote).foregroundStyle(Theme.danger) }
                    } header: {
                        Text("Demo account")
                    } footer: {
                        Text("This is a demo account with sample history. Restarting gives you a brand-new one, so the demo always starts the same way.")
                    }
                }

                VoicePickerSection(app: app)

                Section("Lele, your coach") {
                    Toggle("Speak cues and counts", isOn: $app.settings.speakCues)
                    Toggle("Listen for how it feels", isOn: $app.settings.listenForFeedback)
                    Toggle("Use front camera", isOn: $app.settings.preferFrontCamera)
                }

                Section("Account") {
                    LabeledContent("Email", value: app.user?.email ?? "—")
                    Button("Sign out", role: .destructive) { app.signOut() }
                }

                Section("Privacy & safety") {
                    Label("Video never leaves your phone. Only joint angles and counts are saved.", systemImage: "lock.shield")
                    Label("Lele coaches movement. It doesn't diagnose, and it never gives medication or dosing advice.", systemImage: "cross.case")
                    Label("Chest pain, trouble breathing or a swollen, hot calf? Stop and call 995.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.danger)
                }
                .font(.footnote)
            }
            .navigationTitle("Me")
        }
    }
}

/// First run: create an account (or sign in), pick a path, a short activity-readiness check
/// or clinician link, then camera/mic permissions.
public struct OnboardingView: View {
    enum Step { case welcome, account, path, readiness, link, permissions }

    @Bindable var app: AppModel
    @State private var step: Step
    @State private var creatingAccount = true
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
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
        _step = State(initialValue: app.isSignedIn ? .path : .welcome)
        _answers = State(initialValue: Array(repeating: nil, count: Self.questions.count))
    }

    public var body: some View {
        VStack(spacing: 20) {
            switch step {
            case .welcome: welcome
            case .account: account
            case .path: path
            case .readiness: readiness
            case .link: linkClinician
            case .permissions: permissions
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
            Text("Quick camera-counted sessions and stretches, Lele, a coach you can talk to, and — if you're recovering — your clinician's plan, verified.")
                .foregroundStyle(Theme.muted)
            Spacer()
            Button("Get started") { creatingAccount = true; step = .account }.buttonStyle(PrimaryButtonStyle())
            Button("I already have an account") { creatingAccount = false; step = .account }.buttonStyle(SecondaryButtonStyle())
            demoButtons
        }
    }

    /// One tap into a ready-made account with two weeks of history. Fresh every time.
    private var demoButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Just looking? Try a demo account").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                demoButton("Knee rehab", systemImage: "cross.case.fill", persona: .patient)
                demoButton("Daily mover", systemImage: "figure.run", persona: .mover)
            }
            if let error, step == .welcome { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
        }
        .padding(.top, 6)
    }

    private func demoButton(_ title: String, systemImage: String, persona: API.DemoPersona) -> some View {
        Button {
            Task {
                working = true
                defer { working = false }
                do {
                    try await app.startDemo(persona)
                    error = nil
                    if Permissions.current.all { finish() } else { step = .permissions }
                } catch {
                    self.error = error.localizedDescription
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.surface2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .disabled(working)
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text(creatingAccount ? "Create your account" : "Welcome back").font(.laileTitle)
            if creatingAccount {
                field(TextField("What should I call you?", text: $name).textContentType(.givenName))
            }
            field(TextField("Email", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled())
            field(SecureField(creatingAccount ? "Password (8+ characters)" : "Password", text: $password)
                .textContentType(creatingAccount ? .newPassword : .password))
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
            Spacer()
            Button(working ? "One moment…" : (creatingAccount ? "Create account" : "Sign in")) { Task { await submitAccount() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!accountFormValid || working)
            Button(creatingAccount ? "I already have an account" : "Create a new account") {
                creatingAccount.toggle()
                error = nil
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func field(_ content: some View) -> some View {
        content.padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var accountFormValid: Bool {
        email.contains("@") && password.count >= (creatingAccount ? 8 : 1)
            && (!creatingAccount || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func submitAccount() async {
        working = true
        defer { working = false }
        do {
            let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
            if creatingAccount {
                try await app.register(email: trimmedEmail, password: password, name: name.trimmingCharacters(in: .whitespaces))
                step = .path
            } else {
                try await app.signIn(email: trimmedEmail, password: password)
                // Returning rehab patients already have their clinician linked.
                step = app.mode == .rehab ? .permissions : .path
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var path: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("What brings you here?").font(.laileTitle)
            Text("You can link a clinician later from the Me tab.").foregroundStyle(Theme.muted)
            Spacer()
            Button("I want quick daily movement") { step = .readiness }.buttonStyle(PrimaryButtonStyle())
            Button("I'm recovering with a clinician's plan") { step = .link }.buttonStyle(SecondaryButtonStyle())
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
                step = .permissions
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
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
            Spacer()
            Button("Link and continue") {
                Task {
                    do { try await app.link(inviteCode: inviteCode); step = .permissions } catch { self.error = error.localizedDescription }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("I don't have a code yet") { step = .readiness }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Camera and voice").font(.laileTitle)
            Label("The camera counts your reps and measures your joints. Video never leaves your phone.", systemImage: "camera.fill")
            Label("The microphone lets you tell Lele how things feel mid-exercise — \"it's pulling\", \"sharp pain\".", systemImage: "mic.fill")
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

    private func finish() {
        app.settings.onboardingComplete = true
        app.warmUpVoice()
        Task { await app.refresh() }
    }
}
