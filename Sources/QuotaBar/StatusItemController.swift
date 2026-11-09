import AppKit
import Combine
import QuotaBarCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let menu = NSMenu()
    private let model: AppModel
    private let preferences: AppPreferences
    private let floatingPanel: FloatingPanelController
    private let openSettingsAction: () -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(
        model: AppModel,
        preferences: AppPreferences,
        floatingPanel: FloatingPanelController,
        openSettings: @escaping () -> Void
    ) {
        self.model = model
        self.preferences = preferences
        self.floatingPanel = floatingPanel
        openSettingsAction = openSettings
        super.init()

        let contentController = NSHostingController(
            rootView: MenuContentView(model: model, openSettings: openSettings)
                .fixedSize(horizontal: false, vertical: true)
        )
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = contentController

        menu.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.toolTip = "QuotaBar"
        }

        model.objectWillChange
            .merge(with: preferences.objectWillChange)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)

        updateStatusItem()
    }

    func showDetails() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.close()
            return
        }

        updatePopoverSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

#if DEBUG
    func showContextMenuForTesting() {
        guard let button = statusItem.button else { return }
        showContextMenu(from: button)
    }
#endif

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            showDetails()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        popover.close()
        rebuildMenu()
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let summaryItem = NSMenuItem(title: usageSummary, action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(.separator())

        let floatingItem = item("显示悬浮窗", action: #selector(toggleFloatingPanel))
        floatingItem.state = preferences.showFloatingPanel ? .on : .off
        menu.addItem(floatingItem)
        menu.addItem(item("打开详细面板", action: #selector(openDetails)))

        let refreshItem = item("立即刷新", action: #selector(refreshUsage))
        refreshItem.isEnabled = model.account.isAuthenticated
            && !model.isDemoMode
            && !model.isRefreshing
            && model.phase != .loadingUsage
            && model.phase != .loggingIn
        menu.addItem(refreshItem)

        menu.addItem(item("本地用量历史…", action: #selector(openHistory)))
        menu.addItem(item("打开官方用量页", action: #selector(openUsageDashboard)))
        menu.addItem(.separator())
        menu.addItem(item("设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(item("退出 QuotaBar", action: #selector(quit), keyEquivalent: "q"))
    }

    private func item(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func toggleFloatingPanel() {
        floatingPanel.toggle()
    }

    @objc private func openDetails() {
        showDetails()
    }

    @objc private func refreshUsage() {
        Task { await model.refresh() }
    }

    @objc private func openHistory() { UsageHistoryWindowController.shared.show() }

    @objc private func openUsageDashboard() {
        model.openUsageDashboard()
    }

    @objc private func openSettings() {
        openSettingsAction()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let display = StatusItemDisplayFormatter.make(
            remainingPercent: model.headlineRemaining,
            style: preferences.statusItemStyle
        )

        let label = model.selectedWindow.map { window in
            window.windowDurationMinutes == 300 ? "5h" :
            window.windowDurationMinutes == 10_080 ? "周" : window.windowLabel
        } ?? {
            switch preferences.headlineSelection {
            case .primary: return "额度"
            case .fiveHour: return "5h"
            case .weekly: return "周"
            case .lowest: return "最低"
            }
        }()
        button.title = (display.title.isEmpty ? "" : "\(label) \(display.title)") + (model.isStale ? " !" : "")
        button.toolTip = model.isStale ? "额度数据已过期，正在自动重连" : "\(label) · QuotaBar"

        if display.showsIcon {
            let image = NSImage(
                systemSymbolName: symbolName(for: model.headlineRemaining),
                accessibilityDescription: "Codex 用量"
            )
            image?.isTemplate = true
            button.image = image
        } else {
            button.image = nil
        }

        if popover.isShown {
            DispatchQueue.main.async { [weak self] in
                self?.updatePopoverSize()
            }
        }
    }

    private func updatePopoverSize() {
        guard let hostingController = popover.contentViewController else { return }
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingHeight = hostingController.view.fittingSize.height
        popover.contentSize = NSSize(
            width: 360,
            height: min(620, max(220, fittingHeight))
        )
    }

    private var usageSummary: String {
        if model.isStale { return "额度数据已过期 · 正在自动重连" }
        guard let windows = model.snapshot?.preferredBucket?.windows,
              !windows.isEmpty
        else {
            switch model.phase {
            case .needsLogin, .loggingIn: return "尚未登录 ChatGPT"
            case .failed: return "暂时无法读取用量"
            default: return "正在读取 Codex 用量"
            }
        }

        return windows.prefix(2).map { window in
            let label: String
            if window.windowDurationMinutes == 10_080 {
                label = "周"
            } else if window.windowDurationMinutes % 60 == 0 {
                label = "\(window.windowDurationMinutes / 60) 小时"
            } else {
                label = "\(window.windowDurationMinutes) 分"
            }
            return "\(label) \(Int(window.remainingPercent.rounded()))%"
        }
        .joined(separator: " · ")
    }

    private func symbolName(for remaining: Double?) -> String {
        guard let remaining else { return "gauge.with.dots.needle.33percent" }
        switch remaining {
        case 67...: return "gauge.with.dots.needle.67percent"
        case 34..<67: return "gauge.with.dots.needle.50percent"
        default: return "gauge.with.dots.needle.33percent"
        }
    }
}
