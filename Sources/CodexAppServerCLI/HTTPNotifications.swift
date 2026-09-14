import Foundation
import CodexAppServerKit

#if os(macOS)
struct CLINotificationConfiguration: Sendable, Equatable {
    static let supportedPlaceholders: Set<String> = [
        "event", "timestamp", "thread_id", "turn_id", "item_id", "request_id",
        "status", "interaction_kind", "interaction_method", "summary",
    ]

    let urlTemplate: String
    let method: String
    let headers: [String: String]
    let body: JSONValue?
    let timeoutSeconds: Double

    static func load(
        path: String,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        let fileURL = (path as NSString).isAbsolutePath
            ? URL(fileURLWithPath: path)
            : workingDirectory.appendingPathComponent(path)
        let data: Data
        do { data = try Data(contentsOf: fileURL.standardizedFileURL) }
        catch { throw CodexError.invalidConfiguration("Could not read notification configuration at \(fileURL.standardizedFileURL.path)") }
        return try decode(data, environment: environment)
    }

    static func decode(_ data: Data, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let raw: JSONValue
        do { raw = try JSONValue.decode(data) }
        catch { throw CodexError.invalidConfiguration("Notification configuration is not valid JSON") }
        guard let object = raw.objectValue else { throw CodexError.invalidConfiguration("Notification configuration must be a JSON object") }

        let allowedKeys: Set<String> = ["url", "method", "headers", "body", "timeoutSeconds"]
        let unknownKeys = Set(object.keys).subtracting(allowedKeys).sorted()
        guard unknownKeys.isEmpty else { throw CodexError.invalidConfiguration("Unknown notification configuration field: \(unknownKeys.joined(separator: ", "))") }
        guard let rawURL = object["url"]?.stringValue, !rawURL.isEmpty else { throw CodexError.invalidConfiguration("Notification configuration requires a non-empty string url") }

        let method: String
        if let rawMethod = object["method"] {
            guard let value = rawMethod.stringValue, Self.isHTTPToken(value) else { throw CodexError.invalidConfiguration("Notification method must be a valid HTTP token") }
            method = value.uppercased()
        } else { method = "GET" }

        var headers: [String: String] = [:]
        var normalizedHeaderNames: Set<String> = []
        if let rawHeaders = object["headers"] {
            guard let values = rawHeaders.objectValue else { throw CodexError.invalidConfiguration("Notification headers must be a JSON object of string values") }
            for (name, rawValue) in values {
                guard Self.isHTTPToken(name), let value = rawValue.stringValue else { throw CodexError.invalidConfiguration("Notification headers must use valid names and string values") }
                guard normalizedHeaderNames.insert(name.lowercased()).inserted else { throw CodexError.invalidConfiguration("Notification header names must be unique ignoring case") }
                let expanded = try Self.expandEnvironment(in: value, environment: environment)
                try Self.validateHeaderValue(expanded)
                try CLINotificationTemplate.validate(expanded)
                headers[name] = expanded
            }
        }

        let timeout: Double
        if let rawTimeout = object["timeoutSeconds"] {
            guard let decimal = rawTimeout.decimalValue else { throw CodexError.invalidConfiguration("Notification timeoutSeconds must be a number from 1 through 60") }
            timeout = NSDecimalNumber(decimal: decimal).doubleValue
            guard timeout.isFinite, (1...60).contains(timeout) else { throw CodexError.invalidConfiguration("Notification timeoutSeconds must be a number from 1 through 60") }
        } else { timeout = 10 }

        let urlTemplate = try Self.expandEnvironment(in: rawURL, environment: environment)
        try CLINotificationTemplate.validate(urlTemplate)
        let validationValues = Dictionary(uniqueKeysWithValues: supportedPlaceholders.map { ($0, "") })
        let validationURL = try CLINotificationTemplate.interpolate(urlTemplate, values: validationValues, urlEncode: true)
        guard Self.validHTTPURL(validationURL) != nil else { throw CodexError.invalidConfiguration("Notification url must be an absolute HTTP or HTTPS URL") }

        let body = try object["body"].map { try Self.expandEnvironment(in: $0, environment: environment) }
        if let body { try Self.validateTemplates(in: body) }
        return .init(urlTemplate: urlTemplate, method: method, headers: headers, body: body, timeoutSeconds: timeout)
    }

    func request(for context: CLINotificationContext) throws -> URLRequest {
        let renderedURL = try CLINotificationTemplate.interpolate(urlTemplate, values: context.values, urlEncode: true)
        guard let url = Self.validHTTPURL(renderedURL) else { throw CLINotificationRequestError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = method
        for (name, template) in headers {
            let value = try CLINotificationTemplate.interpolate(template, values: context.values, urlEncode: false)
            do { try Self.validateHeaderValue(value) }
            catch { throw CLINotificationRequestError.invalidHeaders }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            let renderedBody = try Self.interpolate(body, values: context.values)
            request.httpBody = try renderedBody.encoded(sortedKeys: true)
            if !headers.keys.contains(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    private static func validHTTPURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", components.host != nil,
              let url = components.url else { return nil }
        return url
    }

    private static func isHTTPToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || punctuation.contains(byte)
        }
    }

    private static func validateHeaderValue(_ value: String) throws {
        let valid = value.unicodeScalars.allSatisfy { scalar in scalar.value == 9 || (scalar.value >= 32 && scalar.value != 127) }
        guard valid else { throw CodexError.invalidConfiguration("Notification header values cannot contain control characters") }
    }

    private static func expandEnvironment(in value: JSONValue, environment: [String: String]) throws -> JSONValue {
        switch value {
        case .string(let text): return .string(try expandEnvironment(in: text, environment: environment))
        case .array(let values): return .array(try values.map { try expandEnvironment(in: $0, environment: environment) })
        case .object(let values): return .object(try values.mapValues { try expandEnvironment(in: $0, environment: environment) })
        default: return value
        }
    }

    private static func expandEnvironment(in template: String, environment: [String: String]) throws -> String {
        var output = "", remainder = template[...]
        while let start = remainder.range(of: "${") {
            output += remainder[..<start.lowerBound]
            guard let end = remainder[start.upperBound...].firstIndex(of: "}") else { throw CodexError.invalidConfiguration("Malformed environment reference in notification configuration") }
            let name = String(remainder[start.upperBound..<end])
            guard isEnvironmentName(name) else { throw CodexError.invalidConfiguration("Malformed environment reference in notification configuration") }
            guard let value = environment[name], !value.isEmpty else { throw CodexError.invalidConfiguration("Missing notification environment variable \(name)") }
            output += value
            remainder = remainder[remainder.index(after: end)...]
        }
        output += remainder
        return output
    }

    private static func isEnvironmentName(_ value: String) -> Bool {
        guard let first = value.utf8.first, first == 95 || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return value.utf8.dropFirst().allSatisfy { $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    private static func validateTemplates(in value: JSONValue) throws {
        switch value {
        case .string(let text): try CLINotificationTemplate.validate(text)
        case .array(let values): for value in values { try validateTemplates(in: value) }
        case .object(let values): for value in values.values { try validateTemplates(in: value) }
        default: break
        }
    }

    private static func interpolate(_ value: JSONValue, values: [String: String]) throws -> JSONValue {
        switch value {
        case .string(let text): return .string(try CLINotificationTemplate.interpolate(text, values: values, urlEncode: false))
        case .array(let items): return .array(try items.map { try interpolate($0, values: values) })
        case .object(let object): return .object(try object.mapValues { try interpolate($0, values: values) })
        default: return value
        }
    }
}

enum CLINotificationTemplate {
    static func validate(_ template: String) throws {
        let emptyValues = Dictionary(uniqueKeysWithValues: CLINotificationConfiguration.supportedPlaceholders.map { ($0, "") })
        _ = try interpolate(template, values: emptyValues, urlEncode: false)
    }

    static func interpolate(_ template: String, values: [String: String], urlEncode: Bool) throws -> String {
        var output = "", remainder = template[...]
        while let start = remainder.range(of: "{{") {
            let prefix = remainder[..<start.lowerBound]
            guard !prefix.contains("}}") else { throw CodexError.invalidConfiguration("Malformed notification placeholder") }
            output += prefix
            guard let end = remainder[start.upperBound...].range(of: "}}") else { throw CodexError.invalidConfiguration("Malformed notification placeholder") }
            let name = String(remainder[start.upperBound..<end.lowerBound])
            guard CLINotificationConfiguration.supportedPlaceholders.contains(name) else { throw CodexError.invalidConfiguration("Unknown notification placeholder \(name)") }
            let value = values[name] ?? ""
            output += urlEncode ? percentEncode(value) : value
            remainder = remainder[end.upperBound...]
        }
        guard !remainder.contains("}}") else { throw CodexError.invalidConfiguration("Malformed notification placeholder") }
        output += remainder
        return output
    }

    private static func percentEncode(_ value: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        var bytes: [UInt8] = []
        for byte in value.utf8 {
            if (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [45, 46, 95, 126].contains(byte) {
                bytes.append(byte)
            } else {
                bytes.append(37)
                bytes.append(hexadecimal[Int(byte >> 4)])
                bytes.append(hexadecimal[Int(byte & 0x0F)])
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct CLINotificationContext: Sendable, Equatable {
    let values: [String: String]

    static func make(for event: CodexEvent, timestamp: String = Self.timestamp()) -> Self? {
        switch event {
        case .turnCompleted(let threadID, let turn): return makeTurn(threadID: threadID, turn: turn, timestamp: timestamp)
        case .serverRequest(let interaction):
            guard isHumanFacing(kind: interaction.kind, method: interaction.method) else { return nil }
            return makeInteraction(
                id: interaction.id, method: interaction.method, kind: interaction.kind,
                threadID: interaction.threadID, turnID: interaction.turnID, itemID: interaction.itemID,
                questions: interaction.questions.map(\.question), raw: interaction.raw, timestamp: timestamp
            )
        default: return nil
        }
    }

    static func makeTurn(threadID: String?, turn: CodexTurn, timestamp: String) -> Self {
        let status = turn.status ?? ""
        let event: String
        switch status {
        case "completed": event = "turn_completed"
        case "failed": event = "turn_failed"
        case "interrupted": event = "turn_interrupted"
        default: event = "turn_ended"
        }
        let agentMessage = turn.raw["items"]?.arrayValue?.reversed()
            .first { $0["type"]?.stringValue == "agentMessage" && !($0["text"]?.stringValue ?? "").isEmpty }?["text"]?.stringValue
        let errorMessage = turn.raw["error"]?["message"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let fallback = errorMessage ?? (status.isEmpty ? "Turn ended" : "Turn \(status)")
        return .init(values: baseValues(
            event: event, timestamp: timestamp, threadID: threadID ?? turn.threadID, turnID: turn.id,
            status: status, summary: normalizedSummary(agentMessage ?? fallback)
        ))
    }

    static func makeInteraction(
        id: String, method: String, kind: CodexInteractionKind,
        threadID: String?, turnID: String?, itemID: String?, questions: [String],
        raw: JSONValue, timestamp: String
    ) -> Self {
        let questionSummary = questions.filter { !$0.isEmpty }.joined(separator: " / ")
        let fallbacks = [raw["reason"]?.stringValue, raw["command"]?.stringValue, raw["serverName"]?.stringValue]
        let summary = !questionSummary.isEmpty ? questionSummary : fallbacks.compactMap { $0 }.first { !$0.isEmpty } ?? method
        var values = baseValues(
            event: "awaiting_input", timestamp: timestamp, threadID: threadID ?? "", turnID: turnID ?? "",
            status: "", summary: normalizedSummary(summary)
        )
        values["item_id"] = itemID ?? ""
        values["request_id"] = id
        values["interaction_kind"] = interactionKind(kind, method: method)
        values["interaction_method"] = method
        return .init(values: values)
    }

    private static func baseValues(event: String, timestamp: String, threadID: String, turnID: String, status: String, summary: String) -> [String: String] {
        [
            "event": event, "timestamp": timestamp, "thread_id": threadID, "turn_id": turnID,
            "item_id": "", "request_id": "", "status": status, "interaction_kind": "",
            "interaction_method": "", "summary": summary,
        ]
    }

    private static func isHumanFacing(kind: CodexInteractionKind, method: String) -> Bool {
        if case .unknown = kind {
            let normalized = method.lowercased()
            return normalized.contains("approval") || normalized.contains("requestuserinput") || normalized.contains("elicitation")
        }
        return true
    }

    private static func interactionKind(_ kind: CodexInteractionKind, method: String) -> String {
        switch kind {
        case .commandApproval: return "command_approval"
        case .networkApproval: return "network_approval"
        case .fileChangeApproval: return "file_change_approval"
        case .permissionApproval: return "permission_approval"
        case .userInput: return "user_input"
        case .mcpForm: return "mcp_form"
        case .openAIForm: return "openai_form"
        case .urlElicitation: return "url_elicitation"
        case .unknown:
            let normalized = method.lowercased()
            if normalized.contains("execcommand") || normalized.contains("commandexecution") { return "command_approval" }
            if normalized.contains("applypatch") || normalized.contains("filechange") { return "file_change_approval" }
            return "unknown"
        }
    }

    private static func normalizedSummary(_ value: String) -> String {
        String(value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ").prefix(500))
    }

    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}

enum CLINotificationRequestError: Error { case invalidURL, invalidHeaders }
typealias CLINotificationSender = @Sendable (URLRequest) async throws -> URLResponse

private enum CLINotificationSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

actor CLINotificationDispatcher {
    private let configuration: CLINotificationConfiguration
    private let sender: CLINotificationSender
    private let report: @Sendable (String) -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        configuration: CLINotificationConfiguration,
        sender: @escaping CLINotificationSender = { request in
            let (_, response) = try await CLINotificationSession.shared.data(for: request)
            return response
        },
        report: @escaping @Sendable (String) -> Void = { message in
            FileHandle.standardError.write(Data("[notification] \(message)\n".utf8))
        }
    ) {
        self.configuration = configuration
        self.sender = sender
        self.report = report
    }

    func enqueue(_ event: CodexEvent) {
        guard let context = CLINotificationContext.make(for: event) else { return }
        let id = UUID(), configuration = self.configuration, sender = self.sender, report = self.report
        tasks[id] = Task { [weak self] in
            do {
                let request = try configuration.request(for: context)
                let response = try await sender(request)
                guard let http = response as? HTTPURLResponse else { report("request failed: non-HTTP response"); await self?.finished(id); return }
                guard (200..<300).contains(http.statusCode) else { report("request failed: HTTP \(http.statusCode)"); await self?.finished(id); return }
            } catch CLINotificationRequestError.invalidURL { report("request failed: invalid event URL") }
            catch CLINotificationRequestError.invalidHeaders { report("request failed: invalid request headers") }
            catch let error as URLError where error.code == .timedOut { report("request failed: timed out") }
            catch let error as URLError { report("request failed: network error \(error.code.rawValue)") }
            catch is CancellationError { report("request failed: cancelled") }
            catch { report("request failed: transport error") }
            await self?.finished(id)
        }
    }

    func finish() async {
        let outstanding = Array(tasks.values)
        for task in outstanding { await task.value }
    }

    private func finished(_ id: UUID) { tasks[id] = nil }
}
#endif
