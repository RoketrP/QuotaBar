import AppKit
import SwiftUI

private enum SponsorMethod: String, CaseIterable, Identifiable {
    case wechat = "微信"
    case alipay = "支付宝"

    var id: Self { self }

    var fileName: String {
        switch self {
        case .wechat: "sponsor-wechat"
        case .alipay: "sponsor-alipay"
        }
    }
}

private var sponsorResourceBundle: Bundle {
    #if SWIFT_PACKAGE
    let bundleName = "QuotaBar_QuotaBar.bundle"
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(bundleName),
        Bundle.main.bundleURL.appendingPathComponent(bundleName)
    ]

    return candidates
        .compactMap { $0 }
        .lazy
        .compactMap(Bundle.init(url:))
        .first ?? .module
    #else
    .main
    #endif
}

struct SponsorView: View {
    @State private var method: SponsorMethod = .wechat
    private let afdianURL = URL(string: "https://afdian.com/a/codex_used")!

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.pink)

                Text("支持 QuotaBar")
                    .font(.title2.bold())

                Text("QuotaBar 永久免费。赞助完全自愿，金额由你决定。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Picker("赞助方式", selection: $method) {
                ForEach(SponsorMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)

            Button {
                NSWorkspace.shared.open(afdianURL)
            } label: {
                Label("前往爱发电赞助", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("在浏览器中打开 QuotaBar 的爱发电主页")

            if let image = sponsorImage(for: method) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .accessibilityLabel("\(method.rawValue)收款码")
                    .frame(maxWidth: 360, maxHeight: 480)
            } else {
                ContentUnavailableView(
                    "无法载入收款码",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("请重新下载完整的 QuotaBar 发布包。")
                )
                .frame(maxWidth: 360, maxHeight: 480)
            }

            Text("也可以使用下方微信或支付宝收款码。感谢你帮助这个项目继续维护。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 440, height: 640)
    }

    private func sponsorImage(for method: SponsorMethod) -> NSImage? {
        let locations = [
            sponsorResourceBundle.url(
                forResource: method.fileName,
                withExtension: "jpg",
                subdirectory: "Sponsors"
            ),
            sponsorResourceBundle.url(
                forResource: method.fileName,
                withExtension: "jpg"
            )
        ]

        return locations
            .compactMap { $0 }
            .lazy
            .compactMap(NSImage.init(contentsOf:))
            .first
    }
}
