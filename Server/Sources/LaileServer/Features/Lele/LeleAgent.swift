import Foundation
import LaileCore
import Vapor

/// Lele's brain for free conversation. In order: the Tencent Cloud ADP agent (Hunyuan with the
/// physio and medicines knowledge base), the plain LLM with Lele's prompt, then offline answers.
struct LeleAgent {
    let app: Application
    let logger: Logger

    func reply(to text: String, context: String, userID: UUID) async throws -> String {
        let message = "\(context)\n\nQUESTION: \(text)\n\(Self.voiceReminder)"
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

    /// ADP's knowledge-base template can override the persona prompt (third person, headings, file
    /// names as citations), so each message restates Lele's voice.
    static let voiceReminder = "(Reply as Lele, talking to them as \"you\": under 120 words, plain sentences, no headings, no document names.)"

    /// ADP's Fallback Reply (set in the console, see agent/README.md): the knowledge base had no answer.
    static func isFallback(_ text: String) -> Bool {
        text.replacingOccurrences(of: "’", with: "'").hasPrefix("I'm not able to answer that one")
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
                // Section labels from the context Laile sends, echoed back: "[CARE NOTES]".
                .replacingOccurrences(of: #"\s?\[[A-Z][A-Z ]{2,}\]"#, with: "", options: .regularExpression)
                // ADP strips its citations itself and leaves the gap: "work ." → "work."
                .replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
        }
        // A report-style title line ("How Mdm Tan Is Doing") before the first paragraph.
        if let first = lines.firstIndex(where: { !$0.isEmpty }), lines.indices.contains(first + 1), lines[first + 1].isEmpty,
           let last = lines[first].last, !".?!:)\"”".contains(last), lines[first].split(separator: " ").count <= 8 {
            lines.remove(at: first)
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: "**", with: "")
            // Knowledge-base file names cited inline ("... a few weeks 07-medicines-after-joint-surgery.").
            .replacingOccurrences(of: #"\s?\b\d{2}(-[a-z0-9]+){2,}(\.md)?\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)based on the provided [^,:.]*[,:]\s*"#, with: "", options: .regularExpression)
            // The model reintroduces itself mid-conversation: "Hi, I'm Lele from Laile. Your knee…"
            .replacingOccurrences(of: #"^\s*(?i)(?:(?:hi|hello|hey)(?: there)?[!,.]?\s*)?i['’]m lele(?:,? from laile)?(?:,? your [a-z ]{1,30})?[.!]\s*"#, with: "", options: .regularExpression)
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
    /// "thought" (the thinking model's reasoning) and the "reply". Only reply text is kept: when
    /// any message is typed "reply", only those are used; otherwise anything that isn't reasoning.
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
                let typed = messages.contains { ($0["Type"] as? String) == "reply" }
                let replies = messages.filter { isReply($0["Type"] as? String, anyTypedReply: typed) }.map { message in
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
        let anyTypedReply = kinds.values.contains("reply")
        return completed ?? order.filter { isReply(kinds[$0], anyTypedReply: anyTypedReply) }.compactMap { texts[$0] }.joined(separator: "\n")
    }

    static let reasoningTypes: Set<String> = ["thought", "reasoning", "thinking", "think"]

    static func isReply(_ type: String?, anyTypedReply: Bool) -> Bool {
        if anyTypedReply { return type == "reply" }
        return !reasoningTypes.contains(type ?? "")
    }
}

/// Program drafts and the clinician brief through the same Tencent Cloud ADP agent as Lele's chat.
/// The request goes in a named mode ("PLAN REQUEST", "CLINICIAN BRIEF") that Lele's ADP prompt
/// answers with only what was asked for, grounded in the knowledge base. Each call gets a fresh
/// conversation, so drafts never mix with anyone's chat.
struct ADPPlannerProvider: LLMProvider {
    let appKey: String
    let client: any Client
    let logger: Logger

    var name: String { "Lele on Tencent Cloud ADP (Hy3)" }
    var isLive: Bool { true }

    func complete(messages: [ChatMessage], tools: [ToolDefinition], temperature: Double) async throws -> LLMReply {
        let body = messages.compactMap(\.content).joined(separator: "\n\n")
        let text = body.hasPrefix("CLINICIAN BRIEF") || body.hasPrefix("PLAN REQUEST") ? body : "PLAN REQUEST\n\(body)"
        let answer = try await ADPClient(appKey: appKey, client: client)
            .chat(text, visitorId: "laile-planner", conversationId: "laile-plan-\(UUID().uuidString.lowercased())")
        return LLMReply(content: answer, toolCalls: [])
    }
}
