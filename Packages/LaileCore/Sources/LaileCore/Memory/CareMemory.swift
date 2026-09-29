import Foundation

/// Something Lele remembers about a person: what was sore or felt wrong during an exercise,
/// or a note from their clinician. The person sees it, their clinician sees it, and it eases
/// that exercise next time. Plain code, not the model, decides every adjustment.
public struct CareNote: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        /// Pain or soreness during a particular exercise.
        case soreSpot
        /// Clicking, giving way, numbness or tingling during a particular exercise.
        case feelsWrong
        /// Written by the clinician, for the patient and Lele to follow.
        case clinicianNote

        public var label: String {
            switch self {
            case .soreSpot: return "Sore spot"
            case .feelsWrong: return "Felt wrong"
            case .clinicianNote: return "Clinician note"
            }
        }
    }

    public enum Source: String, Codable, Sendable, Hashable {
        /// Recorded from what was said or tapped during a session.
        case session
        /// Noted by Lele in conversation.
        case lele
        case clinician
    }

    public enum Status: String, Codable, Sendable, Hashable {
        case active, resolved
    }

    /// One line in the note's history.
    public struct Event: Codable, Sendable, Hashable {
        public var date: Date
        public var text: String

        public init(date: Date, text: String) {
            self.date = date
            self.text = text
        }
    }

    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var kind: Kind
    public var source: Source
    public var status: Status
    public var exerciseId: String?
    public var bodyLocation: String?
    public var side: Side?
    /// Worst rating (0–10) while the note has been open.
    public var severity: Int?
    /// Clinical one-liner, or the clinician's own words.
    public var text: String
    /// What the person said, word for word, most recent first.
    public var quote: String?
    public var adjustment: ExerciseAdjustment?
    /// Comfortable sessions of this exercise since the adjustment last changed.
    public var comfortableSessions: Int
    /// Clinician's name, for clinician notes.
    public var author: String?
    public var events: [Event]

    public init(id: UUID = UUID(), createdAt: Date, kind: Kind, source: Source, exerciseId: String? = nil,
                bodyLocation: String? = nil, side: Side? = nil, severity: Int? = nil, text: String, quote: String? = nil,
                adjustment: ExerciseAdjustment? = nil, author: String? = nil, events: [Event] = []) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.kind = kind
        self.source = source
        self.status = .active
        self.exerciseId = exerciseId
        self.bodyLocation = bodyLocation
        self.side = side
        self.severity = severity
        self.text = text
        self.quote = quote
        self.adjustment = adjustment
        self.comfortableSessions = 0
        self.author = author
        self.events = events
    }

    public var isActive: Bool { status == .active }

    public var exerciseName: String? {
        exerciseId.map { ExerciseLibrary.standard.spec($0)?.name ?? $0 }
    }

    /// True while this note is making an exercise easier.
    public var isEasing: Bool { isActive && !(adjustment?.isNeutral ?? true) }

    /// "on the inside of your right knee" / "in your wrist" / nil.
    public var whereText: String? {
        guard let location = bodyLocation?.trimmingCharacters(in: .whitespaces), !location.isEmpty else { return nil }
        let sided = side.map { "\($0.rawValue) " } ?? ""
        if let range = location.range(of: " of ") {
            return "on the \(location[..<range.upperBound])your \(sided)\(location[range.upperBound...])"
        }
        return "in your \(sided)\(location)"
    }

    /// Plain-language headline for the person, e.g. "Sore on the inside of your right knee".
    public var plainSummary: String {
        switch kind {
        case .clinicianNote:
            return text
        case .soreSpot, .feelsWrong:
            let what = kind == .feelsWrong ? "Felt wrong" : "Sore"
            let place = whereText.map { " \($0)" } ?? ""
            let rating = severity.map { " (\($0)/10)" } ?? ""
            return what + place + rating
        }
    }

    /// One line for Lele's context and the pre-visit report.
    public var contextLine: String {
        var parts = [exerciseName.map { "\($0): " } ?? "", kind == .clinicianNote ? "Clinician (\(author ?? "care team")): \(text)" : text]
        if let adjustment, !adjustment.isNeutral, let spec = exerciseId.flatMap({ ExerciseLibrary.standard.spec($0) }) {
            parts.append(" — eased (\(adjustment.summary(for: spec)))\(adjustment.keptByClinician ? ", kept by clinician" : "")")
        }
        if status == .resolved { parts.append(" — resolved") }
        return parts.joined()
    }
}

/// How much easier an exercise is made after a sore spot.
public struct ExerciseAdjustment: Codable, Sendable, Hashable {
    /// Degrees the rep target moves back towards the start position: a smaller range counts as a rep.
    public var rangeEase: Double
    /// Holds last this fraction of the planned time (1 = unchanged).
    public var holdScale: Double
    /// The clinician asked to keep this until they change it, so Lele won't ease it back.
    public var keptByClinician: Bool

    public init(rangeEase: Double, holdScale: Double, keptByClinician: Bool = false) {
        self.rangeEase = rangeEase
        self.holdScale = holdScale
        self.keptByClinician = keptByClinician
    }

    public static let neutral = ExerciseAdjustment(rangeEase: 0, holdScale: 1)

    public var isNeutral: Bool { rangeEase < 0.5 && holdScale > 0.99 }

    /// e.g. "15° less knee bend needed" / "holds 60% as long".
    public func summary(for spec: ExerciseSpec) -> String {
        if spec.kind.isHold {
            return "holds \(Int((holdScale * 100).rounded()))% as long"
        }
        let degrees = Int(rangeEase.rounded())
        return spec.tracksKneeFlexion ? "\(degrees)° less knee bend needed" : "\(degrees)° smaller range"
    }
}

public enum CareMemory {
    /// Comfortable sessions of an exercise in a row before Lele eases it back a step.
    public static let comfortableSessionsPerStep = 2
    public static let rangeStep: Double = 5
    public static let holdStep = 0.15
    static let maxRangeEase: Double = 25
    static let minHoldScale = 0.5
    /// Pain rated below this is kept in the session record but doesn't change the exercise.
    public static let minimumPainToEase = 3

    /// How much to ease an exercise for a remark, or nil when it shouldn't change anything.
    public static func easing(for report: SymptomReport) -> (kind: CareNote.Kind, adjustment: ExerciseAdjustment)? {
        switch report.category {
        case .wrongSensation:
            return (.feelsWrong, ExerciseAdjustment(rangeEase: 15, holdScale: 0.6))
        case .pain:
            let severity = report.severity ?? 5
            guard severity >= minimumPainToEase else { return nil }
            return (.soreSpot, severity >= 6 ? ExerciseAdjustment(rangeEase: 15, holdScale: 0.6)
                                             : ExerciseAdjustment(rangeEase: 10, holdScale: 0.75))
        case .expectedStretch:
            // Only a stretch rated as properly painful.
            guard let severity = report.severity, severity >= 5 else { return nil }
            return (.soreSpot, ExerciseAdjustment(rangeEase: 5, holdScale: 0.85))
        case .normal, .effort, .ambiguous, .redFlag:
            return nil
        }
    }

    /// Updates Lele's notes after a finished session: new or recurring sore spots ease their
    /// exercise, and exercises done comfortably ease back towards normal a step at a time.
    /// Returns only the notes that changed (new ones included).
    public static func update(_ notes: [CareNote], after summary: SessionSummary, library: ExerciseLibrary = .standard) -> [CareNote] {
        var working = notes
        var changed = Set<UUID>()
        var soreThisSession = Set<String>()

        for report in summary.symptoms {
            guard let exerciseId = report.exerciseId, let spec = library.spec(exerciseId),
                  case let (kind, ease)? = easing(for: report) else { continue }
            soreThisSession.insert(exerciseId)
            let date = report.timestamp
            if let i = working.firstIndex(where: { $0.isActive && $0.exerciseId == exerciseId && $0.kind != .clinicianNote }) {
                var note = working[i]
                note.kind = (kind == .feelsWrong || note.kind == .feelsWrong) ? .feelsWrong : .soreSpot
                note.severity = [note.severity, report.severity].compactMap { $0 }.max()
                note.bodyLocation = report.bodyLocation ?? note.bodyLocation
                note.side = report.side ?? note.side
                note.text = report.clinicalSummary
                note.quote = report.utterance
                note.adjustment = eased(note.adjustment ?? .neutral, towards: ease)
                note.comfortableSessions = 0
                note.updatedAt = date
                note.events.append(.init(date: date, text: "\(kind == .feelsWrong ? "Felt wrong" : "Sore") again during \(spec.name.lowercased()) (\(report.clinicalSummary)). Eased a little more: \(note.adjustment!.summary(for: spec))."))
                working[i] = note
                changed.insert(note.id)
            } else {
                var note = CareNote(createdAt: date, kind: kind, source: .session, exerciseId: exerciseId,
                                    bodyLocation: report.bodyLocation, side: report.side, severity: report.severity,
                                    text: report.clinicalSummary, quote: report.utterance, adjustment: ease)
                note.events = [.init(date: date, text: "Noted: \(report.clinicalSummary). Next time: \(ease.summary(for: spec)).")]
                working.append(note)
                changed.insert(note.id)
            }
        }

        let doneComfortably = Set(summary.exercises.filter { $0.completedSets > 0 && $0.stopReason == nil }.map(\.exerciseId))
        for i in working.indices {
            var note = working[i]
            guard note.isEasing, let exerciseId = note.exerciseId, let adjustment = note.adjustment, !adjustment.keptByClinician,
                  doneComfortably.contains(exerciseId), !soreThisSession.contains(exerciseId),
                  let spec = library.spec(exerciseId) else { continue }
            note.comfortableSessions += 1
            note.updatedAt = summary.endedAt
            if note.comfortableSessions >= comfortableSessionsPerStep {
                let next = steppedBack(adjustment)
                note.comfortableSessions = 0
                if next.isNeutral {
                    note.adjustment = nil
                    note.status = .resolved
                    note.events.append(.init(date: summary.endedAt, text: "Comfortable again: back to the full \(spec.name.lowercased())."))
                } else {
                    note.adjustment = next
                    note.events.append(.init(date: summary.endedAt, text: "\(comfortableSessionsPerStep) comfortable sessions in a row. Eased back towards normal: now \(next.summary(for: spec))."))
                }
            }
            working[i] = note
            changed.insert(note.id)
        }
        return working.filter { changed.contains($0.id) }
    }

    static func eased(_ current: ExerciseAdjustment, towards new: ExerciseAdjustment) -> ExerciseAdjustment {
        var result = current
        if current.isNeutral {
            result.rangeEase = new.rangeEase
            result.holdScale = new.holdScale
        } else {
            result.rangeEase = min(maxRangeEase, max(current.rangeEase + rangeStep, new.rangeEase))
            result.holdScale = max(minHoldScale, min(current.holdScale - holdStep, new.holdScale))
        }
        result.holdScale = (result.holdScale * 100).rounded() / 100
        return result
    }

    static func steppedBack(_ adjustment: ExerciseAdjustment) -> ExerciseAdjustment {
        var result = adjustment
        result.rangeEase = max(0, adjustment.rangeEase - rangeStep)
        result.holdScale = min(1, ((adjustment.holdScale + holdStep) * 100).rounded() / 100)
        return result
    }

    /// Applies active notes to a session plan: easier targets and shorter holds, plus a line
    /// Lele says when introducing the exercise. The eased range never drops below half the
    /// normal range, and holds never go below the exercise's minimum.
    public static func adjust(_ plan: [PlannedExercise], notes: [CareNote]) -> [PlannedExercise] {
        plan.map { planned in
            guard let note = notes.first(where: { $0.isEasing && $0.exerciseId == planned.spec.id }),
                  let adjustment = note.adjustment else { return planned }
            var eased = planned
            switch planned.spec.kind {
            case .reps:
                if adjustment.rangeEase > 0, let rule = planned.repRule {
                    let range = rule.start - rule.target
                    let ease = min(adjustment.rangeEase, abs(range) / 2)
                    eased.repTargetOverride = rule.target + (range > 0 ? ease : -ease)
                }
            case .hold:
                if adjustment.holdScale < 1, let hold = planned.dose.holdSeconds {
                    let floor = planned.spec.limits.holdSeconds?.lowerBound ?? 1
                    eased.dose.holdSeconds = max(floor, Int((Double(hold) * adjustment.holdScale).rounded()))
                }
            }
            eased.careCue = cue(for: note)
            return eased
        }
    }

    /// Spoken right after the exercise is introduced, so "this one" is clear.
    public static func cue(for note: CareNote) -> CueLine {
        let what: String
        switch note.kind {
        case .feelsWrong: what = "something felt wrong with this one"
        case .soreSpot, .clinicianNote: what = "this one was sore" + (note.whereText.map { " \($0)" } ?? "")
        }
        return CueLine("Last time \(what), so I've made it a little easier today. Tell me how it feels.", key: "care.\(note.id.uuidString.prefix(8))", priority: .normal)
    }

    /// Resolves a note because the person says it feels better (unless the clinician is keeping it).
    public static func markBetter(_ note: CareNote, at date: Date) -> CareNote? {
        guard note.isActive, note.kind != .clinicianNote, !(note.adjustment?.keptByClinician ?? false) else { return nil }
        var resolved = note
        resolved.status = .resolved
        resolved.adjustment = nil
        resolved.updatedAt = date
        resolved.events.append(.init(date: date, text: "You said it feels better, so it's back to normal."))
        return resolved
    }
}
