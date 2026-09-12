import Foundation

public struct CodexDynamicToolResult: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String), imageDataURL(String)
        var json: JSONValue {
            switch self {
            case .text(let text): ["type": "inputText", "text": .string(text)]
            case .imageDataURL(let url): ["type": "inputImage", "imageUrl": .string(url)]
            }
        }
    }
    public var content: [Content]
    public var success: Bool
    public init(content: [Content], success: Bool = true) { self.content = content; self.success = success }
    public static func text(_ text: String, success: Bool = true) -> Self { .init(content: [.text(text)], success: success) }
    var json: JSONValue { ["contentItems": .array(content.map(\.json)), "success": .bool(success)] }
}

public struct CodexDynamicTool: Sendable {
    public typealias Handler = @Sendable (JSONValue) async throws -> CodexDynamicToolResult
    public var name: String, description: String
    public var inputSchema: JSONValue
    public var deferLoading: Bool
    public var handler: Handler
    public init(name: String, description: String, inputSchema: JSONValue, deferLoading: Bool = false, handler: @escaping Handler) { self.name = name; self.description = description; self.inputSchema = inputSchema; self.deferLoading = deferLoading; self.handler = handler }
    var specification: JSONValue { ["type": "function", "name": .string(name), "description": .string(description), "inputSchema": inputSchema, "deferLoading": .bool(deferLoading)] }
}

public actor CodexDynamicToolRegistry {
    private var tools: [String: CodexDynamicTool]
    public init(tools: [CodexDynamicTool] = []) { self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) }) }
    public func register(_ tool: CodexDynamicTool) { tools[tool.name] = tool }
    public func unregister(named name: String) { tools[name] = nil }
    public func removeAll() { tools.removeAll() }
    public func specifications() -> [JSONValue] { tools.values.sorted { $0.name < $1.name }.map(\.specification) }
    func tool(named name: String) -> CodexDynamicTool? { tools[name] }
}
