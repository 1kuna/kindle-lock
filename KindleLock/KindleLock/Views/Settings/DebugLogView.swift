import SwiftUI

/// View for displaying and managing debug logs
struct DebugLogView: View {
    @State private var logger = DebugLogger.shared
    @State private var selectedCategory: DebugLogger.LogEntry.Category?
    @State private var expandedEntryID: UUID?
    @State private var showingExportSheet = false
    @State private var exportURL: URL?

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        List {
            // Filter section
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(
                            title: "All",
                            isSelected: selectedCategory == nil,
                            color: .secondary
                        ) {
                            selectedCategory = nil
                        }

                        ForEach(DebugLogger.LogEntry.Category.allCases, id: \.self) { category in
                            FilterChip(
                                title: category.rawValue,
                                isSelected: selectedCategory == category,
                                color: colorForCategory(category)
                            ) {
                                selectedCategory = category
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // Log entries
            Section {
                if filteredEntries.isEmpty {
                    ContentUnavailableView(
                        "No Logs",
                        systemImage: "doc.text",
                        description: Text(logger.isEnabled ? "Logs will appear here after refreshing progress" : "Enable logging in Settings")
                    )
                } else {
                    ForEach(filteredEntries) { entry in
                        LogEntryRow(
                            entry: entry,
                            isExpanded: expandedEntryID == entry.id,
                            dateFormatter: dateFormatter,
                            fullDateFormatter: fullDateFormatter
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(duration: 0.2)) {
                                if expandedEntryID == entry.id {
                                    expandedEntryID = nil
                                } else {
                                    expandedEntryID = entry.id
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("\(filteredEntries.count) entries")
            }
        }
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: exportLogs) {
                        Label("Export Logs", systemImage: "square.and.arrow.up")
                    }

                    Button(role: .destructive, action: clearLogs) {
                        Label("Clear Logs", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: - Computed Properties

    private var filteredEntries: [DebugLogger.LogEntry] {
        if let category = selectedCategory {
            return logger.entries.filter { $0.category == category }
        }
        return logger.entries
    }

    // MARK: - Actions

    private func exportLogs() {
        exportURL = logger.export()
        showingExportSheet = true
    }

    private func clearLogs() {
        logger.clear()
    }

    // MARK: - Helpers

    private func colorForCategory(_ category: DebugLogger.LogEntry.Category) -> Color {
        switch category {
        case .api: return .blue
        case .auth: return .orange
        case .progress: return .green
        case .error: return .red
        }
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color.opacity(0.2) : Color.secondary.opacity(0.1))
                .foregroundStyle(isSelected ? color : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: DebugLogger.LogEntry
    let isExpanded: Bool
    let dateFormatter: DateFormatter
    let fullDateFormatter: DateFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main row
            HStack(spacing: 10) {
                Image(systemName: entry.category.icon)
                    .font(.caption)
                    .foregroundStyle(colorForCategory(entry.category))
                    .frame(width: 20)

                Text(entry.message)
                    .font(.subheadline)
                    .lineLimit(isExpanded ? nil : 1)

                Spacer()

                Text(dateFormatter.string(from: entry.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Expanded details
            if isExpanded, let details = entry.details {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()

                    Text(fullDateFormatter.string(from: entry.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text(details)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func colorForCategory(_ category: DebugLogger.LogEntry.Category) -> Color {
        switch category {
        case .api: return .blue
        case .auth: return .orange
        case .progress: return .green
        case .error: return .red
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

#Preview {
    NavigationStack {
        DebugLogView()
    }
}
