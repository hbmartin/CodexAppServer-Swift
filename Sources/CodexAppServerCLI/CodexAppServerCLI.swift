import Foundation
import CodexAppServerKit
#if os(macOS)
import CodexAppServerHost
import CodexAppServerRemoteExperimental

private struct EnvironmentBearer: CodexBearerCredentialProvider {
    let variable: String
    func credential() async throws -> CodexBearerCredential { guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else { throw CodexError.invalidConfiguration("Missing environment variable \(variable)") }; return .init(value: value, kind: .capability) }
}
private struct EnvironmentTunnel: CodexTunnelHeaderProvider {
    let header: String, variable: String
    func headers() async throws -> [String: String] { guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else { throw CodexError.invalidConfiguration("Missing environment variable \(variable)") }; return [header: value] }
}
private struct EnvironmentWHAM: WHAMCredentialProvider {
    let variable: String
    func accountBearer() async throws -> String { guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else { throw CodexError.invalidConfiguration("Missing environment variable \(variable)") }; return value }
}
private actor MemoryGrants: WHAMPairingGrantStore {
    var values: [String: WHAMPairingGrant] = [:]
    init(_ initial: WHAMPairingGrant? = nil) { if let initial { values[initial.hostID] = initial } }
    func grant(for hostID: String) -> WHAMPairingGrant? { values[hostID] }
    func save(_ grant: WHAMPairingGrant) { values[grant.hostID] = grant }
    func remove(hostID: String) { values[hostID] = nil }
}
private actor InteractionInbox {
    private var values: [CodexPendingInteraction] = []
    func append(_ value: CodexPendingInteraction) { values.append(value) }
    func latest() -> CodexPendingInteraction? { values.last }
    func remove(_ id: String) { values.removeAll { $0.id == id } }
}
#endif

@main
struct CodexAppServerCLI {
    static func main() async {
#if os(macOS)
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch { FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1) }
#else
        print("codex-app-server-cli requires macOS")
#endif
    }

#if os(macOS)
    static func run(_ arguments: [String]) async throws {
        let notificationPath = try notificationConfigurationPath(in: arguments)
        let lifecycle = arguments.first.flatMap { ["prepare", "status", "start", "stop", "restart", "version"].contains($0) ? $0 : nil }
        let executable = try CodexCLIResolver().resolve(explicitURL: value("--codex", in: arguments).map { URL(fileURLWithPath: $0) })
        if let lifecycle {
            let controller = CodexDaemonController(executableURL: executable)
            switch lifecycle {
            case "prepare": try await controller.prepareManagedDaemon(); print("managed daemon prepared")
            case "status": print(await controller.status())
            case "start": try await controller.start(); print("started")
            case "stop": try await controller.stop(); print("stopped")
            case "restart": try await controller.restart(); print("restarted")
            default: print(try await controller.cliVersion())
            }
            return
        }
        let notifier = try notificationPath.map { CLINotificationDispatcher(configuration: try .load(path: $0)) }
        let factory = try await makeFactory(arguments, executable: executable)
        let registry = CodexDynamicToolRegistry(tools: [.init(name: "sdk_echo", description: "Echo JSON input", inputSchema: ["type": "object"]) { .text(String(decoding: try $0.encoded(sortedKeys: true), as: UTF8.self)) }])
        let client = CodexClient(transportFactory: factory, dynamicTools: registry)
        _ = try await client.connect()
        let inbox = InteractionInbox()
        let subscription = await client.subscribe(policy: .boundedCoalescingDeltas(1_024))
        let eventTask = Task {
            do {
                for try await event in subscription.events {
                    if case .serverRequest(let request) = event { await inbox.append(request) }
                    if let notifier { await notifier.enqueue(event) }
                    printEvent(event)
                }
            }
            catch { print("event stream ended: \(error.localizedDescription)") }
        }
        var replError: Error?
        do { try await repl(client, inbox: inbox) }
        catch { replError = error }
        eventTask.cancel()
        await eventTask.value
        await client.close()
        if let notifier { await notifier.finish() }
        if let replError { throw replError }
    }

    static func makeFactory(_ arguments: [String], executable: URL) async throws -> CodexTransportFactory {
        if arguments.contains("--daemon") { return CodexHostTransports.managedDaemon(controller: .init(executableURL: executable)) }
        if let alias = value("--ssh-proxy", in: arguments) { return try CodexHostTransports.sshProxy(host: .alias(alias)) }
        if let alias = value("--ssh-forward", in: arguments) {
            guard let local = value("--local-port", in: arguments).flatMap(Int.init), let remote = value("--remote-port", in: arguments).flatMap(Int.init) else { throw CodexError.invalidConfiguration("--ssh-forward requires --local-port and --remote-port") }
            let bearer = value("--app-bearer-env", in: arguments).map(EnvironmentBearer.init)
            return try CodexHostTransports.sshForward(host: .alias(alias), localPort: local, remotePort: remote, bearer: bearer)
        }
        if let address = value("--wss", in: arguments), let url = URL(string: address) {
            guard let bearerEnv = value("--app-bearer-env", in: arguments), let tunnelEnv = value("--tunnel-env", in: arguments), let tunnelHeader = value("--tunnel-header", in: arguments) else { throw CodexError.invalidConfiguration("--wss requires --app-bearer-env, --tunnel-env, and --tunnel-header") }
            return CodexWebSocketTransport.factory(configuration: try .init(wssURL: url, applicationBearer: EnvironmentBearer(variable: bearerEnv), tunnelHeaders: EnvironmentTunnel(header: tunnelHeader, variable: tunnelEnv)))
        }
        if let hostID = value("--relay-host", in: arguments), let accountEnv = value("--account-env", in: arguments), let grantEnv = value("--pairing-grant-env", in: arguments) {
            guard let grant = ProcessInfo.processInfo.environment[grantEnv] else { throw CodexError.invalidConfiguration("Missing pairing grant environment variable") }
            let controller = WHAMController(credentials: EnvironmentWHAM(variable: accountEnv), grantStore: MemoryGrants(.init(hostID: hostID, grant: grant)))
            return await controller.transportFactory(hostID: hostID)
        }
        return CodexHostTransports.isolated(executableURL: executable)
    }

    private static func repl(_ client: CodexClient, inbox: InteractionInbox) async throws {
        var threadID: String?, turnID: String?
        print("connected; type help")
        while true {
            print("codex> ", terminator: ""); guard let line = readLine() else { return }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init); guard let command = parts.first else { continue }
            switch command {
            case "help": print("list | open ID | new [MODEL] | fork [full|lastTurn] | history | say TEXT | steer TEXT | interrupt | review [BRANCH] | models | search QUERY | shell COMMAND | approve [DECISION] | answer QUESTION_ID VALUE | reconnect | quit")
            case "list": for item in try await client.listThreads(.init(limit: 50)).items { print("\(item.id)\t\(item.name ?? "")\t\(item.status ?? "")") }
            case "open": guard parts.count > 1 else { continue }; threadID = (try await client.subscribeThread(id: parts[1])).id; print("opened \(threadID!)")
            case "new": let thread = try await client.startThread(options: .init(model: parts.count > 1 ? parts[1] : nil)); threadID = thread.id; print("created \(thread.id)")
            case "fork": guard let threadID else { continue }; let thread = try await client.forkThread(id: threadID, mode: parts.count > 1 && parts[1] == "lastTurn" ? .lastTurn : .fullHistory); print("forked \(thread.id)")
            case "history": guard let threadID else { continue }; for turn in try await client.listTurns(threadID: threadID, limit: 20, itemView: .full).items { print("\(turn.id) \(turn.status ?? "")") }
            case "say": guard let threadID, parts.count > 1 else { continue }; let turn = try await client.startTurn(threadID: threadID, prompt: parts.dropFirst().joined(separator: " ")); turnID = turn.id; print("turn \(turn.id)")
            case "steer": guard let threadID, let turnID, parts.count > 1 else { continue }; _ = try await client.steerTurn(threadID: threadID, expectedTurnID: turnID, inputs: [.text(parts.dropFirst().joined(separator: " "))])
            case "interrupt": guard let threadID, let turnID else { continue }; try await client.interruptTurn(threadID: threadID, turnID: turnID)
            case "review": guard let threadID else { continue }; let target: CodexReviewTarget = parts.count > 1 ? .init(.baseBranch(parts[1])) : .init(.uncommitted); print(try await client.startReview(threadID: threadID, target: target))
            case "models": for model in try await client.listModels() { print(model.id) }
            case "search": guard parts.count > 1 else { continue }; print(try await client.startFileSearch(sessionID: UUID().uuidString, roots: [FileManager.default.currentDirectoryPath], query: parts.dropFirst().joined(separator: " ")))
            case "shell": guard let threadID, parts.count > 1 else { continue }; print(try await client.runThreadShellCommand(threadID: threadID, command: parts.dropFirst().joined(separator: " ")))
            case "approve":
                guard let pending = await inbox.latest() else { print("no pending interaction"); continue }
                try await pending.response.respond(.decision(parts.count > 1 ? parts[1] : "accept")); await inbox.remove(pending.id)
            case "answer":
                guard let pending = await inbox.latest(), parts.count > 2 else { print("answer QUESTION_ID VALUE"); continue }
                try await pending.response.respond(.answers([parts[1]: [parts[2]]])); await inbox.remove(pending.id)
            case "reconnect": _ = try await client.reconnect(); print("reconnected")
            case "quit", "exit": return
            default: print("unknown command")
            }
        }
    }

    static func printEvent(_ event: CodexEvent) {
        switch event {
        case .itemDelta(_, _, let method, let value): if let delta = value["delta"]?.stringValue { print("[\(method)] \(delta)", terminator: "") }
        case .serverRequest(let value): print("\n[interaction] \(value.id) \(value.method)")
        case .connection(let state): print("\n[connection] \(state)")
        case .diagnostic(let value): print("\n[diagnostic] \(value)")
        default: break
        }
    }

    static func value(_ flag: String, in arguments: [String]) -> String? { guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }; return arguments[index + 1] }

    static func notificationConfigurationPath(in arguments: [String]) throws -> String? {
        let matches = arguments.indices.filter { arguments[$0] == "--notify-config" }
        guard matches.count <= 1 else { throw CodexError.invalidConfiguration("--notify-config may be supplied only once") }
        guard let index = matches.first else { return nil }
        if let first = arguments.first, ["prepare", "status", "start", "stop", "restart", "version"].contains(first) {
            throw CodexError.invalidConfiguration("--notify-config is available only in interactive mode")
        }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty, !arguments[index + 1].hasPrefix("--") else { throw CodexError.invalidConfiguration("--notify-config requires a file path") }
        return arguments[index + 1]
    }
#endif
}
