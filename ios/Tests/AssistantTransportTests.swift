import Foundation
import XCTest
@testable import StockTracker

/// Real URLSession byte streams, with only the network replaced. No keychain
/// writes, provider requests, production records, or UI test hooks are involved.
@MainActor
final class AssistantTransportTests: XCTestCase {
    private func client(_ replies: [AssistantStubReply],
                        token: @escaping () async -> String? = { nil },
                        refresh: @escaping () async -> String? = { nil }) -> APIClient {
        AssistantURLProtocol.reset(replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AssistantURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        return APIClient(session: session, validToken: token, refreshToken: refresh)
    }

    private final class Transcript {
        var ids: [Int] = []
        var chunks: [String] = []
        var completed: [String] = []
        var statuses: [String] = []
        var thoughts: [String] = []
        var proposals: [RecordProposal] = []
        var reports: [ReportJob] = []
    }

    private func stream(_ client: APIClient, into transcript: Transcript) async throws {
        try await client.streamChat(
            chatId: 42, message: "Check my portfolio", image: Data([1, 2, 3]),
            onInit: { id, _ in transcript.ids.append(id) },
            onChunk: { transcript.chunks.append($0) },
            onDone: { text, _ in transcript.completed.append(text) },
            onStatus: { transcript.statuses.append($0) },
            onAction: { transcript.proposals.append($0) },
            onReport: { transcript.reports.append($0) },
            onThinking: { transcript.thoughts.append($0) }
        )
    }

    func testFragmentedStreamDeliversTextProposalsAndReportsWithoutSavingRecords() async throws {
        let wire = """
        : keep-alive

        data: {"type":"init","chat_id":42,"title":"Portfolio"}

        data: {"type":"status","text":"Reading holdings…"}

        data: {"type":"thinking","delta":"Checking the dates"}

        data: {"type":"chunk","delta":"台積電 · **NT$1,234.56**"}

        data: {"type":"action","records":{"trades":[{"op":"create","ticker":"2330","type":"buy","shares":100,"price":1050,"date":"2026-10-06","market":"TW","duplicate_of":9},{"op":"delete","id":12,"ticker":"AAPL","consequences":["Position will change"]}],"dividends":[],"summary":"Review these records"}}

        data: {"type":"action","report":{"report_id":"report-test","status":"ready","row_count":3,"title":"Performance"}}

        data: {"type":"future-compatible-event","value":true}

        data: {"type":"done","content":"## Portfolio\\n\\n| Market | P/L |\\n| --- | --- |\\n| TW | NT$1,234.56 |","queries":[]}

        """
        let api = client([.sse(wire)])
        let transcript = Transcript()
        try await stream(api, into: transcript)
        XCTAssertEqual(transcript.ids, [42])
        XCTAssertEqual(transcript.chunks, ["台積電 · **NT$1,234.56**"])
        XCTAssertEqual(transcript.statuses, ["Reading holdings…"])
        XCTAssertEqual(transcript.thoughts, ["Checking the dates"])
        XCTAssertEqual(transcript.completed.count, 1)
        XCTAssertTrue(transcript.completed[0].contains("\n\n| Market | P/L |"))
        XCTAssertEqual(transcript.proposals.count, 1)
        XCTAssertEqual(transcript.proposals[0].trades[0].duplicateOf, 9)
        XCTAssertEqual(transcript.proposals[0].trades[1].op, .delete)
        XCTAssertEqual(transcript.proposals[0].trades[1].recordID, 12)
        XCTAssertEqual(transcript.reports.first?.reportID, "report-test")
        XCTAssertEqual(transcript.reports.first?.rowCount, 3)
        // Receiving an agent action must not send a write request to /trades.
        XCTAssertEqual(AssistantURLProtocol.requests.count, 1)
        XCTAssertEqual(AssistantURLProtocol.requests[0].url?.path, "/api/ai/chat")
        XCTAssertEqual(AssistantURLProtocol.requests[0].value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNil(AssistantURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testClosedStreamWithoutDoneKeepsPartialTextAndTriggersRecovery() async throws {
        let api = client([.sse("data: {\"type\":\"chunk\",\"delta\":\"Partial answer\"}\n\n")])
        let transcript = Transcript()
        do {
            try await stream(api, into: transcript)
            XCTFail("An incomplete stream must throw so the view model can recover")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("before the assistant finished"))
        }
        XCTAssertEqual(transcript.chunks, ["Partial answer"])
        XCTAssertTrue(transcript.completed.isEmpty)
    }

    func testMalformedEventsDoNotSilentlyCompleteOrLoseActionCards() async {
        let malformed = [
            "data: not JSON\n\n",
            "data: {\"type\":\"init\",\"chat_id\":0}\n\n",
            "data: {\"type\":\"chunk\",\"delta\":123}\n\n",
            "data: {\"type\":\"action\",\"records\":{\"trades\":\"invalid\"}}\n\n",
            "data: {\"type\":\"action\",\"report\":{\"title\":\"Missing ID\"}}\n\n",
            "data: {\"type\":\"done\"}\n\n",
        ]
        for wire in malformed {
            let transcript = Transcript()
            do {
                try await stream(client([.sse(wire)]), into: transcript)
                XCTFail("Malformed event unexpectedly succeeded: \(wire)")
            } catch {
                guard case APIError.decoding = error else {
                    XCTFail("Expected decoding error, got \(error)")
                    continue
                }
            }
            XCTAssertTrue(transcript.completed.isEmpty)
            XCTAssertTrue(transcript.proposals.isEmpty)
            XCTAssertTrue(transcript.reports.isEmpty)
        }
    }

    func testServerErrorPreservesItsActionableMessage() async {
        let api = client([.sse("data: {\"type\":\"error\",\"detail\":\"Gemini usage limit reached. Try again shortly.\"}\n\n")])
        do {
            try await stream(api, into: Transcript())
            XCTFail("Expected server error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Gemini usage limit reached. Try again shortly.")
        }
    }

    func testHTTPErrorsKeepJSONDetailsAndDoNotExposeHTML() async {
        for (status, body, expected) in [
            (503, "{\"detail\":\"Add a Gemini key in AI settings.\"}", "Add a Gemini key in AI settings."),
            (429, "{\"detail\":\"Daily AI limit reached. Try tomorrow.\"}", "Daily AI limit reached. Try tomorrow."),
            (502, "<html>Proxy debug details</html>", "Request failed (502)"),
        ] {
            let api = client([AssistantStubReply(status: status, body: body)])
            do {
                try await stream(api, into: Transcript())
                XCTFail("Expected HTTP \(status)")
            } catch {
                guard case let APIError.http(code, detail) = error else {
                    XCTFail("Expected HTTP error, got \(error)")
                    continue
                }
                XCTAssertEqual(code, status)
                XCTAssertEqual(detail, expected)
            }
        }
    }

    func testExpiredTokenRefreshesOnceAndResendsTheSameChatRequest() async throws {
        var refreshes = 0
        let api = client([
            AssistantStubReply(status: 401, body: "{\"detail\":\"Invalid Google credential\"}"),
            .sse("data: {\"type\":\"done\",\"content\":\"Recovered\"}\n\n"),
        ], token: { "old-test-token" }, refresh: { refreshes += 1; return "new-test-token" })
        let transcript = Transcript()
        try await stream(api, into: transcript)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(transcript.completed, ["Recovered"])
        let requests = AssistantURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer old-test-token")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer new-test-token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), requests[1].value(forHTTPHeaderField: "Content-Type"))
    }

    func testRejectedRefreshedTokenStopsInsteadOfRetryingIndefinitely() async {
        var refreshes = 0
        let failure = AssistantStubReply(status: 401, body: "{\"detail\":\"Invalid Google credential\"}")
        let api = client([failure, failure], token: { "old-test-token" }, refresh: {
            refreshes += 1
            return "new-test-token"
        })
        do {
            try await stream(api, into: Transcript())
            XCTFail("Expected sign-in error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sign out and back in"))
        }
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(AssistantURLProtocol.requests.count, 2)
    }

    func testCompletionIsDeliveredOnceAndDoesNotWaitForExtraEvents() async throws {
        let api = client([.sse("""
        data: {"type":"done","content":"Finished"}

        data: {"type":"done","content":"Duplicate"}

        data: {"type":"error","detail":"Late unrelated event"}

        """)])
        let transcript = Transcript()
        try await stream(api, into: transcript)
        XCTAssertEqual(transcript.completed, ["Finished"])
    }
}

private struct AssistantStubReply {
    let status: Int
    let body: String
    var contentType = "application/json"

    static func sse(_ body: String) -> Self {
        Self(status: 200, body: body, contentType: "text/event-stream")
    }
}

private final class AssistantURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var replies: [AssistantStubReply] = []
    private static var capturedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    static func reset(_ newReplies: [AssistantStubReply]) {
        lock.lock()
        defer { lock.unlock() }
        replies = newReplies
        capturedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let reply = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        Self.lock.unlock()
        guard let reply, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": reply.contentType]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let bytes = Data(reply.body.utf8)
        // Split inside JSON and multibyte characters to exercise the byte stream.
        for offset in stride(from: 0, to: bytes.count, by: 7) {
            client?.urlProtocol(self, didLoad: bytes.subdata(in: offset..<min(offset + 7, bytes.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
