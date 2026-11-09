import Foundation

public enum HeadlineSelection: String, CaseIterable, Sendable {
    case primary, fiveHour, weekly, lowest

    public var label: String {
        switch self {
        case .primary: return "主额度（默认）"
        case .fiveHour: return "5 小时额度"
        case .weekly: return "周额度"
        case .lowest: return "剩余最低的额度"
        }
    }

    public func window(in snapshot: RateLimitSnapshot) -> RateLimitWindow? {
        let windows = snapshot.preferredBucket?.windows ?? []
        switch self {
        case .primary: return snapshot.headlineWindow
        case .fiveHour: return windows.first { $0.windowDurationMinutes == 300 }
        case .weekly: return windows.first { $0.windowDurationMinutes == 10_080 }
        case .lowest: return windows.min { $0.remainingPercent < $1.remainingPercent }
        }
    }
}

public enum UsageFreshness {
    public static func isStale(lastUpdated: Date?, now: Date, failed: Bool) -> Bool {
        guard let lastUpdated else { return true }
        return failed || now.timeIntervalSince(lastUpdated) >= 180
    }
}

public enum StatusItemDisplayStyle: String, CaseIterable, Hashable, Sendable {
    case iconAndPercentage
    case percentageOnly
    case iconOnly
}

public struct StatusItemDisplay: Equatable, Sendable {
    public let title: String
    public let showsIcon: Bool

    public init(title: String, showsIcon: Bool) {
        self.title = title
        self.showsIcon = showsIcon
    }
}

public enum StatusItemDisplayFormatter {
    public static func make(
        remainingPercent: Double?,
        style: StatusItemDisplayStyle
    ) -> StatusItemDisplay {
        let percentage = remainingPercent.map {
            "\(Int(min(100, max(0, $0)).rounded()))%"
        } ?? "--%"

        switch style {
        case .iconAndPercentage:
            return StatusItemDisplay(title: percentage, showsIcon: true)
        case .percentageOnly:
            return StatusItemDisplay(
                title: percentage.isEmpty ? "--%" : percentage,
                showsIcon: false
            )
        case .iconOnly:
            return StatusItemDisplay(title: "", showsIcon: true)
        }
    }
}

public enum QuotaBarPreferenceDefaults {
    public static let showFloatingPanel = false
    public static let floatingAcrossSpaces = false
    public static let statusItemStyle = StatusItemDisplayStyle.iconAndPercentage
    public static let globalHotKeyEnabled = true
    public static let notificationsEnabled = false
    public static let lowQuotaThreshold = 20
    public static let notifyOnReset = true
    public static let officialUpdatesEnabled = false
}
