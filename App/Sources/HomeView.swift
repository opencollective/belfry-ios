import BelfryCore
import SwiftUI

// Home (2026-11-16, board iOS-Home; 2026-11-17 the owner: "show the current date instead of
// Today… remove the you are all caught up… keep the hamburger menu top left"): the date as the
// big title, ☰ (the Town drawer) top left. One layout always: To-dos · Mentions · Messages tiles
// (a calm "Nothing new" when empty, still a shortcut), then what waits for me when there is
// something (requests, a new agreement, unread channels and groups), then the coming events.
// No buttons on event rows: the state in words; the event screen holds the actions.
// A guest's Home (board Join-Guest 4): Apply to become a member first, the channels they were
// invited to, then the belfry's places open to everyone.

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let _ = model.version
        SwiftUI.Group {
            if model.derive.amGuest || model.guestReading { GuestHome() } else { MemberHome() }
        }
        .homeChrome()
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
        let next = coming.isEmpty ? model.calendar(.mine).first : nil
        List {
            HomeDateTitle()
            Section {
                HomeTiles(todos: todos)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if requests > 0 {
                Section {
                    NavigationLink(value: PlaceRoute.members) {
                        HomeRow(icon: "person.2", title: requests == 1 ? "1 asking to join" : "\(requests) asking to join",
                                detail: requestNames(), badge: requests)
                    }
                    .accessibilityIdentifier("home-requests")
                }
            }
            if !toAgree.isEmpty {
                Section {
                    NavigationLink(value: PlaceRoute.charter) {
                        HomeRow(icon: "checkmark.seal", title: toAgree.count == 1 ? "1 new agreement to read" : "\(toAgree.count) new agreements to read",
                                detail: Self.agreementLine(toAgree[0]), badge: toAgree.count, detailLines: 2)
                    }
                    .accessibilityIdentifier("home-charter")
                }
            }
            if !recent.isEmpty {
                Section {
                    ForEach(recent) { g in
                        NavigationLink(value: ChatRoute(id: g.id)) { PlaceLine(group: g) }
                    }
                } header: { sectionHeader("Recent activity", link: "Town") { model.tab = .town } }
            }
            if !coming.isEmpty {
                Section {
                    ForEach(coming) { e in
                        NavigationLink(value: EventRoute(key: e.coord, ticket: nil)) { HomeEventLine(e: e) }
                    }
                } header: { sectionHeader("Coming up", link: "Calendar") { model.tab = .calendar } }
            } else if let next {
                Section {
                    NavigationLink(value: EventRoute(key: next.coord, ticket: nil)) { HomeEventLine(e: next) }
                } header: { sectionHeader("Next on your calendar", link: "Calendar") { model.tab = .calendar } }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(14)
    }

    /// The Home reminder's line (board home/home): the first new agreement, its title and explanation.
    static func agreementLine(_ r: Agreement) -> String {
        r.about.isEmpty ? r.title : r.title + ": " + r.about
    }

    private func requestNames() -> String {
        let names = model.agentRequests.map { $0.name + ", an agent" } + model.belfryRequests.map(\.name)
        if names.isEmpty { return "Waiting for you in Members" }
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
            Button { model.pushRoute = .todos } label: {
                Tile(icon: "checkmark.circle", tint: .green, count: todos.onMe.count, title: "To-dos", line: todoLine())
            }
            .accessibilityIdentifier("home-todos")
            Button { model.pushRoute = .mentions } label: {
                Tile(icon: "at", tint: .orange, count: model.newMentions, title: "Mentions", line: mentionLine())
            }
            .accessibilityIdentifier("home-mentions")
            Button { model.pushRoute = .messages } label: {
                Tile(icon: "message", tint: .blue, count: model.unreadDMs, title: "Messages", line: messageLine())
            }
            .accessibilityIdentifier("home-messages")
        }
        .buttonStyle(.plain)
    }

    private func todoLine() -> String {
        if todos.onMe.isEmpty { return todos.open.isEmpty ? "Nothing new" : "\(todos.open.count) open" }
        return "on you · \(todos.open.count) open"
    }

    private func mentionLine() -> String {
        guard model.newMentions > 0, let m = model.mentions.first else { return "Nothing new" }
        let g = m.tag("h").flatMap { model.group($0)?.name }
        return [model.name(m.pubkey).components(separatedBy: " ").first, g].compactMap { $0 }.joined(separator: ", ")
    }

    private func messageLine() -> String {
        let unread = (model.dms?.threads() ?? []).filter { $0.unread > 0 }
        if unread.isEmpty { return "Nothing new" }
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
                // a count only when something is new: the calm state has no number
                if count > 0 { Text("\(count)").font(.title2.bold()).monospacedDigit() }
            }
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.75)
            Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
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
    var detailLines = 1
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(Color.brand)
                .frame(width: 36, height: 36)
                .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(detailLines)
            }
            Spacer(minLength: 4)
            if badge > 0 { CountBadge(n: badge) }
        }
    }
}

/// An event in a list: the date, the title, "18:30 · you host · check-in today". No buttons.
struct HomeEventLine: View {
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
                GroupTitle(group: group, id: group.id).font(.body.weight(n > 0 ? .semibold : .medium)).foregroundStyle(.primary).lineLimit(1)
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

/// The date as Home's big title (it may shrink to fit; the navigation bar shows no title).
struct HomeDateTitle: View {
    var body: some View {
        Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            .font(.largeTitle.bold())
            .lineLimit(1).minimumScaleFactor(0.6)
            .accessibilityAddTraits(.isHeader)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("home-date")
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
            HomeDateTitle()
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
            let rules = model.charterRules
            if !rules.isEmpty || !open.isEmpty {
                Section("Open to everyone") {
                    if !rules.isEmpty {
                        NavigationLink(value: PlaceRoute.charter) {
                            HomeRow(icon: "checkmark.seal", title: "Charter", detail: rules.count == 1 ? "1 short agreement" : "\(rules.count) short agreements")
                        }
                    }
                    ForEach(open) { g in NavigationLink(value: ChatRoute(id: g.id)) { PlaceLine(group: g, subtitle: g.about.isEmpty ? nil : g.about) } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $applying) { BecomeMemberSheet() }
        .task {
            await model.loadApplyStatus()
            await model.loadPublicCharter()
        }
    }
}

/// "Become a member of X": the one big action of a guest's Home, or the request's state in words
/// (board Join-Apply 2): "1 of 2 vouches", who vouched, what else can happen; "Not this time".
struct ApplyCard: View {
    @EnvironmentObject var model: AppModel
    @Binding var applying: Bool
    var body: some View {
        let name = model.config.name
        let s = model.applyState
        VStack(alignment: .leading, spacing: 10) {
            if let s, let a = s.application, a.isOpen {
                Text("Your request to become a member").font(.headline)
                if let line = s.line { Text(line).font(.title3.weight(.semibold)).foregroundStyle(Color.brand) }
                ForEach(a.vouchedBy, id: \.pubkey) { v in
                    HStack(spacing: 8) {
                        Avatar(pubkey: v.pubkey, size: 24)
                        Text("\(v.name.isEmpty ? model.name(v.pubkey) : v.name) vouched for you").font(.subheadline)
                    }
                }
                Text(s.accept == "vouches" ? "Any member can vouch; a steward can also say yes. You stay a guest meanwhile, and your guest access doesn't end while the request is open."
                                           : "A steward will answer. You stay a guest meanwhile, and your guest access doesn't end while the request is open.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if let s, s.application?.state == "declined" {
                Text("Not this time").font(.headline)
                Text("The stewards didn't take your request. You stay a guest\(untilLine(s)). You can ask again later.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { hideKeyboard(); applying = true } label: { Text("Ask again").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
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

    private func untilLine(_ s: ApplyStatus) -> String {
        guard let u = s.until else { return "" }
        return " until " + Date(timeIntervalSince1970: TimeInterval(u)).formatted(.dateTime.weekday(.abbreviated).day().month(.wide))
    }

    private func acceptLine() -> String {
        let base = "Members see the whole town: the Townsquare, its events and groups."
        if (model.applyState?.accept ?? model.membership.accept) == "vouches" {
            let n = model.membership.vouches
            return base + " " + (n == 1 ? "One vouch" : "\(n) vouches") + " or a steward's yes."
        }
        return base + " A steward's yes."
    }
}

/// A guest asks to become a member (board Join-Apply 1): the belfry's question, the saved e-mail
/// (not saved: the save-your-account step first), the charter's agreements ticked one by one (sent
/// as `agreed`: the belfry signs those ticks for the new member), Send.
struct BecomeMemberSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var answer = ""
    @State private var error: ApiError?
    @State private var ticked = Set<String>()
    @State private var mustSave = false

    var body: some View {
        let rules = model.charterRules
        let needSave = model.unsavedGuest || mustSave
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
                    if needSave {
                        Text("Save your e-mail first: the stewards need a way to reach you.").font(.subheadline)
                        SaveAccountCard()
                    } else {
                        Label("Saved", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                }
                if !rules.isEmpty {
                    Section {
                        ForEach(rules) { r in
                            let on = ticked.contains(r.id)
                            TickAgreementRow(rule: r, on: on, titleWeight: .medium, tickFont: .title3) { if on { ticked.remove(r.id) } else { ticked.insert(r.id) } }
                        }
                    } header: { Text("Our charter · \(ticked.count) of \(rules.count) agreed") } footer: { Text("Tick each one you agree to.") }
                }
                if let error, error.code != "guest_not_saved" { Section { Label(error.message, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
                Section {
                    BusyButton {
                        let e = await model.applyAsGuest(answer: answer, agreed: Array(ticked))
                        if e?.code == "guest_not_saved" { mustSave = true; error = e; return }
                        error = e
                        if e == nil { dismiss() }
                    } label: { Text("Send request").frame(maxWidth: .infinity) }
                    .buttonStyle(.brand)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || needSave || ticked.count < rules.count)
                    .accessibilityIdentifier("apply-send")
                } footer: {
                    Text("Your name and answer are shown to members; your e-mail only to stewards.")
                }
            }
            .navigationTitle("Become a member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await model.loadPublicCharter() }
            .onChange(of: model.unsavedGuest) { _, v in if !v { mustSave = false } }
            // a member now (a member link, or accepted): the form is not theirs (SPEC 19.43)
            .onChange(of: model.derive.amGuest) { _, guest in if !guest && !model.guestReading { dismiss() } }
        }
    }
}
