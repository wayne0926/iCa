import Foundation

/// Hourly forecast: meteoblue (basic-1h) for the 7 days from today's midnight, then
/// Open-Meteo for the days after it, out to 16 days. Either one alone, if the other fails.
struct WeatherService: Sendable {
    enum Failure: Error { case noKey, badResponse }

    static let refreshAfter: TimeInterval = 60 * 60

    /// Synchronous read for the first frame.
    func cachedNow(at c: Coordinate) -> [HourWeather]? {
        let near = DiskCache.shared.readNow([HourWeather].self, key: Self.key(c), maxAge: 3 * 86400)?.0
        let far = DiskCache.shared.readNow([HourWeather].self, key: Self.farKey(c), maxAge: 3 * 86400)?.0
        return Self.join(near, far)
    }

    func forecast(at c: Coordinate, force: Bool = false) async throws -> [HourWeather] {
        async let near = try? meteoblue(at: c, force: force)
        async let far = try? openMeteo(at: c, force: force)
        guard let hours = Self.join(await near, await far) else { throw Failure.badResponse }
        return hours
    }

    /// meteoblue's hours, then Open-Meteo's from the first hour meteoblue doesn't cover.
    private static func join(_ near: [HourWeather]?, _ far: [HourWeather]?) -> [HourWeather]? {
        guard let near, let last = near.last?.time else { return far }
        return near + (far ?? []).filter { $0.time > last }
    }

    /// Returns cached data if it is fresh enough, otherwise asks meteoblue.
    private func meteoblue(at c: Coordinate, force: Bool) async throws -> [HourWeather] {
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
    private static func farKey(_ c: Coordinate) -> String { "weather-om|" + String(format: "%.2f,%.2f", c.lat, c.lon) }

    // MARK: Open-Meteo

    /// The 16 days Open-Meteo forecasts, no key needed. Only the days past meteoblue's are used.
    private func openMeteo(at c: Coordinate, force: Bool) async throws -> [HourWeather] {
        if !force, let (hours, _) = await DiskCache.shared.read([HourWeather].self, key: Self.farKey(c), maxAge: Self.refreshAfter) {
            return hours
        }
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(c.lat)),
            .init(name: "longitude", value: String(c.lon)),
            .init(name: "hourly", value: "temperature_2m,precipitation,precipitation_probability,weather_code,is_day,wind_speed_10m"),
            .init(name: "forecast_days", value: "16"),
            .init(name: "wind_speed_unit", value: "ms"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: TimeZone.current.identifier),
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
        let hours = try Self.parseOpenMeteo(data)
        guard !hours.isEmpty else { throw Failure.badResponse }
        await DiskCache.shared.write(hours, key: Self.farKey(c))
        return hours
    }

    private struct OpenMeteoPayload: Decodable {
        struct Hourly: Decodable {
            let time: [Double]
            let temperature_2m: [Double?]
            let precipitation: [Double?]
            let precipitation_probability: [Int?]?
            let weather_code: [Int?]
            let is_day: [Int?]
            let wind_speed_10m: [Double?]
        }
        let hourly: Hourly
    }

    /// Hours missing their temperature or weather code are left out; a missing chance of
    /// rain counts as none.
    static func parseOpenMeteo(_ data: Data) throws -> [HourWeather] {
        let h = try JSONDecoder().decode(OpenMeteoPayload.self, from: data).hourly
        return h.time.indices.compactMap { i in
            guard i < h.temperature_2m.count, i < h.weather_code.count,
                  let temp = h.temperature_2m[i], let code = h.weather_code[i] else { return nil }
            let chance = h.precipitation_probability.flatMap { i < $0.count ? $0[i] : nil } ?? 0
            return HourWeather(time: Date(timeIntervalSince1970: h.time[i]),
                               temperature: temp,
                               precipitation: (i < h.precipitation.count ? h.precipitation[i] : nil) ?? 0,
                               precipitationProbability: chance,
                               pictocode: pictocode(wmo: code),
                               isDaylight: (i < h.is_day.count ? h.is_day[i] : nil) == 1,
                               windSpeed: (i < h.wind_speed_10m.count ? h.wind_speed_10m[i] : nil) ?? 0)
        }
    }

    /// A WMO weather code as the meteoblue pictocode of the same kind, so everything
    /// downstream reads one scale (see `WeatherKind(pictocode:)`).
    static func pictocode(wmo: Int) -> Int {
        switch wmo {
        case 0, 1: return 1          // clear
        case 2: return 4             // partly cloudy
        case 3: return 19            // overcast
        case 45, 48: return 16       // fog
        case 51...57: return 33      // drizzle
        case 61, 63: return 23       // rain
        case 65, 82: return 25       // heavy rain
        case 66, 67: return 35       // freezing rain: sleet
        case 71...77, 85, 86: return 24  // snow
        case 80, 81: return 31       // showers
        case 95...99: return 27      // thunderstorm
        default: return 19
        }
    }

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
