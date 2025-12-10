import Foundation

/// Constants for App Group access from ShieldConfiguration extension
enum ShieldConstants {
    static let appGroupID = "group.com.kindlelock.app"

    enum Keys {
        static let cachedProgress = "cachedProgress"
    }
}

/// Mirror of TodayProgress for decoding in extension
/// NOTE: Must match the main app's TodayProgress struct exactly for JSON decoding to work
struct ShieldTodayProgress: Codable {
    let date: String
    let percentageRead: Double
    let percentageGoal: Double
    let goalMet: Bool
    let goalMetAt: String?
    let percentageRemaining: Double
}

/// Helper to read cached progress from App Group UserDefaults
enum ProgressReader {
    /// Read the cached TodayProgress from shared UserDefaults
    static func readCachedProgress() -> ShieldTodayProgress? {
        guard let defaults = UserDefaults(suiteName: ShieldConstants.appGroupID),
              let data = defaults.data(forKey: ShieldConstants.Keys.cachedProgress) else {
            return nil
        }
        return try? JSONDecoder().decode(ShieldTodayProgress.self, from: data)
    }
}
