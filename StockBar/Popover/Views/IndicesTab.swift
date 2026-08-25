import SwiftUI

struct IndicesTab: View {
    @EnvironmentObject var refresher: QuoteRefresher
    @EnvironmentObject var prefs: TickerPreferences
    @EnvironmentObject var vm: PopoverViewModel   // 拿 settingsRepo 读浏览器模板

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if refresher.indexQuotes.isEmpty {
                    emptyState
                } else {
                    ForEach(refresher.indexQuotes) { q in
                        indexRow(q)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .frame(maxHeight: 320)
    }

    private func openInBrowser(_ index: IndexDescriptor) {
        let template = vm.settingsRepo.string(BrowserURLBuilder.templateKey) ?? BrowserURLBuilder.Template.xueqiu.rawValue
        if let url = BrowserURLBuilder.url(template: template, index: index) {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func indexRow(_ quote: IndexQuote) -> some View {
        let row = IndexRow(quote: quote, scheme: prefs.colorScheme)
        let template = vm.settingsRepo.string(BrowserURLBuilder.templateKey) ?? BrowserURLBuilder.Template.xueqiu.rawValue
        if BrowserURLBuilder.url(template: template, index: quote.descriptor) != nil {
            row
                .contextMenu {
                    Button(L("action.openInBrowser", comment: "")) {
                        openInBrowser(quote.descriptor)
                    }
                }
                .onTapGesture(count: 2) {
                    openInBrowser(quote.descriptor)
                }
        } else {
            row
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(L("indices.empty", comment: ""))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

private struct IndexRow: View {
    let quote: IndexQuote
    let scheme: TickerColorScheme

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.descriptor.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(quote.descriptor.market.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatPrice(quote.price))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                HStack(spacing: 4) {
                    let color: Color = quote.change >= 0 ? SemanticColors.up(scheme: scheme) : SemanticColors.down(scheme: scheme)
                    Text(signed(quote.change))
                        .font(.system(size: 10))
                        .foregroundColor(color)
                        .monospacedDigit()
                    Text(String(format: "%+.2f%%", quote.changePct * 100))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(color)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func formatPrice(_ price: Decimal) -> String {
        DecimalFormatting.string(
            price,
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
            usesGroupingSeparator: true
        ) ?? "\(price)"
    }

    private func signed(_ value: Decimal) -> String {
        let sign = value >= 0 ? "+" : ""
        let text = DecimalFormatting.string(
            value,
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
            usesGroupingSeparator: false
        ) ?? "\(value)"
        return sign + text
    }
}
