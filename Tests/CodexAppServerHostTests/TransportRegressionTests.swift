#if os(macOS)
import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerHost
import Darwin

@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_CODEX_PROCESS_TESTS"] == "1"))
func directoryListingIdentifiesRealServerSymlinks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = directory.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let file = workspace.appendingPathComponent("plain.txt")
    try Data("content".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link.txt"), withDestinationURL: file)
    let environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": directory.path]) { _, new in new }
    let factory = CodexHostTransports.isolated(executableURL: try CodexCLIResolver().resolve(), environment: environment)
    let client = CodexClient(transportFactory: factory, configuration: .init(requestTimeout: .seconds(5), reconnectPolicy: .init(maximumAttempts: 0)))
    do {
        _ = try await client.connect()
        let listing = try await client.listDirectory(path: workspace.path, roots: try .init([workspace]), detail: .detailed)
        #expect(listing.entries.count == 2)
        #expect(listing.entries.first { $0.name == "link.txt" }?.symlinkStatus == .symlink)
        #expect(listing.entries.first { $0.name == "plain.txt" }?.symlinkStatus == .notSymlink)
        #expect(listing.entries.allSatisfy { $0.raw["isSymlink"] == nil })
    } catch {
        await client.close()
        throw error
    }
    await client.close()
}

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

@Test func processTransportPreservesHighVolumeStdoutFrameOrder() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("ordered-output.py")
    let source = """
    #!/usr/bin/python3
    import json
    for sequence in range(10000):
        print(json.dumps({"sequence": sequence}), flush=False)
    """
    try source.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let transport = try await CodexHostTransports.sshProxy(sshURL: script, host: .alias("ignored")).makeTransport()
    try await transport.start()
    var received: [Int] = []
    for try await frame in transport.incomingFrames {
        received.append(try JSONValue.decode(frame)["sequence"]!.intValue!)
    }
    #expect(received == Array(0..<10000))
    await transport.close()
}

@Test func processTransportCloseWakesReadersWhenADescendantKeepsPipesOpen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("inherited-pipes.py")
    let childPIDFile = directory.appendingPathComponent("child-pid")
    let source = """
    #!/usr/bin/python3
    import os, signal, time
    child = os.fork()
    if child == 0:
        open(\"\(childPIDFile.path)\", \"w\").write(str(os.getpid()))
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True: time.sleep(1)
    while True: time.sleep(1)
    """
    try source.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let transport = try await CodexHostTransports.sshProxy(sshURL: script, host: .alias("ignored")).makeTransport()
    try await transport.start()
    for _ in 0..<500 where !FileManager.default.fileExists(atPath: childPIDFile.path) {
        try await Task.sleep(for: .milliseconds(2))
    }
    let childPID = try Int32(String(contentsOf: childPIDFile, encoding: .utf8))!
    defer { _ = Darwin.kill(childPID, SIGKILL) }
    let clock = ContinuousClock()
    let started = clock.now
    await transport.close()
    #expect(clock.now - started < .seconds(2))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_CODEX_PROCESS_TESTS"] == "1"))
func reviewSSHForwardWaitsForListenerReadiness() async throws {
    let executable = try CodexCLIResolver().resolve()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("delayed-ssh.py")
    let environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": directory.path]) { _, new in new }
    let server = try CodexLoopbackWebSocketServer(executableURL: executable, port: 45441, environment: environment)
    try await server.start()
    // The fake SSH process itself owns the local port, just as OpenSSH does.
    let source = """
    #!/usr/bin/python3
    import socket,time,threading,select
    time.sleep(0.8)
    listener=socket.socket()
    listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    listener.bind(('127.0.0.1',45440))
    listener.listen(4)
    def forward(local):
        remote=socket.create_connection(('127.0.0.1',45441))
        try:
            while True:
                for source in select.select([local,remote],[],[])[0]:
                    data=source.recv(65536)
                    if not data: return
                    (remote if source is local else local).sendall(data)
        finally:
            local.close()
            remote.close()
    while True:
        local,_=listener.accept()
        threading.Thread(target=forward,args=(local,),daemon=True).start()
    """
    try source.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let client = CodexClient(transportFactory: try CodexHostTransports.sshForward(sshURL: script, host: .alias("test"), localPort: 45440, remotePort: 45440), configuration: .init(requestTimeout: .seconds(3), reconnectPolicy: .init(maximumAttempts: 0)))
    do { _ = try await client.connect() }
    catch { Issue.record("Connection attempted before tunnel listener was ready: \(error)") }
    await client.close(); await server.stop()
}


private actor ForwardTestBearer: CodexBearerCredentialProvider {
    var calls = 0
    var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(held: Bool = false) { self.held = held }
    func credential() async -> CodexBearerCredential {
        calls += 1
        if held { await withCheckedContinuation { continuation = $0 } }
        return .init(value: "forward-test-secret", kind: .capability)
    }
    func release() { continuation?.resume(); continuation = nil }
}

private func forwardTestListener(port: Int = 0, reuseAddress: Bool = false) throws -> (Int32, Int) {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CodexError.transportClosed("test socket") }
    if reuseAddress {
        var reuse: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else {
            Darwin.close(descriptor); throw CodexError.transportClosed("test reuse")
        }
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
            guard Darwin.bind(descriptor, pointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0,
                  Darwin.listen(descriptor, 4) == 0 else { return Int32(-1) }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            return Darwin.getsockname(descriptor, pointer, &length)
        }
    }
    guard result == 0 else { Darwin.close(descriptor); throw CodexError.transportClosed("test bind") }
    return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
}

private func forwardTestScript(directory: URL, source: String) throws -> URL {
    let script = directory.appendingPathComponent("ssh.py")
    try ("#!/usr/bin/python3\nimport os,time,socket,pathlib\nos.chdir(os.path.dirname(__file__))\n" + source).write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return script
}

private func waitForForwardFile(_ url: URL) async throws {
    for _ in 0..<500 {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CodexError.transportClosed("test fixture did not create \(url.lastPathComponent)")
}

@Test(arguments: [false, true])
func sshForwardRejectsOccupiedPortBeforeRequestingBearer(reuseAddress: Bool) async throws {
    let (listener, port) = try forwardTestListener(reuseAddress: reuseAddress)
    defer { Darwin.close(listener) }
    let bearer = ForwardTestBearer()
    let transport = try await CodexHostTransports.sshForward(sshURL: URL(fileURLWithPath: "/usr/bin/false"), host: .alias("test"), localPort: port, remotePort: port, bearer: bearer).makeTransport()
    do { try await transport.start(); Issue.record("Occupied forwarding port accepted") }
    catch { #expect(error as? CodexError == .transportClosed("SSH local forwarding port \(port) is unavailable")) }
    #expect(await bearer.calls == 0)
    await transport.close()
}

@Test func sshForwardRejectsListenerThatWinsPortAllocationRace() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (reservation, port) = try forwardTestListener()
    Darwin.close(reservation)
    let script = try forwardTestScript(directory: directory, source: "pathlib.Path('started').touch()\nwhile not pathlib.Path('exit').exists(): time.sleep(0.01)\n")
    let bearer = ForwardTestBearer()
    let transport = try await CodexHostTransports.sshForward(sshURL: script, host: .alias("test"), localPort: port, remotePort: port, bearer: bearer).makeTransport()
    let startup = Task { () -> Bool in do { try await transport.start(); return true } catch { return false } }
    try await waitForForwardFile(directory.appendingPathComponent("started"))
    let (intruder, _) = try forwardTestListener(port: port)
    defer { Darwin.close(intruder) }
    // Let readiness poll repeatedly while only the unrelated process owns the port.
    try await Task.sleep(for: .milliseconds(300))
    #expect(await bearer.calls == 0)
    try Data().write(to: directory.appendingPathComponent("exit"))
    #expect(!(await startup.value))
    await transport.close()
}

@Test(arguments: ["owned", "reconnect", "exitDuringCredential", "closeDuringCredential"])
func sshForwardUsesBearerOnlyWhileOwnedListenerIsReady(scenario: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (reservation, port) = try forwardTestListener()
    Darwin.close(reservation)
    let script = try forwardTestScript(directory: directory, source: """
    pathlib.Path('pid').write_text(str(os.getpid()))
    time.sleep(0.2)
    listener=socket.socket()
    listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    listener.bind(('127.0.0.1',\(port)))
    listener.listen(4)
    listener.settimeout(0.05)
    while not pathlib.Path('exit').exists():
        try: connection,_=listener.accept()
        except socket.timeout: continue
        connection.settimeout(2)
        data=b''
        while b'\\r\\n\\r\\n' not in data:
            chunk=connection.recv(4096)
            if not chunk: break
            data+=chunk
        pathlib.Path('request').write_bytes(data)
        connection.close()
    """)
    let bearer = ForwardTestBearer(held: scenario == "exitDuringCredential" || scenario == "closeDuringCredential")
    let transport = try await CodexHostTransports.sshForward(sshURL: script, host: .alias("test"), localPort: port, remotePort: port, bearer: bearer).makeTransport()
    let startup = Task { () -> Bool in do { try await transport.start(); return true } catch { return false } }
    for _ in 0..<500 {
        if await bearer.calls == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await bearer.calls == 1)
    if scenario == "owned" || scenario == "reconnect" {
        #expect(await startup.value)
        try await waitForForwardFile(directory.appendingPathComponent("request"))
        let request = try String(contentsOf: directory.appendingPathComponent("request"), encoding: .utf8)
        #expect(request.lowercased().contains("authorization: bearer forward-test-secret"))
        if scenario == "reconnect" {
            await transport.close()
            try FileManager.default.removeItem(at: directory.appendingPathComponent("request"))
            let replacement = try await CodexHostTransports.sshForward(sshURL: script, host: .alias("test"), localPort: port, remotePort: port, bearer: bearer).makeTransport()
            try await replacement.start()
            try await waitForForwardFile(directory.appendingPathComponent("request"))
            await replacement.close()
            #expect(await bearer.calls == 2)
        }
    } else {
        if scenario == "exitDuringCredential" {
            try Data().write(to: directory.appendingPathComponent("exit"))
            var iterator = transport.incomingFrames.makeAsyncIterator()
            do { _ = try await iterator.next(); Issue.record("Expected SSH exit error") } catch {}
        } else { await transport.close() }
        await bearer.release()
        #expect(!(await startup.value))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("request").path))
    }
    await transport.close()
    let pid = try Int32(String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8))!
    #expect(Darwin.kill(pid, 0) != 0)
}


@Test func webSocketCloseDuringCredentialLoadingPreventsLateStart() async throws {
    let bearer = ForwardTestBearer(held: true)
    let configuration = try CodexWebSocketConfiguration.trustedLoopback(url: URL(string: "ws://127.0.0.1:9")!, applicationBearer: bearer)
    let transport = try await CodexWebSocketTransport.factory(configuration: configuration).makeTransport()
    let startup = Task { () -> Bool in do { try await transport.start(); return true } catch { return false } }
    while await bearer.calls == 0 { await Task.yield() }
    await transport.close()
    await bearer.release()
    #expect(!(await startup.value))
    var iterator = transport.incomingFrames.makeAsyncIterator()
    #expect(try await iterator.next() == nil)
    await transport.close()
}

#endif
