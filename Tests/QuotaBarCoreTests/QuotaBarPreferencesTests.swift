import Testing
@testable import QuotaBarCore

struct QuotaBarPreferencesTests {
    @Test
    func defaultsMatchProductDecisions() {
        #expect(QuotaBarPreferenceDefaults.showFloatingPanel == false)
        #expect(QuotaBarPreferenceDefaults.floatingAcrossSpaces == false)
        #expect(QuotaBarPreferenceDefaults.statusItemStyle == .iconAndPercentage)
        #expect(QuotaBarPreferenceDefaults.globalHotKeyEnabled == true)
        #expect(QuotaBarPreferenceDefaults.notificationsEnabled == false)
        #expect(QuotaBarPreferenceDefaults.lowQuotaThreshold == 20)
        #expect(QuotaBarPreferenceDefaults.notifyOnReset == true)
        #expect(QuotaBarPreferenceDefaults.officialUpdatesEnabled == false)
    }

    @Test
    func statusItemStylesProduceStableOutput() {
        #expect(
            StatusItemDisplayFormatter.make(
                remainingPercent: 62.6,
                style: .iconAndPercentage
            ) == StatusItemDisplay(title: "63%", showsIcon: true)
        )
        #expect(
            StatusItemDisplayFormatter.make(
                remainingPercent: 62.6,
                style: .percentageOnly
            ) == StatusItemDisplay(title: "63%", showsIcon: false)
        )
        #expect(
            StatusItemDisplayFormatter.make(
                remainingPercent: nil,
                style: .percentageOnly
            ) == StatusItemDisplay(title: "--%", showsIcon: false)
        )
        #expect(StatusItemDisplayFormatter.make(remainingPercent: nil, style: .iconAndPercentage)
            == StatusItemDisplay(title: "--%", showsIcon: true))
        #expect(
            StatusItemDisplayFormatter.make(
                remainingPercent: 62.6,
                style: .iconOnly
            ) == StatusItemDisplay(title: "", showsIcon: true)
        )
    }
}
