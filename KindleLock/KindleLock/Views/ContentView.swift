import SwiftUI

/// Root view that switches between setup and dashboard
struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isSetupComplete {
                DashboardView()
            } else {
                SetupView()
            }
        }
        .animation(.smooth, value: appState.isSetupComplete)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
