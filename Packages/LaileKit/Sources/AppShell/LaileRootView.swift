import AppCore
import DesignSystem
import LaileCore
import ProfileFeature
import ProgressFeature
import SessionFeature
import StreamsFeature
import SwiftUI
import TodayFeature

/// Every feature the app ships. Add a module here to add a tab.
@MainActor
public enum FeatureRegistry {
    public static var modules: [any FeatureModule] = [
        TodayModule(),
        StreamsModule(),
        ProgressModule(),
        ProfileModule(),
    ]
}

public struct LaileRootView: View {
    @State private var app = AppModel()

    public init() {}

    public var body: some View {
        Group {
            if app.settings.onboardingComplete {
                tabs
            } else {
                OnboardingView(app: app)
            }
        }
        .tint(Theme.accent)
        .task { await app.refresh() }
        .fullScreenCover(item: $app.activeSession) { launch in
            SessionView(launch: launch, app: app)
        }
    }

    private var tabs: some View {
        TabView(selection: $app.selectedTab) {
            ForEach(FeatureRegistry.modules.filter { $0.tab != nil }.sorted { $0.tab!.order < $1.tab!.order }, id: \.id) { module in
                module.makeRootView(app: app)
                    .tabItem { Label(module.tab!.title, systemImage: module.tab!.systemImage) }
                    .tag(module.id)
            }
        }
    }
}
