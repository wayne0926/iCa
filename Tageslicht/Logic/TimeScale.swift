import CoreGraphics
import Foundation

/// Maps an hour of the day to a y position, folding long empty stretches into a short
/// strip so the page is only as deep as the day is busy.
struct TimeScale: Equatable {
    struct Segment: Equatable {
        let start: Double      // hours from midnight
        let end: Double
        let y: CGFloat
        let height: CGFloat
        let folded: Bool

        var pointsPerHour: CGFloat { height / CGFloat(end - start) }
    }

    let segments: [Segment]

    var height: CGFloat { segments.last.map { $0.y + $0.height } ?? 0 }

    func y(_ hour: Double) -> CGFloat {
        guard let first = segments.first else { return 0 }
        if hour <= first.start { return first.y }
        for s in segments where hour <= s.end {
            return s.y + CGFloat(hour - s.start) * s.pointsPerHour
        }
        return height
    }

    struct Metrics {
        var hourHeight: CGFloat = 60
        var foldHeight: CGFloat = 32
        /// Empty stretches at least this long fold; shorter ones stay to scale.
        var minFold: Double = 1.5
        /// Room kept around each busy stretch, before snapping to the half hour.
        var padding: Double = 0.25
        /// An empty day still shows its daytime, at this fraction of the full scale.
        var quietDay: ClosedRange<Double> = 7...21
        var quietScale: CGFloat = 0.4
    }

    static func make(busy: [ClosedRange<Double>], dayHours: Double, metrics m: Metrics = Metrics()) -> TimeScale {
        // Pad, snap to half hours, merge.
        func down(_ h: Double) -> Double { floor(h * 2) / 2 }
        func up(_ h: Double) -> Double { ceil(h * 2) / 2 }
        let spans = busy
            .map { max(0, down($0.lowerBound - m.padding))...min(dayHours, up($0.upperBound + m.padding)) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for s in spans {
            if let last = merged.last, s.lowerBound <= last.upperBound + 0.001 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, s.upperBound)
            } else {
                merged.append(s)
            }
        }

        var parts: [(start: Double, end: Double, folded: Bool, pph: CGFloat)] = []
        if merged.isEmpty {
            let q = max(0, m.quietDay.lowerBound)...min(dayHours, m.quietDay.upperBound)
            if q.lowerBound > 0 { parts.append((0, q.lowerBound, true, 0)) }
            parts.append((q.lowerBound, q.upperBound, false, m.hourHeight * m.quietScale))
            if q.upperBound < dayHours { parts.append((q.upperBound, dayHours, true, 0)) }
        } else {
            var cursor = 0.0
            for (i, s) in merged.enumerated() {
                let gap = s.lowerBound - cursor
                if gap > 0 {
                    // The stretch before the first event and after the last always fold.
                    let edge = i == 0
                    parts.append((cursor, s.lowerBound, edge || gap >= m.minFold, m.hourHeight))
                }
                parts.append((s.lowerBound, s.upperBound, false, m.hourHeight))
                cursor = s.upperBound
            }
            if cursor < dayHours { parts.append((cursor, dayHours, true, 0)) }
        }

        var y: CGFloat = 0
        let segments = parts.map { p -> Segment in
            let h = p.folded ? m.foldHeight : CGFloat(p.end - p.start) * p.pph
            defer { y += h }
            return Segment(start: p.start, end: p.end, y: y, height: h, folded: p.folded)
        }
        return TimeScale(segments: segments)
    }
}

extension TimeScale {
    /// How present an hour line (or its label) is at this hour: 1 inside an unfolded
    /// stretch, 0 inside a fold. Quiet-day scale labels only every third hour.
    func gridWeight(_ hour: Double, label: Bool = false) -> Double {
        guard let s = segments.first(where: { !$0.folded && hour >= $0.start - 0.001 && hour <= $0.end + 0.001 })
        else { return 0 }
        if label && s.pointsPerHour < 40 && Int(hour.rounded()) % 3 != 0 { return 0 }
        return 1
    }
}

/// A time scale frozen as plain numbers: heights at the hours where the slope may change
/// (linear in between), and how present each whole hour's line and label is. Any scale,
/// and any moment of a change between two scales, can be held as one; that is what lets
/// a change tapped mid-flight start from exactly what is on screen.
struct ScaleFrame: Equatable {
    var hours: [Double]
    var ys: [CGFloat]
    /// Indexed by whole hour.
    var lines: [Double]
    var labels: [Double]

    init(_ scale: TimeScale) {
        var hours: [Double] = [], ys: [CGFloat] = []
        for s in scale.segments {
            if hours.last != s.start { hours.append(s.start); ys.append(s.y) }
            hours.append(s.end); ys.append(s.y + s.height)
        }
        self.hours = hours.isEmpty ? [0] : hours
        self.ys = ys.isEmpty ? [0] : ys
        let last = Int((hours.last ?? 24).rounded(.up))
        lines = (0...last).map { scale.gridWeight(Double($0)) }
        labels = (0...last).map { scale.gridWeight(Double($0), label: true) }
    }

    init(hours: [Double], ys: [CGFloat], lines: [Double], labels: [Double]) {
        self.hours = hours
        self.ys = ys
        self.lines = lines
        self.labels = labels
    }

    var height: CGFloat { ys.last ?? 0 }

    func y(_ hour: Double) -> CGFloat {
        guard hour > hours[0] else { return ys[0] }
        for i in 1..<hours.count where hour <= hours[i] {
            let span = hours[i] - hours[i - 1]
            guard span > 0 else { return ys[i] }
            return ys[i - 1] + (ys[i] - ys[i - 1]) * CGFloat((hour - hours[i - 1]) / span)
        }
        return height
    }

    /// Inverse of `y(_:)`: the hour drawn at a given height.
    func hour(atY y: CGFloat) -> Double {
        guard y > ys[0] else { return hours[0] }
        for i in 1..<ys.count where y <= ys[i] {
            let rise = ys[i] - ys[i - 1]
            guard rise > 0 else { return hours[i] }
            return hours[i - 1] + (hours[i] - hours[i - 1]) * Double((y - ys[i - 1]) / rise)
        }
        return hours.last ?? 24
    }

    func gridWeight(_ hour: Double, label: Bool = false) -> Double {
        let i = Int(hour.rounded())
        let w = label ? labels : lines
        return w.indices.contains(i) ? w[i] : 0
    }
}

/// A time scale part-way between two others, so a change of zoom or folding can be
/// animated: every position, line and label moves along the same curve.
struct ScaleBlend: Equatable {
    var from: ScaleFrame
    var to: ScaleFrame
    /// 0 = `from`, 1 = `to`. May overshoot slightly under a spring.
    var t: Double

    init(_ scale: TimeScale) {
        from = ScaleFrame(scale)
        to = from
        t = 1
    }

    init(from: ScaleFrame, to: ScaleFrame, t: Double) {
        self.from = from
        self.to = to
        self.t = t
    }

    init(from: TimeScale, to: TimeScale, t: Double) {
        self.init(from: ScaleFrame(from), to: ScaleFrame(to), t: t)
    }

    func y(_ hour: Double) -> CGFloat {
        let a = from.y(hour), b = to.y(hour)
        return a + (b - a) * CGFloat(t)
    }

    var height: CGFloat { from.height + (to.height - from.height) * CGFloat(t) }

    /// Lines and labels that exist on only one side fade across the change.
    func gridWeight(_ hour: Double, label: Bool = false) -> Double {
        let a = from.gridWeight(hour, label: label), b = to.gridWeight(hour, label: label)
        return min(1, max(0, a + (b - a) * t))
    }

    /// This moment of the change, frozen: the starting point for a change that interrupts it.
    var frame: ScaleFrame {
        let hours = Array(Set(from.hours + to.hours)).sorted()
        let count = max(from.lines.count, to.lines.count)
        return ScaleFrame(hours: hours, ys: hours.map { y($0) },
                          lines: (0..<count).map { gridWeight(Double($0)) },
                          labels: (0..<count).map { gridWeight(Double($0), label: true) })
    }
}

extension TimeScale {
    /// Inverse of `y(_:)`: the hour drawn at a given height.
    func hour(atY y: CGFloat) -> Double {
        guard let first = segments.first else { return 0 }
        if y <= first.y { return first.start }
        for s in segments where y <= s.y + s.height {
            return s.start + Double((y - s.y) / s.pointsPerHour)
        }
        return segments.last?.end ?? 24
    }
}

extension TimeScale {
    /// The hours a folded page always keeps open, the same for every day, so paging never
    /// shifts the grid: from when days usually start to when they usually end. A rare
    /// early or late event doesn't widen every page; its own day opens up for it instead.
    /// `days` holds each day's timed events; days without any don't vote.
    static func usualHours(_ days: [[ClosedRange<Double>]]) -> ClosedRange<Double>? {
        let starts = days.compactMap { $0.map(\.lowerBound).min() }.sorted()
        let ends = days.compactMap { $0.map(\.upperBound).max() }.sorted()
        guard !starts.isEmpty else { return nil }
        func quantile(_ v: [Double], _ q: Double) -> Double { v[min(v.count - 1, Int(Double(v.count - 1) * q + 0.5))] }
        let lo = quantile(starts, 0.1), hi = quantile(ends, 0.9)
        return lo...max(hi, lo + 1)
    }
}
