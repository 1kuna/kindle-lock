import SwiftUI
import FamilyControls

/// Main dashboard showing reading progress and lock status
struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @State private var showingSettings = false
    @State private var showingAppPicker = false
    @State private var showingReauth = false
    @Namespace private var namespace

    var body: some View {
        NavigationStack {
            GlassEffectContainer(spacing: 24) {
                VStack(spacing: 0) {
                    Spacer()

                    // Progress arc
                    ProgressRingView()
                        .glassEffectID("progress", in: namespace)

                    Spacer(minLength: 24)

                    // Status card
                    StatusCardView(onEditApps: { showingAppPicker = true })
                        .glassEffectID("status", in: namespace)

                    Spacer(minLength: 24)

                    // Action buttons
                    actionButtons

                    // Re-auth banner if needed
                    if appState.needsReauth {
                        reauthBanner
                            .padding(.top, 16)
                    }

                    // Error banner if needed
                    if let error = appState.lastError {
                        errorBanner(error)
                            .padding(.top, appState.needsReauth ? 8 : 16)
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
            }
            .navigationTitle("KindleLock")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingAppPicker) {
                AppPickerSheet()
            }
            .sheet(isPresented: $showingReauth) {
                AmazonLoginView { success in
                    if success {
                        Task { await appState.refreshProgress() }
                    }
                }
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                // Show progress bar when refreshing
                if let progress = appState.refreshProgress, progress.isActive {
                    refreshProgressView(progress)
                }

                HStack(spacing: 12) {
                    // Refresh button
                    Button(action: {
                        Task { await appState.triggerManualRefresh() }
                    }) {
                        HStack(spacing: 8) {
                            if appState.isLoading {
                                ProgressView()
                                    .tint(.primary)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(appState.refreshProgress != nil ? "Refreshing..." : "Refresh")
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.glass)
                    .disabled(appState.isLoading || !appState.isAuthenticated)
                    .glassEffectID("refresh-button", in: namespace)

                    // Open Kindle button
                    Button(action: openKindle) {
                        HStack(spacing: 8) {
                            Image(systemName: "book.fill")
                            Text("Read")
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.glass)
                    .tint(.orange)
                    .glassEffectID("kindle-button", in: namespace)
                }
            }
        }
    }

    @ViewBuilder
    private func refreshProgressView(_ progress: RefreshProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))

                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: progressWidth(for: progress, in: geo.size.width))
                        .animation(.spring(duration: 0.3), value: progress.currentBook)
                }
            }
            .frame(height: 6)

            // Status text
            HStack {
                Text(progress.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if progress.totalBooks > 0 {
                    Text("\(progress.currentBook)/\(progress.totalBooks)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func progressWidth(for progress: RefreshProgress, in totalWidth: CGFloat) -> CGFloat {
        guard progress.totalBooks > 0 else { return 0 }
        let fraction = CGFloat(progress.currentBook) / CGFloat(progress.totalBooks)
        return totalWidth * fraction
    }

    // MARK: - Re-auth Banner

    private var reauthBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)

            Text("Session expired")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Sign In") {
                showingReauth = true
            }
            .font(.caption.bold())
            .foregroundStyle(.orange)
        }
        .padding()
        .glassEffect(.regular.tint(.orange.opacity(0.1)), in: .rect(cornerRadius: 12))
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Retry") {
                Task { await appState.refreshProgress() }
            }
            .font(.caption.bold())
            .foregroundStyle(.orange)
        }
        .padding()
        .glassEffect(.regular.tint(.orange.opacity(0.1)), in: .rect(cornerRadius: 12))
    }

    // MARK: - Actions

    private func openKindle() {
        if let url = URL(string: Constants.URLSchemes.kindle) {
            UIApplication.shared.open(url)
        }
    }
}

/// Sheet for editing blocked apps
struct AppPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selection = FamilyActivitySelection()

    var body: some View {
        NavigationStack {
            FamilyActivityPicker(selection: $selection)
                .navigationTitle("Blocked Apps")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            appState.updateBlockedApps(selection)
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    selection = appState.blockedApps
                }
        }
    }
}

#Preview {
    DashboardView()
        .environment(AppState())
}
