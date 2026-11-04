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

    // MARK: ECMWF EC46 (Open-Meteo seasonal)

    /// Day by day for the next 46 days, from ECMWF's extended-range ensemble: only good for
    /// "likely wet or not", which is all it is used for, on days past the hourly forecast.
    func outlook(at c: Coordinate) async throws -> [DayOutlook] {
        let key = "outlook|" + String(format: "%.2f,%.2f", c.lat, c.lon)
        // EC46 runs once a day.
        if let (days, _) = await DiskCache.shared.read([DayOutlook].self, key: key, maxAge: 6 * 3600) {
            return days
        }
        var comps = URLComponents(string: "https://seasonal-api.open-meteo.com/v1/seasonal")!
        comps.queryItems = [
            .init(name: "latitude", value: String(c.lat)),
            .init(name: "longitude", value: String(c.lon)),
            .init(name: "models", value: "ecmwf_ec46"),
            .init(name: "daily", value: "precipitation_sum,snowfall_sum"),
            .init(name: "forecast_days", value: "46"),
            .init(name: "timezone", value: TimeZone.current.identifier),
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
        let days = try Self.parseOutlook(data)
        guard !days.isEmpty else { throw Failure.badResponse }
        await DiskCache.shared.write(days, key: key)
        return days
    }

    /// The daily block holds `time`, then each variable once for the control run and once
    /// per member (`precipitation_sum`, `precipitation_sum_member01` …). Every series of a
    /// variable is a vote; a day nobody has a value for is left out.
    static func parseOutlook(_ data: Data) throws -> [DayOutlook] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = root["daily"] as? [String: Any],
              let time = daily["time"] as? [String] else { throw Failure.badResponse }
        func series(_ name: String) -> [[Double?]] {
            daily.compactMap { entry -> [Double?]? in
                guard entry.key == name || entry.key.hasPrefix(name + "_member"),
                      let list = entry.value as? [Any] else { return nil }
                return list.map { ($0 as? NSNumber)?.doubleValue }
            }
        }
        let rain = series("precipitation_sum"), snow = series("snowfall_sum")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return time.indices.compactMap { i in
            guard let day = f.date(from: time[i]) else { return nil }
            let amounts = rain.compactMap { i < $0.count ? $0[i] : nil }
            guard !amounts.isEmpty else { return nil }
            let snowy = snow.compactMap { i < $0.count ? $0[i] : nil }
            return DayOutlook(day: Calendar.current.startOfDay(for: day),
                              chance: Int((Double(amounts.filter { $0 >= WetDay.millimetres }.count) / Double(amounts.count) * 100).rounded()),
                              millimetres: amounts.reduce(0, +) / Double(amounts.count),
                              // snowfall_sum is in cm.
                              snow: !snowy.isEmpty && snowy.filter { $0 >= 0.5 }.count * 2 > snowy.count)
        }
    }

    // MARK: DWD radar (Bright Sky)

    /// Whether the DWD radar composite reaches this far: a box safely inside its grid,
    /// whose edges always read zero.
    static func radarCovers(_ c: Coordinate) -> Bool {
        (46.5...55.0).contains(c.lat) && (4.5...15.5).contains(c.lon)
    }

    /// Rain at this point, in five-minute steps, from an hour back to two hours ahead.
    /// The point is the mean of the 3 × 3 km around it, so one noisy pixel doesn't decide.
    func radar(at c: Coordinate) async throws -> [RadarStep] {
        guard Self.radarCovers(c) else { return [] }
        var comps = URLComponents(string: "https://api.brightsky.dev/radar")!
        comps.queryItems = [
            .init(name: "lat", value: String(c.lat)),
            .init(name: "lon", value: String(c.lon)),
            .init(name: "distance", value: "3000"),
            .init(name: "format", value: "plain"),
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
        return try Self.parseRadar(data)
    }

    private struct RadarPayload: Decodable {
        struct Record: Decodable {
            let timestamp: String
            /// 0.01 mm per pixel per five minutes; rows north to south, columns west to east.
            let precipitation_5: [[Int?]]
        }
        struct Position: Decodable { let x: Double; let y: Double }
        let radar: [Record]
        /// top, left, bottom, right, in grid pixels.
        let bbox: [Int]?
        let latlon_position: Position?
    }

    static func parseRadar(_ data: Data) throws -> [RadarStep] {
        let p = try JSONDecoder().decode(RadarPayload.self, from: data)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return p.radar.compactMap { r in
            guard let time = iso.date(from: r.timestamp), !r.precipitation_5.isEmpty else { return nil }
            let rows = r.precipitation_5.count, cols = r.precipitation_5[0].count
            // The point within the cut-out; given either within it or on the whole grid.
            var x = p.latlon_position.map { Int($0.x.rounded(.down)) } ?? cols / 2
            var y = p.latlon_position.map { Int($0.y.rounded(.down)) } ?? rows / 2
            if let b = p.bbox, b.count == 4, x >= cols || y >= rows { x -= b[1]; y -= b[0] }
            guard (0..<cols).contains(x), (0..<rows).contains(y) else { return nil }
            var sum = 0, n = 0
            for row in max(0, y - 1)...min(rows - 1, y + 1) {
                let line = r.precipitation_5[row]
                guard line.count > x else { continue }
                for col in max(0, x - 1)...min(line.count - 1, x + 1) {
                    if let v = line[col] { sum += v; n += 1 }
                }
            }
            guard n > 0 else { return nil }
            return RadarStep(time: time, millimetres: Double(sum) / Double(n) / 100)
        }
        .sorted { $0.time < $1.time }
    }
}
