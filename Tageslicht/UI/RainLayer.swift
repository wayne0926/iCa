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
struct RainLayer: View {
    enum Plane { case behind, inFront }

    let span: PrecipSpan
    /// Seeds the drop hash, so separate showers don't fall in lockstep.
    let index: Int
    let active: Bool
    let plane: Plane

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

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
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active || reduceMotion || lowPower)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let field = Field(left: Theme.gutter * 0.5, right: size.width)
                let planes = plane == .inFront ? (Self.depths - 1)..<Self.depths : 0..<(Self.depths - 1)
                let band = Band(index: index, span: span, top: Self.margin, bottom: size.height - Self.margin)
                guard band.bottom - band.top > 6 else { return }
                if span.snow {
                    drawSnow(&ctx, band, field, planes: planes, t: t)
                } else {
                    drawRain(&ctx, band, field, planes: planes, t: t)
                }
            }
        }
        .allowsHitTesting(false)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
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
    private func drawRain(_ ctx: inout GraphicsContext, _ b: Band, _ f: Field, planes: Range<Int>, t: Double) {
        let height = b.bottom - b.top
        let area = Double(f.width * (height + Self.wander))
        // About 60 % of drops are visible at any moment; budget for that.
        let count = min(Self.maxDropsPerSpan * 2, Int(area / 1000 * Self.density(b.span.intensity) / 0.6))
        let gust = 1 + 0.35 * sin(t * 0.45 + Double(b.index)) * sin(t * 0.17)
        let slant = Self.slant(b.span.wind) * CGFloat(gust)
        let baseSpeed = Self.speed(b.span.intensity)
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
            let length = CGFloat(6 + 7 * near) * CGFloat(0.8 + 0.4 * cycleRand(b.index, i, c, 7))
            let y0 = b.top - Self.wander * 0.5 + CGFloat(cycleRand(b.index, i, c, 5)) * (height + Self.wander)
            let fall = CGFloat(speed * local)
            let y = y0 + fall
            let x = f.left + CGFloat(cycleRand(b.index, i, c, 4)) * f.width - fall * slant
            // Fade over the drop's own life, and softly towards the shower's edges.
            let life01 = CGFloat(sin(Double.pi * local / life))
            let edge = min(1, max(0, min(y - (b.top - Self.wander), b.bottom + Self.wander - y) / Self.fadeLength))
            guard let level = fadeLevel(life01 * edge * f.fade(x)) else { continue }
            let k = depth * Self.fades + level
            paths[k].move(to: CGPoint(x: x, y: y))
            paths[k].addLine(to: CGPoint(x: x - length * slant, y: y + length))
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

    private func drawSnow(_ ctx: inout GraphicsContext, _ b: Band, _ f: Field, planes: Range<Int>, t: Double) {
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
            let y = top - r + CGFloat((rand(b.index, i, 3) * travel + t * speed).truncatingRemainder(dividingBy: travel))
            let sway = CGFloat(4 + 4 * near) * CGFloat(sin(t * 1.1 + rand(b.index, i, 5) * 6.28))
            let x = f.left + CGFloat(rand(b.index, i, 4)) * f.width + sway
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
