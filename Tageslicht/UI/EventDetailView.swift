import SwiftUI

struct EventDetailView: View {
    let event: CalEvent
    let plan: TravelPlan?
    /// The day's forecast, for where the day's events are.
    let hours: [HourWeather]
    /// Held where the event before it was.
    let sameRoom: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.calendarTitle).font(.footnote).foregroundStyle(Theme.graphite)
                    Text(event.title).font(.title2.weight(.bold))
                    Text(timeText).font(.subheadline).foregroundStyle(Theme.graphite).monospacedDigit()
                }

                if let loc = event.location, !loc.isEmpty {
                    Row(symbol: "mappin.and.ellipse", title: loc,
                        detail: sameRoom ? "和上一项在同一地点" : nil)
                }

                if let w = weather {
                    Row(symbol: w.kind.symbol(daylight: w.hour.isDaylight),
                        title: "\(Int(w.hour.temperature.rounded()))°",
                        detail: w.rain.map { String(format: "期间有雨，最大 %.1f mm/h", $0) },
                        tint: w.rain == nil ? .primary : Theme.rain)
                }

                if let plan {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("路上").font(.footnote.weight(.semibold)).foregroundStyle(Theme.graphite)
                        if let b = plan.bike {
                            Row(symbol: "bicycle",
                                title: "骑车 \(Fmt.minutes(b.duration))",
                                detail: plan.mode == .bicycle ? "\(plan.leaveAt.formatted(Fmt.time)) 出发" : nil,
                                chosen: plan.mode == .bicycle)
                        }
                        if let t = plan.transitRoute {
                            Row(symbol: t.firstLeg?.vehicle.symbol ?? "bus.fill",
                                title: transitTitle(t),
                                detail: t.firstLeg.map { "\($0.stop) \($0.departure.formatted(Fmt.time)) 发车" },
                                chosen: plan.mode == .transit)
                        }
                        if plan.reason == .rain {
                            Row(symbol: "cloud.rain.fill", title: "路上有雨，建议坐车", tint: Theme.rain)
                        } else if plan.reason == .far {
                            Row(symbol: "arrow.left.and.right", title: "骑车较远，坐车更省力")
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The hour it starts, and the heaviest rain while it runs, if any.
    private var weather: (hour: HourWeather, kind: WeatherKind, rain: Double?)? {
        guard let first = hours.last(where: { $0.time <= event.start }) ?? hours.first,
              event.start < (hours.last?.time.addingTimeInterval(3600) ?? .distantPast) else { return nil }
        let during = hours.filter { $0.time.addingTimeInterval(3600) > event.start && $0.time < event.end }
        let peak = during.map(\.precipitation).max() ?? 0
        return (first, WeatherKind(pictocode: first.pictocode), peak >= TravelPolicy.rainMillimetres ? peak : nil)
    }

    private var timeText: String {
        if event.isAllDay { return "全天" }
        return "\(Fmt.monthDay(event.start)) \(event.start.formatted(Fmt.time)) – \(event.end.formatted(Fmt.time))"
    }

    private func transitTitle(_ t: RouteResult) -> String {
        guard let leg = t.firstLeg else { return "公共交通 \(Fmt.minutes(t.duration))" }
        return "\(leg.line)\(leg.vehicle.lineSuffix) · 共 \(Fmt.minutes(t.duration))"
    }
}

private struct Row: View {
    let symbol: String
    let title: String
    var detail: String?
    var chosen = false
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(tint == .primary ? Theme.graphite : tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(chosen ? .semibold : .regular)).foregroundStyle(tint)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(Theme.graphite).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            if chosen {
                Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(Theme.graphite)
            }
        }
    }
}
