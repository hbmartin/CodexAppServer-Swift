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
    public var roots: [String]
    public init(_ roots: [URL]) { self.roots = roots.map { $0.standardizedFileURL.path } }
    public func validateAbsolutePath(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw CodexError.unsafePath(path) }
        guard !NSString(string: path).pathComponents.contains("..") else { throw CodexError.unsafePath(path) }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard roots.contains(where: { normalized == $0 || normalized.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { throw CodexError.unsafePath(path) }
        return normalized
    }
}

public struct CodexFileMetadata: Sendable, Equatable { public var path: String; public var isDirectory: Bool; public var isFile: Bool; public var isSymlink: Bool; public var raw: JSONValue }
public struct CodexDirectoryEntry: Sendable, Equatable, Identifiable { public var path: String, name: String; public var isDirectory: Bool, isSymlink: Bool; public var raw: JSONValue; public var id: String { path } }
