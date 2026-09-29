import AppCore
import Charts
import DesignSystem
import LaileCore
import SwiftUI

public struct ProgressModule: FeatureModule {
    public init() {}
    public var id: String { "progress" }
    public var tab: FeatureTab? { FeatureTab(title: "Progress", systemImage: "chart.line.uptrend.xyaxis", order: 2) }
    public func makeRootView(app: AppModel) -> AnyView { AnyView(ProgressScreen(app: app)) }
}

struct ProgressScreen: View {
    @Bindable var app: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    baselineCard
                    if let trends = app.progress?.trends, !trends.isEmpty {
                        ForEach(trends, id: \.kind) { TrendCard(trend: $0) }
                    } else {
                        Card { Text("Finish a session and your numbers will show up here.").foregroundStyle(Theme.muted) }
                    }
                    CareNotesCard(app: app)
                    if let badges = app.rewards?.badges { BadgesCard(badges: badges) }
                    if let sessions = app.progress?.recentSessions, !sessions.isEmpty { RecentSessionsCard(sessions: sessions) }
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Progress")
            .refreshable { await app.refresh() }
        }
    }

    private var baselineCard: some View {
        let template = SessionTemplate.builtIn(app.mode == .rehab ? "knee-baseline" : "move-baseline")!
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(app.mode == .rehab ? "Knee check-in" : "Fitness check", systemImage: "ruler").font(.laileHeadline).foregroundStyle(Theme.text)
                Text(app.mode == .rehab
                     ? "Measure your knee bend and straightening with the camera. Every couple of weeks is plenty."
                     : "Max push-ups, squats and plank hold. Re-test every two weeks to see how far you've come.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                Button { app.start(.template(template)) } label: { Label("Take the \(template.minutes)-minute check", systemImage: "camera.viewfinder") }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

struct TrendCard: View {
    let trend: MetricTrend

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(trend.kind.displayName).font(.laileHeadline).foregroundStyle(Theme.text)
                    Spacer()
                    if let latest = trend.latest {
                        Text(trend.kind.format(latest.value)).font(.title2.weight(.heavy)).foregroundStyle(Theme.text)
                    }
                }
                if let delta = trend.improvementFromBaseline, trend.samples.count > 1 {
                    Label("\(delta >= 0 ? "+" : "−")\(trend.kind.format(abs(delta))) since your baseline",
                          systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(delta >= 0 ? Theme.accent : Theme.warn)
                }
                chart.frame(height: 160)
                ForEach(trend.flags, id: \.self) { flag in
                    Label(flag.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Theme.warn)
                }
                if let next = trend.nextMilestone {
                    Label("Next milestone: \(next.title)", systemImage: "flag").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var chart: some View {
        let pbs = Set(trend.personalBestIds)
        return Chart {
            if let baseline = trend.baseline {
                RuleMark(y: .value("Baseline", baseline.value))
                    .foregroundStyle(Theme.muted.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .bottom, alignment: .leading) { Text("baseline").font(.caption2).foregroundStyle(Theme.muted) }
            }
            if let next = trend.nextMilestone {
                RuleMark(y: .value("Goal", next.threshold))
                    .foregroundStyle(Theme.reward.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .annotation(position: .top, alignment: .trailing) { Text("goal").font(.caption2).foregroundStyle(Theme.reward) }
            }
            ForEach(trend.samples) { sample in
                LineMark(x: .value("Date", sample.date), y: .value(trend.kind.displayName, sample.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.accent)
                PointMark(x: .value("Date", sample.date), y: .value(trend.kind.displayName, sample.value))
                    .symbolSize(pbs.contains(sample.id) ? 90 : 30)
                    .foregroundStyle(pbs.contains(sample.id) ? Theme.reward : Theme.accent)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .accessibilityLabel("\(trend.kind.displayName) over time")
    }
}

struct BadgesCard: View {
    let badges: [BadgeStatus]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Badges · \(badges.filter(\.isEarned).count)/\(badges.count)").font(.laileHeadline).foregroundStyle(Theme.text)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                    ForEach(badges) { status in
                        VStack(spacing: 6) {
                            Image(systemName: status.badge.symbol)
                                .font(.title2)
                                .frame(width: 52, height: 52)
                                .background(status.isEarned ? Theme.rewardSoft : Theme.surface2, in: Circle())
                                .foregroundStyle(status.isEarned ? Theme.reward : Theme.muted.opacity(0.5))
                            Text(status.badge.title).font(.caption2).multilineTextAlignment(.center).foregroundStyle(status.isEarned ? Theme.text : Theme.muted)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(status.badge.title): \(status.badge.detail). \(status.isEarned ? "Earned" : "Not yet earned")")
                    }
                }
            }
        }
    }
}

struct RecentSessionsCard: View {
    let sessions: [SessionSummary]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent sessions").font(.laileHeadline).foregroundStyle(Theme.text)
                ForEach(sessions) { session in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(session.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text("\(session.verifiedReps) reps").font(.subheadline).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}
