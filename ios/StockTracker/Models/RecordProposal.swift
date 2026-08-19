import Foundation

/// A write tool's proposal, as it arrives from the assistant.
///
/// **Nothing here is saved.** A write tool never touches the database — it
/// hands the app this payload, the app renders a confirm card, and the records
/// reach the backend through the ordinary REST endpoints only after the user
/// confirms. That rule holds for every write tool without exception, which is
/// why this type models a *proposal* and not a record.
///
/// It also has to keep parsing what the previous release sent: the backend
/// deploys ahead of the App Store build, and an older payload has no `op`,
/// no `id` and no `before`/`after`. `op` therefore defaults to `.create` and
/// every added field is optional — decoding an old payload yields exactly the
/// add-card behaviour it always had.
struct RecordProposal: Decodable, Equatable {
    var trades: [TradeProposal] = []
    var dividends: [DividendProposal] = []
    /// One line for the card header, e.g. "3 buys and 1 sell, Aug 2026".
    var summary: String = ""
    /// The parser's own remarks, from the image-import path.
    var notes: String = ""

    enum CodingKeys: String, CodingKey { case trades, dividends, summary, notes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trades = (try? c.decode([TradeProposal].self, forKey: .trades)) ?? []
        dividends = (try? c.decode([DividendProposal].self, forKey: .dividends)) ?? []
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
    }

    init(trades: [TradeProposal] = [], dividends: [DividendProposal] = [],
         summary: String = "", notes: String = "") {
        self.trades = trades
        self.dividends = dividends
        self.summary = summary
        self.notes = notes
    }

    var isEmpty: Bool { trades.isEmpty && dividends.isEmpty }
    var count: Int { trades.count + dividends.count }

    /// What kind of card this whole proposal is. A batch of creates gets the
    /// batch card; a single correction or deletion gets its own, because the
    /// question each asks the reader is different — "is this right?" versus
    /// "do you want this gone?".
    enum Shape { case create, update, delete, batch }

    var shape: Shape {
        let ops = Set(trades.map(\.op) + dividends.map(\.op))
        if count > 1 || ops.count > 1 { return .batch }
        switch ops.first ?? .create {
        case .create: return count > 1 ? .batch : .create
        case .update: return .update
        case .delete: return .delete
        }
    }
}

/// What a proposed row does. Absent in payloads from before the update tools
/// existed, and absent means create — see `RecordProposal`.
enum RecordOp: String, Codable, Equatable {
    case create, update, delete
}

/// A proposed trade: a new one, a correction to an existing one, or a deletion.
struct TradeProposal: Decodable, Equatable, Identifiable {
    var op: RecordOp = .create
    /// The row being changed. Present for update and delete only.
    var recordID: Int?
    var type: TradeType?
    var ticker: String?
    var shares: Double?
    var price: Double?
    var date: String?
    var fee: Double?
    var market: MarketCode?
    var notes: String?

    /// For an update: only the fields that actually move, stored and proposed.
    /// The card lists these and nothing else — a reader needs to see what
    /// changes, not re-read what doesn't.
    var before: [String: JSONValue]?
    var after: [String: JSONValue]?
    /// For update and delete: the unchanged identifying context.
    var record: [String: JSONValue]?
    /// What else moves if this delete goes through. Computed by the server
    /// re-running FIFO without the row — never authored by the model.
    var consequences: [String] = []
    /// An existing row this create would duplicate.
    var duplicateOf: Int?

    var id: String { "\(op.rawValue)-\(recordID ?? 0)-\(ticker ?? "")-\(date ?? "")-\(shares ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case op, id, type, ticker, shares, price, date, fee, market, notes
        case before, after, record, consequences
        case duplicateOf = "duplicate_of"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = (try? c.decode(RecordOp.self, forKey: .op)) ?? .create
        recordID = try? c.decode(Int.self, forKey: .id)
        type = try? c.decode(TradeType.self, forKey: .type)
        ticker = try? c.decode(String.self, forKey: .ticker)
        shares = try? c.decode(Double.self, forKey: .shares)
        price = try? c.decode(Double.self, forKey: .price)
        date = try? c.decode(String.self, forKey: .date)
        fee = try? c.decode(Double.self, forKey: .fee)
        market = try? c.decode(MarketCode.self, forKey: .market)
        notes = try? c.decode(String.self, forKey: .notes)
        before = try? c.decode([String: JSONValue].self, forKey: .before)
        after = try? c.decode([String: JSONValue].self, forKey: .after)
        record = try? c.decode([String: JSONValue].self, forKey: .record)
        consequences = (try? c.decode([String].self, forKey: .consequences)) ?? []
        duplicateOf = try? c.decode(Int.self, forKey: .duplicateOf)
    }

    /// Values to show for the identifying header, falling back to `record`
    /// when this is an update or delete (where the top-level fields are absent).
    func string(_ key: String) -> String? {
        record?[key]?.stringValue
    }
    func number(_ key: String) -> Double? {
        record?[key]?.doubleValue
    }

    var displayTicker: String { ticker ?? string("ticker") ?? "—" }
    var displayType: TradeType { type ?? (string("type") == "sell" ? .sell : .buy) }
    var displayMarket: MarketCode {
        market ?? (string("market") == "US" ? .US : .TW)
    }

    /// The payload the ordinary REST endpoint takes, once confirmed. For an
    /// update, the stored record with the proposed changes applied — the
    /// endpoint replaces the row wholesale, so a partial body would blank the
    /// fields the correction didn't mention.
    func createPayload() -> TradeCreate {
        func merged(_ key: String, _ direct: Double?) -> Double {
            if let value = after?[key]?.doubleValue { return value }
            if let direct { return direct }
            return number(key) ?? 0
        }
        func mergedString(_ key: String, _ direct: String?) -> String? {
            after?[key]?.stringValue ?? direct ?? string(key)
        }
        let typeRaw = mergedString("type", type?.rawValue) ?? "buy"
        return TradeCreate(
            type: TradeType(rawValue: typeRaw) ?? .buy,
            ticker: (mergedString("ticker", ticker) ?? "").uppercased(),
            shares: merged("shares", shares),
            price: merged("price", price),
            tradeDate: mergedString("date", date) ?? "",
            fee: merged("fee", fee),
            notes: mergedString("notes", notes),
            market: MarketCode(rawValue: mergedString("market", market?.rawValue) ?? "") )
    }
}

/// A proposed dividend. Same contract as `TradeProposal`.
struct DividendProposal: Decodable, Equatable, Identifiable {
    var op: RecordOp = .create
    var recordID: Int?
    var ticker: String?
    var amount: Double?
    var date: String?
    var market: MarketCode?
    var notes: String?

    var before: [String: JSONValue]?
    var after: [String: JSONValue]?
    var record: [String: JSONValue]?
    var consequences: [String] = []
    var duplicateOf: Int?

    var id: String { "\(op.rawValue)-\(recordID ?? 0)-\(ticker ?? "")-\(date ?? "")-\(amount ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case op, id, ticker, amount, date, market, notes
        case before, after, record, consequences
        case duplicateOf = "duplicate_of"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = (try? c.decode(RecordOp.self, forKey: .op)) ?? .create
        recordID = try? c.decode(Int.self, forKey: .id)
        ticker = try? c.decode(String.self, forKey: .ticker)
        amount = try? c.decode(Double.self, forKey: .amount)
        date = try? c.decode(String.self, forKey: .date)
        market = try? c.decode(MarketCode.self, forKey: .market)
        notes = try? c.decode(String.self, forKey: .notes)
        before = try? c.decode([String: JSONValue].self, forKey: .before)
        after = try? c.decode([String: JSONValue].self, forKey: .after)
        record = try? c.decode([String: JSONValue].self, forKey: .record)
        consequences = (try? c.decode([String].self, forKey: .consequences)) ?? []
        duplicateOf = try? c.decode(Int.self, forKey: .duplicateOf)
    }

    func string(_ key: String) -> String? { record?[key]?.stringValue }
    func number(_ key: String) -> Double? { record?[key]?.doubleValue }

    var displayTicker: String { ticker ?? string("ticker") ?? "—" }
    var displayMarket: MarketCode { market ?? (string("market") == "US" ? .US : .TW) }

    func createPayload() -> DividendCreate {
        DividendCreate(
            ticker: (after?["ticker"]?.stringValue ?? ticker ?? string("ticker") ?? "").uppercased(),
            amount: after?["amount"]?.doubleValue ?? amount ?? number("amount") ?? 0,
            payDate: after?["date"]?.stringValue ?? date ?? string("date") ?? "",
            notes: after?["notes"]?.stringValue ?? notes ?? string("notes"),
            market: market ?? MarketCode(rawValue: string("market") ?? ""))
    }
}

/// The few JSON scalars a proposal's `before`/`after`/`record` can hold.
///
/// Codable, unlike the proposal types around it: those are decode-only (they
/// arrive from the assistant and are never sent back), and a synthesized
/// encoder would collide with their `id`.
///
/// Those maps are deliberately loose on the wire — they carry whichever fields
/// changed — so they can't be a fixed struct. This keeps them typed enough to
/// format without `Any` leaking into the views.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let v): return v
        case .number(let v): return v == v.rounded() ? String(Int(v)) : String(v)
        case .bool(let v): return String(v)
        case .null: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .number(let v): return v
        case .string(let v): return Double(v)
        default: return nil
        }
    }
}

// MARK: - UI-test fixtures

extension RecordProposal {
    /// Fixtures for the scripted design tour, decoded from the exact JSON the
    /// backend emits — so a screenshot can never show a card the wire format
    /// wouldn't actually produce.
    private static func decode(_ json: String) -> RecordProposal {
        (try? JSONDecoder().decode(RecordProposal.self, from: Data(json.utf8)))
            ?? RecordProposal()
    }

    static let demoBatch = decode("""
    {"summary": "3 buys and 1 dividend, Aug 2026",
     "trades": [
       {"op": "create", "type": "buy", "ticker": "2330", "shares": 100, "price": 1050,
        "date": "2026-08-14", "fee": 150, "market": "TW", "duplicate_of": null},
       {"op": "create", "type": "buy", "ticker": "3217", "shares": 1000, "price": 98,
        "date": "2026-04-22", "fee": 140, "market": "TW", "duplicate_of": 12},
       {"op": "create", "type": "sell", "ticker": "2317", "shares": 500, "price": 210.5,
        "date": "2026-08-11", "fee": 45, "market": "TW", "duplicate_of": null}],
     "dividends": [
       {"op": "create", "ticker": "2603", "amount": 5000, "date": "2026-08-11",
        "market": "TW", "notes": "現金股利", "duplicate_of": null}]}
    """)

    /// The payload shape the previous release emitted — no `op`, no `id`, no
    /// `duplicate_of`. It must still decode, and still mean "create": the
    /// backend deploys ahead of the App Store build, so for a while the old
    /// app sees new payloads and the new app sees old ones.
    static let demoLegacy = decode("""
    {"trades": [{"type": "buy", "ticker": "2330", "shares": 100, "price": 1050,
                 "date": "2026-08-14", "fee": 150, "notes": null}],
     "dividends": [], "notes": ""}
    """)

    static let demoEdit = decode("""
    {"trades": [{"op": "update", "id": 3,
      "before": {"price": 1053, "fee": 150},
      "after": {"price": 1035, "fee": 148},
      "record": {"ticker": "2330", "type": "buy", "shares": 100,
                 "date": "2026-03-06", "market": "TW", "price": 1053, "fee": 150}}],
     "dividends": []}
    """)

    static let demoDelete = decode("""
    {"trades": [{"op": "delete", "id": 8,
      "record": {"ticker": "2603", "type": "buy", "shares": 3000, "price": 62.4,
                 "date": "2025-05-27", "fee": 267, "market": "TW"},
      "consequences": [
        "Realized P/L on the 2603 sell of 2026-05-02 changes from 48,186 to 235,653.",
        "This would leave 3,000 more 2603 shares sold than bought — the remaining sells would have no cost basis."]}],
     "dividends": []}
    """)
}
