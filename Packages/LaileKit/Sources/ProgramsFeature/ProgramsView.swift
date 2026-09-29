import AppCore
import DesignSystem
import LaileCore
import LeleFeature
import StreamsFeature
import SwiftUI

public struct ProgramsModule: FeatureModule {
    public init() {}
    public var id: String { "programs" }
    public var tab: FeatureTab? { FeatureTab(title: "Programs", systemImage: "square.stack.3d.up.fill", order: 1) }
    public func makeRootView(app: AppModel) -> AnyView { AnyView(ProgramsView(app: app)) }
}

/// Programs are the unit of everything: your physio's (joined with their code), one Lele built
/// for you, or one from the catalog. Live classes are here too.
struct ProgramsView: View {
    enum Route: Hashable { case liveClasses }

    @Bindable var app: AppModel
    @State private var category: ProgramCategory = .calisthenics
    @State private var detail: SessionTemplate?
    @State private var openEnrollment: Enrollment?
    @State private var showCode = false
    @State private var showGoals = false
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    mine
                    startSomething
                    explore
                    liveClasses
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Programs")
            .refreshable { await app.refresh() }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .liveClasses: StreamsView(app: app)
                }
            }
            .sheet(item: $detail) { template in
                CatalogDetailSheet(app: app, template: template) { detail = nil }
            }
            .sheet(item: $openEnrollment) { enrollment in
                EnrollmentDetailSheet(app: app, enrollment: enrollment) { openEnrollment = nil }
            }
            .sheet(isPresented: $showCode) { JoinWithCodeSheet(app: app) { showCode = false } }
            .sheet(isPresented: $showGoals) { GoalsConversationView(app: app) { enrollment in
                    showGoals = false
                    if let enrollment { app.afterSheetCloses { app.start(enrollment) } }
                } }
            .onChange(of: app.streamToOpen, initial: true) { _, stream in
                if stream != nil, path.last != .liveClasses { path.append(.liveClasses) }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var mine: some View {
        let active = app.activeEnrollments
        let finished = app.enrollments.filter { !$0.isActive }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("My programs", subtitle: active.isEmpty ? "Join one below, or let Lele build one for you." : nil)
            ForEach(active) { enrollment in
                Button { openEnrollment = enrollment } label: { EnrollmentRow(enrollment: enrollment) }.buttonStyle(.plain)
            }
            if !finished.isEmpty {
                Text("Finished").font(.caption.weight(.bold)).foregroundStyle(Theme.muted).padding(.top, 4)
                ForEach(finished) { enrollment in
                    Button { openEnrollment = enrollment } label: { EnrollmentRow(enrollment: enrollment) }.buttonStyle(.plain)
                }
            }
        }
    }

    private var startSomething: some View {
        HStack(spacing: 12) {
            if let supervisor = app.supervisorName {
                // While a physio supervises, extra programs go through them.
                tile("Want to do more?", subtitle: "Lele asks \(supervisor)", symbol: "bubble.left.and.text.bubble.right", color: Theme.accent) {
                    app.askLele("I'd like to do more alongside my program. Could you check with \(supervisor) what I can add?")
                }
            } else {
                tile("Ask Lele for a plan", subtitle: "Tell it your goals", symbol: "sparkles", color: Theme.accent) { showGoals = true }
            }
            tile("I have a code", subtitle: "From my physio", symbol: "stethoscope", color: Theme.reward) { showCode = true }
        }
    }

    private func tile(_ title: String, subtitle: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.title2).foregroundStyle(color)
                Text(title).font(.headline).foregroundStyle(Theme.text)
                Text(subtitle).font(.caption).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.surface2, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var explore: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Explore", subtitle: "Programs from Laile's coaches. Your first session sets your targets.")
            Picker("Category", selection: $category) {
                ForEach(ProgramCategory.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            let joined = Set(app.activeEnrollments.compactMap(\.catalogId))
            ForEach(SessionTemplate.catalogPrograms.filter { $0.category == category }) { template in
                Button { detail = template } label: { CatalogRow(template: template, joined: joined.contains(template.id)) }
                    .buttonStyle(.plain)
            }
        }
    }

    private var liveClasses: some View {
        let upcoming = app.streams.filter { if case .ended = StreamClock.phase(of: $0, at: app.now) { return false }; return true }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Live classes", subtitle: "Move with a coach and everyone else, at the same moment.")
            NavigationLink(value: Route.liveClasses) {
                HStack(spacing: 12) {
                    Image(systemName: "person.3.fill").font(.title2).foregroundStyle(Theme.live)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(upcoming.first?.title ?? "See today's classes").font(.headline).foregroundStyle(Theme.text)
                        Text(upcoming.isEmpty ? "Or try a practice class now" : "\(upcoming.count) coming up today")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.surface2, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
}

struct EnrollmentRow: View {
    let enrollment: Enrollment

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: enrollment.sourceSymbol)
                .font(.title3)
                .foregroundStyle(enrollment.isSupervised ? Theme.reward : Theme.accent)
                .frame(width: 44, height: 44)
                .background(enrollment.isSupervised ? Theme.rewardSoft : Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(enrollment.title).font(.headline).foregroundStyle(Theme.text)
                Text(enrollment.sourceLabel).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            if !enrollment.isActive {
                Pill("Finished")
            } else if enrollment.needsCalibration {
                Pill("Check-in first", color: Theme.reward, background: Theme.rewardSoft)
            }
            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.surface2, lineWidth: 1))
    }
}
