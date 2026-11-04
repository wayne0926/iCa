import SwiftUI

/// The year view, under the months like in iOS Calendar: twelve small months a year.
/// A month opens with the system zoom out of its small copy, and zooms back into it.
struct YearCalendar: View {
    /// The month the month view shows; its small copy carries the zoom source.
    let shownMonth: Date
    let zoom: Namespace.ID
    let onOpen: (Date) -> Void


    @State private var position: ScrollPosition
    @State private var visibleYear: Int
    /// Every year with a section on screen, so a tap never scrolls the month it zooms from.
    /// Not observed: scrolling updates it without redrawing anything.
    @State private var onScreen = OnScreen()
    @State private var pinchUsed = false

    private static let calendar = Calendar.current
    private static let thisYear = calendar.component(.year, from: MonthCalendar.thisMonth)
    private static let years = Array((thisYear - 3)...(thisYear + 3))
    private let today = Calendar.current.startOfDay(for: Date())

    init(shownMonth: Date, zoom: Namespace.ID, onOpen: @escaping (Date) -> Void) {
        self.shownMonth = shownMonth
        self.zoom = zoom
        self.onOpen = onOpen
        let year = Self.calendar.component(.year, from: shownMonth)
        _position = State(initialValue: ScrollPosition(id: year, anchor: .top))
        _visibleYear = State(initialValue: year)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(MonthCalendar.yearTitle(visibleYear))
                    .font(.system(size: 30, weight: .bold))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: visibleYear)
                Spacer(minLength: 0)
                SettingsButton()
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Self.years, id: \.self) { year in
                        YearSection(year: year, isFirst: year == Self.years.first,
                                    today: today, zoom: zoom, onPick: onOpen)
                            .id(year)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition($position, anchor: .top)
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.01) { ids in
                onScreen.years = Set(ids)
                if let top = ids.min(), top != visibleYear { visibleYear = top }
            }
            .scrollIndicators(.hidden)
            .simultaneousGesture(
                // Pinching out opens the months: this month in this year, else January.
                MagnifyGesture()
                    .onChanged { v in
                        guard !pinchUsed, v.magnification > 1.25 else { return }
                        pinchUsed = true
                        onOpen(visibleYear == Self.thisYear ? MonthCalendar.thisMonth
                               : Self.calendar.date(from: DateComponents(year: visibleYear, month: 1, day: 1))
                                 ?? MonthCalendar.thisMonth)
                    }
                    .onEnded { _ in pinchUsed = false }
            )
        }
        .background(Theme.paper)
        .overlay(alignment: .bottomTrailing) {
            if visibleYear != Self.thisYear {
                Button {
                    withAnimation(.snappy) { position.scrollTo(id: Self.thisYear, anchor: .top) }
                } label: {
                    Label("今天", systemImage: visibleYear > Self.thisYear ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .labelStyle(CompactLabelStyle())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(20)
            }
        }
        // Paging the months into a year that isn't on screen: be there when they close.
        .onChange(of: Self.calendar.component(.year, from: shownMonth)) { _, year in
            if !onScreen.years.contains(year) { position.scrollTo(id: year, anchor: .top) }
        }
    }
}

private final class OnScreen {
    var years: Set<Int> = []
}

/// One year of small months, three across. The year is named in the title above; years
/// are told apart by a rule and January coming round again.
private struct YearSection: View {
    let year: Int
    let isFirst: Bool
    let today: Date
    let zoom: Namespace.ID
    let onPick: (Date) -> Void

    var body: some View {
        let cal = Calendar.current
        let months = (1...12).compactMap { cal.date(from: DateComponents(year: year, month: $0, day: 1)) }
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(isFirst ? .clear : Theme.hairline).frame(height: 1)
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 22) {
                ForEach(0..<4, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { col in
                            let m = months[row * 3 + col]
                            MiniMonth(shape: MonthShape(m), isThisMonth: m == MonthCalendar.thisMonth, today: today)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(m) }
                                .background {
                                    Color.clear.matchedTransitionSource(id: ZoomID.month(m), in: zoom)
                                }
                        }
                    }
                }
            }
            .padding(.top, 17)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 26)
    }
}

private struct MiniMonth: View {
    let shape: MonthShape
    let isThisMonth: Bool
    let today: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Fmt.month(shape.month))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isThisMonth ? Theme.now : Theme.ink)
            VStack(spacing: 2) {
                ForEach(shape.weeks.indices, id: \.self) { w in
                    let week = shape.weeks[w]
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { i in
                            Group {
                                if i < week.count, let day = week[i] {
                                    let isToday = day == today
                                    Text("\(Calendar.current.component(.day, from: day))")
                                        .font(.system(size: 10, weight: isToday ? .bold : .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(isToday ? Color.white
                                                         : (Calendar.current.isDateInWeekend(day) ? Theme.graphite : Theme.ink))
                                        .background { if isToday { Circle().fill(Theme.now).frame(width: 17, height: 17) } }
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 15)
                        }
                    }
                }
            }
        }
        .frame(height: 130, alignment: .top)
    }
}
