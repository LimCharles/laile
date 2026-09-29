import Foundation

public enum ProgramCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case calisthenics, mobility, desk, recovery

    public var label: String {
        switch self {
        case .calisthenics: return "Calisthenics"
        case .mobility: return "Mobility"
        case .desk: return "Desk breaks"
        case .recovery: return "After physio"
        }
    }
}

/// A ready-made routine from the Laile catalog. Non-snack ones are programs you join (your first
/// session is a check-in that sets your targets); snacks are 2–10 minute one-offs for people with no time.
public struct SessionTemplate: Codable, Sendable, Hashable, Identifiable {
    public struct Item: Codable, Sendable, Hashable {
        public var exerciseId: String
        public var dose: Dose

        public init(_ exerciseId: String, _ dose: Dose) {
            self.exerciseId = exerciseId
            self.dose = dose
        }
    }

    public var id: String
    public var title: String
    public var subtitle: String
    public var minutes: Int
    public var mode: AppMode
    public var isSnack: Bool
    public var items: [Item]
    public var category: ProgramCategory
    /// 1 (anyone can start) … 3 (needs a base).
    public var level: Int
    public var about: String
    /// Shown in Explore. Clinician protocols and old check-ins aren't.
    public var isCatalog: Bool

    public init(id: String, title: String, subtitle: String, minutes: Int, mode: AppMode, isSnack: Bool, items: [Item],
                category: ProgramCategory = .calisthenics, level: Int = 1, about: String = "", isCatalog: Bool = true) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.minutes = minutes
        self.mode = mode
        self.isSnack = isSnack
        self.items = items
        self.category = category
        self.level = level
        self.about = about
        self.isCatalog = isCatalog
    }

    /// Programs anyone can join from Explore.
    public static var catalogPrograms: [SessionTemplate] { builtIn.filter { $0.isCatalog && !$0.isSnack } }
    /// Quick one-off sessions.
    public static var snacks: [SessionTemplate] { builtIn.filter { $0.isCatalog && $0.isSnack } }

    /// The catalog program as a `Program` (what an enrollment runs).
    public func asProgram() -> Program {
        Program(title: title, items: items.map { ProgramItem(exerciseId: $0.exerciseId, dose: $0.dose, source: .template) },
                precautions: .none, status: .signed, draftedBy: "Laile catalog", summary: about.isEmpty ? subtitle : about)
    }

    public func plan(library: ExerciseLibrary = .standard) -> [PlannedExercise] {
        items.compactMap { item in
            library.spec(item.exerciseId).map { PlannedExercise(spec: $0, dose: item.dose) }
        }
    }

    public static let builtIn: [SessionTemplate] = [
        SessionTemplate(
            id: "desk-reset", title: "Desk reset", subtitle: "Undo an hour of sitting", minutes: 2, mode: .move, isSnack: true,
            items: [
                Item("neck-shoulder-rolls", Dose(sets: 1, holdSeconds: 30, restSeconds: 5)),
                Item("chest-opener", Dose(sets: 1, holdSeconds: 30, restSeconds: 5)),
                Item("sit-to-stand", Dose(sets: 1, reps: 10, restSeconds: 10)),
            ],
            category: .desk, about: "Two minutes between meetings: neck, chest and legs."
        ),
        SessionTemplate(
            id: "morning-mobility", title: "Morning mobility", subtitle: "Wake up stiff joints", minutes: 5, mode: .move, isSnack: true,
            items: [
                Item("deep-squat-hold", Dose(sets: 1, holdSeconds: 30, restSeconds: 10)),
                Item("hip-flexor-stretch", Dose(sets: 1, holdSeconds: 30, restSeconds: 10)),
                Item("glute-bridge", Dose(sets: 1, reps: 12, restSeconds: 15)),
                Item("hamstring-stretch", Dose(sets: 1, holdSeconds: 30, restSeconds: 10)),
                Item("chest-opener", Dose(sets: 1, holdSeconds: 30, restSeconds: 5)),
            ],
            category: .mobility, about: "Hips, hamstrings and chest, gently, before the day starts."
        ),
        SessionTemplate(
            id: "lunch-blast", title: "Lunch-break blast", subtitle: "Seven minutes, no equipment", minutes: 7, mode: .move, isSnack: true,
            items: [
                Item("jumping-jacks", Dose(sets: 1, reps: 25, restSeconds: 15)),
                Item("squat", Dose(sets: 1, reps: 15, restSeconds: 15)),
                Item("knee-push-up", Dose(sets: 1, reps: 10, restSeconds: 15)),
                Item("plank", Dose(sets: 1, holdSeconds: 30, restSeconds: 15)),
                Item("reverse-lunge", Dose(sets: 1, reps: 10, restSeconds: 15)),
                Item("high-knees", Dose(sets: 1, reps: 30, restSeconds: 0)),
            ],
            category: .calisthenics, level: 2, about: "A sweaty seven minutes of the calisthenics basics."
        ),
        SessionTemplate(
            id: "strength-10", title: "Ten-minute strength", subtitle: "The full-body basics", minutes: 10, mode: .move, isSnack: false,
            items: [
                Item("squat", Dose(sets: 3, reps: 12, restSeconds: 30)),
                Item("push-up", Dose(sets: 3, reps: 8, restSeconds: 30)),
                Item("glute-bridge", Dose(sets: 2, reps: 12, restSeconds: 20)),
                Item("plank", Dose(sets: 2, holdSeconds: 40, restSeconds: 20)),
            ],
            category: .calisthenics, level: 2, about: "Squats, push-ups, bridges and planks, three times a week. Your first session sets your numbers."
        ),
        SessionTemplate(
            id: "first-push-up", title: "First push-up", subtitle: "From counter push-ups to the floor", minutes: 8, mode: .move, isSnack: false,
            items: [
                Item("incline-push-up", Dose(sets: 3, reps: 8, restSeconds: 45)),
                Item("knee-push-up", Dose(sets: 2, reps: 6, restSeconds: 45)),
                Item("plank", Dose(sets: 2, holdSeconds: 20, restSeconds: 30)),
                Item("chest-opener", Dose(sets: 1, holdSeconds: 30, restSeconds: 5)),
            ],
            category: .calisthenics, level: 1,
            about: "Three short sessions a week. The camera counts every rep and Laile moves you up a level when you're ready."
        ),
        SessionTemplate(
            id: "squat-strong", title: "Squat strong", subtitle: "Legs that carry you up any stairs", minutes: 10, mode: .move, isSnack: false,
            items: [
                Item("squat", Dose(sets: 3, reps: 12, restSeconds: 45)),
                Item("reverse-lunge", Dose(sets: 2, reps: 8, restSeconds: 45)),
                Item("wall-sit", Dose(sets: 2, holdSeconds: 30, restSeconds: 45)),
                Item("glute-bridge", Dose(sets: 2, reps: 15, restSeconds: 30)),
            ],
            category: .calisthenics, level: 2,
            about: "Squats, lunges and wall sits with depth checked by the camera. Your first session sets your targets."
        ),
        SessionTemplate(
            id: "core-foundations", title: "Core foundations", subtitle: "A back that holds up to long days", minutes: 8, mode: .move, isSnack: false,
            items: [
                Item("glute-bridge", Dose(sets: 2, reps: 12, restSeconds: 30)),
                Item("plank", Dose(sets: 3, holdSeconds: 25, restSeconds: 30)),
                Item("hip-flexor-stretch", Dose(sets: 1, holdSeconds: 30, restSeconds: 10)),
                Item("hamstring-stretch", Dose(sets: 1, holdSeconds: 30, restSeconds: 10)),
            ],
            category: .calisthenics, level: 1,
            about: "Glutes and core for anyone who sits a lot, with stretches for tight hips."
        ),
        SessionTemplate(
            id: "strong-knees", title: "Strong knees for life", subtitle: "What comes after knee physio", minutes: 10, mode: .move, isSnack: false,
            items: [
                Item("sit-to-stand", Dose(sets: 3, reps: 10, restSeconds: 30)),
                Item("glute-bridge", Dose(sets: 2, reps: 12, restSeconds: 30)),
                Item("squat", Dose(sets: 2, reps: 10, restSeconds: 45)),
                Item("reverse-lunge", Dose(sets: 2, reps: 6, restSeconds: 45)),
                Item("hamstring-stretch", Dose(sets: 1, holdSeconds: 30, restSeconds: 10)),
            ],
            category: .recovery, level: 1,
            about: "Builds on knee physio: chair stands to squats and lunges. Any limits your physio set still apply."
        ),
        SessionTemplate(
            id: "shoulder-mobility", title: "Shoulder mobility", subtitle: "Reach, lift and undo the desk hunch", minutes: 8, mode: .move, isSnack: false,
            items: [
                Item("wall-slide", Dose(sets: 2, reps: 8, restSeconds: 20)),
                Item("shoulder-flexion", Dose(sets: 2, reps: 10, restSeconds: 20)),
                Item("shoulder-abduction", Dose(sets: 2, reps: 8, restSeconds: 20)),
                Item("scapular-squeeze", Dose(sets: 8, holdSeconds: 5, restSeconds: 5)),
                Item("chest-opener", Dose(sets: 1, holdSeconds: 30, restSeconds: 5)),
            ],
            category: .mobility, level: 1,
            about: "Arm lifts measured by the camera, so you can watch your reach come back. Good after shoulder physio too."
        ),
        SessionTemplate(
            id: "move-baseline", title: "Fitness check", subtitle: "Find your starting point", minutes: 6, mode: .move, isSnack: false,
            items: [
                Item("push-up", Dose(sets: 1, reps: 50, restSeconds: 60)),
                Item("squat", Dose(sets: 1, reps: 40, restSeconds: 60)),
                Item("plank", Dose(sets: 1, holdSeconds: 180, restSeconds: 0)),
            ],
            isCatalog: false
        ),
        SessionTemplate(
            id: "knee-rehab-early", title: "Knee rehab — early", subtitle: "Weeks 1–2 after knee replacement", minutes: 12, mode: .rehab, isSnack: false,
            items: [
                Item("ankle-pumps", Dose(sets: 1, holdSeconds: 45, restSeconds: 10)),
                Item("quad-set", Dose(sets: 10, holdSeconds: 5, restSeconds: 5)),
                Item("heel-slide", Dose(sets: 2, reps: 10, restSeconds: 30)),
                Item("straight-leg-raise", Dose(sets: 2, reps: 10, restSeconds: 30)),
            ],
            category: .recovery, isCatalog: false
        ),
        SessionTemplate(
            id: "knee-baseline", title: "Knee check-in", subtitle: "Measure your knee bend and straightening", minutes: 4, mode: .rehab, isSnack: false,
            items: [
                Item("quad-set", Dose(sets: 3, holdSeconds: 5, restSeconds: 5)),
                Item("heel-slide", Dose(sets: 1, reps: 5, restSeconds: 0)),
            ],
            category: .recovery, isCatalog: false
        ),
    ]

    public static func builtIn(_ id: String) -> SessionTemplate? { builtIn.first { $0.id == id } }
}
