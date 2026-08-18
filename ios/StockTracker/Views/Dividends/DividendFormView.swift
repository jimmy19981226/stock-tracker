import SwiftUI

/// Add or edit a dividend. Shares the one record sheet with trades — the same
/// explicit market control, the same currency rules, the same validation.
struct DividendFormView: View {
    let market: MarketCode
    let existing: Dividend?
    /// Pre-fills the ticker when adding from a stock's detail page.
    var prefillTicker: String? = nil

    var body: some View {
        RecordFormSheet(kind: .dividend, market: market, prefillTicker: prefillTicker,
                        existingTrade: nil, existingDividend: existing)
    }
}
