import Foundation

/// Shared constants used across the app and extensions
enum Constants {
    /// App Group identifier for sharing data between app and extensions
    static let appGroupID = "group.com.kindlelock.app"

    /// Default values
    static let defaultDailyPercentageGoal: Double = 5.0  // 5% daily reading goal
    static let defaultDayResetHour = 4

    /// UserDefaults keys
    enum Keys {
        static let isSetupComplete = "isSetupComplete"
        static let dailyPercentageGoal = "dailyPercentageGoal"
        static let dayResetHour = "dayResetHour"
        static let blockedApps = "blockedApps"
        static let cachedProgress = "cachedProgress"
        static let lastSyncTime = "lastSyncTime"
        static let bookPositions = "bookPositions"
        static let dailyStats = "dailyStats"
        static let bookMetadataCache = "bookMetadataCache"
        static let lastDeepScanDate = "lastDeepScanDate"
    }

    /// URL schemes
    enum URLSchemes {
        static let kindle = "kindle://"
        static let kindleLock = "kindlelock://"
    }

    /// Background task identifiers
    enum BackgroundTasks {
        static let refresh = "com.kindlelock.app.refresh"
        static let deepScan = "com.kindlelock.app.deepScan"
    }
}
