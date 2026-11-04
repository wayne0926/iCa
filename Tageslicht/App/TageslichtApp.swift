import SwiftUI

@main
struct TageslichtApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                // The timeline's geometry is fixed; past this size labels would collide.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .task {
                    FrameStats.shared.startIfRequested()
                    await store.start()
                }
                .onChange(of: phase) { _, p in
                    if p == .active { Task { await store.refresh() } }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoomProbe") {
            ZoomProbe()
        } else {
            content
        }
        #else
        content
        #endif
    }

    @ViewBuilder private var content: some View {
        switch store.access {
        case .denied:
            AccessDeniedView()
        case .unknown, .granted:
            CalendarRoot()
        }
    }
}

/// Zoom source ids: one type at both ends of every zoom. The shown day's cell and the shown
/// month's small copy carry the shared case; every other one its own.
enum ZoomKey: Hashable {
    case shownDay, shownMonth
    case day(Date), month(Date)
}

#if DEBUG
/// Launch with `-zoomProbe`: the system zoom with nothing of the app around it, one row per
/// way of marking the source. A row whose pages open from and close into the middle of the
/// screen marks its source in a way the system doesn't find.
///   A: the visible square itself, own id each (Apple's own pattern)
///   B: an empty Color.clear behind the square, own id each
///   C: a nearly invisible colour behind the square, own id each
///   D: the visible square, one shared id that moves to the tapped square, pushed by
///      tap and path a pass later (how the app opens its pages)
///   E: as D, the source an empty Color.clear behind (exactly what the app did until 0.9.4)
private struct ZoomProbe: View {
    private struct Item: Hashable { let row: Int; let col: Int }
    private static let shared = "probeShown"
    private static let titles = ["A  visible, own id", "B  Color.clear, own id", "C  opacity 0.001, own id",
                                 "D  visible, shared id, tap + path", "E  Color.clear, shared id, tap + path"]
    @Namespace private var ns
    @State private var path: [Item] = []
    @State private var shown: Item?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(0..<5, id: \.self) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.titles[row]).font(.subheadline.weight(.semibold))
                        HStack(spacing: 12) {
                            ForEach(0..<4, id: \.self) { col in
                                let item = Item(row: row, col: col)
                                if row < 3 {
                                    NavigationLink(value: item) { cell(item) }.buttonStyle(.plain)
                                } else {
                                    cell(item)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            shown = item
                                            DispatchQueue.main.async { path.append(item) }
                                        }
                                }
                            }
                        }
                    }
                }
                Text(Self.versionLine).font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Zoom probe")
            .navigationDestination(for: Item.self) { item in
                let page = Color(hue: Double(item.col) / 4, saturation: 0.5, brightness: 0.9)
                    .overlay(Text("\(["A", "B", "C", "D", "E"][item.row])\(item.col + 1)").font(.largeTitle.bold()))
                    .ignoresSafeArea()
                if item.row < 3 {
                    page.navigationTransition(.zoom(sourceID: item, in: ns))
                } else {
                    page.navigationTransition(.zoom(sourceID: Self.shared, in: ns))
                }
            }
        }
    }

    @ViewBuilder private func cell(_ item: Item) -> some View {
        let square = RoundedRectangle(cornerRadius: 10)
            .fill(Color(hue: Double(item.col) / 4, saturation: 0.5, brightness: 0.9))
            .frame(width: 60, height: 60)
        let movingID = item == shown ? AnyHashable(Self.shared) : AnyHashable(item)
        switch item.row {
        case 0: square.matchedTransitionSource(id: item, in: ns)
        case 1: square.background { Color.clear.matchedTransitionSource(id: item, in: ns) }
        case 2: square.background { Color.black.opacity(0.001).matchedTransitionSource(id: item, in: ns) }
        case 3: square.matchedTransitionSource(id: movingID, in: ns)
        default: square.background { Color.clear.matchedTransitionSource(id: movingID, in: ns) }
        }
    }

    private static let versionLine: String = {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b)) · iOS \(UIDevice.current.systemVersion)"
    }()
}
#endif

/// Which day cell and which small month carry the zoom source. Each page zooms with one
/// fixed source id, and the id moves: to what was tapped before the page opens, and to what
/// the page shows now as it pages or scrolls, so it closes into that. Only the
/// `ZoomSource` modifiers read it, so moving it never redraws the cells or grids.
@MainActor
@Observable
final class ZoomMarks {
    /// The day the day pages show.
    var day: Date?
    /// The month at the top of the month view.
    var month = MonthCalendar.thisMonth
    /// Paged into another month: the month view brings it to the top, so the cell is on
    /// screen to close into.
    var jump: Date?
}

/// Makes a day cell or a small month itself the zoom source, as Apple's own examples do:
/// the system zooms from a picture of it into the page and back. It carries the shared id
/// while its date is the shown one, its own otherwise. A modifier, so following the marks
/// re-reads this alone, never the cell it wraps.
struct ZoomSource: ViewModifier {
    enum Kind: Hashable { case day, month }

    let kind: Kind
    let date: Date
    let marks: ZoomMarks
    let zoom: Namespace.ID

    func body(content: Content) -> some View {
        let id: ZoomKey = kind == .day
            ? (marks.day == date ? .shownDay : .day(date))
            : (marks.month == date ? .shownMonth : .month(date))
        content.matchedTransitionSource(id: id, in: zoom)
    }
}

/// Year → months → day, each opening out of the one below with the system zoom, as in
/// iOS Calendar. The app starts on the months (or the year, if that's where it was left).
private struct CalendarRoot: View {
    private enum Route: Hashable {
        case month(Date)
        case day(Date)
    }

    @State private var path: [Route]
    /// The month the year view should have on screen when the months close into it.
    @State private var shownMonth = MonthCalendar.thisMonth
    @State private var marks = ZoomMarks()
    @Namespace private var zoom
    @AppStorage("showYear") private var showYear = false

    init() {
        let atYear = UserDefaults.standard.bool(forKey: "showYear")
        _path = State(initialValue: atYear ? [] : [.month(MonthCalendar.thisMonth)])
    }

    var body: some View {
        NavigationStack(path: $path) {
            YearCalendar(shownMonth: shownMonth, marks: marks, zoom: zoom) { month in
                // The source moves first; the page opens a pass later, so the zoom starts
                // from what was tapped.
                shownMonth = month
                marks.month = month
                DispatchQueue.main.async { path = [.month(month)] }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .month(let month):
                    MonthCalendar(start: month, marks: marks, zoom: zoom,
                                  onYear: { visible in
                                      // The year view brings that year on screen, then the
                                      // months close into its small copy.
                                      shownMonth = visible
                                      marks.month = visible
                                      DispatchQueue.main.async { path.removeAll() }
                                  }) { day in
                        marks.jump = nil
                        marks.day = day
                        DispatchQueue.main.async { path.append(.day(day)) }
                    }
                    // No `.id` here, as in 0.8.8: both zooms run through this page, and the
                    // stack never swaps one month page for another.
                    .toolbar(.hidden, for: .navigationBar)
                    // Outermost, with a fixed id: the source is what moves.
                    .navigationTransition(.zoom(sourceID: ZoomKey.shownMonth, in: zoom))
                case .day(let day):
                    // Paging moves the source with it; crossing into another month also
                    // brings that month to the top of the month view behind.
                    DayPager(start: day, onDayChange: { [marks] now in
                        guard now != marks.day else { return }
                        let before = marks.day.map(Self.monthStart)
                        marks.day = now
                        let month = Self.monthStart(now)
                        if month != before { marks.jump = month }
                    }, onClose: { if !path.isEmpty { path.removeLast() } })
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationTransition(.zoom(sourceID: ZoomKey.shownDay, in: zoom))
                }
            }
        }
        .tint(Theme.ink)
        .onChange(of: path.isEmpty) { _, atYear in showYear = atYear }
    }

    private static func monthStart(_ day: Date) -> Date {
        MonthCalendar.calendar.dateInterval(of: .month, for: day)?.start ?? day
    }
}

private struct AccessDeniedView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.graphite)
            Text("需要日历权限")
                .font(.headline)
            Text("在“设置”里允许 iCa 访问日历，才能显示你的日程。")
                .font(.subheadline)
                .foregroundStyle(Theme.graphite)
                .multilineTextAlignment(.center)
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
    }
}
