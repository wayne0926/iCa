import SwiftUI

/// An hour of the day and where on screen it sits (window coordinates, so pages whose
/// headers differ in height still line up).
struct TimeAnchor: Equatable {
    let hour: Double
    let screenY: CGFloat
}

struct DayPage: View {
    let model: DayModel
    let isToday: Bool
    let isActive: Bool
    @Binding var anchor: TimeAnchor?
    let onSelect: (CalEvent) -> Void
    /// Back to the month grid.
    let onClose: () -> Void

    @State private var position = ScrollPosition(edge: .top)
    @State private var didScroll = false
    @State private var didAppear = false
    @State private var viewport = Viewport(offset: 0, height: 0)
    /// Window y of the timeline's visible top edge.
    @State private var viewportTop: CGFloat = 0
    /// The in-flight zoom/fold change, stepped frame by frame by `driver`.
    @State private var blend: ScaleBlend?
    @State private var driver = FrameDriver()
    /// The offset the driver last set; the scroll view reports it a frame late.
    @State private var drivenY: CGFloat?
    @AppStorage("timelineZoom") private var zoom = TimelineZoom.standard.rawValue
    @AppStorage("timelineFullDay") private var fullDay = false

    private var hourHeight: CGFloat { (TimelineZoom(rawValue: zoom) ?? .standard).hourHeight }

    var body: some View {
        VStack(spacing: 0) {
            DayHeader(model: model, isToday: isToday, fullDay: fullDay,
                      zoomGrows: (TimelineZoom(rawValue: zoom) ?? .standard).next.hourHeight > hourHeight,
                      onClose: onClose,
                      onZoom: { zoom = (TimelineZoom(rawValue: zoom) ?? .standard).next.rawValue },
                      onFullDay: { fullDay.toggle() })
            if !model.allDay.isEmpty {
                AllDayStrip(events: model.allDay, onSelect: onSelect)
            }
            Divider()
            ScrollView(.vertical) {
                DayTimeline(model: model, isToday: isToday, isActive: isActive,
                            hourHeight: hourHeight, fullDay: fullDay, blend: blend, onSelect: onSelect,
                            extraBottom: blend == nil ? 0 : viewport.height)
            }
            .scrollPosition($position)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Viewport.self) {
                Viewport(offset: $0.contentOffset.y, height: $0.containerSize.height)
            } action: { _, new in
                viewport = new
                publishAnchor()
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { viewportTop = $0 }
        }
        .background(Theme.paper)
        .onAppear {
            // After the first layout pass, or the scroll view has nothing to scroll yet.
            DispatchQueue.main.async {
                if let anchor { align(to: anchor) } else { scrollToStart() }
                didAppear = true
            }
        }
        .onChange(of: anchor) { _, new in
            // Pages beside the one in view follow it, so a swipe lands on the same hours.
            if !isActive, let new { align(to: new) }
        }
        .onChange(of: model.placed.first?.id) { _, _ in
            if fullDay && !isToday && !didAppear { didScroll = false; scrollToStart() }
        }
        .onChange(of: Mode(hourHeight: hourHeight, fullDay: fullDay)) { old, new in
            keepAnchor(from: old, to: new)
        }
    }

    private var currentScale: ScaleFrame {
        blend?.to ?? ScaleFrame(DayTimeline.scale(for: model, isToday: isToday, hourHeight: hourHeight, fullDay: fullDay))
    }

    /// The page in view reports which hour sits a third of the way down.
    private func publishAnchor() {
        guard isActive, didAppear, blend == nil, viewport.height > 0 else { return }
        let lead = viewport.height / 3
        let hour = currentScale.hour(atY: viewport.offset + lead - Theme.topInset)
        let next = TimeAnchor(hour: hour, screenY: viewportTop + lead)
        if next != anchor { anchor = next }
    }

    private func align(to a: TimeAnchor) {
        position.scrollTo(y: max(0, currentScale.y(a.hour) + Theme.topInset - (a.screenY - viewportTop)))
        didScroll = true
    }

    private struct Viewport: Equatable {
        let offset: CGFloat
        let height: CGFloat
    }

    private struct Mode: Equatable {
        let hourHeight: CGFloat
        let fullDay: Bool
    }

    /// On zoom or fold, the moment a third of the way down the view stays put on screen.
    /// One spring drives both the timeline and the scroll offset, frame by frame.
    private func keepAnchor(from old: Mode, to new: Mode) {
        // Pages out of view just land on the new scale, lined up with the page in view.
        guard isActive else {
            driver.stop()
            blend = nil
            drivenY = nil
            if let anchor { align(to: anchor) }
            return
        }
        // A change tapped mid-flight starts from what is on screen right now, not from
        // where the previous one was heading: no frame ever jumps.
        let before = blend?.frame
            ?? ScaleFrame(DayTimeline.scale(for: model, isToday: isToday, hourHeight: old.hourHeight, fullDay: old.fullDay))
        let after = DayTimeline.scale(for: model, isToday: isToday, hourHeight: new.hourHeight, fullDay: new.fullDay)
        let target = ScaleFrame(after)
        let lead = viewport.height / 3
        let fromY = drivenY ?? viewport.offset
        let hour = before.hour(atY: fromY + lead - Theme.topInset)
        // Land inside the final content, so dropping the extra room at the end moves nothing.
        let maxY = max(0, after.height + Theme.topInset * 2 - viewport.height)
        let toY = min(maxY, max(0, after.y(hour) + Theme.topInset - lead))
        driver.run(onFrame: { p in
            blend = ScaleBlend(from: before, to: target, t: p)
            let y = fromY + (toY - fromY) * CGFloat(p)
            drivenY = y
            position.scrollTo(y: y)
        }, onEnd: {
            blend = nil
            drivenY = nil
        })
    }

    /// Today opens at "now". Folded days already start near their first event; a full day
    /// opens at its first event or 8:00, whichever is earlier.
    private func scrollToStart() {
        guard !didScroll else { return }
        let scale = DayTimeline.scale(for: model, isToday: isToday, hourHeight: hourHeight, fullDay: fullDay)
        let y: CGFloat
        if isToday {
            y = scale.y(Date().timeIntervalSince(model.day) / 3600) - 120
        } else if fullDay {
            y = scale.y(min(model.placed.first?.startHour ?? 8, 8) - 0.5)
        } else {
            y = 0
        }
        position.scrollTo(y: max(0, y))
        didScroll = true
    }
}

private struct DayHeader: View {
    let model: DayModel
    let isToday: Bool
    let fullDay: Bool
    /// The zoom button shows what a tap does: a plus while the next step is roomier.
    let zoomGrows: Bool
    let onClose: () -> Void
    let onZoom: () -> Void
    let onFullDay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // The date is the way back: a tap folds the day into its cell in the month.
                Button(action: onClose) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Fmt.monthDay(model.day))
                            .font(.system(size: 28, weight: .bold))
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
                    HStack(spacing: 5) {
                        Image(systemName: s.symbol)
                            .foregroundStyle(Theme.symbolTint(s.kind, daylight: true))
                        Text("\(s.low)° / \(s.high)°")
                            .monospacedDigit()
                    }
                    .font(.system(size: 15, weight: .semibold))
                }
            }
            HStack(spacing: 4) {
                // Only rain earns words here.
                if let wet = model.summary?.wetSpan {
                    Label(wet, systemImage: "drop.fill")
                        .foregroundStyle(Theme.rain)
                        .font(.system(size: 13))
                        .labelStyle(CompactLabelStyle())
                }
                Spacer(minLength: 0)
                // Both controls share one capsule, split by a hairline.
                HStack(spacing: 0) {
                    HeaderButton(symbol: "arrow.up.and.down",
                                 label: zoomGrows ? "放大时间线" : "缩小时间线", action: onZoom)
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
                    // Filled clock = the whole 24 hours are showing.
                    HeaderButton(symbol: fullDay ? "clock.fill" : "clock",
                                 label: fullDay ? "折叠空闲时段" : "显示全天", action: onFullDay)
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

private struct AllDayStrip: View {
    let events: [CalEvent]
    let onSelect: (CalEvent) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(events) { e in
                    Button { onSelect(e) } label: {
                        Text(e.title)
                            .lineLimit(1)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(CalendarInk.mark(e.calendarColor).opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 8)
    }
}
