import Foundation

struct Coordinate: Hashable, Codable, Sendable {
    var lat: Double
    var lon: Double

    static let bonn = Coordinate(lat: 50.7374, lon: 7.0982)

    /// Rounded key so tiny GPS jitter doesn't defeat caches (~100 m).
    var cacheKey: String { String(format: "%.3f,%.3f", lat, lon) }

    /// The roughly 10 km square it lies in. Weather is looked up per square: places in
    /// one town share a forecast.
    var area: Coordinate { Coordinate(lat: (lat * 10).rounded() / 10, lon: (lon * 10).rounded() / 10) }
}

struct RGB: Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double
}

/// Plain snapshot of an EKEvent, safe to pass across threads and cheap to diff.
struct CalEvent: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let coordinate: Coordinate?
    let calendarTitle: String
    /// The colour set for its calendar in the system Calendar app.
    let calendarColor: RGB

    var hasPlace: Bool { coordinate != nil || !(location ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}

struct HourWeather: Hashable, Codable, Sendable {
    let time: Date
    let temperature: Double
    let precipitation: Double          // mm in this hour
    let precipitationProbability: Int  // %
    let pictocode: Int
    let isDaylight: Bool
    let windSpeed: Double              // m/s
}

/// Five minutes of rain from the DWD radar (measured, or extrapolated up to two hours
/// ahead): what fell in the five minutes up to `time`.
struct RadarStep: Hashable, Codable, Sendable {
    let time: Date
    /// mm in these five minutes.
    let millimetres: Double

    static let length: TimeInterval = 5 * 60
    var start: Date { time.addingTimeInterval(-Self.length) }
    /// As a rate, mm/h.
    var rate: Double { millimetres * 12 }
}

/// One day of ECMWF's 46-day ensemble: how many of its runs bring rain.
struct DayOutlook: Hashable, Codable, Sendable {
    let day: Date
    /// Share of the ensemble members with at least a millimetre that day, %.
    let chance: Int
    /// The members' mean, mm.
    let millimetres: Double
    /// Most members fall as snow.
    let snow: Bool
}

struct SunTimes: Hashable, Sendable {
    let sunrise: Date?
    let sunset: Date?
}

enum TravelMode: String, Codable, Sendable {
    case bicycle
    case transit
}

enum VehicleKind: String, Codable, Sendable {
    case bus, tram, subway, train, other

    init(googleType: String) {
        switch googleType {
        case "BUS", "INTERCITY_BUS", "TROLLEYBUS", "SHARE_TAXI": self = .bus
        case "TRAM", "LIGHT_RAIL", "CABLE_CAR", "FUNICULAR": self = .tram
        case "SUBWAY", "METRO_RAIL": self = .subway
        case "RAIL", "HEAVY_RAIL", "COMMUTER_TRAIN", "HIGH_SPEED_TRAIN", "LONG_DISTANCE_TRAIN", "MONORAIL": self = .train
        default: self = .other
        }
    }
}

struct TransitLeg: Hashable, Codable, Sendable {
    let line: String
    let vehicle: VehicleKind
    let departure: Date
    let stop: String
}

/// One routing answer from Google for a single mode.
struct RouteResult: Hashable, Codable, Sendable {
    let mode: TravelMode
    let duration: TimeInterval
    let distance: Double
    /// Transit only: first boarded line; departure of the whole trip (incl. walk to stop).
    let firstLeg: TransitLeg?
    let tripStart: Date?
}

enum TravelReason: Hashable, Sendable {
    case rain
    case far
}

struct TravelPlan: Hashable, Sendable {
    let mode: TravelMode
    let duration: TimeInterval
    let leaveAt: Date
    let transit: TransitLeg?
    let reason: TravelReason?
    let bike: RouteResult?
    let transitRoute: RouteResult?
}
