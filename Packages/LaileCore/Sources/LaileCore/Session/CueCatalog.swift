import Foundation

extension CueLine {
    /// File name (without extension) for this line's pre-generated audio. Derived from the
    /// text itself, so editing a line automatically invalidates its old recording.
    public var audioKey: String { "t-" + CueCatalog.fnv1a(text) }
}

/// Every line the coach can say that is known ahead of time. `generate-cues` renders all of
/// these with a high-quality TTS voice (ElevenLabs by default), so in a session nearly
/// everything plays instantly from the app bundle. Only free-form LLM replies need live TTS.
public enum CueCatalog {
    // MARK: Exercise lines

    public static func intro(_ spec: ExerciseSpec, first: Bool) -> CueLine {
        CueLine("\(first ? "First up" : "Next"): \(spec.name). \(spec.cues.purpose)", key: "ex.\(spec.id).intro")
    }

    public static func setup(_ spec: ExerciseSpec, withCameraTip: Bool) -> CueLine {
        CueLine(withCameraTip ? "\(spec.cues.setup) \(spec.posture.cameraTip)" : spec.cues.setup, key: "ex.\(spec.id).setup")
    }

    public static func go(_ spec: ExerciseSpec) -> CueLine {
        CueLine("Perfect, I can see you. \(spec.cues.go)", key: "ex.\(spec.id).go")
    }

    public static func form(_ check: FormCheck) -> CueLine { CueLine(check.cue, key: "form.\(check.id)") }

    public static func correction(_ text: String) -> CueLine { CueLine(text, key: "correction") }

    public static func rest(seconds: Int) -> CueLine {
        CueLine("Nice. Rest for \(seconds) seconds.", key: "rest.\(seconds)")
    }

    public static func seconds(_ n: Int) -> CueLine { CueLine("\(n) seconds", key: "sec.\(n)", priority: .low) }

    public static let further = CueLine("A little further if it's comfortable.", key: "cue.further")

    // MARK: Setup

    public static func missing(_ parts: [BodyPart]) -> CueLine {
        if parts.count == 1, let part = parts.first {
            return CueLine("I can't see your \(part.spokenName). Move the phone back a little, or shift so it's in view.", key: "setup.missing.\(part.rawValue)")
        }
        return CueLine("I can't see all of the joints I need. Move the phone back a little so your whole body is in view.", key: "setup.missing.several")
    }

    // MARK: Streams

    public static let streamWelcome = CueLine("Welcome in! I'll count your reps with the camera.", key: "stream.welcome")

    public static func streamSegment(_ spec: ExerciseSpec, seconds: Int, coachLine: String?) -> CueLine {
        CueLine("\(spec.name), \(seconds) seconds. \(coachLine ?? spec.cues.go)", key: "stream.segment")
    }

    public static func streamRest(next: ExerciseSpec?) -> CueLine {
        CueLine(next.map { "Rest. Next up: \($0.name)." } ?? "Rest.", key: "stream.rest")
    }

    public static let medicationReferral = CueLine(MedicationBoundary.referral, key: "med.referral", priority: .high)

    // MARK: Everything

    /// All pre-generatable lines, de-duplicated by audio key.
    public static func all(library: ExerciseLibrary = .standard, emergencyNumber: String = "995") -> [CueLine] {
        var lines: [CueLine] = []
        lines += (0...60).map(CueLine.count)
        lines += [.go, .holdIt, .relax, .niceWork, .rest, .sessionDone, .cantSee, .paused, further, streamWelcome, medicationReferral]
        lines += SymptomResponses.all + [SymptomResponses.emergency(number: emergencyNumber)]
        lines += [SetupIssue.noPerson, .tooClose, .tooFar, .offCenter, .needSideView, .needFrontView].map(\.guidance)
        lines += BodyPart.allCases.map { missing([$0]) } + [missing([.hip, .knee])]
        lines += stride(from: 5, through: 120, by: 5).map { rest(seconds: $0) }
        lines += stride(from: 35, through: 180, by: 5).map { seconds($0) }
        for spec in library.all {
            lines += [intro(spec, first: true), intro(spec, first: false), setup(spec, withCameraTip: true), setup(spec, withCameraTip: false), go(spec)]
            lines += spec.formChecks.map(form)
            if case .hold(let rule) = spec.kind, let text = rule.correction { lines.append(correction(text)) }
        }
        for stream in DemoStreams.schedule(around: Date(timeIntervalSince1970: 0)) {
            for (i, segment) in stream.segments.enumerated() {
                if segment.isRest {
                    let next = stream.segments.dropFirst(i + 1).first.flatMap { library.spec($0.exerciseId) }
                    lines.append(streamRest(next: next))
                } else if let spec = library.spec(segment.exerciseId) {
                    lines.append(streamSegment(spec, seconds: segment.durationSeconds, coachLine: segment.coachLine))
                }
            }
        }
        var seen = Set<String>()
        return lines.filter { seen.insert($0.audioKey).inserted }
    }

    /// 64-bit FNV-1a, hex. Stable across platforms and runs (unlike `hashValue`).
    public static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
