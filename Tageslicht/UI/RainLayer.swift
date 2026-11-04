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
/// The shower hangs on the page by springs. Each depth of drops falls through its own
/// pocket of air, tied to the page by an underdamped spring: when the page moves, the
/// drops trail behind it; when it stops, they swing past, back, and settle, so a swipe to
/// and fro sets the shower swaying. Far drops swing slower and less than near ones, and
/// the bottom of the screen a beat after the top, so it bends like a curtain rather than
/// sliding as one sheet. A drop leans along its swing and stretches with it.
///
/// Only the shower's place on screen is tracked, outside any view state; the springs step
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

    /// The springs the shower hangs by. Written as the page moves, stepped as a frame is
    /// drawn; not observed, so it redraws nothing.
    private final class Sway {
        /// The shower's place on screen, from the layout.
        var origin: CGPoint = .zero
        private var last: CGPoint?
        private var lastTime: Double = 0
        /// Per depth, one spring at the top of the screen and one at the bottom.
        private var springs: [Spring] = (0..<RainLayer.depths).flatMap { d -> [Spring] in
            let near = (Double(d) + 0.5) / Double(RainLayer.depths)
            // Near air is light and quick, far air slow; the bottom trails the top.
            let duration = 0.95 - 0.3 * near
            return [Spring(duration: duration, bounce: 0.68), Spring(duration: duration * 1.3, bounce: 0.64)]
        }
        private(set) var frame = Frame.rest

        /// What a frame draws with: per depth, how far the drops are carried off at the top
        /// and at the bottom of the screen, and how fast.
        struct Frame {
            var offset: [CGVector]
            var velocity: [CGVector]
            static let rest = Frame(offset: Array(repeating: .zero, count: RainLayer.depths * 2),
                                    velocity: Array(repeating: .zero, count: RainLayer.depths * 2))

            /// At a given height on screen, between the top spring and the bottom one.
            func at(depth: Int, screenY: CGFloat) -> (offset: CGVector, velocity: CGVector) {
                let w = min(1, max(0, screenY / 900))
                let a = depth * 2, b = a + 1
                return (CGVector(dx: offset[a].dx + (offset[b].dx - offset[a].dx) * w,
                                 dy: offset[a].dy + (offset[b].dy - offset[a].dy) * w),
                        CGVector(dx: velocity[a].dx + (velocity[b].dx - velocity[a].dx) * w,
                                 dy: velocity[a].dy + (velocity[b].dy - velocity[a].dy) * w))
            }
        }

        func step(at t: Double) {
            guard t > lastTime else { return }
            let dt = t - lastTime
            defer { last = origin; lastTime = t }
            guard let from = last else { return }
            // Back after a pause: the air keeps the swing it had, and picks up from where
            // the page is now, at rest.
            if dt > 0.1 {
                for i in springs.indices { springs[i].resume(page: origin) }
                return
            }
            // Fine steps, the page moving evenly between the two samples, so a stiff spring
            // stays steady at any frame rate.
            let n = max(1, Int((dt * 240).rounded(.up)))
            let h = dt / Double(n)
            for k in 1...n {
                let f = CGFloat(k) / CGFloat(n)
                let page = CGPoint(x: from.x + (origin.x - from.x) * f, y: from.y + (origin.y - from.y) * f)
                for i in springs.indices { springs[i].step(toward: page, dt: h) }
            }
            for i in springs.indices {
                let depth = i / 2
                let near = (CGFloat(depth) + 0.5) / CGFloat(RainLayer.depths)
                // Soft limits: a hard swipe drags the drops a bounded way, a small one a
                // proportionate way, and nothing ever stops dead at a wall.
                let new = springs[i].shown(reachX: 5 + 12 * near, reachY: 3 + 7 * near)
                let old = frame.offset[i]
                let raw = CGVector(dx: (new.dx - old.dx) / dt, dy: (new.dy - old.dy) / dt)
                let e = CGFloat(1 - exp(-dt / 0.04))
                frame.velocity[i].dx += (raw.dx - frame.velocity[i].dx) * e
                frame.velocity[i].dy += (raw.dy - frame.velocity[i].dy) * e
                frame.offset[i] = new
            }
        }
    }

    /// A pocket of air tied to the page: stiffness and damping from a duration and a
    /// bounce, the way SwiftUI's own springs are made (mass 1). The drag on it is the air's
    /// own, so a steady scroll holds the drops a little behind, and a stop lets them swing.
    private struct Spring {
        let stiffness: CGFloat
        let damping: CGFloat
        var air: CGPoint?
        var speed: CGVector = .zero
        /// Where the air sat against the page when the clock last stopped.
        var held: CGVector = .zero

        init(duration: Double, bounce: Double) {
            stiffness = CGFloat(pow(2 * .pi / duration, 2))
            damping = CGFloat(4 * .pi * (1 - bounce) / duration)
        }

        mutating func step(toward page: CGPoint, dt: Double) {
            var a = air ?? page
            let h = CGFloat(dt)
            speed.dx += (stiffness * (page.x - a.x) - damping * speed.dx) * h
            speed.dy += (stiffness * (page.y - a.y) - damping * speed.dy) * h
            a.x += speed.dx * h
            a.y += speed.dy * h
            air = a
            held = CGVector(dx: a.x - page.x, dy: a.y - page.y)
        }

        mutating func resume(page: CGPoint) {
            air = CGPoint(x: page.x + held.dx, y: page.y + held.dy)
            speed = .zero
        }

        /// The drift on screen: the air's lag, softly bounded.
        func shown(reachX: CGFloat, reachY: CGFloat) -> CGVector {
            let gain: CGFloat = 0.14
            return CGVector(dx: reachX * tanh(gain * held.dx / reachX),
                            dy: reachY * tanh(gain * held.dy / reachY))
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
            // Carried off by its swing, a little more or less than its neighbours; leaning
            // along the way it moves through the page, stretched when it swings down.
            let (off, vel) = v.at(depth: depth, screenY: top + y0 + fall)
            let give = CGFloat(0.8 + 0.4 * rand(b.index, i, 11))
            let s = CGFloat(speed)
            let down = max(0.7, min(1.6, (s + vel.dy * give) / s))
            let lean = slant - max(-0.5, min(0.5, vel.dx * give / s))
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
            let off = v.at(depth: depth, screenY: sway.origin.y + fallen).offset
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
