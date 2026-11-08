import SwiftUI

@main
struct CablgramApp: App {
    @StateObject private var steps = StepStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(steps)
                .tint(.brand)
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            NewsView()
                .tabItem { Label("News", systemImage: "newspaper.fill") }
            WalkView()
                .tabItem { Label("Walk", systemImage: "figure.walk") }
            RoutesView()
                .tabItem { Label("Routes", systemImage: "map.fill") }
        }
    }
}

extension Color {
    /// Cablgram pink (#FF2684), from the asset catalog.
    static let brand = Color("Brand")
}
