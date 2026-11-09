import Combine
import Foundation
import QuotaBarCore

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var showFloatingPanel: Bool {
        didSet { defaults.set(showFloatingPanel, forKey: Keys.showFloatingPanel) }
    }

    @Published var floatingAcrossSpaces: Bool {
        didSet { defaults.set(floatingAcrossSpaces, forKey: Keys.floatingAcrossSpaces) }
    }

    @Published var statusItemStyle: StatusItemDisplayStyle {
        didSet { defaults.set(statusItemStyle.rawValue, forKey: Keys.statusItemStyle) }
    }

    @Published var globalHotKeyEnabled: Bool {
        didSet { defaults.set(globalHotKeyEnabled, forKey: Keys.globalHotKeyEnabled) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    @Published var lowQuotaThreshold: Int {
        didSet { defaults.set(lowQuotaThreshold, forKey: Keys.lowQuotaThreshold) }
    }

    @Published var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: Keys.notifyOnReset) }
    }

    @Published var officialUpdatesEnabled: Bool {
        didSet { defaults.set(officialUpdatesEnabled, forKey: Keys.officialUpdatesEnabled) }
    }

    @Published var headlineSelection: HeadlineSelection {
        didSet { defaults.set(headlineSelection.rawValue, forKey: "headlineSelection") }
    }

    @Published var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: "historyEnabled") }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let showFloatingPanel = "showFloatingPanel"
        static let floatingAcrossSpaces = "floatingAcrossSpaces"
        static let statusItemStyle = "statusItemStyle"
        static let globalHotKeyEnabled = "globalHotKeyEnabled"
        static let notificationsEnabled = "notificationsEnabled"
        static let lowQuotaThreshold = "lowQuotaThreshold"
        static let notifyOnReset = "notifyOnReset"
        static let officialUpdatesEnabled = "officialUpdatesEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        headlineSelection = HeadlineSelection(rawValue: defaults.string(forKey: "headlineSelection") ?? "") ?? .primary
        historyEnabled = defaults.bool(forKey: "historyEnabled")
        defaults.register(defaults: [
            Keys.showFloatingPanel: QuotaBarPreferenceDefaults.showFloatingPanel,
            Keys.floatingAcrossSpaces: QuotaBarPreferenceDefaults.floatingAcrossSpaces,
            Keys.statusItemStyle: QuotaBarPreferenceDefaults.statusItemStyle.rawValue,
            Keys.globalHotKeyEnabled: QuotaBarPreferenceDefaults.globalHotKeyEnabled,
            Keys.notificationsEnabled: QuotaBarPreferenceDefaults.notificationsEnabled,
            Keys.lowQuotaThreshold: QuotaBarPreferenceDefaults.lowQuotaThreshold,
            Keys.notifyOnReset: QuotaBarPreferenceDefaults.notifyOnReset,
            Keys.officialUpdatesEnabled: QuotaBarPreferenceDefaults.officialUpdatesEnabled
        ])

        showFloatingPanel = defaults.bool(forKey: Keys.showFloatingPanel)
        floatingAcrossSpaces = defaults.bool(forKey: Keys.floatingAcrossSpaces)
        statusItemStyle = StatusItemDisplayStyle(
            rawValue: defaults.string(forKey: Keys.statusItemStyle) ?? ""
        ) ?? QuotaBarPreferenceDefaults.statusItemStyle
        globalHotKeyEnabled = defaults.bool(forKey: Keys.globalHotKeyEnabled)
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        lowQuotaThreshold = defaults.integer(forKey: Keys.lowQuotaThreshold)
        notifyOnReset = defaults.bool(forKey: Keys.notifyOnReset)
        officialUpdatesEnabled = defaults.bool(forKey: Keys.officialUpdatesEnabled)
    }
}
