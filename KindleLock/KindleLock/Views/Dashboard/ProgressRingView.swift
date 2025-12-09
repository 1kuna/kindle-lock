import SwiftUI

/// Custom shape that creates an arc stroke as a filled path (for glass effect)
struct ArcShape: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let lineWidth: CGFloat

    var animatableData: Double {
        get { endAngle.degrees }
        set { }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2

        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle, clockwise: false)

        // Convert stroke to filled shape so glass effect only covers the arc
        return path.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}

/// Animated arc progress indicator showing reading progress
struct ProgressRingView: View {
    @Environment(AppState.self) private var appState

    private let arcSize: CGFloat = 260
    private let lineWidth: CGFloat = 28

    // Arc spans 270° - from 135° (bottom-left) to 45° (bottom-right)
    private let trackStartAngle: Angle = .degrees(135)
    private let trackEndAngle: Angle = .degrees(45)

    var body: some View {
        VStack(spacing: 16) {
            // Arc with content inside
            ZStack {
                // 1. Background track - simple dark stroke (no glass, avoids morphing)
                ArcShape(startAngle: trackStartAngle, endAngle: trackEndAngle, lineWidth: lineWidth)
                    .fill(Color.gray.opacity(0.3))

                // 2. Green-tinted glass for progress only
                Color.clear
                    .frame(width: arcSize, height: arcSize)
                    .glassEffect(
                        .regular.tint(.green),
                        in: ArcShape(startAngle: trackStartAngle, endAngle: progressEndAngle, lineWidth: lineWidth)
                    )
                    .animation(.spring(duration: 0.8, bounce: 0.2), value: appState.progressFraction)

                // Content centered in the arc area
                centerContent
                    .offset(y: 10)  // Center vertically within the arc bowl
            }
            .frame(width: arcSize, height: arcSize)

            // Status label
            statusLabel
        }
    }

    /// Calculate the end angle for the progress arc
    private var progressEndAngle: Angle {
        // Progress goes from 135° to 45° (270° span, going clockwise through 0°)
        // At 0% progress: end at 135°
        // At 100% progress: end at 45° (which is 135° + 270° = 405° = 45°)
        let progressDegrees = 270 * min(1.0, appState.progressFraction)
        return .degrees(135 + progressDegrees)
    }

    // MARK: - Center Content

    private var centerContent: some View {
        VStack(spacing: 4) {
            if appState.isLoading {
                ProgressView()
                    .scaleEffect(1.5)
            } else {
                // Percentage read today
                Text(formatPercentage(appState.percentageRead))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .animation(.spring, value: appState.percentageRead)

                // Goal
                Text("of \(formatPercentage(appState.percentageGoal)) goal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Status Label

    private var statusLabel: some View {
        Group {
            if appState.goalMet {
                Label("Goal Complete!", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                Text("\(formatPercentage(appState.percentageRemaining)) to go")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(appState.goalMet ? .green.opacity(0.2) : .clear).interactive())
        .animation(.spring, value: appState.goalMet)
    }

    // MARK: - Helpers

    private func formatPercentage(_ value: Double) -> String {
        return String(format: "%.1f%%", value)
    }

}

#Preview("In Progress") {
    ProgressRingView()
        .environment(AppState())
        .padding()
}

#Preview("Goal Met") {
    let state = AppState()
    return ProgressRingView()
        .environment(state)
        .padding()
}
