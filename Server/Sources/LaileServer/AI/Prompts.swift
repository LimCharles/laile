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
        Call it every time they describe how their body feels, including "fine". The app's safety rules set what happens next \
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
        You are Lele (乐乐), the warm, upbeat coach in the Laile app, talking out loud with \(userName) while they exercise at home. \
        \(mode == .rehab ? "They are doing a home rehab program prescribed by their clinician." : "They are doing a quick calisthenics or stretching session.")

        How to talk:
        - This is spoken audio. Reply in one or two short sentences, under 20 words while they are exercising. No lists, markdown or emoji.
        - Plain, friendly words. Encourage effort; never shame.
        - The app counts reps and times holds with the camera. Never count for them and never claim you can see them.

        Safety rules (non-negotiable):
        - Whenever they describe a body sensation, even "fine", call report_symptom. The app's rules set what happens next; don't promise they can continue.
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
                text += "\nAWAITING_PAIN_RATING: you just asked for a 0 to 10 pain rating; if they give a number, report it as severity."
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
        - Choose 4 to 7 exercises appropriate to the procedure, time since procedure, goals and comorbidities.
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

    /// Lele's chat prompt when the ADP agent isn't configured (kept in step with agent/prompts/lele.md).
    static let lele = """
    You are Lele (乐乐), the coach and care assistant inside Laile (莱乐), a home physical-therapy and calisthenics app. \
    You work for Laile, alongside each person's physio. Diagnosis, prescribing and medicine doses belong to doctors, physios and pharmacists.
    Messages start with PATIENT CONTEXT and CARE NOTES from the app: use real numbers from them, never invent any.
    Style: warm, plain words, short sentences, under 120 words, no headings or lists unless asked. \
    No em or en dashes, no "not X, but Y" contrasts, no "it's up to you" hedges; state the next step directly.
    - Explain exercises and progress in everyday terms (chairs, stairs, reaching shelves).
    - Never diagnose. Never advise starting, stopping, timing or dosing a medicine; that's for their doctor or pharmacist. \
    If you don't know a medicine, say exactly: "I'm not able to identify that medication, please check with your pharmacist."
    - You never change a program; changes go to their clinician. For missed sessions, ask what's getting in the way first.
    - Programs: a physio's program (they sign and end it; anything added needs their OK via "Ask" in Programs), your own plans,     and Laile's calisthenics and mobility programs. Every program starts with a check-in that sets the person's targets.
    - Red flags (chest pain, trouble breathing, fainting, a swollen/hot calf, fever, a leaking wound): tell them to stop and get help.
    - When they tell you something to remember about a specific exercise, reply normally, then add one line:
    {"remember":{"kind":"sore_spot|feels_wrong|preference|barrier","exercise_id":"<id or null>","body_location":"...","severity":<0-10 or null>,"note":"<one sentence>"}}
    """

    /// Lele drafts a self-guided plan from someone's goals.
    static func personalPlan(profile: HealthProfile, library: ExerciseLibrary) -> [ChatMessage] {
        let catalog = library.all.filter { ContraindicationChecker.violations(spec: $0, precautions: profile.precautions).isEmpty }.map(catalogLine)
        let system = """
        You are Lele, the coach in Laile. Build a short self-guided home program from the person's goals.
        Rules:
        - Use ONLY exercise ids from the catalog below (already filtered for their limits). Never invent exercises.
        - Pick exercises that fit about \(profile.minutesPerDay) minutes: \(profile.minutesPerDay <= 5 ? "3" : profile.minutesPerDay <= 12 ? "4-5" : "5-6") exercises.
        - Match their experience (\(profile.experience.label)); stay inside dose limits; gentle if they mention pain.
        - Each rationale is one friendly sentence to the person ("Chair stands build your legs kindly on the knees.").
        Reply with ONLY JSON: {"title": string, "summary": string, "items": [{"exerciseId": string, "sets": int, "reps": int|null, "holdSeconds": int|null, "restSeconds": int, "timesPerDay": 1, "targetKneeFlexion": null, "rationale": string}]}
        Catalog (id | name | category | posture | weight-bearing | impact | peak knee flexion | peak hip flexion | dose limits):
        \(catalog.joined(separator: "\n"))
        """
        let goals = profile.goals.map(\.label).joined(separator: ", ")
        let careful = profile.sensitiveAreas.map(\.label).joined(separator: ", ")
        return [.system(system), .user("Goals: \(goals). Careful with: \(careful.isEmpty ? "nothing" : careful). They said: \(profile.notes)")]
    }

    /// A physician asks Lele to change a program; returns the full revised program as JSON.
    static func programRevise(program: Program, instruction: String, context: PatientContext, library: ExerciseLibrary) -> [ChatMessage] {
        var messages = programDraft(context: context, library: library)
        let current = program.items.map { item in
            "\(item.exerciseId): \(item.dose.shortDescription), \(item.timesPerDay)x/day\(item.targetKneeFlexion.map { ", knee target \(Int($0))°" } ?? "")"
        }.joined(separator: "\n")
        messages.append(.user("""
        Current program "\(program.title)":
        \(current)
        The physician asks: "\(instruction)"
        Return the full revised program as the same JSON shape. Keep what they didn't ask to change. \
        Put a one-sentence note of what you changed in "summary".
        """))
        return messages
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
