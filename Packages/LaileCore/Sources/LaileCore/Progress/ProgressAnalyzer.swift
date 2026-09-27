import Foundation

public enum ProgressFlag: Codable, Sendable, Hashable {
    /// No meaningful improvement over the last `sessions` samples.
    case plateau(kind: MetricKind, sessions: Int)
    /// Latest value fell well below the best recorded value.
    case regression(kind: MetricKind, best: Double, latest: Double)

    public var kind: MetricKind {
        switch self {
        case .plateau(let kind, _), .regression(let kind, _, _): return kind
        }
    }

    public var message: String {
        switch self {
        case .plateau(let kind, let sessions):
            return "\(kind.displayName) hasn't improved over the last \(sessions) sessions."
        case .regression(let kind, let best, let latest):
            return "\(kind.displayName) dropped from \(kind.format(best)) to \(kind.format(latest))."
        }
    }
}

public enum Achievement: Codable, Sendable, Hashable {
    case personalBest(kind: MetricKind, value: Double, previous: Double?)
    case milestone(Milestone)

    public var title: String {
        switch self {
        case .personalBest(let kind, let value, _):
            return "New best: \(kind.displayName) \(kind.format(value))"
        case .milestone(let milestone):
            return milestone.title
        }
    }
}

public struct MetricTrend: Codable, Sendable, Hashable {
    public var kind: MetricKind
    public var samples: [MetricSample]
    public var baseline: MetricSample?
    public var latest: MetricSample?
    public var best: MetricSample?
    public var personalBestIds: [UUID]
    public var reachedMilestones: [Milestone]
    public var nextMilestone: Milestone?
    public var flags: [ProgressFlag]

    /// Positive = better than baseline, regardless of metric direction.
    public var improvementFromBaseline: Double? {
        guard let baseline, let latest else { return nil }
        let delta = latest.value - baseline.value
        return kind.higherIsBetter ? delta : -delta
    }
}

public enum ProgressAnalyzer {
    public static let plateauWindow = 4

    public static func isBetter(_ a: Double, than b: Double, kind: MetricKind) -> Bool {
        kind.higherIsBetter ? a > b : a < b
    }

    public static func best(of samples: [MetricSample], kind: MetricKind) -> MetricSample? {
        samples.filter { $0.kind == kind }.reduce(nil) { current, sample in
            guard let current else { return sample }
            return isBetter(sample.value, than: current.value, kind: kind) ? sample : current
        }
    }

    public static func trend(kind: MetricKind, samples allSamples: [MetricSample], milestones: [Milestone]) -> MetricTrend {
        let samples = allSamples.filter { $0.kind == kind }.sorted { $0.date < $1.date }
        let baseline = samples.last(where: \.isBaseline) ?? samples.first
        // Treat only the first baseline as "the" baseline when several exist.
        let firstBaseline = samples.first(where: \.isBaseline) ?? baseline

        var pbIds: [UUID] = []
        var runningBest: Double?
        for sample in samples {
            if let rb = runningBest {
                if isBetter(sample.value, than: rb, kind: kind) && abs(sample.value - rb) >= kind.meaningfulChange * 0.5 {
                    pbIds.append(sample.id)
                    runningBest = sample.value
                }
            } else {
                runningBest = sample.value
            }
        }

        let relevant = milestones.filter { $0.kind == kind }
            .sorted { kind.higherIsBetter ? $0.threshold < $1.threshold : $0.threshold > $1.threshold }
        let bestSample = best(of: samples, kind: kind)
        let reached = bestSample.map { b in relevant.filter { $0.isReached(by: b.value) } } ?? []
        let next = relevant.first { m in !reached.contains(m) }

        return MetricTrend(
            kind: kind,
            samples: samples,
            baseline: firstBaseline,
            latest: samples.last,
            best: bestSample,
            personalBestIds: pbIds,
            reachedMilestones: reached,
            nextMilestone: next,
            flags: flags(kind: kind, samples: samples)
        )
    }

    public static func flags(kind: MetricKind, samples: [MetricSample]) -> [ProgressFlag] {
        var result: [ProgressFlag] = []
        guard samples.count >= 2, let latest = samples.last else { return result }

        if let best = best(of: samples, kind: kind), best.id != latest.id {
            let drop = kind.higherIsBetter ? best.value - latest.value : latest.value - best.value
            if drop >= kind.regressionThreshold {
                result.append(.regression(kind: kind, best: best.value, latest: latest.value))
            }
        }

        if samples.count > plateauWindow {
            let before = Array(samples.dropLast(plateauWindow))
            let window = samples.suffix(plateauWindow)
            if let bestBefore = best(of: before, kind: kind) {
                let improved = window.contains { s in
                    let gain = kind.higherIsBetter ? s.value - bestBefore.value : bestBefore.value - s.value
                    return gain >= kind.meaningfulChange
                }
                if !improved && !result.contains(where: { if case .regression = $0 { return true }; return false }) {
                    result.append(.plateau(kind: kind, sessions: plateauWindow))
                }
            }
        }
        return result
    }

    /// Achievements unlocked by adding `new` samples on top of `history`.
    public static func achievements(adding new: [MetricSample], to history: [MetricSample], milestones: [Milestone]) -> [Achievement] {
        var result: [Achievement] = []
        var combined = history
        for sample in new.sorted(by: { $0.date < $1.date }) {
            let previousBest = best(of: combined, kind: sample.kind)
            if let pb = previousBest {
                if isBetter(sample.value, than: pb.value, kind: sample.kind) && abs(sample.value - pb.value) >= sample.kind.meaningfulChange * 0.5 {
                    result.append(.personalBest(kind: sample.kind, value: sample.value, previous: pb.value))
                }
            }
            for milestone in milestones where milestone.kind == sample.kind && milestone.isReached(by: sample.value) {
                let alreadyReached = combined.contains { $0.kind == milestone.kind && milestone.isReached(by: $0.value) }
                if !alreadyReached { result.append(.milestone(milestone)) }
            }
            combined.append(sample)
        }
        return result
    }
}

/// Turns exercise results into metric samples.
public enum MetricExtractor {
    public static func samples(from result: ExerciseResult, spec: ExerciseSpec, date: Date, isBaseline: Bool, sessionId: UUID?) -> [MetricSample] {
        guard let binding = spec.metric else { return [] }
        let value: Double?
        switch binding.source {
        case .peakFlexionFromMinAngle:
            value = result.minAngle.map { 180 - $0 }
        case .extensionDeficitFromMaxAngle:
            value = result.maxAngle.map { max(0, 180 - $0) }
        case .bestSetReps:
            let best = result.repsPerSet.max() ?? 0
            value = best > 0 ? Double(best) : nil
        case .bestSetHoldSeconds:
            let best = result.holdSecondsPerSet.max() ?? 0
            value = best > 0 ? Double(best) : nil
        }
        guard let value else { return [] }
        return [MetricSample(kind: binding.kind, value: value.rounded(), date: date, isBaseline: isBaseline, exerciseId: spec.id, sessionId: sessionId)]
    }

    public static func samples(from summary: SessionSummary, library: ExerciseLibrary) -> [MetricSample] {
        var result: [MetricSample] = []
        for exercise in summary.exercises {
            guard let spec = library.spec(exercise.exerciseId) else { continue }
            result += samples(from: exercise, spec: spec, date: summary.endedAt, isBaseline: summary.isBaseline, sessionId: summary.id)
        }
        // Keep only the best sample per metric per session.
        var bestByKind: [MetricKind: MetricSample] = [:]
        for sample in result {
            if let existing = bestByKind[sample.kind], !ProgressAnalyzer.isBetter(sample.value, than: existing.value, kind: sample.kind) { continue }
            bestByKind[sample.kind] = sample
        }
        if let pain = summary.painBefore {
            bestByKind[.painAtRest] = MetricSample(kind: .painAtRest, value: Double(pain), date: summary.startedAt, isBaseline: summary.isBaseline, sessionId: summary.id)
        }
        return MetricKind.allCases.compactMap { bestByKind[$0] }
    }
}
