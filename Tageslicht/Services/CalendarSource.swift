import EventKit
import UIKit

/// Read-only access to the system calendar. Everything leaving this type is a `CalEvent` value.
final class CalendarSource: @unchecked Sendable {
    let store = EKEventStore()

    /// One calendar as the settings list shows it.
    struct Info: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let color: RGB
        /// The account it belongs to: iCloud, Exchange, Subscribed, …
        let source: String
    }

    private let lock = NSLock()
    private var _hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? [])

    /// Calendars switched off in settings, by identifier. Remembered across launches.
    var hidden: Set<String> {
        get { lock.withLock { _hidden } }
        set {
            lock.withLock { _hidden = newValue }
            UserDefaults.standard.set(Array(newValue), forKey: "hiddenCalendars")
        }
    }

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func calendars() -> [Info] {
        store.calendars(for: .event).map {
            Info(id: $0.calendarIdentifier, title: $0.title, color: Self.rgb($0.cgColor), source: $0.source.title)
        }
    }

    /// Nil when every calendar is switched off: nothing to fetch.
    private func predicate(from: Date, to: Date) -> NSPredicate? {
        let hidden = self.hidden
        guard !hidden.isEmpty else { return store.predicateForEvents(withStart: from, end: to, calendars: nil) }
        let shown = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { return nil }
        return store.predicateForEvents(withStart: from, end: to, calendars: shown)
    }

    /// Synchronous fetch for the first frame only; everything else goes through `events(from:to:)`.
    func eventsNow(from: Date, to: Date) -> [CalEvent] {
        guard let p = predicate(from: from, to: to) else { return [] }
        return store.events(matching: p).map(Self.snapshot)
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Fetches [from, to) off the main thread and snapshots each event.
    func events(from: Date, to: Date) async -> [CalEvent] {
        await Task.detached(priority: .userInitiated) { [self] in
            guard let p = predicate(from: from, to: to) else { return [] }
            return store.events(matching: p).map(Self.snapshot)
        }.value
    }

    /// Converted explicitly: a colour in another space (grey, P3, …) would otherwise read
    /// back as black.
    private static func rgb(_ cg: CGColor?) -> RGB {
        guard let cg, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = cg.converted(to: space, intent: .defaultIntent, options: nil)?.components, c.count >= 3
        else { return RGB(r: 0.5, g: 0.5, b: 0.5) }
        return RGB(r: min(1, max(0, c[0])), g: min(1, max(0, c[1])), b: min(1, max(0, c[2])))
    }

    private static func snapshot(_ e: EKEvent) -> CalEvent {
        let rgb = rgb(e.calendar?.cgColor)
        let geo = e.structuredLocation?.geoLocation?.coordinate
        // Recurring occurrences share eventIdentifier; the start date makes them unique.
        let id = "\(e.eventIdentifier ?? e.calendarItemIdentifier)@\(Int(e.startDate.timeIntervalSince1970))"
        return CalEvent(
            id: id,
            title: e.title?.isEmpty == false ? e.title! : "无标题",
            start: e.startDate,
            end: e.endDate,
            isAllDay: e.isAllDay,
            location: e.location,
            coordinate: geo.map { Coordinate(lat: $0.latitude, lon: $0.longitude) },
            calendarTitle: e.calendar?.title ?? "",
            calendarColor: rgb
        )
    }
}
