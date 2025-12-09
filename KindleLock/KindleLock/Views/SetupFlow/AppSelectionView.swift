import SwiftUI
import FamilyControls

/// App selection step in setup flow using FamilyActivityPicker
struct AppSelectionView: View {
    @Environment(AppState.self) private var appState
    @State private var selection = FamilyActivitySelection()
    @State private var isRetryingAuthorization = false

    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Header
            headerSection

            // Show error or app picker based on authorization status
            if appState.authorizationStatus == .denied {
                authorizationErrorView
            } else {
                // App picker
                FamilyActivityPicker(selection: $selection)
                    .frame(maxHeight: .infinity)

                // Selection summary
                selectionSummary

                // Continue button
                continueButton
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            selection = appState.blockedApps
        }
    }

    // MARK: - Authorization Error View

    private var authorizationErrorView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)

            Text("Screen Time Access Required")
                .font(.headline)

            Text("To block apps, you need to enable Screen Time:\n\n1. Open Settings → Screen Time\n2. Enable Screen Time if not already on\n3. Return here and tap \"Retry\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                Button(action: openSettings) {
                    HStack(spacing: 8) {
                        Image(systemName: "gear")
                        Text("Open Settings")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.glass)
                .tint(.blue)

                Button(action: retryAuthorization) {
                    HStack(spacing: 8) {
                        if isRetryingAuthorization {
                            ProgressView()
                                .tint(.primary)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Retry Authorization")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.glassProminent)
                .disabled(isRetryingAuthorization)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func retryAuthorization() {
        isRetryingAuthorization = true
        Task {
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                appState.authorizationStatus = .approved
                print("FamilyControls authorization granted on retry")
            } catch {
                appState.authorizationStatus = .denied
                print("FamilyControls authorization failed on retry: \(error)")
            }
            isRetryingAuthorization = false
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 100, height: 100)
                .glassEffect(.regular.tint(.accentColor.opacity(0.3)))

            Text("Select Apps to Block")
                .font(.title2.bold())

            Text("Choose which apps will be blocked until you complete your daily reading goal.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Selection Summary

    private var selectionSummary: some View {
        HStack(spacing: 16) {
            summaryItem(
                count: selection.applicationTokens.count,
                label: "Apps",
                icon: "app.fill"
            )

            summaryItem(
                count: selection.categoryTokens.count,
                label: "Categories",
                icon: "square.grid.2x2.fill"
            )

            summaryItem(
                count: selection.webDomainTokens.count,
                label: "Websites",
                icon: "globe"
            )
        }
        .padding()
        .glassEffect(in: .rect(cornerRadius: 16))
    }

    private func summaryItem(count: Int, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text("\(count)")
                    .font(.headline.monospacedDigit())
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Continue Button

    private var continueButton: some View {
        Button(action: saveAndContinue) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.right")
                Text("Continue")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.glassProminent)
        .tint(.accentColor)
        .disabled(!hasSelection)
    }

    // MARK: - Helpers

    private var hasSelection: Bool {
        !selection.applicationTokens.isEmpty ||
        !selection.categoryTokens.isEmpty ||
        !selection.webDomainTokens.isEmpty
    }

    private func saveAndContinue() {
        appState.updateBlockedApps(selection)
        onContinue()
    }
}

#Preview {
    NavigationStack {
        AppSelectionView(onContinue: {})
            .environment(AppState())
    }
}
