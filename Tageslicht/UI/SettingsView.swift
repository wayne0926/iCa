import SwiftUI

/// How the month view colours its events, which calendars the app shows (folded away until
/// asked for, grouped by account), and which build this is. A tap toggles a calendar; the
/// change reaches the month and day pages at once.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [(source: String, calendars: [CalendarSource.Info])] = []
    @AppStorage(MonthColorStyle.key) private var colorStyle = MonthColorStyle.dot
    @AppStorage(DayTimeline.pinGridKey) private var pinGrid = false
    @State private var calendarsOpen = false

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
                Section {
                    Toggle("翻页时时间线不动", isOn: $pinGrid)
                } header: {
                    Text("日视图")
                } footer: {
                    Text("翻页时，刻度和日出日落不跟着翻走。")
                }
                Section {
                    DisclosureGroup(isExpanded: $calendarsOpen) {
                        ForEach(groups, id: \.source) { group in
                            Text(group.source)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.graphite)
                            ForEach(group.calendars) { cal in
                                row(cal)
                            }
                        }
                    } label: {
                        HStack {
                            Text("显示的日历")
                            Spacer(minLength: 0)
                            Text(shownSummary)
                                .monospacedDigit()
                                .foregroundStyle(Theme.graphite)
                        }
                    }
                }
                Section {
                    LabeledContent("版本", value: Self.version)
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

    /// How many of the calendars are shown, e.g. "5 / 7".
    private var shownSummary: String {
        let all = groups.flatMap(\.calendars)
        let shown = all.filter { !store.hiddenCalendars.contains($0.id) }.count
        return "\(shown) / \(all.count)"
    }

    /// Version and build, so two builds can be told apart.
    static let version: String = {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }()

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
