import Combine
import SwiftUI

/// Rain (or snow) falling across the hours it is forecast, with depth: every drop has
/// a distance, and distance sets its size, speed and strength. Far drops are drawn
/// behind the event cards, the nearest ones in front of them.
///
/// No hard box: each drop starts and stops a little before or after the forecast hours,
/// and fades in and out over its own stretch and towards the sides, so the shower has a
/// ragged, natural outline.
///
/// Drops are placed by a fixed hash of their index and moved by the clock, so there is
/// no per-drop state and nothing to allocate between frames. Drops are batched by depth
/// and by fade level: a dozen strokes per frame at most. The clock only runs on the
/// page in view, at most 60 times a second even on a 120 Hz screen, and stops under
/// Reduce Motion and in Low Power Mode, where the shower stands still.
///
/// The shower has inertia (see `Sway`): a page starting, stopping or turning sets the
/// drops swinging a moment later, a page gliding evenly leaves them be, and a swipe to and
/// fro keeps them swaying. Far drops swing slower and less than near ones, and the bottom
/// of the screen a beat after the top, so it bends like a curtain rather than sliding as
/// one sheet. A drop tilts with its swing.
///
/// Only the shower's place on screen is tracked, outside any view state; the swing steps
/// as a frame is drawn, a few multiplications per depth. While the pager is moving, the
/// pages beside the one in view fall too, so the one arriving already sways.
/// Whether the day pager is moving. Only the rain reads it, so a swipe starting or ending
/// redraws nothing else.
@MainActor
@Observable
final class PagerActivity {
    var moving = false
}

struct RainLayer: View {
    enum Plane { case behind, inFront }

    let span: PrecipSpan
    /// Seeds the drop hash, so separate showers don't fall in lockstep.
    let index: Int
    let active: Bool
    let plane: Plane

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(PagerActivity.self) private var pager: PagerActivity?
    @State private var sway = Sway()

    /// Depth planes; the last one is the near plane drawn over the cards.
    private static let depths = 4
    /// Fade levels per depth.
    private static let fades = 3
    private static let maxDropsPerSpan = 160
    /// How far a drop's own start/end may wander from the forecast hour boundary.
    private static let wander: CGFloat = 30
    /// Length of the fade at each end of a drop's run.
    private static let fadeLength: CGFloat = 34
    /// Room the view needs above and below the wet hours for drops that start early or end late.
    static let margin: CGFloat = wander + fadeLength

    var body: some View {
        // The canvas only covers this shower's hours (plus margin), never the whole day.
        let still = !(active || pager?.moving == true) || reduceMotion || lowPower
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: still)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // Standing still, the shower holds whatever swing it had.
                if !still { sway.step(at: t) }
                let v = reduceMotion ? Sway.Frame.rest : sway.frame
                let field = Field(left: Theme.gutter * 0.5, right: size.width)
                let planes = plane == .inFront ? (Self.depths - 1)..<Self.depths : 0..<(Self.depths - 1)
                let band = Band(index: index, span: span, top: Self.margin, bottom: size.height - Self.margin)
                guard band.bottom - band.top > 6 else { return }
                if span.snow {
                    drawSnow(&ctx, band, field, planes: planes, t: t, v: v)
                } else {
                    drawRain(&ctx, band, field, planes: planes, t: t, v: v)
                }
            }
        }
        .allowsHitTesting(false)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { sway.origin = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    /// What the shower hangs by. Written as the page moves, stepped as a frame is drawn;
    /// not observed, so it redraws nothing.
    ///
    /// Inertia, not a rubber band: the drops answer the page's change of speed, never its
    /// position or its speed as such. A page gliding evenly carries them along untouched,
    /// as a smoothly moving train carries a hanging lamp. When it starts, stops or turns,
    /// they lag, gather, swing past and settle, and all of that grows from nothing over a
    /// fraction of a second rather than jumping at the first touch:
    ///  - the page's motion first passes through a short, critically damped smoothing,
    ///    the give of the air it carries, so even a sudden start reaches the drops as a
    ///    build-up, never a jolt, and its acceleration comes out of the smoothing itself
    ///    instead of from differencing noisy samples;
    ///  - each depth hangs from that air as a lightly damped pendulum in a moving frame,
    ///    x'' = -w^2 x - 2 zeta w x' - a, whose swing starts at rest and only builds as
    ///    the acceleration acts on it.
    private final class Sway {
        /// The shower's place on screen, from the layout.
        var origin: CGPoint = .zero
        private var last: CGPoint?
        private var lastTime: Double = 0
        /// The air the drops fall through: the page's motion, smoothed.
        private var air: CGPoint = .zero
        private var airSpeed: CGVector = .zero
        /// How quickly the air takes up the page's motion, rad/s (critically damped).
        private static let give: CGFloat = 24
        /// Per depth, one pendulum at the top of the screen and one at the bottom.
        private var pendulums: [Pendulum] = (0..<RainLayer.depths).flatMap { d -> [Pendulum] in
            let near = (Double(d) + 0.5) / Double(RainLayer.depths)
            // Heavier, slower far drops; the bottom of the screen a beat behind the top.
            let period = 0.95 - 0.27 * near
            return [Pendulum(period: period, damping: 0.2), Pendulum(period: period * 1.15, damping: 0.18)]
        }
        private(set) var frame = Frame.rest

        /// What a frame draws with: per depth, how far the drops are carried off at the top
        /// and at the bottom of the screen.
        struct Frame {
            var offset: [CGVector]
            static let rest = Frame(offset: Array(repeating: .zero, count: RainLayer.depths * 2))

            /// At a given height on screen, between the top pendulum and the bottom one.
            func at(depth: Int, screenY: CGFloat) -> CGVector {
                let w = min(1, max(0, screenY / 900))
                let a = offset[depth * 2], b = offset[depth * 2 + 1]
                return CGVector(dx: a.dx + (b.dx - a.dx) * w, dy: a.dy + (b.dy - a.dy) * w)
            }
        }

        func step(at t: Double) {
            guard t > lastTime else { return }
            let dt = t - lastTime
            defer { last = origin; lastTime = t }
            // First frame, or back after a pause: the air settles where the page is, and
            // the drops keep the swing they had but none of its speed.
            guard let from = last, dt <= 0.1 else {
                air = origin
                airSpeed = .zero
                for i in pendulums.indices { pendulums[i].speed = .zero }
                return
            }
            // Fine steps, the page moving evenly between the two samples, so the result is
            // the same at any frame rate.
            let n = max(1, Int((dt * 240).rounded(.up)))
            let h = CGFloat(dt / Double(n))
            let g = Self.give
            for k in 1...n {
                let f = CGFloat(k) / CGFloat(n)
                let page = CGPoint(x: from.x + (origin.x - from.x) * f, y: from.y + (origin.y - from.y) * f)
                let accel = CGVector(dx: g * g * (page.x - air.x) - 2 * g * airSpeed.dx,
                                     dy: g * g * (page.y - air.y) - 2 * g * airSpeed.dy)
                airSpeed.dx += accel.dx * h
                airSpeed.dy += accel.dy * h
                air.x += airSpeed.dx * h
                air.y += airSpeed.dy * h
                for i in pendulums.indices { pendulums[i].step(frameAccel: accel, dt: h) }
            }
            for i in pendulums.indices {
                let near = (CGFloat(i / 2) + 0.5) / CGFloat(RainLayer.depths)
                frame.offset[i] = pendulums[i].shown(reachX: 6 + 12 * near, reachY: 3 + 6 * near)
            }
        }
    }

    /// A drop hanging in the moving air: a damped pendulum seen from the frame that moves,
    /// so the frame's acceleration is the only force that sets it going.
    private struct Pendulum {
        let w: CGFloat
        let zeta: CGFloat
        var lag: CGVector = .zero
        var speed: CGVector = .zero

        init(period: Double, damping: Double) {
            w = CGFloat(2 * .pi / period)
            zeta = CGFloat(damping)
        }

        mutating func step(frameAccel a: CGVector, dt h: CGFloat) {
            speed.dx += (-w * w * lag.dx - 2 * zeta * w * speed.dx - a.dx) * h
            speed.dy += (-w * w * lag.dy - 2 * zeta * w * speed.dy - a.dy) * h
            lag.dx += speed.dx * h
            lag.dy += speed.dy * h
        }

        /// The drift on screen, softly bounded: a hard flick drags the drops a bounded way,
        /// a light one a proportionate way, and nothing stops dead at a wall.
        func shown(reachX: CGFloat, reachY: CGFloat) -> CGVector {
            let gain: CGFloat = 0.13
            return CGVector(dx: reachX * tanh(gain * lag.dx / reachX),
                            dy: reachY * tanh(gain * lag.dy / reachY))
        }
    }

    private struct Band {
        let index: Int
        let span: PrecipSpan
        let top: CGFloat
        let bottom: CGFloat
    }

    /// Horizontal extent; drops thin out towards both sides instead of stopping at a line.
    private struct Field {
        let left: CGFloat
        let right: CGFloat
        var width: CGFloat { right - left }

        func fade(_ x: CGFloat) -> CGFloat {
            min(1, max(0, (x - left) / 60)) * min(1, max(0, (right - x) / 28))
        }
    }

    /// This drop's own run: the band, nudged a little at each end.
    private func run(_ b: Band, _ i: Int) -> (top: CGFloat, bottom: CGFloat) {
        let top = b.top - Self.fadeLength * 0.5 + (CGFloat(rand(b.index, i, 7)) - 0.5) * 2 * Self.wander
        let bottom = b.bottom + Self.fadeLength * 0.5 + (CGFloat(rand(b.index, i, 8)) - 0.5) * 2 * Self.wander
        return (top, max(bottom, top + Self.fadeLength * 2))
    }

    private func fadeLevel(_ alpha: CGFloat) -> Int? {
        guard alpha > 0.06 else { return nil }
        return min(Self.fades - 1, Int(alpha * CGFloat(Self.fades)))
    }

    // MARK: Rain

    /// Fall speed of a near drop, by mm/h. The range follows the rain but stays gentle.
    private static func speed(_ mm: Double) -> Double {
        switch mm {
        case ..<0.5: return 140
        case ..<2: return 190
        default: return 250
        }
    }

    /// Drops per 1000 pt², by mm/h.
    private static func density(_ mm: Double) -> Double {
        switch mm {
        case ..<0.5: return 0.3
        case ..<2: return 0.5
        default: return 0.8
        }
    }

    /// Horizontal drift per point fallen, from wind in m/s.
    private static func slant(_ wind: Double) -> CGFloat {
        CGFloat(min(0.22, max(0.04, wind * 0.02)))
    }

    /// Each drop lives briefly: it appears somewhere in the shower, falls a short way and
    /// fades, then comes back elsewhere after a random pause. No conveyor belt of streaks
    /// looping top to bottom; the wind's lean drifts slowly too.
    private func drawRain(_ ctx: inout GraphicsContext, _ b: Band, _ f: Field, planes: Range<Int>,
                          t: Double, v: Sway.Frame) {
        let height = b.bottom - b.top
        let area = Double(f.width * (height + Self.wander))
        // About 60 % of drops are visible at any moment; budget for that.
        let count = min(Self.maxDropsPerSpan * 2, Int(area / 1000 * Self.density(b.span.intensity) / 0.6))
        let gust = 1 + 0.35 * sin(t * 0.45 + Double(b.index)) * sin(t * 0.17)
        let slant = Self.slant(b.span.wind) * CGFloat(gust)
        let baseSpeed = Self.speed(b.span.intensity)
        let top = sway.origin.y
        var paths = Array(repeating: Path(), count: Self.depths * Self.fades)
        for i in 0..<count {
            let depth = min(Self.depths - 1, Int(rand(b.index, i, 6) * Double(Self.depths)))
            guard planes.contains(depth) else { continue }
            let near = (Double(depth) + 0.5) / Double(Self.depths)       // 0 far … 1 near
            let life = 0.7 + 0.9 * rand(b.index, i, 1)
            let period = life * (1.3 + 0.7 * rand(b.index, i, 9))
            let clock = t + rand(b.index, i, 3) * period
            let cycle = floor(clock / period)
            let local = clock - cycle * period
            guard local < life else { continue }
            let c = Int(cycle.truncatingRemainder(dividingBy: 9973))
            // A fresh place every appearance.
            let speed = baseSpeed * (0.55 + 0.6 * near) * (0.85 + 0.3 * cycleRand(b.index, i, c, 2))
            let y0 = b.top - Self.wander * 0.5 + CGFloat(cycleRand(b.index, i, c, 5)) * (height + Self.wander)
            let fall = CGFloat(speed * local)
            // Carried off by its swing, a little more or less than its neighbours, and
            // tilted the way a hanging thing tilts when it swings out: by how far, not how
            // fast, so the tilt grows and fades with the swing instead of snapping.
            let off = v.at(depth: depth, screenY: top + y0 + fall)
            let give = CGFloat(0.8 + 0.4 * rand(b.index, i, 11))
            let down = max(0.75, min(1.4, 1 + off.dy * give / 30))
            let lean = slant - max(-0.45, min(0.45, off.dx * give / 36))
            let length = CGFloat(6 + 7 * near) * CGFloat(0.8 + 0.4 * cycleRand(b.index, i, c, 7)) * down
            let y = y0 + fall + off.dy * give
            let x = f.left + CGFloat(cycleRand(b.index, i, c, 4)) * f.width - fall * slant + off.dx * give
            // Fade over the drop's own life, and softly towards the shower's edges.
            let life01 = CGFloat(sin(Double.pi * local / life))
            let edge = min(1, max(0, min(y - (b.top - Self.wander), b.bottom + Self.wander - y) / Self.fadeLength))
            guard let level = fadeLevel(life01 * edge * f.fade(x)) else { continue }
            let k = depth * Self.fades + level
            paths[k].move(to: CGPoint(x: x, y: y))
            paths[k].addLine(to: CGPoint(x: x - length * lean, y: y + length))
        }
        for depth in planes {
            let near = (Double(depth) + 0.5) / Double(Self.depths)
            // Short and round-ended: drops, not streaks.
            let style = StrokeStyle(lineWidth: 3 + 2.4 * near, lineCap: .round)
            for level in 0..<Self.fades where !paths[depth * Self.fades + level].isEmpty {
                let opacity = (0.10 + 0.22 * near) * Double(level + 1) / Double(Self.fades)
                ctx.stroke(paths[depth * Self.fades + level], with: .color(Theme.ink.opacity(opacity)), style: style)
            }
        }
    }

    // MARK: Snow

    private func drawSnow(_ ctx: inout GraphicsContext, _ b: Band, _ f: Field, planes: Range<Int>,
                          t: Double, v: Sway.Frame) {
        let area = Double(f.width * (b.bottom - b.top + Self.wander))
        let count = min(Self.maxDropsPerSpan, Int(area / 1000 * 0.5))
        var paths = Array(repeating: Path(), count: Self.depths * Self.fades)
        for i in 0..<count {
            let depth = min(Self.depths - 1, Int(rand(b.index, i, 6) * Double(Self.depths)))
            guard planes.contains(depth) else { continue }
            let near = (Double(depth) + 0.5) / Double(Self.depths)
            let speed = (18 + 30 * near) * (0.8 + 0.4 * rand(b.index, i, 1))
            let r = CGFloat(1.4 + 2.2 * near)
            let (top, bottom) = run(b, i)
            let travel = Double(bottom - top + r * 2)
            let fallen = top - r + CGFloat((rand(b.index, i, 3) * travel + t * speed).truncatingRemainder(dividingBy: travel))
            // Flakes are light: they swing further than drops.
            let off = v.at(depth: depth, screenY: sway.origin.y + fallen)
            let give = CGFloat(1.1 + 0.5 * rand(b.index, i, 11))
            let y = fallen + off.dy * give
            let drift = CGFloat(4 + 4 * near) * CGFloat(sin(t * 1.1 + rand(b.index, i, 5) * 6.28))
            let x = f.left + CGFloat(rand(b.index, i, 4)) * f.width + drift + off.dx * give
            let vertical = min(1, max(0, min(y + r - top, bottom - y) / Self.fadeLength))
            guard let level = fadeLevel(vertical * f.fade(x)) else { continue }
            paths[depth * Self.fades + level].addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        for depth in planes {
            let near = (Double(depth) + 0.5) / Double(Self.depths)
            for level in 0..<Self.fades where !paths[depth * Self.fades + level].isEmpty {
                let opacity = (0.25 + 0.4 * near) * Double(level + 1) / Double(Self.fades)
                ctx.fill(paths[depth * Self.fades + level], with: .color(Theme.ink.opacity(opacity * 0.6)))
            }
        }
    }

    /// Like `rand`, but different on each appearance of the drop.
    private func cycleRand(_ span: Int, _ i: Int, _ cycle: Int, _ channel: Int) -> Double {
        rand(span, i * 7 + cycle * 7919, channel + 31)
    }

    /// Stable pseudo-random in [0, 1) per drop and channel.
    private func rand(_ span: Int, _ i: Int, _ channel: Int) -> Double {
        let v = sin(Double(span * 7919 + i * 104_729 + channel * 1_299_709) * 12.9898) * 43758.5453
        return v - floor(v)
    }
}

/// Sunshine across the hours forecast clear and cloudless: a few broad, soft shafts of light
/// falling from the upper right, drifting slowly sideways and brightening and dimming each
/// at its own pace, over a faint lift of the whole stretch. Light, not ink: on the pale page
/// brighter than the paper, on the black one a glow. Behind the cards only.
///
/// Like the rain, it has no hard box: it fades in over the stretch above its first hour and
/// out below its last, and towards the hour labels on the left. Shafts are placed by a
/// fixed hash and moved by the clock, nothing kept between frames; the clock runs only on
/// the page in view (and while paging), at 30 frames a second, which slow light needs, and
/// stops under Reduce Motion and in Low Power Mode.
struct SunshineLayer: View {
    /// Seeds the hash, so separate sunny stretches don't move in step.
    let index: Int
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(PagerActivity.self) private var pager: PagerActivity?

    private static let shafts = 4
    /// Horizontal run per point down: the sun stands high to the right.
    private static let lean: CGFloat = 0.42

    var body: some View {
        let still = !(active || pager?.moving == true) || reduceMotion || lowPower
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { timeline in
            Canvas { ctx, size in
                draw(&ctx, size, t: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .mask {
            GeometryReader { g in
                // The band reaches RainLayer.margin past its hours at both ends: the light
                // comes up over that stretch and is full across the hours themselves.
                let m = min(0.45, RainLayer.margin * 1.5 / max(g.size.height, 1))
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: m),
                                       .init(color: .black, location: 1 - m), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .mask {
                        let w = min(0.4, Theme.gutter * 1.2 / max(g.size.width, 1))
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: w),
                                               .init(color: .black, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, t: Double) {
        let light = Theme.sunlight
        // The whole stretch a touch brighter.
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light.opacity(0.22)))
        // Shafts drawn upright, then sheared: x moves left by `lean` per point down.
        var c = ctx
        c.transform = CGAffineTransform(a: 1, b: 0, c: -Self.lean, d: 1, tx: 0, ty: 0)
        let reach = size.width + Self.lean * size.height
        for i in 0..<Self.shafts {
            let width = 28 + 46 * CGFloat(rand(i, 1))
            let place = (Double(i) + 0.5) / Double(Self.shafts) + (rand(i, 2) - 0.5) * 0.18
            let drift = 22 * sin(t * 2 * .pi / (17 + 11 * rand(i, 3)) + rand(i, 4) * 6.28)
            let x = CGFloat(place) * reach + CGFloat(drift)
            // Each brightens and dims at its own slow pace, never quite going out.
            let breathe = 0.6 + 0.4 * sin(t * 2 * .pi / (7 + 5 * rand(i, 5)) + rand(i, 6) * 6.28)
            let strength = (0.45 + 0.35 * rand(i, 7)) * breathe
            let gradient = Gradient(stops: [.init(color: light.opacity(0), location: 0),
                                            .init(color: light.opacity(strength), location: 0.5),
                                            .init(color: light.opacity(0), location: 1)])
            c.fill(Path(CGRect(x: x - width / 2, y: 0, width: width, height: size.height)),
                   with: .linearGradient(gradient, startPoint: CGPoint(x: x - width / 2, y: 0),
                                         endPoint: CGPoint(x: x + width / 2, y: 0)))
        }
    }

    /// Stable pseudo-random in [0, 1) per shaft and channel.
    private func rand(_ i: Int, _ channel: Int) -> Double {
        let v = sin(Double(index * 7919 + i * 104_729 + channel * 1_299_709) * 12.9898) * 43758.5453
        return v - floor(v)
    }
}
