import Foundation

enum APIError: LocalizedError {
    case badURL
    case http(Int, String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid server URL"
        case let .http(code, detail): return detail.isEmpty ? "Server error (\(code))" : detail
        case let .decoding(msg): return "Could not read server response: \(msg)"
        case let .transport(msg): return msg
        }
    }
}

/// Thin async wrapper over the FastAPI backend. Mirrors frontend/src/api.ts.
/// Native URLSession isn't subject to browser CORS, so it talks to the backend
/// directly at AppConfig.baseURL.
final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init() {
        let cfg = URLSessionConfiguration.default
        // The free-tier Render backend spins down when idle and a cold start
        // can take ~60s; give requests room instead of failing at 30s.
        cfg.timeoutIntervalForRequest = 75
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg)

        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    private func url(_ path: String) throws -> URL {
        guard let u = URL(string: AppConfig.baseURL + path) else { throw APIError.badURL }
        return u
    }

    // MARK: - Core request

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        var req = URLRequest(url: try url(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        // Heavy analytics endpoints (performance, dividend calendar) can take
        // minutes on their very first build on a cold backend — give them
        // room instead of failing at the session default.
        if let timeout { req.timeoutInterval = timeout }

        // POST/PUT get the same transient retry as GETs, made safe by a
        // per-attempt idempotency key: the backend replays the original
        // response if a retry re-delivers a create (PUTs are naturally
        // idempotent). DELETE stays no-retry — a repeat would just 404.
        var retryTransient = method == "GET"
        if method == "POST" || method == "PUT" {
            req.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
            retryTransient = true
        }

        let data = try await perform(&req, retryTransient: retryTransient)
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Runs the request with auth attached. Retries once after a transient
    /// transport failure (idempotent GETs only) and once after a 401 with a
    /// freshly refreshed Google token.
    private func perform(_ req: inout URLRequest, retryTransient: Bool) async throws -> Data {
        await Self.attachAuth(&req)
        var (data, http) = try await execute(req, retryTransient: retryTransient)
        if http.statusCode == 401,
           let fresh = await AuthTokenProvider.shared.refreshAfterRejection() {
            req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, http) = try await execute(req, retryTransient: retryTransient)
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw APIError.http(401, "Your Google session expired — please sign out and back in.")
            }
            throw APIError.http(http.statusCode, Self.detail(from: data, status: http.statusCode))
        }
        return data
    }

    /// Transport failures worth one retry: a timeout (backend cold-starting),
    /// or a dead keep-alive connection — after the Render backend idles, the
    /// pooled connection is gone and the first request on it dies instantly
    /// with "the network connection was lost". A fresh attempt succeeds.
    private static let transientCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost,
    ]

    private func execute(_ req: URLRequest, retryTransient: Bool) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await dataTask(req)
        } catch let e as URLError where retryTransient && Self.transientCodes.contains(e.code) {
            do { return try await dataTask(req) }
            catch { throw APIError.transport(error.localizedDescription) }
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    private func dataTask(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.transport("No response from server")
        }
        return (data, http)
    }

    private func send<B: Encodable, T: Decodable>(
        _ path: String, method: String, body: B
    ) async throws -> T {
        try await request(path, method: method, body: try encoder.encode(body))
    }

    /// Attach the signed-in user's Google ID token so the backend can scope data
    /// to that account. AuthTokenProvider refreshes it first if it has expired.
    private static func attachAuth(_ req: inout URLRequest) async {
        if let token = await AuthTokenProvider.shared.validToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Attach the user's chosen AI provider, API key, and selected model so the
    /// backend routes the chat to OpenAI / Gemini / Claude on their behalf.
    private static func attachAIProvider(_ req: inout URLRequest) {
        let p = AISettings.activeProvider
        req.setValue(p.rawValue, forHTTPHeaderField: "X-AI-Provider")
        if let key = AISettings.apiKey(for: p), !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "X-AI-Key")
        }
        req.setValue(AISettings.selectedModel(for: p), forHTTPHeaderField: "X-AI-Model")
    }

    private static func detail(from data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = obj["detail"] as? String {
            return detail
        }
        return "Request failed (\(status))"
    }

    struct EmptyResponse: Decodable {}

    // MARK: - Trades

    func listTrades() async throws -> [Trade] { try await request("/api/trades") }
    func createTrade(_ t: TradeCreate) async throws -> Trade {
        try await send("/api/trades", method: "POST", body: t)
    }
    func updateTrade(_ id: Int, _ t: TradeCreate) async throws -> Trade {
        try await send("/api/trades/\(id)", method: "PUT", body: t)
    }
    func deleteTrade(_ id: Int) async throws {
        let _: EmptyResponse = try await request("/api/trades/\(id)", method: "DELETE")
    }

    // MARK: - Dividends

    func listDividends() async throws -> [Dividend] { try await request("/api/dividends") }
    func createDividend(_ d: DividendCreate) async throws -> Dividend {
        try await send("/api/dividends", method: "POST", body: d)
    }
    func updateDividend(_ id: Int, _ d: DividendCreate) async throws -> Dividend {
        try await send("/api/dividends/\(id)", method: "PUT", body: d)
    }
    func deleteDividend(_ id: Int) async throws {
        let _: EmptyResponse = try await request("/api/dividends/\(id)", method: "DELETE")
    }

    // MARK: - Portfolio

    func getHoldings() async throws -> [Holding] { try await request("/api/portfolio/holdings") }
    func getSummary() async throws -> [CurrencySummary] { try await request("/api/portfolio/summary") }
    func getOverview() async throws -> PortfolioOverview { try await request("/api/portfolio/overview") }
    func getNames() async throws -> [String: String] { try await request("/api/portfolio/names") }
    func getMarkets() async throws -> [MarketConfig] { try await request("/api/markets") }
    /// Cheap fire-and-forget GET the add forms call on appear: it replaces a
    /// dead pooled keep-alive connection and starts the Render cold boot while
    /// the user is still typing, so the save itself doesn't pay for either.
    func warmUp() async { _ = try? await getMarkets() }
    /// Live-probes each quote source server-side; takes a few seconds.
    func getQuoteSources() async throws -> QuoteSourcesStatus { try await request("/api/quotes/sources") }
    func getEarningsHistory(days: Int = 1825) async throws -> [String: [EarningsPoint]] {
        try await request("/api/portfolio/earnings-history?days=\(days)")
    }
    /// Daily total market value of one market's holdings (net-worth curve).
    func getValueHistory(market: MarketCode, period: ValuePeriod) async throws -> [ValuePoint] {
        try await request("/api/portfolio/value-history?market=\(market.rawValue)&period=\(period.rawValue)")
    }

    // MARK: - Stock detail

    func getStockDetail(_ ticker: String, period: HistoryPeriod = .oneYear) async throws -> StockDetail {
        let enc = ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ticker
        return try await request("/api/stock/\(enc)/detail?period=\(period.rawValue)")
    }

    // MARK: - AI image import

    /// Upload a brokerage screenshot/statement image; the backend's vision model
    /// extracts trades + dividends. Read-only — nothing is written until the user
    /// confirms each row (which then goes through the normal create endpoints).
    func parseRecords(imageData: Data,
                      filename: String = "upload.jpg",
                      mimeType: String = "image/jpeg",
                      instructions: String = "") async throws -> ParsedRecords {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: try url("/api/ai/parse-records"))
        req.httpMethod = "POST"
        req.timeoutInterval = 180  // vision parsing can take a while
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // Optional user note, sent as a form field the backend folds into the
        // AI prompt to disambiguate the image.
        let note = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"instructions\"\r\n\r\n")
            body.appendString(note)
            body.appendString("\r\n")
        }
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(imageData)
        body.appendString("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let data = try await perform(&req, retryTransient: false)
        do {
            return try decoder.decode(ParsedRecords.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    // MARK: - Dividend calendar & performance

    func getDividendCalendar() async throws -> DividendCalendar {
        try await request("/api/dividends/calendar", timeout: 240)
    }

    func getPerformance(market: MarketCode, period: String) async throws -> PerformanceReport {
        try await request(
            "/api/portfolio/performance?market=\(market.rawValue)&period=\(period)",
            timeout: 240)
    }

    // MARK: - Indices & live quotes

    private struct IndexSymbolsPayload: Codable { let symbols: [String] }

    func getIndices() async throws -> [IndexQuote] {
        (try await request("/api/indices") as IndicesResponse).indices
    }

    func setIndices(_ symbols: [String]) async throws {
        let _: IndexSymbolsPayload = try await send(
            "/api/indices", method: "PUT", body: IndexSymbolsPayload(symbols: symbols))
    }

    /// Long-lived SSE stream of real-time US price ticks (stocks + indices).
    /// Runs until the server closes the connection or the task is cancelled;
    /// the caller owns reconnection. `onTick` is @MainActor for the same
    /// reason as streamChat's callbacks — ticks mutate @Published state.
    func streamQuotes(onTick: @escaping @MainActor (QuoteTick) -> Void) async throws {
        var req = URLRequest(url: try url("/api/quotes/stream"))
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        await Self.attachAuth(&req)

        var (bytes, resp) = try await session.bytes(for: req)
        guard var http = resp as? HTTPURLResponse else {
            throw APIError.transport("No response from server")
        }
        if http.statusCode == 401,
           let fresh = await AuthTokenProvider.shared.refreshAfterRejection() {
            req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (bytes, resp) = try await session.bytes(for: req)
            guard let retried = resp as? HTTPURLResponse else {
                throw APIError.transport("No response from server")
            }
            http = retried
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, "Quote stream failed (\(http.statusCode))")
        }

        func tick(from evt: [String: Any]) -> QuoteTick? {
            guard let ticker = evt["ticker"] as? String,
                  let price = evt["price"] as? Double else { return nil }
            return QuoteTick(
                ticker: ticker,
                price: price,
                prevClose: evt["prev_close"] as? Double,
                change: evt["change"] as? Double,
                changePct: evt["change_pct"] as? Double
            )
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !json.isEmpty,
                  let data = json.data(using: .utf8),
                  let evt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = evt["type"] as? String
            else { continue }

            switch type {
            case "tick":
                if let t = tick(from: evt) { await onTick(t) }
            case "snapshot":
                for raw in evt["ticks"] as? [[String: Any]] ?? [] {
                    if let t = tick(from: raw) { await onTick(t) }
                }
            default:
                break
            }
        }
    }

    // MARK: - AI

    func getAiStatus() async throws -> AiStatus { try await request("/api/ai/status") }
    func listChats() async throws -> [ChatSummary] { try await request("/api/ai/chats") }
    func getChat(_ id: Int) async throws -> ChatDetail { try await request("/api/ai/chats/\(id)") }
    func deleteChat(_ id: Int) async throws {
        let _: EmptyResponse = try await request("/api/ai/chats/\(id)", method: "DELETE")
    }
    /// Cancel the chat's in-flight server-side generation (stop button).
    func stopChat(_ id: Int) async throws {
        let _: EmptyResponse = try await request("/api/ai/chats/\(id)/stop", method: "POST")
    }
    /// Wake the backend and pre-build the chat context — called when the
    /// Assistant screen opens so the first send streams with zero waiting.
    func prewarmAI() async {
        let _: EmptyResponse? = try? await request("/api/ai/prewarm", method: "POST")
    }

    /// Streams the assistant reply from /api/ai/chat (Server-Sent Events).
    /// `onInit` fires with the chat id/title, `onChunk` with each text delta,
    /// `onDone` with the canonical content (citations resolved). Throws on error.
    /// Callbacks are @MainActor: they mutate @Published view-model state, and
    /// invoking them from the SSE read loop's background executor let UIKit
    /// race a keyboard dismissal against off-main layout — freezing the chat.
    func streamChat(
        chatId: Int?,
        message: String,
        onInit: @escaping @MainActor (Int, String) -> Void,
        onChunk: @escaping @MainActor (String) -> Void,
        onDone: @escaping @MainActor (String, [String]) -> Void,
        onStatus: @escaping @MainActor (String) -> Void = { _ in },
        onAction: @escaping @MainActor (ParsedRecords) -> Void = { _ in },
        onThinking: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws {
        var req = URLRequest(url: try url("/api/ai/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        await Self.attachAuth(&req)
        Self.attachAIProvider(&req)
        var payload: [String: Any] = ["message": message]
        if let chatId { payload["chat_id"] = chatId }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var (bytes, resp) = try await session.bytes(for: req)
        guard var http = resp as? HTTPURLResponse else {
            throw APIError.transport("No response from server")
        }
        if http.statusCode == 401,
           let fresh = await AuthTokenProvider.shared.refreshAfterRejection() {
            req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (bytes, resp) = try await session.bytes(for: req)
            guard let retried = resp as? HTTPURLResponse else {
                throw APIError.transport("No response from server")
            }
            http = retried
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, "Assistant request failed (\(http.statusCode))")
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !json.isEmpty,
                  let data = json.data(using: .utf8),
                  let evt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = evt["type"] as? String
            else { continue }

            switch type {
            case "init":
                await onInit(evt["chat_id"] as? Int ?? 0, evt["title"] as? String ?? "New chat")
            case "chunk":
                if let delta = evt["delta"] as? String { await onChunk(delta) }
            case "thinking":
                // Reasoning deltas (Claude extended thinking / Gemini thought
                // summaries) for the collapsible reasoning section.
                if let delta = evt["delta"] as? String { await onThinking(delta) }
            case "status":
                // Tool-call progress ("Searching the web…", "Reading
                // holdings…") so the UI isn't a silent spinner.
                if let text = evt["text"] as? String { await onStatus(text) }
            case "action":
                // A write tool proposed records — decoded into the same
                // ParsedRecords the image-import confirm card renders.
                if let rec = evt["records"] as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: rec),
                   let parsed = try? decoder.decode(ParsedRecords.self, from: data) {
                    await onAction(parsed)
                }
            case "done":
                await onDone(evt["content"] as? String ?? "", evt["queries"] as? [String] ?? [])
            case "error":
                throw APIError.transport(evt["detail"] as? String ?? "Assistant error")
            default:
                break
            }
        }
    }
}

private extension Data {
    mutating func appendString(_ s: String) {
        append(Data(s.utf8))
    }
}
