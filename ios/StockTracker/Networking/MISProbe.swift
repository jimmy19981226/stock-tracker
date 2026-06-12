import Foundation

/// Device-side reachability check of TWSE MIS — no backend involved. MIS only
/// answers Taiwan consumer connections, so the phone can often reach it even
/// when the cloud backend can't; this distinguishes "MIS is down" from "my
/// relay/backend can't reach it".
enum MISProbe {
    static func isUp() async -> Bool {
        var comps = URLComponents(string: "https://mis.twse.com.tw/stock/api/getStockInfo.jsp")!
        comps.queryItems = [
            .init(name: "ex_ch", value: "tse_2330.tw"),
            .init(name: "json", value: "1"),
            .init(name: "delay", value: "0"),
            .init(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://mis.twse.com.tw/stock/index.jsp", forHTTPHeaderField: "Referer")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["msgArray"] as? [[String: Any]]
        else { return false }
        return !rows.isEmpty
    }
}
