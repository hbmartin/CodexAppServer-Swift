import Foundation

public enum CodexMedia {
    public static func dataURL(data: Data, mimeType: String, limit: Int = 10 * 1_024 * 1_024) throws -> String {
        guard data.count <= limit else { throw CodexError.mediaTooLarge(actual: data.count, limit: limit) }
        guard mimeType.contains("/"), !mimeType.contains(";") else { throw CodexError.invalidConfiguration("Invalid MIME type") }
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
    public static func image(data: Data, mimeType: String, detail: String? = nil, limit: Int = 10 * 1_024 * 1_024) throws -> CodexInput { .imageURL(try dataURL(data: data, mimeType: mimeType, limit: limit), detail: detail) }
    public static func audio(data: Data, mimeType: String, limit: Int = 10 * 1_024 * 1_024) throws -> CodexInput { .audioURL(try dataURL(data: data, mimeType: mimeType, limit: limit)) }
}

public struct CodexWorkspaceRoots: Sendable, Equatable {
    public let roots: [String]
    public init(_ roots: [URL]) throws {
        var seen: Set<String> = []
        var validated: [String] = []
        for root in roots {
            guard root.isFileURL, root.host == nil || root.host == "", root.query == nil, root.fragment == nil else {
                throw CodexError.invalidArgument("Workspace roots must be absolute local file URLs")
            }
            let path = root.standardizedFileURL.path
            guard path.hasPrefix("/") else { throw CodexError.unsafePath(path) }
            if seen.insert(path).inserted { validated.append(path) }
        }
        self.roots = validated
    }
    public func validateAbsolutePath(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw CodexError.unsafePath(path) }
        guard !NSString(string: path).pathComponents.contains("..") else { throw CodexError.unsafePath(path) }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard roots.contains(where: { root in root == "/" || normalized == root || normalized.hasPrefix(root + "/") }) else { throw CodexError.unsafePath(path) }
        return normalized
    }

    func containingRoot(for path: String) -> String? {
        roots.filter { root in root == "/" || path == root || path.hasPrefix(root + "/") }.max(by: { $0.count < $1.count })
    }
}

public enum CodexSymlinkStatus: Sendable, Equatable { case unknown, notSymlink, symlink }

public struct CodexFileMetadata: Sendable, Equatable {
    public var path: String
    public var isDirectory: Bool
    public var isFile: Bool
    public var symlinkStatus: CodexSymlinkStatus
    public var createdAtMilliseconds: Int64
    public var modifiedAtMilliseconds: Int64
    public var raw: JSONValue

    public init(path: String, raw: JSONValue) throws {
        self.path = path; self.raw = raw
        isDirectory = try raw.requireBool("isDirectory", context: "metadata")
        isFile = try raw.requireBool("isFile", context: "metadata")
        symlinkStatus = try raw.requireBool("isSymlink", context: "metadata") ? .symlink : .notSymlink
        createdAtMilliseconds = try raw.requireInt64("createdAtMs", context: "metadata")
        modifiedAtMilliseconds = try raw.requireInt64("modifiedAtMs", context: "metadata")
    }
}

public struct CodexDirectoryEntry: Sendable, Equatable, Identifiable {
    public var path: String, name: String
    public var isDirectory: Bool, isFile: Bool
    public var symlinkStatus: CodexSymlinkStatus
    public var createdAtMilliseconds: Int64?
    public var modifiedAtMilliseconds: Int64?
    public var raw: JSONValue
    public var metadataRaw: JSONValue?
    public var id: String { path }
}

public struct CodexDirectoryDiagnostic: Sendable, Equatable {
    public var path: String
    public var message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}

public struct CodexDirectoryListing: Sendable, Equatable {
    public var entries: [CodexDirectoryEntry]
    public var diagnostics: [CodexDirectoryDiagnostic]
    public var raw: JSONValue
    public init(entries: [CodexDirectoryEntry], diagnostics: [CodexDirectoryDiagnostic] = [], raw: JSONValue) {
        self.entries = entries; self.diagnostics = diagnostics; self.raw = raw
    }
}

public enum CodexDirectoryListingDetail: Sendable, Equatable {
    case basic
    case metadata(maximumConcurrentRequests: Int)
    public static let detailed: Self = .metadata(maximumConcurrentRequests: 8)
}
