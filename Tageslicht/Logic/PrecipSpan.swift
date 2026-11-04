import Foundation

/// A run of consecutive wet hours, in hours from midnight, ready to animate.
struct PrecipSpan: Equatable {
    let start: Double
    let end: Double
    /// Heaviest hour in the run, mm/h.
    let intensity: Double
    let snow: Bool
    /// Strongest wind in the run, m/s; tilts the drops.
    let wind: Double

    /// Drizzle below this doesn't animate; the forecast is too unsure to show it as rain.
    static let threshold = 0.1

    /// Wet hours, merged into runs. Where the radar reaches (its hour back and two hours
    /// ahead), it decides instead, five minutes at a time: the shower then starts and
    /// stops when the radar says, not on the hour.
    static func spans(from hours: [HourWeather], day: Date, radar: [RadarStep] = []) -> [PrecipSpan] {
        let window = radar.first.flatMap { f in radar.last.map { (from: f.start, to: $0.time) } }
        // Pieces in hours from midnight: (start, end, mm/h, snow, wind).
        var pieces: [(Double, Double, Double, Bool, Double)] = []
        for h in hours where h.precipitation >= threshold {
            var from = h.time, to = h.time.addingTimeInterval(3600)
            let snow = WeatherKind(pictocode: h.pictocode) == .snow
            if let w = window {
                // The forecast keeps only what lies outside the radar's stretch.
                if from >= w.from && to <= w.to { continue }
                if from < w.from && to > w.from && to <= w.to { to = w.from }
                if from >= w.from && from < w.to && to > w.to { from = w.to }
            }
            pieces.append((from.timeIntervalSince(day) / 3600, to.timeIntervalSince(day) / 3600,
                           h.precipitation, snow, h.windSpeed))
        }
        for s in radar where s.rate >= threshold {
            // The radar can't tell rain from snow; the hour's forecast can.
            let hour = hours.last { $0.time <= s.start }
            pieces.append((s.start.timeIntervalSince(day) / 3600, s.time.timeIntervalSince(day) / 3600,
                           s.rate, hour.map { WeatherKind(pictocode: $0.pictocode) == .snow } ?? false,
                           hour?.windSpeed ?? 3))
        }
        pieces.sort { $0.0 < $1.0 }
        var result: [PrecipSpan] = []
        for p in pieces {
            if let last = result.last, abs(last.end - p.0) < 0.01, last.snow == p.3 {
                result[result.count - 1] = PrecipSpan(start: last.start, end: p.1, intensity: max(last.intensity, p.2),
                                                      snow: p.3, wind: max(last.wind, p.4))
            } else {
                result.append(PrecipSpan(start: p.0, end: p.1, intensity: p.2, snow: p.3, wind: p.4))
            }
        }
        return result
    }
}
