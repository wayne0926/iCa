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
                .task { await store.start() }
                .onChange(of: phase) { _, p in
                    if p == .active { Task { await store.refresh() } }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        switch store.access {
        case .denied:
            AccessDeniedView()
        case .unknown, .granted:
            CalendarRoot()
        }
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
            Text("在“设置”里允许 Tageslicht 访问日历，才能显示你的日程。")
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
