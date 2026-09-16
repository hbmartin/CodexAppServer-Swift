import Foundation
import CodexAppServerKit

public struct CodexRemoteSensitiveValue: Sendable, Equatable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let storage: String
    public init(_ value: String) { storage = value }
    public var unsafeRawValue: String { storage }
    public func withUnsafeValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(storage) }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(reflecting: "<redacted>") }
}

public struct CodexRemoteCredential: Sendable, Equatable {
    public var accountID: String
    public var accessToken: CodexRemoteSensitiveValue

    public init(accountID: String, accessToken: CodexRemoteSensitiveValue) throws {
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty else { throw CodexRemoteError.invalidConfiguration("accountID must not be empty") }
        guard !accessToken.unsafeRawValue.isEmpty else { throw CodexRemoteError.invalidConfiguration("access token must not be empty") }
        self.accountID = accountID
        self.accessToken = accessToken
    }
}

public protocol CodexRemoteCredentialProvider: Sendable {
    func credential() async throws -> CodexRemoteCredential
}

/// A short-lived authorization for an enrolled Remote Control controller client.
public struct CodexRemoteClientAuthorization: Sendable, Equatable {
    public static let controllerWebSocketScope = "remote_control_controller_websocket"

    public var accountID: String
    public var accountUserID: String?
    public var clientID: String
    public var sessionToken: CodexRemoteSensitiveValue
    public var expiresAt: Date?
    public var scopes: [String]
    public var requiresDeviceKeyProof: Bool

    public init(
        accountID: String,
        accountUserID: String? = nil,
        clientID: String,
        sessionToken: CodexRemoteSensitiveValue,
        expiresAt: Date? = nil,
        scopes: [String] = [Self.controllerWebSocketScope],
        requiresDeviceKeyProof: Bool = true
    ) throws {
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty else { throw CodexRemoteError.invalidConfiguration("authorization accountID must not be empty") }
        guard !clientID.isEmpty else { throw CodexRemoteError.invalidConfiguration("authorization clientID must not be empty") }
        guard !sessionToken.unsafeRawValue.isEmpty else { throw CodexRemoteError.invalidConfiguration("client session token must not be empty") }
        guard Set(scopes).count == scopes.count, scopes.allSatisfy({ !$0.isEmpty }) else {
            throw CodexRemoteError.invalidConfiguration("authorization scopes must be non-empty and unique")
        }
        self.accountID = accountID
        self.accountUserID = accountUserID
        self.clientID = clientID
        self.sessionToken = sessionToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.requiresDeviceKeyProof = requiresDeviceKeyProof
    }

    public func isExpired(at date: Date = .now, leeway: TimeInterval = 30) -> Bool {
        expiresAt.map { $0.timeIntervalSince(date) <= leeway } ?? false
    }
}

/// Supplies the controller session and signs service challenges with application-owned device keys.
public protocol CodexRemoteClientAuthorizationProvider: Sendable {
    func authorization(for credential: CodexRemoteCredential, forceRefresh: Bool) async throws -> CodexRemoteClientAuthorization
    func response(to challenge: JSONValue, using authorization: CodexRemoteClientAuthorization) async throws -> JSONValue
}

public extension CodexRemoteClientAuthorizationProvider {
    func response(to challenge: JSONValue, using authorization: CodexRemoteClientAuthorization) async throws -> JSONValue {
        throw CodexRemoteError.authorizationRequired("the authorization provider does not implement device-key challenge signing")
    }
}

/// Adapts application-owned enrollment and signing closures to the Remote Control API.
public struct CodexRemoteClosureAuthorizationProvider: CodexRemoteClientAuthorizationProvider {
    public typealias Authorization = @Sendable (CodexRemoteCredential, Bool) async throws -> CodexRemoteClientAuthorization
    public typealias ChallengeResponse = @Sendable (JSONValue, CodexRemoteClientAuthorization) async throws -> JSONValue

    private let authorize: Authorization
    private let challengeResponse: ChallengeResponse?

    public init(authorization: @escaping Authorization, challengeResponse: ChallengeResponse? = nil) {
        authorize = authorization
        self.challengeResponse = challengeResponse
    }

    public func authorization(for credential: CodexRemoteCredential, forceRefresh: Bool) async throws -> CodexRemoteClientAuthorization {
        try await authorize(credential, forceRefresh)
    }

    public func response(to challenge: JSONValue, using authorization: CodexRemoteClientAuthorization) async throws -> JSONValue {
        guard let challengeResponse else {
            throw CodexRemoteError.authorizationRequired("the authorization provider does not implement device-key challenge signing")
        }
        return try await challengeResponse(challenge, authorization)
    }
}

public struct CodexRemotePairingResult: Sendable, Equatable {
    public let clientID: String
    public let environmentID: String?
    public let raw: JSONValue

    public init(clientID: String, raw: JSONValue) {
        self.clientID = clientID
        environmentID = raw["env_id"]?.stringValue
            ?? raw["environment_id"]?.stringValue
            ?? raw["environmentId"]?.stringValue
        self.raw = raw
    }
}

public struct CodexRemoteHost: Sendable, Equatable, Identifiable {
    public let id: String
    public let raw: JSONValue
    public var name: String? {
        raw["display_name"]?.stringValue
            ?? raw["host_name"]?.stringValue
            ?? raw["name"]?.stringValue
    }
    public var hostName: String? { raw["host_name"]?.stringValue ?? raw["name"]?.stringValue }
    public var online: Bool? { raw["online"]?.boolValue }
    public var busy: Bool? { raw["busy"]?.boolValue }
    public var environmentID: String { id }
    public var clientType: String? { raw["client_type"]?.stringValue }
    public var appServerVersion: String? { raw["app_server_version"]?.stringValue }

    public init(raw: JSONValue) throws {
        id = try raw.requireString("env_id", "environment_id", "environmentId", context: "remoteHost")
        self.raw = raw
    }
}

public struct CodexRemoteDiagnostic: Sendable, Equatable {
    public var code: String
    public var message: String
    public var statusCode: Int?
    public var entryIndex: Int?
    public var path: String?
    public var raw: JSONValue?
    public var originalByteCount: Int?
    public var rawOmitted: Bool

    public init(code: String, message: String, statusCode: Int? = nil, entryIndex: Int? = nil, path: String? = nil, raw: JSONValue? = nil, originalByteCount: Int? = nil, rawOmitted: Bool = false) {
        self.code = code
        self.message = message
        self.statusCode = statusCode
        self.entryIndex = entryIndex
        self.path = path
        self.raw = raw
        self.originalByteCount = originalByteCount
        self.rawOmitted = rawOmitted
    }
}

public struct CodexRemoteHostListing: Sendable, Equatable {
    public var hosts: [CodexRemoteHost]
    public var diagnostics: [CodexRemoteDiagnostic]
    public var raw: JSONValue

    public init(hosts: [CodexRemoteHost], diagnostics: [CodexRemoteDiagnostic], raw: JSONValue) {
        self.hosts = hosts
        self.diagnostics = diagnostics
        self.raw = raw
    }
}

public struct CodexRemotePairingCode: Sendable, Equatable {
    public var value: String

    public init(_ value: String) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CodexRemoteError.invalidConfiguration("pairing code must not be empty") }
        self.value = clean
    }

    public init(qrPayload: String) throws {
        if let url = URL(string: qrPayload),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let code = components.queryItems?.first(where: { ["code", "pairing_code", "pairingCode", "manual_pairing_code"].contains($0.name) })?.value {
            try self.init(code)
            return
        }
        try self.init(qrPayload)
    }
}

public enum CodexRemoteDiagnosticMode: Sendable, Equatable {
    case redacted
    case full(maximumBytes: Int)
    public static let full: Self = .full(maximumBytes: 1_048_576)
}

public struct CodexRemoteConfiguration: Sendable, Equatable {
    public let baseURL: URL
    public let requestTimeout: TimeInterval
    public let pingInterval: Duration
    public let maximumFrameBytes: Int
    public let maximumSegmentBytes: Int
    public let maximumOutboundFrames: Int
    public let maximumReadAttempts: Int
    public let maximumHostPages: Int
    public let diagnosticMode: CodexRemoteDiagnosticMode

    public static let official = try! Self()

    public init(
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
        requestTimeout: TimeInterval = 15,
        pingInterval: Duration = .seconds(30),
        maximumFrameBytes: Int = 32 * 1_024 * 1_024,
        maximumSegmentBytes: Int = 100 * 1_024,
        maximumOutboundFrames: Int = 1_024,
        maximumReadAttempts: Int = 3,
        maximumHostPages: Int = 100,
        diagnosticMode: CodexRemoteDiagnosticMode = .redacted
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(), let rawHost = baseURL.host?.lowercased() else {
            throw CodexRemoteError.invalidConfiguration("remote base URL must be absolute")
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        let serviceHost = host == "chatgpt.com" || host == "chatgpt-staging.com"
            || host.hasSuffix(".chatgpt.com") || host.hasSuffix(".chatgpt-staging.com")
        guard (scheme == "https" && (loopback || serviceHost)) || (scheme == "http" && loopback) else {
            throw CodexRemoteError.invalidConfiguration("remote base URL must use HTTPS on a ChatGPT host or HTTP/HTTPS on loopback")
        }
        guard baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw CodexRemoteError.invalidConfiguration("remote base URL must not contain credentials, a query, or a fragment")
        }
        guard requestTimeout > 0, pingInterval > .zero,
              maximumFrameBytes > 0, maximumFrameBytes <= 1_024 * 1_024 * 1_024,
              maximumSegmentBytes > 0, maximumSegmentBytes <= 100 * 1_024,
              maximumSegmentBytes <= maximumFrameBytes, maximumOutboundFrames > 0,
              maximumReadAttempts > 0, maximumHostPages > 0 else {
            throw CodexRemoteError.invalidConfiguration("remote limits must be positive; frames are capped at 1 GiB and wire segments at 100 KiB")
        }
        if case .full(let maximumBytes) = diagnosticMode, maximumBytes <= 0 {
            throw CodexRemoteError.invalidConfiguration("diagnostic byte limit must be positive")
        }
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
        self.pingInterval = pingInterval
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumSegmentBytes = maximumSegmentBytes
        self.maximumOutboundFrames = maximumOutboundFrames
        self.maximumReadAttempts = maximumReadAttempts
        self.maximumHostPages = maximumHostPages
        self.diagnosticMode = diagnosticMode
    }
}

public enum CodexRemoteError: Error, Sendable, Equatable {
    case invalidConfiguration(String)
    case authorizationRequired(String)
    case authorizationAccountMismatch(expected: String, received: String)
    case authorizationExpired
    case http(statusCode: Int, message: String, diagnostic: CodexRemoteDiagnostic?)
    case malformedResponse(String)
    case ambiguousMutation(operation: String, message: String)
    case hostMismatch(expected: String, received: String?)
    case invalidSequence(JSONValue?)
    case sequenceGap(expected: Int64, received: Int64)
    case malformedEnvelope(String)
    case deviceChallengeRejected(String)
    case closed
}

extension CodexRemoteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): "Invalid Remote Control configuration: \(message)"
        case .authorizationRequired(let message): "Remote Control client authorization is required: \(message)"
        case .authorizationAccountMismatch(let expected, let received): "Remote Control authorization is for account \(received), expected \(expected)."
        case .authorizationExpired: "The Remote Control client authorization is expired or too close to expiration."
        case .http(let status, let message, _): "Remote Control HTTP \(status): \(message)"
        case .malformedResponse(let message): "Malformed Remote Control response: \(message)"
        case .ambiguousMutation(let operation, let message): "The \(operation) result is ambiguous: \(message)"
        case .hostMismatch(let expected, let received): "Remote environment mismatch; expected \(expected), received \(received ?? "missing")."
        case .invalidSequence(let value): "Invalid Remote Control sequence: \(String(describing: value))"
        case .sequenceGap(let expected, let received): "Remote Control sequence gap; expected \(expected), received \(received)."
        case .malformedEnvelope(let message): "Malformed Remote Control envelope: \(message)"
        case .deviceChallengeRejected(let message): "Remote Control device-key challenge was rejected: \(message)"
        case .closed: "The Remote Control connection is closed."
        }
    }
}
