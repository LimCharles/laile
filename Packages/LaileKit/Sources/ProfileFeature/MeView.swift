import AppCore
import DesignSystem
import LaileCore
import LeleFeature
import SwiftUI

/// Me: who you are, what you told Lele, your coach's voice and settings. Opened from Today.
public struct MeView: View {
    @Bindable var app: AppModel
    @State private var restartingDemo = false
    @State private var demoError: String?
    @State private var showGoals = false

    public init(app: AppModel) { self.app = app }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 44)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) {
                            Text(app.user?.displayName ?? "You").font(.headline)
                            Text(app.user?.email ?? "").font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }
                }

                Section {
                    if let health = app.today?.health {
                        LabeledContent("Goals", value: health.goals.map(\.label).joined(separator: ", "))
                        LabeledContent("Most days", value: "\(health.minutesPerDay) min")
                        LabeledContent("Careful with", value: health.sensitiveAreas.isEmpty ? "Nothing" : health.sensitiveAreas.map(\.label).joined(separator: ", "))
                        if health.clinicianPrecautions != nil {
                            Label("Limits from your physio still protect you in every program.", systemImage: "shield.lefthalf.filled")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                    if !app.isSupervised {
                        Button { showGoals = true } label: { Label(app.today?.health == nil ? "Tell Lele your goals" : "Update with Lele", systemImage: "sparkles") }
                    }
                } header: {
                    Text("What you told Lele")
                }

                if let supervised = app.activeEnrollments.first(where: \.isSupervised) {
                    Section("Your care team") {
                        LabeledContent("Physio", value: supervised.supervisorName ?? app.user?.clinicianName ?? "—")
                        LabeledContent("Program", value: supervised.title)
                        Text("They see your sessions, measurements, what you tell Lele about pain, and your sessions live while you're doing them.")
                            .font(.footnote).foregroundStyle(Theme.muted)
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
                    Toggle("Gentle mode (low impact only)", isOn: $app.settings.gentleOnly)
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { app.showMe = false } } }
            .sheet(isPresented: $showGoals) {
                GoalsConversationView(app: app) { enrollment in
                    showGoals = false
                    if let enrollment {
                        app.showMe = false
                        app.afterSheetCloses { app.start(enrollment) }
                    }
                }
            }
        }
    }
}

/// First run: create an account (or sign in), then either Lele's goals conversation or a
/// physio's code, then camera/mic permissions. Their first program's check-in opens at the end.
public struct OnboardingView: View {
    enum Step { case welcome, account, path, goals, link, permissions }

    @Bindable var app: AppModel
    @State private var step: Step
    @State private var creatingAccount = true
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var inviteCode = ""
    @State private var error: String?
    /// The program to open once onboarding finishes.
    @State private var firstProgram: Enrollment?

    public init(app: AppModel) {
        self.app = app
        _step = State(initialValue: app.isSignedIn ? .path : .welcome)
    }

    public var body: some View {
        Group {
            switch step {
            case .goals:
                GoalsConversationView(app: app) { enrollment in
                    firstProgram = enrollment
                    step = .permissions
                }
            default:
                VStack(spacing: 20) {
                    switch step {
                    case .welcome: welcome
                    case .account: account
                    case .path: path
                    case .link: linkClinician
                    case .permissions, .goals: permissions
                    }
                }
                .padding(24)
                .screenBackground()
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("莱乐").font(.system(size: 44, weight: .heavy, design: .rounded)).foregroundStyle(Theme.accent)
            Text("Get strong. Get better.").font(.laileTitle)
            Text("Physio and calisthenics programs that fit you, camera-counted, with Lele, a coach who checks in, remembers what hurt, and keeps your physio in the loop.")
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
                demoButton("Physio patient", systemImage: "cross.case.fill", persona: .patient)
                demoButton("Calisthenics", systemImage: "figure.strengthtraining.traditional", persona: .mover)
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
                field(TextField("What should Lele call you?", text: $name).textContentType(.givenName))
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
                // Returning people already have their programs.
                step = app.activeEnrollments.isEmpty ? .path : .permissions
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var path: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            LeleAvatar(size: 56)
            Text("Hi, I'm Lele.").font(.laileTitle)
            Text("I'm your coach at Laile. Are you here to get stronger and move better, or has a physio given you a code for your program?")
                .foregroundStyle(Theme.muted)
            Spacer()
            Button { step = .goals } label: { Label("Talk to Lele about my goals", systemImage: "sparkles") }
                .buttonStyle(PrimaryButtonStyle())
            Button { step = .link } label: { Label("I have a code from my physio", systemImage: "stethoscope") }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var linkClinician: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Join your physio's program").font(.laileTitle)
            Text("Enter the code from your physiotherapist or doctor. Your program, limits and medicines come from them, and they see how you're getting on.")
                .foregroundStyle(Theme.muted)
            TextField("LAI-XXXXXX", text: $inviteCode)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .font(.title3.monospaced())
                .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
            Spacer()
            Button(working ? "Joining…" : "Join and continue") {
                Task {
                    working = true
                    defer { working = false }
                    do {
                        try await app.link(inviteCode: inviteCode.trimmingCharacters(in: .whitespaces))
                        firstProgram = app.activeEnrollments.first(where: \.isSupervised)
                        error = nil
                        step = .permissions
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(inviteCode.trimmingCharacters(in: .whitespaces).count < 6 || working)
            Button("I don't have a code") { error = nil; step = .goals }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Camera and voice").font(.laileTitle)
            Label("The camera counts your reps and measures how far your joints move. Video never leaves your phone.", systemImage: "camera.fill")
            Label("The microphone lets you talk to Lele and tell it how things feel mid-exercise: \"it's pulling\", \"sharp pain\".", systemImage: "mic.fill")
            Label("Speech recognition turns what you say into notes and safety checks.", systemImage: "waveform")
            Spacer()
            Button(firstProgram == nil ? "Allow camera and microphone" : "Allow, then start my check-in") {
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
        let program = firstProgram
        Task {
            await app.refresh()
            if let program { app.start(program) }
        }
    }
}
