import Foundation

/// One artwork record from the Art Institute of Chicago API.
struct Artwork: Codable, Equatable {
    struct Thumbnail: Codable, Equatable {
        let altText: String?
    }

    let id: Int
    let title: String
    let artistDisplay: String?
    let dateDisplay: String?
    let placeOfOrigin: String?
    let mediumDisplay: String?
    let dimensions: String?
    let shortDescription: String?
    let description: String?
    let styleTitle: String?
    let fiscalYear: Int?
    let exhibitionHistory: String?
    let creditLine: String?
    let imageId: String
    let thumbnail: Thumbnail?

    var pageURL: URL { URL(string: "https://www.artic.edu/artworks/\(id)")! }
    // 843px wide is the size AIC recommends for IIIF requests.
    var imageURL: URL { URL(string: "https://www.artic.edu/iiif/2/\(imageId)/full/843,/0/default.jpg")! }
}

enum AICError: Error {
    case badStatus(Int)
    case badImage
    case nothingFound
}

/// Fetches public-domain paintings. Everything museum-specific lives here.
enum AICClient {
    // Override with ART_WIDGET_API to test the offline fallback.
    static let apiBase = ProcessInfo.processInfo.environment["ART_WIDGET_API"] ?? "https://api.artic.edu/api/v1"

    static let fields = [
        "id", "title", "artist_display", "date_display", "place_of_origin", "medium_display",
        "dimensions", "short_description", "description", "style_title", "fiscal_year",
        "exhibition_history", "credit_line", "image_id", "thumbnail",
    ].joined(separator: ",")

    /// Sorted by id so a position means the same painting on every device.
    static func filter(order: String) -> String {
        #"{"query":{"bool":{"must":[{"term":{"is_public_domain":true}},{"term":{"artwork_type_title.keyword":"Painting"}},{"exists":{"field":"image_id"}}]}},"sort":[{"id":"\#(order)"}]}"#
    }

    /// The API refuses positions past this, in either sort order.
    static let maxPosition = 1000

    private struct SearchResponse: Decodable {
        struct Pagination: Decodable { let total: Int }
        let pagination: Pagination
        let data: [Artwork]
    }

    /// Number of paintings in the pool.
    static func total() async throws -> Int {
        try await search(limit: 0, page: 1).pagination.total
    }

    /// The painting at a 1-based position in the pool. The far end is read in reverse order,
    /// because the API stops at `maxPosition`.
    static func artwork(at position: Int, total: Int) async throws -> Artwork {
        let response = position <= maxPosition
            ? try await search(limit: 1, page: position, order: "asc")
            : try await search(limit: 1, page: total - position + 1, order: "desc")
        guard let art = response.data.first else { throw AICError.nothingFound }
        return art
    }

    /// The painting for a day, the same on every device. A record with no usable image
    /// moves on to the next day's slot; network errors throw so the caller retries.
    static func daily(day: Int) async throws -> (Artwork, Data) {
        let total = try await total()
        guard total > 0 else { throw AICError.nothingFound }
        var lastError: Error = AICError.nothingFound
        for attempt in 0..<8 {
            do {
                let art = try await artwork(at: DailyPick.position(day: day + attempt, total: total), total: total)
                return (art, try await imageData(for: art))
            } catch AICError.badStatus(404), AICError.badImage {
                lastError = AICError.badImage
            }
        }
        throw lastError
    }

    /// One record, for opening a painting from its id.
    static func artwork(id: Int) async throws -> Artwork {
        struct Record: Decodable { let data: Artwork }
        var url = URLComponents(string: "\(apiBase)/artworks/\(id)")!
        url.queryItems = [URLQueryItem(name: "fields", value: fields)]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Record.self, from: try await get(url.url!)).data
    }

    static func imageData(for art: Artwork) async throws -> Data {
        let data = try await get(art.imageURL)
        guard data.count > 1000 else { throw AICError.badImage }
        return data
    }

    private static func search(limit: Int, page: Int, order: String = "asc") async throws -> SearchResponse {
        var url = URLComponents(string: "\(apiBase)/artworks/search")!
        url.queryItems = [
            URLQueryItem(name: "params", value: filter(order: order)),
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
        ]
        let data = try await get(url.url!)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SearchResponse.self, from: data)
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        // AIC asks API users to identify themselves with this header.
        request.setValue("art-widget (personal widget)", forHTTPHeaderField: "AIC-User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AICError.badStatus(status) }
        return data
    }
}
