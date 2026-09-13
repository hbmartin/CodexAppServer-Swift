import Foundation

public struct CodexTransportDiagnostic: Sendable, Equatable {
    public enum Level: Sendable { case debug, info, warning, error }
    public var level: Level
    public var message: String
    public init(level: Level, message: String) { self.level = level; self.message = message }
}

/// One connected byte-framed channel. A factory creates a fresh channel for every reconnect generation.
public protocol CodexTransport: Sendable {
    var incomingFrames: AsyncThrowingStream<Data, Error> { get }
    var diagnostics: AsyncStream<CodexTransportDiagnostic> { get }
    func start() async throws
    func send(frame: Data) async throws
    func close() async
}

public struct CodexTransportFactory: Sendable {
    public typealias Builder = @Sendable () async throws -> any CodexTransport
    private let builder: Builder
    public init(_ builder: @escaping Builder) { self.builder = builder }
    public func makeTransport() async throws -> any CodexTransport { try await builder() }
}

public enum CodexBufferingPolicy: Sendable, Equatable {
    case boundedFailing(Int), boundedCoalescingDeltas(Int), unbounded
    public static let `default`: Self = .boundedFailing(1_024)
}

/// A failure of an individual event subscription; the transport remains connected.
public enum CodexSubscriptionError: Error, Sendable, Equatable, LocalizedError {
    case bufferOverflow
    public var errorDescription: String? { "subscriber buffer overflow" }
}

public struct CodexSubscription: Sendable {
    public let id: UUID
    public let events: AsyncThrowingStream<CodexEvent, Error>
    private let cancelClosure: @Sendable () -> Void
    init(id: UUID, events: AsyncThrowingStream<CodexEvent, Error>, cancel: @escaping @Sendable () -> Void) { self.id = id; self.events = events; self.cancelClosure = cancel }
    public func cancel() { cancelClosure() }
}
