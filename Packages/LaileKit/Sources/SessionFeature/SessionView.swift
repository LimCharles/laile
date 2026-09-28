import AppCore
import DesignSystem
import LaileCore
import PoseKit
import SwiftUI

/// Full-screen workout: camera + skeleton, one huge number, a spoken coach you can talk to.
public struct SessionView: View {
    @State private var model: SessionViewModel
    @Environment(\.dismiss) private var dismiss

    public init(launch: SessionLaunch, app: AppModel) {
        _model = State(initialValue: SessionViewModel(launch: launch, app: app))
    }

    public var body: some View {
        Group {
            switch model.stage {
            case .painBefore:
                PainScaleView(title: "Before we start", question: "How much pain are you in right now?", onPick: model.setPainBefore)
            case .running:
                RunningSessionView(model: model, onClose: close)
            case .painAfter:
                PainScaleView(title: "Nice work", question: "How much pain are you in now that you've finished?", onPick: model.setPainAfter)
            case .submitting:
                ProgressView("Saving your session…").frame(maxWidth: .infinity, maxHeight: .infinity).screenBackground()
            case .done:
                SessionResultView(model: model, onDone: close)
            }
        }
        .task {
            model.warmUp()
            if model.stage == .running { await model.begin() }
        }
        .onDisappear { model.teardown() }
        .statusBarHidden(model.stage == .running)
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }

    private func close() {
        UIApplication.shared.isIdleTimerDisabled = false
        model.teardown()
        dismiss()
    }
}

struct RunningSessionView: View {
    @Bindable var model: SessionViewModel
    let onClose: () -> Void
    @State private var confirmEnd = false

    var body: some View {
        ZStack {
            camera
            VStack(spacing: 12) {
                topBar
                if let error = model.cameraError { errorBanner(error) }
                Spacer()
                if let toast = model.toast {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                hud
                captions
                controls
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .animation(.snappy, value: model.toast)
        .confirmationDialog("End this session?", isPresented: $confirmEnd) {
            Button("End and save what I did") { model.endEarly() }
            Button("Leave without saving", role: .destructive) { onClose() }
        }
    }

    private var camera: some View {
        ZStack {
            if let session = model.pose.captureSession {
                CameraPreview(session: session)
            } else {
                SimulatedCameraBackdrop()
            }
            SkeletonOverlay(frame: model.latestFrame, highlight: model.highlightedJoints, mirrored: model.mirrored,
                            angleLabel: model.snapshot.angle.map { "\(Int($0.rounded()))°" })
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button { confirmEnd = true } label: {
                Image(systemName: "xmark").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("End session")
            VStack(alignment: .leading, spacing: 2) {
                Text(model.snapshot.exerciseName).font(.title3.weight(.bold))
                Text("Exercise \(min(model.snapshot.exerciseIndex + 1, max(model.snapshot.exerciseCount, 1))) of \(model.snapshot.exerciseCount) · Set \(model.snapshot.setIndex + 1) of \(max(model.snapshot.totalSets, 1))")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            Spacer()
            if model.listening {
                Image(systemName: "waveform").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .accessibilityLabel("Listening — tell me how it feels")
            }
        }
        .foregroundStyle(.white)
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.white)
            .padding(10).frame(maxWidth: .infinity).background(Theme.danger.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var hud: some View {
        let s = model.snapshot
        Group {
            switch s.phase {
            case .setup:
                SetupHUD(issues: s.setupIssues, exercise: model.currentExercise)
            case .countdown(let remaining):
                Text(remaining >= 4 ? "Get ready" : "\(remaining)")
                    .font(remaining >= 4 ? .laileTitle : .system(size: 110, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
            case .active:
                if s.isHold { HoldHUD(snapshot: s) } else { RepHUD(snapshot: s, pulse: model.repPulse) }
            case .rest:
                VStack(spacing: 4) {
                    Text("Rest").font(.laileTitle)
                    Text("\(s.restRemaining ?? 0)").font(.system(size: 80, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                    Text("Next: set \(s.setIndex + 2) of \(s.totalSets)").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
            case .paused(let reason):
                PausedHUD(reason: reason, model: model)
            case .finished:
                Text("Done!").font(.laileTitle).frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var captions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.caption.isEmpty {
                Label(model.caption, systemImage: "person.wave.2.fill").font(.callout).lineLimit(3)
            }
            if !model.heard.isEmpty {
                Label("“\(model.heard)”", systemImage: "mic.fill").font(.callout).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SessionViewModel.QuickReply.allCases) { reply in
                        Button(reply.rawValue) { model.quickReply(reply) }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(reply == .sharp || reply == .wrong ? Theme.danger.opacity(0.35) : Color.white.opacity(0.15), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            HStack(spacing: 10) {
                Button { model.togglePause() } label: {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(color: .white.opacity(0.18)))
                Button { model.skip() } label: {
                    Label("Skip", systemImage: "forward.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(color: .white.opacity(0.18)))
            }
        }
    }
}

struct SetupHUD: View {
    let issues: [SetupIssue]
    let exercise: PlannedExercise?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Camera setup", systemImage: "camera.viewfinder").font(.headline)
            Text(issues.first?.guidance.text ?? "Hold still — checking I can see you…").font(.title3.weight(.semibold))
            if let exercise {
                Text(exercise.spec.posture.cameraTip).font(.subheadline).foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RepHUD: View {
    let snapshot: ConductorSnapshot
    let pulse: Int

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(snapshot.reps)")
                    .font(.system(size: 96, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText())
                    .scaleEffect(pulse % 2 == 0 ? 1 : 1.06)
                    .animation(.spring(duration: 0.25), value: pulse)
                Text("of \(snapshot.targetReps ?? 0) reps").font(.headline).foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            // Depth meter: how far through the rep you are right now.
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.15)).frame(width: 22, height: 120)
                    Capsule().fill(snapshot.repProgress >= 1 ? Theme.accent : Theme.reward)
                        .frame(width: 22, height: 120 * max(0.05, min(1, snapshot.repProgress)))
                        .animation(.linear(duration: 0.08), value: snapshot.repProgress)
                }
                Text("depth").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
            .accessibilityHidden(true)
        }
    }
}

struct HoldHUD: View {
    let snapshot: ConductorSnapshot

    var body: some View {
        let target = Double(snapshot.targetHoldSeconds ?? 30)
        HStack(spacing: 18) {
            ZStack {
                RingProgress(progress: snapshot.holdSeconds / max(target, 1), lineWidth: 12, color: snapshot.isHolding ? Theme.accent : Theme.warn)
                Text("\(Int(snapshot.holdSeconds))").font(.system(size: 44, weight: .heavy, design: .rounded)).contentTransition(.numericText())
            }
            .frame(width: 118, height: 118)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.isHolding ? "Hold…" : "Get into position").font(.title2.weight(.bold))
                Text("\(Int(target))s target").foregroundStyle(.white.opacity(0.75))
                Text("Tell me how it feels any time.").font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
    }
}

struct PausedHUD: View {
    let reason: PauseReason
    let model: SessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch reason {
            case .awaitingPainRating:
                Text("From 0 to 10, how bad is the pain?").font(.title3.weight(.bold))
                Text("Say a number, or tap one.").font(.subheadline).foregroundStyle(.white.opacity(0.75))
                PainGrid { model.rate($0) }
            case .clarifying:
                Text("Is that a stretching feeling, or a sharp pain?").font(.title3.weight(.bold))
                HStack {
                    Button("Stretching") { model.quickReply(.stretch) }.buttonStyle(PrimaryButtonStyle(color: Theme.accent))
                    Button("Sharp pain") { model.quickReply(.sharp) }.buttonStyle(PrimaryButtonStyle(color: Theme.danger))
                }
            case .user:
                Text("Paused").font(.title2.weight(.bold))
                Text("Take your time. Tap resume when you're ready.").foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PainGrid: View {
    let onPick: (Int) -> Void
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(0...10, id: \.self) { n in
                Button("\(n)") { onPick(n) }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(PainScaleView.color(for: n).opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Pain \(n) out of 10")
            }
        }
    }
}

/// 0–10 pain rating with plain-language anchors.
struct PainScaleView: View {
    let title: String
    let question: String
    let onPick: (Int?) -> Void

    static func color(for n: Int) -> Color {
        switch n {
        case 0...3: return Theme.accent
        case 4...6: return Theme.reward
        default: return Theme.danger
        }
    }

    static func label(for n: Int) -> String {
        switch n {
        case 0: return "No pain"
        case 1...3: return "Mild"
        case 4...6: return "Moderate"
        case 7...9: return "Severe"
        default: return "Worst imaginable"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text(title).font(.laileTitle)
            Text(question).font(.title3).foregroundStyle(Theme.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(0...10, id: \.self) { n in
                    Button { onPick(n) } label: {
                        VStack(spacing: 2) {
                            Text("\(n)").font(.title2.weight(.heavy))
                            Text(Self.label(for: n)).font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .foregroundStyle(.white)
                        .background(Self.color(for: n), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .accessibilityLabel("\(n), \(Self.label(for: n))")
                }
            }
            Button("Skip") { onPick(nil) }.buttonStyle(SecondaryButtonStyle())
            Spacer()
        }
        .padding(20)
        .screenBackground()
    }
}
