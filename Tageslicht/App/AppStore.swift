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

    init(month: Date, calendar: Calendar) {
        self.month = month
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
        leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
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
        await refreshWeather(force: false)
        for m in models.values { await loadTravel(for: m) }
    }

    /// Called when the app comes back to the foreground.
    func refresh() async {
        guard started else { return }
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
    }

    private func fill(_ m: DayModel, with list: [CalEvent]) {
        let allDay = list.filter(\.isAllDay).sorted { $0.title < $1.title }
        let placed = DayLayout.place(list, on: m.day, calendar: calendar)
        if allDay != m.allDay { m.allDay = allDay }
        if placed != m.placed {
            m.placed = placed
            // Its events decide where the day's weather comes from.
            fillWeather(m)
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
        let areas = Set(models.values.map(area(of:))).union([here.area])
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
        for m in models.values where area(of: m) == a {
            fillWeather(m)
            replan(m)
        }
    }

    /// Where a day's weather comes from: the first of its events that can be placed on the
    /// map, else where the phone is. Unplaced addresses are looked up in the background.
    private func area(of m: DayModel) -> Coordinate {
        for e in m.placed.map(\.event).sorted(by: { $0.start < $1.start }) {
            if let c = e.coordinate { return c.area }
            guard let address = e.location?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty,
                  !unplaceable.contains(address) else { continue }
            if let c = places[address] ?? geocoder.cachedNow(address) {
                places[address] = c
                return c.area
            }
            geocode(address)
            break
        }
        return here.area
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
                for m in models.values where m.placed.contains(where: { $0.event.location?.trimmingCharacters(in: .whitespacesAndNewlines) == next }) {
                    fillWeather(m)
                }
            }
            geocoding = false
        }
    }

    private func fillWeather(_ m: DayModel) {
        guard let end = calendar.date(byAdding: .day, value: 1, to: m.day) else { return }
        let a = area(of: m)
        guard let forecast = forecasts[a] else {
            // Not fetched yet: the phone's area stands in until it arrives.
            if started { Task { await fetchForecast(a, force: false) } }
            if let near = forecasts[here.area], a != here.area { apply(near, to: m, until: end) }
            return
        }
        apply(forecast, to: m, until: end)
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
                  let plan = TravelPolicy.plan(arrival: trip.arrival, bike: r.bike, transit: r.transit, weather: m.hours)
            else { continue }
            plans[trip.eventID] = plan
        }
        if plans != m.travel { m.travel = plans }
        let same = sameRoom(m)
        if same != m.sameRoom { m.sameRoom = same }
    }
}
