import SwiftUI

/// App settings view
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var dailyGoal: Double = 5.0
    @State private var showingResetAlert = false
    @State private var showingReauth = false
    @State private var loggingEnabled = DebugLogger.shared.isEnabled
    @State private var showingExportSheet = false
    @State private var exportURL: URL?
    @ObservedObject private var authService = KindleAuthService.shared

    private let goalOptions: [Double] = [1, 2, 3, 5, 7, 10, 15, 20]

    var body: some View {
        NavigationStack {
            Form {
                // Account section
                Section {
                    HStack {
                        Image(systemName: authService.isAuthenticated ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(authService.isAuthenticated ? .green : .red)
                        Text(authService.isAuthenticated ? "Connected to Amazon" : "Not connected")
                        Spacer()
                        Button(authService.isAuthenticated ? "Change" : "Sign In") {
                            showingReauth = true
                        }
                        .buttonStyle(.glass)
                    }
                } header: {
                    Label("Amazon Account", systemImage: "person.circle")
                }

                // Reading goal section
                Section {
                    Picker("Daily goal", selection: $dailyGoal) {
                        ForEach(goalOptions, id: \.self) { value in
                            Text("\(Int(value))%").tag(value)
                        }
                    }
                } header: {
                    Label("Reading Goal", systemImage: "book")
                } footer: {
                    Text("The percentage of your book you need to read each day to unlock your apps.")
                }

                // Info section
                Section {
                    HStack {
                        Text("Reset Time")
                        Spacer()
                        Text("4:00 AM")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Blocked Apps")
                        Spacer()
                        Text("\(appState.blockedApps.applicationTokens.count)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Info", systemImage: "info.circle")
                }

                // Library scan section
                Section {
                    Button {
                        Task {
                            await appState.performDeepScan()
                        }
                    } label: {
                        HStack {
                            if appState.isDeepScanning {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.trailing, 4)
                                Text("Scanning...")
                            } else {
                                Text("Scan Full Library")
                            }
                            Spacer()
                            if !appState.isDeepScanning {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(appState.isDeepScanning || !authService.isAuthenticated)

                    if let lastScan = appState.lastDeepScanDate {
                        HStack {
                            Text("Last Full Scan")
                            Spacer()
                            Text(lastScan, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label("Library", systemImage: "books.vertical")
                } footer: {
                    Text("Full scan checks all books in your library. This runs automatically overnight while charging, or you can trigger it manually.")
                }

                // About section
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.appVersion)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("About", systemImage: "questionmark.circle")
                }

                // Developer section
                Section {
                    Toggle("Enable Logging", isOn: $loggingEnabled)
                        .onChange(of: loggingEnabled) { _, newValue in
                            DebugLogger.shared.isEnabled = newValue
                        }

                    NavigationLink {
                        DebugLogView()
                    } label: {
                        HStack {
                            Text("View Logs")
                            Spacer()
                            Text("\(DebugLogger.shared.entries.count)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Export Logs") {
                        exportURL = DebugLogger.shared.export()
                        showingExportSheet = true
                    }

                    Button("Clear Logs", role: .destructive) {
                        DebugLogger.shared.clear()
                    }
                } header: {
                    Label("Developer", systemImage: "hammer")
                } footer: {
                    Text("Debug logging captures API calls and progress calculations to help diagnose issues.")
                }

                // Reset section
                Section {
                    Button("Reset Setup", role: .destructive) {
                        showingResetAlert = true
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                } footer: {
                    Text("This will sign out and clear all settings.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                dailyGoal = appState.percentageGoal
            }
            .onChange(of: dailyGoal) { _, newValue in
                // Save the new goal to settings
                SettingsStore().dailyPercentageGoal = newValue
            }
            .alert("Reset Setup?", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    appState.resetSetup()
                    dismiss()
                }
            } message: {
                Text("This will sign out and clear all your settings and blocked apps. You'll need to set up the app again.")
            }
            .sheet(isPresented: $showingReauth) {
                AmazonLoginView { success in
                    if success {
                        Task { await appState.refreshProgress() }
                    }
                }
            }
            .sheet(isPresented: $showingExportSheet) {
                if let url = exportURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }
}

// MARK: - Share Sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Bundle Extension

extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
