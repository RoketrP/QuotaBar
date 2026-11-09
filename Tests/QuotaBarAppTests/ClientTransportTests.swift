import Foundation
import Testing
@testable import QuotaBar

@Suite(.serialized)
struct ClientTransportTests {
    func helper(_ mode: String) throws -> (URL, CodexAppServerClient) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("helper")
        let content = """
        #!/usr/bin/python3
        import sys, json, time
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            method = request['method']
            if '\(mode)' == 'init-timeout' or (method != 'initialize' and '\(mode)' == 'timeout'):
                continue
            if method != 'initialize' and '\(mode)' == 'exit': sys.exit(1)
            if method == 'initialize': result = {}
            elif method == 'account/read': result = {'account': {'email': 'fake@example.invalid', 'planType': 'plus'}}
            else: result = {}
            print(json.dumps({'id': request['id'], 'result': result}), flush=True)
        """
        try content.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (folder, CodexAppServerClient(binaryURL: script, codexHomeURL: nil, requestTimeout: 3))
    }
    @Test func initializeAndRead() async throws {
        let (folder, client) = try helper("ok")
        defer { client.stop(); try? FileManager.default.removeItem(at: folder) }
        try await client.start()
        #expect(try await client.readAccount().isAuthenticated)
    }
    @Test func timeoutReleasesRequestAndClientCanRestart() async throws {
        let (folder, client) = try helper("timeout")
        defer { client.stop(); try? FileManager.default.removeItem(at: folder) }
        try await client.start()
        do { _ = try await client.readAccount(); Issue.record("Expected timeout") }
        catch { #expect(error as? CodexClientError != nil) }
        client.stop()
        try await client.start()
    }
    @Test func initializationTimeoutCleansUpAndAllowsRestart() async throws {
        let (folder, client) = try helper("init-timeout")
        defer { client.stop(); try? FileManager.default.removeItem(at: folder) }
        for _ in 0..<2 {
            do { try await client.start(); Issue.record("Expected initialization timeout") }
            catch { #expect(error is CodexClientError) }
        }
    }
    @Test func terminationFailsPendingRequest() async throws {
        let (folder, client) = try helper("exit")
        defer { client.stop(); try? FileManager.default.removeItem(at: folder) }
        try await client.start()
        do { _ = try await client.readAccount(); Issue.record("Expected termination error") }
        catch { #expect(error is CodexClientError) }
    }
    @Test func cancellationCompletesWithoutWaitingForTimeout() async throws {
        let (folder, client) = try helper("timeout")
        defer { client.stop(); try? FileManager.default.removeItem(at: folder) }
        try await client.start()
        let task = Task { try await client.readAccount() }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }
}
