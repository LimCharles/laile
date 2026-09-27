import Foundation

/// A ready-made routine. "Snacks" are the 2–10 minute sessions for people with no time.
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

    public init(id: String, title: String, subtitle: String, minutes: Int, mode: AppMode, isSnack: Bool, items: [Item]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.minutes = minutes
        self.mode = mode
        self.isSnack = isSnack
        self.items = items
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
            ]
        ),
        SessionTemplate(
            id: "morning-mobility", title: "Morning mobility", subtitle: "Wake up stiff joints", minutes: 5, mode: .move, isSnack: true,
            items: [
                Item("deep-squat-hold", Dose(sets: 1, holdSeconds: 30, restSeconds: 10)),
                Item("hip-flexor-stretch", Dose(sets: 1, holdSeconds: 30, restSeconds: 10)),
                Item("glute-bridge", Dose(sets: 1, reps: 12, restSeconds: 15)),
                Item("hamstring-stretch", Dose(sets: 1, holdSeconds: 30, restSeconds: 10)),
                Item("chest-opener", Dose(sets: 1, holdSeconds: 30, restSeconds: 5)),
            ]
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
            ]
        ),
        SessionTemplate(
            id: "strength-10", title: "Ten-minute strength", subtitle: "The full-body basics", minutes: 10, mode: .move, isSnack: false,
            items: [
                Item("squat", Dose(sets: 3, reps: 12, restSeconds: 30)),
                Item("push-up", Dose(sets: 3, reps: 8, restSeconds: 30)),
                Item("glute-bridge", Dose(sets: 2, reps: 12, restSeconds: 20)),
                Item("plank", Dose(sets: 2, holdSeconds: 40, restSeconds: 20)),
            ]
        ),
        SessionTemplate(
            id: "move-baseline", title: "Fitness check", subtitle: "Find your starting point", minutes: 6, mode: .move, isSnack: false,
            items: [
                Item("push-up", Dose(sets: 1, reps: 50, restSeconds: 60)),
                Item("squat", Dose(sets: 1, reps: 40, restSeconds: 60)),
                Item("plank", Dose(sets: 1, holdSeconds: 180, restSeconds: 0)),
            ]
        ),
        SessionTemplate(
            id: "knee-rehab-early", title: "Knee rehab — early", subtitle: "Weeks 1–2 after knee replacement", minutes: 12, mode: .rehab, isSnack: false,
            items: [
                Item("ankle-pumps", Dose(sets: 1, holdSeconds: 45, restSeconds: 10)),
                Item("quad-set", Dose(sets: 10, holdSeconds: 5, restSeconds: 5)),
                Item("heel-slide", Dose(sets: 2, reps: 10, restSeconds: 30)),
                Item("straight-leg-raise", Dose(sets: 2, reps: 10, restSeconds: 30)),
            ]
        ),
        SessionTemplate(
            id: "knee-baseline", title: "Knee check-in", subtitle: "Measure your knee bend and straightening", minutes: 4, mode: .rehab, isSnack: false,
            items: [
                Item("quad-set", Dose(sets: 3, holdSeconds: 5, restSeconds: 5)),
                Item("heel-slide", Dose(sets: 1, reps: 5, restSeconds: 0)),
            ]
        ),
    ]

    public static func builtIn(_ id: String) -> SessionTemplate? { builtIn.first { $0.id == id } }
}
