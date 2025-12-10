import SwiftUI

/// Final confirmation step in setup flow
struct ConfirmationView: View {
    @Environment(AppState.self) private var appState
    @Namespace private var namespace

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Success icon
            successIcon

            // Title
            Text("You're All Set!")
                .font(.title.bold())

            // Summary card
            summaryCard

            Spacer()

            // Start button
            startButton
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Success Icon

    private var successIcon: some View {
        GlassEffectContainer(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.green.opacity(0.1))
                    .frame(width: 120, height: 120)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
            }
            .glassEffect(.regular.tint(.green.opacity(0.2)))
            .glassEffectID("success-icon", in: namespace)
        }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryRow(
                icon: "checkmark.circle.fill",
                iconColor: .green,
                text: "Connected to Kindle"
            )

            Divider()

            summaryRow(
                icon: "app.badge.checkmark.fill",
                iconColor: .blue,
                text: "\(appState.blockedApps.applicationTokens.count) apps will be blocked"
            )

            Divider()

            summaryRow(
                icon: "book.fill",
                iconColor: .orange,
                text: "Read \(Int(appState.percentageGoal))% daily to unlock"
            )

            Divider()

            summaryRow(
                icon: "clock.fill",
                iconColor: .purple,
                text: "Resets at 4:00 AM each day"
            )
        }
        .padding(20)
        .glassEffect(in: .rect(cornerRadius: 20))
    }

    private func summaryRow(icon: String, iconColor: Color, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            Text(text)
                .font(.subheadline)

            Spacer()
        }
    }

    // MARK: - Start Button

    private var startButton: some View {
        Button {
            Task {
                await startApp()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                Text("Start Using KindleLock")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.glassProminent)
        .tint(.green)
    }

    // MARK: - Actions

    private func startApp() async {
        // Request notification permission (non-blocking, don't care about result)
        _ = await NotificationService.shared.requestAuthorization()

        withAnimation(.spring(duration: 0.5)) {
            appState.completeSetup()
        }
    }
}

#Preview {
    ConfirmationView()
        .environment(AppState())
}
