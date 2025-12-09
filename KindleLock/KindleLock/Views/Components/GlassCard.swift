import SwiftUI

/// Reusable glass card container component
struct GlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    @ViewBuilder let content: () -> Content

    init(
        cornerRadius: CGFloat = 20,
        tint: Color? = nil,
        interactive: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.interactive = interactive
        self.content = content
    }

    var body: some View {
        content()
            .padding(20)
            .glassEffect(glassStyle, in: .rect(cornerRadius: cornerRadius))
    }

    private var glassStyle: Glass {
        var style = Glass.regular
        if let tint = tint {
            style = style.tint(tint)
        }
        if interactive {
            style = style.interactive()
        }
        return style
    }
}

/// Preview helper
#Preview {
    VStack(spacing: 20) {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Default Glass Card")
                    .font(.headline)
                Text("This uses the default glass effect")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        GlassCard(tint: .blue.opacity(0.2)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tinted Glass Card")
                    .font(.headline)
                Text("This uses a blue tint")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        GlassCard(cornerRadius: 12, tint: .green.opacity(0.15)) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Success!")
                    .font(.subheadline.weight(.medium))
            }
        }
    }
    .padding()
}
