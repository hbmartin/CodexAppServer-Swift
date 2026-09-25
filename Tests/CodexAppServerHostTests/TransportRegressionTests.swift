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
    let fixture = try await InheritedPipeFixture()
    try await fixture.run { fixture in
        let processes = try await fixture.waitForReadiness()
        #expect(Darwin.kill(processes.child, 0) == 0)
        let started = ContinuousClock.now
        await fixture.transport.close()
        // The descendant must still hold the pipes open throughout the measured close.
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(Darwin.kill(processes.child, 0) == 0)
    }
}

@Test func processTransportReadinessTimeoutCleansUpInheritedPipeFixture() async throws {
    let fixture = try await InheritedPipeFixture(publishesReadiness: false)
    await #expect(throws: InheritedPipeFixture.Failure.timedOut("ready")) {
        try await fixture.run { fixture in
            // Establish that a real descendant exists before exercising unavailable readiness.
            let processes = try await fixture.waitForDiagnosticPIDs()
            #expect(Darwin.kill(processes.child, 0) == 0)
            _ = try await fixture.waitForReadiness(timeout: .milliseconds(100))
        }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
}

@Test func processTransportCancellationCleansUpInheritedPipeFixture() async throws {
    let fixture = try await InheritedPipeFixture(publishesReadiness: false)
    let task = Task {
        try await fixture.run { fixture in
            _ = try await fixture.waitForReadiness(timeout: .seconds(30))
        }
    }
    do {
        let processes = try await fixture.waitForDiagnosticPIDs()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(processes.running.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    } catch {
        task.cancel()
        _ = await task.result
        throw error
    }
}

private struct InheritedPipeFixture: Sendable {
    enum Failure: Error, Equatable {
        case timedOut(String)
        case processesDidNotExit([Int32])
    }

    struct ProcessIDs: Decodable, Sendable {
        let parent: Int32
        let child: Int32
        var running: [Int32] { [parent, child].filter { Darwin.kill($0, 0) == 0 } }
    }

    let directory: URL
    let transport: any CodexTransport
    private let lifetime: URL
    private let readiness: URL
    private let diagnosticPIDs: URL

    init(publishesReadiness: Bool = true) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        lifetime = directory.appendingPathComponent("lifetime")
        readiness = directory.appendingPathComponent("ready")
        diagnosticPIDs = directory.appendingPathComponent("processes.json")
        do {
            try Data().write(to: lifetime)
            let script = directory.appendingPathComponent("inherited-pipes.py")
            let source = """
            #!/usr/bin/python3
            import json, os, pathlib, signal, time
            directory = pathlib.Path(__file__).parent
            parent = os.getpid()
            child = os.fork()
            if child == 0:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                processes = json.dumps({"parent": parent, "child": os.getpid()})
                (directory / "processes.json").write_text(processes)
                if \(publishesReadiness ? "True" : "False"):
                    (directory / "ready").write_text(processes)
                while (directory / "lifetime").exists(): time.sleep(0.01)
                os._exit(0)
            while True: time.sleep(1)
            """
            try source.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            transport = try await CodexHostTransports.sshProxy(sshURL: script, host: .alias("ignored")).makeTransport()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func run(_ operation: @Sendable (Self) async throws -> Void) async throws {
        // Removing the directory is also a fallback for the lifetime marker on every exit.
        defer { try? FileManager.default.removeItem(at: directory) }
        let result: Result<Void, Error>
        do {
            try await transport.start()
            try await operation(self)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        do { try await cleanUp() }
        catch { Issue.record(error) }
        try result.get()
    }

    func waitForReadiness(timeout: Duration = .seconds(5)) async throws -> ProcessIDs {
        try await waitForPIDs(at: readiness, timeout: timeout)
    }

    func waitForDiagnosticPIDs() async throws -> ProcessIDs {
        try await waitForPIDs(at: diagnosticPIDs, timeout: .seconds(5))
    }

    private func readPIDs(at url: URL) -> ProcessIDs? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProcessIDs.self, from: data)
    }

    private func waitForPIDs(at url: URL, timeout: Duration) async throws -> ProcessIDs {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let processes = readPIDs(at: url) { return processes }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.timedOut(url.lastPathComponent)
    }

    private func cleanUp() async throws {
        // A detached task does not inherit cancellation from the test's readiness wait.
        try await Task.detached {
            let removal = Result { try FileManager.default.removeItem(at: lifetime) }
            await transport.close()
            try removal.get()
            // PID reporting verifies cleanup; removing the marker stops the child even when
            // startup never supplied a PID or readiness record to the test.
            if let processes = readPIDs(at: diagnosticPIDs) {
                let deadline = ContinuousClock.now + .seconds(5)
                while !processes.running.isEmpty, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let running = processes.running
                guard running.isEmpty else { throw Failure.processesDidNotExit(running) }
            }
        }.value
    }
}

@Test func processTransportCannotRestartAfterClose() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("single-start.py")
    let launches = directory.appendingPathComponent("launches")
    let source = """
    #!/usr/bin/python3
    import time
    with open(\"\(launches.path)\", \"a\") as output:
        output.write("started\\n")
        output.flush()
    while True: time.sleep(1)
    """
    try source.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let transport = try await CodexHostTransports.sshProxy(sshURL: script, host: .alias("ignored")).makeTransport()
    try await transport.start()
    try await waitForForwardFile(launches, expectedContents: "started\n")
    await transport.close()
    await #expect(throws: CodexError.alreadyConnected) { try await transport.start() }
    let launchCount = try String(contentsOf: launches, encoding: .utf8).split(separator: "\n").count
    #expect(launchCount == 1)
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

private func waitForForwardFile(_ url: URL, expectedContents: String? = nil) async throws {
    for _ in 0..<500 {
        if let expectedContents {
            if (try? String(contentsOf: url, encoding: .utf8)) == expectedContents { return }
        } else if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    let expectation = expectedContents.map { " with contents \(String(reflecting: $0))" } ?? ""
    throw CodexError.transportClosed("test fixture did not create \(url.lastPathComponent)\(expectation)")
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
