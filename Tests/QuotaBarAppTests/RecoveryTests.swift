import Foundation
import Testing
import XCTest
import Combine
@testable import QuotaBar
import QuotaBarCore

final class StubClient: CodexClient {
    var onNotification: CodexAppServerClient.NotificationHandler?
    var error: Error?
    var account = CodexAccount(isAuthenticated: true, email: "test@example.invalid", planType: "plus")
    var reads = 0
    var stopped = false
    var beforeRead: (@MainActor (Int) async -> Void)?
    var value: RateLimitSnapshot {
        .init(buckets: [.init(id: "codex", name: nil, planType: nil,
            primary: .init(usedPercent: 20, windowDurationMinutes: 300, resetsAt: Date().addingTimeInterval(500)),
            secondary: nil, reachedType: nil)])
    }
    func start() async throws { if let error { throw error } }
    func stop() { stopped = true }
    func readAccount() async throws -> CodexAccount { account }
    func readRateLimits() async throws -> RateLimitSnapshot {
        reads += 1
        if let beforeRead { await beforeRead(reads) }
        if let error { throw error }
        return value
    }
    func beginChatGPTLogin() async throws -> URL { URL(string: "https://example.invalid")! }
    func logout() async throws {}
}

@MainActor
private final class ReadGate {
    let started = XCTestExpectation(description: "Mock quota request started")
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite(.serialized) @MainActor
struct RecoveryTests {
    func environment() -> (URL, UserDefaults, UsageHistoryService, AppPreferences) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "QuotaBarTests-\(UUID())")!
        return (folder, defaults, UsageHistoryService(fileURL: folder.appendingPathComponent("usage.json"), defaults: defaults),
                AppPreferences(defaults: defaults))
    }
    @Test func reconnectsAfterInitialFailure() async {
        let (folder, _, history, preferences) = environment()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bad = StubClient(); bad.error = CodexClientError.serverStopped
        let good = StubClient()
        var attempts = 0
        let model = AppModel(makeClient: { attempts += 1; return attempts == 1 ? bad : good },
                             history: history, preferences: preferences, processUsage: { _ in }, resetAlerts: {})
        await model.refresh()
        #expect(model.phase == .failed)
        #expect(bad.stopped)
        await model.refresh()
        #expect(attempts == 2)
        #expect(model.phase == .ready)
        #expect(model.errorMessage == nil)
    }
    @Test func failurePreservesSnapshotButMarksItStaleThenRecovers() async {
        let (folder, _, history, preferences) = environment()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = StubClient()
        let model = AppModel(makeClient: { client }, history: history, preferences: preferences,
                             processUsage: { _ in }, resetAlerts: {})
        await model.refresh()
        let before = model.snapshot
        client.error = CodexClientError.timedOut
        await model.refresh()
        #expect(model.snapshot == before)
        #expect(model.isStale)
        client.error = nil
        await model.refresh()
        #expect(!model.isStale)
    }
    @Test func coalescesRefreshAndDiscardsLateRealDataAfterEnteringDemo() async {
        let (folder, _, history, preferences) = environment()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = StubClient()
        let gate = ReadGate()
        client.beforeRead = { _ in await gate.pause() }
        let model = AppModel(makeClient: { client }, history: history, preferences: preferences,
                             processUsage: { _ in }, resetAlerts: {})
        let task = Task { await model.refresh() }
        let started = await XCTWaiter.fulfillment(of: [gate.started], timeout: 5)
        #expect(started == .completed)
        await model.refresh()
        #expect(client.reads == 1)
        model.enterDemoMode()
        gate.release()
        await task.value
        #expect(model.isDemoMode)
        #expect(model.headlineRemaining == 63)
        #expect(history.history.samples.isEmpty)
    }
    @Test func historyOptInAndLogoutClear() async {
        let (folder, _, history, preferences) = environment()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = StubClient()
        let model = AppModel(makeClient: { client }, history: history, preferences: preferences,
                             processUsage: { _ in }, resetAlerts: {})
        await model.refresh()
        #expect(history.history.samples.isEmpty)
        preferences.historyEnabled = true
        await model.refresh()
        #expect(history.history.samples.count == 1)
        await model.logout()
        #expect(model.snapshot == nil)
        #expect(history.history.samples.isEmpty)
    }
    @Test func wakeRefreshesAndPreferencesSurviveRestart() async {
        let (folder, defaults, history, preferences) = environment()
        defer { try? FileManager.default.removeItem(at: folder) }
        preferences.headlineSelection = .weekly
        preferences.historyEnabled = true
        let reopened = AppPreferences(defaults: defaults)
        #expect(reopened.headlineSelection == .weekly)
        #expect(reopened.historyEnabled)
        let client = StubClient()
        let model = AppModel(makeClient: { client }, history: history, preferences: reopened,
                             processUsage: { _ in }, resetAlerts: {})
        await model.refresh()
        #expect(model.headlineRemaining == nil)
        await model.didWake()
        #expect(client.reads == 2)
        #expect(model.phase == .ready)
    }
    @Test func persistedHistorySurvivesSameAccountAndClearsOnSwitch() throws {
        let (folder, defaults, history, _) = environment()
        defer { try? FileManager.default.removeItem(at: folder) }
        history.bindAccount("first@example.invalid")
        history.record(StubClient().value, enabled: true, isDemo: false)
        let reopened = UsageHistoryService(fileURL: folder.appendingPathComponent("usage.json"), defaults: defaults)
        reopened.bindAccount("first@example.invalid")
        #expect(reopened.history.samples.count == 1)
        reopened.bindAccount("second@example.invalid")
        #expect(reopened.history.samples.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("usage.json").path))
    }
    @Test func backgroundPollingRecoversWithoutManualRefresh() async throws {
        let (folder, _, history, preferences) = environment()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bad = StubClient(); bad.error = CodexClientError.serverStopped
        let good = StubClient()
        var attempts = 0
        let recovered = XCTestExpectation(description: "Background retry completed")
        let model = AppModel(makeClient: { attempts += 1; return attempts == 1 ? bad : good },
                             history: history, preferences: preferences,
                             processUsage: { _ in recovered.fulfill() }, resetAlerts: {})
        defer { model.shutdown() }
        await model.start()
        #expect(model.phase == .failed)
        let result = await XCTWaiter.fulfillment(of: [recovered], timeout: 15)
        #expect(result == .completed)
        #expect(model.phase == .ready)
        #expect(attempts == 2)
    }
    @Test func accountChangeDuringReadDiscardsOldResult() async throws {
        let (folder, _, history, preferences) = environment()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = StubClient()
        let first = ReadGate()
        let second = ReadGate()
        client.beforeRead = { count in
            if count == 1 { await first.pause() } else { await second.pause() }
        }
        preferences.historyEnabled = true
        let completed = XCTestExpectation(description: "New account snapshot accepted")
        let model = AppModel(makeClient: { client }, history: history, preferences: preferences,
                             processUsage: { _ in completed.fulfill() }, resetAlerts: {})
        let task = Task { await model.refresh() }
        let initialRead = await XCTWaiter.fulfillment(of: [first.started], timeout: 5)
        #expect(initialRead == .completed)
        let changed = XCTestExpectation(description: "Account change notification handled")
        let subscription = model.$phase.dropFirst().filter { $0 == .loadingUsage }.prefix(1)
            .sink { _ in changed.fulfill() }
        defer { subscription.cancel() }
        client.account = .init(isAuthenticated: true, email: "new@example.invalid", planType: "plus")
        client.onNotification?("account/updated", .object([:]))
        let notification = await XCTWaiter.fulfillment(of: [changed], timeout: 5)
        #expect(notification == .completed)
        first.release()
        await task.value
        let nextRead = await XCTWaiter.fulfillment(of: [second.started], timeout: 5)
        #expect(nextRead == .completed)
        #expect(model.snapshot == nil)
        #expect(history.history.samples.isEmpty)
        second.release()
        let accepted = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        #expect(accepted == .completed)
        #expect(model.account.email == "new@example.invalid")
        #expect(model.phase == .ready)
        #expect(history.history.samples.count == 1)
    }
    @Test func corruptFileIsPreservedUntilExplicitClear() throws {
        let (folder, defaults, _, _) = environment()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("usage.json")
        try Data("broken".utf8).write(to: url)
        let service = UsageHistoryService(fileURL: url, defaults: defaults)
        service.bindAccount("test@example.invalid")
        service.record(StubClient().value, enabled: true, isDemo: false)
        #expect(service.errorMessage != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
        service.clear()
        service.record(StubClient().value, enabled: true, isDemo: false)
        #expect(service.errorMessage == nil)
        #expect(service.history.samples.count == 1)
    }
}
