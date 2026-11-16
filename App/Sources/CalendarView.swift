import BelfryCore
import SwiftUI

// Calendar (2026-11-16, board iOS-CalGroups): My calendar (going, maybe, hosting) · Invited (not
// answered yet) · Discover (the belfry's other events); meetings are events too. A week strip
// (Monday first) with a dot under the days that have something; going back a week shows that
// week's past events. No buttons on rows: a row says its state and pushes the event screen.
// Guests (board Join-Guest 5): Public events · Going.

struct CalendarView: View {
    @EnvironmentObject var model: AppModel
    @State private var list: CalendarList?
    @State private var week = 0
    @State private var newEvent = false

    var body: some View {
        let _ = model.version
        let guest = model.derive.amGuest || model.guestReading
        let lists: [CalendarList] = guest ? [.publicEvents, .going] : [.mine, .invited, .discover]
        let current = list.flatMap { lists.contains($0) ? $0 : nil } ?? lists[0]
        let events = week == 0 ? model.calendar(current) : pastOrFuture(current)
        List {
            Section {
                Picker("Which events", selection: Binding(get: { current }, set: { list = $0 })) {
                    ForEach(lists, id: \.self) { l in Text(label(l)).tag(l) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                WeekStrip(week: $week, marked: Set(events.map { model.derive.startOfDay($0.start) }))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            }
            if events.isEmpty {
                Section {
                    Text(empty(current)).font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(sections(events), id: \.title) { s in
                    Section {
                        ForEach(s.events) { e in
                            NavigationLink(value: EventRoute(key: e.coord, ticket: nil)) { CalendarRow(e: e, showDay: s.showDay) }
                        }
                    } header: {
                        HStack {
                            Text(s.title).font(.title3.bold()).foregroundStyle(.primary)
                            Spacer()
                            if let d = s.detail { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        .textCase(nil)
                        .padding(.horizontal, -4)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .placeChrome("Calendar")
        .toolbar {
            if !guest {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { hideKeyboard(); newEvent = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New event")
                }
            }
        }
        .sheet(isPresented: $newEvent) { EventFormSheet(editing: nil, channel: generalId) }
        .refreshable { await model.refresh() }
    }

    private func label(_ l: CalendarList) -> String {
        if l == .invited {
            let n = model.calendar(.invited).count
            return n > 0 ? "Invited \(n)" : "Invited"
        }
        return l.title
    }

    private func empty(_ l: CalendarList) -> String {
        if week != 0 { return "Nothing that week." }
        switch l {
        case .mine, .going: return "You're not going to anything yet. Discover shows what's on."
        case .invited: return "No invitations waiting."
        case .discover, .publicEvents: return "Nothing planned yet."
        }
    }

    /// Another week (back = past events of that week, forward = that week's events).
    private func pastOrFuture(_ l: CalendarList) -> [CalEvent] {
        let d = model.derive
        let (from, to) = WeekStrip.range(week)
        let pool: [CalEvent]
        if week < 0 {
            pool = d.eventsIn(.past, now: .now).filter { e in l == .discover || l == .publicEvents || model.isMine(e) }
        } else {
            pool = model.calendar(l)
        }
        return pool.filter { $0.start >= from && $0.start < to }.sorted { $0.start < $1.start }
    }

    struct Part { let title: String; var detail: String?; let events: [CalEvent]; var showDay = true }

    private func sections(_ events: [CalEvent]) -> [Part] {
        let d = model.derive
        let now = Int.now
        if week != 0 {
            let (from, _) = WeekStrip.range(week)
            let start = Date(timeIntervalSince1970: TimeInterval(from))
            return [Part(title: "Week of " + start.formatted(.dateTime.day().month(.wide)), events: events)]
        }
        let today = d.startOfDay(now)
        let (_, weekEnd) = WeekStrip.range(0)
        let t = events.filter { d.startOfDay($0.start) <= today }
        let w = events.filter { d.startOfDay($0.start) > today && $0.start < weekEnd }
        let later = events.filter { $0.start >= weekEnd }
        var out = [Part]()
        if !t.isEmpty { out.append(Part(title: "Today", detail: Date.now.formatted(.dateTime.weekday(.wide).day()), events: t, showDay: false)) }
        if !w.isEmpty { out.append(Part(title: "This week", events: w)) }
        if !later.isEmpty { out.append(Part(title: "Later", events: later)) }
        return out
    }
}

/// One event: time column, a coloured bar, title, "place · state" (and how many go when I host).
private struct CalendarRow: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let showDay: Bool
    var body: some View {
        let date = Date(timeIntervalSince1970: TimeInterval(e.start))
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                if showDay { Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.subheadline) }
                Text(e.allDay ? "All day" : Format.time(e.start)).font(showDay ? .subheadline : .subheadline.weight(.medium))
                    .foregroundStyle(showDay ? .secondary : .primary)
                if !showDay, let end = e.end, !e.allDay { Text(Format.time(end)).font(.subheadline).foregroundStyle(.secondary) }
            }
            .frame(width: 54, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.body.weight(.medium)).lineLimit(2)
                Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var line: String {
        var parts = [String]()
        if let p = model.eventPlace(e) { parts.append(p) }
        if let ch = e.channels.first, let g = model.group(ch), ch != generalId { parts.append(g.name) }
        parts.append(model.eventStatus(e))
        return parts.joined(separator: " · ")
    }

    private var tint: Color {
        if e.status == .cancelled { return .secondary }
        if e.hosts.contains(model.me) { return .orange }
        if e.meeting { return .pink }
        if model.isInvited(e) { return .red }
        let palette: [Color] = [.blue, .green, .teal, .indigo, .purple]
        return palette[e.d.utf8.reduce(0) { $0 &+ Int($1) } % palette.count]
    }
}

/// A week, Monday first: the month, ‹ ›, seven days, today filled, a dot under days with events.
struct WeekStrip: View {
    @Binding var week: Int
    let marked: Set<Int>

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = .current
        return c
    }

    /// [start, end) of week OFFSET (0 = this week), unix seconds.
    static func range(_ offset: Int) -> (Int, Int) {
        let c = calendar
        let start = c.dateInterval(of: .weekOfYear, for: .now)?.start ?? c.startOfDay(for: .now)
        let s = c.date(byAdding: .day, value: 7 * offset, to: start) ?? start
        let e = c.date(byAdding: .day, value: 7, to: s) ?? s
        return (Int(s.timeIntervalSince1970), Int(e.timeIntervalSince1970))
    }

    var body: some View {
        let c = WeekStrip.calendar
        let (from, _) = WeekStrip.range(week)
        let start = Date(timeIntervalSince1970: TimeInterval(from))
        let days = (0..<7).compactMap { c.date(byAdding: .day, value: $0, to: start) }
        VStack(spacing: 8) {
            HStack {
                Text(start.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { withAnimation { week -= 1 } } label: { Image(systemName: "chevron.left").frame(width: 36, height: 30) }
                    .accessibilityLabel("Week before")
                Button { withAnimation { week += 1 } } label: { Image(systemName: "chevron.right").frame(width: 36, height: 30) }
                    .accessibilityLabel("Week after")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.brand)
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    let today = c.isDateInToday(day)
                    VStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(day.formatted(.dateTime.day())).font(.title3.weight(today ? .bold : .regular))
                            .foregroundStyle(today ? Theme.onAccent : .primary)
                            .frame(width: 38, height: 38)
                            .background(today ? Theme.accent : Color.clear, in: Circle())
                        Circle().fill(marked.contains(Int(c.startOfDay(for: day).timeIntervalSince1970)) ? Color.secondary : Color.clear)
                            .frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -40 { withAnimation { week += 1 } } else if v.translation.width > 40 { withAnimation { week -= 1 } }
        })
    }
}
