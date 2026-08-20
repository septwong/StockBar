import AppKit
import SwiftUI

struct AboutPane: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
            VStack(spacing: 4) {
                Text("StockBar").font(.system(size: 22, weight: .bold))
                Text(AppVersion.displayShort).foregroundColor(.secondary).font(.system(size: 12))
            }
            Text(L("about.tagline", comment: ""))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)
            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/septwong/StockBar")!)
                Link(L("about.reportIssue", comment: ""), destination: URL(string: "https://github.com/septwong/StockBar/issues")!)
            }
            .font(.system(size: 11))
            Button(L("menu.checkForUpdates", comment: "")) {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
            Toggle(
                L("update.automaticDownloads", comment: ""),
                isOn: $updater.automaticallyDownloadsUpdates
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            Spacer()
            Text("© 2026 StockBar contributors")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }
}
