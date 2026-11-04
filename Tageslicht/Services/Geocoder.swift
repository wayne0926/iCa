import CoreLocation

/// Calendar addresses to coordinates through Apple's geocoder, each looked up once and
/// remembered on disk. Room names in front of the street ("0.038 (Hörsaal), Meckenheimer
/// Allee 166") are dropped piece by piece until the rest is found.
struct Geocoder: Sendable {
    nonisolated func cachedNow(_ address: String) -> Coordinate? {
        DiskCache.shared.readNow(Coordinate.self, key: Self.key(address), maxAge: 180 * 86400)?.0
    }

    func coordinate(for address: String, near: Coordinate) async -> Coordinate? {
        if let c = cachedNow(address) { return c }
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: near.lat, longitude: near.lon),
                                      radius: 50_000, identifier: "near")
        var parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        while !parts.isEmpty {
            let query = parts.joined(separator: ", ")
            if let l = try? await CLGeocoder().geocodeAddressString(query, in: region).first?.location {
                let c = Coordinate(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
                await DiskCache.shared.write(c, key: Self.key(address))
                return c
            }
            parts.removeFirst()
        }
        return nil
    }

    private static func key(_ address: String) -> String { "geo|" + address }
}
