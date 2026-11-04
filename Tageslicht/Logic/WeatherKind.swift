import Foundation

/// Coarse weather class derived from meteoblue's hourly pictocode (1–35).
enum WeatherKind: Hashable, Sendable {
    case clear, fewClouds, cloudy, fog, drizzle, rain, heavyRain, snow, sleet, thunder, showers

    init(pictocode: Int) {
        switch pictocode {
        case 1, 2, 3: self = .clear
        case 4...9, 13...15: self = .fewClouds
        case 10, 11, 12: self = .thunder
        case 16, 17, 18: self = .fog
        case 19...22: self = .cloudy
        case 23: self = .rain
        case 33: self = .drizzle
        case 25: self = .heavyRain
        case 24, 26, 29, 32, 34: self = .snow
        case 27, 28, 30: self = .thunder
        case 31: self = .showers
        case 35: self = .sleet
        default: self = .cloudy
        }
    }

    var isWet: Bool {
        switch self {
        case .drizzle, .rain, .heavyRain, .snow, .sleet, .thunder, .showers: return true
        default: return false
        }
    }

    func symbol(daylight: Bool) -> String {
        switch self {
        case .clear: return daylight ? "sun.max.fill" : "moon.stars.fill"
        case .fewClouds: return daylight ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .rain: return "cloud.rain.fill"
        case .heavyRain: return "cloud.heavyrain.fill"
        case .snow: return "cloud.snow.fill"
        case .sleet: return "cloud.sleet.fill"
        case .thunder: return "cloud.bolt.rain.fill"
        case .showers: return daylight ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        }
    }
}

/// One-line summary of a day's hourly forecast for the header.
struct DaySummary: Hashable {
    let low: Int
    let high: Int
    let symbol: String
    let kind: WeatherKind
    /// e.g. "15:00–17:00 有雨"; nil when dry.
    let wetSpan: String?

    /// Past the hourly forecast: the 46-day ensemble's weather for the day, no more.
    init(outlook o: DayOutlook) {
        low = 0
        high = 0
        kind = WeatherKind(pictocode: o.pictocode)
        symbol = kind.symbol(daylight: true)
        wetSpan = nil
    }

    init?(hours: [HourWeather], calendar: Calendar = .current) {
        guard !hours.isEmpty else { return nil }
        let temps = hours.map(\.temperature)
        low = Int(temps.min()!.rounded())
        high = Int(temps.max()!.rounded())

        // Representative symbol: the most common class among daylight hours.
        let pool = hours.filter(\.isDaylight).isEmpty ? hours : hours.filter(\.isDaylight)
        var counts: [WeatherKind: Int] = [:]
        for h in pool { counts[WeatherKind(pictocode: h.pictocode), default: 0] += 1 }
        let wetHours = hours.filter { $0.precipitation >= TravelPolicy.rainMillimetres }
        let main = wetHours.count >= 2 ? WeatherKind(pictocode: wetHours[0].pictocode)
                                       : counts.max { $0.value < $1.value }!.key
        kind = main
        symbol = main.symbol(daylight: true)

        if let first = wetHours.first, let last = wetHours.last {
            let f = Date.FormatStyle(locale: Locale(identifier: "zh_CN")).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            wetSpan = "\(first.time.formatted(f))–\(last.time.addingTimeInterval(3600).formatted(f)) 有雨"
        } else {
            wetSpan = nil
        }
    }
}
