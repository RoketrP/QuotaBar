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

            Section("隐私") {
                Text("QuotaBar 不包含广告或分析 SDK，不会把你的 ChatGPT 登录信息或用量数据发送给开发者。")
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
