import AppCore
import DesignSystem
import LaileCore
import PoseKit
import SwiftUI

public struct StreamsModule: FeatureModule {
    public init() {}
    public var id: String { "streams" }
    public var tab: FeatureTab? { FeatureTab(title: "Streams", systemImage: "dot.radiowaves.left.and.right", order: 1) }
    public func makeRootView(app: AppModel) -> AnyView { AnyView(StreamsView(app: app)) }
}

struct StreamsView: View {
    @Bindable var app: AppModel
    @State private var open: StreamEvent?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Follow along with a coach and everyone else doing the same move at the same moment. Your camera counts your reps.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                        Button {
                            open = DemoStreams.practice(startingAt: app.now.addingTimeInterval(8), gentle: app.mode == .rehab || app.settings.gentleOnly)
                        } label: {
                            Label("Practice stream — starts now", systemImage: "play.circle.fill")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        section("Live now", streams(where: { if case .live = $0 { return true }; return false }))
                        section("Starting soon", streams(where: { if case .lobby = $0 { return true }; return false }))
                        section("Later today", streams(where: { if case .upcoming = $0 { return true }; return false }))
                    }
                    .padding(16)
                }
            }
            .screenBackground()
            .navigationTitle("Streams")
            .refreshable { await app.refresh() }
            .fullScreenCover(item: $open) { stream in StreamRoomView(stream: stream, app: app) }
            .onChange(of: app.streamToOpen, initial: true) { _, stream in
                if let stream { open = stream; app.streamToOpen = nil }
            }
        }
    }

    private func streams(where match: (StreamPhase) -> Bool) -> [StreamEvent] {
        app.streams.filter { match(StreamClock.phase(of: $0, at: app.now)) }
    }

    @ViewBuilder private func section(_ title: String, _ streams: [StreamEvent]) -> some View {
        if !streams.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.laileHeadline).foregroundStyle(Theme.text)
                ForEach(streams) { stream in
                    let blocked = violations(stream)
                    Button { if blocked.isEmpty { open = stream } } label: {
                        StreamRow(stream: stream, now: app.now, blockedReason: blocked.first?.message)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Rehab patients only see streams their clinician's precautions allow.
    private func violations(_ stream: StreamEvent) -> [ProgramViolation] {
        var precautions = app.today?.program?.precautions
        if precautions == nil && app.settings.gentleOnly { precautions = Precautions(maxImpact: .low) }
        guard let precautions else { return [] }
        return StreamEligibility.violations(for: stream, precautions: precautions)
    }
}

struct StreamRow: View {
    let stream: StreamEvent
    let now: Date
    let blockedReason: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    statusPill
                    Spacer()
                    IntensityDots(stream.intensity)
                }
                Text(stream.title).font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                Text(stream.summary).font(.subheadline).foregroundStyle(Theme.muted)
                HStack(spacing: 12) {
                    Label(stream.hostName, systemImage: "person.fill")
                    Label("\(stream.minutes) min", systemImage: "clock")
                    Label("\(stream.segments.filter { !$0.isRest }.count) moves", systemImage: "figure.mixed.cardio")
                }
                .font(.caption).foregroundStyle(Theme.muted)
                if let blockedReason {
                    Label("Not in your plan: \(blockedReason)", systemImage: "lock.fill").font(.caption).foregroundStyle(Theme.warn)
                }
            }
        }
        .opacity(blockedReason == nil ? 1 : 0.6)
    }

    @ViewBuilder private var statusPill: some View {
        switch StreamClock.phase(of: stream, at: now) {
        case .live(let p):
            Pill("● LIVE · \(Int(p.totalElapsed / 60)):\(String(format: "%02d", Int(p.totalElapsed) % 60)) in", color: .white, background: Theme.live)
        case .lobby(let s):
            Pill("Lobby · starts in \(Int(s / 60)):\(String(format: "%02d", Int(s) % 60))", color: Theme.warn, background: Theme.rewardSoft)
        case .upcoming:
            Pill(stream.scheduledStart.formatted(date: .omitted, time: .shortened))
        case .ended:
            Pill("Ended")
        }
    }
}

struct StreamRoomView: View {
    @State private var model: StreamRoomModel
    @Environment(\.dismiss) private var dismiss

    init(stream: StreamEvent, app: AppModel) {
        _model = State(initialValue: StreamRoomModel(stream: stream, app: app))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                header
                hostStage
                if model.joined { myCamera }
                leaderboard
                Spacer(minLength: 0)
                footer
            }
            .padding(16)
            if model.finished, let result = model.result {
                StreamResultOverlay(result: result) { close() }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.open(); UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func close() {
        Task {
            await model.leave()
            dismiss()
        }
    }

    private var header: some View {
        HStack {
            Button { close() } label: { Image(systemName: "xmark").font(.headline).padding(10).background(.white.opacity(0.12), in: Circle()) }
                .accessibilityLabel("Leave stream")
            VStack(alignment: .leading, spacing: 0) {
                Text(model.stream.title).font(.headline)
                Text("with \(model.stream.hostName) · \(model.participants) moving").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            if case .live = model.phase { Pill("● LIVE", color: .white, background: Theme.live) }
        }
        .foregroundStyle(.white)
    }

    /// The host panel. With a host video (TRTC live or a premiere file) this would show it; the
    /// built-in schedule uses an animated exercise card driven by the shared clock.
    @ViewBuilder private var hostStage: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .upcoming(let s), .lobby(let s):
                Text("Starts in").font(.headline).foregroundStyle(.white.opacity(0.7))
                Text(clock(s)).font(.system(size: 64, weight: .heavy, design: .rounded)).monospacedDigit()
                Text("Set your phone up so it can see your whole body.").font(.subheadline).foregroundStyle(.white.opacity(0.7))
            case .live(let p):
                let segment = model.stream.segments[p.segmentIndex]
                if segment.isRest {
                    Image(systemName: "wind").font(.system(size: 44)).foregroundStyle(Theme.accent)
                    Text("Rest").font(.laileTitle)
                    if let next = model.nextSegment, let spec = ExerciseLibrary.standard.spec(next.exerciseId) {
                        Text("Next: \(spec.name)").foregroundStyle(.white.opacity(0.75))
                    }
                } else if let spec = model.spec {
                    Image(systemName: spec.symbol).font(.system(size: 48)).foregroundStyle(Theme.accent)
                        .symbolEffect(.pulse, options: .repeating)
                    Text(spec.name).font(.laileTitle)
                    if let line = segment.coachLine { Text("“\(line)”").font(.subheadline).foregroundStyle(.white.opacity(0.75)) }
                }
                Text(clock(p.segmentRemaining)).font(.system(size: 54, weight: .heavy, design: .rounded)).monospacedDigit()
                ProgressView(value: p.totalElapsed, total: Double(model.stream.durationSeconds)).tint(Theme.accent)
            case .ended:
                Image(systemName: "flag.checkered").font(.system(size: 44))
                Text("Stream finished").font(.laileTitle)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
    }

    private var myCamera: some View {
        HStack(spacing: 12) {
            ZStack {
                if let session = model.pose.captureSession { CameraPreview(session: session) } else { SimulatedCameraBackdrop() }
                SkeletonOverlay(frame: model.latestFrame, mirrored: model.pose.isFrontCamera)
            }
            .frame(width: 110, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                if model.spec?.kind.isHold == true {
                    Text("\(Int(model.segmentHold))s").font(.system(size: 48, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                    Text("held this round").font(.caption).foregroundStyle(.white.opacity(0.7))
                } else {
                    Text("\(model.segmentReps)").font(.system(size: 48, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                    Text("reps this round").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Text("\(model.totalReps) verified in total").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                if let error = model.cameraError { Text(error).font(.caption2).foregroundStyle(Theme.danger) }
            }
            Spacer()
        }
        .foregroundStyle(.white)
    }

    private var leaderboard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera-verified reps").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
            ForEach(visibleLeaderboard, id: \.1.id) { index, entry in
                HStack {
                    Text("\(index + 1)").font(.caption.weight(.heavy)).frame(width: 20)
                    Text(entry.displayName).fontWeight(entry.isYou ? .heavy : .regular)
                    Spacer()
                    Text("\(entry.verifiedReps)").monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(entry.isYou ? Theme.accent : .white)
            }
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }

    /// Top five, plus your own row if you're further down.
    private var visibleLeaderboard: [(Int, LeaderboardEntry)] {
        let ranked = Array(model.leaderboard.enumerated())
        var rows = Array(ranked.prefix(5))
        if let you = ranked.first(where: { $0.element.isYou }), you.offset >= 5 { rows.append(you) }
        return rows.map { ($0.offset, $0.element) }
    }

    @ViewBuilder private var footer: some View {
        if !model.joined {
            switch model.phase {
            case .ended:
                Button("Close") { close() }.buttonStyle(PrimaryButtonStyle())
            default:
                Button { Task { await model.join() } } label: {
                    Label(isLive ? "Join now" : "Join the lobby", systemImage: "figure.run")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        } else if case .ended = model.phase, model.result == nil {
            ProgressView("Saving…").tint(.white).foregroundStyle(.white)
        }
    }

    private var isLive: Bool { if case .live = model.phase { return true }; return false }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

struct StreamResultOverlay: View {
    let result: API.SessionSubmitResponse
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "trophy.fill").font(.system(size: 50)).foregroundStyle(Theme.reward)
            Text("Stream complete!").font(.laileTitle)
            Text("+\(result.movement.xpAwarded) XP · \(result.movement.moveStreak.current)-day streak").font(.headline).foregroundStyle(Theme.reward)
            ForEach(result.movement.newBadges) { badge in Label(badge.title, systemImage: badge.symbol) }
            Button("Done", action: onClose).buttonStyle(PrimaryButtonStyle())
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .padding(24)
        .overlay { Confetti() }
    }
}
