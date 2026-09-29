import Foundation
import LaileCore
import Vapor

/// Lele's brain for free conversation. In order: the Tencent Cloud ADP agent (Hunyuan with the
/// physio and medicines knowledge base), the plain LLM with Lele's prompt, then offline answers.
struct LeleAgent {
    let app: Application
    let logger: Logger

    func reply(to text: String, context: String, userID: UUID) async throws -> String {
        let message = "\(context)\n\nQUESTION: \(text)"
        if let appKey = app.laile.config.adpAppKey {
            do {
                let answer = try await ADPClient(appKey: appKey, client: app.client).chat(message, visitorId: userID.uuidString,
                                                                                          conversationId: Self.conversationId(userID))
                if !answer.isEmpty { return Self.tidy(answer) }
            } catch {
                logger.warning("ADP chat failed (\(error)); falling back")
            }
        }
        if app.laile.llm.isLive {
            let reply = try await app.laile.llm.complete(messages: [.system(Prompts.lele), .user(message)], tools: [], temperature: 0.4)
            if let content = reply.content, !content.isEmpty { return Self.tidy(content) }
        }
        return Self.offline(text)
    }

    /// One ADP conversation per person per day, so context stays relevant and bounded.
    static func conversationId(_ userID: UUID, now: Date = Date()) -> String {
        "laile-\(userID.uuidString.replacingOccurrences(of: "-", with: "").lowercased())-\(DayKey(now, timeZone: .current).description)"
    }

    /// ADP's knowledge-base answers can come back with markdown headings and [n] citations.
    static func tidy(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.hasPrefix("#") { l.removeFirst() }
            return l.trimmingCharacters(in: .whitespaces)
        }
        lines = lines.map { $0.replacingOccurrences(of: #"\s?\[\d+(,\s?\d+)*\]"#, with: "", options: .regularExpression) }
        return lines.joined(separator: "\n").replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits off a `{"remember": …}` line (and any other trailing JSON the app handles itself).
    static func extractRemember(_ text: String) -> (String, RememberRequest?) {
        var remember: RememberRequest?
        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{"), trimmed.contains("\"remember\"") {
                remember = try? JSONDecoder().decode(RememberRequest.self, from: Data(Prompts.extractJSON(trimmed).utf8))
                continue
            }
            if trimmed.hasPrefix("{\"decision\"") || trimmed == "json" { continue }
            kept.append(line)
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), remember)
    }

    /// Without any model: answer the common things from the exercise library, otherwise be honest.
    static func offline(_ text: String) -> String {
        let lower = text.lowercased()
        if let spec = ExerciseLibrary.standard.all.first(where: { lower.contains($0.name.lowercased()) || lower.contains($0.id.replacingOccurrences(of: "-", with: " ")) }) {
            return "\(spec.name): \(spec.cues.purpose) \(spec.cues.setup) \(spec.cues.go)"
        }
        if lower.contains("how am i doing") || lower.contains("progress") {
            return "Your Progress tab has your charts. Every rep there is camera-counted, compared with where you started."
        }
        return "I can't think this one through right now, sorry. For anything about your recovery, your clinician is the best person to ask, and your pharmacist for medicines."
    }
}

/// Tencent Cloud ADP chat API (HTTP SSE): https://wss.lke.tencentcloud.com/adp/v2/chat
struct ADPClient {
    let appKey: String
    let client: Client
    static let endpoint = URI(string: "https://wss.lke.tencentcloud.com/adp/v2/chat")

    struct Body: Content {
        struct Part: Codable { var `Type`: String; var Text: String }
        var RequestId: String
        var ConversationId: String
        var AppKey: String
        var VisitorId: String
        var Contents: [Part]
        var Stream: String
        var Incremental: Bool
    }

    func chat(_ text: String, visitorId: String, conversationId: String) async throws -> String {
        let body = Body(RequestId: UUID().uuidString, ConversationId: conversationId, AppKey: appKey, VisitorId: visitorId,
                        Contents: [.init(Type: "text", Text: text)], Stream: "enable", Incremental: true)
        let response = try await client.post(Self.endpoint, headers: ["Content-Type": "application/json"]) { req in
            try req.content.encode(body, as: .json)
        }
        guard response.status == .ok, let buffer = response.body else {
            throw Abort(.badGateway, reason: "ADP returned \(response.status.code)")
        }
        return try Self.parse(String(buffer: buffer))
    }

    /// Collects the reply text from the SSE stream. Deltas are appended; if a delta repeats the
    /// text so far (non-incremental mode), it replaces it.
    static func parse(_ stream: String) throws -> String {
        var text = ""
        var event = ""
        for raw in stream.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let type = (json["Type"] as? String) ?? event
                if type == "text.delta", let delta = json["Text"] as? String {
                    text = delta.hasPrefix(text) && !text.isEmpty ? delta : text + delta
                } else if type == "error" || json["Error"] != nil {
                    let message = ((json["Error"] as? [String: Any])?["Message"] as? String) ?? "unknown error"
                    throw Abort(.badGateway, reason: "ADP: \(message)")
                }
            }
        }
        return text
    }
}
