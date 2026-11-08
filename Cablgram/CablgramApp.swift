import SwiftUI

@main
struct CablgramApp: App {
    @StateObject private var steps = StepStore()

    init() {
        GoogleMapsConfig.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(steps)
                .tint(.brand)
        }
    }
}

enum AppTab: Hashable {
    case news, walk, routes
}

struct ContentView: View {
    @EnvironmentObject private var steps: StepStore
    @State private var tab: AppTab = .news

    var body: some View {
        TabView(selection: $tab) {
            NewsView(openWalk: { tab = .walk })
                .tabItem { Label("News", systemImage: "newspaper.fill") }
                .tag(AppTab.news)
            WalkView()
                .tabItem { Label("Walk", systemImage: "figure.walk") }
                .tag(AppTab.walk)
            RoutesView()
                .tabItem { Label("Routes", systemImage: "map.fill") }
                .tag(AppTab.routes)
        }
        .task { await steps.start() }
    }
}
