import Foundation

/// What the app and its widget share, through their App Group.
///
/// Side-loaded, the app is re-signed under the person's own team: SideStore renames it
/// `us.lied.tageslicht.<TEAM>` (the widget `us.lied.tageslicht.<TEAM>.Widget`) and its App
/// Group `group.us.lied.tageslicht.shared.<TEAM>`. The group is named apart from the bundle
/// identifier on purpose: one that equals it is renamed after each target's own identifier,
/// and the app and the widget would end up in different groups. Which name is in force is
/// found at run time: the first the system grants a container for.
enum AppGroup {
    static let base = "group.us.lied.tageslicht.shared"
    private static let appID = "us.lied.tageslicht"

    static let identifier: String? = {
        var candidates = [base]
        if let id = Bundle.main.bundleIdentifier, id.hasPrefix(appID + ".") {
            let rest = id.dropFirst(appID.count + 1).split(separator: ".")
            if let team = rest.first, team != "Widget" { candidates.insert(base + "." + team, at: 0) }
        }
        return candidates.first { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
    }()

    static var container: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }
}

/// The days the widget may show (today and the two after), as the app last knew them: each
/// day's weather, its timed events, and the calendars switched off. The widget reads the
/// calendar itself when it may, and falls back on these events when it may not.
struct WidgetSnapshot: Codable, Equatable {
    struct Event: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let location: String?
        /// The calendar's colour.
        let r: Double
        let g: Double
        let b: Double
    }

    struct Day: Codable, Equatable {
        /// Midnight it starts at.
        let day: Date
        /// The day's weather as an outline SF Symbol, e.g. "cloud.sun"; nil without a forecast.
        let symbol: String?
        let events: [Event]
        let allDay: Int
    }

    var days: [Day]
    var hidden: [String]

    private static let file = "widget-snapshot.json"

    static func read() -> WidgetSnapshot? {
        guard let url = AppGroup.container?.appendingPathComponent(file),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// False without an App Group to write into.
    @discardableResult
    func write() -> Bool {
        guard let url = AppGroup.container?.appendingPathComponent(Self.file),
              let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
