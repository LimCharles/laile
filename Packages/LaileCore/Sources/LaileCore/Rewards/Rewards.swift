import Foundation

public enum ActivityKind: String, Codable, Sendable, CaseIterable, Hashable {
    case checkIn, session, snack, stretch, stream, baseline, bonus, medication

    public var isMovement: Bool {
        switch self {
        case .session, .snack, .stretch, .stream, .baseline: return true
        case .checkIn, .bonus, .medication: return false
        }
    }
}

/// One line in the rewards ledger. XP totals, streaks and badges are all derived from the
/// ledger, so the server and the on-device demo backend compute identical results.
public struct ActivityRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var day: DayKey
    public var kind: ActivityKind
    public var xp: Int
    public var at: Date
    public var reps: Int
    public var refId: String?
    public var note: String?

    public init(id: UUID = UUID(), day: DayKey, kind: ActivityKind, xp: Int, at: Date, reps: Int = 0, refId: String? = nil, note: String? = nil) {
        self.id = id
        self.day = day
        self.kind = kind
        self.xp = xp
        self.at = at
        self.reps = reps
        self.refId = refId
        self.note = note
    }
}

public struct RewardRules: Codable, Sendable, Hashable {
    /// XP for day 1…7 of the daily check-in calendar.
    public var checkInCycleXP: [Int]
    public var sessionXP: Int
    public var snackXP: Int
    public var stretchXP: Int
    public var streamXP: Int
    public var baselineXP: Int
    public var firstMoveOfDayBonus: Int
    public var xpPerVerifiedRep: Int
    public var repXPCap: Int
    public var streakMilestones: [Int: Int]
    public var loginMilestones: [Int: Int]
    /// "Never miss twice": a shield is earned every N streak days and quietly covers one missed day.
    public var shieldEveryDays: Int
    public var maxShields: Int

    public static let standard = RewardRules(
        checkInCycleXP: [10, 15, 20, 25, 30, 40, 75],
        sessionXP: 50, snackXP: 25, stretchXP: 15, streamXP: 60, baselineXP: 40,
        firstMoveOfDayBonus: 20, xpPerVerifiedRep: 1, repXPCap: 50,
        streakMilestones: [3: 30, 7: 100, 14: 150, 30: 300, 60: 500, 100: 1000],
        loginMilestones: [7: 50, 30: 200],
        shieldEveryDays: 7, maxShields: 2
    )

    public func baseXP(for kind: ActivityKind) -> Int {
        switch kind {
        case .session: return sessionXP
        case .snack: return snackXP
        case .stretch: return stretchXP
        case .stream: return streamXP
        case .baseline: return baselineXP
        case .checkIn, .bonus, .medication: return 0
        }
    }
}

public enum StreakStatus: String, Codable, Sendable, Hashable {
    /// Already done today.
    case activeToday
    /// Streak alive; do something today to extend it.
    case pendingToday
    /// Missed yesterday, but a shield will cover it if you move today.
    case shieldPending
    case broken
    case none
}

public struct StreakState: Codable, Sendable, Hashable {
    public var current: Int
    public var best: Int
    public var shields: Int
    public var shieldsUsed: Int
    public var lastActiveDay: DayKey?
    public var status: StreakStatus

    public static let empty = StreakState(current: 0, best: 0, shields: 0, shieldsUsed: 0, lastActiveDay: nil, status: .none)
}

public enum StreakCalculator {
    public static func streak(days input: Set<DayKey>, today: DayKey, shieldEvery: Int, maxShields: Int) -> StreakState {
        let days = input.filter { $0 <= today }.sorted()
        guard !days.isEmpty else { return .empty }
        var current = 0, best = 0, shields = 0, used = 0
        var last: DayKey?
        for day in days {
            if let previous = last {
                let gap = previous.days(until: day)
                if gap == 1 {
                    current += 1
                } else if gap == 2 && shields > 0 {
                    shields -= 1
                    used += 1
                    current += 1
                } else {
                    current = 1
                    shields = 0
                }
            } else {
                current = 1
            }
            if maxShields > 0, current % shieldEvery == 0 { shields = min(maxShields, shields + 1) }
            best = max(best, current)
            last = day
        }
        let gap = last!.days(until: today)
        let status: StreakStatus
        switch gap {
        case 0: status = .activeToday
        case 1: status = .pendingToday
        case 2 where shields > 0: status = .shieldPending
        default: status = .broken
        }
        return StreakState(current: status == .broken ? 0 : current, best: best, shields: status == .broken ? 0 : shields,
                           shieldsUsed: used, lastActiveDay: last, status: status)
    }
}

public struct LevelInfo: Codable, Sendable, Hashable {
    public var level: Int
    public var totalXP: Int
    public var xpIntoLevel: Int
    public var xpForNextLevel: Int

    public var progress: Double { xpForNextLevel > 0 ? Double(xpIntoLevel) / Double(xpForNextLevel) : 0 }

    /// Level n → n+1 costs 100 + 50·(n−1) XP.
    public static func from(totalXP: Int) -> LevelInfo {
        var level = 1
        var remaining = max(0, totalXP)
        var cost = 100
        while remaining >= cost {
            remaining -= cost
            level += 1
            cost = 100 + 50 * (level - 1)
        }
        return LevelInfo(level: level, totalXP: totalXP, xpIntoLevel: remaining, xpForNextLevel: cost)
    }
}

public struct DailyRewardSlot: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable, Hashable { case claimed, today, upcoming }
    public var dayNumber: Int
    public var xp: Int
    public var state: State
    public var id: Int { dayNumber }
}

public struct Badge: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    /// SF Symbol name.
    public var symbol: String
}

public struct BadgeStatus: Codable, Sendable, Hashable, Identifiable {
    public var badge: Badge
    public var earnedOn: DayKey?
    public var id: String { badge.id }
    public var isEarned: Bool { earnedOn != nil }
}

public struct RewardsSummary: Codable, Sendable, Hashable {
    public var level: LevelInfo
    public var loginStreak: StreakState
    public var moveStreak: StreakState
    public var checkedInToday: Bool
    public var movedToday: Bool
    public var todayXP: Int
    public var dailyCalendar: [DailyRewardSlot]
    public var badges: [BadgeStatus]
}

public struct CheckInOutcome: Codable, Sendable, Hashable {
    public var alreadyCheckedIn: Bool
    public var xpAwarded: Int
    public var dayNumber: Int
    public var loginStreak: Int
    public var records: [ActivityRecord]
    public var newBadges: [Badge]
}

public struct MovementOutcome: Codable, Sendable, Hashable {
    public var records: [ActivityRecord]
    public var xpAwarded: Int
    public var moveStreak: StreakState
    public var streakMilestone: Int?
    public var newBadges: [Badge]
}

public enum BadgeCatalog {
    public static let all: [Badge] = [
        Badge(id: "first-move", title: "First step", detail: "Finish your first session", symbol: "figure.walk"),
        Badge(id: "login-7", title: "Seven-day regular", detail: "Check in 7 days in a row", symbol: "calendar.badge.checkmark"),
        Badge(id: "streak-7", title: "Week warrior", detail: "Move 7 days in a row", symbol: "flame.fill"),
        Badge(id: "streak-30", title: "Habit locked", detail: "Move 30 days in a row", symbol: "flame.circle.fill"),
        Badge(id: "snack-10", title: "Snack attack", detail: "Finish 10 quick snacks", symbol: "bolt.fill"),
        Badge(id: "stream-1", title: "Better together", detail: "Join a live stream", symbol: "person.3.fill"),
        Badge(id: "reps-100", title: "Centurion", detail: "100 camera-verified reps", symbol: "100.circle.fill"),
        Badge(id: "reps-1000", title: "Thousand club", detail: "1,000 camera-verified reps", symbol: "trophy.fill"),
        Badge(id: "baseline-1", title: "Know your numbers", detail: "Complete a baseline check", symbol: "ruler.fill"),
        Badge(id: "pb-1", title: "Personal best", detail: "Beat one of your own records", symbol: "chart.line.uptrend.xyaxis"),
        Badge(id: "early-bird", title: "Early bird", detail: "Move before 8am", symbol: "sunrise.fill"),
    ]

    public static func badge(_ id: String) -> Badge? { all.first { $0.id == id } }

    /// Day each badge was first earned, derived from the ledger.
    public static func earned(history: [ActivityRecord], timeZone: TimeZone) -> [String: DayKey] {
        var earned: [String: DayKey] = [:]
        func mark(_ id: String, _ day: DayKey) { if earned[id] == nil { earned[id] = day } }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var snacks = 0, reps = 0
        for record in history.sorted(by: { $0.at < $1.at }) {
            if record.kind.isMovement {
                mark("first-move", record.day)
                if calendar.component(.hour, from: record.at) < 8 { mark("early-bird", record.day) }
            }
            switch record.kind {
            case .snack:
                snacks += 1
                if snacks >= 10 { mark("snack-10", record.day) }
            case .stream: mark("stream-1", record.day)
            case .baseline: mark("baseline-1", record.day)
            case .bonus:
                if let ref = record.refId {
                    if ref == "streak-7" { mark("streak-7", record.day) }
                    if ref == "streak-30" { mark("streak-30", record.day) }
                    if ref == "login-7" { mark("login-7", record.day) }
                    if ref.hasPrefix("pb") { mark("pb-1", record.day) }
                }
            default: break
            }
            reps += record.reps
            if reps >= 100 { mark("reps-100", record.day) }
            if reps >= 1000 { mark("reps-1000", record.day) }
        }
        return earned
    }
}

public struct RewardEngine: Sendable {
    public var rules: RewardRules
    public var timeZone: TimeZone

    public init(rules: RewardRules = .standard, timeZone: TimeZone) {
        self.rules = rules
        self.timeZone = timeZone
    }

    public func today(_ now: Date) -> DayKey { DayKey(now, timeZone: timeZone) }

    public func checkIn(now: Date, history: [ActivityRecord]) -> CheckInOutcome {
        let today = today(now)
        let checkInDays = Set(history.filter { $0.kind == .checkIn }.map(\.day))
        let before = StreakCalculator.streak(days: checkInDays, today: today, shieldEvery: 1, maxShields: 0)
        if checkInDays.contains(today) {
            return CheckInOutcome(alreadyCheckedIn: true, xpAwarded: 0, dayNumber: cycleDay(for: before.current),
                                  loginStreak: before.current, records: [], newBadges: [])
        }
        let newStreak = before.status == .pendingToday ? before.current + 1 : 1
        let dayNumber = cycleDay(for: newStreak)
        var records = [ActivityRecord(day: today, kind: .checkIn, xp: rules.checkInCycleXP[dayNumber - 1], at: now, note: "Day \(dayNumber) reward")]
        if let bonus = rules.loginMilestones[newStreak], !history.contains(where: { $0.refId == "login-\(newStreak)" }) {
            records.append(ActivityRecord(day: today, kind: .bonus, xp: bonus, at: now, refId: "login-\(newStreak)", note: "\(newStreak)-day check-in streak"))
        }
        return CheckInOutcome(alreadyCheckedIn: false, xpAwarded: records.reduce(0) { $0 + $1.xp }, dayNumber: dayNumber,
                              loginStreak: newStreak, records: records, newBadges: newBadges(history: history, adding: records))
    }

    public func recordMovement(kind: ActivityKind, reps: Int, refId: String?, now: Date, history: [ActivityRecord], extraBonuses: [ActivityRecord] = []) -> MovementOutcome {
        precondition(kind.isMovement, "recordMovement needs a movement kind")
        let today = today(now)
        let repXP = min(rules.repXPCap, reps * rules.xpPerVerifiedRep)
        var records = [ActivityRecord(day: today, kind: kind, xp: rules.baseXP(for: kind) + repXP, at: now, reps: reps, refId: refId)]

        let movedToday = history.contains { $0.kind.isMovement && $0.day == today }
        if !movedToday {
            records.append(ActivityRecord(day: today, kind: .bonus, xp: rules.firstMoveOfDayBonus, at: now, refId: "daily-goal-\(today)", note: "First move of the day"))
        }

        let activeBefore = Set(history.filter { $0.kind.isMovement }.map(\.day))
        let before = StreakCalculator.streak(days: activeBefore, today: today, shieldEvery: rules.shieldEveryDays, maxShields: rules.maxShields)
        let after = StreakCalculator.streak(days: activeBefore.union([today]), today: today, shieldEvery: rules.shieldEveryDays, maxShields: rules.maxShields)

        var milestoneHit: Int?
        for (milestone, bonus) in rules.streakMilestones.sorted(by: { $0.key < $1.key })
        where before.current < milestone && after.current >= milestone && !history.contains(where: { $0.refId == "streak-\(milestone)" }) {
            milestoneHit = milestone
            records.append(ActivityRecord(day: today, kind: .bonus, xp: bonus, at: now, refId: "streak-\(milestone)", note: "\(milestone)-day move streak"))
        }
        records += extraBonuses
        return MovementOutcome(records: records, xpAwarded: records.reduce(0) { $0 + $1.xp }, moveStreak: after,
                               streakMilestone: milestoneHit, newBadges: newBadges(history: history, adding: records))
    }

    public func summary(now: Date, history: [ActivityRecord]) -> RewardsSummary {
        let today = today(now)
        let checkInDays = Set(history.filter { $0.kind == .checkIn }.map(\.day))
        let activeDays = Set(history.filter { $0.kind.isMovement }.map(\.day))
        let login = StreakCalculator.streak(days: checkInDays, today: today, shieldEvery: 1, maxShields: 0)
        let move = StreakCalculator.streak(days: activeDays, today: today, shieldEvery: rules.shieldEveryDays, maxShields: rules.maxShields)
        let checkedIn = checkInDays.contains(today)

        let cycleDayToday = checkedIn ? cycleDay(for: login.current) : cycleDay(for: login.status == .pendingToday ? login.current + 1 : 1)
        let calendar = (1...7).map { n -> DailyRewardSlot in
            let state: DailyRewardSlot.State
            if n < cycleDayToday || (n == cycleDayToday && checkedIn) { state = .claimed } else if n == cycleDayToday { state = .today } else { state = .upcoming }
            return DailyRewardSlot(dayNumber: n, xp: rules.checkInCycleXP[n - 1], state: state)
        }

        let earned = BadgeCatalog.earned(history: history, timeZone: timeZone)
        return RewardsSummary(
            level: LevelInfo.from(totalXP: history.reduce(0) { $0 + $1.xp }),
            loginStreak: login,
            moveStreak: move,
            checkedInToday: checkedIn,
            movedToday: activeDays.contains(today),
            todayXP: history.filter { $0.day == today }.reduce(0) { $0 + $1.xp },
            dailyCalendar: calendar,
            badges: BadgeCatalog.all.map { BadgeStatus(badge: $0, earnedOn: earned[$0.id]) }
        )
    }

    func cycleDay(for streak: Int) -> Int { streak <= 0 ? 1 : ((streak - 1) % rules.checkInCycleXP.count) + 1 }

    func newBadges(history: [ActivityRecord], adding records: [ActivityRecord]) -> [Badge] {
        let before = BadgeCatalog.earned(history: history, timeZone: timeZone)
        let after = BadgeCatalog.earned(history: history + records, timeZone: timeZone)
        return BadgeCatalog.all.filter { after[$0.id] != nil && before[$0.id] == nil }
    }
}
