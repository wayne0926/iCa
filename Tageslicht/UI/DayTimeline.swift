import SwiftUI

/// The A layout on a folding time scale: busy stretches at full scale, long empty
/// stretches folded into a short strip. Rain falls across the hours it's forecast;
/// sunrise/sunset rules cross the grid.
struct DayTimeline: View {
    let model: DayModel
    let isToday: Bool
    /// Only the page in view animates.
    let isActive: Bool
    let hourHeight: CGFloat
    /// Show all 24 hours at full scale instead of folding the empty stretches.
    let fullDay: Bool
    /// Supplied by the page while a zoom or fold change is in flight; nil at rest.
    let blend: ScaleBlend?
    let onSelect: (CalEvent) -> Void

    /// Extra room below the day while a change animates, so the scroll offset is never
    /// clamped by a content height that is still catching up.
    let extraBottom: CGFloat
    /// The hour lines and labels hold still on screen while the day pages under them.
    var pinGrid = false
    /// Settings: whether the grid holds still while paging.
    static let pinGridKey = "timelinePinGrid"

    var body: some View {
        let target = Self.scale(for: model, isToday: isToday, hourHeight: hourHeight, fullDay: fullDay)
        let scale = blend ?? ScaleBlend(target)
        let wet = PrecipSpan.spans(from: model.hours, day: model.day)
        let now = Date()
        let hours = Int(Self.dayHours(model.day).rounded())
        // Everything is a positioned view: an animation frame only moves layers, it never
        // repaints the day. The order below is the drawing order: the hour grid, then the day.
        ZStack(alignment: .topLeading) {
            TimelineLayout(scale: scale, extraBottom: extraBottom) {
                ForEach(0...hours, id: \.self) { i in
                    Rectangle()
                        .fill(Theme.hairline)
                        .opacity(scale.gridWeight(Double(i)))
                        .layoutValue(key: Slot.self, value: .rule(Double(i)))
                }
                ForEach(0..<hours, id: \.self) { i in
                    Text(Fmt.hour(model.day.addingTimeInterval(Double(i) * 3600)))
                        .font(Theme.hourLabel)
                        .foregroundStyle(Theme.hourInk)
                        .fixedSize()
                        .opacity(scale.gridWeight(Double(i), label: true))
                        .layoutValue(key: Slot.self, value: .label(Double(i)))
                }
            }
            .modifier(PinnedToScreen(on: pinGrid))
            dayLayer(scale: scale, wet: wet, now: now)
        }
        .overlay(alignment: .topLeading) {
            if isToday { NowLine(day: model.day, scale: scale) }
        }
    }

    private func dayLayer(scale: ScaleBlend, wet: [PrecipSpan], now: Date) -> some View {
        TimelineLayout(scale: scale, extraBottom: extraBottom) {
            ForEach(sunMarks, id: \.symbol) { mark in
                Rectangle()
                    .fill(Theme.sunRule)
                    .layoutValue(key: Slot.self, value: .sunRule(mark.hour))
                Text("\(Image(systemName: mark.symbol)) \(mark.date.formatted(Fmt.time))")
                    .font(Theme.mark)
                    .foregroundStyle(Theme.sun)
                    .fixedSize()
                    .layoutValue(key: Slot.self, value: .sunTag(mark.hour))
            }
            ForEach(Array(wet.enumerated()), id: \.offset) { i, span in
                RainLayer(span: span, index: i, active: isActive, plane: .behind)
                    .layoutValue(key: Slot.self, value: .band(span.start, span.end))
            }
            ForEach(model.placed) { p in
                // From the height on screen right now, so mid-change the inside never jumps.
                let height = scale.y(p.endHour) - scale.y(p.startHour)
                EventBlock(event: p.event, compact: height < 52, roomy: height >= 80,
                           isPast: p.event.end < now)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(p.event) }
                    .layoutValue(key: Slot.self, value: .card(p.startHour, p.endHour, column: p.column, columns: p.columns))
            }
            // The nearest drops pass in front of the cards.
            ForEach(Array(wet.enumerated()), id: \.offset) { i, span in
                RainLayer(span: span, index: i, active: isActive, plane: .inFront)
                    .layoutValue(key: Slot.self, value: .band(span.start, span.end))
            }
        }
    }

    private struct SunMark {
        let date: Date
        let hour: Double
        let symbol: String
    }

    private var sunMarks: [SunMark] {
        [(model.sun.sunrise, "sunrise"), (model.sun.sunset, "sunset")].compactMap { date, symbol in
            date.map { SunMark(date: $0, hour: $0.timeIntervalSince(model.day) / 3600, symbol: symbol) }
        }
    }

    /// Folded: every day keeps the same usual hours open, so pages line up when swiped;
    /// a day's own events outside them open up on that day only. The present hour gets no
    /// such room: at night the now line simply runs through the fold. Travel lives in the
    /// detail sheet.
    static func scale(for model: DayModel, isToday: Bool, hourHeight: CGFloat, fullDay: Bool) -> TimeScale {
        let metrics = TimeScale.Metrics(hourHeight: hourHeight, foldHeight: Theme.foldHeight)
        let hours = dayHours(model.day)
        if fullDay { return TimeScale.make(busy: [0...hours], dayHours: hours, metrics: metrics) }
        var busy = model.placed.map { $0.startHour...$0.endHour }
        if let usual = model.usual { busy.append(usual) }
        return TimeScale.make(busy: busy, dayHours: hours, metrics: metrics)
    }

    static func dayHours(_ day: Date) -> Double {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        return end.timeIntervalSince(day) / 3600
    }
}

/// Takes back the page's sideways slide, so the grid stays where it is on screen while the
/// page moves under it. The page's own scroll view clips it to the page: mid-swipe each
/// page shows its own grid over its own part of the screen, and where both days have the
/// same hours (they're lined up before a swipe) the two halves meet as one grid. Applied
/// as the frame is drawn, so the swipe never redraws or lays out anything.
private struct PinnedToScreen: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.visualEffect { content, proxy in
                content.offset(x: -proxy.frame(in: .scrollView(axis: .horizontal)).minX)
            }
        } else {
            content
        }
    }
}

// MARK: - Layout

struct Slot: LayoutValueKey {
    enum Kind: Equatable {
        case card(column: Int, columns: Int)
        case rule, label, sunRule, sunTag, band
    }

    static let defaultValue = Slot(kind: .rule, start: 0, end: 0)
    let kind: Kind
    let start: Double
    let end: Double

    static func card(_ start: Double, _ end: Double, column: Int, columns: Int) -> Slot {
        Slot(kind: .card(column: column, columns: columns), start: start, end: end)
    }
    static func rule(_ h: Double) -> Slot { Slot(kind: .rule, start: h, end: h) }
    static func label(_ h: Double) -> Slot { Slot(kind: .label, start: h, end: h) }
    static func sunRule(_ h: Double) -> Slot { Slot(kind: .sunRule, start: h, end: h) }
    static func sunTag(_ h: Double) -> Slot { Slot(kind: .sunTag, start: h, end: h) }
    static func band(_ start: Double, _ end: Double) -> Slot { Slot(kind: .band, start: start, end: end) }
}

/// Positions every piece of the day through the time scale, without any GeometryReader.
struct TimelineLayout: Layout {
    var scale: ScaleBlend
    var extraBottom: CGFloat

    /// Inset that keeps hour lines off a card's edges.
    private static let cardGap: CGFloat = 6
    private static let cardMinHeight: CGFloat = 30

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 375, height: Theme.topInset * 2 + scale.height + extraBottom)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        func y(_ h: Double) -> CGFloat { bounds.minY + Theme.topInset + scale.y(h) }
        let area = bounds.width - Theme.eventsLeading - Theme.trailing
        for v in subviews {
            let s = v[Slot.self]
            switch s.kind {
            case .card(let column, let columns):
                let colWidth = area / CGFloat(max(columns, 1))
                let x = bounds.minX + Theme.eventsLeading + colWidth * CGFloat(column)
                let top = y(s.start) + Self.cardGap / 2
                let h = max(y(s.end) - Self.cardGap / 2 - top, Self.cardMinHeight)
                v.place(at: CGPoint(x: x, y: top), anchor: .topLeading,
                        proposal: ProposedViewSize(width: colWidth - (column < columns - 1 ? 4 : 0), height: h))
            case .rule:
                let x = bounds.minX + Theme.eventsLeading - 4
                v.place(at: CGPoint(x: x, y: y(s.start) - 0.5), anchor: .topLeading,
                        proposal: ProposedViewSize(width: bounds.maxX - x, height: 1))
            case .sunRule:
                let x = bounds.minX + Theme.gutter
                v.place(at: CGPoint(x: x, y: y(s.start) - 0.5), anchor: .topLeading,
                        proposal: ProposedViewSize(width: bounds.maxX - x, height: 1))
            case .label:
                v.place(at: CGPoint(x: bounds.minX + Theme.gutter - 6, y: y(s.start)), anchor: .trailing,
                        proposal: .unspecified)
            case .sunTag:
                v.place(at: CGPoint(x: bounds.maxX - Theme.trailing, y: y(s.start) - 2), anchor: .bottomTrailing,
                        proposal: .unspecified)
            case .band:
                let m = RainLayer.margin
                let top = y(s.start) - m
                v.place(at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading,
                        proposal: ProposedViewSize(width: bounds.width, height: y(s.end) + m - top))
            }
        }
    }
}

// MARK: - Now

private struct NowLine: View, Animatable {
    let day: Date
    var scale: ScaleBlend

    var animatableData: Double {
        get { scale.t }
        set { scale.t = newValue }
    }

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let offset = Theme.topInset + scale.y(ctx.date.timeIntervalSince(day) / 3600)
            HStack(spacing: 0) {
                Circle().fill(Theme.now).frame(width: 7, height: 7)
                Rectangle().fill(Theme.now).frame(height: 1.5)
            }
            .padding(.leading, Theme.eventsLeading - 4)
            .offset(y: offset - 3.5)
            .allowsHitTesting(false)
        }
    }
}
