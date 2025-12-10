import SwiftUI
import FamilyControls
import BackgroundTasks

@main
struct KindleLockApp: App {
    @State private var appState = AppState()

    init() {
        // Register background refresh task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Constants.BackgroundTasks.refresh,
            using: nil
        ) { task in
            Task { @MainActor in
                await handleBackgroundRefresh(task: task as! BGAppRefreshTask)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task {
                    await requestFamilyControlsAuthorization()
                    // Only refresh if authenticated
                    if appState.isAuthenticated {
                        await appState.refreshProgress()
                    }
                    scheduleBackgroundRefresh()
                }
        }
    }

    // MARK: - FamilyControls Authorization

    private func requestFamilyControlsAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            appState.authorizationStatus = .approved
            print("FamilyControls authorization granted")
            appState.forceUpdateShields()
        } catch {
            appState.authorizationStatus = .denied
            print("FamilyControls authorization failed: \(error)")
            print("User needs to enable Screen Time in Settings > Screen Time")
        }
    }

    // MARK: - Background Refresh

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Constants.BackgroundTasks.refresh)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes

        do {
            try BGTaskScheduler.shared.submit(request)
            print("Background refresh scheduled")
        } catch {
            print("Could not schedule background refresh: \(error)")
        }
    }
}

@MainActor
private func handleBackgroundRefresh(task: BGAppRefreshTask) async {
    // Schedule the next refresh
    let request = BGAppRefreshTaskRequest(identifier: Constants.BackgroundTasks.refresh)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)

    // Create a temporary app state for background refresh
    let backgroundState = AppState()

    // Only refresh if authenticated
    guard backgroundState.isAuthenticated else {
        task.setTaskCompleted(success: true)
        return
    }

    let refreshTask = Task {
        await backgroundState.refreshProgress()
    }

    task.expirationHandler = {
        refreshTask.cancel()
    }

    await refreshTask.value
    // Note: Notification is sent from calculateTodayProgress() when goal is first met
    task.setTaskCompleted(success: true)
}
