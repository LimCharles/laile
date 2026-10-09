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
        lines = lines.map {
            $0.replacingOccurrences(of: #"\s?\[\d+(,\s?\d+)*\](\(@ref\))?"#, with: "", options: .regularExpression)
                // ADP strips its citations itself and leaves the gap: "work ." → "work."
                .replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: "**", with: "")
            // No dashes in Lele's voice: number ranges read "3 to 5", other dashes become commas.
            .replacingOccurrences(of: #"(\d)\s?[–—]\s?(\d)"#, with: "$1 to $2", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[—–]\s*"#, with: ", ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Collects the reply from the SSE stream. ADP streams several messages per response: a
    /// "thought" (the thinking model's reasoning) and the "reply". Only reply text is kept.
    /// `text.delta` appends, `text.replace` swaps a message's text, and `response.completed`
    /// carries every message in full, which wins when present.
    static func parse(_ stream: String) throws -> String {
        var kinds: [String: String] = [:]
        var texts: [String: String] = [:]
        var order: [String] = []
        var completed: String?
        var event = ""
        func note(_ id: String) { if !order.contains(id) { order.append(id) } }
        for raw in stream.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:"),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)) as? [String: Any]
            else { continue }
            switch (json["Type"] as? String) ?? event {
            case "message.added":
                if let message = json["Message"] as? [String: Any], let id = message["MessageId"] as? String {
                    kinds[id] = message["Type"] as? String
                    note(id)
                }
            case "text.delta":
                guard let delta = json["Text"] as? String else { continue }
                let id = json["MessageId"] as? String ?? ""
                let sofar = texts[id] ?? ""
                texts[id] = delta.hasPrefix(sofar) && !sofar.isEmpty ? delta : sofar + delta
                note(id)
            case "text.replace":
                guard let replacement = json["Text"] as? String else { continue }
                let id = json["MessageId"] as? String ?? ""
                texts[id] = replacement
                note(id)
            case "response.completed":
                let messages = (json["Response"] as? [String: Any])?["Messages"] as? [[String: Any]] ?? []
                let replies = messages.filter { ($0["Type"] as? String) != "thought" }.map { message in
                    ((message["Contents"] as? [[String: Any]]) ?? []).filter { ($0["Type"] as? String) == "text" }
                        .compactMap { $0["Text"] as? String }.joined()
                }.filter { !$0.isEmpty }
                if !replies.isEmpty { completed = replies.joined(separator: "\n") }
            case "error":
                let message = ((json["Error"] as? [String: Any])?["Message"] as? String) ?? "unknown error"
                throw Abort(.badGateway, reason: "ADP: \(message)")
            default:
                if let error = json["Error"] as? [String: Any] {
                    throw Abort(.badGateway, reason: "ADP: \(error["Message"] as? String ?? "unknown error")")
                }
            }
        }
        return completed ?? order.filter { kinds[$0] != "thought" }.compactMap { texts[$0] }.joined(separator: "\n")
    }
}
