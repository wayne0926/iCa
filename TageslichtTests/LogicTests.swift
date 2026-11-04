import XCTest
@testable import Tageslicht

final class SunCalculatorTests: XCTestCase {
    private var berlin: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    private func assertClock(_ date: Date?, _ h: Int, _ m: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let date else { return XCTFail("nil", file: file, line: line) }
        let c = berlin.dateComponents([.hour, .minute], from: date)
        let got = c.hour! * 60 + c.minute!
        XCTAssertEqual(Double(got), Double(h * 60 + m), accuracy: 3, "got \(c.hour!):\(c.minute!)", file: file, line: line)
    }

    func testBonnNovember() {
        let day = berlin.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        let t = SunCalculator.times(on: day, at: .bonn, calendar: berlin)
        assertClock(t.sunrise, 7, 26)
        assertClock(t.sunset, 17, 3)
    }

    func testBonnMidsummerUsesDST() {
        let day = berlin.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12))!
        let t = SunCalculator.times(on: day, at: .bonn, calendar: berlin)
        assertClock(t.sunrise, 5, 18)
        assertClock(t.sunset, 21, 48)
    }

    func testPolarNightHasNoSunrise() {
        let day = berlin.date(from: DateComponents(year: 2026, month: 12, day: 21, hour: 12))!
        let t = SunCalculator.times(on: day, at: Coordinate(lat: 78.2, lon: 15.6), calendar: berlin)
        XCTAssertNil(t.sunrise)
        XCTAssertNil(t.sunset)
    }
}

final class DayLayoutTests: XCTestCase {
    private let cal = Calendar.current
    private lazy var day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_793_700_000))

    private func ev(_ id: String, _ from: Double, _ to: Double, allDay: Bool = false) -> CalEvent {
        CalEvent(id: id, title: id, start: day.addingTimeInterval(from * 3600), end: day.addingTimeInterval(to * 3600),
                 isAllDay: allDay, location: nil, coordinate: nil, calendarTitle: "", calendarColor: RGB(r: 0, g: 0, b: 0))
    }

    func testSeparateEventsTakeFullWidth() {
        let p = DayLayout.place([ev("a", 9, 10), ev("b", 10, 11)], on: day, calendar: cal)
        XCTAssertEqual(p.map(\.columns), [1, 1])
        XCTAssertEqual(p.map(\.column), [0, 0])
    }

    func testChainedOverlapReusesFreedColumn() {
        // a overlaps b, b overlaps c, a ends before c starts: two columns, c goes back to column 0.
        let p = DayLayout.place([ev("c", 11, 12), ev("a", 9, 10.5), ev("b", 10, 11.5)], on: day, calendar: cal)
        let byID = Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0) })
        XCTAssertEqual(byID["a"]?.column, 0)
        XCTAssertEqual(byID["b"]?.column, 1)
        XCTAssertEqual(byID["c"]?.column, 0)
        XCTAssertEqual(Set(p.map(\.columns)), [2])
    }

    func testAllDayIgnoredAndOvernightClipped() {
        let p = DayLayout.place([ev("x", 0, 24, allDay: true), ev("late", 22, 26)], on: day, calendar: cal)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].startHour, 22)
        XCTAssertEqual(p[0].endHour, 24, accuracy: 1) // 23–25 on DST days
    }

    func testTinyEventGetsMinimumHeight() {
        let p = DayLayout.place([ev("t", 9, 9.05)], on: day, calendar: cal)
        XCTAssertEqual(p[0].endHour - p[0].startHour, DayLayout.minimumHours, accuracy: 0.001)
    }
}

final class TravelPolicyTests: XCTestCase {
    private let arrival = Date(timeIntervalSince1970: 1_793_721_600) // some afternoon
    private func bike(_ min: Double) -> RouteResult {
        RouteResult(mode: .bicycle, duration: min * 60, distance: 0, firstLeg: nil, tripStart: nil)
    }
    private func transit(_ min: Double) -> RouteResult {
        RouteResult(mode: .transit, duration: min * 60, distance: 0,
                    firstLeg: TransitLeg(line: "604", vehicle: .bus, departure: arrival.addingTimeInterval(-min * 60 + 120), stop: "Hbf"),
                    tripStart: arrival.addingTimeInterval(-min * 60))
    }
    private func hour(_ offsetHours: Double, mm: Double, prob: Int = 90) -> HourWeather {
        HourWeather(time: arrival.addingTimeInterval(offsetHours * 3600), temperature: 8, precipitation: mm,
                    precipitationProbability: prob, pictocode: mm > 0 ? 23 : 22, isDaylight: true, windSpeed: 2)
    }

    func testDryShortRideIsBike() {
        let p = TravelPolicy.plan(arrival: arrival, bike: bike(12), transit: transit(15), weather: [hour(-1, mm: 0)])
        XCTAssertEqual(p?.mode, .bicycle)
        XCTAssertEqual(p?.leaveAt, arrival.addingTimeInterval(-12 * 60 - TravelPolicy.buffer))
    }

    func testRainDuringRideSwitchesToTransit() {
        let p = TravelPolicy.plan(arrival: arrival, bike: bike(12), transit: transit(15), weather: [hour(-1, mm: 1.2)])
        XCTAssertEqual(p?.mode, .transit)
        XCTAssertEqual(p?.reason, .rain)
        XCTAssertEqual(p?.leaveAt, arrival.addingTimeInterval(-15 * 60))
    }

    func testRainAfterArrivalDoesNotCount() {
        let p = TravelPolicy.plan(arrival: arrival, bike: bike(12), transit: transit(15), weather: [hour(0, mm: 3)])
        XCTAssertEqual(p?.mode, .bicycle)
    }

    func testLongRideWithComparableTransit() {
        let p = TravelPolicy.plan(arrival: arrival, bike: bike(40), transit: transit(35), weather: [])
        XCTAssertEqual(p?.mode, .transit)
        XCTAssertEqual(p?.reason, .far)
    }

    func testWalkOnlyTransitFallsBackToBike() {
        let walkOnly = RouteResult(mode: .transit, duration: 900, distance: 0, firstLeg: nil, tripStart: nil)
        let p = TravelPolicy.plan(arrival: arrival, bike: bike(10), transit: walkOnly, weather: [hour(-1, mm: 2)])
        XCTAssertEqual(p?.mode, .bicycle)
    }
}

final class ParsingTests: XCTestCase {
    func testMeteoblueHourly() throws {
        let json = """
        {"metadata":{"utc_timeoffset":1.0},
         "data_1h":{"time":["2026-11-03 15:00","2026-11-03 16:00"],"temperature":[7.5,6.9],
          "precipitation":[0.0,1.4],"precipitation_probability":[10,85],"pictocode":[22,23],
          "isdaylight":[1,0],"windspeed":[2.1,3.0]}}
        """.data(using: .utf8)!
        let hours = try WeatherService.parse(json)
        XCTAssertEqual(hours.count, 2)
        XCTAssertEqual(hours[1].precipitation, 1.4)
        XCTAssertEqual(hours[0].time, ISO8601DateFormatter().date(from: "2026-11-03T14:00:00Z"))
        XCTAssertFalse(hours[1].isDaylight)
    }

    func testGoogleTransitStartIncludesWalk() throws {
        let json = """
        {"routes":[{"distanceMeters":1499,"duration":"456s","legs":[{"steps":[
          {"staticDuration":"90s","travelMode":"WALK"},{"staticDuration":"30s","travelMode":"WALK"},
          {"staticDuration":"300s","travelMode":"TRANSIT","transitDetails":{
            "stopDetails":{"departureStop":{"name":"Bonn Hbf"},"departureTime":"2026-11-04T15:47:00Z"},
            "transitLine":{"nameShort":"604","vehicle":{"type":"BUS"}}}}]}]}]}
        """.data(using: .utf8)!
        let r = try XCTUnwrap(RoutesService.parse(json, mode: .transit))
        XCTAssertEqual(r.duration, 456)
        XCTAssertEqual(r.firstLeg?.line, "604")
        XCTAssertEqual(r.firstLeg?.vehicle, .bus)
        XCTAssertEqual(r.tripStart, ISO8601DateFormatter().date(from: "2026-11-04T15:45:00Z"))
    }

    func testEmptyRoutesIsNil() throws {
        XCTAssertNil(try RoutesService.parse("{}".data(using: .utf8)!, mode: .bicycle))
    }
}

final class TimeScaleTests: XCTestCase {
    private let m = TimeScale.Metrics()

    func testEdgesFoldAndBusyStaysToScale() {
        let s = TimeScale.make(busy: [10...11.5], dayHours: 24)
        // 0–9:30 folded, 9:30–12 full (padding snapped to half hours), 12–24 folded.
        XCTAssertEqual(s.segments.map(\.start), [0, 9.5, 12])
        XCTAssertEqual(s.segments.map(\.folded), [true, false, true])
        XCTAssertEqual(s.y(11) - s.y(10), m.hourHeight)
        XCTAssertEqual(s.height, m.foldHeight * 2 + 2.5 * m.hourHeight)
    }

    func testShortGapStaysLongGapFolds() {
        let short = TimeScale.make(busy: [9...10, 11.5...12], dayHours: 24)
        XCTAssertEqual(short.segments.map(\.folded), [true, false, false, false, true]) // 30-min gap stays

        let long = TimeScale.make(busy: [9...10, 13...14], dayHours: 24) // 3 h apart
        XCTAssertEqual(long.segments.map(\.folded), [true, false, true, false, true])
        XCTAssertEqual(long.segments[2].start, 10.5)
        XCTAssertEqual(long.segments[2].end, 12.5)
    }

    func testEmptyDayShowsDaytimeCompact() {
        let s = TimeScale.make(busy: [], dayHours: 24)
        XCTAssertEqual(s.segments.map(\.folded), [true, false, true])
        XCTAssertEqual(s.segments[1].height, 14 * m.hourHeight * m.quietScale)
    }

    func testYIsMonotonic() {
        let s = TimeScale.make(busy: [8...9, 14...18, 20...21], dayHours: 24)
        var last: CGFloat = -1
        for h in stride(from: 0.0, through: 24, by: 0.25) {
            XCTAssertGreaterThanOrEqual(s.y(h), last)
            last = s.y(h)
        }
        XCTAssertEqual(s.y(24), s.height)
    }
}

final class PrecipSpanTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_793_660_400)
    private func h(_ hour: Int, _ mm: Double, code: Int = 23) -> HourWeather {
        HourWeather(time: day.addingTimeInterval(Double(hour) * 3600), temperature: 5, precipitation: mm,
                    precipitationProbability: 80, pictocode: code, isDaylight: true, windSpeed: 1)
    }

    func testConsecutiveWetHoursMergeWithPeakIntensity() {
        let s = PrecipSpan.spans(from: [h(13, 0), h(14, 0.4), h(15, 2.5), h(16, 0.2), h(17, 0)], day: day)
        XCTAssertEqual(s, [PrecipSpan(start: 14, end: 17, intensity: 2.5, snow: false, wind: 1)])
    }

    func testGapSplitsAndSnowStaysSeparate() {
        let s = PrecipSpan.spans(from: [h(8, 1), h(10, 1), h(11, 1, code: 24)], day: day)
        XCTAssertEqual(s.map(\.start), [8, 10, 11])
        XCTAssertEqual(s.map(\.snow), [false, false, true])
    }

    func testTraceAmountsIgnored() {
        XCTAssertTrue(PrecipSpan.spans(from: [h(9, 0.05)], day: day).isEmpty)
    }
}

final class ScaleBlendTests: XCTestCase {
    private let folded = TimeScale.make(busy: [10...11], dayHours: 24)
    private let full = TimeScale.make(busy: [0...24], dayHours: 24)

    func testEndpointsMatchTheirScales() {
        let b0 = ScaleBlend(from: folded, to: full, t: 0)
        let b1 = ScaleBlend(from: folded, to: full, t: 1)
        for h in [0.0, 9.5, 10.25, 15, 24] {
            XCTAssertEqual(b0.y(h), folded.y(h), accuracy: 0.001)
            XCTAssertEqual(b1.y(h), full.y(h), accuracy: 0.001)
        }
        XCTAssertEqual(b1.height, full.height, accuracy: 0.001)
    }

    func testHalfwayIsMidpoint() {
        let b = ScaleBlend(from: folded, to: full, t: 0.5)
        XCTAssertEqual(b.y(15), (folded.y(15) + full.y(15)) / 2, accuracy: 0.001)
    }

    func testGridFadesBetweenFoldedAndOpen() {
        // 15:00 is folded in `folded`, a full line in `full`.
        XCTAssertEqual(ScaleBlend(from: folded, to: full, t: 0).gridWeight(15), 0)
        XCTAssertEqual(ScaleBlend(from: folded, to: full, t: 0.25).gridWeight(15), 0.25, accuracy: 0.001)
        XCTAssertEqual(ScaleBlend(from: folded, to: full, t: 1).gridWeight(15), 1)
        XCTAssertEqual(ScaleBlend(from: folded, to: full, t: 0.5).gridWeight(10), 1) // open in both
    }
}

final class ScaleFrameTests: XCTestCase {
    private let folded = TimeScale.make(busy: [10...11], dayHours: 24)
    private let full = TimeScale.make(busy: [0...24], dayHours: 24)
    private let zoomed = TimeScale.make(busy: [0...24], dayHours: 24, metrics: .init(hourHeight: 100))

    func testFrameMatchesItsScale() {
        let f = ScaleFrame(folded)
        for h in stride(from: 0.0, through: 24, by: 0.25) {
            XCTAssertEqual(f.y(h), folded.y(h), accuracy: 0.001)
            XCTAssertEqual(f.hour(atY: f.y(h)), h, accuracy: 0.001)
        }
        XCTAssertEqual(f.gridWeight(15), 0)
        XCTAssertEqual(f.gridWeight(10), 1)
    }

    /// A change that interrupts another starts exactly where the screen is.
    func testInterruptingStartsFromScreen() {
        let mid = ScaleBlend(from: folded, to: full, t: 0.4)
        let next = ScaleBlend(from: mid.frame, to: ScaleFrame(zoomed), t: 0)
        for h in stride(from: 0.0, through: 24, by: 0.5) {
            XCTAssertEqual(next.y(h), mid.y(h), accuracy: 0.001)
            XCTAssertEqual(next.gridWeight(h), mid.gridWeight(h), accuracy: 0.001)
        }
    }
}

final class UsualHoursTests: XCTestCase {
    func testOutlierDoesNotWidenEveryDay() {
        var days: [[ClosedRange<Double>]] = Array(repeating: [9...12, 14...16], count: 18)
        days.append([22...23.5])     // one late night
        days.append([6...7])         // one early morning
        let u = TimeScale.usualHours(days)
        XCTAssertEqual(u, 9...16)
    }

    func testNoEventsNoRange() {
        XCTAssertNil(TimeScale.usualHours([[], []]))
    }
}

final class HyphenationTests: XCTestCase {
    func testBreaksLongGermanWords() {
        let s = Hyphenation.soften("Einführung in die Geographie")
        XCTAssertTrue(s.contains("füh\u{00AD}rung"), s)
        XCTAssertEqual(s.replacingOccurrences(of: Hyphenation.softHyphen, with: ""), "Einführung in die Geographie")
    }

    func testLeavesShortWordsAndChineseAlone() {
        XCTAssertEqual(Hyphenation.soften("B3 VL"), "B3 VL")
        XCTAssertEqual(Hyphenation.soften("语言咖啡"), "语言咖啡")
    }
}

final class TimeScaleInverseTests: XCTestCase {
    func testRoundTrip() {
        let s = TimeScale.make(busy: [9...10.5, 14...15], dayHours: 24)
        for h in stride(from: 9.0, through: 15, by: 0.25) {
            XCTAssertEqual(s.hour(atY: s.y(h)), h, accuracy: 0.001)
        }
    }
}
