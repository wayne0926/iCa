import SwiftUI

/// Which calendars the app shows, grouped by account. A tap toggles one; the change
/// reaches the month and day pages at once.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [(source: String, calendars: [CalendarSource.Info])] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.source) { group in
                    Section(group.source) {
                        ForEach(group.calendars) { cal in
                            row(cal)
                        }
                    }
                }
            }
            .navigationTitle("显示的日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(Theme.ink)
        .onAppear { groups = store.calendarGroups() }
    }

    private func row(_ cal: CalendarSource.Info) -> some View {
        let shown = !store.hiddenCalendars.contains(cal.id)
        return Button {
            store.setCalendar(cal.id, shown: !shown)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(CalendarInk.mark(cal.color))
                    .frame(width: 12, height: 12)
                Text(cal.title)
                    .foregroundStyle(shown ? Theme.ink : Theme.graphite)
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .opacity(shown ? 1 : 0)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(shown ? .isSelected : [])
    }
}
