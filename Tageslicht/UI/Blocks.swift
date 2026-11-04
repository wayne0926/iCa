import SwiftUI

/// An event as a lifted card: plain surface, soft shadow, the calendar's colour as a
/// capsule set inside the padding rather than painted along the edge.
struct EventBlock: View {
    let event: CalEvent
    let compact: Bool
    /// Tall enough to give the place its own line.
    let roomy: Bool
    let isPast: Bool

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 10) {
            Capsule()
                .fill(CalendarInk.mark(event.calendarColor).opacity(isPast ? 0.45 : 1))
                // One width everywhere; short cards only get a shorter capsule.
                .frame(width: 11, height: compact ? 20 : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(Theme.eventTitle)
                    .foregroundStyle(isPast ? Theme.graphite : Theme.ink)
                    .lineLimit(compact ? 1 : 2)
                if !compact, let place = event.location, !place.isEmpty {
                    Text(place)
                        .font(Theme.eventDetail)
                        .foregroundStyle(Theme.graphite)
                        .lineLimit(roomy ? 2 : 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, compact ? 0 : (roomy ? 12 : 8))
        .animation(.spring(duration: 0.35), value: roomy)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .leading : .topLeading)
        .background { CardSurface(radius: compact ? Theme.blockRadius * 0.625 : Theme.blockRadius,
                                  fill: CalendarInk.card(event.calendarColor)) }
    }
}

/// Card fill and shadow on one shape, so the shadow follows the same corners.
/// A fixed continuous radius: a card keeps its shape wherever it sits on screen.
/// In dark mode a shadow can't lift anything; the fill's own tone does (see `CalendarInk`).
private struct CardSurface: View {
    let radius: CGFloat
    let fill: Color

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .shadow(color: Theme.shadow, radius: 8, x: 0, y: 3)
    }
}
