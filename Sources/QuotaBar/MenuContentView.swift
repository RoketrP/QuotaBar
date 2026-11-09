import AppKit
import QuotaBarCore
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var updates = OfficialUpdatesService.shared
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                monitorContent
            }.frame(maxHeight: 480)

            Divider()
            footer
        }
        .frame(width: 360)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            QuotaMark(size: 30, progress: model.headlineRemaining ?? 72)

            VStack(alignment: .leading, spacing: 2) {
                Text("QuotaBar")
                    .font(.headline)
                Text("Codex 用量监控")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(model.planLabel)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(16)
    }

    @ViewBuilder
    private var monitorContent: some View {
        switch model.phase {
        case .connecting:
            LoadingStateView(
                title: "正在启动本地服务",
                detail: "你的登录信息只保存在这台 Mac 上。"
            )
        case .needsLogin, .loggingIn:
            LoginView(model: model)
        case .loadingUsage:
            LoadingStateView(
                title: "正在读取剩余用量",
                detail: "正在连接 Codex 官方额度接口。"
            )
        case .ready:
            if let snapshot = model.snapshot {
                UsageDashboardView(
                    model: model,
                    snapshot: snapshot,
                    preferences: preferences,
                    updates: updates
                )
            } else {
                LoadingStateView(
                    title: "正在读取剩余用量",
                    detail: "首次读取可能需要几秒钟。"
                )
            }
        case .failed:
            ErrorStateView(model: model)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.openUsageDashboard()
            } label: {
                Label("官方用量页", systemImage: "safari")
            }
            .buttonStyle(.plain)

            Spacer()
            Button("历史") { UsageHistoryWindowController.shared.show() }
                .buttonStyle(.plain)

            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("设置")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("退出 QuotaBar")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct UsageDashboardView: View {
    @ObservedObject var model: AppModel
    let snapshot: RateLimitSnapshot
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var updates: OfficialUpdatesService
    @State private var copiedConfirmation = false

    private var windows: [RateLimitWindow] {
        snapshot.preferredBucket?.windows ?? []
    }

    var body: some View {
        VStack(spacing: 14) {
            if model.isDemoMode {
                HStack {
                    Label("演示数据", systemImage: "eye")
                    Spacer()
                    Button("连接真实账户") {
                        Task { await model.connectRealAccountFromDemo() }
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .padding(10)
                .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }

            if model.isStale {
                HStack {
                    Label("数据已过期 · 正在自动重连", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("重新登录") { Task { await model.beginLogin() } }
                        .disabled(model.isRefreshing)
                }.font(.caption).foregroundStyle(.orange)
                if let error = model.errorMessage {
                    Text(error).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let headline = model.selectedWindow {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(headline.remainingPercent.rounded()))")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("% 剩余")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack {
                    Text(headline.windowLabel)
                    Spacer()
                    Text("已用 \(headline.usedPercent, format: .number.precision(.fractionLength(0...1)))%")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("所选额度窗口未返回").foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(windows) { window in
                    UsageWindowCard(window: window)
                }
            }

            OfficialUpdatesCard(preferences: preferences, service: updates)

            HStack {
                if let lastUpdated = model.lastUpdated {
                    Text("更新于 \(lastUpdated, format: .dateTime.hour().minute().second())")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !model.isDemoMode {
                    Button("退出账户") {
                        Task { await model.logout() }
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    copyUsageSummary()
                } label: {
                    Label(
                        copiedConfirmation ? "已复制" : "复制",
                        systemImage: copiedConfirmation ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.borderless)
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
            }
            .font(.caption)
        }
        .padding(16)
    }

    private func copyUsageSummary() {
        let summary = UsageSummaryFormatter.make(
            snapshot: snapshot,
            isDemoMode: model.isDemoMode
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        copiedConfirmation = true

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedConfirmation = false
        }
    }
}

private struct OfficialUpdatesCard: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var service: OfficialUpdatesService
    @State private var showsMore = false

    private var visibleItems: ArraySlice<OfficialUpdateItem> {
        service.items.prefix(showsMore ? 3 : 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("AI / Codex 官方动态", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()

                if preferences.officialUpdatesEnabled {
                    if service.phase == .loading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Button {
                            Task { await service.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("刷新官方动态")
                    }
                }
            }

            if !preferences.officialUpdatesEnabled {
                HStack(alignment: .center, spacing: 10) {
                    Text("每天最多自动读取一次 OpenAI 与 GitHub 官方更新，不发送账户或额度数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("启用") {
                        preferences.officialUpdatesEnabled = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if service.items.isEmpty {
                if service.phase == .failed {
                    Text(service.errorMessage ?? "暂时无法读取官方动态。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("正在读取官方动态…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider()
                    }
                    OfficialUpdateRow(item: item, showsSummary: index == 0)
                }

                if service.items.count > 1 {
                    Button(showsMore ? "收起" : "再看 \(min(2, service.items.count - 1)) 条") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showsMore.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .task(id: preferences.officialUpdatesEnabled) {
            await service.refreshIfNeeded(enabled: preferences.officialUpdatesEnabled)
        }
    }
}

private struct OfficialUpdateRow: View {
    let item: OfficialUpdateItem
    let showsSummary: Bool

    var body: some View {
        Button {
            NSWorkspace.shared.open(item.link)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if showsSummary && !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 5) {
                    Text(item.source.rawValue)
                    if let publishedAt = item.publishedAt {
                        Text("·")
                        Text(publishedAt, format: .dateTime.month().day())
                    }
                    Image(systemName: "arrow.up.right")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在浏览器中打开官方来源")
    }
}

private struct UsageWindowCard: View {
    let window: RateLimitWindow

    private var tint: Color {
        switch window.remainingPercent {
        case 50...:
            return .green
        case 20..<50:
            return .orange
        default:
            return .red
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(window.windowLabel)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }

            ProgressView(value: window.remainingPercent, total: 100)
                .tint(tint)

            HStack {
                Text("重置倒计时")
                    .foregroundStyle(.secondary)
                Spacer()
                if window.resetsAt > Date() {
                    Text(
                        timerInterval: Date()...window.resetsAt,
                        countsDown: true,
                        showsHours: true
                    )
                    .monospacedDigit()
                } else {
                    Text("即将刷新")
                }
            }
            .font(.caption)
        }
        .padding(12)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LoginView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 36))
                .foregroundStyle(.green)

            Text(model.phase == .loggingIn ? "请在浏览器中完成登录" : "连接你的 ChatGPT 账户")
                .font(.headline)

            Text("QuotaBar 使用 Codex 官方登录流程。密码和令牌不会发送给开发者。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if model.phase == .loggingIn {
                ProgressView().controlSize(.small)
                Button("取消登录") { model.cancelLogin() }
            } else {
                HStack {
                    Button("先看演示") {
                        model.enterDemoMode()
                    }
                    .buttonStyle(.bordered)

                    Button("登录 ChatGPT") {
                        Task { await model.beginLogin() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
    }
}

private struct LoadingStateView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}

private struct ErrorStateView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("暂时无法读取用量")
                .font(.headline)
            Text(model.errorMessage ?? "请稍后重试。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("将自动重试，也可以立即重新连接。")
                .font(.caption).foregroundStyle(.secondary)
            Button("重试") {
                Task { await model.activate() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

struct QuotaMark: View {
    let size: CGFloat
    let progress: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.11, blue: 0.16), .black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .stroke(.white.opacity(0.18), lineWidth: size * 0.09)
                .padding(size * 0.2)

            Circle()
                .trim(from: 0, to: max(0.04, progress / 100))
                .stroke(
                    Color(red: 0.22, green: 0.92, blue: 0.55),
                    style: StrokeStyle(
                        lineWidth: size * 0.09,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
                .padding(size * 0.2)

            Circle()
                .fill(.white)
                .frame(width: size * 0.11, height: size * 0.11)
        }
        .frame(width: size, height: size)
    }
}
