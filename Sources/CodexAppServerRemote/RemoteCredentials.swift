import Foundation
import CodexAppServerKit

public struct CodexRemoteEnvironmentCredentialProvider: CodexRemoteCredentialProvider {
    public var tokenVariable: String
    public var accountIDVariable: String
    private let environment: [String: String]

    public init(tokenVariable: String, accountIDVariable: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.tokenVariable = tokenVariable
        self.accountIDVariable = accountIDVariable
        self.environment = environment
    }

    public func credential() async throws -> CodexRemoteCredential {
        guard let token = environment[tokenVariable], !token.isEmpty else {
            throw CodexRemoteError.invalidConfiguration("missing environment variable \(tokenVariable)")
        }
        guard let accountID = environment[accountIDVariable], !accountID.isEmpty else {
            throw CodexRemoteError.invalidConfiguration("missing environment variable \(accountIDVariable)")
        }
        return try .init(accountID: accountID, accessToken: .init(token))
    }
}

#if os(macOS)
public struct CodexRemoteCodexLoginCredentialProvider: CodexRemoteCredentialProvider {
    private let environmentVariables: (token: String, account: String)?
    private let environment: [String: String]
    private let authFileURL: URL?

    public init(tokenEnvironmentVariable: String? = nil, accountIDEnvironmentVariable: String? = nil, authFileURL: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard (tokenEnvironmentVariable == nil) == (accountIDEnvironmentVariable == nil) else {
            throw CodexRemoteError.invalidConfiguration("token and account-ID environment variables must be supplied together")
        }
        environmentVariables = tokenEnvironmentVariable.map { ($0, accountIDEnvironmentVariable!) }
        self.environment = environment
        self.authFileURL = authFileURL
    }

    public func credential() async throws -> CodexRemoteCredential {
        if let (tokenVariable, accountVariable) = environmentVariables {
            return try await CodexRemoteEnvironmentCredentialProvider(
                tokenVariable: tokenVariable,
                accountIDVariable: accountVariable,
                environment: environment
            ).credential()
        }

        let fileURL: URL
        if let authFileURL {
            fileURL = authFileURL
        } else if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            fileURL = URL(fileURLWithPath: codexHome, isDirectory: true).appending(path: "auth.json")
        } else {
            fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".codex", directoryHint: .isDirectory)
                .appending(path: "auth.json")
        }

        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw CodexRemoteError.invalidConfiguration("could not read Codex login at \(fileURL.path)") }

        let raw: JSONValue
        do { raw = try .decode(data) }
        catch { throw CodexRemoteError.invalidConfiguration("Codex login file is not valid JSON") }

        let tokens = raw["tokens"]
        let token = tokens?["access_token"]?.stringValue
            ?? tokens?["accessToken"]?.stringValue
            ?? raw["access_token"]?.stringValue
        guard let token, !token.isEmpty else {
            throw CodexRemoteError.invalidConfiguration("Codex login has no account access token")
        }
        let accountID = tokens?["account_id"]?.stringValue
            ?? tokens?["accountId"]?.stringValue
            ?? raw["account_id"]?.stringValue
        guard let accountID, !accountID.isEmpty else {
            throw CodexRemoteError.invalidConfiguration("Codex login has no account ID")
        }
        return try .init(accountID: accountID, accessToken: .init(token))
    }
}
#endif
