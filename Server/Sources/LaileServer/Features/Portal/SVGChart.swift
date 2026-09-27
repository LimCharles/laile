import Foundation
import LaileCore

/// Server-rendered line charts for the clinician portal — no JavaScript, prints cleanly.
enum SVGChart {
    static func trend(_ trend: MetricTrend, width: Double = 560, height: Double = 170) -> String {
        let samples = trend.samples
        guard !samples.isEmpty else { return "<p class=\"muted\">No data yet.</p>" }
        let pad = (left: 40.0, right: 14.0, top: 14.0, bottom: 26.0)
        let plotW = width - pad.left - pad.right, plotH = height - pad.top - pad.bottom

        let milestoneValues = (trend.reachedMilestones + [trend.nextMilestone].compactMap { $0 }).map(\.threshold)
        let values = samples.map(\.value) + milestoneValues
        var lo = values.min() ?? 0, hi = values.max() ?? 1
        if hi - lo < 10 { hi += 5; lo -= 5 }
        lo = max(0, lo - (hi - lo) * 0.1)
        hi += (hi - lo) * 0.1

        let t0 = samples.first!.date.timeIntervalSince1970
        let t1 = max(samples.last!.date.timeIntervalSince1970, t0 + 86_400)
        func x(_ d: Date) -> Double { pad.left + (d.timeIntervalSince1970 - t0) / (t1 - t0) * plotW }
        func y(_ v: Double) -> Double { pad.top + (1 - (v - lo) / (hi - lo)) * plotH }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }

        var svg = "<svg class=\"chart\" viewBox=\"0 0 \(Int(width)) \(Int(height))\" role=\"img\" aria-label=\"\(trend.kind.displayName) trend\">"
        // Gridlines + y labels.
        for i in 0...3 {
            let v = lo + (hi - lo) * Double(i) / 3
            svg += "<line class=\"grid\" x1=\"\(f(pad.left))\" x2=\"\(f(width - pad.right))\" y1=\"\(f(y(v)))\" y2=\"\(f(y(v)))\"/>"
            svg += "<text class=\"axis\" x=\"\(f(pad.left - 6))\" y=\"\(f(y(v) + 4))\" text-anchor=\"end\">\(Int(v.rounded()))</text>"
        }
        // Milestone lines.
        for milestone in trend.reachedMilestones + [trend.nextMilestone].compactMap({ $0 }) {
            let reached = trend.reachedMilestones.contains(milestone)
            svg += "<line class=\"milestone\(reached ? " reached" : "")\" x1=\"\(f(pad.left))\" x2=\"\(f(width - pad.right))\" y1=\"\(f(y(milestone.threshold)))\" y2=\"\(f(y(milestone.threshold)))\"/>"
            svg += "<text class=\"milestone-label\" x=\"\(f(width - pad.right - 4))\" y=\"\(f(y(milestone.threshold) - 4))\" text-anchor=\"end\">\(trend.kind.format(milestone.threshold))\(reached ? " ✓" : " goal")</text>"
        }
        // Baseline.
        if let baseline = trend.baseline {
            svg += "<line class=\"baseline\" x1=\"\(f(pad.left))\" x2=\"\(f(width - pad.right))\" y1=\"\(f(y(baseline.value)))\" y2=\"\(f(y(baseline.value)))\"/>"
            svg += "<text class=\"axis\" x=\"\(f(pad.left + 4))\" y=\"\(f(y(baseline.value) + 12))\">baseline</text>"
        }
        // Line + points.
        let path = samples.enumerated().map { i, s in "\(i == 0 ? "M" : "L")\(f(x(s.date))),\(f(y(s.value)))" }.joined(separator: " ")
        svg += "<path class=\"line\" d=\"\(path)\"/>"
        let pbs = Set(trend.personalBestIds)
        for s in samples {
            let cls = pbs.contains(s.id) ? "point pb" : "point"
            svg += "<circle class=\"\(cls)\" cx=\"\(f(x(s.date)))\" cy=\"\(f(y(s.value)))\" r=\"\(pbs.contains(s.id) ? 4.5 : 3)\"><title>\(Self.date(s.date)): \(trend.kind.format(s.value))\(pbs.contains(s.id) ? " (personal best)" : "")</title></circle>"
        }
        // X labels: first and last date.
        svg += "<text class=\"axis\" x=\"\(f(pad.left))\" y=\"\(f(height - 6))\">\(Self.date(samples.first!.date))</text>"
        svg += "<text class=\"axis\" x=\"\(f(width - pad.right))\" y=\"\(f(height - 6))\" text-anchor=\"end\">\(Self.date(samples.last!.date))</text>"
        svg += "</svg>"
        return svg
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        f.timeZone = TimeZone(identifier: "Asia/Singapore")
        return f.string(from: d)
    }
}
