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
/// so paging between days changes only what differs: a cloud slides in front of the sun and
/// hides it, the sun peeks out from behind, rain or snow appears under the same cloud (the
/// system's Magic Replace, where it can match the two symbols).
private struct WeatherGlyph: View {
    let kind: WeatherKind

    private static let motion = Animation.smooth(duration: 0.5)
    private static let swap = ContentTransition.symbolEffect(.replace.magic(fallback: .replace.downUp))

    private enum Sun { case full, peek, gone }

    private var sun: Sun {
        switch kind {
        case .clear: return .full
        case .fewClouds, .showers: return .peek
        default: return .gone
        }
    }

    /// The cloud's symbol; nil when the sky is clear.
    private var cloud: String? {
        switch kind {
        case .clear: return nil
        case .fewClouds, .cloudy: return "cloud"
        case .fog: return "cloud.fog"
        case .drizzle: return "cloud.drizzle"
        case .rain, .showers: return "cloud.rain"
        case .heavyRain: return "cloud.heavyrain"
        case .snow: return "cloud.snow"
        case .sleet: return "cloud.sleet"
        case .thunder: return "cloud.bolt.rain"
        }
    }

    var body: some View {
        // A clear sky keeps the plain cloud, faded out, so the next cloud has one to grow from.
        let name = cloud ?? "cloud"
        let shown = cloud != nil
        let peek = sun == .peek
        ZStack {
            Image(systemName: "sun.max")
                .scaleEffect(sun == .full ? 1 : peek ? 0.68 : 0.5)
                .offset(x: sun == .full ? 0 : peek ? 5 : 3, y: sun == .full ? 0 : peek ? -4 : -2)
                .opacity(sun == .gone ? 0 : 1)
            // The cloud's shape, a little larger, cut out of the sun behind it: the cloud reads
            // as in front, with a sliver of air between them, on any background.
            Image(systemName: name + ".fill")
                .contentTransition(Self.swap)
                .scaleEffect(1.14)
                .blendMode(.destinationOut)
                .modifier(CloudPlace(shown: shown, peek: peek))
            Image(systemName: name)
                .contentTransition(Self.swap)
                .modifier(CloudPlace(shown: shown, peek: peek))
        }
        .compositingGroup()
        .font(.system(size: 17, weight: .semibold))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(Theme.ink)
        .frame(width: 30, height: 26)
        .animation(Self.motion, value: kind)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// Where the cloud sits: in from the lower left when it comes, beside the sun when the
    /// sun peeks out, the whole glyph otherwise.
    private struct CloudPlace: ViewModifier {
        let shown: Bool
        let peek: Bool

        func body(content: Content) -> some View {
            content
                .scaleEffect(!shown ? 0.8 : peek ? 0.88 : 1)
                .offset(x: !shown ? -10 : peek ? -2 : 0, y: !shown ? 3 : peek ? 2 : 0)
                .opacity(shown ? 1 : 0)
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
