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
        switch store.access {
        case .denied:
            AccessDeniedView()
        case .unknown, .granted:
            CalendarRoot()
        }
    }
}

/// Where the reader is, kept without redrawing anything: the month at the top of the month
/// view and the day the day pages show. Read only when a page opens or closes.
/// Names a zoom source: each day cell and each small month carries its own, for good.
/// The open page names the one it shows now, so after paging or scrolling it closes
/// into the right one.
enum ZoomID: Hashable {
    case day(Date)
    case month(Date)
}

final class NavTracker {
    var month = MonthCalendar.thisMonth
    var day: Date?
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
    @State private var tracker = NavTracker()
    @Namespace private var zoom
    @AppStorage("showYear") private var showYear = false

    init() {
        let atYear = UserDefaults.standard.bool(forKey: "showYear")
        _path = State(initialValue: atYear ? [] : [.month(MonthCalendar.thisMonth)])
    }

    var body: some View {
        NavigationStack(path: $path) {
            YearCalendar(shownMonth: shownMonth, zoom: zoom) { month in
                shownMonth = month
                path = [.month(month)]
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .month(let month):
                    MonthCalendar(start: month, tracker: tracker, zoom: zoom,
                                  onYear: { visible in
                                      // The year view brings that year on screen, then the
                                      // months close into its small copy.
                                      shownMonth = visible
                                      DispatchQueue.main.async { path.removeAll() }
                                  }) { day in
                        tracker.day = day
                        path.append(.day(day))
                    }
                    // A month page opened on another month is a new page, with its own scroll.
                    .id(month)
                    .toolbar(.hidden, for: .navigationBar)
                case .day(let day):
                    DayPager(start: day, zoom: zoom, onDayChange: { [tracker] now in tracker.day = now },
                             onClose: { close(openedOn: day) })
                    .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
        .tint(Theme.ink)
        .onChange(of: path.isEmpty) { _, atYear in showYear = atYear }
    }

    /// Back to the months, zooming into the cell of the day the pages are on now. Paged into
    /// another month: a month view opened on that month takes the place of the old one, so
    /// the cell is there to zoom into.
    private func close(openedOn opened: Date) {
        guard !path.isEmpty else { return }
        let month = Self.monthStart(tracker.day ?? opened)
        if month != Self.monthStart(opened) {
            path = [.month(month)]
        } else {
            path.removeLast()
        }
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
