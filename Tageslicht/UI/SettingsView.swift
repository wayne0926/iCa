import SwiftUI

/// How the month view colours its events, and which calendars the app shows, grouped by
/// account. A tap toggles one; the change reaches the month and day pages at once.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [(source: String, calendars: [CalendarSource.Info])] = []
    @AppStorage(MonthColorStyle.key) private var colorStyle = MonthColorStyle.dot

    var body: some View {
        NavigationStack {
            List {
                Section("月历") {
                    Picker("日历颜色", selection: $colorStyle) {
                        Text("小点").tag(MonthColorStyle.dot)
                        Text("整块上色").tag(MonthColorStyle.fill)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                ForEach(groups, id: \.source) { group in
                    Section(group.source) {
                        ForEach(group.calendars) { cal in
                            row(cal)
                        }
                    }
                }
            }
            .navigationTitle("设置")
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
