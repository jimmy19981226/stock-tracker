import Foundation
import UIKit
import XCTest
@testable import StockTracker

@MainActor
final class AssistantConversationTests: XCTestCase {
    private final class BackgroundRecorder {
        var expirations: [() -> Void] = []
        var ended: [UIBackgroundTaskIdentifier] = []
        var handlers: AssistantBackgroundTasks {
            AssistantBackgroundTasks(begin: { expiration in
                self.expirations.append(expiration)
                return UIBackgroundTaskIdentifier(rawValue: self.expirations.count)
            }, end: { self.ended.append($0) })
        }
    }

    private func model(deferredHistory: Bool = false, refreshPortfolio: @escaping (PortfolioStore) async -> Void = { _ in }) -> (AssistantViewModel, BackgroundRecorder) {
        ConversationURLProtocol.reset(deferredHistory: deferredHistory)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConversationURLProtocol.self]
        let session = URLSession(configuration: config)
        let api = APIClient(session: session, validToken: { nil }, refreshToken: { nil })
        let background = BackgroundRecorder()
        let vm = AssistantViewModel(api: api, backgroundTasks: background.handlers,
                                    refreshPortfolio: refreshPortfolio,
                                    recoveryDelay: { await Task.yield() })
        addTeardownBlock {
            await MainActor.run { vm.reset() }
            session.invalidateAndCancel()
        }
        return (vm, background)
    }

    private enum WaitError: Error { case timedOut }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(timeout))
        while !condition(), clock.now < end { try await Task.sleep(nanoseconds: 10_000_000) }
        guard condition() else {
            XCTFail("Timed out waiting for asynchronous state", file: file, line: line)
            throw WaitError.timedOut
        }
    }

    private func start(_ vm: AssistantViewModel, number: Int = 1) async throws -> ConversationURLProtocol {
        vm.input = "Question \(number)"
        vm.send()
        try await waitUntil { ConversationURLProtocol.chatChannels.count == number && vm.currentChatId == number }
        return try XCTUnwrap(ConversationURLProtocol.chatChannels.last)
    }

    private func stageDraft(_ vm: AssistantViewModel) throws {
        vm.input = "Unsent follow-up"
        vm.present(.demoBatch)
        vm.reportIDs = ["report-from-old-chat"]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        vm.attachImage(try XCTUnwrap(image.pngData()))
    }

    func testOpeningDifferentHistoryDetachesStreamAndClearsItsDraftState() async throws {
        let (vm, _) = model()
        let old = try await start(vm)
        try stageDraft(vm)
        await vm.openChat(20)
        XCTAssertEqual(vm.currentChatId, 20)
        XCTAssertEqual(vm.messages.map(\.content), ["History 20"])
        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(vm.input, "")
        XCTAssertNil(vm.pendingAttachment)
        XCTAssertNil(vm.pendingImport)
        XCTAssertTrue(vm.importTradeOn.isEmpty)
        XCTAssertTrue(vm.reportIDs.isEmpty)
        try await waitUntil { old.wasStopped }
        old.event(["type": "chunk", "delta": "Stale answer"])
        old.event(["type": "done", "content": "Wrong conversation"])
        await Task.yield()
        XCTAssertEqual(vm.messages.map(\.content), ["History 20"])
        XCTAssertEqual(vm.streamingText, "")
        XCTAssertEqual(ConversationURLProtocol.stopRequests, 0,
                       "History navigation detaches the client; the old server reply can finish in history")
    }

    func testOpeningCurrentHistoryPreservesStreamAndUnsentDraft() async throws {
        let (vm, _) = model()
        let channel = try await start(vm)
        try stageDraft(vm)
        await vm.openChat(1)
        XCTAssertTrue(vm.isStreaming)
        XCTAssertEqual(vm.input, "Unsent follow-up")
        XCTAssertNotNil(vm.pendingAttachment)
        XCTAssertNotNil(vm.pendingImport)
        XCTAssertFalse(channel.wasStopped)
        channel.event(["type": "done", "content": "Finished once"])
        try await waitUntil { !vm.isStreaming }
        XCTAssertEqual(vm.messages.filter { $0.role == "assistant" }.map(\.content), ["Finished once"])
        XCTAssertEqual(vm.input, "Unsent follow-up")
    }

    func testResetClearsConversationDraftAndProposal() throws {
        let (vm, _) = model()
        try stageDraft(vm)
        vm.messages = [ChatMessage(role: "assistant", content: "Old conversation")]
        vm.reset()
        XCTAssertEqual(vm.input, "")
        XCTAssertNil(vm.pendingAttachment)
        XCTAssertNil(vm.pendingImport)
        XCTAssertTrue(vm.reportIDs.isEmpty)
        XCTAssertTrue(vm.messages.isEmpty)
    }

    func testOldStreamCleanupCannotEndNewRunsBackgroundAllowance() async throws {
        let (vm, background) = model()
        let old = try await start(vm)
        vm.reset()
        // send() acquires the next allowance before cancelled A can resume cleanup.
        vm.input = "Second question"
        vm.send()
        try await waitUntil { old.wasStopped && ConversationURLProtocol.chatChannels.count == 2 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(vm.isStreaming)
        XCTAssertEqual(background.expirations.count, 2)
        XCTAssertEqual(background.ended.map(\.rawValue), [1])
        let latest = try XCTUnwrap(ConversationURLProtocol.chatChannels.last)
        latest.event(["type": "done", "content": "New answer"])
        try await waitUntil { !vm.isStreaming }
        XCTAssertEqual(background.ended.map(\.rawValue), [1, 2])
    }

    func testOldExpirationHandlerCannotEndNewRunsBackgroundAllowance() async throws {
        let (vm, background) = model()
        _ = try await start(vm)
        let oldExpiration = try XCTUnwrap(background.expirations.first)
        vm.reset()
        _ = try await start(vm, number: 2)
        oldExpiration()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(background.ended.map(\.rawValue), [1])
        XCTAssertTrue(vm.isStreaming)
        background.expirations[1]()
        try await waitUntil { background.ended.map(\.rawValue) == [1, 2] }
        XCTAssertTrue(vm.isStreaming, "Expiration releases background time; server generation remains recoverable")
    }

    func testDelayedHistoryCannotReplaceANewerSend() async throws {
        let (vm, _) = model(deferredHistory: true)
        let loading = Task { await vm.openChat(20) }
        try await waitUntil { ConversationURLProtocol.historyChannels.count == 1 }
        _ = try await start(vm)
        ConversationURLProtocol.historyChannels[0].history(20)
        await loading.value
        XCTAssertEqual(vm.currentChatId, 1)
        XCTAssertTrue(vm.isStreaming)
        XCTAssertEqual(vm.messages.map(\.content), ["Question 1"])
    }

    func testOutOfOrderHistoryLoadsKeepTheLastSelectedConversation() async throws {
        let (vm, _) = model(deferredHistory: true)
        let first = Task { await vm.openChat(20) }
        try await waitUntil { ConversationURLProtocol.historyChannels.count == 1 }
        let second = Task { await vm.openChat(30) }
        try await waitUntil { ConversationURLProtocol.historyChannels.count == 2 }
        ConversationURLProtocol.historyChannels[1].history(30)
        await second.value
        ConversationURLProtocol.historyChannels[0].history(20)
        await first.value
        XCTAssertEqual(vm.currentChatId, 30)
        XCTAssertEqual(vm.messages.map(\.content), ["History 30"])
    }

    func testConfirmedBatchFinishesWithoutTouchingAnotherConversationsDraft() async throws {
        var reloads = 0
        let (vm, _) = model(refreshPortfolio: { _ in reloads += 1 })
        let rows = RecordProposal.demoLegacy.trades
        vm.present(RecordProposal(trades: rows + rows))
        let submission = Task { await vm.submitImport(store: PortfolioStore()) }
        try await waitUntil { ConversationURLProtocol.tradeChannels.count == 1 }
        await vm.openChat(20)
        vm.present(.demoEdit)
        vm.input = "Draft in new conversation"
        ConversationURLProtocol.tradeChannels[0].trade(1)
        try await waitUntil { ConversationURLProtocol.tradeChannels.count == 2 }
        ConversationURLProtocol.tradeChannels[1].trade(2)
        await submission.value
        XCTAssertEqual(reloads, 1, "Confirmed writes must still refresh the shared portfolio")
        XCTAssertEqual(vm.currentChatId, 20)
        XCTAssertEqual(vm.messages.map(\.content), ["History 20"])
        XCTAssertEqual(vm.pendingImport, .demoEdit)
        XCTAssertEqual(vm.input, "Draft in new conversation")
        XCTAssertFalse(vm.isSubmittingImport)
    }

    func testConfirmCannotSubmitTheSameProposalTwiceWhilePending() async throws {
        let (vm, _) = model()
        vm.present(.demoLegacy)
        let first = Task { await vm.submitImport(store: PortfolioStore()) }
        try await waitUntil { ConversationURLProtocol.tradeChannels.count == 1 }
        await vm.submitImport(store: PortfolioStore())
        XCTAssertEqual(ConversationURLProtocol.tradeChannels.count, 1)
        ConversationURLProtocol.tradeChannels[0].trade(1)
        await first.value
        XCTAssertNil(vm.pendingImport)
        XCTAssertFalse(vm.isSubmittingImport)
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertTrue(vm.messages[0].content.contains("added 1 record"))
    }

    func testRecoveryCannotReplaceANewerConversationAfterAwaitingNetwork() async throws {
        let (vm, _) = model(deferredHistory: true)
        let old = try await start(vm)
        old.event(["type": "error", "detail": "Connection interrupted"])
        old.finish()
        try await waitUntil(timeout: 5) { ConversationURLProtocol.historyChannels.count == 1 }
        let history = try XCTUnwrap(ConversationURLProtocol.historyChannels.first)
        vm.reset()
        _ = try await start(vm, number: 2)
        history.history(1, messages: [
            ["role": "user", "content": "Old question"],
            ["role": "assistant", "content": "Old recovered answer"],
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.currentChatId, 2)
        XCTAssertTrue(vm.isStreaming)
        XCTAssertEqual(vm.messages.map(\.content), ["Question 2"])
    }
}

private final class ConversationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var chats: [ConversationURLProtocol] = []
    private static var histories: [ConversationURLProtocol] = []
    private static var trades: [ConversationURLProtocol] = []
    private static var deferred = false
    private static var stops = 0
    private var stopped = false

    static var chatChannels: [ConversationURLProtocol] { lock.withLock { chats } }
    static var tradeChannels: [ConversationURLProtocol] { lock.withLock { trades } }
    static var historyChannels: [ConversationURLProtocol] { lock.withLock { histories } }
    static var stopRequests: Int { lock.withLock { stops } }
    var wasStopped: Bool { Self.lock.withLock { stopped } }

    static func reset(deferredHistory: Bool) {
        lock.withLock { chats = []; histories = []; trades = []; stops = 0; deferred = deferredHistory }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path == "/api/ai/chat" {
            let number = Self.lock.withLock { Self.chats.append(self); return Self.chats.count }
            respond(contentType: "text/event-stream")
            event(["type": "init", "chat_id": number, "title": "Chat \(number)"])
        } else if path == "/api/trades", request.httpMethod == "POST" {
            Self.lock.withLock { Self.trades.append(self) }
        } else if path.hasSuffix("/stop") {
            Self.lock.withLock { Self.stops += 1 }
            respond(contentType: "application/json", status: 204)
            finish()
        } else if path.hasPrefix("/api/ai/chats/") {
            let shouldDefer = Self.lock.withLock { Self.histories.append(self); return Self.deferred }
            if !shouldDefer { history(Int(path.split(separator: "/").last ?? "0") ?? 0) }
        } else {
            respond(contentType: "application/json", status: 404)
            finish()
        }
    }

    private func respond(contentType: String, status: Int = 200) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": contentType]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func event(_ event: [String: Any]) {
        guard !wasStopped, let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        var wire = Data("data: ".utf8)
        wire.append(data)
        wire.append(Data("\n\n".utf8))
        client?.urlProtocol(self, didLoad: wire)
    }

    func history(_ id: Int, messages: [[String: String]]? = nil) {
        guard !wasStopped else { return }
        respond(contentType: "application/json")
        let body: [String: Any] = [
            "id": id, "title": "History \(id)", "created_at": "2026-10-27", "updated_at": "2026-10-27",
            "messages": messages ?? [["role": "assistant", "content": "History \(id)"]],
        ]
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        finish()
    }

    func trade(_ id: Int) {
        guard !wasStopped else { return }
        respond(contentType: "application/json")
        let body: [String: Any] = ["id": id, "type": "buy", "ticker": "2330", "shares": 100,
                                   "price": 1050, "trade_date": "2026-10-27", "fee": 20,
                                   "market": "TW", "created_at": "2026-10-27", "status": "open"]
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        finish()
    }

    func finish() { if !wasStopped { client?.urlProtocolDidFinishLoading(self) } }
    override func stopLoading() { Self.lock.withLock { stopped = true } }
}
