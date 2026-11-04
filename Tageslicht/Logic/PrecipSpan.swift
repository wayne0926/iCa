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

    static func spans(from hours: [HourWeather], day: Date) -> [PrecipSpan] {
        var result: [PrecipSpan] = []
        for h in hours where h.precipitation >= threshold {
            let start = h.time.timeIntervalSince(day) / 3600
            let kind = WeatherKind(pictocode: h.pictocode)
            let snow = kind == .snow
            if let last = result.last, abs(last.end - start) < 0.01, last.snow == snow {
                result[result.count - 1] = PrecipSpan(start: last.start, end: start + 1,
                                                      intensity: max(last.intensity, h.precipitation), snow: snow,
                                                      wind: max(last.wind, h.windSpeed))
            } else {
                result.append(PrecipSpan(start: start, end: start + 1, intensity: h.precipitation, snow: snow,
                                         wind: h.windSpeed))
            }
        }
        return result
    }
}
