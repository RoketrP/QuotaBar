import AppKit
import QuotaBarCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published var isEnabled = SMAppService.mainApp.status == .enabled
    @Published var errorMessage: String?

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = SMAppService.mainApp.status == .enabled
            errorMessage = nil
        } catch {
            isEnabled = SMAppService.mainApp.status == .enabled
            errorMessage = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @StateObject private var launchAtLogin = LaunchAtLoginManager()
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var notifications = UsageNotificationService.shared
    @ObservedObject private var hotKey = GlobalHotKeyController.shared
    @ObservedObject private var officialUpdates = OfficialUpdatesService.shared
    @State private var isUpdatingNotifications = false
    let openSponsor: () -> Void

    var body: some View {
        Form {
            Section("通用") {
                Toggle(
                    "登录 Mac 后自动启动",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )

                if let errorMessage = launchAtLogin.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                    .foregroundStyle(.red)
                }
            }

            Section("显示") {
                Toggle("显示悬浮窗", isOn: $preferences.showFloatingPanel)
                Toggle(
                    "在所有桌面和全屏 App 中显示",
                    isOn: $preferences.floatingAcrossSpaces
                )

                Picker("菜单栏样式", selection: $preferences.statusItemStyle) {
                    Text("图标 + 百分比").tag(StatusItemDisplayStyle.iconAndPercentage)
                    Text("仅百分比").tag(StatusItemDisplayStyle.percentageOnly)
                    Text("仅图标").tag(StatusItemDisplayStyle.iconOnly)
                }
                .pickerStyle(.segmented)
                Picker("菜单栏额度", selection: $preferences.headlineSelection) {
                    ForEach(HeadlineSelection.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("指定窗口未返回时显示“--%”，不会用其他窗口冒充。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("本地用量历史") {
                Toggle("记录最近 30 天额度", isOn: $preferences.historyEnabled)
                Text("默认关闭。只在本机保存额度快照，不含邮箱或凭证；退出或切换账户时清空。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("查看趋势、导出或清空…") { UsageHistoryWindowController.shared.show() }
            }

            Section("快捷操作") {
                Toggle("启用全局快捷键", isOn: $preferences.globalHotKeyEnabled)

                HStack {
                    Text("显示或隐藏悬浮窗")
                    Spacer()
                    Text("⌥⌘Q")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = hotKey.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("额度提醒") {
                Toggle(
                    "启用系统通知",
                    isOn: Binding(
                        get: { preferences.notificationsEnabled },
                        set: { updateNotifications(enabled: $0) }
                    )
                )
                .disabled(isUpdatingNotifications)

                Picker("低额度阈值", selection: $preferences.lowQuotaThreshold) {
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                    Text("30%").tag(30)
                }
                .pickerStyle(.segmented)
                .disabled(!preferences.notificationsEnabled)

                Toggle("额度重置后通知", isOn: $preferences.notifyOnReset)
                    .disabled(!preferences.notificationsEnabled)

                if isUpdatingNotifications {
                    ProgressView()
                        .controlSize(.small)
                }

                if let errorMessage = notifications.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if notifications.authorizationStatus == .denied
                    || notifications.errorMessage != nil
                {
                    Button("打开系统通知设置") {
                        openNotificationSettings()
                    }
                }
            }

            Section("AI 动态") {
                Toggle(
                    "显示 AI / Codex 官方动态",
                    isOn: Binding(
                        get: { preferences.officialUpdatesEnabled },
                        set: { setOfficialUpdatesEnabled($0) }
                    )
                )

                Text("启用后每天最多自动访问一次官方 RSS；手动刷新会立即访问。只缓存公开标题、摘要和链接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if preferences.officialUpdatesEnabled {
                    HStack {
                        Button("立即刷新") {
                            Task { await officialUpdates.refresh() }
                        }
                        .disabled(officialUpdates.phase == .loading)

                        if officialUpdates.phase == .loading {
                            ProgressView()
                                .controlSize(.small)
                        } else if let lastUpdated = officialUpdates.lastUpdated {
                            Text("更新于 \(lastUpdated, format: .dateTime.month().day().hour().minute())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage = officialUpdates.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("隐私") {
                Text("QuotaBar 不包含广告或分析 SDK，不会把你的 ChatGPT 登录信息或用量数据发送给开发者。AI 动态只有在你主动启用后才访问官方 RSS。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("支持开发") {
                Text("QuotaBar 永久免费。赞助完全自愿，不会解锁或限制任何功能。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    openSponsor()
                } label: {
                    Label("查看赞助方式", systemImage: "heart")
                }
            }

            Section("关于") {
                Text("QuotaBar 不是 OpenAI 官方产品，也不受 OpenAI 赞助或认可。Codex 与 ChatGPT 是其各自权利人的商标。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        openURL("https://github.com/RoketrP/QuotaBar/releases/latest")
                    } label: {
                        Label("检查新版本", systemImage: "arrow.up.right.square")
                    }

                    Button {
                        openURL("https://github.com/RoketrP/QuotaBar/issues")
                    } label: {
                        Label("反馈问题", systemImage: "exclamationmark.bubble")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 690)
    }

    private func updateNotifications(enabled: Bool) {
        isUpdatingNotifications = true
        Task {
            await notifications.setNotificationsEnabled(enabled)
            isUpdatingNotifications = false
        }
    }

    private func setOfficialUpdatesEnabled(_ enabled: Bool) {
        preferences.officialUpdatesEnabled = enabled
        guard enabled else { return }
        Task { await officialUpdates.refreshIfNeeded(enabled: true) }
    }

    private func openNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openURL(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}
