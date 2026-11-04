import SwiftUI

/// The A layout on a folding time scale: busy stretches at full scale, long empty
/// stretches folded into a short strip. Rain falls across the hours it's forecast;
/// sunrise and sunset sit as small balls at the right edge.
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
            // Last, so a ball is never under a card it has stepped aside from, and its tap
            // never reaches the card.
            ForEach(sunMarks, id: \.rising) { mark in
                SunBall(date: mark.date, rising: mark.rising)
                    .layoutValue(key: Slot.self, value: .sun(mark.hour))
            }
        }
    }

    private struct SunMark {
        let date: Date
        let hour: Double
        let rising: Bool
    }

    private var sunMarks: [SunMark] {
        [(model.sun.sunrise, true), (model.sun.sunset, false)].compactMap { date, rising in
            date.map { SunMark(date: $0, hour: $0.timeIntervalSince(model.day) / 3600, rising: rising) }
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
        case rule, label, sun, band
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
    static func sun(_ h: Double) -> Slot { Slot(kind: .sun, start: h, end: h) }
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
        func cardSpan(_ s: Slot) -> (top: CGFloat, bottom: CGFloat) {
            let top = y(s.start) + Self.cardGap / 2
            return (top, top + max(y(s.end) - Self.cardGap / 2 - top, Self.cardMinHeight))
        }
        let area = bounds.width - Theme.eventsLeading - Theme.trailing
        // Where cards reach the right edge, for the sun balls to keep clear of. A handful of
        // cards, once per layout pass.
        let taken = Self.takenAtRightEdge(subviews.map { $0[Slot.self] }, span: cardSpan)
        for v in subviews {
            let s = v[Slot.self]
            switch s.kind {
            case .card(let column, let columns):
                let colWidth = area / CGFloat(max(columns, 1))
                let x = bounds.minX + Theme.eventsLeading + colWidth * CGFloat(column)
                let span = cardSpan(s)
                v.place(at: CGPoint(x: x, y: span.top), anchor: .topLeading,
                        proposal: ProposedViewSize(width: colWidth - (column < columns - 1 ? 4 : 0), height: span.bottom - span.top))
            case .rule:
                let x = bounds.minX + Theme.eventsLeading - 4
                v.place(at: CGPoint(x: x, y: y(s.start) - 0.5), anchor: .topLeading,
                        proposal: ProposedViewSize(width: bounds.maxX - x, height: 1))
            case .label:
                v.place(at: CGPoint(x: bounds.minX + Theme.gutter - 6, y: y(s.start)), anchor: .trailing,
                        proposal: .unspecified)
            case .sun:
                let clear = SunBall.size / 2 + 4
                let cy = Self.free(near: y(s.start), taken: taken, clear: clear,
                                   floor: bounds.minY + clear)
                // The view carries its own invisible tap margin on every side.
                v.place(at: CGPoint(x: bounds.maxX - SunBall.edge + SunBall.hitMargin, y: cy),
                        anchor: .trailing, proposal: .unspecified)
            case .band:
                let m = RainLayer.margin
                let top = y(s.start) - m
                v.place(at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading,
                        proposal: ProposedViewSize(width: bounds.width, height: y(s.end) + m - top))
            }
        }
    }

    /// The vertical stretches covered by cards in the last column, the ones that reach the
    /// right edge, sorted and merged.
    private static func takenAtRightEdge(_ slots: [Slot],
                                         span: (Slot) -> (top: CGFloat, bottom: CGFloat)) -> [ClosedRange<CGFloat>] {
        let spans = slots.compactMap { s -> ClosedRange<CGFloat>? in
            guard case .card(let column, let columns) = s.kind, column == columns - 1 else { return nil }
            let r = span(s)
            return r.top...r.bottom
        }
        .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<CGFloat>] = []
        for r in spans {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// The centre nearest `y` that keeps `clear` away from every taken stretch: the ball
    /// stays at its hour when it can, else steps just above or below the cards in its way,
    /// whichever is the shorter move.
    private static func free(near y: CGFloat, taken: [ClosedRange<CGFloat>], clear: CGFloat,
                             floor: CGFloat) -> CGFloat {
        // Grown by the clearance and merged again: two cards closer than a ball are one block.
        var blocks: [ClosedRange<CGFloat>] = []
        for r in taken {
            let g = (r.lowerBound - clear)...(r.upperBound + clear)
            if let last = blocks.last, g.lowerBound <= last.upperBound {
                blocks[blocks.count - 1] = last.lowerBound...max(last.upperBound, g.upperBound)
            } else {
                blocks.append(g)
            }
        }
        guard let block = blocks.first(where: { $0.contains(y) }) else { return y }
        let above = block.lowerBound, below = block.upperBound
        if above < floor { return below }
        return y - above <= below - y ? above : below
    }
}

// MARK: - Sun

/// Sunrise or sunset: a small, quiet ball at the right edge, near its hour. A tap slides
/// the time out to its left; it folds back by itself a few seconds later.
private struct SunBall: View {
    let date: Date
    let rising: Bool
    @State private var open = false

    static let size: CGFloat = 24
    /// Distance from the timeline's right edge to the ball's.
    static let edge: CGFloat = 6
    /// Invisible margin around the ball that still takes the tap.
    static let hitMargin: CGFloat = 8
    private static let glyph: CGFloat = 14

    var body: some View {
        HStack(spacing: 5) {
            if open {
                Text(date.formatted(Fmt.time))
                    .font(Theme.mark)
                    .foregroundStyle(Theme.sun)
                    .fixedSize()
                    .transition(.opacity.combined(with: .offset(x: 8)))
            }
            SunGlyph(rising: rising)
                .stroke(Theme.sun, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .frame(width: Self.glyph, height: Self.glyph)
        }
        // Closed it is exactly a circle; open, it grows to the left only, so the glyph
        // never moves under the finger.
        .padding(.leading, open ? 10 : (Self.size - Self.glyph) / 2)
        .padding(.trailing, (Self.size - Self.glyph) / 2)
        .frame(height: Self.size)
        .background(Capsule().fill(Theme.sunBall))
        .padding(Self.hitMargin)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.3)) { open.toggle() }
        }
        .task(id: open) {
            guard open else { return }
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.snappy(duration: 0.3)) { open = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rising ? "日出" : "日落") \(date.formatted(Fmt.time))")
        .accessibilityAddTraits(.isButton)
    }
}

/// A half sun on the horizon with a chevron above it: up for sunrise, down for sunset.
/// Drawn as strokes so the line weight matches the rest of the page.
private struct SunGlyph: Shape {
    let rising: Bool

    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        let base = r.minY + h * 0.82
        let radius = w * 0.3
        // Horizon.
        p.move(to: CGPoint(x: r.minX + w * 0.06, y: base))
        p.addLine(to: CGPoint(x: r.maxX - w * 0.06, y: base))
        // Upper half of the sun, left to right over the top.
        p.move(to: CGPoint(x: r.midX - radius, y: base))
        p.addRelativeArc(center: CGPoint(x: r.midX, y: base), radius: radius,
                         startAngle: .degrees(180), delta: .degrees(180))
        // Chevron.
        let top = r.minY + h * 0.07, depth = h * 0.17, half = w * 0.19
        let tip = rising ? top : top + depth
        let wings = rising ? top + depth : top
        p.move(to: CGPoint(x: r.midX - half, y: wings))
        p.addLine(to: CGPoint(x: r.midX, y: tip))
        p.addLine(to: CGPoint(x: r.midX + half, y: wings))
        return p
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
