#if os(macOS)
import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerHost
import Darwin

@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_CODEX_PROCESS_TESTS"] == "1"))
func reviewWebSocketHonorsConfiguredMaximumFrameBytes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("large.txt")
    try Data(repeating: 65, count: 1_100_000).write(to: file)
    let environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": directory.path]) { _, new in new }
    let server = try CodexLoopbackWebSocketServer(executableURL: try CodexCLIResolver().resolve(), port: 45439, environment: environment)
    let client = CodexClient(transportFactory: try await server.transportFactory(), configuration: .init(requestTimeout: .seconds(5), reconnectPolicy: .init(maximumAttempts: 0)))
    do {
        _ = try await client.connect()
        let result = try await client.raw.request(method: "fs/readFile", params: ["path": .string(file.path)])
        #expect(result["dataBase64"]?.stringValue?.count == 1_466_668)
    } catch { Issue.record("Configured 32 MiB limit rejects 1.5 MiB response: \(error)") }
    await client.close(); await server.stop()
}

@Test func reviewOversizedProcessFrameTerminatesOwnedChild() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("fake-ssh.py"), pidFile = directory.appendingPathComponent("pid")
    let source = "#!/usr/bin/python3\nimport os,time\nopen(\"\(pidFile.path)\",'w').write(str(os.getpid()))\nprint('x'*4096,flush=True)\ntime.sleep(15)\n"
    try source.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let client = CodexClient(transportFactory: try CodexHostTransports.sshProxy(sshURL: script, host: .alias("test"), maximumFrameBytes: 1024), configuration: .init(requestTimeout: .seconds(3), reconnectPolicy: .init(maximumAttempts: 0)))
    _ = try? await client.connect()
    await client.close()
    let pid = try Int32(String(contentsOf: pidFile, encoding: .utf8))!
    let alive = Darwin.kill(pid, 0) == 0
    if alive { _ = Darwin.kill(pid, SIGKILL) }
    #expect(!alive)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_CODEX_PROCESS_TESTS"] == "1"))
func reviewSSHForwardWaitsForListenerReadiness() async throws {
    let executable = try CodexCLIResolver().resolve()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
    let executableLiteral = String(decoding: try encoder.encode(executable.path), as: UTF8.self)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("delayed-ssh.py")
    let source = "#!/usr/bin/python3\nimport os,time\ntime.sleep(0.8)\nos.environ['CODEX_HOME']=\"\(directory.path)\"\nos.execv(\(executableLiteral),['codex','app-server','--listen','ws://127.0.0.1:45440'])\n"
    try source.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let client = CodexClient(transportFactory: try CodexHostTransports.sshForward(sshURL: script, host: .alias("test"), localPort: 45440, remotePort: 45440), configuration: .init(requestTimeout: .seconds(3), reconnectPolicy: .init(maximumAttempts: 0)))
    do { _ = try await client.connect() }
    catch { Issue.record("Connection attempted before tunnel listener was ready: \(error)") }
    await client.close()
}

#endif
