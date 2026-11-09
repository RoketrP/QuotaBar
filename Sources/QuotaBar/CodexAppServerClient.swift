import AppKit
import Foundation
import QuotaBarCore

struct CodexAccount: Equatable {
    let isAuthenticated: Bool
    let email: String?
    let planType: String?

    static let signedOut = CodexAccount(
        isAuthenticated: false,
        email: nil,
        planType: nil
    )
}

enum CodexClientError: LocalizedError {
    case binaryNotFound
    case serverNotRunning
    case serverStopped
    case timedOut
    case malformedResponse
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "没有找到内置 Codex 服务程序。"
        case .serverNotRunning:
            return "Codex 服务尚未启动。"
        case .serverStopped:
            return "Codex 服务意外停止了。"
        case .timedOut:
            return "读取用量超时，正在尝试重新连接。"
        case .malformedResponse:
            return "Codex 返回了无法识别的数据。"
        case let .remote(message):
            return message
        }
    }
}

protocol CodexClient: AnyObject {
    var onNotification: CodexAppServerClient.NotificationHandler? { get set }
    func start() async throws
    func readAccount() async throws -> CodexAccount
    func readRateLimits() async throws -> RateLimitSnapshot
    func beginChatGPTLogin() async throws -> URL
    func logout() async throws
    func stop()
}

final class CodexAppServerClient: CodexClient {
    typealias NotificationHandler = @Sendable (String, JSONValue) -> Void

    private let binaryURL: URL
    private let codexHomeURL: URL?
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputBuffer = Data()
    private var generation = UUID()
    private var readHandles: [FileHandle] = []
    private let requestTimeout: TimeInterval
    private var nextRequestID = 1
    private var pending: [
        Int: (continuation: CheckedContinuation<JSONValue, Error>, deadline: DispatchWorkItem)
    ] = [:]

    private var notificationHandler: NotificationHandler?
    var onNotification: NotificationHandler? {
        get { withStateLock { notificationHandler } }
        set { withStateLock { notificationHandler = newValue } }
    }

    init(
        binaryURL: URL = CodexBinaryLocator.locate(),
        codexHomeURL: URL? = CodexHome.defaultURL(),
        requestTimeout: TimeInterval = 20
    ) {
        self.requestTimeout = requestTimeout
        self.binaryURL = binaryURL
        self.codexHomeURL = codexHomeURL
    }

    func start() async throws {
        let isAlreadyRunning = withStateLock { process != nil }
        guard !isAlreadyRunning else { return }

        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw CodexClientError.binaryNotFound
        }

        if let codexHomeURL {
            try FileManager.default.createDirectory(
                at: codexHomeURL,
                withIntermediateDirectories: true
            )
        }

        let task = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()

        task.executableURL = binaryURL
        task.arguments = ["app-server"]
        task.standardInput = standardInput
        task.standardOutput = standardOutput
        task.standardError = standardError

        var environment = ProcessInfo.processInfo.environment
        if let codexHomeURL {
            environment["CODEX_HOME"] = codexHomeURL.path
        }
        task.environment = environment

        let connectionID = UUID()
        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeOutput(data, generation: connectionID)
        }

        // Drain diagnostics so the helper can never block on a full stderr pipe.
        // Deliberately do not retain this output because it could include account details.
        standardError.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        task.terminationHandler = { [weak self] _ in
            self?.handleTermination(generation: connectionID)
        }

        withStateLock {
            generation = connectionID
            process = task
            inputHandle = standardInput.fileHandleForWriting
            outputBuffer = Data()
            readHandles = [standardOutput.fileHandleForReading, standardError.fileHandleForReading]
        }

        do {
            try task.run()
        } catch {
            stop()
            throw error
        }

        do {
            let initializeResult = try await request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("quotabar"),
                        "title": .string("QuotaBar"),
                        "version": .string(AppVersion.current)
                    ]),
                    "capabilities": .object([:])
                ])
            )

            guard initializeResult.objectValue != nil else {
                throw CodexClientError.malformedResponse
            }

            try sendNotification(method: "initialized", params: .object([:]))
        } catch {
            stop()
            throw error
        }
    }

    func readAccount() async throws -> CodexAccount {
        let result = try await request(
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        )

        guard let root = result.objectValue else {
            throw CodexClientError.malformedResponse
        }

        guard let account = root["account"]?.objectValue else {
            return .signedOut
        }

        return CodexAccount(
            isAuthenticated: true,
            email: account["email"]?.stringValue,
            planType: account["planType"]?.stringValue
        )
    }

    func readRateLimits() async throws -> RateLimitSnapshot {
        let result = try await request(
            method: "account/rateLimits/read",
            params: .object([:])
        )
        return try RateLimitParser.parse(result: result)
    }

    func beginChatGPTLogin() async throws -> URL {
        let result = try await request(
            method: "account/login/start",
            params: .object([
                "type": .string("chatgpt"),
                "useHostedLoginSuccessPage": .bool(true),
                "appBrand": .string("chatgpt")
            ])
        )

        guard
            let urlString = result["authUrl"]?.stringValue,
            let url = URL(string: urlString)
        else {
            throw CodexClientError.malformedResponse
        }

        return url
    }

    func logout() async throws {
        _ = try await request(
            method: "account/logout",
            params: .object([:])
        )
    }

    func stop() {
        stateLock.lock()
        generation = UUID()
        let task = process
        process = nil
        let handle = inputHandle
        inputHandle = nil
        let handles = readHandles
        readHandles = []
        outputBuffer = Data()
        let requests = Array(pending.values)
        pending.removeAll()
        stateLock.unlock()

        handles.forEach { $0.readabilityHandler = nil }
        try? handle?.close()
        if task?.isRunning == true { task?.terminate() }
        requests.forEach {
            $0.deadline.cancel()
            $0.continuation.resume(throwing: CodexClientError.serverStopped)
        }
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        let requestID = withStateLock {
            let value = nextRequestID
            nextRequestID += 1
            return value
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = DispatchWorkItem { [weak self] in
                    self?.complete(requestID: requestID, result: .failure(CodexClientError.timedOut))
                }
                stateLock.lock()
                if Task.isCancelled {
                    stateLock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[requestID] = (continuation, deadline)
                stateLock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + requestTimeout, execute: deadline)
                do {
                    try write(.object([
                        "method": .string(method), "id": .number(Double(requestID)), "params": params
                    ]))
                } catch {
                    complete(requestID: requestID, result: .failure(error))
                }
            }
        } onCancel: { [weak self] in
            self?.complete(requestID: requestID, result: .failure(CancellationError()))
        }
    }

    private func sendNotification(method: String, params: JSONValue) throws {
        try write(
            .object([
                "method": .string(method),
                "params": params
            ])
        )
    }

    private func write(_ message: JSONValue) throws {
        stateLock.lock()
        let handle = inputHandle
        stateLock.unlock()

        guard let handle else {
            throw CodexClientError.serverNotRunning
        }

        var data = try JSONEncoder().encode(message)
        data.append(0x0A)

        writeLock.lock()
        defer { writeLock.unlock() }
        try handle.write(contentsOf: data)
    }

    private func consumeOutput(_ data: Data, generation connectionID: UUID) {
        var completeLines: [Data] = []

        stateLock.lock()
        guard generation == connectionID else { stateLock.unlock(); return }
        outputBuffer.append(data)
        let newline = Data([0x0A])

        while let range = outputBuffer.range(of: newline) {
            let line = outputBuffer.subdata(in: outputBuffer.startIndex..<range.lowerBound)
            outputBuffer.removeSubrange(outputBuffer.startIndex...range.lowerBound)
            if !line.isEmpty {
                completeLines.append(line)
            }
        }
        stateLock.unlock()

        for line in completeLines {
            handleLine(line)
        }
    }

    private func handleLine(_ data: Data) {
        guard
            let message = try? JSONDecoder().decode(JSONValue.self, from: data),
            let object = message.objectValue
        else {
            return
        }

        if let requestID = object["id"]?.intValue {
            if let errorObject = object["error"]?.objectValue {
                let message = errorObject["message"]?.stringValue ?? "Codex 请求失败。"
                complete(
                    requestID: requestID,
                    result: .failure(CodexClientError.remote(message))
                )
            } else if let result = object["result"] {
                complete(requestID: requestID, result: .success(result))
            } else {
                complete(
                    requestID: requestID,
                    result: .failure(CodexClientError.malformedResponse)
                )
            }
            return
        }

        if
            let method = object["method"]?.stringValue,
            let params = object["params"]
        {
            onNotification?(method, params)
        }
    }

    private func complete(
        requestID: Int,
        result: Result<JSONValue, Error>
    ) {
        stateLock.lock()
        let request = pending.removeValue(forKey: requestID)
        stateLock.unlock()
        request?.deadline.cancel()
        request?.continuation.resume(with: result)
    }

    private func handleTermination(generation connectionID: UUID) {
        stateLock.lock()
        guard generation == connectionID else { stateLock.unlock(); return }
        process = nil
        inputHandle = nil
        let handles = readHandles
        readHandles = []
        let requests = Array(pending.values)
        pending.removeAll()
        stateLock.unlock()
        handles.forEach { $0.readabilityHandler = nil }
        requests.forEach {
            $0.deadline.cancel()
            $0.continuation.resume(throwing: CodexClientError.serverStopped)
        }
        onNotification?("quotabar/disconnected", .object([:]))
    }

    private func withStateLock<T>(_ operation: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try operation()
    }
}

enum CodexBinaryLocator {
    static func locate() -> URL {
        let fileManager = FileManager.default

        let candidates: [URL?] = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Helpers")
                .appendingPathComponent("codex"),
            ProcessInfo.processInfo.environment["CODEX_BINARY_PATH"].map {
                URL(fileURLWithPath: $0)
            },
            URL(
                fileURLWithPath:
                    "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/" +
                    "@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
            ),
            URL(
                fileURLWithPath:
                    "/usr/local/lib/node_modules/@openai/codex/node_modules/" +
                    "@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"
            )
        ]

        return candidates
            .compactMap { $0 }
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
            ?? URL(fileURLWithPath: "/nonexistent/quotabar-codex")
    }
}

enum CodexHome {
    static func defaultURL() -> URL? {
        if ProcessInfo.processInfo.environment["QUOTABAR_USE_EXISTING_CODEX_HOME"] == "1" {
            return nil
        }

        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        return applicationSupport
            .appendingPathComponent("QuotaBar", isDirectory: true)
            .appendingPathComponent("Codex", isDirectory: true)
    }
}

enum AppVersion {
    static var current: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.3.0"
    }
}
