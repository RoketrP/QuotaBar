import QuotaBarCore
import SwiftUI

struct FloatingHUDView: View {
    @ObservedObject var model: AppModel
    let onHide: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            header
            content
        }
        .padding(12)
        .frame(width: 300, height: 176)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.primary.opacity(0.12), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            QuotaMark(size: 22, progress: model.headlineRemaining ?? 72)

            Text("QuotaBar")
                .font(.subheadline.weight(.semibold))

            if model.isDemoMode {
                Text("演示")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
            } else {
                Text(model.planLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(!model.account.isAuthenticated || model.isDemoMode || model.isRefreshing)
            .help("立即刷新")

            Button(action: onHide) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("隐藏悬浮窗")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .ready:
            if let snapshot = model.snapshot {
                readyContent(snapshot)
            } else {
                stateView(icon: "hourglass", title: "等待额度数据", detail: "稍后自动刷新")
            }
        case .connecting:
            stateView(icon: "bolt.horizontal", title: "正在启动 Codex", detail: "登录信息仅保存在本机")
        case .needsLogin, .loggingIn:
            stateView(icon: "person.crop.circle", title: "需要登录 ChatGPT", detail: "左键菜单栏图标继续")
        case .loadingUsage:
            stateView(icon: "arrow.triangle.2.circlepath", title: "正在读取剩余用量", detail: "首次读取可能需要几秒")
        case .failed:
            stateView(icon: "exclamationmark.triangle", title: "暂时无法读取用量", detail: "打开详细面板后重试")
        }
    }

    private func readyContent(_ snapshot: RateLimitSnapshot) -> some View {
        VStack(spacing: 8) {
            ForEach(Array((snapshot.preferredBucket?.windows ?? []).prefix(2))) { window in
                FloatingUsageRow(window: window)
            }

            Spacer(minLength: 0)

            HStack {
                Text(model.isDemoMode ? "演示数据" : (model.isStale ? "数据已过期 · 自动重连中" : "自动刷新：每 60 秒"))
                    .foregroundStyle(model.isStale ? .orange : .secondary)
                Spacer()
                if let lastUpdated = model.lastUpdated {
                    Text(lastUpdated, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stateView(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FloatingUsageRow: View {
    let window: RateLimitWindow

    private var tint: Color {
        switch window.remainingPercent {
        case 50...: return .green
        case 20..<50: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(shortLabel)
                .frame(width: 48, alignment: .leading)

            ProgressView(value: window.remainingPercent, total: 100)
                .tint(tint)

            Text("\(Int(window.remainingPercent.rounded()))%")
                .foregroundStyle(tint)
                .frame(width: 34, alignment: .trailing)

            Group {
                if window.resetsAt > Date() {
                    Text(
                        timerInterval: Date()...window.resetsAt,
                        countsDown: true,
                        showsHours: true
                    )
                } else {
                    Text("即将刷新")
                }
            }
            .frame(width: 62, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
    }

    private var shortLabel: String {
        if window.windowDurationMinutes == 10_080 { return "周额度" }
        if window.windowDurationMinutes % 60 == 0 {
            return "\(window.windowDurationMinutes / 60) 小时"
        }
        return "\(window.windowDurationMinutes) 分"
    }
}
