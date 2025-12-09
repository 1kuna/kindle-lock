import Foundation
import Observation

/// Centralized debug logging service for diagnosing progress tracking issues
@MainActor
@Observable
final class DebugLogger {
    static let shared = DebugLogger()

    // MARK: - Types

    struct LogEntry: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let category: Category
        let message: String
        let details: String?

        enum Category: String, Codable, CaseIterable {
            case api = "API"
            case auth = "Auth"
            case progress = "Progress"
            case error = "Error"

            var icon: String {
                switch self {
                case .api: return "arrow.up.arrow.down"
                case .auth: return "person.badge.key"
                case .progress: return "chart.line.uptrend.xyaxis"
                case .error: return "exclamationmark.triangle"
                }
            }
        }

        init(category: Category, message: String, details: String? = nil) {
            self.id = UUID()
            self.timestamp = Date()
            self.category = category
            self.message = message
            self.details = details
        }
    }

    // MARK: - Properties

    private(set) var entries: [LogEntry] = []

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "debugLoggingEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "debugLoggingEnabled") }
    }

    private let maxEntries = 500
    private let entriesKey = "debugLogEntries"

    // MARK: - Initialization

    private init() {
        loadEntries()
    }

    // MARK: - Logging Methods

    func log(_ category: LogEntry.Category, _ message: String, details: String? = nil) {
        guard isEnabled else { return }

        let entry = LogEntry(category: category, message: message, details: details)
        entries.insert(entry, at: 0)

        // Trim old entries
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }

        saveEntries()

        // Also print for Xcode console
        let detailStr = details.map { " | \($0)" } ?? ""
        print("[\(category.rawValue)] \(message)\(detailStr)")
    }

    /// Log a book position fetch result
    func logBookPosition(
        asin: String,
        title: String,
        position: Int?,
        start: Int?,
        end: Int?,
        percentage: Double,
        cached: Bool
    ) {
        let posStr = position.map { String($0) } ?? "nil"
        let startStr = start.map { String($0) } ?? "nil"
        let endStr = end.map { String($0) } ?? "nil"
        let cacheStr = cached ? " (cached)" : ""

        let message = "\"\(title.prefix(25))\" pos=\(posStr)\(cacheStr)"
        let details = "ASIN: \(asin)\nPosition: \(posStr)\nStart: \(startStr)\nEnd: \(endStr)\nCalculated: \(String(format: "%.2f", percentage))%"

        log(.api, message, details: details)
    }

    /// Log progress calculation for a book
    func logProgressCalculation(
        title: String,
        asin: String,
        startPercent: Double,
        currentPercent: Double,
        delta: Double
    ) {
        let deltaStr = delta > 0 ? "+\(String(format: "%.2f", delta))" : String(format: "%.2f", delta)
        let message = "\"\(title.prefix(25))\" \(deltaStr)%"
        let details = "ASIN: \(asin)\nStart of day: \(String(format: "%.2f", startPercent))%\nCurrent: \(String(format: "%.2f", currentPercent))%\nDelta: \(deltaStr)%"

        log(.progress, message, details: details)
    }

    /// Log daily progress summary
    func logProgressSummary(totalRead: Double, goal: Double, goalMet: Bool) {
        let status = goalMet ? "GOAL MET" : "\(String(format: "%.1f", goal - totalRead))% remaining"
        let message = "Total: \(String(format: "%.2f", totalRead))% of \(String(format: "%.1f", goal))% - \(status)"

        log(.progress, message)
    }

    // MARK: - Management

    func clear() {
        entries.removeAll()
        saveEntries()
    }

    /// Export logs to a temporary JSON file and return the URL
    func export() -> URL {
        let exportData = ExportData(
            exportedAt: Date(),
            entries: entries
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = (try? encoder.encode(exportData)) ?? Data()

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "kindlelock_debug_\(ISO8601DateFormatter().string(from: Date())).json"
        let fileURL = tempDir.appendingPathComponent(fileName)

        try? data.write(to: fileURL)

        return fileURL
    }

    // MARK: - Persistence

    private func loadEntries() {
        guard let data = UserDefaults.standard.data(forKey: entriesKey) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let loaded = try? decoder.decode([LogEntry].self, from: data) {
            entries = loaded
        }
    }

    private func saveEntries() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
    }

    // MARK: - Export Data Structure

    private struct ExportData: Codable {
        let exportedAt: Date
        let entries: [LogEntry]
    }
}
