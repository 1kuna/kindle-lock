import Foundation
import FamilyControls

/// Persistent storage using App Group UserDefaults
@MainActor
final class SettingsStore: Sendable {
    private let defaults: UserDefaults

    init() {
        self.defaults = UserDefaults(suiteName: Constants.appGroupID) ?? .standard
    }

    // MARK: - App State

    var isSetupComplete: Bool {
        get { defaults.bool(forKey: Constants.Keys.isSetupComplete) }
        set { defaults.set(newValue, forKey: Constants.Keys.isSetupComplete) }
    }

    var dailyPercentageGoal: Double {
        get {
            let value = defaults.double(forKey: Constants.Keys.dailyPercentageGoal)
            return value > 0 ? value : Constants.defaultDailyPercentageGoal
        }
        set { defaults.set(newValue, forKey: Constants.Keys.dailyPercentageGoal) }
    }

    var dayResetHour: Int {
        get {
            let value = defaults.integer(forKey: Constants.Keys.dayResetHour)
            return value > 0 ? value : Constants.defaultDayResetHour
        }
        set { defaults.set(newValue, forKey: Constants.Keys.dayResetHour) }
    }

    // MARK: - Blocked Apps

    var blockedApps: FamilyActivitySelection {
        get {
            guard let data = defaults.data(forKey: Constants.Keys.blockedApps) else {
                return FamilyActivitySelection()
            }
            do {
                return try JSONDecoder().decode(FamilyActivitySelection.self, from: data)
            } catch {
                print("Failed to decode blocked apps: \(error)")
                return FamilyActivitySelection()
            }
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                defaults.set(data, forKey: Constants.Keys.blockedApps)
            } catch {
                print("Failed to encode blocked apps: \(error)")
            }
        }
    }

    // MARK: - Progress Cache

    var cachedProgress: TodayProgress? {
        get {
            guard let data = defaults.data(forKey: Constants.Keys.cachedProgress) else {
                return nil
            }
            return try? JSONDecoder().decode(TodayProgress.self, from: data)
        }
        set {
            if let newValue = newValue {
                let data = try? JSONEncoder().encode(newValue)
                defaults.set(data, forKey: Constants.Keys.cachedProgress)
            } else {
                defaults.removeObject(forKey: Constants.Keys.cachedProgress)
            }
        }
    }

    var lastSyncTime: Date? {
        get { defaults.object(forKey: Constants.Keys.lastSyncTime) as? Date }
        set { defaults.set(newValue, forKey: Constants.Keys.lastSyncTime) }
    }

    var lastDeepScanDate: Date? {
        get { defaults.object(forKey: Constants.Keys.lastDeepScanDate) as? Date }
        set { defaults.set(newValue, forKey: Constants.Keys.lastDeepScanDate) }
    }

    // MARK: - Book Position Tracking

    /// Store position snapshots for all books
    var bookPositions: [String: Int] {
        get {
            guard let data = defaults.data(forKey: Constants.Keys.bookPositions) else {
                return [:]
            }
            return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Constants.Keys.bookPositions)
        }
    }

    /// Store daily stats
    var dailyStats: DailyStats? {
        get {
            guard let data = defaults.data(forKey: Constants.Keys.dailyStats) else {
                return nil
            }
            return try? JSONDecoder().decode(DailyStats.self, from: data)
        }
        set {
            if let newValue = newValue {
                let data = try? JSONEncoder().encode(newValue)
                defaults.set(data, forKey: Constants.Keys.dailyStats)
            } else {
                defaults.removeObject(forKey: Constants.Keys.dailyStats)
            }
        }
    }

    // MARK: - Book Metadata Cache

    /// Cache book metadata (startPosition/endPosition don't change)
    var bookMetadataCache: [String: BookMetadata] {
        get {
            guard let data = defaults.data(forKey: Constants.Keys.bookMetadataCache) else {
                return [:]
            }
            return (try? JSONDecoder().decode([String: BookMetadata].self, from: data)) ?? [:]
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Constants.Keys.bookMetadataCache)
        }
    }

    // MARK: - Reset

    func resetAll() {
        let keys = [
            Constants.Keys.isSetupComplete,
            Constants.Keys.dailyPercentageGoal,
            Constants.Keys.dayResetHour,
            Constants.Keys.blockedApps,
            Constants.Keys.cachedProgress,
            Constants.Keys.lastSyncTime,
            Constants.Keys.lastDeepScanDate,
            Constants.Keys.bookPositions,
            Constants.Keys.dailyStats,
            Constants.Keys.bookMetadataCache
        ]
        keys.forEach { defaults.removeObject(forKey: $0) }
    }
}
