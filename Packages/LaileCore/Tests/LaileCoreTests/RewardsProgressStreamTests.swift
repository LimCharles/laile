import Foundation
import Testing
@testable import LaileCore

@Suite struct DayKeyTests {
    @Test func ordinalRoundTrip() {
        for ordinal in [-1000, 0, 1, 20_000, 20_724] {
            #expect(DayKey(ordinal: ordinal).ordinal == ordinal)
        }
        #expect(DayKey(year: 1970, month: 1, day: 1).ordinal == 0)
        #expect(DayKey(year: 2026, month: 3, day: 1).adding(days: -1) == DayKey(year: 2026, month: 2, day: 28))
        #expect(DayKey(year: 2026, month: 9, day: 28).isoWeekday == 1) // Monday
    }

    @Test func codableAsString() throws {
        let data = try LaileJSON.encoder().encode([DayKey(year: 2026, month: 9, day: 28)])
        #expect(String(decoding: data, as: UTF8.self) == "[\"2026-09-28\"]")
    }
}

@Suite struct RewardTests {
    let tz = TimeZone(identifier: "Asia/Singapore")!
    var engine: RewardEngine { RewardEngine(timeZone: tz) }

    func date(_ day: Int, hour: Int = 12) -> Date {
        var c = DateComponents(year: 2026, month: 9, day: day, hour: hour)
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test func dailyCheckInCycle() {
        var history: [ActivityRecord] = []
        var xps: [Int] = []
        for day in 1...8 {
            let outcome = engine.checkIn(now: date(day), history: history)
            history += outcome.records
            xps.append(outcome.records.first!.xp)
        }
        #expect(xps == [10, 15, 20, 25, 30, 40, 75, 10])
        #expect(history.contains { $0.refId == "login-7" })
        let again = engine.checkIn(now: date(8, hour: 20), history: history)
        #expect(again.alreadyCheckedIn && again.xpAwarded == 0)
    }

    @Test func missedCheckInResetsCycle() {
        var history = engine.checkIn(now: date(1), history: []).records
        history += engine.checkIn(now: date(2), history: history).records
        let outcome = engine.checkIn(now: date(4), history: history)
        #expect(outcome.dayNumber == 1)
    }

    @Test func neverMissTwiceShield() {
        // 7 straight days earns a shield; missing day 8 is covered if you move on day 9.
        var history: [ActivityRecord] = []
        for day in 1...7 { history += engine.recordMovement(kind: .snack, reps: 10, refId: nil, now: date(day), history: history).records }
        #expect(history.contains { $0.refId == "streak-7" })
        let atRisk = engine.summary(now: date(9), history: history).moveStreak
        #expect(atRisk.status == .shieldPending)
        let outcome = engine.recordMovement(kind: .session, reps: 0, refId: nil, now: date(9), history: history)
        #expect(outcome.moveStreak.current == 8)
        #expect(outcome.moveStreak.shieldsUsed == 1)
    }

    @Test func twoMissedDaysBreakStreak() {
        var history: [ActivityRecord] = []
        for day in 1...3 { history += engine.recordMovement(kind: .snack, reps: 0, refId: nil, now: date(day), history: history).records }
        let summary = engine.summary(now: date(6), history: history)
        #expect(summary.moveStreak.status == .broken)
        #expect(summary.moveStreak.current == 0)
        #expect(summary.moveStreak.best == 3)
    }

    @Test func firstMoveBonusAndBadges() {
        let outcome = engine.recordMovement(kind: .snack, reps: 120, refId: nil, now: date(1, hour: 7), history: [])
        #expect(outcome.records.contains { $0.refId?.hasPrefix("daily-goal") == true })
        let ids = Set(outcome.newBadges.map(\.id))
        #expect(ids.isSuperset(of: ["first-move", "early-bird", "reps-100"]))
        #expect(outcome.xpAwarded == 25 + 50 + 20) // snack + capped rep XP + first-move bonus
    }

    @Test func levels() {
        #expect(LevelInfo.from(totalXP: 0).level == 1)
        #expect(LevelInfo.from(totalXP: 100).level == 2)
        #expect(LevelInfo.from(totalXP: 249).level == 2)
        #expect(LevelInfo.from(totalXP: 250).level == 3)
    }

    @Test func calendarShowsTodayClaimable() {
        let history = engine.checkIn(now: date(1), history: []).records
        let summary = engine.summary(now: date(2), history: history)
        #expect(summary.dailyCalendar.map(\.state) == [.claimed, .today, .upcoming, .upcoming, .upcoming, .upcoming, .upcoming])
    }
}

@Suite struct ProgressTests {
    func samples(_ values: [Double], kind: MetricKind = .kneeFlexion) -> [MetricSample] {
        values.enumerated().map { i, v in
            MetricSample(kind: kind, value: v, date: Date(timeIntervalSince1970: Double(i) * 86_400), isBaseline: i == 0)
        }
    }

    @Test func trendMarksBaselinePBsAndMilestones() {
        let trend = ProgressAnalyzer.trend(kind: .kneeFlexion, samples: samples([62, 70, 78, 85, 91]), milestones: Milestone.rehabDefaults)
        #expect(trend.baseline?.value == 62)
        #expect(trend.improvementFromBaseline == 29)
        #expect(trend.personalBestIds.count == 4)
        #expect(trend.reachedMilestones.map(\.id) == ["knee-70", "knee-90"])
        #expect(trend.nextMilestone?.id == "knee-110")
        #expect(trend.flags.isEmpty)
    }

    @Test func plateauFlag() {
        let flags = ProgressAnalyzer.flags(kind: .kneeFlexion, samples: samples([60, 75, 84, 85, 84, 85, 86]))
        #expect(flags.contains(.plateau(kind: .kneeFlexion, sessions: 4)))
    }

    @Test func regressionFlag() {
        let flags = ProgressAnalyzer.flags(kind: .kneeFlexion, samples: samples([60, 80, 88, 78]))
        #expect(flags.contains(.regression(kind: .kneeFlexion, best: 88, latest: 78)))
    }

    @Test func lowerIsBetterMetrics() {
        let trend = ProgressAnalyzer.trend(kind: .kneeExtensionDeficit, samples: samples([15, 11, 8, 4], kind: .kneeExtensionDeficit), milestones: Milestone.rehabDefaults)
        #expect(trend.improvementFromBaseline == 11)
        #expect(trend.reachedMilestones.map(\.id) == ["ext-10", "ext-5"])
    }

    @Test func achievementsOnNewSample() {
        let history = samples([62, 70, 85])
        let new = [MetricSample(kind: .kneeFlexion, value: 92, date: Date(timeIntervalSince1970: 10 * 86_400))]
        let achievements = ProgressAnalyzer.achievements(adding: new, to: history, milestones: Milestone.rehabDefaults)
        #expect(achievements.count == 2)
        #expect(achievements.contains(.milestone(Milestone.rehabDefaults[1])))
    }
}

@Suite struct StreamTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var stream: StreamEvent {
        StreamEvent(title: "T", hostName: "H", summary: "", kind: .premiere, scheduledStart: start,
                    segments: [StreamSegment(exerciseId: "squat", durationSeconds: 60), .rest(20), StreamSegment(exerciseId: "plank", durationSeconds: 40)],
                    intensity: 2)
    }

    @Test func phases() {
        #expect(StreamClock.phase(of: stream, at: start.addingTimeInterval(-600)) == .upcoming(startsIn: 600))
        #expect(StreamClock.phase(of: stream, at: start.addingTimeInterval(-60)) == .lobby(startsIn: 60))
        if case .live(let p) = StreamClock.phase(of: stream, at: start.addingTimeInterval(70)) {
            #expect(p.segmentIndex == 1)
            #expect(p.segmentRemaining == 10)
        } else { Issue.record("expected live") }
        #expect(StreamClock.phase(of: stream, at: start.addingTimeInterval(121)) == .ended)
    }

    @Test func eligibilityUsesPrecautions() {
        let violations = StreamEligibility.violations(for: stream, precautions: Precautions(weightBearing: .none))
        #expect(violations.map(\.exerciseId) == ["squat", "plank"])
    }

    @Test func demoScheduleAlwaysHasSomethingSoon() {
        let now = Date()
        let schedule = DemoStreams.schedule(around: now)
        let soonOrLive = schedule.filter {
            switch StreamClock.phase(of: $0, at: now) {
            case .live, .lobby: return true
            case .upcoming(let s): return s < 20 * 60
            case .ended: return false
            }
        }
        #expect(!soonOrLive.isEmpty)
        #expect(Set(schedule.map(\.id)).count == schedule.count)
        #expect(schedule.allSatisfy { $0.segments.allSatisfy { $0.isRest || ExerciseLibrary.standard.spec($0.exerciseId) != nil } })
    }
}
