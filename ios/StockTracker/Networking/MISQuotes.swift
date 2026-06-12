import Foundation

/// A real-time quote fetched directly from TWSE MIS on this device.
struct MISQuote {
    let price: Double
    let previousClose: Double?
}

/// Device-side client for TWSE MIS — no backend involved. MIS only answers
/// Taiwan consumer connections, so the phone can often reach it even when the
/// cloud backend can't; whenever it does, PortfolioStore overlays these
/// real-time prices on top of the backend's (possibly delayed) TW data.
enum MISQuotes {
    private static let endpoint = "https://mis.twse.com.tw/stock/api/getStockInfo.jsp"

    static func isUp() async -> Bool {
        let quotes = await fetch(["2330"])
        return !quotes.isEmpty
    }

    /// Live quotes keyed by bare ticker. Tries both TSE and OTC prefixes per
    /// ticker; unknown tickers and any transport error just drop out, so an
    /// empty result means "keep the backend's prices".
    static func fetch(_ tickers: [String]) async -> [String: MISQuote] {
        let codes = tickers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !codes.isEmpty else { return [:] }

        var comps = URLComponents(string: endpoint)!
        comps.queryItems = [
            .init(name: "ex_ch", value: codes.flatMap { ["tse_\($0).tw", "otc_\($0).tw"] }
                                            .joined(separator: "|")),
            .init(name: "json", value: "1"),
            .init(name: "delay", value: "0"),
            .init(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://mis.twse.com.tw/stock/index.jsp", forHTTPHeaderField: "Referer")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["msgArray"] as? [[String: Any]]
        else { return [:] }

        var out: [String: MISQuote] = [:]
        for row in rows {
            guard let code = (row["c"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !code.isEmpty else { continue }
            // Price priority mirrors the backend's tw_quotes.py: last trade →
            // bid/ask midpoint → today's open → previous close.
            let ask = posFloat(firstToken(row["a"]))
            let bid = posFloat(firstToken(row["b"]))
            var price = posFloat(row["z"])
            if price == nil, let ask, let bid { price = (ask + bid) / 2 }
            if price == nil { price = ask ?? bid }
            if price == nil { price = posFloat(row["o"]) }
            let prevClose = posFloat(row["y"])
            if price == nil { price = prevClose }
            guard let price else { continue }
            out[code.uppercased()] = MISQuote(price: price, previousClose: prevClose)
        }
        return out
    }

    /// MIS bid/ask fields look like "2300.0000_2305.0000_…_".
    private static func firstToken(_ v: Any?) -> String? {
        (v as? String)?.split(separator: "_").first.map(String.init)
    }

    /// MIS uses "-" and "0.0000" as placeholders; only positive numbers count.
    private static func posFloat(_ v: Any?) -> Double? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces),
              !s.isEmpty, s != "-", let d = Double(s), d > 0 else { return nil }
        return d
    }
}
