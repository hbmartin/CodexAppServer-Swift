import Foundation

public struct CodexBearerCredential: Sendable, Equatable {
    public enum Kind: Sendable { case capability, signed }
    public var value: String
    public var kind: Kind
    public init(value: String, kind: Kind) { self.value = value; self.kind = kind }
}

public protocol CodexBearerCredentialProvider: Sendable {
    func credential() async throws -> CodexBearerCredential
}
public protocol CodexTunnelHeaderProvider: Sendable {
    /// Headers establishing the tunnel/private-network identity. Must not contain Authorization.
    func headers() async throws -> [String: String]
}

public struct CodexWebSocketConfiguration: Sendable {
    public enum Security: Sendable { case dualAuthenticatedWSS, trustedLoopback }
    public var url: URL
    public var security: Security
    public var applicationBearer: (any CodexBearerCredentialProvider)?
    public var tunnelHeaders: (any CodexTunnelHeaderProvider)?
    public var maximumFrameBytes: Int
    public var urlSessionConfiguration: URLSessionConfiguration

    public init(wssURL: URL, applicationBearer: any CodexBearerCredentialProvider, tunnelHeaders: any CodexTunnelHeaderProvider, maximumFrameBytes: Int = 32 * 1_024 * 1_024, urlSessionConfiguration: URLSessionConfiguration = .ephemeral) throws {
        guard wssURL.scheme?.lowercased() == "wss" else { throw CodexError.invalidConfiguration("Remote WebSocket URLs must use wss") }
        self.url = wssURL; self.security = .dualAuthenticatedWSS; self.applicationBearer = applicationBearer; self.tunnelHeaders = tunnelHeaders; self.maximumFrameBytes = maximumFrameBytes; self.urlSessionConfiguration = urlSessionConfiguration
    }

    public static func trustedLoopback(url: URL, applicationBearer: (any CodexBearerCredentialProvider)? = nil, maximumFrameBytes: Int = 32 * 1_024 * 1_024) throws -> Self {
        guard ["127.0.0.1", "::1", "localhost"].contains(url.host?.lowercased() ?? "") else { throw CodexError.invalidConfiguration("Plain WebSocket is restricted to loopback") }
        var value = try Self(wssURL: URL(string: "wss://localhost")!, applicationBearer: EmptyBearer(), tunnelHeaders: EmptyTunnel())
        value.url = url; value.security = .trustedLoopback; value.applicationBearer = applicationBearer; value.tunnelHeaders = nil; value.maximumFrameBytes = maximumFrameBytes
        return value
    }
}

private struct EmptyBearer: CodexBearerCredentialProvider { func credential() async throws -> CodexBearerCredential { .init(value: "", kind: .capability) } }
private struct EmptyTunnel: CodexTunnelHeaderProvider { func headers() async throws -> [String: String] { [:] } }

public enum CodexWebSocketTransport {
    public static func factory(configuration: CodexWebSocketConfiguration) -> CodexTransportFactory {
        .init { WebSocketConnection(configuration: configuration) }
    }
}

private actor WebSocketConnection: CodexTransport {
    nonisolated let incomingFrames: AsyncThrowingStream<Data, Error>
    nonisolated let diagnostics: AsyncStream<CodexTransportDiagnostic>
    private let frameContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let diagnosticContinuation: AsyncStream<CodexTransportDiagnostic>.Continuation
    private let configuration: CodexWebSocketConfiguration
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var started = false

    init(configuration: CodexWebSocketConfiguration) {
        self.configuration = configuration
        let frames = AsyncThrowingStream<Data, Error>.makeStream(); incomingFrames = frames.stream; frameContinuation = frames.continuation
        let diagnostics = AsyncStream<CodexTransportDiagnostic>.makeStream(); self.diagnostics = diagnostics.stream; diagnosticContinuation = diagnostics.continuation
    }

    func start() async throws {
        guard !started else { throw CodexError.alreadyConnected }
        var request = URLRequest(url: configuration.url)
        switch configuration.security {
        case .dualAuthenticatedWSS:
            guard let bearerProvider = configuration.applicationBearer, let tunnelProvider = configuration.tunnelHeaders else { throw CodexError.invalidConfiguration("WSS requires application bearer and tunnel identity providers") }
            let bearer = try await bearerProvider.credential(), headers = try await tunnelProvider.headers()
            guard !bearer.value.isEmpty, !headers.isEmpty else { throw CodexError.invalidConfiguration("Both WSS security layers must be non-empty") }
            guard !headers.keys.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) else { throw CodexError.invalidConfiguration("Tunnel headers must not replace the application Authorization bearer") }
            request.setValue("Bearer \(bearer.value)", forHTTPHeaderField: "Authorization")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        case .trustedLoopback:
            if let bearerProvider = configuration.applicationBearer {
                let bearer = try await bearerProvider.credential(); if !bearer.value.isEmpty { request.setValue("Bearer \(bearer.value)", forHTTPHeaderField: "Authorization") }
            }
        }
        let session = URLSession(configuration: configuration.urlSessionConfiguration)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = configuration.maximumFrameBytes
        self.session = session; self.socket = socket; started = true; socket.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
    }

    func send(frame: Data) async throws {
        guard let socket, started else { throw CodexError.disconnected }
        guard frame.count <= configuration.maximumFrameBytes else { throw CodexError.frameTooLarge(actual: frame.count, limit: configuration.maximumFrameBytes) }
        guard let text = String(data: frame, encoding: .utf8) else { throw CodexError.malformedFrame("outbound frame is not UTF-8") }
        try await socket.send(.string(text))
    }

    func close() async {
        guard started else { return }; started = false
        receiveTask?.cancel(); receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        frameContinuation.finish(); diagnosticContinuation.finish()
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data
                switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                guard data.count <= configuration.maximumFrameBytes else { throw CodexError.frameTooLarge(actual: data.count, limit: configuration.maximumFrameBytes) }
                frameContinuation.yield(data)
            }
        } catch {
            if !Task.isCancelled { frameContinuation.finish(throwing: error) }
        }
    }
}
