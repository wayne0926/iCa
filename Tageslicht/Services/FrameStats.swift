import QuartzCore

/// Launch with `-frameStats` to log dropped frames: every frame that took longer than
/// one and a half display intervals, summed per second of activity. Off by default and
/// costs nothing then; used to compare builds while scrolling.
@MainActor
final class FrameStats: NSObject {
    static let shared = FrameStats()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0, late = 0, lost = 0
    private var worst: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0

    func startIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-frameStats"), link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let interval = l.targetTimestamp - l.timestamp
        defer { last = l.timestamp }
        guard last > 0, interval > 0 else { windowStart = l.timestamp; return }
        let dt = l.timestamp - last
        frames += 1
        if dt > interval * 1.5 {
            late += 1
            lost += Int((dt / interval).rounded()) - 1
            worst = max(worst, dt)
        }
        if l.timestamp - windowStart >= 1 {
            if late > 0 {
                print(String(format: "FRAMES %d late %d lost %d worst %.0fms", frames, late, lost, worst * 1000))
            }
            frames = 0; late = 0; lost = 0; worst = 0
            windowStart = l.timestamp
        }
    }
}
