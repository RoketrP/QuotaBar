import Foundation
import Testing
@testable import QuotaBarCore

struct UsageHistoryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func snapshot(_ time: Date, used: Double = 20, bucket: String = "codex") -> RateLimitSnapshot {
        RateLimitSnapshot(buckets: [.init(id: bucket, name: nil, planType: nil,
            primary: .init(usedPercent: used, windowDurationMinutes: 300, resetsAt: time.addingTimeInterval(500)),
            secondary: .init(usedPercent: 90, windowDurationMinutes: 10080, resetsAt: time.addingTimeInterval(5000)),
            reachedType: nil)], fetchedAt: time)
    }

    @Test func samplesAtMostOncePerMinutePerSeries() {
        var history = UsageHistory()
        history.record(snapshot(now))
        history.record(snapshot(now.addingTimeInterval(59)))
        #expect(history.samples.count == 2)
        history.record(snapshot(now.addingTimeInterval(60)))
        #expect(history.samples.count == 4)
    }
    @Test func skipsDemoAndPrunesThirtyDays() {
        var history = UsageHistory()
        history.record(snapshot(now), isDemo: true)
        #expect(history.samples.isEmpty)
        history.record(snapshot(now.addingTimeInterval(-UsageHistory.retention - 1)))
        history.record(snapshot(now))
        #expect(history.samples.count == 2)
        #expect(history.samples.allSatisfy { $0.timestamp == now })
    }
    @Test func roundTripAndCSVContainOnlyQuotaFields() throws {
        var history = UsageHistory()
        history.record(snapshot(now, bucket: "codex,\"other\""))
        let data = try JSONEncoder().encode(history)
        #expect(try JSONDecoder().decode(UsageHistory.self, from: data) == history)
        #expect(history.csv.contains("\"codex,\"\"other\"\"\""))
        #expect(history.csv.split(separator: "\n").count == 3)
        #expect(!history.csv.contains("email"))
        #expect(!history.csv.contains("token"))
    }
    @Test func explicitSelectionNeverFallsBackToAnotherWindow() {
        let snapshot = snapshot(now)
        #expect(HeadlineSelection.primary.window(in: snapshot)?.windowDurationMinutes == 300)
        #expect(HeadlineSelection.fiveHour.window(in: snapshot)?.remainingPercent == 80)
        #expect(HeadlineSelection.weekly.window(in: snapshot)?.remainingPercent == 10)
        #expect(HeadlineSelection.lowest.window(in: snapshot)?.windowDurationMinutes == 10080)
        let missing = RateLimitSnapshot(buckets: [], fetchedAt: now)
        #expect(HeadlineSelection.weekly.window(in: missing) == nil)
        let onlyShort = RateLimitSnapshot(buckets: [.init(id: "codex", name: nil, planType: nil,
            primary: snapshot.headlineWindow, secondary: nil, reachedType: nil)])
        #expect(HeadlineSelection.weekly.window(in: onlyShort) == nil)
    }
    @Test func csvNeutralizesSpreadsheetFormulaPrefixes() {
        var history = UsageHistory()
        history.record(snapshot(now, bucket: "=formula"))
        #expect(history.csv.contains("\"'=formula\""))
    }
    @Test func staleAfterFailureOrThreeMinutes() {
        #expect(!UsageFreshness.isStale(lastUpdated: now, now: now.addingTimeInterval(179), failed: false))
        #expect(UsageFreshness.isStale(lastUpdated: now, now: now.addingTimeInterval(180), failed: false))
        #expect(UsageFreshness.isStale(lastUpdated: now, now: now, failed: true))
        #expect(UsageFreshness.isStale(lastUpdated: nil, now: now, failed: false))
    }
}

struct HistoryPlotTests {
    @Test func doesNotConnectResetsOrOfflineGapsAndPreservesExtrema() {
        let now = Date()
        var history = UsageHistory()
        for minute in 0..<4000 {
            let timestamp = now.addingTimeInterval(Double(minute * 60 + (minute >= 2000 ? 600 : 0)))
            history.record(.init(buckets: [.init(id: "codex", name: nil, planType: nil,
                primary: .init(usedPercent: minute == 1234 ? 99 : 30,
                               windowDurationMinutes: 300,
                               resetsAt: now.addingTimeInterval(minute < 1000 ? 999_999 : 1_999_999)),
                secondary: nil, reachedType: nil)], fetchedAt: timestamp))
        }
        let points = UsageHistoryPlotPoint.make(samples: history.samples)
        #expect(points.count < history.samples.count)
        #expect(Set(points.map(\.segment)).count == 3)
        #expect(points.contains { $0.sample.remainingPercent == 1 })
        #expect(points.first?.sample == history.samples.first)
        #expect(points.last?.sample == history.samples.last)
    }
    @Test func retryBackoffIsBoundedAndRateLimitsWaitLonger() {
        #expect((1...6).map { ConnectionRetryPolicy.delay(failures: $0) } == [5, 10, 20, 40, 60, 60])
        #expect(ConnectionRetryPolicy.delay(failures: 1, rateLimited: true) == 300)
    }
}
