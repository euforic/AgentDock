import Foundation

public enum TranscriptProvider: String, Sendable, Hashable, Codable {
    case codex
    case claude

    public var capabilities: TranscriptProviderCapabilities {
        switch self {
        case .codex:
            return .init(supportsApprovals: true)
        case .claude:
            return .init(supportsApprovals: false)
        }
    }
}

public struct TranscriptProviderCapabilities: Sendable, Hashable, Codable {
    public let supportsApprovals: Bool

    public init(supportsApprovals: Bool) {
        self.supportsApprovals = supportsApprovals
    }
}

public enum TranscriptEventAvailability: Sendable, Hashable {
    case available
    case unavailable(String)
}

public enum TranscriptMessageRole: String, Sendable, Hashable, Codable {
    case user
    case assistant
    case system
    case tool
    case unknown
}

public enum TranscriptEventKind: String, Sendable, Hashable, Codable {
    case message
    case reasoning
    case toolCall
    case toolOutput
    case command
    case fileReference
    case patch
    case error
    case approval
    case status
    case unsupported
    case malformed
}

public struct TranscriptText: Sendable, Hashable, Codable {
    public let value: String
    public let originalByteCount: Int
    public let isTruncated: Bool

    public init(_ value: String, limit: Int = TranscriptRecordDecoder.defaultTextLimit) {
        let boundedLimit = max(0, limit)
        originalByteCount = value.utf8.count
        isTruncated = originalByteCount > boundedLimit
        self.value = isTruncated
            ? Self.validUTF8Prefix(of: value, byteLimit: boundedLimit)
            : value
    }

    private static func validUTF8Prefix(of value: String, byteLimit: Int) -> String {
        var bytes = Array(value.utf8.prefix(byteLimit))
        while !bytes.isEmpty {
            if let prefix = String(bytes: bytes, encoding: .utf8) {
                return prefix
            }
            bytes.removeLast()
        }
        return ""
    }
}

public struct TranscriptEvent: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let sequence: Int
    public let kind: TranscriptEventKind
    public let role: TranscriptMessageRole
    public let title: String?
    public let text: TranscriptText?
    public let name: String?
    public let callID: String?
    public let providerEventID: String?
    public let sourceType: String
    public let timestamp: Date?

    public init(
        id: String,
        sequence: Int,
        kind: TranscriptEventKind,
        role: TranscriptMessageRole = .unknown,
        title: String? = nil,
        text: TranscriptText? = nil,
        name: String? = nil,
        callID: String? = nil,
        providerEventID: String? = nil,
        sourceType: String,
        timestamp: Date? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.kind = kind
        self.role = role
        self.title = title
        self.text = text
        self.name = name
        self.callID = callID
        self.providerEventID = providerEventID
        self.sourceType = sourceType
        self.timestamp = timestamp
    }

    public func availability(for provider: TranscriptProvider) -> TranscriptEventAvailability {
        if kind == .approval, !provider.capabilities.supportsApprovals {
            return .unavailable("Approval events are not available for this provider.")
        }
        return .available
    }

    public func renderableText(for provider: TranscriptProvider) -> TranscriptText? {
        guard availability(for: provider) == .available else { return nil }
        return text
    }
}

public struct TranscriptPage: Sendable, Hashable, Codable {
    public let events: [TranscriptEvent]
    public let hasOlderEvents: Bool

    public init(events: [TranscriptEvent], hasOlderEvents: Bool) {
        self.events = events
        self.hasOlderEvents = hasOlderEvents
    }

    /// Prepends an older page while preserving input order and existing event identity.
    public func prepending(_ olderPage: TranscriptPage) -> TranscriptPage {
        let currentIDs = Set(events.map(\.id))
        var seenOlder = Set<String>()
        let uniqueOlder = olderPage.events.filter {
            !currentIDs.contains($0.id) && seenOlder.insert($0.id).inserted
        }
        let merged = uniqueOlder + events
        return TranscriptPage(events: merged, hasOlderEvents: olderPage.hasOlderEvents)
    }
}

public struct TranscriptDocument: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let sessionID: String
    public let provider: TranscriptProvider
    public var events: [TranscriptEvent]
    public var hasOlderEvents: Bool
    public var isInitialLoading: Bool
    public var isLoadingOlder: Bool

    public init(
        id: String,
        sessionID: String,
        provider: TranscriptProvider,
        events: [TranscriptEvent] = [],
        hasOlderEvents: Bool = false,
        isInitialLoading: Bool = false,
        isLoadingOlder: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.provider = provider
        self.events = events
        self.hasOlderEvents = hasOlderEvents
        self.isInitialLoading = isInitialLoading
        self.isLoadingOlder = isLoadingOlder
    }

}

public struct TranscriptRecordDecoder: Sendable {
    public static let defaultTextLimit = 64 * 1024

    public let textLimit: Int

    public init(textLimit: Int = defaultTextLimit) {
        self.textLimit = max(0, textLimit)
    }

    /// Decodes one JSON-lines record. Invalid JSON becomes a renderable malformed event.
    /// `sequence` must be the record's stable source ordinal, not its position in a loaded page.
    public func decode(_ data: Data, sequence: Int) -> TranscriptEvent? {
        guard !data.isEmpty else { return nil }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return event(
                data: data,
                sequence: sequence,
                sourceType: "malformed",
                kind: .malformed,
                title: "Malformed transcript record",
                text: error.localizedDescription
            )
        }
        guard let record = object as? [String: Any] else {
            return event(
                data: data,
                sequence: sequence,
                sourceType: "malformed",
                kind: .malformed,
                title: "Transcript record is not an object",
                text: "The record root was \(rootTypeName(object)); its content was not rendered."
            )
        }

        let envelopeType = string(record["type"]) ?? "unknown"
        let payload = dictionary(record["payload"]) ?? dictionary(record["item"]) ?? record
        let payloadType = string(payload["type"]) ?? envelopeType
        let sourceType = envelopeType == payloadType ? payloadType : "\(envelopeType).\(payloadType)"
        let payloadID = firstString(payload, keys: ["id", "item_id", "event_id"])
            ?? firstString(record, keys: ["id", "item_id", "event_id"])
        let callID = firstString(payload, keys: ["call_id", "callId"])
            ?? firstString(record, keys: ["call_id", "callId"])
        let role = TranscriptMessageRole(rawValue: string(payload["role"]) ?? "") ?? .unknown
        let name = firstString(payload, keys: ["name", "tool_name", "command"])

        if payloadType.localizedCaseInsensitiveContains("approval") {
            return event(
                data: data,
                sequence: sequence,
                sourceType: sourceType,
                kind: .approval,
                title: readable(payloadType),
                text: extractText(payload["message"]) ?? extractText(payload["reason"]),
                callID: callID,
                payloadID: payloadID
            )
        }
        if payloadType.localizedCaseInsensitiveContains("error")
            || payloadType == "turn_aborted"
        {
            return event(
                data: data,
                sequence: sequence,
                sourceType: sourceType,
                kind: .error,
                title: readable(payloadType),
                text: extractText(payload["message"]) ?? extractText(payload["error"])
                    ?? extractText(payload["details"]),
                callID: callID,
                payloadID: payloadID
            )
        }
        if payloadType == "file_reference" || payloadType == "file_ref" {
            return event(
                data: data,
                sequence: sequence,
                sourceType: sourceType,
                kind: .fileReference,
                title: firstString(payload, keys: ["label", "name"]) ?? "File reference",
                text: firstString(payload, keys: ["path", "url"]),
                payloadID: payloadID
            )
        }

        switch (envelopeType, payloadType) {
        case ("response_item", "message"), (_, "message"):
            guard role == .user || role == .assistant else {
                return event(
                    data: data,
                    sequence: sequence,
                    sourceType: sourceType,
                    kind: .unsupported,
                    title: "Non-conversation message",
                    text: "A \(string(payload["role"]) ?? "unknown") message was not rendered.",
                    payloadID: payloadID
                )
            }
            let messageText = extractMessageText(payload["content"]) ?? extractText(payload["text"])
            return event(
                data: data,
                sequence: sequence,
                sourceType: sourceType,
                kind: messageText == nil ? .malformed : .message,
                role: role,
                title: messageText == nil ? "Message content is unavailable" : nil,
                text: messageText,
                payloadID: payloadID
            )
        case ("response_item", "reasoning"), (_, "reasoning"), ("event_msg", "agent_reasoning"):
            return event(data: data, sequence: sequence, sourceType: sourceType, kind: .reasoning,
                         role: .assistant, text: extractText(payload["summary"]) ?? extractText(payload["content"])
                            ?? extractText(payload["text"]), payloadID: payloadID)
        case ("response_item", "function_call"):
            let kind: TranscriptEventKind = isCommand(name) ? .command : .toolCall
            return event(data: data, sequence: sequence, sourceType: sourceType, kind: kind,
                         title: name, text: extractText(payload["arguments"]), name: name,
                         callID: callID, payloadID: payloadID)
        case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"),
             ("response_item", "tool_search_output"):
            return event(data: data, sequence: sequence, sourceType: sourceType, kind: .toolOutput,
                         role: .tool, text: extractText(payload["output"]) ?? extractText(payload["content"]),
                         name: name, callID: callID, payloadID: payloadID)
        case ("response_item", "custom_tool_call"), ("response_item", "web_search_call"),
             ("response_item", "tool_search_call"), ("response_item", "image_generation_call"):
            let kind: TranscriptEventKind = isPatch(name) ? .patch : .toolCall
            return event(data: data, sequence: sequence, sourceType: sourceType, kind: kind,
                         title: name ?? readable(payloadType), text: extractText(payload["input"])
                            ?? extractText(payload["arguments"]) ?? extractText(payload["query"]),
                         name: name ?? payloadType, callID: callID, payloadID: payloadID)
        case ("event_msg", "patch_apply_end"):
            let succeeded = payload["success"] as? Bool
            return event(data: data, sequence: sequence, sourceType: sourceType,
                         kind: succeeded == false ? .error : .patch,
                         title: succeeded == false ? "Patch failed" : "Files changed",
                         text: extractText(payload["changes"]) ?? extractText(payload["patch"])
                            ?? extractText(payload["stdout"]) ?? extractText(payload["stderr"])
                            ?? extractText(payload["message"]),
                         payloadID: payloadID)
        case ("event_msg", "mcp_tool_call_end"), ("event_msg", "web_search_end"):
            return event(data: data, sequence: sequence, sourceType: sourceType, kind: .toolOutput,
                         role: .tool, title: name ?? readable(payloadType),
                         text: extractText(payload["output"]) ?? extractText(payload["result"])
                            ?? extractText(payload["message"]), name: name,
                         callID: callID, payloadID: payloadID)
        case ("event_msg", "task_started"), ("event_msg", "task_complete"),
             ("event_msg", "context_compacted"), ("event_msg", "sub_agent_activity"):
            return event(data: data, sequence: sequence, sourceType: sourceType, kind: .status,
                         title: readable(payloadType), text: extractText(payload["message"])
                            ?? extractText(payload["status"]), payloadID: payloadID)
        default:
            return event(data: data, sequence: sequence, sourceType: sourceType, kind: .unsupported,
                         title: "Unsupported transcript record", text: sourceType, callID: callID,
                         payloadID: payloadID)
        }
    }

    private func event(
        data: Data,
        sequence: Int,
        sourceType: String,
        kind: TranscriptEventKind,
        role: TranscriptMessageRole = .unknown,
        title: String? = nil,
        text: String? = nil,
        name: String? = nil,
        callID: String? = nil,
        payloadID: String? = nil
    ) -> TranscriptEvent {
        // Row identity belongs to the source record. Provider IDs and call IDs can repeat
        // across lifecycle updates, so they remain metadata rather than SwiftUI identity.
        let id = "\(sourceType):record:\(sequence)"
        return TranscriptEvent(
            id: id,
            sequence: sequence,
            kind: kind,
            role: role,
            title: title,
            text: text.map { TranscriptText($0, limit: textLimit) },
            name: name,
            callID: callID,
            providerEventID: payloadID,
            sourceType: sourceType
        )
    }

    private func extractText(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text }
        if let values = value as? [Any] {
            let parts = values.compactMap(extractText)
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        if let value = value as? [String: Any] {
            for key in [
                "text", "content", "output_text", "input_text", "summary_text",
                "value", "message", "output", "input", "arguments"
            ] {
                if let result = extractText(value[key]) { return result }
            }
            return stringify(value)
        }
        return stringify(value)
    }

    private func extractMessageText(_ value: Any?) -> String? {
        guard let content = value as? [Any] else {
            return extractText(value)
        }
        let parts = content.compactMap { item -> String? in
            guard let item = item as? [String: Any] else { return nil }
            switch string(item["type"]) {
            case "input_text", "output_text", "summary_text":
                return string(item["text"])
            case "input_image", "output_image":
                return "[Image attachment]"
            default:
                return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func stringify(_ value: Any) -> String? {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let result = String(data: data, encoding: .utf8) {
            return result
        }
        return String(describing: value)
    }

    private func rootTypeName(_ value: Any) -> String {
        switch value {
        case is [Any]: "an array"
        case is String: "a string"
        case is NSNumber: "a number or boolean"
        case is NSNull: "null"
        default: "an unknown value"
        }
    }

    private func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private func string(_ value: Any?) -> String? { value as? String }
    private func firstString(_ value: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { string(value[$0]) }.first
    }
    private func isCommand(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name.contains("command") || name == "exec" || name == "shell"
    }
    private func isPatch(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name.contains("patch") || name.contains("file_edit")
    }
    private func readable(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func fnv1a(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
