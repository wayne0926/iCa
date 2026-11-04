import SwiftUI

/// Horizontal paging between days. Pages are lazy; only the visible one and its
/// neighbours exist at any time. Only the timelines page: the date, the controls and the
/// all-day events above them stay where they are and change in place.
struct DayPager: View {
    @Environment(AppStore.self) private var store
    @State private var selection: Date?
    /// The day the header names: whichever page covers most of the screen, so it changes
    /// once, halfway through a swipe.
    @State private var shown: Date
    /// Paging back: the date's digits roll down.
    @State private var backwards = false
    /// Only a scroll moves the header; the offset a pager reports before it has been put
    /// on its first page is not a day. The rain on the pages beside follows it too.
    @State private var activity = PagerActivity()
    @State private var detail: CalEvent?
    /// When the page came on screen, and whether it is on its way back: a tap that lands
    /// while the zoom still runs, opening or closing, is a tap meant for the month, never
    /// one that opens an event.
    @State private var openedAt = Date()
    @State private var closing = false
    /// The moment the reader is looking at, shared by every page so paging keeps hours level.
    @State private var anchor: TimeAnchor?
    /// With the grid held still, the grid and the sun balls are drawn here, once for all pages.
    @State private var pinTrack = PinTrack()
    @AppStorage(DayTimeline.pinGridKey) private var pinGrid = false

    private let today = Calendar.current.startOfDay(for: Date())
    private let days: [Date]
    /// Told which day is in view, as the reader pages.
    private let onDayChange: (Date) -> Void
    /// Back to the month grid.
    private let onClose: () -> Void

    init(start: Date, onDayChange: @escaping (Date) -> Void, onClose: @escaping () -> Void) {
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
        _shown = State(initialValue: start)
    }

    var body: some View {
        let model = store.model(for: shown)
        VStack(spacing: 0) {
            DayHeader(model: model, isToday: shown == today, backwards: backwards, onClose: close)
            if !model.allDay.isEmpty {
                AllDayStrip(day: shown, events: model.allDay, onSelect: select)
                    .transition(.opacity)
            }
            Divider()
            pager
        }
        .background(Theme.paper)
        .coordinateSpace(.named(DayPage.rootSpace))
        .onAppear {
            openedAt = Date()
            closing = false
        }
        .onDisappear {
            closing = true
            detail = nil
        }
        .sheet(item: $detail) { e in
            let model = store.model(for: e.start)
            EventDetailView(event: e, plan: model.travel[e.id], hours: model.hours,
                            sameRoom: model.sameRoom.contains(e.id))
                .presentationDetents([.medium, .large])
        }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    DayPage(model: store.model(for: day), isToday: day == today, isActive: day == selection,
                            anchor: $anchor, onSelect: select)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .coordinateSpace(.named(PinTrack.space))
        .environment(activity)
        .environment(pinTrack)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selection)
        .scrollIndicators(.hidden)
        // Which page covers most of the screen. The action runs only when that changes,
        // not on every frame of the swipe.
        .onScrollGeometryChange(for: Int.self) { g in
            let width = g.containerSize.width
            return width > 0 ? Int(((g.contentOffset.x + g.contentInsets.leading) / width).rounded()) : -1
        } action: { _, i in
            guard activity.moving, days.indices.contains(i) else { return }
            show(days[i])
        }
        // Told once a page has settled, not as one slides past mid-swipe: what follows the
        // day (the zoom source, the month view behind scrolling to its month) then never
        // works during the swipe itself.
        .onScrollPhaseChange { _, phase in
            if activity.moving != phase.isScrolling { activity.moving = phase.isScrolling }
            if phase == .idle, let s = selection {
                show(s)
                onDayChange(s)
            }
        }
        // The page in view, for the held-still grid and sun balls. Only they read it, and
        // only when it changes.
        .onScrollGeometryChange(for: Int.self) { g in
            let width = g.containerSize.width
            return width > 0 ? Int(((g.contentOffset.x + g.contentInsets.leading) / width).rounded()) : -1
        } action: { _, i in
            pinTrack.page = i
        }
        // Held still, the grid lies under every page and the sun balls over them.
        .background {
            if pinGrid { PinnedGrid(track: pinTrack, days: days) }
        }
        .overlay {
            if pinGrid { SunOverlay(track: pinTrack, days: days) }
        }
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
    }

    private func show(_ day: Date) {
        guard day != shown else { return }
        withAnimation(DayPage.stripAnimation) {
            backwards = day < shown
            shown = day
        }
    }

    /// The date tapped before the page settled: name the day in view first, so the page
    /// closes into its cell.
    private func close() {
        closing = true
        if let s = selection { onDayChange(s) }
        onClose()
    }

    /// The zoom takes about half a second; until it has, the page isn't the one tapped.
    private func select(_ e: CalEvent) {
        guard !closing, Date().timeIntervalSince(openedAt) > 0.5 else { return }
        detail = e
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

private struct DayHeader: View {
    let model: DayModel
    let isToday: Bool
    let backwards: Bool
    let onClose: () -> Void

    @AppStorage("timelineZoom") private var zoom = TimelineZoom.standard.rawValue
    @AppStorage("timelineFullDay") private var fullDay = false

    /// The widest date there is: it holds the room, so neither the weekday after it nor the
    /// button around it moves as the digits change.
    private static let widest = "12月28日"

    var body: some View {
        let step = TimelineZoom(rawValue: zoom) ?? .standard
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // The date is the way back: a tap folds the day into its cell in the month.
                Button(action: onClose) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ZStack(alignment: .leading) {
                            Text(Self.widest).hidden().accessibilityHidden(true)
                            Text(Fmt.monthDay(model.day))
                                .contentTransition(.numericText(countsDown: backwards))
                        }
                        .font(.system(size: 28, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        Text(model.day.formatted(Fmt.weekday))
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(isToday ? Theme.now : Theme.graphite)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("返回月历")
                Spacer(minLength: 0)
                if let s = model.summary {
                    WeatherGlyph(kind: s.kind)
                        .transition(.opacity)
                }
            }
            HStack(spacing: 4) {
                // Only rain earns words here.
                if let wet = model.summary?.wetSpan {
                    Label(wet, systemImage: "drop.fill")
                        .foregroundStyle(Theme.rain)
                        .font(.system(size: 13))
                        .labelStyle(CompactLabelStyle())
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                // Both controls share one capsule, split by a hairline. They work on every
                // page at once, so they don't page.
                HStack(spacing: 0) {
                    // The button shows what a tap does: a plus while the next step is roomier.
                    let grows = step.next.hourHeight > step.hourHeight
                    HeaderButton(symbol: "arrow.up.and.down",
                                 label: grows ? "放大时间线" : "缩小时间线",
                                 action: { zoom = step.next.rawValue })
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
                    // Filled clock = the whole 24 hours are showing.
                    HeaderButton(symbol: fullDay ? "clock.fill" : "clock",
                                 label: fullDay ? "折叠空闲时段" : "显示全天", action: { fullDay.toggle() })
                }
                .background(Theme.ink.opacity(0.07), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The day's weather in the header's ink, built from layers instead of one symbol per kind,
/// so paging between days changes only what differs and every change is a motion, never a
/// swap: a cloud slides in front of the sun and hides it, the sun peeks out from behind;
/// the cloud is always the same one, rising a little to make room as rain grows out of its
/// underside, shrinks back into it, turns to snow or gives way to fog or a bolt.
///
/// The system's Magic Replace morphs only symbols it knows as variants of each other
/// (cloud and cloud.rain are not), so the precipitation is drawn here, in the symbols'
/// stroke weight, as shapes whose size animates.
private struct WeatherGlyph: View {
    let kind: WeatherKind

    private static let motion = Animation.smooth(duration: 0.5)
    private static let size = CGSize(width: 30, height: 26)
    /// The symbols' semibold stroke at 17 pt.
    private static let stroke = StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round)

    private enum Sun { case full, peek, gone }

    private var sun: Sun {
        switch kind {
        case .clear: return .full
        case .fewClouds, .showers: return .peek
        default: return .gone
        }
    }

    /// How long the drops are. Kept when there is no rain, so they slide up into the cloud
    /// whole rather than shrinking to dots.
    private var drops: CGFloat {
        switch kind {
        case .drizzle: return 2.5
        case .heavyRain: return 7.5
        case .sleet: return 3.5
        default: return 5.5
        }
    }

    private var raining: Bool {
        switch kind {
        case .drizzle, .rain, .showers, .heavyRain, .sleet: return true
        default: return false
        }
    }

    /// Snowflakes, first row and second row; sleet has only the second, between the drops.
    private var flakes: (CGFloat, CGFloat) {
        switch kind {
        case .snow: return (1, 1)
        case .sleet: return (0, 1)
        default: return (0, 0)
        }
    }

    var body: some View {
        let shown = kind != .clear
        let peek = sun == .peek
        let fog: CGFloat = kind == .fog ? 1 : 0
        let bolt = kind == .thunder
        // Anything under the cloud: it rises and narrows a little to make room.
        let under = raining || flakes.1 > 0 || fog > 0 || bolt
        let place = CloudPlace(shown: shown, peek: peek, under: under)
        ZStack {
            Image(systemName: "sun.max")
                .scaleEffect(sun == .full ? 1 : peek ? (under ? 0.62 : 0.68) : 0.5)
                .offset(x: sun == .full ? 0 : peek ? 5 : 3,
                        y: sun == .full ? 0 : peek ? (under ? -6 : -4) : -2)
                .opacity(sun == .gone ? 0 : 1)
            // What falls from the cloud hangs from it: it moves with the cloud, and leaves by
            // going back up into it.
            Group {
                Drops(length: drops, out: raining ? 1 : 0)
                    .stroke(style: Self.stroke)
                    .opacity(raining ? 1 : 0)
                Flakes(rows: AnimatablePair(flakes.0, flakes.1))
                Mist(amount: fog)
                    .stroke(style: Self.stroke)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .scaleEffect(bolt ? 1 : 0.5, anchor: .top)
                    .offset(y: bolt ? 8 : 2)
                    .opacity(bolt ? 1 : 0)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .offset(x: place.x, y: place.y + CloudPlace.rise)
            // The cloud's shape, a little larger, cut out of the sun and of whatever falls
            // behind it: the cloud reads as in front, with a sliver of air around it, on any
            // background, and drops going back up vanish into it.
            Image(systemName: "cloud.fill")
                .scaleEffect(1.14)
                .blendMode(.destinationOut)
                .modifier(place)
            Image(systemName: "cloud")
                .modifier(place)
        }
        .compositingGroup()
        .font(.system(size: 17, weight: .semibold))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(Theme.ink)
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(Self.motion, value: kind)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// Where the cloud sits: in from the lower left when it comes, beside the sun when the
    /// sun peeks out, raised when something falls from it, the whole glyph otherwise.
    private struct CloudPlace: ViewModifier {
        let shown: Bool
        let peek: Bool
        let under: Bool

        /// How far the cloud rises to make room underneath.
        static let rise: CGFloat = 5

        var x: CGFloat { !shown ? -10 : peek ? -2 : 0 }
        var y: CGFloat { !shown ? 3 : (peek ? 2 : 0) - (under ? Self.rise : 0) }
        var scale: CGFloat { (!shown ? 0.8 : peek ? 0.88 : 1) * (under ? 0.9 : 1) }

        func body(content: Content) -> some View {
            content
                .scaleEffect(scale)
                .offset(x: x, y: y)
                .opacity(shown ? 1 : 0)
        }
    }

    /// Where precipitation starts: just under the cloud, risen to make room.
    private static let underside: CGFloat = 16.5

    /// Three short slanted strokes, the middle one a little lower. `out` 1 hangs them under
    /// the cloud; towards 0 they slide whole back up into it, where the cloud's cut-out
    /// hides them. Never shortened to nothing, so never left as dots.
    private struct Drops: Shape {
        var length: CGFloat
        var out: CGFloat
        var animatableData: AnimatablePair<CGFloat, CGFloat> {
            get { AnimatablePair(length, out) }
            set { length = newValue.first; out = newValue.second }
        }

        func path(in r: CGRect) -> Path {
            var p = Path()
            let back = (length + 3) * (1 - out)
            for i in 0..<3 {
                let x = r.midX + CGFloat(i - 1) * 5.5 + 1 + back * 0.35
                let top = r.minY + WeatherGlyph.underside + (i == 1 ? 1.5 : 0) - back
                p.move(to: CGPoint(x: x, y: top))
                p.addLine(to: CGPoint(x: x - length * 0.35, y: top + length))
            }
            return p
        }
    }

    /// Snowflakes as dots, in two staggered rows, each row growing and dropping into place.
    private struct Flakes: Shape {
        var rows: AnimatablePair<CGFloat, CGFloat>
        var animatableData: AnimatablePair<CGFloat, CGFloat> {
            get { rows }
            set { rows = newValue }
        }

        func path(in r: CGRect) -> Path {
            var p = Path()
            let top = r.minY + WeatherGlyph.underside
            func dot(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat) {
                guard a > 0.02 else { return }
                let radius = 1.6 * a
                let c = CGPoint(x: r.midX + x, y: top + y - (1 - a) * 3)
                p.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            }
            for i in 0..<3 { dot(CGFloat(i - 1) * 5.5, 2, rows.first) }
            for i in 0..<2 { dot(CGFloat(i) * 5.5 - 2.75, 6.5, rows.second) }
            return p
        }
    }

    /// Fog: two lines under the cloud, drawn out from the middle.
    private struct Mist: Shape {
        var amount: CGFloat
        var animatableData: CGFloat {
            get { amount }
            set { amount = newValue }
        }

        func path(in r: CGRect) -> Path {
            var p = Path()
            guard amount > 0.02 else { return p }
            let top = r.minY + WeatherGlyph.underside
            for (y, half) in [(CGFloat(2), CGFloat(8)), (CGFloat(6), CGFloat(5.5))] {
                p.move(to: CGPoint(x: r.midX - half * amount, y: top + y))
                p.addLine(to: CGPoint(x: r.midX + half * amount, y: top + y))
            }
            return p
        }
    }

    private var label: String {
        switch kind {
        case .clear: return "晴"
        case .fewClouds: return "晴间多云"
        case .cloudy: return "多云"
        case .fog: return "雾"
        case .drizzle: return "毛毛雨"
        case .rain: return "雨"
        case .heavyRain: return "大雨"
        case .snow: return "雪"
        case .sleet: return "雨夹雪"
        case .thunder: return "雷雨"
        case .showers: return "阵雨"
        }
    }
}

private struct HeaderButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 46, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Gives under the finger, so a block reads as something to press. Only the press is
/// animated: the release is where the date's tap closes the page, and a spring back to
/// full size and full opacity would still be running inside the page as it zooms down
/// into its cell.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(configuration.isPressed ? .spring(duration: 0.25) : nil, value: configuration.isPressed)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The day's all-day events. One that runs over several days gets a bar of its own that
/// stays where it is from one day to the next, and runs off the edge of the screen on the
/// side it goes on: off the right, there is more of it tomorrow; off the left, it began
/// before today. Its title stays put while the bar's ends change. One-day events follow as
/// capsules.
private struct AllDayStrip: View {
    let day: Date
    let events: [CalEvent]
    let onSelect: (CalEvent) -> Void

    private static let inset: CGFloat = 16

    var body: some View {
        let cal = Calendar.current
        let next = cal.date(byAdding: .day, value: 1, to: day) ?? day
        // An end at midnight belongs to the day before.
        let runs = events
            .map { e in Run(event: e, before: e.start < day, after: e.end > next) }
        let long = runs.filter { $0.before || $0.after }
            .sorted { ($0.event.start, $1.event.end, $0.event.title) < ($1.event.start, $0.event.end, $1.event.title) }
        let single = runs.filter { !$0.before && !$0.after }.map(\.event)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(long, id: \.event.id) { run in
                bar(run)
                    .transition(.opacity)
            }
            if !single.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(single) { e in
                            Button { onSelect(e) } label: {
                                Text(e.title)
                                    .lineLimit(1)
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(CalendarInk.mark(e.calendarColor).opacity(0.18), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, Self.inset)
                }
                .scrollIndicators(.hidden)
                .transition(.opacity)
            }
        }
        .padding(.bottom, 8)
    }

    private func bar(_ run: Run) -> some View {
        let r: CGFloat = 13
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: run.before ? 0 : r, bottomLeadingRadius: run.before ? 0 : r,
            bottomTrailingRadius: run.after ? 0 : r, topTrailingRadius: run.after ? 0 : r,
            style: .continuous)
        return Button { onSelect(run.event) } label: {
            Text(run.event.title)
                .lineLimit(1)
                .font(.system(size: 13, weight: .medium))
                .padding(.vertical, 5)
                .padding(.horizontal, Self.inset + 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    shape
                        .fill(CalendarInk.mark(run.event.calendarColor).opacity(0.18))
                        .padding(.leading, run.before ? 0 : Self.inset)
                        .padding(.trailing, run.after ? 0 : Self.inset)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private struct Run {
        let event: CalEvent
        /// Began on an earlier day.
        let before: Bool
        /// Goes on into tomorrow.
        let after: Bool
    }
}
