import Foundation

enum Place: Hashable, Sendable {
    case coordinate(Coordinate)
    case address(String)

    var cacheKey: String {
        switch self {
        case .coordinate(let c): return c.cacheKey
        case .address(let a): return a.lowercased()
        }
    }

    fileprivate var json: [String: Any] {
        switch self {
        case .coordinate(let c): return ["location": ["latLng": ["latitude": c.lat, "longitude": c.lon]]]
        case .address(let a): return ["address": a]
        }
    }
}

/// Google Routes API (computeRoutes). Bike routes are cached for a month,
/// transit for half a day (timetables), both on disk.
struct RoutesService: Sendable {
    enum Failure: Error { case noKey, badResponse }

    func bike(from: Place, to: Place) async throws -> RouteResult? {
        let key = "bike|\(from.cacheKey)|\(to.cacheKey)"
        if let (hit, _) = await DiskCache.shared.read(Optional<RouteResult>.self, key: key, maxAge: 30 * 86400) { return hit }
        let r = try await compute(from: from, to: to, mode: .bicycle, arrival: nil)
        await DiskCache.shared.write(r, key: key)
        return r
    }

    func transit(from: Place, to: Place, arrival: Date) async throws -> RouteResult? {
        let minute = Int(arrival.timeIntervalSince1970 / 60)
        let key = "transit|\(from.cacheKey)|\(to.cacheKey)|\(minute)"
        if let (hit, _) = await DiskCache.shared.read(Optional<RouteResult>.self, key: key, maxAge: 12 * 3600) { return hit }
        let r = try await compute(from: from, to: to, mode: .transit, arrival: arrival)
        await DiskCache.shared.write(r, key: key)
        return r
    }

    private func compute(from: Place, to: Place, mode: TravelMode, arrival: Date?) async throws -> RouteResult? {
        guard let apiKey = Secrets.googleMaps else { throw Failure.noKey }
        var body: [String: Any] = [
            "origin": from.json,
            "destination": to.json,
            "travelMode": mode == .bicycle ? "BICYCLE" : "TRANSIT",
            "languageCode": "de",
        ]
        if let arrival {
            body["arrivalTime"] = ISO8601DateFormatter().string(from: arrival)
        }
        var req = URLRequest(url: URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue([
            "routes.duration", "routes.distanceMeters",
            "routes.legs.steps.travelMode", "routes.legs.steps.staticDuration",
            "routes.legs.steps.transitDetails.transitLine.nameShort",
            "routes.legs.steps.transitDetails.transitLine.name",
            "routes.legs.steps.transitDetails.transitLine.vehicle.type",
            "routes.legs.steps.transitDetails.stopDetails.departureTime",
            "routes.legs.steps.transitDetails.stopDetails.departureStop.name",
        ].joined(separator: ","), forHTTPHeaderField: "X-Goog-FieldMask")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
        return try Self.parse(data, mode: mode)
    }

    private struct Payload: Decodable {
        struct Route: Decodable {
            let duration: String?
            let distanceMeters: Double?
            let legs: [Leg]?
        }
        struct Leg: Decodable { let steps: [Step]? }
        struct Step: Decodable {
            let travelMode: String?
            let staticDuration: String?
            let transitDetails: Transit?
        }
        struct Transit: Decodable {
            struct Line: Decodable {
                struct Vehicle: Decodable { let type: String? }
                let nameShort: String?
                let name: String?
                let vehicle: Vehicle?
            }
            struct Stops: Decodable {
                struct Stop: Decodable { let name: String? }
                let departureTime: String?
                let departureStop: Stop?
            }
            let transitLine: Line?
            let stopDetails: Stops?
        }
        let routes: [Route]?
    }

    static func parse(_ data: Data, mode: TravelMode) throws -> RouteResult? {
        let p = try JSONDecoder().decode(Payload.self, from: data)
        guard let route = p.routes?.first, let d = seconds(route.duration) else { return nil }
        let steps = route.legs?.flatMap { $0.steps ?? [] } ?? []

        var leg: TransitLeg?
        var tripStart: Date?
        if mode == .transit, let idx = steps.firstIndex(where: { $0.transitDetails != nil }),
           let td = steps[idx].transitDetails,
           let dep = td.stopDetails?.departureTime.flatMap(parseISO) {
            // Walking before the first boarding moves the real departure earlier.
            let walk = steps[..<idx].compactMap { seconds($0.staticDuration) }.reduce(0, +)
            tripStart = dep.addingTimeInterval(-walk)
            leg = TransitLeg(line: td.transitLine?.nameShort ?? td.transitLine?.name ?? "",
                             vehicle: VehicleKind(googleType: td.transitLine?.vehicle?.type ?? ""),
                             departure: dep,
                             stop: td.stopDetails?.departureStop?.name ?? "")
        }
        // Google's duration already runs door to door, walking included.
        return RouteResult(mode: mode, duration: d, distance: route.distanceMeters ?? 0,
                           firstLeg: leg, tripStart: tripStart)
    }

    static func seconds(_ s: String?) -> TimeInterval? {
        guard let s, s.hasSuffix("s"), let v = Double(s.dropLast()) else { return nil }
        return v
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
