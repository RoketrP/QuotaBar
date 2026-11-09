import Foundation

public struct UsageHistorySample: Codable, Equatable, Identifiable, Sendable {
    public let timestamp: Date
    public let bucketID: String
    public let durationMinutes: Int
    public let remainingPercent: Double
    public let resetsAt: Date

    public var id: String { "\(timestamp.timeIntervalSince1970)-\(bucketID)-\(durationMinutes)" }
    public var windowLabel: String {
        RateLimitWindow(usedPercent: 100 - remainingPercent,
                        windowDurationMinutes: durationMinutes, resetsAt: resetsAt).windowLabel
    }
}

public struct UsageHistory: Codable, Equatable, Sendable {
    public private(set) var samples: [UsageHistorySample] = []
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    public init() {}

    public mutating func prune(now: Date) {
        samples.removeAll { $0.timestamp < now.addingTimeInterval(-Self.retention) || $0.timestamp > now }
    }

    public mutating func record(_ snapshot: RateLimitSnapshot, isDemo: Bool = false) {
        guard !isDemo else { return }
        prune(now: snapshot.fetchedAt)
        for bucket in snapshot.buckets {
            for window in bucket.windows where window.windowDurationMinutes > 0 && window.usedPercent.isFinite {
                // Keep at most one sample per minute and series, including manual refreshes.
                if let last = samples.last(where: {
                    $0.bucketID == bucket.id && $0.durationMinutes == window.windowDurationMinutes
                }), snapshot.fetchedAt.timeIntervalSince(last.timestamp) < 60 { continue }
                samples.append(UsageHistorySample(
                    timestamp: snapshot.fetchedAt, bucketID: bucket.id,
                    durationMinutes: window.windowDurationMinutes,
                    remainingPercent: window.remainingPercent, resetsAt: window.resetsAt
                ))
            }
        }
    }

    public var csv: String {
        func quote(_ text: String) -> String {
            let safe = text.first.map { "=+-@\t\r".contains($0) } == true ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        let rows = samples.map {
            [formatter.string(from: $0.timestamp), quote($0.bucketID), String($0.durationMinutes),
             String($0.remainingPercent), formatter.string(from: $0.resetsAt)].joined(separator: ",")
        }
        return (["timestamp_utc,bucket_id,window_minutes,remaining_percent,resets_at_utc"] + rows).joined(separator: "\n") + "\n"
    }
}

public struct UsageHistoryPlotPoint: Identifiable, Sendable {
    public let sample: UsageHistorySample
    public let segment: Int
    public var id: String { sample.id }

    public static func make(samples: [UsageHistorySample]) -> [Self] {
        var previous: UsageHistorySample?
        var segment = 0
        let raw = samples.map { sample in
            if let previous,
               sample.resetsAt != previous.resetsAt || sample.timestamp.timeIntervalSince(previous.timestamp) > 300 {
                segment += 1
            }
            previous = sample
            return Self(sample: sample, segment: segment)
        }
        // Bound chart work while preserving segment boundaries and local extrema.
        // The stored history and exported CSV always retain every original sample.
        let strideSize = max(1, raw.count / 800)
        guard strideSize > 1 else { return raw }
        var result: [Self] = []
        for start in stride(from: 0, to: raw.count, by: strideSize) {
            let chunk = raw[start..<min(start + strideSize, raw.count)]
            for group in Dictionary(grouping: chunk, by: \.segment).values {
                let candidates = [group.first!, group.last!,
                    group.min { $0.sample.remainingPercent < $1.sample.remainingPercent }!,
                    group.max { $0.sample.remainingPercent < $1.sample.remainingPercent }!]
                var seen = Set<String>()
                result.append(contentsOf: candidates.filter { seen.insert($0.id).inserted }
                    .sorted { $0.sample.timestamp < $1.sample.timestamp })
            }
        }
        return result.sorted { $0.sample.timestamp < $1.sample.timestamp }
    }
}

public enum ConnectionRetryPolicy {
    public static func delay(failures: Int, rateLimited: Bool = false) -> TimeInterval {
        if rateLimited { return 300 }
        return min(60, 5 * pow(2, Double(min(max(0, failures - 1), 4))))
    }
}
