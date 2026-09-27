import Foundation
import LaileCore
import Vapor

/// Minimal JSON value for tool schemas and arbitrary arguments.
indirect enum JSONValue: Codable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

struct ChatMessage: Codable, Sendable, Hashable {
    var role: String
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", content: text) }
    static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: text) }
    static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: "assistant", content: text) }
}

struct ToolCall: Codable, Sendable, Hashable {
    struct Function: Codable, Sendable, Hashable {
        var name: String
        /// JSON-encoded arguments, as chat-completions APIs return them.
        var arguments: String
    }

    var id: String
    var type: String = "function"
    var function: Function
}

struct ToolDefinition: Codable, Sendable, Hashable {
    struct Function: Codable, Sendable, Hashable {
        var name: String
        var description: String
        var parameters: JSONValue
    }

    var type: String = "function"
    var function: Function
}

struct LLMReply: Sendable {
    var content: String?
    var toolCalls: [ToolCall]
}

protocol LLMProvider: Sendable {
    /// Shown in the portal so clinicians know what drafted a program.
    var name: String { get }
    /// False for the offline mock — callers fall back to deterministic logic.
    var isLive: Bool { get }
    func complete(messages: [ChatMessage], tools: [ToolDefinition], temperature: Double) async throws -> LLMReply
}

/// Tencent Hunyuan via its chat-completions endpoint (the same wire format also works for
/// other Tencent Cloud model endpoints, e.g. models hosted on ADP).
struct HunyuanProvider: LLMProvider {
    let config: LaileConfig.LLM
    let client: any Client
    let logger: Logger

    var name: String { "Hunyuan (\(config.model))" }
    var isLive: Bool { true }

    struct RequestBody: Content {
        var model: String
        var messages: [ChatMessage]
        var tools: [ToolDefinition]?
        var temperature: Double
        var stream = false
    }

    struct ResponseBody: Decodable {
        struct Choice: Decodable { var message: ChatMessage }
        var choices: [Choice]
    }

    func complete(messages: [ChatMessage], tools: [ToolDefinition], temperature: Double) async throws -> LLMReply {
        let url = URI(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: config.apiKey)
        let body = RequestBody(model: config.model, messages: messages, tools: tools.isEmpty ? nil : tools, temperature: temperature)
        let response = try await client.post(url, headers: headers) { req in
            try req.content.encode(body, using: JSONEncoder())
        }
        guard response.status == .ok else {
            let text = response.body.map { String(buffer: $0) } ?? ""
            logger.error("LLM HTTP \(response.status.code): \(text.prefix(300))")
            throw Abort(.badGateway, reason: "LLM request failed (\(response.status.code))")
        }
        let decoded = try response.content.decode(ResponseBody.self, using: JSONDecoder())
        guard let message = decoded.choices.first?.message else { throw Abort(.badGateway, reason: "LLM returned no choices") }
        return LLMReply(content: message.content, toolCalls: message.toolCalls ?? [])
    }
}

/// Offline stand-in used when no LLM key is configured (and in tests). It behaves like the
/// coach would: classifies the utterance with the on-device rules and replies briefly.
struct MockLLMProvider: LLMProvider {
    var name: String { "Offline rules (no LLM configured)" }
    var isLive: Bool { false }

    func complete(messages: [ChatMessage], tools: [ToolDefinition], temperature: Double) async throws -> LLMReply {
        let lastUser = messages.last { $0.role == "user" }?.content ?? ""
        let awaiting = messages.contains { $0.role == "system" && ($0.content ?? "").contains("AWAITING_PAIN_RATING") }
        let report = UtteranceClassifier.classify(lastUser, awaitingRating: awaiting)
        guard tools.contains(where: { $0.function.name == CoachTools.reportSymptom.function.name }), report.category != .normal else {
            return LLMReply(content: "You're doing great. Keep going.", toolCalls: [])
        }
        let args = CoachTools.SymptomArguments(category: report.category.rawValue, bodyLocation: report.bodyLocation,
                                               side: report.side?.rawValue, quality: report.quality, severity: report.severity)
        let json = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
        return LLMReply(content: nil, toolCalls: [ToolCall(id: "mock-\(UUID().uuidString.prefix(8))", function: .init(name: "report_symptom", arguments: json))])
    }
}
