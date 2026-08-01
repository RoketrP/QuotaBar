import AppKit
import SwiftUI

@MainActor
final class QuotaBarAppDelegate: NSObject, NSApplicationDelegate {
    private var floatingPanelController: FloatingPanelController?
    private var statusItemController: StatusItemController?
    private var hotKeyController: GlobalHotKeyController?
    private var settingsWindowController: SettingsWindowController?
    private var sponsorWindowController: SponsorWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let model = AppModel.shared
        let preferences = AppPreferences.shared
        let sponsorWindow = SponsorWindowController()
        let settingsWindow = SettingsWindowController {
            sponsorWindow.show()
        }
        sponsorWindowController = sponsorWindow
        settingsWindowController = settingsWindow

        let floatingPanel = FloatingPanelController(
            model: model,
            preferences: preferences
        )
        floatingPanelController = floatingPanel
        let statusItem = StatusItemController(
            model: model,
            preferences: preferences,
            floatingPanel: floatingPanel,
            openSettings: {
                settingsWindow.show()
            }
        )
        statusItemController = statusItem

        let hotKey = GlobalHotKeyController.shared
        hotKey.onToggle = { [weak floatingPanel] in
            floatingPanel?.toggle()
        }
        hotKeyController = hotKey

        let arguments = ProcessInfo.processInfo.arguments
        Task {
            await UsageNotificationService.shared.refreshAuthorizationStatus()
#if DEBUG
            if arguments.contains("--demo") {
                model.enterDemoMode()
                return
            }
#endif
            await model.start()
        }

#if DEBUG
        if arguments.contains("--show-settings") {
            settingsWindow.show()
        }
        if arguments.contains("--show-context-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                statusItem.showContextMenuForTesting()
            }
        }
        if arguments.contains("--show-details") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                statusItem.showDetails()
            }
        }
#endif
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            statusItemController?.showDetails()
        }
        return true
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

}

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(QuotaBarAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        // Keeps the SwiftUI app lifecycle alive without adding a second status item.
        MenuBarExtra(
            "QuotaBar Scene Host",
            systemImage: "gauge.with.dots.needle.33percent",
            isInserted: .constant(false)
        ) {
            EmptyView()
        }

    }
}
