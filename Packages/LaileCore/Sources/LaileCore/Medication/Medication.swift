import Foundation

public struct TimeOfDay: Codable, Sendable, Hashable, Comparable {
    public var hour: Int
    public var minute: Int

    public init(_ hour: Int, _ minute: Int = 0) {
        self.hour = hour
        self.minute = minute
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    public var label: String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", h12, minute, hour < 12 ? "am" : "pm")
    }
}

/// A medication exactly as the clinician entered it. The app explains and reminds; it never
/// suggests changing anything about it.
public struct Medication: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// As prescribed, e.g. "1 tablet". Displayed verbatim, never computed.
    public var doseText: String
    /// Plain-language purpose, e.g. "Prevents blood clots after surgery".
    public var purpose: String
    /// e.g. "Take with food."
    public var howToTake: String
    public var times: [TimeOfDay]
    public var prescribedBy: String
    public var endsOn: DayKey?

    public init(id: UUID = UUID(), name: String, doseText: String, purpose: String, howToTake: String, times: [TimeOfDay],
                prescribedBy: String, endsOn: DayKey? = nil) {
        self.id = id
        self.name = name
        self.doseText = doseText
        self.purpose = purpose
        self.howToTake = howToTake
        self.times = times
        self.prescribedBy = prescribedBy
        self.endsOn = endsOn
    }
}

public struct MedicationLogEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var medicationId: UUID
    public var day: DayKey
    public var scheduled: TimeOfDay
    public var takenAt: Date

    public init(id: UUID = UUID(), medicationId: UUID, day: DayKey, scheduled: TimeOfDay, takenAt: Date) {
        self.id = id
        self.medicationId = medicationId
        self.day = day
        self.scheduled = scheduled
        self.takenAt = takenAt
    }
}

public struct MedicationDose: Codable, Sendable, Hashable, Identifiable {
    public var medication: Medication
    public var scheduled: TimeOfDay
    public var taken: Bool
    public var id: String { "\(medication.id)-\(scheduled.hour)-\(scheduled.minute)" }
}

public enum MedicationSchedule {
    public static func doses(for medications: [Medication], on day: DayKey, log: [MedicationLogEntry]) -> [MedicationDose] {
        medications
            .filter { med in med.endsOn.map { day <= $0 } ?? true }
            .flatMap { med in
                med.times.map { time in
                    MedicationDose(medication: med, scheduled: time,
                                   taken: log.contains { $0.medicationId == med.id && $0.day == day && $0.scheduled == time })
                }
            }
            .sorted { $0.scheduled < $1.scheduled }
    }
}
