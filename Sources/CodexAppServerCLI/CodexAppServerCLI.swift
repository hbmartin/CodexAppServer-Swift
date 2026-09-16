import ArgumentParser
import Foundation
import CodexAppServerKit
#if os(macOS)
import Darwin
import CodexAppServerHost
import CodexAppServerRemote

private struct EnvironmentBearer: CodexBearerCredentialProvider {
    let variable: String
    func credential() async throws -> CodexBearerCredential {
        guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else { throw CodexError.invalidConfiguration("Missing environment variable \(variable)") }
        return .init(value: value, kind: .capability)
    }
}
private struct EnvironmentTunnel: CodexTunnelHeaderProvider {
    let header: String, variable: String
    func headers() async throws -> [String: String] {
        guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else { throw CodexError.invalidConfiguration("Missing environment variable \(variable)") }
        return [header: value]
    }
}

private actor InteractionInbox {
    private var values: [CodexPendingInteraction] = []
    func append(_ value: CodexPendingInteraction) { values.removeAll { $0.requestID == value.requestID }; values.append(value) }
    func latest() -> CodexPendingInteraction? { values.last }
    func value(id: String) -> CodexPendingInteraction? { values.last { $0.id == id } }
    func remove(_ id: String) { values.removeAll { $0.id == id } }
}

private actor CLIJSONWriter {
    func write(_ value: JSONValue, to handle: FileHandle = .standardOutput) {
        guard let data = try? value.encoded(sortedKeys: true) else { return }
        handle.write(data); handle.write(Data([0x0A]))
    }
}

struct CLIMachineCommand: Sendable, Equatable {
    var id: String
    var name: String
    var arguments: JSONValue
}

struct CLIExecutableOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the Codex CLI executable.") var codex: String?
    func resolve() throws -> URL { try CodexCLIResolver().resolve(explicitURL: codex.map(URL.init(fileURLWithPath:))) }
}
struct JSONOutputOption: ParsableArguments { @Flag(name: .long, help: "Emit versioned JSON output.") var json = false }
struct NotificationOption: ParsableArguments {
    @Option(name: .customLong("notify-config"), help: "HTTP notification configuration file.") private var notifyConfigs: [String] = []
    var notifyConfig: String? { notifyConfigs.first }
    mutating func validate() throws {
        guard notifyConfigs.count <= 1 else { throw ValidationError("--notify-config may be supplied only once") }
        guard notifyConfigs.first?.isEmpty != true else { throw ValidationError("--notify-config requires a file path") }
    }
}
struct RemoteAuthOptions: ParsableArguments {
    @Option(name: .long, help: "Environment variable containing the account access token.") var accountTokenEnv: String?
    @Option(name: .long, help: "Environment variable containing the account ID.") var accountIDEnv: String?
    @Option(name: .long, help: "Explicit Codex auth.json path.") var authFile: String?
    @Option(name: .long, help: "Executable implementing the Remote Control authorization-helper JSON protocol.") var authorizationHelper: String?
    mutating func validate() throws {
        guard (accountTokenEnv == nil) == (accountIDEnv == nil) else { throw ValidationError("--account-token-env and --account-id-env must be supplied together") }
        guard accountTokenEnv == nil || authFile == nil else { throw ValidationError("environment credentials and --auth-file are mutually exclusive") }
    }
    func provider() throws -> any CodexRemoteCredentialProvider {
        if let accountTokenEnv, let accountIDEnv { return CodexRemoteEnvironmentCredentialProvider(tokenVariable: accountTokenEnv, accountIDVariable: accountIDEnv) }
        return try CodexRemoteCodexLoginCredentialProvider(authFileURL: authFile.map(URL.init(fileURLWithPath:)))
    }
    func controller(requireAuthorization: Bool = false) throws -> CodexRemoteController {
        let authorization = try authorizationHelper.map { try RemoteAuthorizationHelper(path: $0) }
        if requireAuthorization, authorization == nil {
            throw ValidationError("--authorization-helper is required; Remote Control pairing and connections use step-up enrollment and device-key signing")
        }
        return .init(credentials: try provider(), authorizationProvider: authorization)
    }
}

struct RemoteAuthorizationHelper: CodexRemoteClientAuthorizationProvider {
    let executableURL: URL
    let timeout: Duration

    init(path: String, timeout: Duration = .seconds(30)) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ValidationError("--authorization-helper must name an executable file")
        }
        executableURL = url
        self.timeout = timeout
    }

    func authorization(for credential: CodexRemoteCredential, forceRefresh: Bool) async throws -> CodexRemoteClientAuthorization {
        let output = try await run(action: "authorize", input: [
            "schemaVersion": 1,
            "action": "authorize",
            "accountID": .string(credential.accountID),
            "accountAccessToken": .string(credential.accessToken.unsafeRawValue),
            "forceRefresh": .bool(forceRefresh),
        ])
        let value = output["authorization"] ?? output
        let accountID = value["accountID"]?.stringValue ?? credential.accountID
        guard let clientID = value["clientID"]?.stringValue,
              let sessionToken = value["sessionToken"]?.stringValue else {
            throw CodexRemoteError.malformedResponse("authorization helper omitted clientID or sessionToken")
        }
        let expiresAt: Date?
        if let text = value["expiresAt"]?.stringValue {
            let standard = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions.insert(.withFractionalSeconds)
            guard let parsed = standard.date(from: text) ?? fractional.date(from: text) else {
                throw CodexRemoteError.malformedResponse("authorization helper returned an invalid expiresAt value")
            }
            expiresAt = parsed
        }
        else if let epoch = value["expiresAt"]?.int64Value { expiresAt = Date(timeIntervalSince1970: TimeInterval(epoch)) }
        else { expiresAt = nil }
        let scopes = value["scopes"]?.arrayValue?.compactMap(\.stringValue)
            ?? [CodexRemoteClientAuthorization.controllerWebSocketScope]
        return try .init(
            accountID: accountID,
            accountUserID: value["accountUserID"]?.stringValue,
            clientID: clientID,
            sessionToken: .init(sessionToken),
            expiresAt: expiresAt,
            scopes: scopes,
            requiresDeviceKeyProof: value["requiresDeviceKeyProof"]?.boolValue ?? true
        )
    }

    func response(to challenge: JSONValue, using authorization: CodexRemoteClientAuthorization) async throws -> JSONValue {
        let output = try await run(action: "sign-challenge", input: [
            "schemaVersion": 1,
            "action": "sign-challenge",
            "accountID": .string(authorization.accountID),
            "accountUserID": authorization.accountUserID.map(JSONValue.string) ?? .null,
            "clientID": .string(authorization.clientID),
            "challenge": challenge,
        ])
        return output["proof"] ?? output
    }

    private func run(action: String, input: JSONValue) async throws -> JSONValue {
        let executableURL = self.executableURL
        let timeout = self.timeout
        let inputData = try input.encoded()
        let worker = Task.detached {
            let process = Process()
            let standardInput = Pipe(), standardOutput = Pipe(), standardError = Pipe()
            process.executableURL = executableURL
            process.arguments = [action]
            process.standardInput = standardInput
            process.standardOutput = standardOutput
            process.standardError = standardError
            try process.run()
            standardInput.fileHandleForWriting.write(inputData)
            standardInput.fileHandleForWriting.write(Data([0x0A]))
            try standardInput.fileHandleForWriting.close()
            let outputTask = Task.detached { () -> (data: Data, exceededLimit: Bool) in
                let handle = standardOutput.fileHandleForReading
                defer { try? handle.close() }
                let limit = 1_048_576
                var data = Data()
                while data.count <= limit {
                    let count = min(64 * 1_024, limit + 1 - data.count)
                    guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else { break }
                    data.append(chunk)
                }
                let exceededLimit = data.count > limit
                if exceededLimit, process.isRunning {
                    process.terminate()
                    usleep(100_000)
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                }
                return (data, exceededLimit)
            }
            let errorTask = Task.detached {
                let handle = standardError.fileHandleForReading
                defer { try? handle.close() }
                while let chunk = try? handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {}
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var timedOut = false
            do {
                while process.isRunning {
                    try Task.checkCancellation()
                    if clock.now >= deadline { timedOut = true; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch is CancellationError {
                await terminateAuthorizationHelper(process)
                outputTask.cancel(); errorTask.cancel()
                _ = await outputTask.value; _ = await errorTask.value
                throw CancellationError()
            }
            if timedOut { await terminateAuthorizationHelper(process) }
            else { await Task.detached { process.waitUntilExit() }.value }
            let outputResult = await outputTask.value
            _ = await errorTask.value
            if timedOut {
                throw CodexRemoteError.authorizationRequired("authorization helper timed out for \(action)")
            }
            guard !outputResult.exceededLimit else {
                throw CodexRemoteError.malformedResponse("authorization helper output exceeded 1 MiB")
            }
            guard process.terminationStatus == 0 else {
                throw CodexRemoteError.authorizationRequired("authorization helper failed for \(action) with status \(process.terminationStatus)")
            }
            do { return try JSONValue.decode(outputResult.data) }
            catch { throw CodexRemoteError.malformedResponse("authorization helper returned invalid JSON for \(action)") }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}

private func terminateAuthorizationHelper(_ process: Process) async {
    if process.isRunning {
        process.terminate()
        try? await Task.sleep(for: .milliseconds(100))
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }
    await Task.detached { process.waitUntilExit() }.value
}

@main
struct CodexAppServerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codex-app-server-cli",
        abstract: "Connect to Codex app-server locally or through Remote Control.",
        subcommands: [Daemon.self, Connect.self, Remote.self]
    )
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var command: any ParsableCommand
        do {
            command = try await asyncParseAsRoot(arguments)
        } catch {
            if error is CleanExit || !arguments.contains("--json") { exit(withError: error) }
            emitMachineError(id: nil, code: "invalid_arguments", message: message(for: error))
            Darwin.exit(EXIT_FAILURE)
        }
        do {
            if var asyncCommand = command as? any AsyncParsableCommand { try await asyncCommand.run() }
            else { try command.run() }
        } catch {
            if error is CleanExit || !arguments.contains("--json") { exit(withError: error) }
            let rendered = error is ValidationError ? message(for: error) : error.localizedDescription
            emitMachineError(id: nil, code: cliErrorCode(error), message: rendered)
            Darwin.exit(EXIT_FAILURE)
        }
    }
    mutating func run() async throws { throw CleanExit.helpRequest(self) }

    struct Daemon: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Manage the local app-server daemon.", subcommands: [Prepare.self, Status.self, Start.self, Stop.self, Restart.self, Version.self])
        struct Prepare: AsyncParsableCommand { @OptionGroup var cli: CLIExecutableOptions; @OptionGroup var output: JSONOutputOption; func run() async throws { let c = CodexDaemonController(executableURL: try cli.resolve()); try await c.prepareManagedDaemon(); emitOneShot(output.json, ["status": "prepared"]) } }
        struct Status: AsyncParsableCommand { @OptionGroup var cli: CLIExecutableOptions; @OptionGroup var output: JSONOutputOption; func run() async throws { let value = await CodexDaemonController(executableURL: try cli.resolve()).status(); emitOneShot(output.json, daemonStatusJSON(value), text: String(describing: value)) } }
        struct Start: AsyncParsableCommand { @OptionGroup var cli: CLIExecutableOptions; @OptionGroup var output: JSONOutputOption; func run() async throws { try await CodexDaemonController(executableURL: try cli.resolve()).start(); emitOneShot(output.json, ["status": "started"]) } }
        struct Stop: AsyncParsableCommand { @OptionGroup var cli: CLIExecutableOptions; @OptionGroup var output: JSONOutputOption; func run() async throws { try await CodexDaemonController(executableURL: try cli.resolve()).stop(); emitOneShot(output.json, ["status": "stopped"]) } }
        struct Restart: AsyncParsableCommand { @OptionGroup var cli: CLIExecutableOptions; @OptionGroup var output: JSONOutputOption; func run() async throws { try await CodexDaemonController(executableURL: try cli.resolve()).restart(); emitOneShot(output.json, ["status": "restarted"]) } }
        struct Version: AsyncParsableCommand { @OptionGroup var cli: CLIExecutableOptions; @OptionGroup var output: JSONOutputOption; func run() async throws { let value = try await CodexDaemonController(executableURL: try cli.resolve()).daemonVersion(); emitOneShot(output.json, ["version": .string(value)], text: value) } }
    }

    struct Connect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open an interactive app-server connection.", subcommands: [Isolated.self, Managed.self, SSHProxy.self, SSHForward.self, WSS.self])
        struct Isolated: AsyncParsableCommand {
            @OptionGroup var cli: CLIExecutableOptions; @OptionGroup var notification: NotificationOption; @OptionGroup var output: JSONOutputOption
            func run() async throws { try await runInteractive(factory: CodexHostTransports.isolated(executableURL: try cli.resolve()), notificationPath: notification.notifyConfig, json: output.json) }
        }
        struct Managed: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "daemon")
            @OptionGroup var cli: CLIExecutableOptions; @OptionGroup var notification: NotificationOption; @OptionGroup var output: JSONOutputOption
            func run() async throws { try await runInteractive(factory: CodexHostTransports.managedDaemon(controller: .init(executableURL: try cli.resolve())), notificationPath: notification.notifyConfig, json: output.json) }
        }
        struct SSHProxy: AsyncParsableCommand {
            @Argument(help: "SSH host alias.") var host: String; @Option(name: .long) var ssh = "/usr/bin/ssh"
            @OptionGroup var notification: NotificationOption; @OptionGroup var output: JSONOutputOption
            func run() async throws { try await runInteractive(factory: try CodexHostTransports.sshProxy(sshURL: URL(fileURLWithPath: ssh), host: .alias(host)), notificationPath: notification.notifyConfig, json: output.json) }
        }
        struct SSHForward: AsyncParsableCommand {
            @Argument var host: String; @Option(name: .long) var ssh = "/usr/bin/ssh"; @Option(name: .long) var localPort: Int; @Option(name: .long) var remotePort: Int
            @Option(name: .long) var remoteHost = "127.0.0.1"; @Option(name: .long) var path = "/"; @Option(name: .long) var appBearerEnv: String?
            @OptionGroup var notification: NotificationOption; @OptionGroup var output: JSONOutputOption
            func run() async throws { let bearer = appBearerEnv.map(EnvironmentBearer.init); let factory = try CodexHostTransports.sshForward(sshURL: URL(fileURLWithPath: ssh), host: .alias(host), localPort: localPort, remotePort: remotePort, remoteHost: remoteHost, path: path, bearer: bearer); try await runInteractive(factory: factory, notificationPath: notification.notifyConfig, json: output.json) }
        }
        struct WSS: AsyncParsableCommand {
            @Argument var url: String; @Option(name: .long) var appBearerEnv: String; @Option(name: .long) var tunnelEnv: String; @Option(name: .long) var tunnelHeader: String
            @OptionGroup var notification: NotificationOption; @OptionGroup var output: JSONOutputOption
            func run() async throws { guard let value = URL(string: url) else { throw ValidationError("invalid WSS URL") }; let config = try CodexWebSocketConfiguration(wssURL: value, applicationBearer: EnvironmentBearer(variable: appBearerEnv), tunnelHeaders: EnvironmentTunnel(header: tunnelHeader, variable: tunnelEnv)); try await runInteractive(factory: CodexWebSocketTransport.factory(configuration: config), notificationPath: notification.notifyConfig, json: output.json) }
        }
    }

    struct Remote: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Discover, pair, and connect through Codex Remote Control.", subcommands: [Pair.self, Hosts.self, Connect.self, Remove.self, RevokeClient.self])
        struct Pair: AsyncParsableCommand {
            @Argument(help: "Pairing code or pairing URL. Securely prompted when omitted.") var code: String?
            @OptionGroup var auth: RemoteAuthOptions; @OptionGroup var output: JSONOutputOption
            func run() async throws {
                let controller = try auth.controller(requireAuthorization: true)
                let value: String
                if let code { value = code }
                else { guard isatty(STDIN_FILENO) == 1, let pointer = getpass("Pairing code: ") else { throw ValidationError("a pairing code is required in noninteractive mode") }; value = String(cString: pointer) }
                let result = try await controller.pair(.init(qrPayload: value))
                emitOneShot(output.json, pairingJSON(result), text: "paired client \(result.clientID)\(result.environmentID.map { " with \($0)" } ?? "")")
            }
        }
        struct Hosts: AsyncParsableCommand {
            @OptionGroup var auth: RemoteAuthOptions; @OptionGroup var output: JSONOutputOption
            func run() async throws { let listing = try await auth.controller().listHosts(); let value: JSONValue = ["hosts": .array(listing.hosts.map(\.raw)), "diagnostics": .array(listing.diagnostics.map(diagnosticJSON))]; emitOneShot(output.json, value, text: listing.hosts.map { "\($0.id)\t\($0.name ?? "")\t\($0.online.map(String.init) ?? "unknown")" }.joined(separator: "\n")) }
        }
        struct Connect: AsyncParsableCommand {
            @Argument(help: "Environment ID. Prompted from online environments when omitted.") var environmentID: String?
            @OptionGroup var auth: RemoteAuthOptions; @OptionGroup var notification: NotificationOption; @OptionGroup var output: JSONOutputOption
            func run() async throws {
                let controller = try auth.controller(requireAuthorization: true); let chosen = try await selectRemoteHost(controller: controller, requested: environmentID, machineMode: output.json)
                let session = try await controller.connect(environmentID: chosen)
                do { try await runInteractive(client: session.client, notificationPath: notification.notifyConfig, json: output.json) }
                catch { await session.close(); throw error }
                await session.close()
            }
        }
        struct Remove: AsyncParsableCommand {
            @Argument var environmentID: String; @OptionGroup var auth: RemoteAuthOptions; @OptionGroup var output: JSONOutputOption
            func run() async throws { try await auth.controller().removeEnvironment(id: environmentID); emitOneShot(output.json, ["environmentID": .string(environmentID), "status": "removed"], text: "removed \(environmentID)") }
        }
        struct RevokeClient: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "revoke-client")
            @OptionGroup var auth: RemoteAuthOptions; @OptionGroup var output: JSONOutputOption
            func run() async throws { try await auth.controller(requireAuthorization: true).revokeClient(); emitOneShot(output.json, ["status": "revoked"], text: "revoked Remote Control client") }
        }
    }

    static func decodeMachineCommand(_ line: String) throws -> CLIMachineCommand {
        let input = try JSONValue.decode(Data(line.utf8))
        guard input["schemaVersion"]?.intValue == 1 else { throw CodexError.invalidArgument("schemaVersion must be 1") }
        guard let id = input["id"]?.stringValue, !id.isEmpty else { throw CodexError.invalidArgument("id must be a non-empty string") }
        guard let command = input["command"]?.stringValue, !command.isEmpty else { throw CodexError.invalidArgument("command is required") }
        let arguments = input["arguments"] ?? .object([:])
        guard arguments.objectValue != nil else { throw CodexError.invalidArgument("arguments must be an object") }
        return .init(id: id, name: command, arguments: arguments)
    }
}

func runInteractive(factory: CodexTransportFactory, notificationPath: String?, json: Bool) async throws {
    let registry = CodexDynamicToolRegistry(tools: [.init(name: "sdk_echo", description: "Echo JSON input", inputSchema: ["type": "object"]) { .text(String(decoding: try $0.encoded(sortedKeys: true), as: UTF8.self)) }])
    let client = CodexClient(transportFactory: factory, dynamicTools: registry)
    do {
        _ = try await client.connect()
        try await runInteractive(client: client, notificationPath: notificationPath, json: json)
    } catch {
        await client.close()
        throw error
    }
    await client.close()
}

private func runInteractive(client: CodexClient, notificationPath: String?, json: Bool) async throws {
    let notifier = try notificationPath.map { CLINotificationDispatcher(configuration: try .load(path: $0)) }
    let inbox = InteractionInbox(), subscription = await client.subscribe(policy: .boundedCoalescingDeltas(1_024), includesProtocolMessages: json), writer = CLIJSONWriter()
    let eventTask = Task {
        do {
            for try await event in subscription.events {
                if case .serverRequest(let request) = event { await inbox.append(request) }
                if let notifier { await notifier.enqueue(event) }
                if json { await printMachineEvent(event, writer: writer) } else { printHumanEvent(event) }
            }
        } catch {
            if json { await writer.write(machineRecord(type: "diagnostic", fields: ["message": .string(error.localizedDescription)])) }
            else { print("event stream ended: \(error.localizedDescription)") }
        }
    }
    do { if json { try await machineLoop(client, inbox: inbox, writer: writer) } else { try await textLoop(client, inbox: inbox) } }
    catch { eventTask.cancel(); await eventTask.value; if let notifier { await notifier.finish() }; throw error }
    eventTask.cancel(); await eventTask.value; if let notifier { await notifier.finish() }
}

private func textLoop(_ client: CodexClient, inbox: InteractionInbox) async throws {
    var threadID: String?, turnID: String?
    print("connected; type help")
    while true {
        print("codex> ", terminator: ""); guard let line = readLine() else { return }
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init); guard let command = parts.first else { continue }
        switch command {
        case "help": print("list | open ID | new [MODEL] | fork [full|lastTurn] | history | say TEXT | steer TEXT | interrupt | review [BRANCH] | models | search QUERY | shell COMMAND | approve [DECISION] | answer QUESTION_ID VALUE | reconnect | quit")
        case "list": for item in try await client.listThreads(.init(limit: 50)).items { print("\(item.id)\t\(item.name ?? "")\t\(item.status ?? "")") }
        case "open": guard parts.count > 1 else { print("open ID"); continue }; threadID = (try await client.subscribeThread(id: parts[1])).id; print("opened \(threadID!)")
        case "new": let thread = try await client.startThread(options: .init(model: parts.count > 1 ? parts[1] : nil)); threadID = thread.id; print("created \(thread.id)")
        case "fork": guard let threadID else { print("open a thread first"); continue }; let thread = try await client.forkThread(id: threadID, mode: parts.count > 1 && parts[1] == "lastTurn" ? .lastTurn : .fullHistory); print("forked \(thread.id)")
        case "history": guard let threadID else { print("open a thread first"); continue }; for turn in try await client.listTurns(threadID: threadID, limit: 20, itemView: .full).items { print("\(turn.id) \(turn.status ?? "")") }
        case "say": guard let threadID, parts.count > 1 else { print("say TEXT"); continue }; let turn = try await client.startTurn(threadID: threadID, prompt: parts.dropFirst().joined(separator: " ")); turnID = turn.id; print("turn \(turn.id)")
        case "steer": guard let threadID, let turnID, parts.count > 1 else { print("steer TEXT"); continue }; _ = try await client.steerTurn(threadID: threadID, expectedTurnID: turnID, inputs: [.text(parts.dropFirst().joined(separator: " "))])
        case "interrupt": guard let threadID, let turnID else { print("no active turn"); continue }; try await client.interruptTurn(threadID: threadID, turnID: turnID)
        case "review": guard let threadID else { print("open a thread first"); continue }; let target: CodexReviewTarget = parts.count > 1 ? .init(.baseBranch(parts[1])) : .init(.uncommitted); print(try await client.startReview(threadID: threadID, target: target))
        case "models": for model in try await client.listModels() { print(model.id) }
        case "search": guard parts.count > 1 else { print("search QUERY"); continue }; print(try await client.startFileSearch(sessionID: UUID().uuidString, roots: [FileManager.default.currentDirectoryPath], query: parts.dropFirst().joined(separator: " ")))
        case "shell": guard let threadID, parts.count > 1 else { print("shell COMMAND"); continue }; print(try await client.runThreadShellCommand(threadID: threadID, command: parts.dropFirst().joined(separator: " ")))
        case "approve": guard let pending = await inbox.latest() else { print("no pending interaction"); continue }; try await pending.response.respond(.decision(parts.count > 1 ? parts[1] : "accept")); await inbox.remove(pending.id)
        case "answer": guard let pending = await inbox.latest(), parts.count > 2 else { print("answer QUESTION_ID VALUE"); continue }; try await pending.response.respond(.answers([parts[1]: [parts[2]]])); await inbox.remove(pending.id)
        case "reconnect": _ = try await client.reconnect(); print("reconnected")
        case "quit", "exit": return
        default: print("unknown command")
        }
    }
}

private func machineLoop(_ client: CodexClient, inbox: InteractionInbox, writer: CLIJSONWriter) async throws {
    while let line = readLine() {
        var id: String?
        do {
            let command = try CodexAppServerCLI.decodeMachineCommand(line)
            id = command.id
            let result = try await executeMachineCommand(command.name, arguments: command.arguments, client: client, inbox: inbox)
            await writer.write(machineRecord(type: "result", fields: ["id": .string(command.id), "result": result]))
            if command.name == "session.close" { return }
        } catch {
            await writer.write(machineErrorRecord(id: id, error: error))
        }
    }
}

private func executeMachineCommand(_ command: String, arguments: JSONValue, client: CodexClient, inbox: InteractionInbox) async throws -> JSONValue {
    func required(_ key: String) throws -> String { guard let value = arguments[key]?.stringValue, !value.isEmpty else { throw CodexError.invalidArgument("\(key) is required") }; return value }
    switch command {
    case "thread.list": let page = try await client.listThreads(.init(cursor: arguments["cursor"]?.stringValue, limit: arguments["limit"]?.intValue)); return ["items": .array(page.items.map(\.raw)), "nextCursor": page.nextCursor.map(JSONValue.string) ?? .null, "backwardsCursor": page.backwardsCursor.map(JSONValue.string) ?? .null]
    case "thread.read": return (try await client.readThread(id: required("threadID"), includeTurns: arguments["includeTurns"]?.boolValue ?? true)).raw
    case "thread.start": return (try await client.startThread(options: .init(model: arguments["model"]?.stringValue, workingDirectory: arguments["workingDirectory"]?.stringValue.map(URL.init(fileURLWithPath:)) ))).raw
    case "thread.fork": return (try await client.forkThread(id: required("threadID"), mode: arguments["mode"]?.stringValue == "lastTurn" ? .lastTurn : .fullHistory)).raw
    case "thread.history": let page = try await client.listTurns(threadID: required("threadID"), cursor: arguments["cursor"]?.stringValue, limit: arguments["limit"]?.intValue, itemView: .full); return ["items": .array(page.items.map(\.raw)), "nextCursor": page.nextCursor.map(JSONValue.string) ?? .null, "backwardsCursor": page.backwardsCursor.map(JSONValue.string) ?? .null]
    case "turn.start": return (try await client.startTurn(threadID: required("threadID"), prompt: required("text"), options: .init(model: arguments["model"]?.stringValue))).raw
    case "turn.steer": return (try await client.steerTurn(threadID: required("threadID"), expectedTurnID: required("turnID"), inputs: [.text(try required("text"))])).raw
    case "turn.interrupt": try await client.interruptTurn(threadID: required("threadID"), turnID: required("turnID")); return ["interrupted": true]
    case "review.start": let target = arguments["baseBranch"]?.stringValue.map { CodexReviewTarget(.baseBranch($0)) } ?? CodexReviewTarget(.uncommitted); return try await client.startReview(threadID: required("threadID"), target: target)
    case "model.list": return ["models": .array(try await client.listModels().map(\.raw))]
    case "file.search": return try await client.startFileSearch(sessionID: arguments["sessionID"]?.stringValue ?? UUID().uuidString, roots: arguments["roots"]?.arrayValue?.compactMap(\.stringValue) ?? [FileManager.default.currentDirectoryPath], query: required("query"))
    case "shell.run": return try await client.runThreadShellCommand(threadID: required("threadID"), command: required("command"))
    case "interaction.respond": guard let pending = await inbox.value(id: try required("requestID")) else { throw CodexError.invalidArgument("unknown requestID") }; if let decision = arguments["decision"]?.stringValue { try await pending.response.respond(.decision(decision)) } else { let answers = arguments["answers"]?.objectValue?.mapValues { $0.arrayValue?.compactMap(\.stringValue) ?? [] } ?? [:]; try await pending.response.respond(.answers(answers)) }; await inbox.remove(pending.id); return ["responded": true]
    case "client.reconnect": return try await client.reconnect()
    case "session.close": await client.close(); return ["closed": true]
    default: throw CodexError.invalidArgument("unknown command \(command)")
    }
}

private func printHumanEvent(_ event: CodexEvent) {
    switch event {
    case .itemDelta(_, _, let method, let value): if let delta = value["delta"]?.stringValue { print("[\(method)] \(delta)", terminator: "") }
    case .serverRequest(let value): print("\n[interaction] \(value.id) \(value.method)")
    case .connection(let state): print("\n[connection] \(state)")
    case .diagnostic(let value): print("\n[diagnostic] \(value)")
    default: break
    }
}
private func printMachineEvent(_ event: CodexEvent, writer: CLIJSONWriter) async {
    switch event {
    case .protocolMessage(let message): await writer.write(machineRecord(type: "protocol", fields: ["direction": "inbound", "message": message]))
    case .connection(let state): await writer.write(machineRecord(type: "lifecycle", fields: ["state": .string(String(describing: state))]))
    case .diagnostic(let value): await writer.write(machineRecord(type: "diagnostic", fields: ["message": .string(String(describing: value))]))
    default: break
    }
}

private func machineRecord(type: String, fields: [String: JSONValue]) -> JSONValue { .object(["schemaVersion": 1, "type": .string(type)].merging(fields) { _, new in new }) }
private func machineErrorRecord(id: String?, error: Error) -> JSONValue {
    machineRecord(type: "error", fields: [
        "id": id.map(JSONValue.string) ?? .null,
        "error": ["code": .string(cliErrorCode(error)), "message": .string(error.localizedDescription)],
    ])
}
private func cliErrorCode(_ error: Error) -> String {
    switch error {
    case is ValidationError: "invalid_arguments"
    case is CodexRemoteError: "remote_error"
    case is CodexError: "codex_error"
    default: "command_failed"
    }
}
private func emitMachineError(id: String?, code: String, message: String) {
    let value = machineRecord(type: "error", fields: [
        "id": id.map(JSONValue.string) ?? .null,
        "error": ["code": .string(code), "message": .string(message)],
    ])
    guard let data = try? value.encoded(sortedKeys: true) else { return }
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([0x0A]))
}
private func emitOneShot(_ json: Bool, _ result: JSONValue, text: String? = nil) {
    if json { let data = try? machineRecord(type: "result", fields: ["result": result]).encoded(sortedKeys: true); if let data { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([0x0A])) } }
    else { print(text ?? String(decoding: (try? result.encoded(sortedKeys: true)) ?? Data(), as: UTF8.self)) }
}
private func pairingJSON(_ result: CodexRemotePairingResult) -> JSONValue { ["clientID": .string(result.clientID), "environmentID": result.environmentID.map(JSONValue.string) ?? .null, "response": result.raw] }
private func diagnosticJSON(_ value: CodexRemoteDiagnostic) -> JSONValue { ["code": .string(value.code), "message": .string(value.message), "statusCode": value.statusCode.map { .number(Decimal($0)) } ?? .null, "entryIndex": value.entryIndex.map { .number(Decimal($0)) } ?? .null, "path": value.path.map(JSONValue.string) ?? .null, "raw": value.raw ?? .null, "originalByteCount": value.originalByteCount.map { .number(Decimal($0)) } ?? .null, "rawOmitted": .bool(value.rawOmitted)] }
private func daemonStatusJSON(_ value: CodexDaemonStatus) -> JSONValue { switch value { case .notPrepared: ["status": "notPrepared"]; case .stopped: ["status": "stopped"]; case .running(let version): ["status": "running", "version": version.map(JSONValue.string) ?? .null]; case .unavailable(let message): ["status": "unavailable", "message": .string(message)] } }

private func selectRemoteHost(controller: CodexRemoteController, requested: String?, machineMode: Bool) async throws -> String {
    if let requested, !requested.isEmpty { return requested }
    let online = try await controller.listHosts().hosts.filter { $0.online == true }
    if online.count == 1 { return online[0].id }
    guard !machineMode, isatty(STDIN_FILENO) == 1 else { throw ValidationError("environment ID is required unless exactly one Remote Control environment is online") }
    guard !online.isEmpty else { throw ValidationError("no Remote Control environments are online") }
    for (index, host) in online.enumerated() { print("\(index + 1). \(host.name ?? host.id) [\(host.id)]") }
    print("Host: ", terminator: ""); guard let input = readLine(), let index = Int(input), online.indices.contains(index - 1) else { throw ValidationError("invalid host selection") }
    return online[index - 1].id
}
#else
@main
private enum CodexAppServerCLIUnsupportedPlatform {
    static func main() {}
}
#endif
