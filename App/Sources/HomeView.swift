import BelfryCore
import SwiftUI

// Home (2026-11-16, board iOS-Home): what needs me today on this belfry. Rows show only when
// they have something: requests (stewards, vouching members), a new agreement of the charter,
// To-dos · Mentions · Messages, Coming up, then Recent activity (unread channels and groups).
// No buttons on event rows: the state in words; the event screen holds the actions. Nothing
// waiting: the Arms, one sentence, the next thing on my calendar and two ways out.
// A guest's Home (board Join-Guest 4): Apply to become a member first, the channels they were
// invited to, then the belfry's places open to everyone.

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let _ = model.version
        SwiftUI.Group {
            if model.derive.amGuest || model.guestReading { GuestHome() } else { MemberHome() }
        }
        .placeChrome(model.derive.amGuest || model.guestReading ? "Welcome" : "Today")
        .refreshable { await model.refresh(); await model.loadRequests(force: true) }
        .task { await model.loadRequests() }
    }
}

private struct MemberHome: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let d = model.derive
        let todos = model.myTodos
        let requests = model.requestCount
        let toAgree = d.charterToAgree()
        let coming = Array(model.comingUp().prefix(3))
        let recent = Array(model.unreadPlaces().prefix(6))
        let calm = requests == 0 && toAgree.isEmpty && todos.onMe.isEmpty && model.newMentions == 0 && model.unreadDMs == 0 && recent.isEmpty
        List {
            Section {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            if requests > 0 {
                Section {
                    NavigationLink(value: PlaceRoute.gates) {
                        HomeRow(icon: "door.left.hand.open", title: requests == 1 ? "1 asking to join" : "\(requests) asking to join",
                                detail: requestNames(), badge: requests)
                    }
                    .accessibilityIdentifier("home-requests")
                }
            }
            if !toAgree.isEmpty {
                Section {
                    NavigationLink(value: PlaceRoute.charter) {
                        HomeRow(icon: "checkmark.seal", title: toAgree.count == 1 ? "1 new agreement to read" : "\(toAgree.count) new agreements to read",
                                detail: "Charter: " + toAgree[0].title, badge: toAgree.count)
                    }
                    .accessibilityIdentifier("home-charter")
                }
            }
            if calm {
                Section { CalmCard(next: model.calendar(.mine).first) }
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    HomeTiles(todos: todos)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            if !calm && !coming.isEmpty {
                Section {
                    ForEach(coming) { e in
                        NavigationLink(value: EventRoute(key: e.coord, ticket: nil)) { EventLine(e: e) }
                    }
                } header: { sectionHeader("Coming up", link: "Calendar") { model.tab = .calendar } }
            }
            if !recent.isEmpty {
                Section {
                    ForEach(recent) { g in
                        NavigationLink(value: ChatRoute(id: g.id)) { PlaceLine(group: g) }
                    }
                } header: { sectionHeader("Recent activity", link: "Town") { model.tab = .town } }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(14)
    }

    private func requestNames() -> String {
        let names = model.agentRequests.map { $0.name + ", an agent" } + model.belfryRequests.map(\.name)
        if names.isEmpty { return "Waiting for you in the Gates" }
        return names.prefix(2).joined(separator: " · ")
    }

    private func sectionHeader(_ title: String, link: String, go: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.title3.bold()).foregroundStyle(.primary)
            Spacer()
            Button(link, action: go).font(.subheadline).foregroundStyle(Color.brand)
        }
        .textCase(nil)
        .padding(.horizontal, -4)
    }
}

/// To-dos · Mentions · Messages: three tiles, each pushes its list.
private struct HomeTiles: View {
    @EnvironmentObject var model: AppModel
    let todos: (onMe: [TodoRef], open: [TodoRef])

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink(value: PlaceRoute.todos) {
                Tile(icon: "checkmark.circle", tint: .green, count: todos.onMe.count, title: "To-dos",
                     line: todos.onMe.isEmpty ? "\(todos.open.count) open" : "on you · \(todos.open.count) open")
            }
            .accessibilityIdentifier("home-todos")
            NavigationLink(value: PlaceRoute.mentions) {
                Tile(icon: "at", tint: .orange, count: model.newMentions, title: "Mentions", line: mentionLine())
            }
            .accessibilityIdentifier("home-mentions")
            NavigationLink(value: PlaceRoute.messages) {
                Tile(icon: "message", tint: .blue, count: model.unreadDMs, title: "Messages", line: messageLine())
            }
            .accessibilityIdentifier("home-messages")
        }
        .buttonStyle(.plain)
    }

    private func mentionLine() -> String {
        guard let m = model.mentions.first else { return "Nobody yet" }
        let g = m.tag("h").flatMap { model.group($0)?.name }
        return [model.name(m.pubkey).components(separatedBy: " ").first, g].compactMap { $0 }.joined(separator: ", ")
    }

    private func messageLine() -> String {
        let unread = (model.dms?.threads() ?? []).filter { $0.unread > 0 }
        if unread.isEmpty { return "All read" }
        let names = unread.prefix(2).map { convName(model, $0.conv).components(separatedBy: " ").first ?? "" }
        return names.joined(separator: ", ") + (unread.count > 2 ? " +\(unread.count - 2)" : "")
    }
}

private struct Tile: View {
    let icon: String
    let tint: Color
    let count: Int
    let title: String
    let line: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(tint, in: Circle())
                Spacer()
                Text("\(count)").font(.title2.bold()).monospacedDigit()
            }
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// A row of Home: an icon in a rounded square, a title, a line, a count.
struct HomeRow: View {
    let icon: String
    let title: String
    let detail: String
    var badge = 0
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(Color.brand)
                .frame(width: 36, height: 36)
                .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if badge > 0 { CountBadge(n: badge) }
        }
    }
}

/// An event in a list: the date, the title, "18:30 · you host · check-in today". No buttons.
struct EventLine: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    var body: some View {
        HStack(spacing: 12) {
            DateChip(at: e.start)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var line: String {
        var parts = [e.allDay ? "All day" : Format.time(e.start)]
        if e.meeting { parts.append(e.links.isEmpty ? "meeting" : "online meeting") }
        parts.append(model.eventStatus(e))
        return parts.joined(separator: " · ")
    }
}

/// An unread channel or group: its mark, name, last message, time, count.
struct PlaceLine: View {
    @EnvironmentObject var model: AppModel
    let group: Channel
    var subtitle: String? = nil
    var body: some View {
        let last = model.derive.messages(group.id).last
        let n = model.unread(group.id)
        HStack(spacing: 12) {
            PlaceGlyph(group: group)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.body.weight(n > 0 ? .semibold : .medium)).foregroundStyle(.primary).lineLimit(1)
                if let last {
                    Text(model.name(last.ev.pubkey).components(separatedBy: " ").first.map { $0 + ": " } ?? "")
                        .font(.subheadline).foregroundStyle(.secondary)
                    + Text(preview(last.text)).font(.subheadline).foregroundStyle(.secondary)
                }
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                if let last { Text(Format.short(last.at)).font(.caption).foregroundStyle(.secondary) }
                if n > 0 { CountBadge(n: n) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func preview(_ t: String) -> String {
        let plain = Rx("\\*\\*|__|~~|`").replace(t, with: "")
        let s = model.derive.plainRefs(plain).replacingOccurrences(of: "\n", with: " ")
        return s.isEmpty ? "a photo" : s
    }
}

/// A channel's # or a group's shape, in a grey circle.
struct PlaceGlyph: View {
    let group: Channel
    var body: some View {
        SwiftUI.Group {
            if group.isPod {
                PodShape(members: group.members.count)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: group.isProposal ? "doc.text" : "number").font(.body.weight(.semibold))
            }
        }
        .frame(width: 40, height: 40)
        .background(Color.primary.opacity(0.07), in: Circle())
        .accessibilityHidden(true)
    }
}

/// Nothing waits: calm, not empty.
private struct CalmCard: View {
    @EnvironmentObject var model: AppModel
    let next: CalEvent?
    var body: some View {
        VStack(spacing: 14) {
            BelfryLogo(size: 52)
                .frame(width: 84, height: 84)
                .background(Color.brand.opacity(0.1), in: Circle())
            Text("You're all caught up").font(.title3.bold())
            Text(next == nil ? "No to-dos, mentions or messages waiting. Nothing on your calendar this week."
                             : "No to-dos, mentions or messages waiting. They'll show up here when someone needs you.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let next {
                NavigationLink(value: EventRoute(key: next.coord, ticket: nil)) {
                    EventLine(e: next).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Button { model.tab = .town } label: { Label("Open the Square", systemImage: "building.columns") }
                    .buttonStyle(.bordered)
                Button { model.tab = .calendar } label: { Label("What's on", systemImage: "calendar") }
                    .buttonStyle(.bordered)
            }
            .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// ---- a guest's Home --------------------------------------------------------------------------

private struct GuestHome: View {
    @EnvironmentObject var model: AppModel
    @State private var applying = false

    var body: some View {
        let d = model.derive
        let first = model.realName(model.me).components(separatedBy: " ").first ?? ""
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    if !first.isEmpty { Text("Hello, " + first).font(.headline) }
                    Text(model.guestLine).font(.subheadline).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            Section { ApplyCard(applying: $applying) }
            let mine = model.guestChannels
            if !mine.isEmpty {
                Section("You were invited to") {
                    ForEach(mine) { g in NavigationLink(value: ChatRoute(id: g.id)) { PlaceLine(group: g) } }
                }
            }
            let open = model.openToEveryone
            if d.charterGroup != nil || !open.isEmpty {
                Section("Open to everyone") {
                    if d.charterGroup != nil, !d.charter().isEmpty {
                        NavigationLink(value: PlaceRoute.charter) {
                            HomeRow(icon: "checkmark.seal", title: "Charter", detail: "\(d.charter().count) short agreements")
                        }
                    }
                    ForEach(open) { g in NavigationLink(value: ChatRoute(id: g.id)) { PlaceLine(group: g, subtitle: g.about.isEmpty ? nil : g.about) } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $applying) { ApplySheet() }
    }
}

/// "Become a member of X": the one big action of a guest's Home, or the request's state.
struct ApplyCard: View {
    @EnvironmentObject var model: AppModel
    @Binding var applying: Bool
    var body: some View {
        let name = model.config.name
        VStack(alignment: .leading, spacing: 10) {
            if model.guestApplied {
                Text("Your request to become a member").font(.headline)
                Text(model.membership.accept == "vouches" ? "Any member can vouch; a steward can also say yes. You stay a guest meanwhile."
                                                          : "A steward will answer. You stay a guest meanwhile.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Label("Sent", systemImage: "paperplane").font(.subheadline.weight(.medium)).foregroundStyle(Color.brand)
            } else {
                Text("Become a member of \(name)").font(.headline)
                Text(acceptLine()).font(.subheadline).foregroundStyle(.secondary)
                Button { hideKeyboard(); applying = true } label: {
                    Text("Apply to become a member").frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand)
                .accessibilityIdentifier("guest-apply")
            }
        }
        .padding(.vertical, 6)
    }

    private func acceptLine() -> String {
        let base = "Members see the whole town: the Square, its events and groups."
        if model.membership.accept == "vouches" {
            let n = model.membership.vouches
            return base + " " + (n == 1 ? "One vouch" : "\(n) vouches") + " or a steward's yes."
        }
        return base + " A steward's yes."
    }
}

/// A guest asks to become a member (board Join-Apply 1): the belfry's question, the saved
/// e-mail, the charter's agreements. The belfry can't take a guest's request yet (SERVER-NEEDS
/// 12): the request is refused in words, except in the demo.
struct ApplySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var answer = ""
    @State private var error: String?
    @State private var charter = false

    var body: some View {
        let d = model.derive
        let rules = d.charter()
        let agreed = rules.filter { $0.agreed[model.me] != nil }.count
        NavigationStack {
            Form {
                Section {
                    Text(model.membership.accept == "vouches"
                         ? "\(model.config.name) asks one question. Members vouching, or a steward's yes, makes you a member."
                         : "\(model.config.name) asks one question. A steward's yes makes you a member.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("What brings you to \(model.config.name)?") {
                    TextField("A few words", text: $answer, axis: .vertical).lineLimit(3...8).font(.body)
                }
                Section("E-mail") {
                    if model.unsavedGuest {
                        Label("Save your e-mail first: Me → Save your account", systemImage: "envelope.badge")
                    } else {
                        Label("Saved", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                }
                if !rules.isEmpty {
                    Section {
                        Button { charter = true } label: {
                            LabeledContent("Our charter", value: "\(agreed) of \(rules.count) agreements ticked")
                        }
                    }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
                Section {
                    BusyButton {
                        error = await model.applyAsGuest(answer: answer)
                        if error == nil { dismiss() }
                    } label: { Text("Send request").frame(maxWidth: .infinity) }
                    .buttonStyle(.brand)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.unsavedGuest || agreed < rules.count)
                } footer: {
                    Text("Your name and answer are shown to members; your e-mail only to stewards.")
                }
            }
            .navigationTitle("Become a member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(isPresented: $charter) { CharterView() }
        }
    }
}
