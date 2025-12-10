import Foundation

/// Direct Kindle API client - calls Amazon's web reader APIs
@MainActor
final class KindleAPIService {
    static let shared = KindleAPIService()

    private let authService = KindleAuthService.shared
    private let logger = DebugLogger.shared
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    // MARK: - API Endpoints

    private enum Endpoint {
        static let baseURL = "https://read.amazon.com"

        /// Quick refresh - 20 most recent books (for frequent background updates)
        static var libraryQuick: URL {
            URL(string: "\(baseURL)/kindle-library/search?query=&libraryType=BOOKS&sortType=recency&querySize=20")!
        }

        /// Full library fetch - 50 books per page (for deep scan)
        static func libraryPage(paginationToken: String? = nil) -> URL {
            var urlString = "\(baseURL)/kindle-library/search?query=&libraryType=BOOKS&sortType=recency&querySize=50"
            if let token = paginationToken {
                urlString += "&paginationToken=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)"
            }
            return URL(string: urlString)!
        }

        static func deviceToken(_ token: String) -> URL {
            URL(string: "\(baseURL)/service/web/register/getDeviceToken?serialNumber=\(token)&deviceType=\(token)")!
        }

        static func startReading(asin: String) -> URL {
            URL(string: "\(baseURL)/service/mobile/reader/startReading?asin=\(asin)&clientVersion=20000100")!
        }
    }

    // MARK: - Public API

    /// Fetch library and reading progress for all books
    /// Pass in cached metadata to avoid refetching S3 metadata
    func fetchLibraryWithProgress(metadataCache: [String: BookMetadata] = [:]) async throws -> [KindleBook] {
        // First, get the library list
        let books = try await fetchLibrary()

        // Ensure we have ADP token for startReading calls
        try await ensureADPToken()

        // Fetch position and metadata for each book
        var enrichedBooks: [KindleBook] = []
        for book in books {
            var enriched = book
            let cachedMeta = metadataCache[book.asin]

            if let result = try? await fetchReadingPositionWithMetadata(asin: book.asin, cachedMetadata: cachedMeta) {
                enriched.currentPosition = result.position
                enriched.startPosition = result.startPosition
                enriched.endPosition = result.endPosition
            }
            enrichedBooks.append(enriched)
        }

        return enrichedBooks
    }

    /// Fetch 20 most recent books (quick refresh for background updates)
    func fetchLibraryQuick() async throws -> [KindleBook] {
        logger.log(.api, "Fetching library (quick - 20 books)...")
        return try await fetchLibraryPage(url: Endpoint.libraryQuick)
    }

    /// Fetch entire library with pagination (for deep scan)
    func fetchEntireLibrary() async throws -> [KindleBook] {
        logger.log(.api, "Fetching entire library (paginated)...")

        var allBooks: [KindleBook] = []
        var paginationToken: String? = nil
        var pageCount = 0
        let maxPages = 20 // Safety limit: 20 pages * 50 books = 1000 books max

        repeat {
            pageCount += 1
            let url = Endpoint.libraryPage(paginationToken: paginationToken)
            let request = makeRequest(url: url)
            let (data, response) = try await session.data(for: request)

            try validateResponse(response)

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let itemsList = json["itemsList"] as? [[String: Any]] else {
                logger.log(.error, "Library decode failed on page \(pageCount)")
                throw KindleAPIError.decodingError
            }

            let books = parseBooks(from: itemsList)
            allBooks.append(contentsOf: books)

            // Get pagination token for next page (nil if no more pages)
            paginationToken = json["paginationToken"] as? String
            logger.log(.api, "Page \(pageCount): \(books.count) books, total: \(allBooks.count)")

        } while paginationToken != nil && pageCount < maxPages

        logger.log(.api, "Full library fetched: \(allBooks.count) books across \(pageCount) pages")
        return allBooks
    }

    /// Fetch a single page of library results (internal helper)
    private func fetchLibraryPage(url: URL) async throws -> [KindleBook] {
        let request = makeRequest(url: url)
        let (data, response) = try await session.data(for: request)

        try validateResponse(response)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let itemsList = json["itemsList"] as? [[String: Any]] else {
            logger.log(.error, "Library decode failed", details: "Could not parse itemsList from response")
            throw KindleAPIError.decodingError
        }

        let books = parseBooks(from: itemsList)
        logger.log(.api, "Library page fetched: \(books.count) books")
        return books
    }

    /// Parse books from API response items
    private func parseBooks(from itemsList: [[String: Any]]) -> [KindleBook] {
        itemsList.compactMap { item -> KindleBook? in
            guard let asin = item["asin"] as? String,
                  let title = item["title"] as? String else {
                return nil
            }

            return KindleBook(
                asin: asin,
                title: title,
                authors: (item["authors"] as? [String]) ?? [],
                coverUrl: item["productUrl"] as? String,
                percentageRead: item["percentageRead"] as? Int ?? 0,
                currentPosition: nil
            )
        }
    }

    /// Fetch just the library list - 20 most recent (default for backward compatibility)
    func fetchLibrary() async throws -> [KindleBook] {
        try await fetchLibraryQuick()
    }

    /// Fetch reading position and metadata for a specific book
    /// Returns (position, startPosition, endPosition) or nil if failed
    func fetchReadingPositionWithMetadata(asin: String, cachedMetadata: BookMetadata?) async throws -> (position: Int, startPosition: Int, endPosition: Int)? {
        var request = makeRequest(url: Endpoint.startReading(asin: asin))

        // Add ADP token if available
        if let adpToken = authService.adpSessionToken {
            request.setValue(adpToken, forHTTPHeaderField: "x-adp-session-token")
        }

        let (data, response) = try await session.data(for: request)

        try validateResponse(response)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lastPageRead = json["lastPageReadData"] as? [String: Any],
              let position = lastPageRead["position"] as? Int else {
            logger.log(.error, "Position fetch failed for \(asin)", details: "Could not parse lastPageReadData.position")
            return nil
        }

        // Use cached metadata if available
        if let cached = cachedMetadata {
            let percentage = calculatePercentage(position: position, start: cached.startPosition, end: cached.endPosition)
            logger.log(.api, "Position: \(asin.prefix(8))... pos=\(position) (cached meta)", details: "ASIN: \(asin)\nPosition: \(position)\nStart: \(cached.startPosition)\nEnd: \(cached.endPosition)\nCalculated: \(String(format: "%.2f", percentage))%")
            return (position, cached.startPosition, cached.endPosition)
        }

        // Otherwise, fetch metadata from S3
        if let metadataUrl = json["metadataUrl"] as? String,
           let metadata = try? await fetchBookMetadata(url: metadataUrl) {
            let percentage = calculatePercentage(position: position, start: metadata.startPosition, end: metadata.endPosition)
            logger.log(.api, "Position: \(asin.prefix(8))... pos=\(position) (fresh meta)", details: "ASIN: \(asin)\nPosition: \(position)\nStart: \(metadata.startPosition)\nEnd: \(metadata.endPosition)\nCalculated: \(String(format: "%.2f", percentage))%")
            return (position, metadata.startPosition, metadata.endPosition)
        }

        // Fallback: return position without metadata
        logger.log(.error, "No metadata for \(asin)", details: "Position fetched but could not get start/end positions")
        return nil
    }

    /// Calculate percentage from position and bounds (helper for logging)
    private func calculatePercentage(position: Int, start: Int, end: Int) -> Double {
        guard end > start else { return 0 }
        let range = Double(end - start)
        let progress = Double(position - start)
        return max(0, min(100, (progress / range) * 100))
    }

    /// Fetch reading position for a specific book (legacy - returns just position)
    func fetchReadingPosition(asin: String) async throws -> Int? {
        var request = makeRequest(url: Endpoint.startReading(asin: asin))

        // Add ADP token if available
        if let adpToken = authService.adpSessionToken {
            request.setValue(adpToken, forHTTPHeaderField: "x-adp-session-token")
        }

        let (data, response) = try await session.data(for: request)

        try validateResponse(response)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lastPageRead = json["lastPageReadData"] as? [String: Any],
              let position = lastPageRead["position"] as? Int else {
            return nil
        }

        return position
    }

    // MARK: - Metadata Fetching

    /// Fetch book metadata from S3 (contains startPosition and endPosition)
    private func fetchBookMetadata(url: String) async throws -> (startPosition: Int, endPosition: Int)? {
        guard let metadataUrl = URL(string: url) else {
            return nil
        }

        let (data, response) = try await session.data(from: metadataUrl)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        // Response is JSONP format: callback({...})
        // Need to strip the callback wrapper
        guard var responseString = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Extract JSON from JSONP
        if let jsonStart = responseString.firstIndex(of: "("),
           let jsonEnd = responseString.lastIndex(of: ")") {
            responseString = String(responseString[responseString.index(after: jsonStart)..<jsonEnd])
        }

        guard let jsonData = responseString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let startPosition = json["startPosition"] as? Int,
              let endPosition = json["endPosition"] as? Int else {
            return nil
        }

        return (startPosition, endPosition)
    }

    // MARK: - ADP Token Management

    /// Ensure we have a valid ADP session token
    private func ensureADPToken() async throws {
        // If we already have one, use it
        if authService.adpSessionToken != nil {
            logger.log(.auth, "ADP token present")
            return
        }

        // Need device token to get ADP token
        guard let deviceToken = authService.deviceToken else {
            logger.log(.error, "Missing device token for ADP acquisition")
            throw KindleAPIError.missingDeviceToken
        }

        logger.log(.auth, "Acquiring ADP token...")

        let request = makeRequest(url: Endpoint.deviceToken(deviceToken))
        let (data, response) = try await session.data(for: request)

        try validateResponse(response)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let adpToken = json["deviceSessionToken"] as? String else {
            logger.log(.error, "ADP token decode failed")
            throw KindleAPIError.decodingError
        }

        authService.saveADPSessionToken(adpToken)
        logger.log(.auth, "ADP token acquired")
    }

    // MARK: - Request Building

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(authService.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let sessionId = authService.sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "x-amzn-sessionid")
        }

        return request
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.log(.error, "Invalid response (not HTTP)")
            throw KindleAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401, 403:
            logger.log(.error, "Unauthorized (HTTP \(httpResponse.statusCode))", details: "Session expired or invalid credentials")
            authService.markSessionExpired()
            throw KindleAPIError.unauthorized
        case 500...599:
            logger.log(.error, "Server error (HTTP \(httpResponse.statusCode))")
            throw KindleAPIError.serverError(httpResponse.statusCode)
        default:
            logger.log(.error, "HTTP error \(httpResponse.statusCode)")
            throw KindleAPIError.httpError(httpResponse.statusCode)
        }
    }
}

// MARK: - Models

struct KindleBook: Identifiable, Equatable, Sendable {
    let asin: String
    let title: String
    let authors: [String]
    let coverUrl: String?
    let percentageRead: Int
    var currentPosition: Int?

    // Metadata from S3 for accurate percentage calculation
    var startPosition: Int?
    var endPosition: Int?

    var id: String { asin }

    var authorsFormatted: String {
        authors.joined(separator: ", ")
    }

    /// Calculate accurate percentage based on position and book bounds
    var calculatedPercentage: Double {
        guard let position = currentPosition,
              let start = startPosition,
              let end = endPosition,
              end > start else {
            return 0
        }
        let range = Double(end - start)
        let progress = Double(position - start)
        return max(0, min(100, (progress / range) * 100))
    }
}

/// Cached metadata for a book (positions don't change)
struct BookMetadata: Codable, Equatable, Sendable {
    let asin: String
    let startPosition: Int
    let endPosition: Int
    let fetchedAt: Date
}

// MARK: - Errors

enum KindleAPIError: LocalizedError {
    case unauthorized
    case invalidResponse
    case decodingError
    case httpError(Int)
    case serverError(Int)
    case missingDeviceToken
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Session expired. Please log in again."
        case .invalidResponse:
            return "Invalid response from Kindle servers"
        case .decodingError:
            return "Failed to parse Kindle data"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .serverError(let code):
            return "Kindle server error: \(code)"
        case .missingDeviceToken:
            return "Missing device token. Please log in again."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
