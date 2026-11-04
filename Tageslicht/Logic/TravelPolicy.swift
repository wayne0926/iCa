import Foundation

/// Decides bike vs. public transport for one trip. Bike is the default;
/// transit wins when it rains on the way or the ride is long.
enum TravelPolicy {
    /// Rain heavier than this (mm in the hour) during the ride means take transit.
    static let rainMillimetres = 0.3
    /// Or this likely, with at least a drizzle forecast.
    static let rainProbability = 70
    /// Rides longer than this make transit worth it, if transit isn't much slower.
    static let longRide: TimeInterval = 30 * 60
    static let transitSlackFactor = 1.25
    /// Lock up the bike / walk in from the stop.
    static let buffer: TimeInterval = 3 * 60

    static func plan(arrival: Date,
                     bike: RouteResult?,
                     transit: RouteResult?,
                     weather: [HourWeather]) -> TravelPlan? {
        func bikePlan(_ b: RouteResult) -> TravelPlan {
            TravelPlan(mode: .bicycle, duration: b.duration,
                       leaveAt: arrival.addingTimeInterval(-b.duration - buffer),
                       transit: nil, reason: nil, bike: bike, transitRoute: transit)
        }
        func transitPlan(_ t: RouteResult, _ reason: TravelReason?) -> TravelPlan {
            TravelPlan(mode: .transit, duration: t.duration,
                       leaveAt: t.tripStart ?? arrival.addingTimeInterval(-t.duration - buffer),
                       transit: t.firstLeg, reason: reason, bike: bike, transitRoute: transit)
        }

        guard let b = bike else { return transit.map { transitPlan($0, nil) } }
        guard let t = transit, t.firstLeg != nil else { return bikePlan(b) }

        let rideStart = arrival.addingTimeInterval(-b.duration - buffer)
        if isWet(from: rideStart, to: arrival, weather: weather) {
            return transitPlan(t, .rain)
        }
        if b.duration > longRide && t.duration <= b.duration * transitSlackFactor {
            return transitPlan(t, .far)
        }
        return bikePlan(b)
    }

    static func isWet(from start: Date, to end: Date, weather: [HourWeather]) -> Bool {
        weather.contains { h in
            let hEnd = h.time.addingTimeInterval(3600)
            guard hEnd > start, h.time < end else { return false }
            return h.precipitation >= rainMillimetres
                || (h.precipitationProbability >= rainProbability && h.precipitation >= 0.1)
        }
    }
}
