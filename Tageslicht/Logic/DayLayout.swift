import Foundation

/// Where a timed event sits on one day's timeline. Positions are in hours from midnight
/// so the view only multiplies by its hour height.
struct PlacedEvent: Identifiable, Hashable {
    let event: CalEvent
    let startHour: Double
    let endHour: Double
    let column: Int
    let columns: Int

    var id: String { event.id }
}

enum DayLayout {
    /// Minimum visual length so a 5-minute event is still tappable.
    static let minimumHours = 0.4

    /// Greedy column packing: overlapping events form a cluster and share its width equally.
    static func place(_ events: [CalEvent], on day: Date, calendar: Calendar = .current) -> [PlacedEvent] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let dayLength = dayEnd.timeIntervalSince(dayStart) / 3600 // 23 or 25 on DST days

        let spans: [(CalEvent, Double, Double)] = events
            .filter { !$0.isAllDay && $0.end > dayStart && $0.start < dayEnd }
            .map { e in
                let s = max(0, e.start.timeIntervalSince(dayStart) / 3600)
                let raw = min(dayLength, e.end.timeIntervalSince(dayStart) / 3600)
                return (e, s, min(dayLength, max(raw, s + minimumHours)))
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 > $1.2 }

        var result: [PlacedEvent] = []
        var cluster: [(CalEvent, Double, Double, Int)] = []
        var columnEnds: [Double] = []
        var clusterEnd = -Double.infinity

        func flush() {
            let count = max(columnEnds.count, 1)
            result += cluster.map { PlacedEvent(event: $0.0, startHour: $0.1, endHour: $0.2, column: $0.3, columns: count) }
            cluster.removeAll()
            columnEnds.removeAll()
        }

        for (e, s, en) in spans {
            if s >= clusterEnd {
                flush()
                clusterEnd = en
            } else {
                clusterEnd = max(clusterEnd, en)
            }
            let col = columnEnds.firstIndex { $0 <= s } ?? columnEnds.count
            if col == columnEnds.count { columnEnds.append(en) } else { columnEnds[col] = en }
            cluster.append((e, s, en, col))
        }
        flush()
        return result
    }
}
