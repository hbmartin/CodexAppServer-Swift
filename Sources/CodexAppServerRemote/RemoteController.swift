import Foundation
import CodexAppServerKit

enum CodexRemotePath {
    static let pair = "wham/remote/control/client/pair"
    static let hosts = "codex/remote/control/environments"
    static let socket = "codex/remote/control/client"
    static func environment(_ id: String) -> String { "codex/remote/control/environments/\(pathComponent(id))" }
    static func client(_ id: String) -> String { "wham/remote/control/clients/\(pathComponent(id))" }

    private static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public actor CodexRemoteController {
    public let configuration: CodexRemoteConfiguration
    private let credentials: any CodexRemoteCredentialProvider
    private let authorizationProvider: (any CodexRemoteClientAuthorizationProvider)?
    private let session: URLSession

    public init(
        credentials: any CodexRemoteCredentialProvider,
        authorizationProvider: (any CodexRemoteClientAuthorizationProvider)? = nil,
        configuration: CodexRemoteConfiguration = .official,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.credentials = credentials
        self.authorizationProvider = authorizationProvider
        self.configuration = configuration
        let copied = sessionConfiguration.copy() as? URLSessionConfiguration ?? sessionConfiguration
        copied.timeoutIntervalForRequest = configuration.requestTimeout
        session = URLSession(configuration: copied)
    }

    #if os(macOS)
    public static func codexLogin(
        authorizationProvider: (any CodexRemoteClientAuthorizationProvider)? = nil,
        configuration: CodexRemoteConfiguration = .official,
        tokenEnvironmentVariable: String? = nil,
        accountIDEnvironmentVariable: String? = nil,
        authFileURL: URL? = nil
    ) throws -> CodexRemoteController {
        let provider = try CodexRemoteCodexLoginCredentialProvider(
            tokenEnvironmentVariable: tokenEnvironmentVariable,
            accountIDEnvironmentVariable: accountIDEnvironmentVariable,
            authFileURL: authFileURL
        )
        return .init(credentials: provider, authorizationProvider: authorizationProvider, configuration: configuration)
    }
    #endif

    /// Claims a host's manual pairing code for the enrolled controller client.
    ///
    /// This mutation is deliberately never retried because a transport failure can leave its
    /// outcome ambiguous.
    @discardableResult
    public func pair(_ code: CodexRemotePairingCode) async throws -> CodexRemotePairingResult {
        let credential = try await credentials.credential()
        let authorization = try await validatedAuthorization(for: credential, forceRefresh: false)
        let raw: JSONValue
        do {
            raw = try await request(
                path: CodexRemotePath.pair,
                method: "POST",
                body: ["client_id": .string(authorization.clientID), "manual_pairing_code": .string(code.value)],
                safeRead: false,
                credential: credential
            ).0
        } catch let error as CodexRemoteError { throw error }
        catch { throw CodexRemoteError.ambiguousMutation(operation: "pair", message: error.localizedDescription) }
        return .init(clientID: authorization.clientID, raw: raw)
    }

    /// Lists every Remote Control environment visible to the signed-in account, following the
    /// service cursor until completion.
    public func listHosts() async throws -> CodexRemoteHostListing {
        var cursor: String?
        var seenCursors: Set<String> = []
        var entries: [JSONValue] = []
        var pages: [JSONValue] = []
        var diagnostics: [CodexRemoteDiagnostic] = []

        for pageIndex in 0..<configuration.maximumHostPages {
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            let raw = try await request(path: CodexRemotePath.hosts, query: query, method: "GET", body: nil, safeRead: true).0
            pages.append(raw)
            guard let pageEntries = raw["items"]?.arrayValue else {
                throw CodexRemoteError.malformedResponse("environment page \(pageIndex + 1) has no items array")
            }
            entries.append(contentsOf: pageEntries)
            guard let next = raw["cursor"]?.stringValue, !next.isEmpty else { cursor = nil; break }
            guard seenCursors.insert(next).inserted else {
                throw CodexRemoteError.malformedResponse("environment pagination repeated cursor \(next)")
            }
            cursor = next
            if pageIndex + 1 == configuration.maximumHostPages {
                throw CodexRemoteError.malformedResponse("environment pagination exceeded \(configuration.maximumHostPages) pages")
            }
        }

        var hosts: [CodexRemoteHost] = []
        hosts.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            do { hosts.append(try .init(raw: entry)) }
            catch {
                diagnostics.append(makeDiagnostic(code: "invalid_host", message: error.localizedDescription, entryIndex: index, raw: entry))
            }
        }
        return .init(hosts: hosts, diagnostics: diagnostics, raw: ["items": .array(entries), "pages": .array(pages)])
    }

    /// Removes a Remote Control environment from the account. This is an account mutation and is
    /// never retried.
    public func removeEnvironment(id: String) async throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexRemoteError.invalidConfiguration("environment ID must not be empty")
        }
        do {
            _ = try await request(path: CodexRemotePath.environment(id), method: "DELETE", body: nil, safeRead: false, acceptedStatusCodes: [404])
        } catch let error as CodexRemoteError { throw error }
        catch { throw CodexRemoteError.ambiguousMutation(operation: "remove environment", message: error.localizedDescription) }
    }

    /// Revokes this enrolled controller client. Future pairing and connections require a new
    /// enrollment and device key.
    public func revokeClient() async throws {
        let credential = try await credentials.credential()
        let authorization = try await validatedAuthorization(for: credential, forceRefresh: false)
        do {
            _ = try await request(
                path: CodexRemotePath.client(authorization.clientID),
                method: "DELETE",
                body: nil,
                safeRead: false,
                acceptedStatusCodes: [404],
                credential: credential
            )
        } catch let error as CodexRemoteError { throw error }
        catch { throw CodexRemoteError.ambiguousMutation(operation: "revoke client", message: error.localizedDescription) }
    }

    public func transportFactory(environmentID: String) -> CodexTransportFactory {
        let credentials = self.credentials
        let authorizationProvider = self.authorizationProvider
        let configuration = self.configuration
        return .init {
            guard !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodexRemoteError.invalidConfiguration("environment ID must not be empty")
            }
            guard let authorizationProvider else {
                throw CodexRemoteError.authorizationRequired("provide a CodexRemoteClientAuthorizationProvider before connecting")
            }
            let credential = try await credentials.credential()
            var authorization = try await authorizationProvider.authorization(for: credential, forceRefresh: false)
            if authorization.isExpired() {
                authorization = try await authorizationProvider.authorization(for: credential, forceRefresh: true)
            }
            try Self.validate(authorization: authorization, credential: credential)
            guard !authorization.isExpired() else { throw CodexRemoteError.authorizationExpired }
            return CodexRemoteConnection(
                environmentID: environmentID,
                credential: credential,
                authorization: authorization,
                authorizationProvider: authorizationProvider,
                configuration: configuration
            )
        }
    }

    public func connect(
        environmentID: String,
        clientConfiguration: CodexClientConfiguration = .init(),
        dynamicTools: CodexDynamicToolRegistry = .init()
    ) async throws -> CodexRemoteSession {
        let client = CodexClient(
            transportFactory: transportFactory(environmentID: environmentID),
            configuration: clientConfiguration,
            dynamicTools: dynamicTools
        )
        do { _ = try await client.connect() }
        catch { await client.close(); throw error }
        return CodexRemoteSession(environmentID: environmentID, client: client)
    }

    private func validatedAuthorization(for credential: CodexRemoteCredential, forceRefresh: Bool) async throws -> CodexRemoteClientAuthorization {
        guard let authorizationProvider else {
            throw CodexRemoteError.authorizationRequired("pairing and connections require controller enrollment, a client session, and device-key signing")
        }
        var authorization = try await authorizationProvider.authorization(for: credential, forceRefresh: forceRefresh)
        if !forceRefresh, authorization.isExpired() {
            authorization = try await authorizationProvider.authorization(for: credential, forceRefresh: true)
        }
        try Self.validate(authorization: authorization, credential: credential)
        guard !authorization.isExpired() else { throw CodexRemoteError.authorizationExpired }
        return authorization
    }

    private static func validate(authorization: CodexRemoteClientAuthorization, credential: CodexRemoteCredential) throws {
        guard authorization.accountID == credential.accountID else {
            throw CodexRemoteError.authorizationAccountMismatch(expected: credential.accountID, received: authorization.accountID)
        }
        if authorization.requiresDeviceKeyProof,
           authorization.scopes != [CodexRemoteClientAuthorization.controllerWebSocketScope] {
            throw CodexRemoteError.invalidConfiguration("controller authorization must contain exactly the Remote Control WebSocket scope")
        }
        if authorization.requiresDeviceKeyProof {
            guard authorization.accountUserID?.isEmpty == false else {
                throw CodexRemoteError.invalidConfiguration("device-bound controller authorization requires an account user ID")
            }
            guard authorization.expiresAt != nil else {
                throw CodexRemoteError.invalidConfiguration("device-bound controller authorization requires an expiration")
            }
        }
    }

    private func request(
        path: String,
        query: [URLQueryItem] = [],
        method: String,
        body: JSONValue?,
        safeRead: Bool,
        acceptedStatusCodes: Set<Int> = [],
        credential fixedCredential: CodexRemoteCredential? = nil
    ) async throws -> (JSONValue, CodexRemoteCredential) {
        let attempts = safeRead ? max(1, configuration.maximumReadAttempts) : 1
        var lastError: Error?
        var retriedUnauthorized = false
        for attempt in 1...attempts {
            try Task.checkCancellation()
            let credential: CodexRemoteCredential
            if let fixedCredential { credential = fixedCredential }
            else { credential = try await credentials.credential() }
            var request = URLRequest(url: try endpoint(path: path, query: query), timeoutInterval: configuration.requestTimeout)
            request.httpMethod = method
            request.setValue("Bearer \(credential.accessToken.unsafeRawValue)", forHTTPHeaderField: "Authorization")
            request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try body.encoded()
            }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw CodexRemoteError.malformedResponse("response is not HTTP")
                }
                if (200..<300).contains(http.statusCode) || acceptedStatusCodes.contains(http.statusCode) {
                    if data.isEmpty { return (.object([:]), credential) }
                    do { return (try .decode(data), credential) }
                    catch {
                        if safeRead { throw CodexRemoteError.malformedResponse("response body is not valid JSON") }
                        throw CodexRemoteError.ambiguousMutation(operation: method, message: "success response was not valid JSON")
                    }
                }
                let diagnostic = responseDiagnostic(status: http.statusCode, data: data)
                let error = CodexRemoteError.http(statusCode: http.statusCode, message: diagnostic.message, diagnostic: diagnostic)
                if safeRead, http.statusCode == 401, !retriedUnauthorized, attempt < attempts {
                    retriedUnauthorized = true
                    lastError = error
                    continue
                }
                if safeRead, shouldRetry(status: http.statusCode), attempt < attempts {
                    lastError = error
                    try await retryDelay(attempt: attempt, response: http)
                    continue
                }
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CodexRemoteError {
                throw error
            } catch {
                if safeRead, attempt < attempts {
                    lastError = error
                    try await retryDelay(attempt: attempt, response: nil)
                    continue
                }
                if safeRead { throw error }
                throw CodexRemoteError.ambiguousMutation(operation: method, message: error.localizedDescription)
            }
        }
        throw lastError ?? CodexRemoteError.malformedResponse("request attempts exhausted")
    }

    private func endpoint(path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw CodexRemoteError.invalidConfiguration("could not parse remote base URL")
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, relativePath].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw CodexRemoteError.invalidConfiguration("could not construct Remote Control URL")
        }
        return url
    }

    private func shouldRetry(status: Int) -> Bool { status == 408 || status == 429 || (500...599).contains(status) }

    private func retryDelay(attempt: Int, response: HTTPURLResponse?) async throws {
        let retryAfter = response?.value(forHTTPHeaderField: "Retry-After")
            .flatMap(Double.init)
            .map { min(max($0, 0), 5) }
        let seconds = retryAfter ?? min(0.25 * pow(2, Double(attempt - 1)), 2)
        try await Task.sleep(for: .seconds(seconds))
    }

    private func responseDiagnostic(status: Int, data: Data) -> CodexRemoteDiagnostic {
        let raw = try? JSONValue.decode(data)
        let message = raw?["detail"]?.stringValue
            ?? raw?["message"]?.stringValue
            ?? raw?["error"]?.stringValue
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        return makeDiagnostic(code: "http_error", message: message, statusCode: status, raw: raw, data: data)
    }

    private func makeDiagnostic(
        code: String,
        message: String,
        statusCode: Int? = nil,
        entryIndex: Int? = nil,
        raw: JSONValue? = nil,
        data: Data? = nil
    ) -> CodexRemoteDiagnostic {
        switch configuration.diagnosticMode {
        case .redacted:
            return .init(code: code, message: message, statusCode: statusCode, entryIndex: entryIndex, rawOmitted: raw != nil || data != nil)
        case .full(let maximumBytes):
            let count = data?.count ?? (raw.flatMap { try? $0.encoded().count } ?? 0)
            guard count <= maximumBytes else {
                return .init(code: code, message: message, statusCode: statusCode, entryIndex: entryIndex, originalByteCount: count, rawOmitted: true)
            }
            return .init(code: code, message: message, statusCode: statusCode, entryIndex: entryIndex, raw: raw, originalByteCount: count == 0 ? nil : count)
        }
    }
}

public actor CodexRemoteSession {
    public let environmentID: String
    public nonisolated let client: CodexClient

    init(environmentID: String, client: CodexClient) {
        self.environmentID = environmentID
        self.client = client
    }

    public func close() async { await client.close() }
}
