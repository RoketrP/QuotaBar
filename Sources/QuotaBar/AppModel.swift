import AppKit
import Foundation
import QuotaBarCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    enum Phase: Equatable {
        case connecting, needsLogin, loggingIn, loadingUsage, ready, failed
    }
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var account: CodexAccount = .signedOut
    @Published private(set) var snapshot: RateLimitSnapshot?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isDemoMode = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var now = Date()
    @Published var errorMessage: String?

    private var client: CodexClient?
    private let makeClient: () -> CodexClient
    private let preferences: AppPreferences
    private let history: UsageHistoryService
    private let processUsage: @MainActor (RateLimitSnapshot) -> Void
    private let resetAlerts: @MainActor () -> Void
    private var pollTask: Task<Void, Never>?
    private var operationID = UUID()
    private var connectionID = UUID()
    private var retryAt = Date.distantPast
    private var accountRevision = 0
    private var refreshQueued = false
    private var failures = 0
    private var lastPruned = Date.distantPast
    private var hasStarted = false

    init(makeClient: @escaping () -> CodexClient = { CodexAppServerClient() },
         history: UsageHistoryService? = nil, preferences: AppPreferences? = nil,
         processUsage: @escaping @MainActor (RateLimitSnapshot) -> Void = {
             UsageNotificationService.shared.process(snapshot: $0, isDemoMode: false)
         }, resetAlerts: @escaping @MainActor () -> Void = { UsageNotificationService.shared.resetBaseline() }) {
        self.makeClient = makeClient
        self.history = history ?? .shared
        self.preferences = preferences ?? .shared
        self.processUsage = processUsage
        self.resetAlerts = resetAlerts
    }

    var selectedWindow: RateLimitWindow? {
        snapshot.flatMap { preferences.headlineSelection.window(in: $0) }
    }
    var headlineRemaining: Double? { selectedWindow?.remainingPercent }
    var isStale: Bool {
        !isDemoMode && snapshot != nil && UsageFreshness.isStale(
            lastUpdated: lastUpdated, now: now, failed: errorMessage != nil)
    }
    var planLabel: String { (snapshot?.planType ?? account.planType ?? "ChatGPT").uppercased() }

    deinit { pollTask?.cancel(); client?.stop() }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        startPolling()
        await refresh()
    }

    func activate() async { await refresh() }

    private func connectedClient() async throws -> CodexClient {
        if let client { return client }
        let candidate = makeClient()
        let id = UUID()
        connectionID = id
        client = candidate
        candidate.onNotification = { [weak self] method, params in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == id, !self.isDemoMode else { return }
                self.handleNotification(method: method, params: params)
            }
        }
        try await candidate.start()
        return candidate
    }

    func refresh() async {
        guard !isDemoMode, !isRefreshing, phase != .loggingIn else { return }
        let id = UUID()
        operationID = id
        isRefreshing = true
        defer { finishOperation(id) }
        if snapshot == nil { phase = client == nil ? .connecting : .loadingUsage }
        let revision = accountRevision
        do {
            let active = try await connectedClient()
            guard operationID == id else { return }
            let newAccount = try await active.readAccount()
            guard operationID == id, revision == accountRevision else { return }
            if account.email != newAccount.email { snapshot = nil; lastUpdated = nil; resetAlerts() }
            account = newAccount
            guard account.isAuthenticated else {
                snapshot = nil
                lastUpdated = nil
                history.bindAccount(nil)
                errorMessage = nil
                phase = .needsLogin
                retryAt = Date().addingTimeInterval(60)
                return
            }
            history.bindAccount(account.email)
            let newSnapshot = try await active.readRateLimits()
            guard operationID == id, revision == accountRevision else { return }
            snapshot = newSnapshot
            lastUpdated = newSnapshot.fetchedAt
            now = Date()
            errorMessage = nil
            phase = .ready
            failures = 0
            retryAt = now.addingTimeInterval(60)
            history.record(newSnapshot, enabled: preferences.historyEnabled, isDemo: false)
            processUsage(newSnapshot)
        } catch {
            guard operationID == id, revision == accountRevision else { return }
            present(error)
        }
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        isRefreshing = false
        if refreshQueued, phase != .loggingIn {
            refreshQueued = false
            Task { [weak self] in await self?.refresh() }
        }
    }

    func shutdown() {
        operationID = UUID()
        pollTask?.cancel()
        pollTask = nil
        disconnect()
        isRefreshing = false
    }

    func beginLogin() async {
        guard !isRefreshing, phase != .loggingIn else { return }
        isDemoMode = false
        snapshot = nil
        lastUpdated = nil
        errorMessage = nil
        let id = UUID()
        operationID = id
        isRefreshing = true
        phase = .loggingIn
        defer { finishOperation(id) }
        do {
            let active = try await connectedClient()
            let url = try await active.beginChatGPTLogin()
            guard operationID == id else { return }
            NSWorkspace.shared.open(url)
        } catch {
            guard operationID == id else { return }
            present(error)
        }
    }

    func cancelLogin() {
        operationID = UUID()
        isRefreshing = false
        disconnect()
        phase = .needsLogin
    }

    func logout() async {
        guard !isRefreshing else { return }
        let id = UUID()
        operationID = id
        isRefreshing = true
        defer { finishOperation(id) }
        do {
            let active = try await connectedClient()
            try await active.logout()
            guard operationID == id else { return }
            disconnect()
            isDemoMode = false
            snapshot = nil
            lastUpdated = nil
            account = .signedOut
            errorMessage = nil
            phase = .needsLogin
            history.bindAccount(nil)
            resetAlerts()
        } catch { if operationID == id { present(error) } }
    }

    func openUsageDashboard() {
        if let url = URL(string: "https://chatgpt.com/codex/settings/usage") { NSWorkspace.shared.open(url) }
    }

    func enterDemoMode() {
        operationID = UUID()
        disconnect()
        isRefreshing = false
        let now = Date()
        let fiveHour = RateLimitWindow(
            usedPercent: 37,
            windowDurationMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 60 * 60 + 18 * 60)
        )
        let weekly = RateLimitWindow(
            usedPercent: 61,
            windowDurationMinutes: 10_080,
            resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60 + 7 * 60 * 60)
        )
        let bucket = RateLimitBucket(
            id: "codex",
            name: nil,
            planType: "plus",
            primary: fiveHour,
            secondary: weekly,
            reachedType: nil
        )

        isDemoMode = true
        resetAlerts()
        account = .signedOut
        snapshot = RateLimitSnapshot(buckets: [bucket], fetchedAt: now)
        lastUpdated = now
        errorMessage = nil
        phase = .ready
    }

    func connectRealAccountFromDemo() async {
        isDemoMode = false
        snapshot = nil
        await beginLogin()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let waitingForUser = self?.isDemoMode == true || self?.phase == .loggingIn || self?.isRefreshing == true
                let delay = waitingForUser ? 5 : min(5, max(0.1, self?.retryAt.timeIntervalSinceNow ?? 5))
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.now = Date()
                if self.now.timeIntervalSince(self.lastPruned) >= 60 {
                    self.history.pruneExpired()
                    self.lastPruned = self.now
                }
                if self.now >= self.retryAt { await self.refresh() }
            }
        }
    }

    func didWake() async {
        now = Date()
        await refresh()
    }

    private func handleNotification(method: String, params: JSONValue) {
        switch method {
        case "quotabar/disconnected":
            if !isRefreshing { present(CodexClientError.serverStopped) }
        case "account/login/completed":
            if params["success"]?.boolValue == true {
                phase = .needsLogin
                refreshQueued = isRefreshing
                // The login-start response can still be completing; allow it to finish first.
                retryAt = .distantPast
                Task { [weak self] in await self?.refresh() }
            } else {
                errorMessage = params["error"]?.stringValue ?? "ChatGPT 登录未完成。"
                phase = .needsLogin
            }
        case "account/updated":
            accountRevision += 1
            snapshot = nil
            lastUpdated = nil
            resetAlerts()
            if phase != .loggingIn { phase = .loadingUsage }
            refreshQueued = isRefreshing
            retryAt = .distantPast
            Task { [weak self] in await self?.refresh() }
        case "account/rateLimits/updated":
            guard !isRefreshing else { return }
            retryAt = .distantPast
            Task { [weak self] in await self?.refresh() }
        default: break
        }
    }

    private func disconnect() {
        connectionID = UUID()
        client?.onNotification = nil
        client?.stop()
        client = nil
    }

    private func present(_ error: Error) {
        disconnect()
        errorMessage = error.localizedDescription
        phase = snapshot == nil ? .failed : .ready
        failures += 1
        let rateLimited: Bool
        if case let CodexClientError.remote(message) = error {
            rateLimited = message.contains("429")
        } else { rateLimited = false }
        retryAt = Date().addingTimeInterval(ConnectionRetryPolicy.delay(failures: failures, rateLimited: rateLimited))
    }
}
