import SwiftUI

enum Theme {
    static let foldHeight: CGFloat = 38
    static let gutter: CGFloat = 44
    static let eventsLeading: CGFloat = gutter + 8
    /// Matches the header's 16pt page margin, so cards line up with the date above.
    static let trailing: CGFloat = 16
    static let topInset: CGFloat = 12
    /// Card corner radius (continuous curve); short cards use a smaller one.
    static let blockRadius: CGFloat = 16

    // Type: the v0.5.3 proportions at about 0.88 of their size.
    static let eventTitle = Font.system(size: 15, weight: .medium)
    static let eventDetail = Font.system(size: 13)
    static let hourLabel = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let mark = Font.system(size: 11, weight: .medium).monospacedDigit()

    // Palette: neutrals for text and structure, three theme colours that each mean one thing.
    /// The page sits a step below white in light mode, so cards can be the brightest thing
    /// on it; black in dark mode.
    static let paper = Color(.systemGroupedBackground)
    static let ink = Color(.label)
    /// Secondary text. Kept dark enough to read at a glance.
    static let graphite = Color(.label).opacity(0.62)
    /// Hour lines: clearly visible, still behind the content.
    static let hairline = Color(.label).opacity(0.16)
    /// Hour numbers. In dark mode full white glows against black and outshouts the events,
    /// so it steps back a little; in light mode it stays full ink.
    static let hourInk = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.72) : .label })
    static let shadow = Color(UIColor { $0.userInterfaceStyle == .dark ? .clear : UIColor.black.withAlphaComponent(0.12) })
    /// The sunrise/sunset ball: a faint grey disc, just enough to hold its glyph.
    static let sunBall = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.06)
    })
    /// Sunshine on the page: light, so on the pale page it is brighter than the paper and on
    /// the black one a faint glow.
    static let sunlight = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.2) : UIColor(white: 1, alpha: 1)
    })
    /// Under the sunshine on the pale page, where light alone hardly shows on the near-white
    /// paper: a soft patch of shade around each cluster of light, as under leaves, so the
    /// spots stand out. Its deepest, at a patch's middle. Nothing on the black page, where
    /// the light shows by itself.
    static let sunShade = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? .clear : UIColor(white: 0, alpha: 0.09)
    })
    /// Rain: wet hours, and trips moved onto transit because of it.
    static let rain = dynamic(light: (0.16, 0.47, 0.84), dark: (0.40, 0.66, 0.96))
    /// Now: the current-time line and today's weekday.
    static let now = dynamic(light: (0.90, 0.26, 0.24), dark: (1.0, 0.42, 0.40))
    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

extension Color {
    init(_ rgb: RGB) { self.init(red: rgb.r, green: rgb.g, blue: rgb.b) }
}

/// How a calendar's colour shows on each appearance.
enum CalendarInk {
    /// The capsule. On a dark page a dark calendar colour (black, navy, brown) would sink
    /// into it, so it is raised to a readable brightness, keeping its hue.
    static func mark(_ rgb: RGB) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? lifted(rgb) : UIColor(rgb) })
    }

    /// The card stands out by being lighter than the page. Light: pure white on the grey
    /// page, with its shadow. Dark: the page's raised grey with the calendar's hue mixed in,
    /// so it reads as that calendar's card rather than a grey slab.
    static func card(_ rgb: RGB) -> Color {
        Color(UIColor { t in
            guard t.userInterfaceStyle == .dark else { return .white }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            lifted(rgb).getRed(&r, green: &g, blue: &b, alpha: &a)
            let base: CGFloat = 0.11, k: CGFloat = 0.2
            return UIColor(red: base + (r - base) * k, green: base + (g - base) * k, blue: base + (b - base) * k, alpha: 1)
        })
    }

    /// A block coloured in its calendar's colour, for the month view's "filled" style. Light
    /// enough under dark text on a white page; on a dark page, deep enough under light text.
    static func fill(_ rgb: RGB) -> Color {
        Color(UIColor { t in
            let dark = t.userInterfaceStyle == .dark
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            (dark ? lifted(rgb) : UIColor(rgb)).getRed(&r, green: &g, blue: &b, alpha: &a)
            let base: CGFloat = dark ? 0.11 : 1, k: CGFloat = dark ? 0.42 : 0.30
            return UIColor(red: base + (r - base) * k, green: base + (g - base) * k, blue: base + (b - base) * k, alpha: 1)
        })
    }

    private static func lifted(_ rgb: RGB) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(rgb).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        // Near black, the hue is noise; it must not turn into a colour when brightened.
        let sure = min(1, v / 0.35)
        return UIColor(hue: h, saturation: s * 0.85 * sure, brightness: max(v, 0.78), alpha: 1)
    }
}

extension UIColor {
    convenience init(_ rgb: RGB) { self.init(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }
}

/// Timeline density, cycled by the header's zoom button.
enum TimelineZoom: Int, CaseIterable {
    case tight, standard, loose

    var hourHeight: CGFloat {
        switch self {
        case .tight: return 52
        case .standard: return 72
        case .loose: return 100
        }
    }

    var next: TimelineZoom { TimelineZoom(rawValue: (rawValue + 1) % Self.allCases.count) ?? .standard }
}

enum Fmt {
    static let time = Date.FormatStyle(locale: Locale(identifier: "zh_CN")).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

    /// Gutter label: the hour alone, "09".
    static func hour(_ d: Date) -> String {
        String(format: "%02d", Calendar.current.component(.hour, from: d))
    }

    /// Month grid title, "11月".
    static func month(_ d: Date) -> String { "\(Calendar.current.component(.month, from: d))月" }

    /// The user's calendar (week start, weekends) with Chinese names for weekdays.
    static let zh: Calendar = {
        var c = Calendar.current
        c.locale = Locale(identifier: "zh_CN")
        return c
    }()

    static func monthDay(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month!)月\(c.day!)日"
    }
    static let weekday = Date.FormatStyle(locale: Locale(identifier: "zh_CN")).weekday(.abbreviated)

    static func minutes(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        return m < 60 ? "\(m) 分钟" : "\(m / 60) 小时 \(m % 60) 分"
    }
}

extension VehicleKind {
    var symbol: String {
        switch self {
        case .bus: return "bus.fill"
        case .tram: return "tram.fill"
        case .subway: return "tram.fill.tunnel"
        case .train: return "train.side.front.car"
        case .other: return "bus.fill"
        }
    }

    var lineSuffix: String {
        switch self {
        case .bus: return " 路"
        default: return ""
        }
    }
}

/// How the month view shows which calendar an event belongs to.
enum MonthColorStyle: String, CaseIterable {
    /// A small dot in the calendar's colour on a plain block.
    case dot
    /// The whole block in the calendar's colour.
    case fill

    static let key = "monthColorStyle"
}

extension EnvironmentValues {
    @Entry var monthColorStyle: MonthColorStyle = .dot
}
