import Foundation
import LaileCore
import Vapor

/// One conversational turn with the exercise coach.
///
/// Order matters: deterministic safety checks run *before* the LLM, and the LLM's symptom
/// classification is handed to `SymptomRules` (code), which decides the action. For any
/// action other than "continue", the spoken reply is a fixed, reviewed line.
struct CoachAgent {
    struct Turn {
        var reply: String
        var report: SymptomReport?
        var action: SymptomAction?
    }

    let llm: any LLMProvider
    let logger: Logger

    func respond(to utterance: String, history: [ChatMessage], context: API.VoiceContext?, mode: AppMode,
                 userName: String, policy: SymptomPolicy) async -> Turn {
        // 1. Red flags never wait on a model.
        if let flag = RedFlagDetector.detect(utterance) {
            var report = SymptomReport(category: .redFlag, utterance: utterance, source: .voiceLLM, redFlagReason: flag.reason)
            report.action = .endSession(flag.level)
            let line = SymptomResponses.line(for: .endSession(flag.level), category: .redFlag, policy: policy)!
            return Turn(reply: line.text, report: report, action: .endSession(flag.level))
        }
        // 2. Medication dosing questions get the fixed referral.
        if MedicationBoundary.isDoseQuestion(utterance) {
            return Turn(reply: MedicationBoundary.referral, report: nil, action: nil)
        }
        // 3. The model classifies and chats.
        var messages = [ChatMessage.system(Prompts.coachSystem(context: context, mode: mode, userName: userName))]
        messages += history.suffix(8)
        messages.append(.user(utterance))

        var reply: LLMReply
        do {
            reply = try await llm.complete(messages: messages, tools: [CoachTools.reportSymptom], temperature: 0.4)
        } catch {
            logger.warning("Coach LLM failed, using offline rules: \(error)")
            reply = (try? await MockLLMProvider().complete(messages: messages, tools: [CoachTools.reportSymptom], temperature: 0)) ?? LLMReply(content: nil, toolCalls: [])
        }

        guard let call = reply.toolCalls.first, var report = CoachTools.report(from: call, utterance: utterance) else {
            return Turn(reply: reply.content?.nonEmpty ?? "Okay. Keep going at your own pace.", report: nil, action: nil)
        }
        let decision = SymptomRules.decide(report, policy: policy)
        report.action = decision.action
        let fixedLine = SymptomResponses.line(for: decision.action, category: report.category, policy: policy)?.text
        let spoken: String
        if case .continueExercise = decision.action {
            spoken = reply.content?.nonEmpty ?? fixedLine ?? "Okay, noted. Keep going."
        } else {
            spoken = fixedLine ?? "Let's pause there."
        }
        return Turn(reply: spoken, report: report, action: decision.action)
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
