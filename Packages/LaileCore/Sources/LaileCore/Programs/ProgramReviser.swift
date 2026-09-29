import Foundation

/// A physician asks Lele to change a program in plain words ("make it gentler", "focus on hip
/// strength", "add wall slides", "drop the lunges"). This is the rule-based reviser: it handles
/// the common requests offline and is the fallback when the model is unavailable. Either way the
/// result is a draft that passes the contraindication check and waits for the physician to sign.
public enum ProgramReviser {
    public struct Revision: Sendable, Hashable {
        public var items: [ProgramItem]
        /// What changed, one line each, for the physician to review.
        public var changes: [String]
        public var understood: Bool
    }

    /// Exercises that serve each focus a physician might ask for.
    static let focus: [(words: [String], ids: [String], label: String)] = [
        (["hip", "glute"], ["glute-bridge", "sit-to-stand", "reverse-lunge"], "hip strength"),
        (["quad", "thigh"], ["quad-set", "straight-leg-raise", "long-arc-quad", "sit-to-stand"], "thigh strength"),
        (["knee bend", "flexion", "range"], ["heel-slide"], "knee range"),
        (["shoulder", "arm", "reach"], ["shoulder-flexion", "shoulder-abduction", "wall-slide", "scapular-squeeze"], "shoulder range"),
        (["posture", "desk", "neck"], ["scapular-squeeze", "chest-opener", "neck-shoulder-rolls"], "posture"),
        (["core", "back", "trunk"], ["glute-bridge", "plank"], "core"),
        (["balance", "function", "stairs", "standing"], ["sit-to-stand", "mini-squat", "reverse-lunge"], "standing function"),
        (["stretch", "mobility", "flexib"], ["hamstring-stretch", "hip-flexor-stretch", "chest-opener"], "mobility"),
    ]

    public static func revise(_ program: Program, instruction: String, library: ExerciseLibrary = .standard) -> Revision {
        let text = " " + instruction.lowercased() + " "
        var items = program.items
        var changes: [String] = []
        var understood = false

        func name(_ id: String) -> String { library.spec(id)?.name ?? id }
        func mentioned() -> [ExerciseSpec] {
            library.all.filter { spec in
                let n = spec.name.lowercased()
                let singular = n.hasSuffix("s") ? String(n.dropLast()) : n
                return text.contains(n) || text.contains(singular) || text.contains(spec.id.replacingOccurrences(of: "-", with: " "))
            }
        }
        func scale(_ factor: Double, verb: String) {
            items = items.map { item in
                guard let spec = library.spec(item.exerciseId) else { return item }
                var next = item
                if let reps = item.dose.reps {
                    let r = Int((Double(reps) * factor).rounded())
                    next.dose.reps = spec.limits.reps.map { r.clamped(to: $0) } ?? r
                }
                if let hold = item.dose.holdSeconds {
                    let h = Int((Double(hold) * factor).rounded())
                    next.dose.holdSeconds = spec.limits.holdSeconds.map { h.clamped(to: $0) } ?? h
                }
                if next.dose != item.dose {
                    changes.append("\(verb) \(spec.name): \(item.dose.shortDescription) → \(next.dose.shortDescription)")
                    next.source = .aiDraft
                }
                return next
            }
        }

        let removeWords = [" remove ", " drop ", " stop ", " take out ", " without ", " no more "]
        if removeWords.contains(where: text.contains) {
            for spec in mentioned() where items.contains(where: { $0.exerciseId == spec.id }) {
                items.removeAll { $0.exerciseId == spec.id }
                changes.append("Removed \(spec.name)")
                understood = true
            }
        }
        let addWords = [" add ", " include ", " introduce ", " start "]
        if addWords.contains(where: text.contains) {
            for spec in mentioned() where !items.contains(where: { $0.exerciseId == spec.id }) {
                items.append(ProgramItem(exerciseId: spec.id, dose: spec.defaultDose, rationale: "Added at the physician's request.", source: .aiDraft))
                changes.append("Added \(spec.name) (\(spec.defaultDose.shortDescription))")
                understood = true
            }
        }
        if [" gentler ", " easier ", " less ", " reduce ", " lighter ", " back off ", " flare"].contains(where: text.contains) {
            scale(0.7, verb: "Eased")
            understood = true
        } else if [" harder ", " progress", " more ", " increase ", " challenge", " step up "].contains(where: text.contains) {
            scale(1.3, verb: "Progressed")
            understood = true
        }
        for entry in focus where entry.words.contains(where: { text.contains($0) }) && text.contains("focus") {
            for id in entry.ids where !items.contains(where: { $0.exerciseId == id }) {
                guard let spec = library.spec(id) else { continue }
                items.append(ProgramItem(exerciseId: id, dose: spec.defaultDose, rationale: "Adds \(entry.label), as requested.", source: .aiDraft))
                changes.append("Added \(name(id)) for \(entry.label)")
            }
            understood = true
        }
        let (kept, blocked) = ContraindicationChecker.sanitize(items: items, precautions: program.precautions, library: library)
        changes += blocked.map { "Left out \(name($0.exerciseId)): \($0.message)" }
        return Revision(items: kept, changes: changes, understood: understood)
    }
}
