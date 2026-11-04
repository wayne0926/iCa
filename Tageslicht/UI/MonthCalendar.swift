import SwiftUI

/// Identifies one row of the month list: a month's title, or one of its weeks.
struct MonthRowID: Hashable {
    let month: Date
    /// -1 for the title, then the month's weeks in order.
    let week: Int
}

/// A month laid out in weeks of the locale's week; days outside the month are empty.
struct MonthShape {
    let month: Date
    let weeks: [[Date?]]

    init(_ month: Date, calendar: Calendar = .current) {
        self.month = month
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
        let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let cells: [Date?] = Array(repeating: nil, count: leading) + days.map { $0 }
        weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
    }

    var leading: Int { weeks.first?.firstIndex { $0 != nil } ?? 0 }
}

/// Months in one continuous vertical scroll, opened from the year view. Pinching switches
/// between dots and each day's events written out, one step per pinch, animated by the
/// system; pinching in from dots, or tapping the year, goes back to the year.
struct MonthCalendar: View {
    @Environment(AppStore.self) private var store
    /// Where the zoom sources are: told which month is at the top, and which day the day
    /// pages show.
    let marks: ZoomMarks
    let zoom: Namespace.ID
    /// Back to the year, with the month at the top.
    let onYear: (Date) -> Void
    let onOpen: (Date) -> Void


    @AppStorage("monthDetailed") private var detailed = true
    @AppStorage(MonthColorStyle.key) private var colorStyle = MonthColorStyle.dot
    /// One switch per pinch.
    @State private var pinchUsed = false
    @State private var position: ScrollPosition
    /// The month at the top. Only the year title and the today button read it, so a new
    /// month scrolling in never redraws the list.
    @State private var cursor: MonthCursor
    /// The list's slide and fade while it jumps to another month (see `jump(to:)`).
    @State private var slide: CGFloat = 0
    @State private var fade: Double = 1
    @State private var jumping = false
    private let start: Date

    static let calendar = Calendar.current
    static let thisMonth = calendar.dateInterval(of: .month, for: Date())?.start ?? calendar.startOfDay(for: Date())
    /// Built once: three years either side.
    private static let shapes: [MonthShape] = (-36...36).compactMap {
        calendar.date(byAdding: .month, value: $0, to: thisMonth).map { MonthShape($0) }
    }
    private let today = Calendar.current.startOfDay(for: Date())

    init(start: Date, marks: ZoomMarks, zoom: Namespace.ID,
         onYear: @escaping (Date) -> Void, onOpen: @escaping (Date) -> Void) {
        self.start = start
        self.marks = marks
        self.zoom = zoom
        self.onYear = onYear
        self.onOpen = onOpen
        _position = State(initialValue: ScrollPosition(id: MonthRowID(month: start, week: -1), anchor: .top))
        _cursor = State(initialValue: MonthCursor(visible: start))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // The year is the way back to the year view, as the date is on a day page.
                YearButton(cursor: cursor) { onYear(cursor.visible) }
                Spacer(minLength: 0)
                SettingsButton()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
            WeekdayRow()
                .padding(.horizontal, WeekRow.inset)
                .padding(.bottom, 8)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Self.shapes, id: \.month) { shape in
                        MonthTitle(shape: shape, isThisMonth: shape.month == Self.thisMonth)
                            .id(MonthRowID(month: shape.month, week: -1))
                        ForEach(shape.weeks.indices, id: \.self) { w in
                            WeekRow(month: shape.month, week: shape.weeks[w], today: today, detailed: detailed,
                                    marks: marks, zoom: zoom, onOpen: onOpen)
                                .id(MonthRowID(month: shape.month, week: w))
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition($position, anchor: .top)
            .onScrollTargetVisibilityChange(idType: MonthRowID.self) { ids in
                if let top = ids.min(by: { ($0.month, $0.week) < ($1.month, $1.week) }), top.month != cursor.visible {
                    cursor.visible = top.month
                    marks.month = top.month
                }
            }
            .scrollIndicators(.hidden)
            .simultaneousGesture(pinch)
            .offset(y: slide)
            .opacity(fade)
            .clipped()
        }
        .environment(\.monthColorStyle, colorStyle)
        .background(Theme.paper)
        .background { FollowJump(marks: marks, cursor: cursor, position: $position) }
        .overlay(alignment: .bottomTrailing) {
            TodayButton(cursor: cursor) { jump(to: Self.thisMonth) }
        }
    }

    /// To another month, months away. An animated scroll can't do this in a lazy list
    /// whose rows have different heights: it heads for a guessed offset, corrects it on
    /// the way, and slides the rows it builds in flight over each other, so every run
    /// looks different. Instead the list slides a little the way it would scroll and
    /// fades, jumps while unseen, and comes in from the other side on an easing curve.
    /// Only the list's layer moves; nothing in it animates.
    private func jump(to month: Date) {
        guard !jumping, month != cursor.visible else { return }
        jumping = true
        // Later months are further down: the content moves up, as a scroll down would.
        let travel: CGFloat = month > cursor.visible ? -44 : 44
        withAnimation(.easeIn(duration: 0.12)) {
            slide = travel
            fade = 0
        } completion: {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                position.scrollTo(id: MonthRowID(month: month, week: -1), anchor: .top)
                slide = -travel
            }
            // Told outright: a jump made in code doesn't always report what came into view.
            marks.month = month
            // A turn later, so the jump has been laid out and drawn unseen first, and the
            // way in starts from the far side, not from where the way out ended.
            DispatchQueue.main.async {
                withAnimation(.smooth(duration: 0.38)) {
                    cursor.visible = month
                    slide = 0
                    fade = 1
                } completion: {
                    jumping = false
                }
            }
        }
    }

    static func yearTitle(_ year: Int) -> String { "\(String(year))年" }

    /// Out: events written out. In: dots, and from dots, the year. The switch happens the
    /// moment the pinch is clear, not when the fingers lift.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                guard !pinchUsed else { return }
                if v.magnification > 1.2, !detailed {
                    pinchUsed = true
                    withAnimation(.smooth) { detailed = true }
                } else if v.magnification < 0.83, detailed {
                    pinchUsed = true
                    withAnimation(.smooth) { detailed = false }
                } else if v.magnification < 0.75, !detailed {
                    pinchUsed = true
                    onYear(cursor.visible)
                }
            }
            .onEnded { _ in pinchUsed = false }
    }
}

/// The month at the top of the month view.
@MainActor
@Observable
private final class MonthCursor {
    var visible: Date
    init(visible: Date) { self.visible = visible }
}

/// The day pages paged into another month: bring it to the top while they are still open,
/// so its cell is on screen when they close into it. Its own view, so watching for that
/// redraws nothing else.
private struct FollowJump: View {
    let marks: ZoomMarks
    let cursor: MonthCursor
    @Binding var position: ScrollPosition

    var body: some View {
        Color.clear.onChange(of: marks.jump) { _, month in
            guard let month, month != cursor.visible else { return }
            position.scrollTo(id: MonthRowID(month: month, week: -1), anchor: .top)
            // The list is hidden under the day pages and may not report what it shows.
            cursor.visible = month
        }
    }
}

/// The year, as the way back to the year view, as the date is on a day page.
private struct YearButton: View {
    let cursor: MonthCursor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(MonthCalendar.yearTitle(MonthCalendar.calendar.component(.year, from: cursor.visible)))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("年历")
    }
}

private struct TodayButton: View {
    let cursor: MonthCursor
    let action: () -> Void

    var body: some View {
        if cursor.visible != MonthCalendar.thisMonth {
            Button(action: action) {
                Label("今天", systemImage: cursor.visible > MonthCalendar.thisMonth ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .labelStyle(CompactLabelStyle())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(20)
            .transition(.opacity)
        }
    }
}

/// The gear, and the calendar list it opens.
struct SettingsButton: View {
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background(Theme.ink.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("设置")
        .sheet(isPresented: $open) {
            SettingsView().presentationDetents([.medium, .large])
        }
    }
}

/// Weekday initials in the locale's week order; weekends step back like their dates.
private struct WeekdayRow: View {
    var body: some View {
        let cal = Calendar.current
        let symbols = Fmt.zh.veryShortStandaloneWeekdaySymbols
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                let weekday = (cal.firstWeekday - 1 + i) % 7
                Text(symbols[weekday])
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(weekday == 0 || weekday == 6 ? Theme.graphite : Theme.ink)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Seven equal columns; an empty one still holds its place.
private struct Columns<Cell: View>: View {
    var alignment: VerticalAlignment = .center
    @ViewBuilder let cell: (Int) -> Cell

    var body: some View {
        HStack(alignment: alignment, spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                ZStack(alignment: .top) {
                    Color.clear.frame(width: 1, height: 1)
                    cell(i)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The month's name, standing over the column of its 1st.
private struct MonthTitle: View {
    let shape: MonthShape
    let isThisMonth: Bool

    var body: some View {
        Columns { i in
            if i == shape.leading {
                Text(Fmt.month(shape.month))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(isThisMonth ? Theme.now : Theme.ink)
                    .fixedSize()
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
        .padding(.horizontal, WeekRow.inset)
    }
}

private struct WeekRow: View {
    @Environment(AppStore.self) private var store
    let month: Date
    let week: [Date?]
    let today: Date
    let detailed: Bool
    let marks: ZoomMarks
    let zoom: Namespace.ID
    let onOpen: (Date) -> Void

    static let inset: CGFloat = 6

    var body: some View {
        let model = store.month(for: month)
        let items = model.items
        let bars = WeekBars.segments(model.spans, in: week)
        let lanes = (bars.map(\.lane).max() ?? -1) + 1
        let first = week.compactMap { $0 }.first ?? today
        let isThisWeek = week.contains { $0 == today }
        VStack(spacing: 0) {
            // Each week opens with a rule, starting where the month does, and its number.
            ZStack(alignment: .leading) {
                Columns { i in
                    Rectangle()
                        .fill(i < week.count && week[i] != nil ? Theme.hairline : .clear)
                        .frame(height: 1)
                }
                Text("\(Calendar.current.component(.weekOfYear, from: first))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isThisWeek ? Theme.now : Theme.graphite)
                    .padding(.trailing, 4)
                    .background(Theme.paper)
            }
            Columns(alignment: .top) { i in
                    if i < week.count, let day = week[i] {
                        DayCell(day: day, isToday: day == today, items: items[day] ?? [], lanes: lanes, detailed: detailed)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(day) }
                            .modifier(ZoomSource(kind: .day, date: day, marks: marks, zoom: zoom))
                    }
                }
                // Several-day events run across the week as one bar, under the day numbers.
                .overlay(alignment: .topLeading) {
                    if detailed, !bars.isEmpty {
                        WeekBars {
                            ForEach(bars, id: \.span.id) { bar in
                                SpanBar(bar: bar).layoutValue(key: WeekBars.Slot.self, value: bar)
                            }
                        }
                        .padding(.top, DayCell.chipsTop)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .frame(minHeight: detailed ? 96 : 62, alignment: .top)
        }
        .padding(.horizontal, Self.inset)
    }
}

private struct DayCell: View {
    let day: Date
    let isToday: Bool
    let items: [MonthItem]
    /// Rows of several-day bars in this week; the day's own events start below them.
    let lanes: Int
    let detailed: Bool

    private static let maxDots = 3
    private static let maxChips = 4
    /// Where the written-out events begin: under the day number.
    static let chipsTop: CGFloat = 6 + 34 + 4

    var body: some View {
        let own = items.filter { !$0.spanning }
        VStack(spacing: 4) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 18, weight: isToday ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.white : (Calendar.current.isDateInWeekend(day) ? Theme.graphite : Theme.ink))
                .frame(width: 34, height: 34)
                .background { if isToday { Circle().fill(Theme.now) } }
            if detailed {
                VStack(spacing: 3) {
                    Color.clear.frame(height: CGFloat(lanes) * WeekBars.pitch - (lanes > 0 ? 3 : 0))
                    ForEach(own.prefix(Self.maxChips), id: \.id) { Chip(item: $0) }
                    if own.count > Self.maxChips {
                        Text("+\(own.count - Self.maxChips)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.graphite)
                    }
                }
                .padding(.horizontal, 2)
                .transition(.opacity)
            } else {
                HStack(spacing: 3) {
                    ForEach(Array(items.prefix(Self.maxDots).enumerated()), id: \.offset) { _, item in
                        Circle().fill(CalendarInk.mark(item.color)).frame(width: 6, height: 6)
                    }
                }
                .frame(height: 6)
                .padding(.top, 1)
                .transition(.opacity)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// An event written into its day: the same surface as the day page's cards, with the
/// calendar's colour as a dot. All-day events are a single line.
private struct Chip: View {
    let item: MonthItem
    @Environment(\.monthColorStyle) private var style

    var body: some View {
        let filled = style == .fill
        let dot = Circle().fill(CalendarInk.mark(item.color)).frame(width: filled ? 0 : 5, height: 5)
        Group {
            if let time = item.time {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: filled ? 0 : 3) {
                        dot
                        Text(time)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.graphite)
                    }
                }
                .padding(.vertical, 3)
            } else {
                HStack(spacing: filled ? 0 : 3) {
                    dot
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(filled ? CalendarInk.fill(item.color) : CalendarInk.card(item.color),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Lays several-day bars over a week's seven columns, one lane per row.
private struct WeekBars: Layout {
    struct Bar: Hashable {
        let span: MonthSpan
        let start: Int
        let end: Int
        let lane: Int
        /// Carries on from the week before / into the week after.
        let openStart: Bool
        let openEnd: Bool
    }

    struct Slot: LayoutValueKey {
        static let defaultValue: Bar? = nil
    }

    static let height: CGFloat = 18
    static let pitch: CGFloat = height + 3
    static let maxLanes = 3

    /// The week's piece of each span, packed into the fewest lanes, longest first.
    static func segments(_ spans: [MonthSpan], in week: [Date?]) -> [Bar] {
        var pieces: [(span: MonthSpan, start: Int, end: Int)] = []
        for span in spans {
            let cols = week.indices.filter { i in week[i].map { $0 >= span.first && $0 <= span.last } ?? false }
            if let s = cols.first, let e = cols.last { pieces.append((span, s, e)) }
        }
        pieces.sort { ($0.start, $1.end - $1.start) < ($1.start, $0.end - $0.start) }
        var laneEnds: [Int] = []
        var bars: [Bar] = []
        for p in pieces {
            let lane = laneEnds.firstIndex { $0 < p.start } ?? laneEnds.count
            guard lane < maxLanes else { continue }
            if lane == laneEnds.count { laneEnds.append(p.end) } else { laneEnds[lane] = p.end }
            bars.append(Bar(span: p.span, start: p.start, end: p.end, lane: lane,
                            openStart: week[p.start].map { $0 > p.span.first } ?? false,
                            openEnd: week[p.end].map { $0 < p.span.last } ?? false))
        }
        return bars
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lanes = (subviews.compactMap { $0[Slot.self]?.lane }.max() ?? -1) + 1
        return CGSize(width: proposal.width ?? 0, height: CGFloat(lanes) * Self.pitch)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let col = bounds.width / 7
        for v in subviews {
            guard let bar = v[Slot.self] else { continue }
            // Inset like the chips, except where the bar runs on past the week.
            let lead: CGFloat = bar.openStart ? 0 : 2
            let trail: CGFloat = bar.openEnd ? 0 : 2
            let x = bounds.minX + CGFloat(bar.start) * col + lead
            let width = CGFloat(bar.end - bar.start + 1) * col - lead - trail
            v.place(at: CGPoint(x: x, y: bounds.minY + CGFloat(bar.lane) * Self.pitch), anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: Self.height))
        }
    }
}

/// One week's stretch of a several-day event: the all-day chip, drawn long. Square ends
/// where it continues into the next or previous week.
private struct SpanBar: View {
    let bar: WeekBars.Bar
    @Environment(\.monthColorStyle) private var style

    var body: some View {
        let r: CGFloat = 6
        let filled = style == .fill
        HStack(spacing: filled ? 0 : 3) {
            Circle().fill(CalendarInk.mark(bar.span.color)).frame(width: filled ? 0 : 5, height: 5)
            Text(bar.span.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(filled ? CalendarInk.fill(bar.span.color) : CalendarInk.card(bar.span.color),
                    in: UnevenRoundedRectangle(topLeadingRadius: bar.openStart ? 0 : r,
                                               bottomLeadingRadius: bar.openStart ? 0 : r,
                                               bottomTrailingRadius: bar.openEnd ? 0 : r,
                                               topTrailingRadius: bar.openEnd ? 0 : r,
                                               style: .continuous))
    }
}

