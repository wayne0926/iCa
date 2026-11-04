import Foundation

/// Hourly forecast from meteoblue (basic-1h), 7 days from today's midnight.
struct WeatherService: Sendable {
    enum Failure: Error { case noKey, badResponse }

    static let refreshAfter: TimeInterval = 60 * 60

    /// Synchronous read for the first frame.
    func cachedNow(at c: Coordinate) -> [HourWeather]? {
        DiskCache.shared.readNow([HourWeather].self, key: Self.key(c), maxAge: 3 * 86400)?.0
    }

    /// Returns cached data if it is fresh enough, otherwise asks meteoblue.
    func forecast(at c: Coordinate, force: Bool = false) async throws -> [HourWeather] {
        if !force, let (hours, _) = await DiskCache.shared.read([HourWeather].self, key: Self.key(c), maxAge: Self.refreshAfter) {
            return hours
        }
        guard let key = Secrets.meteoblue else { throw Failure.noKey }
        var comps = URLComponents(string: "https://my.meteoblue.com/packages/basic-1h")!
        comps.queryItems = [
            .init(name: "lat", value: String(c.lat)),
            .init(name: "lon", value: String(c.lon)),
            .init(name: "format", value: "json"),
            .init(name: "tz", value: TimeZone.current.identifier),
            .init(name: "forecast_days", value: "7"),
            .init(name: "apikey", value: key),
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
        let hours = try Self.parse(data)
        await DiskCache.shared.write(hours, key: Self.key(c))
        return hours
    }

    private static func key(_ c: Coordinate) -> String { "weather|" + String(format: "%.2f,%.2f", c.lat, c.lon) }

    private struct Payload: Decodable {
        struct Metadata: Decodable { let utc_timeoffset: Double }
        struct Hourly: Decodable {
            let time: [String]
            let temperature: [Double]
            let precipitation: [Double]
            let precipitation_probability: [Int]
            let pictocode: [Int]
            let isdaylight: [Int]
            let windspeed: [Double]
        }
        let metadata: Metadata
        let data_1h: Hourly
    }

    static func parse(_ data: Data) throws -> [HourWeather] {
        let p = try JSONDecoder().decode(Payload.self, from: data)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(secondsFromGMT: Int(p.metadata.utc_timeoffset * 3600))
        let h = p.data_1h
        return h.time.indices.compactMap { i in
            guard let t = f.date(from: h.time[i]) else { return nil }
            return HourWeather(time: t,
                               temperature: h.temperature[i],
                               precipitation: h.precipitation[i],
                               precipitationProbability: h.precipitation_probability[i],
                               pictocode: h.pictocode[i],
                               isDaylight: h.isdaylight[i] == 1,
                               windSpeed: h.windspeed[i])
        }
    }
}
