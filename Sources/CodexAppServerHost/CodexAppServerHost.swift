#if os(macOS)
@preconcurrency import Foundation
import Darwin
import CodexAppServerKit

public struct CodexCLIVersion: Sendable, Comparable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    public init(major: Int, minor: Int, patch: Int) { self.major = major; self.minor = minor; self.patch = patch }
    public init?(_ text: String) {
        let match = text.split(whereSeparator: { !$0.isNumber && $0 != "." }).first(where: { $0.contains(".") }) ?? Substring(text)
        let parts = match.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }; major = parts[0]; minor = parts[1]; patch = parts.count > 2 ? parts[2] : 0
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch) }
    public var description: String { "\(major).\(minor).\(patch)" }
    public static let minimumSupported = Self(major: 0, minor: 146, patch: 0)
}

public enum CodexDaemonStatus: Sendable, Equatable { case notPrepared, stopped, running(version: String?), unavailable(String) }

public struct CodexCLIResolver: Sendable {
    public init() {}
    public func resolve(explicitURL: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let explicitURL, FileManager.default.isExecutableFile(atPath: explicitURL.path) { return explicitURL }
        var paths = (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        paths += [URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex")]
        guard let result = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw CodexError.invalidConfiguration("Codex CLI was not found") }
        return result
    }
}

public actor CodexDaemonController {
    public let executableURL: URL
    public let environment: [String: String]
    private var prepared = false
    public init(executableURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment) { self.executableURL = executableURL; self.environment = environment }

    public func cliVersion() throws -> CodexCLIVersion {
        let output = try run(["--version"])
        guard let version = CodexCLIVersion(output) else { throw CodexError.invalidConfiguration("Could not parse Codex version: \(output)") }
        guard version >= .minimumSupported else { throw CodexError.unsupportedFeature("Codex CLI 0.146.0 or newer is required; found \(version)") }
        return version
    }
    /// The only operation allowed to install/bootstrap durable daemon management.
    public func prepareManagedDaemon() throws { _ = try cliVersion(); _ = try run(["app-server", "daemon", "bootstrap"]); prepared = true }
    public func status() -> CodexDaemonStatus {
        do { let version = try run(["app-server", "daemon", "version"]).trimmingCharacters(in: .whitespacesAndNewlines); prepared = true; return .running(version: version) }
        catch { return prepared ? .stopped : .notPrepared }
    }
    public func ensureRunning() throws { _ = try cliVersion(); _ = try run(["app-server", "daemon", "start"]); prepared = true }
    public func start() throws { try ensureRunning() }
    public func stop() throws { _ = try run(["app-server", "daemon", "stop"]); prepared = true }
    public func restart() throws { _ = try cliVersion(); _ = try run(["app-server", "daemon", "restart"]); prepared = true }
    public func daemonVersion() throws -> String { try run(["app-server", "daemon", "version"]).trimmingCharacters(in: .whitespacesAndNewlines) }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = executableURL; process.arguments = arguments; process.environment = environment; process.standardOutput = output; process.standardError = error
        do { try process.run() } catch { throw CodexError.transportClosed(error.localizedDescription) }
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw CodexError.transportClosed(stderr.isEmpty ? stdout : stderr) }
        return stdout
    }
}

public enum CodexSSHHost: Sendable, Equatable {
    case alias(String)
    case structured(hostname: String, user: String?, port: Int?, identityFile: URL?, options: [String: String])
}

public enum CodexSSHArguments {
    private static let safeOptions: Set<String> = ["ConnectTimeout", "ServerAliveInterval", "ServerAliveCountMax", "IdentitiesOnly", "ProxyJump", "LogLevel", "IPQoS"]
    public static func build(host: CodexSSHHost, remoteArguments: [String]) throws -> [String] {
        var result = ["-o", "BatchMode=yes"]
        let destination: String
        switch host {
        case .alias(let value):
            guard !value.isEmpty, !value.hasPrefix("-") else { throw CodexError.invalidConfiguration("Invalid SSH alias") }; destination = value
        case .structured(let hostname, let user, let port, let identity, let options):
            guard !hostname.isEmpty, !hostname.hasPrefix("-") else { throw CodexError.invalidConfiguration("Invalid SSH hostname") }
            if let port { guard (1...65535).contains(port) else { throw CodexError.invalidConfiguration("Invalid SSH port") }; result += ["-p", String(port)] }
            if let identity { result += ["-i", identity.path] }
            for key in options.keys.sorted() { guard safeOptions.contains(key), let value = options[key], !value.contains("\n") else { throw CodexError.invalidConfiguration("Unsafe SSH option \(key)") }; result += ["-o", "\(key)=\(value)"] }
            destination = user.map { "\($0)@\(hostname)" } ?? hostname
        }
        return result + ["--", destination] + remoteArguments
    }
}

public enum CodexHostTransports {
    public static func isolated(executableURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment, maximumFrameBytes: Int = 32 * 1_024 * 1_024) -> CodexTransportFactory {
        .init {
            _ = try await CodexDaemonController(executableURL: executableURL, environment: environment).cliVersion()
            return ProcessJSONLTransport(executableURL: executableURL, arguments: ["app-server", "--listen", "stdio://"], environment: environment, maximumFrameBytes: maximumFrameBytes)
        }
    }
    public static func managedDaemon(controller: CodexDaemonController, maximumFrameBytes: Int = 32 * 1_024 * 1_024) -> CodexTransportFactory {
        .init {
            try await controller.ensureRunning()
            return ProcessJSONLTransport(executableURL: controller.executableURL, arguments: ["app-server", "proxy"], environment: controller.environment, maximumFrameBytes: maximumFrameBytes)
        }
    }
    public static func sshProxy(sshURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"), host: CodexSSHHost, maximumFrameBytes: Int = 32 * 1_024 * 1_024) throws -> CodexTransportFactory {
        let arguments = try CodexSSHArguments.build(host: host, remoteArguments: ["codex", "app-server", "proxy"])
        return process(executableURL: sshURL, arguments: arguments, environment: ProcessInfo.processInfo.environment, maximumFrameBytes: maximumFrameBytes)
    }
    public static func sshForward(sshURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"), host: CodexSSHHost, localPort: Int, remotePort: Int, remoteHost: String = "127.0.0.1", path: String = "/", bearer: (any CodexBearerCredentialProvider)? = nil) throws -> CodexTransportFactory {
        guard (1...65535).contains(localPort), (1...65535).contains(remotePort) else { throw CodexError.invalidConfiguration("SSH forwarding requires explicit valid local and remote ports") }
        let args = try CodexSSHArguments.build(host: host, remoteArguments: [])
        let insertion = ["-N", "-L", "\(localPort):\(remoteHost):\(remotePort)"]
        guard let marker = args.firstIndex(of: "--") else { throw CodexError.invalidConfiguration("Invalid SSH argument construction") }
        let tunnelArguments = Array(args[..<marker]) + insertion + Array(args[marker...])
        let url = URL(string: "ws://127.0.0.1:\(localPort)\(path.hasPrefix("/") ? path : "/" + path)")!
        return .init { SSHForwardTransport(sshURL: sshURL, arguments: tunnelArguments, webSocketConfiguration: try .trustedLoopback(url: url, applicationBearer: bearer)) }
    }
    private static func process(executableURL: URL, arguments: [String], environment: [String: String], maximumFrameBytes: Int) -> CodexTransportFactory {
        .init { ProcessJSONLTransport(executableURL: executableURL, arguments: arguments, environment: environment, maximumFrameBytes: maximumFrameBytes) }
    }
}

/// Immutable connection description suitable for storing in an app-owned host registry.
public enum CodexHostProfile: Sendable {
    case isolated(executableURL: URL, environment: [String: String])
    case managed(CodexDaemonController)
    case sshProxy(sshURL: URL, host: CodexSSHHost)
    case sshForward(sshURL: URL, host: CodexSSHHost, localPort: Int, remotePort: Int, remoteHost: String, path: String, bearer: (any CodexBearerCredentialProvider)?)

    public func transportFactory() throws -> CodexTransportFactory {
        switch self {
        case .isolated(let executable, let environment): CodexHostTransports.isolated(executableURL: executable, environment: environment)
        case .managed(let controller): CodexHostTransports.managedDaemon(controller: controller)
        case .sshProxy(let ssh, let host): try CodexHostTransports.sshProxy(sshURL: ssh, host: host)
        case .sshForward(let ssh, let host, let local, let remote, let remoteHost, let path, let bearer): try CodexHostTransports.sshForward(sshURL: ssh, host: host, localPort: local, remotePort: remote, remoteHost: remoteHost, path: path, bearer: bearer)
        }
    }
}

/// Supervises one host-local loopback WebSocket listener that can be shared by multiple clients.
public actor CodexLoopbackWebSocketServer {
    public let executableURL: URL
    public let port: Int
    public let environment: [String: String]
    private var process: Process?
    public init(executableURL: URL, port: Int, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard (1...65535).contains(port) else { throw CodexError.invalidConfiguration("Invalid loopback port") }
        self.executableURL = executableURL; self.port = port; self.environment = environment
    }
    public func start() async throws {
        if process?.isRunning == true { return }
        _ = try await CodexDaemonController(executableURL: executableURL, environment: environment).cliVersion()
        let child = Process(); child.executableURL = executableURL; child.arguments = ["app-server", "--listen", "ws://127.0.0.1:\(port)"]; child.environment = environment
        child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { throw CodexError.transportClosed(error.localizedDescription) }; process = child
        let health = URL(string: "http://127.0.0.1:\(port)/readyz")!
        for _ in 0..<40 {
            if !child.isRunning { process = nil; throw CodexError.transportClosed("Loopback listener exited during startup") }
            if let (_, response) = try? await URLSession.shared.data(from: health), (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await stop(); throw CodexError.transportClosed("Loopback listener did not become ready")
    }
    public func ensureRunning() async throws { try await start() }
    public func isRunning() -> Bool { process?.isRunning == true }
    public func stop() async {
        guard let process else { return }; self.process = nil
        if process.isRunning { process.terminate(); try? await Task.sleep(for: .milliseconds(100)); if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) } }
    }
    public func transportFactory(bearer: (any CodexBearerCredentialProvider)? = nil) throws -> CodexTransportFactory {
        let configuration = try CodexWebSocketConfiguration.trustedLoopback(url: URL(string: "ws://127.0.0.1:\(port)")!, applicationBearer: bearer)
        let server = self
        return .init { try await server.ensureRunning(); return try await CodexWebSocketTransport.factory(configuration: configuration).makeTransport() }
    }
}

private actor ProcessJSONLTransport: CodexTransport {
    nonisolated let incomingFrames: AsyncThrowingStream<Data, Error>
    nonisolated let diagnostics: AsyncStream<CodexTransportDiagnostic>
    private let frameContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let diagnosticContinuation: AsyncStream<CodexTransportDiagnostic>.Continuation
    private let executableURL: URL, arguments: [String], environment: [String: String]
    private let maximumFrameBytes: Int
    private var process: Process?, input: FileHandle?, outputHandle: FileHandle?, errorHandle: FileHandle?, outputBuffer = Data(), stderrTail = Data(), closing = false
    init(executableURL: URL, arguments: [String], environment: [String: String], maximumFrameBytes: Int) {
        self.executableURL = executableURL; self.arguments = arguments; self.environment = environment; self.maximumFrameBytes = maximumFrameBytes
        let frames = AsyncThrowingStream<Data, Error>.makeStream(); incomingFrames = frames.stream; frameContinuation = frames.continuation
        let diagnostics = AsyncStream<CodexTransportDiagnostic>.makeStream(); self.diagnostics = diagnostics.stream; diagnosticContinuation = diagnostics.continuation
    }
    func start() throws {
        guard process == nil else { throw CodexError.alreadyConnected }
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = executableURL; child.arguments = arguments; child.environment = environment; child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in let data = handle.availableData; Task { await self?.receiveStdout(data) } }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in let data = handle.availableData; Task { await self?.receiveStderr(data) } }
        child.terminationHandler = { [weak self] child in Task { await self?.terminated(child.terminationStatus) } }
        do { try child.run() } catch { throw CodexError.transportClosed(error.localizedDescription) }
        process = child; input = stdin.fileHandleForWriting; outputHandle = stdout.fileHandleForReading; errorHandle = stderr.fileHandleForReading
    }
    func send(frame: Data) throws {
        guard let input else { throw CodexError.disconnected }; guard frame.count <= maximumFrameBytes else { throw CodexError.frameTooLarge(actual: frame.count, limit: maximumFrameBytes) }
        var value = frame; value.append(0x0A); do { try input.write(contentsOf: value) } catch { throw CodexError.transportClosed(error.localizedDescription) }
    }
    func close() async {
        guard !closing else { return }; closing = true; try? input?.close(); input = nil
        if let process, process.isRunning { process.terminate(); try? await Task.sleep(for: .milliseconds(100)); if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) } }
        finish(nil)
    }
    private func receiveStdout(_ data: Data) {
        guard !data.isEmpty else { return }; outputBuffer.append(data)
        if outputBuffer.count > maximumFrameBytes, !outputBuffer.contains(0x0A) { finish(CodexError.frameTooLarge(actual: outputBuffer.count, limit: maximumFrameBytes)); return }
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            var frame = Data(outputBuffer[..<newline]); outputBuffer.removeSubrange(...newline); if frame.last == 0x0D { frame.removeLast() }
            if frame.count > maximumFrameBytes { finish(CodexError.frameTooLarge(actual: frame.count, limit: maximumFrameBytes)); return }
            if !frame.isEmpty { frameContinuation.yield(frame) }
        }
    }
    private func receiveStderr(_ data: Data) { guard !data.isEmpty else { return }; stderrTail.append(data); if stderrTail.count > 65_536 { stderrTail.removeFirst(stderrTail.count - 65_536) }; diagnosticContinuation.yield(.init(level: .debug, message: String(decoding: data, as: UTF8.self))) }
    private func terminated(_ code: Int32) {
        outputHandle?.readabilityHandler = nil; errorHandle?.readabilityHandler = nil
        if let trailing = outputHandle?.readDataToEndOfFile(), !trailing.isEmpty { receiveStdout(trailing) }
        if let trailing = errorHandle?.readDataToEndOfFile(), !trailing.isEmpty { receiveStderr(trailing) }
        finish(closing || code == 0 ? nil : CodexError.transportClosed("process exited \(code): \(String(decoding: stderrTail, as: UTF8.self))"))
    }
    private func finish(_ error: Error?) {
        guard process != nil else { return }; process = nil; try? input?.close(); input = nil
        outputHandle?.readabilityHandler = nil; errorHandle?.readabilityHandler = nil; outputHandle = nil; errorHandle = nil
        if let error { frameContinuation.finish(throwing: error) } else { frameContinuation.finish() }; diagnosticContinuation.finish()
    }
}

private actor SSHForwardTransport: CodexTransport {
    nonisolated let incomingFrames: AsyncThrowingStream<Data, Error>
    nonisolated let diagnostics: AsyncStream<CodexTransportDiagnostic>
    private let frames: AsyncThrowingStream<Data, Error>.Continuation, diagnostic: AsyncStream<CodexTransportDiagnostic>.Continuation
    private let sshURL: URL, arguments: [String], webSocketConfiguration: CodexWebSocketConfiguration
    private var process: Process?, inner: (any CodexTransport)?, tasks: [Task<Void, Never>] = []
    init(sshURL: URL, arguments: [String], webSocketConfiguration: CodexWebSocketConfiguration) {
        self.sshURL = sshURL; self.arguments = arguments; self.webSocketConfiguration = webSocketConfiguration
        let f = AsyncThrowingStream<Data, Error>.makeStream(); incomingFrames = f.stream; frames = f.continuation
        let d = AsyncStream<CodexTransportDiagnostic>.makeStream(); diagnostics = d.stream; diagnostic = d.continuation
    }
    func start() async throws {
        let child = Process(), errors = Pipe(); child.executableURL = sshURL; child.arguments = arguments; child.standardError = errors
        do { try child.run() } catch { throw CodexError.transportClosed(error.localizedDescription) }; process = child
        try await Task.sleep(for: .milliseconds(200))
        guard child.isRunning else { throw CodexError.transportClosed(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
        let transport = try await CodexWebSocketTransport.factory(configuration: webSocketConfiguration).makeTransport(); try await transport.start(); inner = transport
        let incoming = transport.incomingFrames, diagnostics = transport.diagnostics
        tasks = [Task { [weak self] in do { for try await frame in incoming { self?.frames.yield(frame) } } catch { self?.frames.finish(throwing: error) } }, Task { [weak self] in for await value in diagnostics { self?.diagnostic.yield(value) } }]
    }
    func send(frame: Data) async throws { guard let inner else { throw CodexError.disconnected }; try await inner.send(frame: frame) }
    func close() async { for task in tasks { task.cancel() }; tasks.removeAll(); await inner?.close(); inner = nil; if let process, process.isRunning { process.terminate() }; process = nil; frames.finish(); diagnostic.finish() }
}
#endif
