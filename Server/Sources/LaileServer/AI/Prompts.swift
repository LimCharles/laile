import Foundation
import LaileCore

enum CoachTools {
    struct SymptomArguments: Codable {
        var category: String
        var bodyLocation: String?
        var side: String?
        var quality: String?
        var severity: Int?

        enum CodingKeys: String, CodingKey {
            case category, side, quality, severity
            case bodyLocation = "body_location"
        }
    }

    static let reportSymptom = ToolDefinition(function: .init(
        name: "report_symptom",
        description: """
        Record any body sensation the user mentions (pain, pulling, burning, clicking, numbness, etc.). \
        Call it every time they describe how their body feels, including "fine". The app — not you — decides \
        whether to continue, stop the set, or escalate.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "category": .object([
                    "type": .string("string"),
                    "enum": .array(SymptomCategory.allCases.map { .string($0.rawValue) }),
                    "description": .string("normal=fine/counting; effort=muscles working/burning/tired; expectedStretch=pulling/tight; ambiguous=unclear like 'ow'; pain=sharp/stabbing/hurts; wrongSensation=clicking/giving way/numb/tingling; redFlag=chest pain, breathing trouble, calf swelling, fainting"),
                ]),
                "body_location": .object(["type": .string("string"), "description": .string("e.g. 'inside of knee', 'calf', 'lower back'")]),
                "side": .object(["type": .string("string"), "enum": .array([.string("left"), .string("right")])]),
                "quality": .object(["type": .string("string"), "description": .string("e.g. sharp, dull, pulling, clicking, burning")]),
                "severity": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(10)]),
            ]),
            "required": .array([.string("category")]),
        ])
    ))

    static func report(from call: ToolCall, utterance: String) -> SymptomReport? {
        guard call.function.name == reportSymptom.function.name,
              let args = try? JSONDecoder().decode(SymptomArguments.self, from: Data(call.function.arguments.utf8)),
              let category = SymptomCategory(rawValue: args.category) else { return nil }
        return SymptomReport(category: category, utterance: utterance, bodyLocation: args.bodyLocation,
                             side: args.side.flatMap(Side.init(rawValue:)), quality: args.quality,
                             severity: args.severity.map { min(10, max(0, $0)) }, source: .voiceLLM)
    }
}

enum Prompts {
    static func coachSystem(context: API.VoiceContext?, mode: AppMode, userName: String) -> String {
        var text = """
        You are Laile, a warm, upbeat movement coach talking out loud with \(userName) while they exercise at home. \
        \(mode == .rehab ? "They are doing a home rehab program prescribed by their clinician." : "They are doing a quick calisthenics or stretching session.")

        How to talk:
        - This is spoken audio. Reply in one or two short sentences, under 20 words while they are exercising. No lists, markdown or emoji.
        - Plain, friendly words. Encourage effort; never shame.
        - The app counts reps and times holds with the camera. Never count for them and never claim you can see them.

        Safety rules (non-negotiable):
        - Whenever they describe a body sensation — even "fine" — call report_symptom. The app decides what happens next; don't promise they can continue.
        - If it's unclear whether it's a stretch or a sharp pain, ask exactly that.
        - Never diagnose. Never give medication advice or dosing advice; say it's a question for their doctor or pharmacist.
        - If they mention chest pain, trouble breathing, fainting, or a swollen/hot calf, call report_symptom with category redFlag.
        """
        if let context {
            text += "\n\nRight now: phase=\(context.phase)"
            if let name = context.exerciseName { text += ", exercise=\(name)" }
            if let set = context.setIndex, let total = context.totalSets { text += ", set \(set + 1) of \(total)" }
            if let reps = context.reps { text += ", reps so far=\(reps)" }
            if let hold = context.holdSeconds { text += ", holding for \(hold)s" }
            if context.awaitingPainRating {
                text += "\nAWAITING_PAIN_RATING: you just asked for a 0–10 pain rating; if they give a number, report it as severity."
            }
        }
        return text
    }

    static func programDraft(context: PatientContext, library: ExerciseLibrary) -> [ChatMessage] {
        let catalog = library.specs(for: .rehab).map(catalogLine) + library.specs(for: .move).filter { !$0.modes.contains(.rehab) }.map(catalogLine)
        let system = """
        You draft home exercise programs for a physiotherapist to REVIEW and SIGN. You never prescribe directly to patients.

        Rules:
        - Use ONLY exercise ids from the catalog below. Never invent exercises.
        - Respect every precaution. Anything contraindicated will be removed automatically, so don't include it.
        - Choose 4–7 exercises appropriate to the procedure, time since procedure, goals and comorbidities.
        - Stay inside each exercise's dose limits.
        - For knee exercises you may set targetKneeFlexion (clinical degrees, 0 = straight) as a progressive goal.
        - Each rationale is one short clinical sentence the physiotherapist can check.

        Reply with ONLY a JSON object, no prose, in exactly this shape:
        {"title": string, "summary": string, "items": [{"exerciseId": string, "sets": int, "reps": int|null, "holdSeconds": int|null, "restSeconds": int, "timesPerDay": int, "targetKneeFlexion": number|null, "rationale": string}]}

        Catalog (id | name | category | posture | weight-bearing | impact | peak knee flexion | peak hip flexion | dose limits):
        \(catalog.joined(separator: "\n"))
        """
        let encoder = LaileJSON.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let patient = (try? String(decoding: encoder.encode(context), as: UTF8.self)) ?? "{}"
        let days = context.daysSinceProcedure(now: Date()).map { "Days since procedure: \($0)\n" } ?? ""
        return [.system(system), .user("\(days)Patient context:\n\(patient)")]
    }

    static func catalogLine(_ spec: ExerciseSpec) -> String {
        let l = spec.limits
        let dose = [
            "sets \(l.sets.lowerBound)-\(l.sets.upperBound)",
            l.reps.map { "reps \($0.lowerBound)-\($0.upperBound)" },
            l.holdSeconds.map { "hold \($0.lowerBound)-\($0.upperBound)s" },
        ].compactMap { $0 }.joined(separator: ", ")
        return "\(spec.id) | \(spec.name) | \(spec.category.rawValue) | \(spec.posture.rawValue) | \(spec.loads.weightBearing ? "yes" : "no") | \(spec.loads.impact.label) | \(Int(spec.loads.peakKneeFlexion))° | \(Int(spec.loads.peakHipFlexion))° | \(dose)"
    }

    /// Models sometimes wrap JSON in prose or code fences; take the outermost object.
    static func extractJSON(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return text }
        return String(text[start...end])
    }
}
