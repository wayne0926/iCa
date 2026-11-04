import EventKit
import Observation
import UIKit

/// Everything one day page draws. Each page observes only its own model,
/// so loading tomorrow's routes never re-renders today.
@MainActor
@Observable
final class DayModel {
    let day: Date
    var allDay: [CalEvent] = []
    var placed: [PlacedEvent] = []
    var hours: [HourWeather] = []
    /// Today only: the DWD radar's five-minute rain, an hour back to two ahead.
    var radar: [RadarStep] = []
    var summary: DaySummary?
    var sun: SunTimes
    var travel: [String: TravelPlan] = [:]
    /// Events held where the one before them was: nowhere to go.
    var sameRoom: Set<String> = []
    /// The hours every folded page keeps open, shared by all days so paging keeps the
    /// grid level. Nil until there are events to learn it from.
    var usual: ClosedRange<Double>?

    init(day: Date, sun: SunTimes) {
        self.day = day
        self.sun = sun
    }
}

/// One event as the month grid shows it.
struct MonthItem: Hashable {
    let id: String
    /// With soft hyphens, for narrow columns.
    let title: String
    /// Nil for all-day events.
    let start: Date?
    /// The start, written out once here rather than on every redraw.
    let time: String?
    let color: RGB
    /// Runs over more than one day; the grid draws it as one bar, not a chip per day.
    let spanning: Bool
}

/// An event over several days, drawn as one bar across them.
struct MonthSpan: Hashable {
    let id: String
    let title: String
    let color: RGB
    let first: Date
    /// Inclusive.
    let last: Date
}

/// One month of the month grid: its days, and each day's events.
@MainActor
@Observable
final class MonthModel {
    let month: Date
    /// Every day of the month, in order.
    let days: [Date]
    /// Empty cells before the 1st, given the locale's first weekday.
    let leading: Int
    var items: [Date: [MonthItem]] = [:]
    var spans: [MonthSpan] = []
    /// Days likely to be wet, for the rain in their cells.
    var wet: [Date: WetDay] = [:]

    init(month: Date, calendar: Calendar) {
        self.month = month
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
        leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
    }
}

/// A day the forecast gives a good chance of rain or snow.
struct WetDay: Hashable {
    let snow: Bool
    /// Heaviest hour, mm/h.
    let intensity: Double

    /// Enough rain to be more than a few drops: a millimetre over the day, or several
    /// waking hours with rain in them. The hourly chance of rain plays no part: meteoblue
    /// and Open-Meteo give a day of steady rain hours of only 20–50 %, and the month must
    /// show what the day page shows.
    static let millimetres = 1.0
    static let wetHours = 3
    /// Past the hourly forecast, ECMWF's runs vote: at least half of them with a millimetre.
    /// Two weeks and more ahead the share stays near the season's usual (here about 30–60 %);
    /// no day there is a sure thing, only likelier than the others.
    static let outlookChance = 50

    init?(hours: [HourWeather]) {
        let wet = hours.filter { $0.precipitation >= PrecipSpan.threshold }
        let wakingWet = wet.filter { (7..<23).contains(Calendar.current.component(.hour, from: $0.time)) }
        guard hours.reduce(0, { $0 + $1.precipitation }) >= Self.millimetres || wakingWet.count >= Self.wetHours
        else { return nil }
        let snowy = wet.filter { WeatherKind(pictocode: $0.pictocode) == .snow }.count
        snow = snowy * 2 > wet.count
        intensity = wet.map(\.precipitation).max() ?? 0
    }

    /// From the 46-day ensemble, past the hourly forecast: enough of its runs bring rain.
    init?(outlook o: DayOutlook) {
        guard o.chance >= Self.outlookChance else { return nil }
        snow = o.snow
        // Spread over a few hours, as a day's rain usually is.
        intensity = o.millimetres / 6
    }
}

@MainActor
@Observable
final class AppStore {
    enum Access { case unknown, granted, denied }

    private(set) var access: Access = .unknown
    /// Calendars switched off in settings.
    private(set) var hiddenCalendars: Set<String> = []

    @ObservationIgnored private let calendar = Calendar.current
    @ObservationIgnored private let source = CalendarSource()
    @ObservationIgnored private let location = LocationProvider()
    @ObservationIgnored private let weatherService = WeatherService()
    @ObservationIgnored private let routes = RoutesService()

    @ObservationIgnored private var models: [Date: DayModel] = [:]
    @ObservationIgnored private var months: [Date: MonthModel] = [:]
    /// Recurring events repeat their titles; hyphenate each once.
    @ObservationIgnored private var hyphenated: [String: String] = [:]
    @ObservationIgnored private var events: [Date: [CalEvent]] = [:]
    @ObservationIgnored private var routeCache: [String: (bike: RouteResult?, transit: RouteResult?)] = [:]
    /// Forecasts by area (see `Coordinate.area`), and when each was fetched.
    @ObservationIgnored private var forecasts: [Coordinate: [HourWeather]] = [:]
    @ObservationIgnored private var fetchedAt: [Coordinate: Date] = [:]
    @ObservationIgnored private var fetching: Set<Coordinate> = []
    /// ECMWF's 46-day outlook by area, for the month's days past the hourly forecast.
    @ObservationIgnored private var outlooks: [Coordinate: [Date: DayOutlook]] = [:]
    @ObservationIgnored private var radarLoop: Task<Void, Never>?
    @ObservationIgnored private let geocoder = Geocoder()
    /// Event addresses already placed on the map, and those Apple couldn't find.
    @ObservationIgnored private var places: [String: Coordinate] = [:]
    @ObservationIgnored private var unplaceable: Set<String> = []
    @ObservationIgnored private var geocodeQueue: [String] = []
    @ObservationIgnored private var geocoding = false
    @ObservationIgnored private var here: Coordinate = .bonn
    @ObservationIgnored private var started = false
    @ObservationIgnored private var reload: Task<Void, Never>?
    /// Learned from the prefetched months, remembered so the first frame already has it.
    @ObservationIgnored private var usual: ClosedRange<Double>? = AppStore.savedUsual()
    /// Routes wait for a real position, so the Bonn fallback never burns API calls.
    @ObservationIgnored private var locationReady = false

    /// How far ahead routes are looked up; transit timetables beyond a week are guesswork anyway.
    private let travelHorizon: TimeInterval = 7 * 86400

    /// The first frame must already show today: cached weather and today's events are
    /// read synchronously here (a few milliseconds), everything else follows async.
    init() {
        hiddenCalendars = source.hidden
        if let cached = weatherService.cachedNow(at: here.area) { forecasts[here.area] = cached }
        if source.hasAccess {
            access = .granted
            let today = calendar.startOfDay(for: Date())
            if let end = calendar.date(byAdding: .day, value: 1, to: today) {
                events[today] = source.eventsNow(from: today, to: end)
            }
        }
    }

    func start() async {
        guard !started else { return }
        started = true

        if access != .granted {
            access = await source.requestAccess() ? .granted : .denied
        }
        guard access == .granted else { return }
        #if DEBUG
        DemoSeed.runIfRequested(store: source.store)
        DemoSeed.seedSemesterIfRequested(store: source.store)
        #endif
        await prefetchEvents()
        for m in months.values { await loadMonth(m) }

        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: source.store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        }

        if let c = await location.current() { here = c }
        locationReady = true
        startRadar()
        await refreshWeather(force: false)
        for m in models.values { await loadTravel(for: m) }
    }

    /// Called when the app comes back to the foreground.
    func refresh() async {
        guard started else { return }
        await refreshRadar()
        await refreshWeather(force: false)
        if let today = models[calendar.startOfDay(for: Date())] { await loadTravel(for: today) }
    }

    func model(for day: Date) -> DayModel {
        let key = calendar.startOfDay(for: day)
        if let m = models[key] { return m }
        let m = DayModel(day: key, sun: SunCalculator.times(on: key, at: here, calendar: calendar))
        models[key] = m
        m.usual = usual
        fillWeather(m)
        if let hit = events[key] {
            // Cache hit: the page is complete on its first frame.
            fill(m, with: hit)
            Task { await loadTravel(for: m) }
        } else if access == .granted {
            Task { await loadEvents(for: m) }
        }
        return m
    }

    func month(for date: Date) -> MonthModel {
        let key = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        if let m = months[key] { return m }
        let m = MonthModel(month: key, calendar: calendar)
        months[key] = m
        if m.days.allSatisfy({ events[$0] != nil }) {
            // Inside the prefetched window: dots on the first frame.
            fillItems(m)
        } else if access == .granted {
            Task { await loadMonth(m) }
        }
        return m
    }

    // MARK: - Events

    /// One query for two months around today, split per day, so paging never waits on EventKit.
    private func prefetchEvents() async {
        let today = calendar.startOfDay(for: Date())
        guard let from = calendar.date(byAdding: .day, value: -14, to: today),
              let to = calendar.date(byAdding: .day, value: 60, to: today) else { return }
        let list = await source.events(from: from, to: to)
        var byDay: [Date: [CalEvent]] = [:]
        var day = from
        while day < to {
            byDay[day] = []
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? to
        }
        for e in list {
            // An event lands on every day it overlaps.
            var d = max(calendar.startOfDay(for: e.start), from)
            while d < min(e.end, to) || (d == calendar.startOfDay(for: e.start) && e.end == e.start) {
                byDay[d, default: []].append(e)
                guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
                d = next
            }
        }
        events.merge(byDay) { _, new in new }
        learnUsual()
        for m in models.values {
            if m.usual != usual { m.usual = usual }
            if let hit = events[m.day] { fill(m, with: hit) }
        }
    }

    private func loadEvents(for m: DayModel) async {
        let start = m.day
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let list: [CalEvent]
        if let hit = events[start] {
            list = hit
        } else {
            list = await source.events(from: start, to: end)
            events[start] = list
        }
        fill(m, with: list)
        await loadTravel(for: m)
    }

    /// One query per month outside the prefetched window; its days are kept for the day pages too.
    private func loadMonth(_ m: MonthModel) async {
        if !m.days.allSatisfy({ events[$0] != nil }),
           let end = calendar.date(byAdding: .month, value: 1, to: m.month) {
            let list = await source.events(from: m.month, to: end)
            for d in m.days {
                guard events[d] == nil, let next = calendar.date(byAdding: .day, value: 1, to: d) else { continue }
                events[d] = list.filter { $0.start < next && ($0.end > d || $0.start == d) }
            }
        }
        fillItems(m)
    }

    /// All-day events first, then by start time; the grid shows the first few.
    private func fillItems(_ m: MonthModel) {
        var items: [Date: [MonthItem]] = [:]
        var spans: [String: MonthSpan] = [:]
        for d in m.days {
            guard let list = events[d], !list.isEmpty else { continue }
            items[d] = list.sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }.map { e in
                let title = hyphenated[e.title] ?? Hyphenation.soften(e.title)
                hyphenated[e.title] = title
                // The day it ends on: an end at midnight belongs to the day before.
                let first = calendar.startOfDay(for: e.start)
                let last = calendar.startOfDay(for: max(e.start, e.end.addingTimeInterval(-1)))
                let spanning = last > first
                if spanning, spans[e.id] == nil {
                    spans[e.id] = MonthSpan(id: e.id, title: e.title, color: e.calendarColor, first: first, last: last)
                }
                // An event carried over from yesterday starts, for this day, at midnight.
                let start = e.isAllDay ? nil : max(e.start, d)
                return MonthItem(id: e.id, title: title, start: start, time: start?.formatted(Fmt.time),
                                 color: e.calendarColor, spanning: spanning)
            }
        }
        let ordered = spans.values.sorted { ($0.first, $1.last, $0.title) < ($1.first, $0.last, $1.title) }
        if items != m.items { m.items = items }
        if ordered != m.spans { m.spans = ordered }
        // Its events decide where each day's weather comes from.
        fillWet(m)
    }

    private func fill(_ m: DayModel, with list: [CalEvent]) {
        let allDay = list.filter(\.isAllDay).sorted { $0.title < $1.title }
        let placed = DayLayout.place(list, on: m.day, calendar: calendar)
        if allDay != m.allDay { m.allDay = allDay }
        if placed != m.placed {
            m.placed = placed
            // Its events decide where the day's weather comes from, and the days beside it.
            fillWeather(m)
            for step in [-1, 1] {
                if let d = calendar.date(byAdding: .day, value: step, to: m.day), let n = models[d] { fillWeather(n) }
            }
        }
    }

    /// Only the prefetched window votes, and only when it is (re)loaded: a day loaded
    /// later never moves the grid under pages already on screen.
    private func learnUsual() {
        let days = events.map { day, list in
            DayLayout.place(list, on: day, calendar: calendar).map { $0.startHour...$0.endHour }
        }
        guard let new = TimeScale.usualHours(days), new != usual else { return }
        usual = new
        UserDefaults.standard.set([new.lowerBound, new.upperBound], forKey: "usualHours")
    }

    private static func savedUsual() -> ClosedRange<Double>? {
        guard let v = UserDefaults.standard.array(forKey: "usualHours") as? [Double], v.count == 2, v[0] < v[1]
        else { return nil }
        return v[0]...v[1]
    }

    /// Every calendar on the device, grouped by account, for settings.
    func calendarGroups() -> [(source: String, calendars: [CalendarSource.Info])] {
        let all = source.calendars()
        let order = Array(NSOrderedSet(array: all.map(\.source))) as? [String] ?? []
        return order.map { s in (s, all.filter { $0.source == s }.sorted { $0.title < $1.title }) }
    }

    func setCalendar(_ id: String, shown: Bool) {
        if shown { hiddenCalendars.remove(id) } else { hiddenCalendars.insert(id) }
        source.hidden = hiddenCalendars
        scheduleReload()
    }

    /// A sync sends EKEventStoreChanged in bursts, and settings toggles come several at once:
    /// one reload once they have stopped for a moment, not one per notice.
    private func scheduleReload() {
        reload?.cancel()
        reload = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await calendarChanged()
        }
    }

    /// One query per month that anything has asked for, never one per day: the day pages
    /// already opened are then filled from those months.
    private func calendarChanged() async {
        events.removeAll()
        await prefetchEvents()
        for key in Set(models.keys.map(monthStart)) where months[key] == nil {
            months[key] = MonthModel(month: key, calendar: calendar)
        }
        for m in months.values.sorted(by: { $0.month < $1.month }) {
            guard !Task.isCancelled else { return }
            await loadMonth(m)
        }
        for m in models.values {
            guard !Task.isCancelled else { return }
            await loadEvents(for: m)
        }
    }

    private func monthStart(_ day: Date) -> Date {
        calendar.dateInterval(of: .month, for: day)?.start ?? day
    }

    // MARK: - Weather

    private func refreshWeather(force: Bool) async {
        let areas = Set(models.values.map { area(on: $0.day) }).union([here.area])
        for a in areas { await fetchForecast(a, force: force) }
    }

    private func fetchForecast(_ a: Coordinate, force: Bool) async {
        if !force, let t = fetchedAt[a], Date().timeIntervalSince(t) < WeatherService.refreshAfter { return }
        guard !fetching.contains(a) else { return }
        fetching.insert(a)
        defer { fetching.remove(a) }
        guard var hours = try? await weatherService.forecast(at: a, force: force) else {
            // Try this area again in five minutes, not on every redraw.
            fetchedAt[a] = Date().addingTimeInterval(5 * 60 - WeatherService.refreshAfter)
            return
        }
        #if DEBUG
        hours = DemoSeed.rainIfRequested(hours)
        #endif
        fetchedAt[a] = Date()
        forecasts[a] = hours
        if let days = try? await weatherService.outlook(at: a) {
            outlooks[a] = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { $1 })
        }
        for m in models.values where area(on: m.day) == a {
            fillWeather(m)
            replan(m)
        }
        for m in months.values { fillWet(m) }
    }

    /// Where a day's weather comes from: the first of its events that can be placed on the
    /// map; without one, the last such event the day before (where the morning starts),
    /// then the first the day after; else where the phone is. Two days away no longer
    /// counts. Unplaced addresses are looked up in the background, the phone's area
    /// standing in meanwhile.
    private func area(on day: Date) -> Coordinate {
        let timed = { (d: Date?) -> [CalEvent] in d.flatMap { self.events[$0] }?.filter { !$0.isAllDay } ?? [] }
        let candidates = [
            timed(day).sorted { $0.start < $1.start },
            timed(calendar.date(byAdding: .day, value: -1, to: day)).sorted { $0.start > $1.start },
            timed(calendar.date(byAdding: .day, value: 1, to: day)).sorted { $0.start < $1.start },
        ]
        for list in candidates {
            switch spot(of: list) {
            case .at(let c): return c
            case .pending: return here.area
            case .nowhere: continue
            }
        }
        return here.area
    }

    private enum Spot { case at(Coordinate), pending, nowhere }

    /// The area of the first of these events that has a place.
    private func spot(of list: [CalEvent]) -> Spot {
        for e in list {
            if let c = e.coordinate { return .at(c.area) }
            guard let address = e.location?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty,
                  !unplaceable.contains(address) else { continue }
            if let c = places[address] ?? geocoder.cachedNow(address) {
                places[address] = c
                return .at(c.area)
            }
            geocode(address)
            return .pending
        }
        return .nowhere
    }

    private func geocode(_ address: String) {
        guard !geocodeQueue.contains(address) else { return }
        geocodeQueue.append(address)
        guard !geocoding else { return }
        geocoding = true
        Task {
            // One at a time: Apple's geocoder throttles bursts.
            while !geocodeQueue.isEmpty {
                let next = geocodeQueue.removeFirst()
                if let c = await geocoder.coordinate(for: next, near: here) {
                    places[next] = c
                } else {
                    unplaceable.insert(next)
                }
                // It may decide the weather of its own day or of the days beside it.
                for m in models.values { fillWeather(m) }
                for m in months.values { fillWet(m) }
            }
            geocoding = false
        }
    }

    private func fillWeather(_ m: DayModel) {
        guard let end = calendar.date(byAdding: .day, value: 1, to: m.day) else { return }
        let a = area(on: m.day)
        guard let forecast = forecasts[a] else {
            // Not fetched yet: the phone's area stands in until it arrives.
            if started { Task { await fetchForecast(a, force: false) } }
            if let near = forecasts[here.area], a != here.area { apply(near, to: m, until: end) }
            applyOutlook(a, to: m)
            return
        }
        apply(forecast, to: m, until: end)
        applyOutlook(a, to: m)
    }

    /// A day past the hourly forecast still gets its weather in the header, from the
    /// 46-day ensemble.
    private func applyOutlook(_ a: Coordinate, to m: DayModel) {
        guard m.hours.isEmpty, let o = (outlooks[a] ?? outlooks[here.area])?[m.day] else { return }
        let s = DaySummary(outlook: o)
        if s != m.summary { m.summary = s }
    }

    /// The month's likely wet days, each from its own place's forecast. Days not yet
    /// forecast (past, or beyond 16 days) stay dry.
    private func fillWet(_ m: MonthModel) {
        let today = calendar.startOfDay(for: Date())
        var wet: [Date: WetDay] = [:]
        for d in m.days where d >= today {
            guard let end = calendar.date(byAdding: .day, value: 1, to: d) else { continue }
            let a = area(on: d)
            if forecasts[a] == nil, started { Task { await fetchForecast(a, force: false) } }
            // Hourly where there is a forecast for the whole day, the ensemble after that.
            if let forecast = forecasts[a] ?? forecasts[here.area], let last = forecast.last?.time, last >= end.addingTimeInterval(-3600) {
                if let w = WetDay(hours: forecast.filter { $0.time >= d && $0.time < end }) { wet[d] = w }
            } else if let o = (outlooks[a] ?? outlooks[here.area])?[d], let w = WetDay(outlook: o) {
                wet[d] = w
            }
        }
        if wet != m.wet { m.wet = wet }
    }

    // MARK: - Radar

    /// Every five minutes while the app is open, as often as the radar itself: today's
    /// rain from the DWD radar where it reaches (Germany and around it).
    private func startRadar() {
        guard radarLoop == nil else { return }
        radarLoop = Task {
            while !Task.isCancelled {
                await refreshRadar()
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
    }

    private func refreshRadar() async {
        let today = calendar.startOfDay(for: Date())
        // The radar is sharp to a kilometre: the phone's own position, not its area, when
        // that is where the day is.
        let a = area(on: today)
        let steps = (try? await weatherService.radar(at: a == here.area ? here : a)) ?? []
        let m = model(for: today)
        // Nothing back, or out of range: the forecast speaks alone.
        guard steps != m.radar else { return }
        m.radar = steps
        replan(m)
    }

    private func apply(_ forecast: [HourWeather], to m: DayModel, until end: Date) {
        let hours = forecast.filter { $0.time >= m.day && $0.time < end }
        if hours != m.hours {
            m.hours = hours
            m.summary = DaySummary(hours: hours, calendar: calendar)
        }
        let sun = SunCalculator.times(on: m.day, at: here, calendar: calendar)
        if sun != m.sun { m.sun = sun }
    }

    // MARK: - Travel

    private func loadTravel(for m: DayModel) async {
        guard locationReady else { return }
        let now = Date()
        let trips = tripsNeeded(m, now: now)
        guard !trips.isEmpty else {
            if !m.travel.isEmpty { m.travel = [:] }
            return
        }
        let routes = self.routes
        await withTaskGroup(of: (String, RouteResult?, RouteResult?).self) { group in
            for trip in trips where routeCache[trip.key] == nil {
                group.addTask {
                    async let b = try? routes.bike(from: trip.from, to: trip.to)
                    async let t = try? routes.transit(from: trip.from, to: trip.to, arrival: trip.arrival)
                    return (trip.key, (await b) ?? nil, (await t) ?? nil)
                }
            }
            for await (key, b, t) in group { routeCache[key] = (b, t) }
        }
        replan(m)
    }

    private struct Trip {
        let eventID: String
        let from: Place
        let to: Place
        let arrival: Date
        var key: String { "\(from.cacheKey)|\(to.cacheKey)|\(Int(arrival.timeIntervalSince1970))" }
    }

    /// Origin is the previous event's place if it ended recently, otherwise where the phone is.
    private func tripsNeeded(_ m: DayModel, now: Date) -> [Trip] {
        let timed = m.placed.map(\.event).sorted { $0.start < $1.start }
        var trips: [Trip] = []
        for (i, e) in timed.enumerated() {
            guard e.hasPlace, e.start > now, e.start.timeIntervalSince(now) < travelHorizon,
                  let to = place(of: e) else { continue }
            var from = Place.coordinate(here)
            if let prev = timed[..<i].last(where: { $0.hasPlace && $0.end <= e.start }),
               e.start.timeIntervalSince(prev.end) < 4 * 3600, let p = place(of: prev) {
                if p.cacheKey == to.cacheKey { continue } // same room, no trip
                from = p
            }
            trips.append(Trip(eventID: e.id, from: from, to: to, arrival: e.start))
        }
        return trips
    }

    /// Events in the same place as the one just before them (within four hours).
    private func sameRoom(_ m: DayModel) -> Set<String> {
        let timed = m.placed.map(\.event).sorted { $0.start < $1.start }
        var ids: Set<String> = []
        for (i, e) in timed.enumerated() {
            guard let to = place(of: e),
                  let prev = timed[..<i].last(where: { $0.hasPlace && $0.end <= e.start }),
                  e.start.timeIntervalSince(prev.end) < 4 * 3600, let p = place(of: prev),
                  p.cacheKey == to.cacheKey else { continue }
            ids.insert(e.id)
        }
        return ids
    }

    private func place(of e: CalEvent) -> Place? {
        if let c = e.coordinate { return .coordinate(c) }
        if let l = e.location?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty { return .address(l) }
        return nil
    }

    private func replan(_ m: DayModel) {
        var plans: [String: TravelPlan] = [:]
        for trip in tripsNeeded(m, now: Date()) {
            guard let r = routeCache[trip.key],
                  let plan = TravelPolicy.plan(arrival: trip.arrival, bike: r.bike, transit: r.transit,
                                               weather: m.hours, radar: m.radar)
            else { continue }
            plans[trip.eventID] = plan
        }
        if plans != m.travel { m.travel = plans }
        let same = sameRoom(m)
        if same != m.sameRoom { m.sameRoom = same }
    }
}
