import CoreLocation
import EventKit
import SwiftUI
import WidgetKit

@main
struct TageslichtWidgets: WidgetBundle {
    var body: some Widget {
        TimelineWidget()
    }
}

/// The day page, small: the next few hours on the hour grid, with the events in them and
/// the red line at now. Once today has nothing left, it turns to tomorrow's first hours.
struct TimelineWidget: Widget {
    static let kind = "DayTimeline"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: Provider()) { entry in
            TimelineWidgetView(entry: entry)
                .containerBackground(for: .widget) { Ink.paper }
        }
        .configurationDisplayName("时间线")
        .description("接下来几个小时的日程；今天的结束后，显示明天的。")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Data

struct Entry: TimelineEntry {
    let date: Date
    let plan: Plan
}

/// Today's and the next two days' events, and each day's weather.
struct Agenda {
    var events: [WidgetSnapshot.Event]
    var symbols: [Date: String]

    static let empty = Agenda(events: [], symbols: [:])

    /// The calendar itself when the widget may read it, so it is current even while the app
    /// stays closed; otherwise the events the app last left. Weather only ever comes from
    /// the app.
    static func load(from today: Date, calendar: Calendar = .current) -> Agenda {
        let snapshot = WidgetSnapshot.read()
        var symbols: [Date: String] = [:]
        for d in snapshot?.days ?? [] { if let s = d.symbol { symbols[calendar.startOfDay(for: d.day)] = s } }
        guard let end = calendar.date(byAdding: .day, value: 3, to: today) else { return .empty }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let store = EKEventStore()
            let hidden = Set(snapshot?.hidden ?? [])
            let shown = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
            if !shown.isEmpty {
                let found = store.events(matching: store.predicateForEvents(withStart: today, end: end, calendars: shown))
                let events = found.filter { !$0.isAllDay }.map { e -> WidgetSnapshot.Event in
                    var r: CGFloat = 0.5, g: CGFloat = 0.5, b: CGFloat = 0.5, a: CGFloat = 1
                    if let c = e.calendar?.cgColor { UIColor(cgColor: c).getRed(&r, green: &g, blue: &b, alpha: &a) }
                    return WidgetSnapshot.Event(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "",
                                                start: e.startDate, end: e.endDate, location: e.location,
                                                r: Double(r), g: Double(g), b: Double(b))
                }
                return Agenda(events: events, symbols: symbols)
            }
        }
        let events = (snapshot?.days ?? []).flatMap(\.events)
        return Agenda(events: events, symbols: symbols)
    }
}

extension Agenda {
    /// As `load`, and when the app has left no weather (its App Group not in force), the
    /// widget asks Open-Meteo itself, for where the phone last was.
    static func loadWithWeather(from today: Date) async -> Agenda {
        var agenda = load(from: today)
        if agenda.symbols.isEmpty, let place = CLLocationManager().location?.coordinate {
            agenda.symbols = await OpenMeteo.symbols(lat: place.latitude, lon: place.longitude)
        }
        return agenda
    }
}

/// The widget's own weather, only when the app's is missing: Open-Meteo's daily weather
/// code for the next three days, as the outline symbol the app would show.
enum OpenMeteo {
    static func symbols(lat: Double, lon: Double) async -> [Date: String] {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "daily", value: "weather_code"),
            .init(name: "forecast_days", value: "3"),
            .init(name: "timezone", value: TimeZone.current.identifier),
        ]
        struct Payload: Decodable {
            struct Daily: Decodable { let time: [String]; let weather_code: [Int?] }
            let daily: Daily
        }
        guard let url = comps.url, let answer = try? await URLSession.shared.data(from: url),
              let p = try? JSONDecoder().decode(Payload.self, from: answer.0) else { return [:] }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        var result: [Date: String] = [:]
        for (i, t) in p.daily.time.enumerated() where i < p.daily.weather_code.count {
            guard let d = f.date(from: t), let code = p.daily.weather_code[i] else { continue }
            result[Calendar.current.startOfDay(for: d)] = symbol(wmo: code)
        }
        return result
    }

    static func symbol(wmo: Int) -> String {
        switch wmo {
        case 0, 1: return "sun.max"
        case 2: return "cloud.sun"
        case 45, 48: return "cloud.fog"
        case 51...57: return "cloud.drizzle"
        case 61, 63: return "cloud.rain"
        case 65, 82: return "cloud.heavyrain"
        case 66, 67: return "cloud.sleet"
        case 71...77, 85, 86: return "cloud.snow"
        case 80, 81: return "cloud.sun.rain"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }
}

/// Which day and which hours to show at a moment, and what is in them.
///
/// - Today, while anything is still to come: from the hour now is in, three and a half
///   hours. More than an hour and a half free before the next event is skipped: the window
///   opens on the hour half an hour before it, so the next event is in view, whole as far
///   as it fits.
/// - Once today's last event is over: tomorrow, from the hour its first event starts in.
/// - Nothing either day: the day it is (or tomorrow, from the evening on), empty.
struct Plan {
    let day: Date
    let isToday: Bool
    /// Hours from the day's midnight.
    let from: Double
    let span: Double
    let events: [WidgetSnapshot.Event]
    let symbol: String?

    /// Hours in view.
    static let window = 3.5

    static func make(at now: Date, agenda: Agenda, calendar: Calendar = .current) -> Plan {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: tomorrow) ?? tomorrow.addingTimeInterval(86400)
        func on(_ d: Date, until e: Date) -> [WidgetSnapshot.Event] {
            agenda.events.filter { $0.end > d && $0.start < e }.sorted { $0.start < $1.start }
        }
        func hours(_ t: Date, from d: Date) -> Double { t.timeIntervalSince(d) / 3600 }
        func plan(_ d: Date, isToday: Bool, from: Double, events: [WidgetSnapshot.Event]) -> Plan {
            Plan(day: d, isToday: isToday, from: max(0, min(from, 24 - window)), span: window, events: events,
                 symbol: agenda.symbols[d])
        }

        let todays = on(today, until: tomorrow)
        if let next = todays.first(where: { $0.end > now }) {
            let nowH = hours(now, from: today)
            var from = nowH.rounded(.down)
            let nextH = hours(next.start, from: today)
            if nextH > nowH + 1.5 { from = (nextH - 0.5).rounded(.down) }
            return plan(today, isToday: true, from: from, events: todays)
        }
        let tomorrows = on(tomorrow, until: dayAfter)
        if let first = tomorrows.first {
            let from = max(0, hours(first.start, from: tomorrow)).rounded(.down)
            return plan(tomorrow, isToday: false, from: from, events: tomorrows)
        }
        let evening = calendar.component(.hour, from: now) >= 18
        return plan(evening ? tomorrow : today, isToday: !evening, from: 8, events: [])
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), plan: Plan.make(at: Date(), agenda: .empty))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        Task {
            let now = Date()
            let agenda = await Agenda.loadWithWeather(from: Calendar.current.startOfDay(for: now))
            completion(Entry(date: now, plan: Plan.make(at: now, agenda: agenda)))
        }
    }

    /// Every quarter hour for three hours, so the red line moves and the window follows,
    /// plus each moment an event starts or ends; then the calendar is read again.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let now = Date()
            let agenda = await Agenda.loadWithWeather(from: Calendar.current.startOfDay(for: now))
            let until = now.addingTimeInterval(3 * 3600)
            var dates = stride(from: 0.0, to: 3 * 3600, by: 15 * 60).map { now.addingTimeInterval($0) }
            for e in agenda.events {
                for t in [e.start, e.end] where t > now && t < until { dates.append(t) }
            }
            let entries = dates.sorted().map { Entry(date: $0, plan: Plan.make(at: $0, agenda: agenda)) }
            completion(Timeline(entries: entries, policy: .atEnd))
        }
    }
}

// MARK: - Look

/// The app's palette, for the widget: the same neutrals and calendar colours (see Theme).
enum Ink {
    /// The app's page: the pale grey of the light page, black on the dark one.
    static let paper = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? .black : UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)
    })
    static let graphite = Color(.label).opacity(0.62)
    static let hairline = Color(.label).opacity(0.16)
    static let hourInk = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.72) : .label })
    static let now = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.42, blue: 0.40, alpha: 1)
                                      : UIColor(red: 0.90, green: 0.26, blue: 0.24, alpha: 1)
    })

    static func mark(_ e: WidgetSnapshot.Event) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? lifted(e) : UIColor(red: e.r, green: e.g, blue: e.b, alpha: 1) })
    }

    static func card(_ e: WidgetSnapshot.Event) -> Color {
        Color(UIColor { t in
            guard t.userInterfaceStyle == .dark else { return .white }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            lifted(e).getRed(&r, green: &g, blue: &b, alpha: &a)
            let base: CGFloat = 0.11, k: CGFloat = 0.2
            return UIColor(red: base + (r - base) * k, green: base + (g - base) * k, blue: base + (b - base) * k, alpha: 1)
        })
    }

    private static func lifted(_ e: WidgetSnapshot.Event) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: e.r, green: e.g, blue: e.b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let sure = min(1, v / 0.35)
        return UIColor(hue: h, saturation: s * 0.85 * sure, brightness: max(v, 0.78), alpha: 1)
    }
}

struct TimelineWidgetView: View {
    let entry: Entry

    private static let zh = Locale(identifier: "zh_CN")

    var body: some View {
        let p = entry.plan
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(monthDay(p.day))
                        .font(.system(size: 15, weight: .bold))
                    Text(p.isToday ? p.day.formatted(Date.FormatStyle(locale: Self.zh).weekday(.abbreviated)) : "明天")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.isToday ? Ink.now : Ink.graphite)
                }
                Spacer(minLength: 0)
                if let s = p.symbol {
                    Image(systemName: s)
                        .font(.system(size: 16, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                }
            }
            .padding(.leading, 2)
            if p.events.isEmpty {
                Spacer(minLength: 0)
                Text(p.isToday ? "今天没有更多日程" : "明天没有日程")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.graphite)
                Spacer(minLength: 0)
            } else {
                MiniTimeline(plan: p, now: entry.date)
            }
        }
        .foregroundStyle(Color(.label))
    }

    private func monthDay(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }
}

/// The hour grid for the plan's window: hour numbers and rules, the events as cards with
/// their calendar's bar, side by side where they overlap, and on today the line at now.
private struct MiniTimeline: View {
    let plan: Plan
    let now: Date

    private static let gutter: CGFloat = 18
    private static let inset: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            let hourHeight = (g.size.height - Self.inset * 2) / plan.span
            let y = { (h: Double) -> CGFloat in Self.inset + CGFloat(h - plan.from) * hourHeight }
            let first = Int(plan.from.rounded(.up))
            let last = Int((plan.from + plan.span).rounded(.down))
            ZStack(alignment: .topLeading) {
                ForEach(Array(first...max(first, last)), id: \.self) { h in
                    Rectangle()
                        .fill(Ink.hairline)
                        .frame(width: g.size.width - Self.gutter, height: 1)
                        .offset(x: Self.gutter, y: y(Double(h)))
                    Text(String(format: "%02d", h % 24))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Ink.hourInk)
                        .frame(width: Self.gutter - 3, alignment: .leading)
                        .offset(y: y(Double(h)) - 6)
                }
                ForEach(placed(), id: \.event.id) { p in
                    let top = y(p.from), bottom = y(p.to)
                    let width = (g.size.width - Self.gutter - 4) / CGFloat(p.columns)
                    Block(event: p.event, height: bottom - top, past: p.event.end <= now)
                        .frame(width: width - (p.columns > 1 ? 3 : 0), height: max(0, bottom - top - 3))
                        .offset(x: Self.gutter + 4 + CGFloat(p.column) * width, y: top + 1.5)
                }
                if plan.isToday {
                    let h = now.timeIntervalSince(plan.day) / 3600
                    if h >= plan.from && h <= plan.from + plan.span {
                        Rectangle()
                            .fill(Ink.now)
                            .frame(width: g.size.width - Self.gutter, height: 1.5)
                            .offset(x: Self.gutter, y: y(h) - 0.75)
                        Circle()
                            .fill(Ink.now)
                            .frame(width: 6, height: 6)
                            .offset(x: Self.gutter - 3, y: y(h) - 3)
                    }
                }
            }
        }
    }

    private struct Placed {
        let event: WidgetSnapshot.Event
        let from: Double
        let to: Double
        var column = 0
        var columns = 1
    }

    /// The events in the window, clipped to it, in columns where they overlap.
    private func placed() -> [Placed] {
        let end = plan.from + plan.span
        var list = plan.events.compactMap { e -> Placed? in
            let s = max(plan.from, e.start.timeIntervalSince(plan.day) / 3600)
            let t = min(end, e.end.timeIntervalSince(plan.day) / 3600)
            return t - s > 0.05 ? Placed(event: e, from: s, to: t) : nil
        }
        // Overlapping runs share the width; each event takes the first free column.
        var i = 0
        while i < list.count {
            var j = i, runEnd = list[i].to
            var columnEnds: [Double] = []
            while j < list.count && (j == i || list[j].from < runEnd) {
                let c = columnEnds.firstIndex { $0 <= list[j].from } ?? columnEnds.count
                if c == columnEnds.count { columnEnds.append(list[j].to) } else { columnEnds[c] = list[j].to }
                list[j].column = c
                runEnd = max(runEnd, list[j].to)
                j += 1
            }
            for k in i..<j { list[k].columns = columnEnds.count }
            i = j
        }
        return list
    }
}

private struct Block: View {
    let event: WidgetSnapshot.Event
    let height: CGFloat
    let past: Bool

    private static let time = Date.FormatStyle(locale: Locale(identifier: "zh_CN")).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Ink.mark(event))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(height >= 44 ? 2 : 1)
                if height >= 34 {
                    Text(detail)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Ink.graphite)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, height >= 22 ? 4 : 1)
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Ink.card(event), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(past ? 0.55 : 1)
    }

    private var detail: String {
        let t = event.start.formatted(Self.time)
        guard let l = event.location?.split(whereSeparator: \.isNewline).first, !l.isEmpty else { return t }
        return t + " · " + l
    }
}
