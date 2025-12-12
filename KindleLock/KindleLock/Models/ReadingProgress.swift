import Foundation

/// Today's reading progress - computed locally from stored snapshots
struct TodayProgress: Codable, Equatable, Sendable {
    let date: String
    let percentageRead: Double      // Total percentage points read today across all books
    let percentageGoal: Double      // Daily goal (e.g., 5.0 for 5%)
    let goalMet: Bool
    let goalMetAt: String?
    let percentageRemaining: Double

    /// Progress toward goal as a fraction (0.0 to 1.0)
    var progressFraction: Double {
        guard percentageGoal > 0 else { return 0 }
        return min(1.0, percentageRead / percentageGoal)
    }

    /// Create from local calculation with explicit effective day
    init(date: String, percentageRead: Double, percentageGoal: Double, goalMetAt: String? = nil) {
        self.percentageRead = percentageRead
        self.percentageGoal = percentageGoal
        self.goalMet = percentageRead >= percentageGoal
        self.goalMetAt = goalMetAt
        self.percentageRemaining = max(0, percentageGoal - percentageRead)
    }

    /// Create with explicit date
    init(date: String, percentageRead: Double, percentageGoal: Double, goalMet: Bool, goalMetAt: String?, percentageRemaining: Double) {
        self.date = date
        self.percentageRead = percentageRead
        self.percentageGoal = percentageGoal
        self.goalMet = goalMet
        self.goalMetAt = goalMetAt
        self.percentageRemaining = percentageRemaining
    }
}

/// Snapshot of book position at a point in time
struct BookPositionSnapshot: Codable, Equatable, Sendable {
    let asin: String
    let position: Int
    let timestamp: Date
}

/// Daily reading statistics stored locally
struct DailyStats: Codable, Equatable, Sendable {
    let date: String
    var percentageRead: Double
    var goalMetAt: String?

    /// Start of day percentages for accurate progress tracking (ASIN -> percentage)
    var startOfDayPercentages: [String: Double]

    /// Last known percentages from previous refresh - used as next day's baseline
    /// Updated on every refresh to track where we left off
    var lastKnownPercentages: [String: Double]

    init(date: String) {
        self.date = date
        self.percentageRead = 0
        self.goalMetAt = nil
        self.startOfDayPercentages = [:]
        self.lastKnownPercentages = [:]
    }

    /// Create with inherited baseline from previous day
    init(date: String, inheritedBaseline: [String: Double]) {
        self.date = date
        self.percentageRead = 0
        self.goalMetAt = nil
        self.startOfDayPercentages = inheritedBaseline
        self.lastKnownPercentages = inheritedBaseline
    }

    // Custom decoder to handle migration from old format
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        percentageRead = try container.decodeIfPresent(Double.self, forKey: .percentageRead) ?? 0
        goalMetAt = try container.decodeIfPresent(String.self, forKey: .goalMetAt)
        startOfDayPercentages = try container.decodeIfPresent([String: Double].self, forKey: .startOfDayPercentages) ?? [:]
        lastKnownPercentages = try container.decodeIfPresent([String: Double].self, forKey: .lastKnownPercentages) ?? [:]
    }
}

/// Observable state for refresh progress (used in UI)
struct RefreshProgress: Sendable, Equatable {
    var isActive: Bool = false
    var totalBooks: Int = 0
    var currentBook: Int = 0
    var currentBookTitle: String = ""
    var statusMessage: String = ""
    var isComplete: Bool = false
    var error: String?
}
