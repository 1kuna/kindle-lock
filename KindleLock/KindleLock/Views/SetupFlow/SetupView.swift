import SwiftUI

/// Main setup/onboarding flow container
struct SetupView: View {
    @Environment(AppState.self) private var appState
    @State private var currentStep = 0
    @State private var showLogin = false
    @Namespace private var namespace

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Step indicator
                stepIndicator
                    .padding(.bottom, 12)

                // Pages
                TabView(selection: $currentStep) {
                    AmazonLoginStepView(onContinue: { nextStep() }, showLogin: $showLogin)
                        .tag(0)

                    AppSelectionView(onContinue: { nextStep() })
                        .tag(1)

                    ConfirmationView()
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showLogin) {
                AmazonLoginView { success in
                    if success {
                        nextStep()
                    }
                }
            }
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(0..<3) { step in
                    stepPill(for: step)
                }
            }
        }
        .frame(height: 8)
    }

    private func stepPill(for step: Int) -> some View {
        Capsule()
            .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
            .frame(width: step == currentStep ? 24 : 8, height: 8)
            .glassEffect()
            .glassEffectID("step-\(step)", in: namespace)
            .animation(.spring(duration: 0.3), value: currentStep)
    }

    // MARK: - Navigation

    private func nextStep() {
        withAnimation(.spring(duration: 0.4)) {
            if currentStep < 2 {
                currentStep += 1
            }
        }
    }
}

// MARK: - Amazon Login Step

/// Step 1: Sign in to Amazon Kindle
private struct AmazonLoginStepView: View {
    let onContinue: () -> Void
    @Binding var showLogin: Bool
    @ObservedObject private var authService = KindleAuthService.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "book.fill")
                .font(.system(size: 60))
                .foregroundStyle(.tint)

            Text("Connect Your Account")
                .font(.title2.bold())

            Text("Sign in with your Amazon account to track your reading progress.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            if authService.isAuthenticated {
                Label("Connected to Amazon", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)

                Button("Continue") {
                    onContinue()
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
                .controlSize(.large)
            } else {
                Button("Sign in to Amazon") {
                    showLogin = true
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }

            Spacer()
        }
        .padding()
    }
}

#Preview {
    SetupView()
        .environment(AppState())
}
