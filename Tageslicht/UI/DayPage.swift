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

    @State private var position = ScrollPosition(edge: .top)
    @State private var didScroll = false
    @State private var didAppear = false
    /// Where the timeline's viewport is. Written on every scroll frame, read only by the
    /// actions below and while a zoom runs, so scrolling never redraws the page.
    @State private var geo = PageGeometry()
    /// The in-flight zoom/fold change, stepped frame by frame by `driver`.
    @State private var blend: ScaleBlend?
    @State private var driver = FrameDriver()
    /// The offset the driver last set; the scroll view reports it a frame late.
    @State private var drivenY: CGFloat?
    @AppStorage("timelineZoom") private var zoom = TimelineZoom.standard.rawValue
    @AppStorage("timelineFullDay") private var fullDay = false
    @AppStorage(DayTimeline.pinGridKey) private var pinGrid = false

    private var hourHeight: CGFloat { (TimelineZoom(rawValue: zoom) ?? .standard).hourHeight }

    /// Only the timeline: the date, the controls and the all-day events sit above the pager
    /// and stay put while the days slide under them.
    var body: some View {
        ScrollView(.vertical) {
            DayTimeline(model: model, isToday: isToday, isActive: isActive,
                        hourHeight: hourHeight, fullDay: fullDay, blend: blend, onSelect: onSelect,
                        extraBottom: blend == nil ? 0 : geo.height, pinGrid: pinGrid)
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Viewport.self) {
            Viewport(offset: $0.contentOffset.y, height: $0.containerSize.height)
        } action: { _, new in
            geo.offset = new.offset
            geo.height = new.height
        }
        // The pages beside follow once per gesture, not every frame: when a finger lands,
        // when it lifts, when the scroll comes to rest. A finger landing to swipe sideways
        // is one of those, so they are lined up before they come into view.
        .onScrollPhaseChange { _, _ in publishAnchor() }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { geo.top = $0 }
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
        guard isActive, didAppear, blend == nil, geo.height > 0 else { return }
        let lead = geo.height / 3
        let hour = currentScale.hour(atY: geo.offset + lead - Theme.topInset)
        let next = TimeAnchor(hour: hour, screenY: geo.top + lead)
        if next != anchor { anchor = next }
    }

    private func align(to a: TimeAnchor) {
        position.scrollTo(y: max(0, currentScale.y(a.hour) + Theme.topInset - (a.screenY - geo.top)))
        didScroll = true
    }

    private struct Viewport: Equatable {
        let offset: CGFloat
        let height: CGFloat
    }

    /// Not observed: nothing redraws when it changes.
    private final class PageGeometry {
        var offset: CGFloat = 0
        var height: CGFloat = 0
        /// Window y of the timeline's visible top edge.
        var top: CGFloat = 0
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
        let lead = geo.height / 3
        let fromY = drivenY ?? geo.offset
        let hour = before.hour(atY: fromY + lead - Theme.topInset)
        // Land inside the final content, so dropping the extra room at the end moves nothing.
        let maxY = max(0, after.height + Theme.topInset * 2 - geo.height)
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
