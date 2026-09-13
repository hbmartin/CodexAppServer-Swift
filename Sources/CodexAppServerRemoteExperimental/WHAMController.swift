import Foundation
import CodexAppServerKit

/// Unsupported private-service surface. It can break independently of the SDK's 0.2.x compatibility promise.
public protocol WHAMCredentialProvider: Sendable { func accountBearer() async throws -> String }
public protocol WHAMPairingGrantStore: Sendable {
    func grant(for hostID: String) async throws -> WHAMPairingGrant?
    func save(_ grant: WHAMPairingGrant) async throws
    func remove(hostID: String) async throws
}

public struct WHAMPairingGrant: Codable, Sendable, Equatable, Identifiable {
    public var hostID: String
    public var environmentID: String?
    public var grant: String
    public var id: String { hostID }
    public init(hostID: String, environmentID: String? = nil, grant: String) { self.hostID = hostID; self.environmentID = environmentID; self.grant = grant }
}

public struct WHAMHost: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String?
    public var online: Bool?
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw; id = raw["serverId"]?.stringValue ?? raw["hostId"]?.stringValue ?? raw["id"]?.stringValue ?? ""; name = raw["name"]?.stringValue; online = raw["online"]?.boolValue }
}

public struct WHAMEndpoints: Sendable {
    public var baseURL: URL
    public var claimPath: String
    public var hostsPath: String
    public var revokePath: @Sendable (String) -> String
    public var controllerWebSocketPath: String
    public init(baseURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/remote/control")!, claimPath: String = "controller/pair", hostsPath: String = "controller/servers", revokePath: @escaping @Sendable (String) -> String = { "controller/pairing/\($0)" }, controllerWebSocketPath: String = "controller") {
        self.baseURL = baseURL; self.claimPath = claimPath; self.hostsPath = hostsPath; self.revokePath = revokePath; self.controllerWebSocketPath = controllerWebSocketPath
    }
    func url(path: String) -> URL { baseURL.appending(path: path) }
}

public struct WHAMPairingCode: Sendable, Equatable {
    public var value: String
    public init(_ value: String) throws { let clean = value.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { throw CodexError.invalidConfiguration("Empty pairing code") }; self.value = clean }
    public init(qrPayload: String) throws {
        if let url = URL(string: qrPayload), let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let code = components.queryItems?.first(where: { ["code", "pairing_code", "pairingCode"].contains($0.name) })?.value { try self.init(code); return }
        try self.init(qrPayload)
    }
}

public actor WHAMController {
    public let endpoints: WHAMEndpoints
    private let credentials: any WHAMCredentialProvider
    private let grants: any WHAMPairingGrantStore
    private let session: URLSession
    public init(credentials: any WHAMCredentialProvider, grantStore: any WHAMPairingGrantStore, endpoints: WHAMEndpoints = .init(), sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.credentials = credentials; self.grants = grantStore; self.endpoints = endpoints; self.session = URLSession(configuration: sessionConfiguration)
    }

    @discardableResult
    public func claim(_ code: WHAMPairingCode) async throws -> WHAMPairingGrant {
        let result = try await request(path: endpoints.claimPath, method: "POST", body: ["pairing_code": .string(code.value), "protocol_version": "2"])
        guard let hostID = result["serverId"]?.stringValue ?? result["hostId"]?.stringValue, let value = result["pairingGrant"]?.stringValue ?? result["grant"]?.stringValue else { throw CodexError.missingField("serverId/pairingGrant") }
        let grant = WHAMPairingGrant(hostID: hostID, environmentID: result["environmentId"]?.stringValue, grant: value); try await grants.save(grant); return grant
    }
    public func listPairedHosts() async throws -> [WHAMHost] {
        let result = try await request(path: endpoints.hostsPath, method: "GET", body: nil)
        return (result["servers"]?.arrayValue ?? result["data"]?.arrayValue ?? []).map(WHAMHost.init)
    }
    public func revoke(hostID: String) async throws {
        _ = try await request(path: endpoints.revokePath(hostID), method: "DELETE", body: nil); try await grants.remove(hostID: hostID)
    }
    public func transportFactory(hostID: String, maximumOutboundFrames: Int = 1_024, maximumFrameBytes: Int = 32 * 1_024 * 1_024) -> CodexTransportFactory {
        let cursor = WHAMCursor()
        return .init { [credentials, grants, endpoints] in
            guard let grant = try await grants.grant(for: hostID) else { throw CodexError.invalidConfiguration("No pairing grant for host") }
            return WHAMConnection(hostID: hostID, grant: grant, credentials: credentials, endpoints: endpoints, cursor: cursor, maximumOutboundFrames: maximumOutboundFrames, maximumFrameBytes: maximumFrameBytes)
        }
    }

    private func request(path: String, method: String, body: JSONValue?) async throws -> JSONValue {
        var request = URLRequest(url: endpoints.url(path: path)); request.httpMethod = method
        request.setValue("Bearer \(try await credentials.accountBearer())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try body.encoded() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CodexError.transportClosed("WHAM request rejected") }
        return try .decode(data)
    }
}

private actor WHAMCursor {
    private var value: Int64 = 0
    func current() -> Int64 { value }
    func accept(_ candidate: Int64) -> Bool { guard candidate > value else { return false }; value = candidate; return true }
}

private actor WHAMConnection: CodexTransport {
    nonisolated let incomingFrames: AsyncThrowingStream<Data, Error>
    nonisolated let diagnostics: AsyncStream<CodexTransportDiagnostic>
    private let frameContinuation: AsyncThrowingStream<Data, Error>.Continuation, diagnosticContinuation: AsyncStream<CodexTransportDiagnostic>.Continuation
    private let hostID: String, grant: WHAMPairingGrant, credentials: any WHAMCredentialProvider, endpoints: WHAMEndpoints, cursor: WHAMCursor
    private let maximumOutboundFrames: Int, maximumFrameBytes: Int
    private var session: URLSession?, socket: URLSessionWebSocketTask?, tasks: [Task<Void, Never>] = [], outbound = 0, sequence: Int64 = 0
    init(hostID: String, grant: WHAMPairingGrant, credentials: any WHAMCredentialProvider, endpoints: WHAMEndpoints, cursor: WHAMCursor, maximumOutboundFrames: Int, maximumFrameBytes: Int) {
        self.hostID = hostID; self.grant = grant; self.credentials = credentials; self.endpoints = endpoints; self.cursor = cursor; self.maximumOutboundFrames = maximumOutboundFrames; self.maximumFrameBytes = maximumFrameBytes
        let f = AsyncThrowingStream<Data, Error>.makeStream(); incomingFrames = f.stream; frameContinuation = f.continuation
        let d = AsyncStream<CodexTransportDiagnostic>.makeStream(); diagnostics = d.stream; diagnosticContinuation = d.continuation
    }
    func start() async throws {
        var components = URLComponents(url: endpoints.url(path: endpoints.controllerWebSocketPath), resolvingAgainstBaseURL: false)!; components.scheme = components.scheme == "http" ? "ws" : "wss"
        var request = URLRequest(url: components.url!); request.setValue("Bearer \(try await credentials.accountBearer())", forHTTPHeaderField: "Authorization"); request.setValue(grant.grant, forHTTPHeaderField: "x-codex-pairing-grant"); request.setValue(hostID, forHTTPHeaderField: "x-codex-server-id"); request.setValue("2", forHTTPHeaderField: "x-codex-protocol-version"); request.setValue(String(await cursor.current()), forHTTPHeaderField: "x-codex-subscribe-cursor")
        let session = URLSession(configuration: .ephemeral), socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = maximumFrameBytes
        self.session = session; self.socket = socket; socket.resume()
        tasks = [Task { [weak self] in await self?.receiveLoop(socket) }, Task { [weak self] in await self?.pingLoop(socket) }]
    }
    func send(frame: Data) async throws {
        guard let socket else { throw CodexError.disconnected }; guard frame.count <= maximumFrameBytes else { throw CodexError.frameTooLarge(actual: frame.count, limit: maximumFrameBytes) }; guard outbound < maximumOutboundFrames else { throw CodexError.transportClosed("WHAM outbound buffer full") }
        outbound += 1; defer { outbound -= 1 }; sequence += 1
        let payload = try JSONValue.decode(frame)
        let envelope: JSONValue = ["protocol_version": "2", "seq_id": .number(Decimal(sequence)), "server_id": .string(hostID), "payload": payload]
        try await socket.send(.string(String(decoding: try envelope.encoded(), as: UTF8.self)))
    }
    func close() async { for task in tasks { task.cancel() }; tasks.removeAll(); socket?.cancel(with: .goingAway, reason: nil); socket = nil; session?.invalidateAndCancel(); session = nil; frameContinuation.finish(); diagnosticContinuation.finish() }
    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive(); let data: Data
                switch message { case .string(let value): data = Data(value.utf8); case .data(let value): data = value; @unknown default: continue }
                guard data.count <= maximumFrameBytes else { throw CodexError.frameTooLarge(actual: data.count, limit: maximumFrameBytes) }
                let envelope = try JSONValue.decode(data), seq = Int64(envelope["seq_id"]?.intValue ?? 0)
                guard await cursor.accept(seq) else { continue }
                guard let payload = envelope["payload"] else { continue }; frameContinuation.yield(try payload.encoded())
            }
        } catch { if !Task.isCancelled { frameContinuation.finish(throwing: error) } }
    }
    private func pingLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10)); guard !Task.isCancelled else { return }
            socket.sendPing { [weak self] error in
                if let error { Task { await self?.pingFailed(error) } }
            }
        }
    }
    private func pingFailed(_ error: Error) { frameContinuation.finish(throwing: error) }
}

#if os(macOS)
/// Explicit opt-in provider. The SDK never probes this or any other credential file automatically.
public struct WHAMCodexAuthFileCredentialProvider: WHAMCredentialProvider {
    public var fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func accountBearer() async throws -> String {
        let data = try Data(contentsOf: fileURL), json = try JSONValue.decode(data)
        guard let token = json["tokens"]?["access_token"]?.stringValue ?? json["access_token"]?.stringValue else { throw CodexError.missingField("access_token") }
        return token
    }
}
#endif
