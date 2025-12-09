import SwiftUI
import FamilyControls
import Observation
import Combine

/// Authorization status for FamilyControls
enum AuthorizationStatus: Sendable {
    case notDetermined
    case approved
    case denied
}

/// Main application state using the new @Observable macro
@MainActor
@Observable
final class AppState {
    // MARK: - Published State

    var todayProgress: TodayProgress?
    var isLoading = false
    var lastError: String?
    var isSetupComplete: Bool
    var blockedApps: FamilyActivitySelection
    var authorizationStatus: AuthorizationStatus = .notDetermined
    var refreshProgress: RefreshProgress?

    /// Tracks auth state from KindleAuthService (mirrored for @Observable compatibility)
    private(set) var isAuthenticatedState: Bool = false

    // MARK: - Services

    private let settings: SettingsStore
    private let kindleAPI: KindleAPIService
    private let authService: KindleAuthService
    private let shieldManager: ShieldManager
    private let logger = DebugLogger.shared
    private var authCancellable: AnyCancellable?

    // MARK: - Initialization

    init() {
        self.settings = SettingsStore()
        self.kindleAPI = KindleAPIService.shared
        self.authService = KindleAuthService.shared
        self.shieldManager = ShieldManager()
        self.isSetupComplete = settings.isSetupComplete
        self.blockedApps = settings.blockedApps
        self.isAuthenticatedState = authService.isAuthenticated

        // Load cached progress if available
        if let cached = settings.cachedProgress {
            self.todayProgress = cached
        }

        // Subscribe to auth service changes (bridges ObservableObject to @Observable)
        // Use .prepend() to emit current value immediately, not just on subsequent changes
        authCancellable = authService.$isAuthenticated
            .prepend(authService.isAuthenticated)
            .receive(on: RunLoop.main)
            .sink { [weak self] isAuth in
                self?.isAuthenticatedState = isAuth
            }
    }

    // MARK: - Computed Properties

    var goalMet: Bool {
        todayProgress?.goalMet ?? false
    }

    var percentageRead: Double {
        todayProgress?.percentageRead ?? 0
    }

    var percentageGoal: Double {
        todayProgress?.percentageGoal ?? settings.dailyPercentageGoal
    }

    var percentageRemaining: Double {
        todayProgress?.percentageRemaining ?? settings.dailyPercentageGoal
    }

    var progressFraction: Double {
        todayProgress?.progressFraction ?? 0
    }

    var isAuthenticated: Bool {
        isAuthenticatedState
    }

    var needsReauth: Bool {
        !isAuthenticatedState && isSetupComplete
    }

    // MARK: - Actions

    /// Refresh reading progress from Kindle API
    func refreshProgress() async {
        guard isAuthenticatedState else {
            lastError = "Please sign in to Amazon"
            logger.log(.error, "Refresh failed: not authenticated")
            return
        }

        logger.log(.progress, "Background refresh started")
        isLoading = true
        lastError = nil

        do {
            // Pass metadata cache to avoid refetching S3 data
            let books = try await kindleAPI.fetchLibraryWithProgress(metadataCache: settings.bookMetadataCache)

            // Cache any new metadata
            updateMetadataCache(from: books)

            let progress = calculateTodayProgress(from: books)
            todayProgress = progress
            settings.cachedProgress = progress
            settings.lastSyncTime = Date()
            updateShields()

            logger.log(.progress, "Refresh complete: \(String(format: "%.2f", progress.percentageRead))% today")
        } catch let error as KindleAPIError {
            if case .unauthorized = error {
                lastError = "Session expired. Please sign in again."
            } else {
                lastError = error.localizedDescription
            }
            logger.log(.error, "Refresh error: \(error.localizedDescription)")
        } catch {
            lastError = error.localizedDescription
            logger.log(.error, "Refresh error: \(error.localizedDescription)")
        }

        isLoading = false
    }

    /// Trigger a manual refresh with progress updates
    func triggerManualRefresh() async {
        guard isAuthenticatedState else {
            lastError = "Please sign in to Amazon"
            logger.log(.error, "Manual refresh failed: not authenticated")
            return
        }

        logger.log(.progress, "Manual refresh started")
        isLoading = true
        lastError = nil
        refreshProgress = RefreshProgress(isActive: true, statusMessage: "Connecting...")

        do {
            // Fetch library first
            refreshProgress?.statusMessage = "Loading library..."
            let books = try await kindleAPI.fetchLibrary()
            refreshProgress?.totalBooks = books.count

            // Get metadata cache
            let metadataCache = settings.bookMetadataCache

            // Fetch position and metadata for each book
            var enrichedBooks: [KindleBook] = []
            for (index, book) in books.enumerated() {
                refreshProgress?.currentBook = index + 1
                refreshProgress?.currentBookTitle = book.title
                refreshProgress?.statusMessage = "Checking \(book.title.prefix(20))..."

                var enriched = book
                let cachedMeta = metadataCache[book.asin]

                if let result = try? await kindleAPI.fetchReadingPositionWithMetadata(asin: book.asin, cachedMetadata: cachedMeta) {
                    enriched.currentPosition = result.position
                    enriched.startPosition = result.startPosition
                    enriched.endPosition = result.endPosition
                }
                enrichedBooks.append(enriched)
            }

            // Cache any new metadata
            updateMetadataCache(from: enrichedBooks)

            // Calculate and save progress
            let progress = calculateTodayProgress(from: enrichedBooks)
            todayProgress = progress
            settings.cachedProgress = progress
            settings.lastSyncTime = Date()
            updateShields()

            refreshProgress?.isComplete = true
            refreshProgress?.statusMessage = "Done!"

            logger.log(.progress, "Manual refresh complete: \(String(format: "%.2f", progress.percentageRead))% today")

            // Clear progress after a brief delay
            try? await Task.sleep(for: .seconds(1.5))
            refreshProgress = nil

        } catch let error as KindleAPIError {
            if case .unauthorized = error {
                lastError = "Session expired. Please sign in again."
            } else {
                lastError = error.localizedDescription
            }
            logger.log(.error, "Manual refresh error: \(error.localizedDescription)")
            refreshProgress?.error = error.localizedDescription
            refreshProgress = nil
        } catch {
            lastError = error.localizedDescription
            logger.log(.error, "Manual refresh error: \(error.localizedDescription)")
            refreshProgress = nil
        }

        isLoading = false
    }

    /// Calculate today's progress from book positions using percentage-based tracking
    private func calculateTodayProgress(from books: [KindleBook]) -> TodayProgress {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        // Get or create daily stats
        var stats = settings.dailyStats
        let isNewDay = stats?.date != today

        if isNewDay {
            logger.log(.progress, "New day detected: \(today)", details: "Previous date: \(stats?.date ?? "none")")

            // Use yesterday's last known positions as today's start-of-day baseline
            // This ensures reading done before opening the app is counted
            let inheritedBaseline = stats?.lastKnownPercentages ?? [:]

            logger.log(.progress, "Inheriting \(inheritedBaseline.count) baselines from previous day")

            // Create new day stats with inherited baseline
            stats = DailyStats(date: today, inheritedBaseline: inheritedBaseline)
        }

        // Calculate total percentage points read today across all books
        var totalPercentageRead: Double = 0
        var booksWithProgress = 0

        // Track current positions for next day's baseline
        var currentPercentages: [String: Double] = [:]

        for book in books {
            guard book.currentPosition != nil else { continue }

            let currentPercent = book.calculatedPercentage
            currentPercentages[book.asin] = currentPercent

            // Get start-of-day percentage
            let startPercent: Double
            if let savedStart = stats?.startOfDayPercentages[book.asin] {
                startPercent = savedStart
            } else {
                // New book not in baseline - use current as start (no progress for this book today)
                startPercent = currentPercent
                // Also add to start-of-day so we don't log this warning repeatedly
                stats?.startOfDayPercentages[book.asin] = currentPercent
                logger.log(.progress, "New book detected: \(book.title.prefix(20))...", details: "ASIN: \(book.asin)\nUsing current \(String(format: "%.2f", currentPercent))% as baseline")
            }

            // Calculate delta
            let delta = currentPercent - startPercent

            // Log per-book progress calculation
            logger.logProgressCalculation(
                title: book.title,
                asin: book.asin,
                startPercent: startPercent,
                currentPercent: currentPercent,
                delta: delta
            )

            // Only count positive progress
            if delta > 0 {
                totalPercentageRead += delta
                booksWithProgress += 1
            }
        }

        // Always update last known percentages for next day's baseline
        stats?.lastKnownPercentages = currentPercentages

        // Check if goal was just met
        let goal = settings.dailyPercentageGoal
        var goalMetAt = stats?.goalMetAt
        if totalPercentageRead >= goal && goalMetAt == nil {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            goalMetAt = timeFormatter.string(from: Date())
            logger.log(.progress, "GOAL MET at \(goalMetAt ?? "?")")
        }

        // Log summary
        logger.logProgressSummary(totalRead: totalPercentageRead, goal: goal, goalMet: totalPercentageRead >= goal)

        // Update stats
        stats?.percentageRead = totalPercentageRead
        stats?.goalMetAt = goalMetAt
        settings.dailyStats = stats

        return TodayProgress(
            percentageRead: totalPercentageRead,
            percentageGoal: goal,
            goalMetAt: goalMetAt
        )
    }

    /// Cache metadata from books that have it
    private func updateMetadataCache(from books: [KindleBook]) {
        var cache = settings.bookMetadataCache
        var updated = false

        for book in books {
            // Only cache if we have metadata and it's not already cached
            if let start = book.startPosition,
               let end = book.endPosition,
               cache[book.asin] == nil {
                cache[book.asin] = BookMetadata(
                    asin: book.asin,
                    startPosition: start,
                    endPosition: end,
                    fetchedAt: Date()
                )
                updated = true
            }
        }

        if updated {
            settings.bookMetadataCache = cache
        }
    }

    /// Update the blocked apps selection
    func updateBlockedApps(_ selection: FamilyActivitySelection) {
        blockedApps = selection
        settings.blockedApps = selection
        updateShields()
    }

    /// Complete the setup process
    func completeSetup() {
        settings.isSetupComplete = true
        isSetupComplete = true
        updateShields()
    }

    /// Reset setup and clear all data
    func resetSetup() {
        shieldManager.removeAllShields()
        settings.resetAll()
        authService.logout()
        isSetupComplete = false
        todayProgress = nil
        blockedApps = FamilyActivitySelection()
    }

    // MARK: - Shield Management

    /// Update shields based on goal status
    private func updateShields() {
        if goalMet {
            shieldManager.removeAllShields()
        } else {
            shieldManager.applyShields(to: blockedApps)
        }
    }

    /// Force shield update (called after authorization)
    func forceUpdateShields() {
        updateShields()
    }
}
