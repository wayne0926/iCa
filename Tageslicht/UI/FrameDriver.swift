import SwiftUI
import QuartzCore

/// Runs one spring from 0 to 1 on the display's own clock and reports progress every
/// frame. The timeline and its scroll position both read the same number, so they can't
/// drift apart the way two separately animated properties do.
@MainActor
final class FrameDriver {
    static let spring = Spring(duration: 0.55, bounce: 0.14)

    private var link: CADisplayLink?
    private var elapsed: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var onFrame: ((Double) -> Void)?
    private var onEnd: (() -> Void)?

    func run(onFrame: @escaping (Double) -> Void, onEnd: @escaping () -> Void) {
        stop()
        self.onFrame = onFrame
        self.onEnd = onEnd
        elapsed = 0
        last = CACurrentMediaTime()
        let link = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        onFrame(0)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// A frame never advances the curve by more than this: after a hitch the motion
    /// resumes where it was instead of skipping to the end.
    private static let maxStep: CFTimeInterval = 1.0 / 30

    fileprivate func tick(_ timestamp: CFTimeInterval) {
        elapsed += min(timestamp - last, Self.maxStep)
        last = timestamp
        if elapsed >= Self.spring.settlingDuration {
            stop()
            onFrame?(1)
            onEnd?()
            onFrame = nil
            onEnd = nil
            return
        }
        onFrame?(Self.spring.value(target: 1.0, time: elapsed))
    }

    /// CADisplayLink retains its target; the proxy keeps that from retaining the driver.
    private final class Proxy: NSObject {
        weak var owner: FrameDriver?
        init(_ owner: FrameDriver) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            let t = link.targetTimestamp
            MainActor.assumeIsolated { owner?.tick(t) }
        }
    }
}
