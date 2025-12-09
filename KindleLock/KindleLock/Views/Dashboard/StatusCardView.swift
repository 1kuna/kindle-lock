import SwiftUI

/// Card showing lock status and blocked apps count
struct StatusCardView: View {
    @Environment(AppState.self) private var appState

    let onEditApps: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Lock status header
            lockStatusHeader

            Divider()

            // Blocked apps info
            blockedAppsRow

            // Categories if any
            if !appState.blockedApps.categoryTokens.isEmpty {
                Divider()
                categoriesRow
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(statusColor.opacity(0.1)).interactive(), in: .rect(cornerRadius: 20))
    }

    // MARK: - Lock Status Header

    private var lockStatusHeader: some View {
        HStack(spacing: 12) {
            // Lock icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: appState.goalMet ? "lock.open.fill" : "lock.fill")
                    .font(.title3)
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.goalMet ? "Apps Unlocked" : "Apps Blocked")
                    .font(.headline)

                Text(appState.goalMet ? "Keep up the great reading!" : "Complete your reading goal to unlock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .animation(.spring, value: appState.goalMet)
    }

    // MARK: - Blocked Apps Row

    private var blockedAppsRow: some View {
        HStack {
            Label {
                Text("Blocked apps")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "app.fill")
                    .foregroundStyle(.blue)
            }
            .font(.subheadline)

            Spacer()

            Text("\(appState.blockedApps.applicationTokens.count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())

            Button(action: onEditApps) {
                Image(systemName: "pencil.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.glass)
        }
    }

    // MARK: - Categories Row

    private var categoriesRow: some View {
        HStack {
            Label {
                Text("Categories")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundStyle(.purple)
            }
            .font(.subheadline)

            Spacer()

            Text("\(appState.blockedApps.categoryTokens.count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        appState.goalMet ? .green : .red
    }
}

#Preview {
    StatusCardView(onEditApps: {})
        .environment(AppState())
        .padding()
}
