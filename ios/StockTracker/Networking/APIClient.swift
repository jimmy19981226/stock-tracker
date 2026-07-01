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
        body: Data? = nil
    ) async throws -> T {
        var req = URLRequest(url: try url(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let data = try await perform(&req, retryTimeout: method == "GET")
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Runs the request with auth attached. Retries once after a timeout
    /// (idempotent GETs only — rides out the backend cold-starting) and once
    /// after a 401 with a freshly refreshed Google token.
    private func perform(_ req: inout URLRequest, retryTimeout: Bool) async throws -> Data {
        await Self.attachAuth(&req)
        var (data, http) = try await execute(req, retryTimeout: retryTimeout)
        if http.statusCode == 401,
           let fresh = await AuthTokenProvider.shared.refreshAfterRejection() {
            req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, http) = try await execute(req, retryTimeout: retryTimeout)
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw APIError.http(401, "Your Google session expired — please sign out and back in.")
            }
            throw APIError.http(http.statusCode, Self.detail(from: data, status: http.statusCode))
        }
        return data
    }

    private func execute(_ req: URLRequest, retryTimeout: Bool) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await dataTask(req)
        } catch let e as URLError where retryTimeout && e.code == .timedOut {
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
    /// Live-probes each quote source server-side; takes a few seconds.
    func getQuoteSources() async throws -> QuoteSourcesStatus { try await request("/api/quotes/sources") }
    func getEarningsHistory(days: Int = 1825) async throws -> [String: [EarningsPoint]] {
        try await request("/api/portfolio/earnings-history?days=\(days)")
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

        let data = try await perform(&req, retryTimeout: false)
        do {
            return try decoder.decode(ParsedRecords.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    // MARK: - AI

    func getAiStatus() async throws -> AiStatus { try await request("/api/ai/status") }
    func listChats() async throws -> [ChatSummary] { try await request("/api/ai/chats") }
    func getChat(_ id: Int) async throws -> ChatDetail { try await request("/api/ai/chats/\(id)") }
    func deleteChat(_ id: Int) async throws {
        let _: EmptyResponse = try await request("/api/ai/chats/\(id)", method: "DELETE")
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
        onDone: @escaping @MainActor (String, [String]) -> Void
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
