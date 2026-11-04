import SwiftUI

/// Horizontal paging between days. Pages are lazy; only the visible one and its
/// neighbours exist at any time.
struct DayPager: View {
    @Environment(AppStore.self) private var store
    @State private var selection: Date?
    @State private var detail: CalEvent?
    /// The moment the reader is looking at, shared by every page so paging keeps hours level.
    @State private var anchor: TimeAnchor?

    private let today = Calendar.current.startOfDay(for: Date())
    private let days: [Date]
    /// Told which day is in view, as the reader pages.
    private let onDayChange: (Date) -> Void
    /// Back to the month grid.
    private let onClose: () -> Void
    private let zoom: Namespace.ID

    init(start: Date, zoom: Namespace.ID, onDayChange: @escaping (Date) -> Void, onClose: @escaping () -> Void) {
        self.zoom = zoom
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.startOfDay(for: start)
        // Wide enough around both today and the day opened.
        let first = min(today, start), last = max(today, start)
        let from = cal.date(byAdding: .day, value: -180, to: first) ?? first
        let to = cal.date(byAdding: .day, value: 365, to: last) ?? last
        var days: [Date] = []
        var d = from
        while d <= to {
            days.append(d)
            d = cal.date(byAdding: .day, value: 1, to: d) ?? to.addingTimeInterval(1)
        }
        self.days = days
        self.onDayChange = onDayChange
        self.onClose = onClose
        _selection = State(initialValue: start)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    DayPage(model: store.model(for: day), isToday: day == today, isActive: day == selection,
                            anchor: $anchor, onSelect: { detail = $0 }, onClose: onClose)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selection)
        .scrollIndicators(.hidden)
        .onChange(of: selection) { _, new in if let new { onDayChange(new) } }
        .overlay(alignment: .bottomTrailing) {
            if let s = selection, s != today {
                Button {
                    withAnimation(.snappy) { selection = today }
                } label: {
                    Label("今天", systemImage: s < today ? "chevron.right" : "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .labelStyle(TodayLabelStyle(trailingIcon: s < today))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(20)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: selection == today)
        .background(Theme.paper)
        .sheet(item: $detail) { e in
            let model = store.model(for: e.start)
            EventDetailView(event: e, plan: model.travel[e.id], hours: model.hours,
                            sameRoom: model.sameRoom.contains(e.id))
                .presentationDetents([.medium, .large])
        }
        // Closes into the cell of the day shown now, wherever paging has got to.
        .navigationTransition(.zoom(sourceID: ZoomID.day(selection ?? days[0]), in: zoom))
    }
}

private struct TodayLabelStyle: LabelStyle {
    let trailingIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if !trailingIcon { configuration.icon }
            configuration.title
            if trailingIcon { configuration.icon }
        }
    }
}
