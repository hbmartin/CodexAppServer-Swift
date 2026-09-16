import Foundation
import CodexAppServerKit

public struct CodexRemoteEnvironmentCredentialProvider: CodexRemoteCredentialProvider, CustomReflectable {
    public let tokenVariable: String
    public let accountIDVariable: String
    private let token: CodexRemoteSensitiveValue?
    private let accountID: String?

    public init(tokenVariable: String, accountIDVariable: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.tokenVariable = tokenVariable
        self.accountIDVariable = accountIDVariable
        token = environment[tokenVariable].map(CodexRemoteSensitiveValue.init)
        accountID = environment[accountIDVariable]
    }

    public func credential() async throws -> CodexRemoteCredential {
        guard let token, !token.unsafeRawValue.isEmpty else {
            throw CodexRemoteError.invalidConfiguration("missing environment variable \(tokenVariable)")
        }
        guard let accountID, !accountID.isEmpty else {
            throw CodexRemoteError.invalidConfiguration("missing environment variable \(accountIDVariable)")
        }
        return try .init(accountID: accountID, accessToken: token)
    }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "tokenVariable": tokenVariable,
            "accountIDVariable": accountIDVariable,
            "credential": "<redacted>",
        ], displayStyle: .struct)
    }
}

#if os(macOS)
public struct CodexRemoteCodexLoginCredentialProvider: CodexRemoteCredentialProvider, CustomReflectable {
    private let environmentVariables: (token: String, account: String)?
    private let environmentToken: CodexRemoteSensitiveValue?
    private let environmentAccountID: String?
    private let codexHome: String?
    private let authFileURL: URL?

    public init(tokenEnvironmentVariable: String? = nil, accountIDEnvironmentVariable: String? = nil, authFileURL: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard (tokenEnvironmentVariable == nil) == (accountIDEnvironmentVariable == nil) else {
            throw CodexRemoteError.invalidConfiguration("token and account-ID environment variables must be supplied together")
        }
        environmentVariables = tokenEnvironmentVariable.map { ($0, accountIDEnvironmentVariable!) }
        environmentToken = tokenEnvironmentVariable.flatMap { environment[$0] }.map(CodexRemoteSensitiveValue.init)
        environmentAccountID = accountIDEnvironmentVariable.flatMap { environment[$0] }
        codexHome = environment["CODEX_HOME"]
        self.authFileURL = authFileURL
    }

    public func credential() async throws -> CodexRemoteCredential {
        if let (tokenVariable, accountVariable) = environmentVariables {
            guard let environmentToken, !environmentToken.unsafeRawValue.isEmpty else {
                throw CodexRemoteError.invalidConfiguration("missing environment variable \(tokenVariable)")
            }
            guard let environmentAccountID, !environmentAccountID.isEmpty else {
                throw CodexRemoteError.invalidConfiguration("missing environment variable \(accountVariable)")
            }
            return try .init(accountID: environmentAccountID, accessToken: environmentToken)
        }

        let fileURL: URL
        if let authFileURL {
            fileURL = authFileURL
        } else if let codexHome, !codexHome.isEmpty {
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

    public var customMirror: Mirror {
        Mirror(self, children: [
            "source": environmentVariables == nil ? "Codex login file" : "environment variables",
            "credential": "<redacted>",
        ], displayStyle: .struct)
    }
}
#endif
