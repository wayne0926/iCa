#if DEBUG
import EventKit

/// Debug builds only: launch with `-seedDemo` to fill an empty simulator calendar
/// with a realistic Bonn week. Skips days that already have the demo events.
enum DemoSeed {
    private static let plan: [(dayOffset: Int, start: Double, end: Double, title: String, place: String?)] = [
        (0, 10.25, 11.75, "Analysis I", "Regina-Pacis-Weg 3, 53113 Bonn"),
        (0, 12.5, 13.5, "午饭", "Nassestraße 11, 53113 Bonn"),
        (0, 16, 18, "Tutorium", "Endenicher Allee 60, 53115 Bonn"),
        (0, 19.5, 21, "语言咖啡", "Bonngasse 10, 53111 Bonn"),
        (1, 9, 10.5, "Lineare Algebra", "Endenicher Allee 60, 53115 Bonn"),
        (1, 10.5, 11, "Sprechstunde", "Endenicher Allee 60, 53115 Bonn"),
        (1, 14, 15, "Bürgeramt", "Stadthaus, Berliner Platz 2, 53111 Bonn"),
        (1, 18, 19.5, "Sport", "Römerstraße 164, 53117 Bonn"),
        (2, 13, 14, "组会", nil),
    ]

    /// `-fakeRain`: tomorrow 14–17 h turns wet, to exercise the rain animation.
    static func rainIfRequested(_ hours: [HourWeather]) -> [HourWeather] {
        guard ProcessInfo.processInfo.arguments.contains("-fakeRain") else { return hours }
        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) else { return hours }
        let wet = tomorrow.addingTimeInterval(14 * 3600)..<tomorrow.addingTimeInterval(17 * 3600)
        return hours.map { h in
            guard wet.contains(h.time) else { return h }
            return HourWeather(time: h.time, temperature: h.temperature, precipitation: 1.2,
                               precipitationProbability: 90, pictocode: 23, isDaylight: h.isDaylight,
                               windSpeed: h.windSpeed)
        }
    }

    static func runIfRequested(store: EKEventStore) {
        guard ProcessInfo.processInfo.arguments.contains("-seedDemo"),
              let calendar = store.defaultCalendarForNewEvents else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for item in plan {
            guard let day = cal.date(byAdding: .day, value: item.dayOffset, to: today),
                  let next = cal.date(byAdding: .day, value: 1, to: day) else { continue }
            let existing = store.events(matching: store.predicateForEvents(withStart: day, end: next, calendars: [calendar]))
            guard !existing.contains(where: { $0.title == item.title }) else { continue }
            let e = EKEvent(eventStore: store)
            e.calendar = calendar
            e.title = item.title
            e.location = item.place
            e.startDate = day.addingTimeInterval(item.start * 3600)
            e.endDate = day.addingTimeInterval(item.end * 3600)
            try? store.save(e, span: .thisEvent, commit: false)
        }
        // Several days at once, to exercise the month's spanning bars.
        if let start = cal.date(byAdding: .day, value: 2, to: today),
           let end = cal.date(byAdding: .day, value: 6, to: today),
           !store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [calendar]))
               .contains(where: { $0.title == "Ersti-Fahrt Eifel" }) {
            let e = EKEvent(eventStore: store)
            e.calendar = calendar
            e.title = "Ersti-Fahrt Eifel"
            e.isAllDay = true
            e.startDate = start
            e.endDate = end
            try? store.save(e, span: .thisEvent, commit: false)
        }
        try? store.commit()
    }
}
#endif
