import AppKit
import Combine
import CryptoKit
import Foundation
import QuotaBarCore
import UniformTypeIdentifiers

@MainActor
final class UsageHistoryService: ObservableObject {
    static let shared = UsageHistoryService()
    @Published private(set) var history = UsageHistory()
    @Published private(set) var errorMessage: String?
    private let fileURL: URL
    private let defaults: UserDefaults
    private var canWrite = true
    private var accountFingerprint: String?

    init(fileURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar/History/usage.json")
        accountFingerprint = defaults.string(forKey: "historyAccountFingerprint")
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                history = try JSONDecoder().decode(UsageHistory.self, from: Data(contentsOf: self.fileURL))
                history.prune(now: Date())
                persist()
            }
        } catch {
            canWrite = false
            errorMessage = "无法读取历史文件。原文件已保留，请备份该文件或清空后重新记录。"
        }
    }

#if DEBUG
    static func preview() -> UsageHistoryService {
        let service = UsageHistoryService(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("unused.json"))
        let now = Date()
        for minute in stride(from: 360, through: 0, by: -2) {
            let date = now.addingTimeInterval(-Double(minute) * 60)
            let resets = now.addingTimeInterval(minute > 180 ? -180 * 60 : 120 * 60)
            service.history.record(.init(buckets: [.init(id: "codex", name: nil, planType: nil,
                primary: .init(usedPercent: Double(minute > 180 ? 360 - minute : 180 - minute) * 0.45,
                               windowDurationMinutes: 300, resetsAt: resets),
                secondary: .init(usedPercent: 15 + Double(360 - minute) * 0.08,
                                 windowDurationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
                reachedType: nil)], fetchedAt: date))
        }
        service.canWrite = false
        return service
    }
#endif

    func bindAccount(_ identifier: String?) {
        guard canWrite else { return }
        // A local one-way fingerprint prevents mixing histories after an external account change.
        // Email, credentials and the fingerprint are never written into samples or CSV exports.
        let fingerprint = identifier.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        if fingerprint != accountFingerprint || fingerprint == nil {
            clear()
            accountFingerprint = fingerprint
            defaults.set(fingerprint, forKey: "historyAccountFingerprint")
        }
    }

    func record(_ snapshot: RateLimitSnapshot, enabled: Bool, isDemo: Bool) {
        guard enabled, !isDemo, canWrite else { return }
        history.record(snapshot)
        persist()
    }

    func clear() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            history = UsageHistory()
            canWrite = true
            errorMessage = nil
        } catch {
            canWrite = false
            history = UsageHistory()
            errorMessage = "无法清空历史文件，请检查文件访问权限。"
        }
    }

    func pruneExpired() {
        guard canWrite else { return }
        let count = history.samples.count
        history.prune(now: Date())
        if count != history.samples.count { persist() }
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func exportCSV() {
        pruneExpired()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "QuotaBar-history.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try history.csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func persist() {
        guard canWrite else { return }
        do {
            let folder = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(history)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            errorMessage = nil
        } catch {
            errorMessage = "历史记录未能保存：\(error.localizedDescription)"
        }
    }
}
