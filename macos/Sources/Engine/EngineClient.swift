import Foundation

enum EngineError: Error, LocalizedError, Equatable {
    case unreachable(String)
    case http(status: Int)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail): "Engine not reachable: \(detail)"
        case .http(let status): "Engine returned HTTP \(status)"
        case .malformedResponse(let detail): "Unexpected engine response: \(detail)"
        }
    }
}

/// Thin async wrapper over the engine's JSON API.
///
/// Deliberately stateless: every call is a request. Live state arrives through
/// `NotifyClient` instead of polling, and `EngineStore` is what holds it.
actor EngineClient {
    nonisolated let endpoint: EngineEndpoint

    private let session: URLSession
    private let decoder: JSONDecoder

    init(endpoint: EngineEndpoint = .default) {
        self.endpoint = endpoint

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    // MARK: - Reads

    func outputs() async throws -> [Output] {
        let response: OutputsResponse = try await get("api/outputs")
        return response.outputs
    }

    func player() async throws -> PlayerStatus {
        try await get("api/player")
    }

    /// The queue item the player is on, or nil when it is on none.
    ///
    /// Two requests, because OwnTone 29.3 has no GET for
    /// `/api/queue/items/now_playing` -- only PUT -- and answers the GET
    /// with 400 and "Unrecognized JSON API request". So this reads the
    /// player's `item_id` and asks the queue for that one item.
    func nowPlaying() async throws -> NowPlaying? {
        let status = try await player()
        guard status.itemId > 0 else { return nil }
        let response: QueueResponse = try await get("api/queue", query: [
            URLQueryItem(name: "id", value: String(status.itemId))
        ])
        return response.items.first
    }

    // MARK: - Writes

    func setSelected(_ selected: Bool, forOutput id: String) async throws {
        try await put("api/outputs/\(id)", body: ["selected": selected])
    }

    func setVolume(_ volume: Int, forOutput id: String) async throws {
        try await put("api/outputs/\(id)", body: ["volume": clampVolume(volume)])
    }

    /// Answers a device's on-screen verification code. Sent together with
    /// `selected` so a successful pairing also completes the selection the
    /// user originally asked for.
    func verify(pin: String, forOutput id: String) async throws {
        try await put("api/outputs/\(id)", body: ["pin": pin, "selected": true])
    }

    /// Enables exactly `ids` and disables everything else, in one request.
    /// This is what speaker presets and rejoin-on-free should use, since it
    /// cannot leave the set half-applied.
    func setEnabledOutputs(_ ids: [String]) async throws {
        try await put("api/outputs/set", body: ["outputs": ids])
    }

    func setMasterVolume(_ volume: Int) async throws {
        try await put("api/player/volume", query: [
            URLQueryItem(name: "volume", value: String(clampVolume(volume)))
        ])
    }

    // MARK: - Artwork

    /// Artwork paths from the engine are relative; external stream artwork is
    /// absolute. Both shapes appear in `artwork_url`.
    nonisolated func artworkURL(for path: String, maxPixels: Int) -> URL? {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        // The engine hands back "./artwork/item/1?v=287": a path relative to
        // its own root, dot-slash and all, with a cache-busting query. The
        // dot-slash has to go, or the request misses the artwork API and lands
        // in the static file handler (seen in the engine log as "Could not
        // dereference .../htdocs/./artwork/item/1"), and the query has to be
        // split off before the path is appended, or it is percent-encoded
        // into the path.
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var relative = String(parts[0])
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        while relative.hasPrefix("/") { relative.removeFirst() }
        var components = URLComponents(url: endpoint.api(relative), resolvingAgainstBaseURL: false)
        var query = parts.count > 1 ? URLComponents(string: "?" + parts[1])?.queryItems ?? [] : []
        query += [
            URLQueryItem(name: "maxwidth", value: String(maxPixels)),
            URLQueryItem(name: "maxheight", value: String(maxPixels)),
        ]
        components?.queryItems = query
        return components?.url
    }

    // MARK: - Plumbing

    private enum Method: String {
        case get = "GET"
        case put = "PUT"
    }

    private nonisolated func clampVolume(_ volume: Int) -> Int {
        min(100, max(0, volume))
    }

    private func request(_ method: Method, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var url = endpoint.api(path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        return request
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, response) = try await perform(request(.get, path, query: query))
        try check(response)
        return try decode(T.self, from: data)
    }

    private func put(
        _ path: String,
        query: [URLQueryItem] = [],
        body: [String: any Sendable]? = nil
    ) async throws {
        var request = request(.put, path, query: query)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (_, response) = try await perform(request)
        try check(response)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw EngineError.malformedResponse("not an HTTP response")
            }
            return (data, http)
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreachable(error.localizedDescription)
        }
    }

    private func check(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw EngineError.http(status: response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw EngineError.malformedResponse(String(describing: error))
        }
    }
}
