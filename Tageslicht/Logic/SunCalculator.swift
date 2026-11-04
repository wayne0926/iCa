import Foundation

/// Sunrise/sunset from the classic Almanac for Computers algorithm (official zenith 90.833°).
/// Accurate to about a minute at mid latitudes, which is all a timeline needs.
enum SunCalculator {
    static func times(on day: Date, at c: Coordinate, calendar: Calendar = .current) -> SunTimes {
        SunTimes(sunrise: event(rising: true, day: day, c: c, calendar: calendar),
                 sunset: event(rising: false, day: day, c: c, calendar: calendar))
    }

    private static func event(rising: Bool, day: Date, c: Coordinate, calendar: Calendar) -> Date? {
        let rad = Double.pi / 180
        guard let n = calendar.ordinality(of: .day, in: .year, for: day) else { return nil }
        let lngHour = c.lon / 15
        let t = Double(n) + ((rising ? 6 : 18) - lngHour) / 24

        let m = 0.9856 * t - 3.289
        var l = m + 1.916 * sin(m * rad) + 0.020 * sin(2 * m * rad) + 282.634
        l = normalize(l, 360)

        var ra = normalize(atan(0.91764 * tan(l * rad)) / rad, 360)
        ra += floor(l / 90) * 90 - floor(ra / 90) * 90
        ra /= 15

        let sinDec = 0.39782 * sin(l * rad)
        let cosDec = cos(asin(sinDec))
        let cosH = (cos(90.833 * rad) - sinDec * sin(c.lat * rad)) / (cosDec * cos(c.lat * rad))
        guard cosH >= -1, cosH <= 1 else { return nil } // polar day / night

        var h = acos(cosH) / rad
        if rising { h = 360 - h }
        h /= 15

        let localMean = h + ra - 0.06571 * t - 6.622
        let ut = normalize(localMean - lngHour, 24)

        // UT hours are counted from midnight UTC of the same calendar date.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let ymd = calendar.dateComponents([.year, .month, .day], from: day)
        guard let midnightUTC = utc.date(from: ymd) else { return nil }
        var result = midnightUTC.addingTimeInterval(ut * 3600)
        // Far from the time zone's meridian the UT date can roll over; pull it back onto `day`.
        let dayStart = calendar.startOfDay(for: day)
        if result < dayStart { result += 86400 }
        if result >= dayStart.addingTimeInterval(86400) { result -= 86400 }
        return result
    }

    private static func normalize(_ v: Double, _ range: Double) -> Double {
        let r = v.truncatingRemainder(dividingBy: range)
        return r < 0 ? r + range : r
    }
}
