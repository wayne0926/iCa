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

#if DEBUG
/// Launch with `-zoomProbe`: the system zoom with nothing of the app around it, one row per
/// way of marking the source. A row whose pages open from and close into the middle of the
/// screen marks its source in a way this system doesn't find.
///   A: the visible square itself (Apple's own pattern)
///   B: an empty Color.clear behind the square (what the app does)
///   C: a nearly invisible colour behind the square
private struct ZoomProbe: View {
    private struct Item: Hashable { let row: Int; let col: Int }
    @Namespace private var ns

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(0..<3, id: \.self) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(["A  visible square", "B  Color.clear behind", "C  opacity 0.001 behind"][row])
                            .font(.headline)
                        HStack(spacing: 12) {
                            ForEach(0..<4, id: \.self) { col in
                                NavigationLink(value: Item(row: row, col: col)) { cell(row: row, col: col) }
                                    .buttonStyle(.plain)
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
                Color(hue: Double(item.col) / 4, saturation: 0.5, brightness: 0.9)
                    .overlay(Text("\(["A", "B", "C"][item.row])\(item.col + 1)").font(.largeTitle.bold()))
                    .ignoresSafeArea()
                    .navigationTransition(.zoom(sourceID: item, in: ns))
            }
        }
    }

    @ViewBuilder private func cell(row: Int, col: Int) -> some View {
        let square = RoundedRectangle(cornerRadius: 10)
            .fill(Color(hue: Double(col) / 4, saturation: 0.5, brightness: 0.9))
            .frame(width: 64, height: 64)
        let id = Item(row: row, col: col)
        switch row {
        case 0: square.matchedTransitionSource(id: id, in: ns)
        case 1: square.background { Color.clear.matchedTransitionSource(id: id, in: ns) }
        default: square.background { Color.black.opacity(0.001).matchedTransitionSource(id: id, in: ns) }
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

/// Year → months → day, each opening out of the one below with the system zoom, as in
/// iOS Calendar. The app starts on the months (or the year, if that's where it was left).
private struct CalendarRoot: View {
    private enum Route: Hashable {
        case month(Date)
        case day(Date)
    }

    @State private var path: [Route]
    @State private var jump: Date?
    /// The month the month view shows, and the day the day pages show; their small copies
    /// below carry the zoom sources.
    @State private var shownMonth = MonthCalendar.thisMonth
    @State private var shownDay: Date?
    @Namespace private var zoom
    @AppStorage("showYear") private var showYear = false

    init() {
        let atYear = UserDefaults.standard.bool(forKey: "showYear")
        _path = State(initialValue: atYear ? [] : [.month(MonthCalendar.thisMonth)])
    }

    var body: some View {
        NavigationStack(path: $path) {
            YearCalendar(shownMonth: shownMonth, zoom: zoom) { month in
                // The source moves first; the page opens a pass later, so the zoom starts
                // from what was tapped.
                shownMonth = month
                DispatchQueue.main.async { path = [.month(month)] }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .month(let month):
                    MonthCalendar(start: month, jump: $jump, shown: shownDay, zoom: zoom,
                                  onVisibleMonth: { shownMonth = $0 },
                                  onYear: { path.removeAll() }) { day in
                        shownDay = day
                        DispatchQueue.main.async { path.append(.day(day)) }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationTransition(.zoom(sourceID: YearCalendar.shownSource, in: zoom))
                case .day(let day):
                    DayPager(start: day, onDayChange: { now in
                        shownDay = now
                        // Paged into another month: going back lands on that month.
                        jump = MonthCalendar.calendar.dateInterval(of: .month, for: now)?.start
                    }, onClose: { if !path.isEmpty { path.removeLast() } })
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationTransition(.zoom(sourceID: MonthCalendar.shownSource, in: zoom))
                }
            }
        }
        .tint(Theme.ink)
        .onChange(of: path.isEmpty) { _, atYear in showYear = atYear }
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
