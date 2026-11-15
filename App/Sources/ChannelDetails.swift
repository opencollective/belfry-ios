import BelfryCore
import CoreImage
import SwiftUI

// Channel info (the web's full pull-down view), in tabs: About (description, e-mail address,
// follow bell, who was active, events, pods, proposals), Members (guests, agents, admins,
// labels), To-dos, Files (photos, files, drop box links), Settings (admins). And the invite
// sheet: someone who is here already, the member link, a guest link (1 / 50 people; 1 day /
// 1 week / 1 month), "My own agent".

enum InfoTab: String, CaseIterable { case about = "About", members = "Members", todos = "Todos", files = "Files", log = "Log", settings = "Settings" }

struct ChannelDetails: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    /// "Go there" from the Log: a message or a thread in the channel.
    var go: (LogGo) -> Void = { _ in }
    @State var tab: InfoTab = .about
    @State private var invite = false
    @State private var profile: ProfileKey?

    var body: some View {
        let _ = model.version
        let g = model.group(id)
        let admin = model.derive.canAdmin(g)
        NavigationStack {
            List {
                Section {
                    Picker("Tab", selection: $tab) {
                        ForEach(InfoTab.allCases.filter { $0 != .settings }, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                switch tab {
                case .about: AboutTab(id: id, invite: { invite = true })
                case .members: MembersTab(id: id) { profile = ProfileKey(pubkey: $0) }
                case .todos: TodosTab(id: id)
                case .files: FilesTab(id: id)
                case .log: LogTab(id: id) { g in
                    switch g {
                    case .todos: tab = .todos
                    case .members: tab = .members
                    default: dismiss(); go(g)
                    }
                }
                case .settings: SettingsTab(id: id)
                }
            }
            .navigationTitle(g.map { $0.isPod ? $0.name : "#" + $0.name } ?? id)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if admin {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { tab = tab == .settings ? .about : .settings } label: { Image(systemName: tab == .settings ? "gearshape.fill" : "gearshape") }
                            .accessibilityLabel("Channel settings")
                    }
                }
            }
            .sheet(isPresented: $invite) { InviteSheet(id: id) }
            .navigationDestination(item: $profile) { ProfileView(pubkey: $0.pubkey, pushed: true) }
            .onAppear {
                switch model.launch.screen {
                case "members": tab = .members
                case "todos": tab = .todos
                case "files": tab = .files
                case "log": tab = .log
                default: break
                }
            }
            .task {
                await model.revalidateConfig()
                await model.askWhois(Array(g?.members ?? []).filter { model.derive.guestJoinKeys.contains($0) })
            }
        }
        .presentationDetents([.large])
    }
}

/// Everything that happened in the channel, newest first, a section per day (SPEC 19.23 Log).
struct LogTab: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let go: (LogGo) -> Void
    @State private var open: String?

    var body: some View {
        let d = model.derive
        let items = d.channelLog(id)
        let days = Dictionary(grouping: items) { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.ev.createdAt))) }
        if items.isEmpty { Section { Text("Nothing here yet.").foregroundStyle(.secondary) } }
        ForEach(days.keys.sorted(by: >), id: \.self) { day in
            Section(Format.day(Int(day.timeIntervalSince1970))) {
                ForEach(days[day] ?? []) { it in
                    Button { withAnimation(.snappy) { open = open == it.id ? nil : it.id } } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text(it.icon).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                (Text(d.logWho(id, it.ev.pubkey)).fontWeight(.semibold) + Text(" " + it.text)).font(.subheadline)
                                if let detail = it.detail {
                                    Text(verbatim: detail).font(.footnote).foregroundStyle(.secondary).lineLimit(open == it.id ? nil : 1)
                                }
                                if open == it.id {
                                    Text(Date(timeIntervalSince1970: TimeInterval(it.ev.createdAt)).formatted(date: .complete, time: .standard))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let g = it.go {
                                        Button("Go there") { go(g) }.font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                                    }
                                }
                            }
                            Spacer(minLength: 4)
                            Text(Format.time(it.ev.createdAt)).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct AboutTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let id: String
    let invite: () -> Void

    var body: some View {
        let d = model.derive
        let g = model.group(id)
        let active = d.recentlyActive(id)
        Section {
            if let p = g?.parent, let parent = model.group(p) {
                Text("\(g?.isProposal == true ? "Proposal" : "Pod") in \(parent.isPod ? parent.name : "#" + parent.name)").font(.footnote).foregroundStyle(.secondary)
            }
            if let about = g?.about, !about.isEmpty { MarkdownText(text: about) } else { Text("No description yet.").foregroundStyle(.secondary) }
            if d.isInbox(g) {
                Label("Anyone can e-mail \(d.mailAddress(id)): mails land here as cards.", systemImage: "tray").font(.footnote)
            } else {
                Label("Members can e-mail \(d.mailAddress(id)): their mail shows as their message.", systemImage: "envelope").font(.footnote)
            }
        }
        if !d.amGuest { FollowBell(id: id) }
        Section {
            Button(action: invite) { ActionRow(icon: "person.badge.plus", title: "Invite people") }
            if let g, !g.members.contains(model.me), !g.admins.contains(model.me), !g.isPod {
                ActionButtonRow(icon: "person.crop.circle.badge.plus", title: "Join") { model.join(id) }
            }
            if let g, g.isPod, g.members.contains(model.me) {
                ActionButtonRow(icon: "rectangle.portrait.and.arrow.right", title: "Leave the group", destructive: true) { model.leave(id) }
            }
        }
        Section(active.isEmpty ? "Nobody active this month yet" : "Active in the last 30 days") {
            ForEach(active, id: \.pubkey) { a in
                HStack {
                    Avatar(pubkey: a.pubkey, size: 28)
                    Text(model.name(a.pubkey))
                    Spacer()
                    Text(Format.ago(a.at)).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        let events = d.upcoming(id, now: .now)
        if !events.isEmpty {
            Section("Events") { ForEach(events) { e in Button { model.openEvent = e.coord } label: { EventRow(e: e) }.buttonStyle(.plain) } }
        }
        let pods = d.pods(id)
        if !pods.isEmpty {
            Section("Groups") {
                ForEach(pods) { p in
                    Button { openChannel(p.id, nil) } label: { HStack { ChannelGlyph(group: p, size: 20); Text(p.name) } }.buttonStyle(.plain)
                }
            }
        }
        let props = d.proposalsIn(id)
        if !props.isEmpty {
            Section("Proposals") {
                ForEach(props) { p in
                    Button { openChannel(p.groupId, nil) } label: { ActionRow(icon: "doc.text", title: p.title, detail: p.status.label) }.buttonStyle(.plain)
                }
            }
        }
    }
}

/// E-mails of this channel's announcements: off / as they happen / monthly.
struct FollowBell: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var state: String?
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section {
            Picker(selection: Binding(get: { state ?? "stop" }, set: { set($0) })) {
                Text("Off").tag("stop")
                Text("As they happen").tag("asap")
                Text("Once a month").tag("monthly")
            } label: {
                HStack { Label("E-mail me its announcements", systemImage: state == nil ? "bell" : "bell.fill"); if busy { ProgressView().controlSize(.small) } }
            }
            .disabled(busy || !loaded)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if model.pushState == .on { PushLevelPicker(id: id) }
        }
        .task {
            state = await model.follow(id)
            loaded = true
        }
    }

    func set(_ choice: String) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            switch await model.setFollow(id, choice) {
            case .success(let f): state = f
            case .failure(let e): error = e.message
            }
            busy = false
        }
    }
}

struct MembersTab: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let open: (String) -> Void
    @State private var labeling: String?

    var body: some View {
        let d = model.derive
        let rows = d.memberRows(id)
        let admin = d.canAdmin(id)
        let readingN = d.readingCount(id)
        Section {
            ForEach(rows) { r in
                Button { open(r.pubkey) } label: {
                    HStack(spacing: 10) {
                        Avatar(pubkey: r.pubkey, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(r.pubkey == model.me ? "You" : r.name).font(.subheadline.weight(.semibold))
                                if r.isAdmin { Chip(text: "admin") }
                                if let role = model.roles.label(of: r.pubkey), role.lowercased() != "admin" { Chip(text: role) }
                                if let k = d.kindLabel(r.pubkey) { Chip(text: k.lowercased(), tint: .brand) }
                                else if let c = r.guest?.chip { Chip(text: c, tint: .brand) }
                            }
                            let sub = [r.guest?.by.map { "invited by " + model.name($0) }, r.labels.isEmpty ? nil : r.labels.joined(separator: " · "),
                                       r.place.map { People.placeLabel($0) }].compactMap { $0 }
                            if !sub.isEmpty { Text(sub.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        if admin {
                            Button { labeling = r.pubkey } label: { Image(systemName: "tag") }.buttonStyle(.borderless).accessibilityLabel("Labels")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("\(rows.count) \(rows.count == 1 ? "person" : "people")")
        } footer: {
            // guest mode (SPEC 19.26): people who opened an invite link and have not joined are a number
            if readingN > 0 {
                Text("\(readingN == 1 ? "1 guest is reading" : "\(readingN) guests are reading"): they opened an invite link and have not joined yet.")
            }
        }
        .sheet(item: Binding(get: { labeling.map { ProfileKey(pubkey: $0) } }, set: { labeling = $0?.pubkey })) { k in
            LabelsSheet(id: id, pubkey: k.pubkey)
        }
        .task { await model.loadRoles() }
    }
}

/// A member's labels in a channel (organiser, speaker…), set by its admins.
struct LabelsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    let pubkey: String
    @State private var labels = [String]()
    @State private var custom = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(Set(Actions.suggestedLabels + labels)).sorted(), id: \.self) { l in
                        Button {
                            if labels.contains(l) { labels.removeAll { $0 == l } } else { labels.append(l) }
                        } label: {
                            HStack { Text(l); Spacer(); if labels.contains(l) { Image(systemName: "checkmark") } }
                        }
                    }
                    HStack {
                        TextField("Another label", text: $custom).font(.body)
                        Button("Add") { let c = custom.jsTrim().lowercased(); if !c.isEmpty && !labels.contains(c) { labels.append(c) }; custom = "" }
                    }
                }
            }
            .navigationTitle(model.name(pubkey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { BusyButton("Save") { model.setMemberLabels(pubkey, in: id, labels: labels); dismiss() } }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                labels = model.derive.memberLabels(id)[pubkey] ?? []
            }
        }
        .presentationDetents([.medium, .large])
        .solidSheet()
    }
}

struct TodosTab: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var newTodo = ""
    @State private var open: String?

    var body: some View {
        let tasks = model.derive.tasks(id)
        Section {
            HStack {
                TextField("Add a todo", text: $newTodo).font(.body)
                BusyButton { model.addTodo(newTodo, in: id); newTodo = "" } label: { Image(systemName: "plus.circle.fill") }
                    .disabled(newTodo.jsTrim().isEmpty)
            }
        }
        Section("To do") {
            let todo = tasks.filter { !$0.done }
            if todo.isEmpty { Text("Nothing to do.").foregroundStyle(.secondary) }
            ForEach(todo) { t in todoRow(t) }
        }
        let done = tasks.filter(\.done)
        if !done.isEmpty { Section("Done") { ForEach(done) { t in todoRow(t) } } }
    }

    @ViewBuilder func todoRow(_ t: TodoTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TodoRow(t: t, group: id)
            HStack(spacing: 14) {
                Button(open == t.id ? "Hide comments" : t.comments.isEmpty ? "Comment" : "\(t.comments.count) comments") {
                    withAnimation { open = open == t.id ? nil : t.id }
                }
                if t.author == model.me {
                    BusyButton("Delete", role: .destructive) { model.todo(t, in: id, "delete") }
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            if open == t.id { TodoComments(t: t, group: id) }
        }
    }
}

struct TodoComments: View {
    @EnvironmentObject var model: AppModel
    let t: TodoTask
    let group: String
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(t.comments.enumerated()), id: \.offset) { _, c in
                HStack(alignment: .top, spacing: 6) {
                    Avatar(pubkey: c.author, size: 20)
                    VStack(alignment: .leading) {
                        Text(model.name(c.author)).font(.caption.weight(.semibold))
                        Text(c.text).font(.caption)
                    }
                }
            }
            HStack {
                TextField("Comment", text: $text).font(.body)
                BusyButton("Send") { model.commentTodo(t, in: group, text: text.jsTrim()); text = "" }.disabled(text.jsTrim().isEmpty)
            }
        }
        .padding(.leading, 34)
    }
}

struct FilesTab: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var drop = false

    var body: some View {
        let d = model.derive
        let files = d.files(id)
        let photos = files.filter(\.isImage)
        let others = files.filter { !$0.isImage }
        let links = d.dropLinks(id, now: .now)
        Section("Drop box links") {
            Button { drop = true } label: { ActionRow(icon: "tray.and.arrow.down", title: "New drop box link", detail: "Anyone with the link can add photos and files here") }
            ForEach(links) { l in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.dropURL(l.token)).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled)
                        Text("\(l.login ? "Signed-in people" : "Anyone") · until \(Date(timeIntervalSince1970: TimeInterval(l.expires)).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if l.author == model.me { BusyButton("End", role: .destructive) { model.endDropLink(l) }.font(.caption).buttonStyle(.borderless) }
                }
            }
        }
        Section("Photos") {
            if photos.isEmpty { Text("No photos yet.").foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(photos, id: \.url) { MediaView(media: $0).frame(width: 96, height: 96).clipped() }
            }
        }
        if !others.isEmpty {
            Section("Files") { ForEach(others, id: \.url) { MediaView(media: $0) } }
        }
        Section {}.sheet(isPresented: $drop) { DropLinkSheet(id: id) }
    }
}

/// A new drop box link: how long (1 day / 1 week / 1 month), who (anyone / signed in), then its QR.
struct DropLinkSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var days = 7
    @State private var login = false
    @State private var token: String?

    var body: some View {
        NavigationStack {
            Form {
                if let token {
                    let url = model.derive.dropURL(token)
                    Section {
                        LinkBlock(url: url, title: "Drop box", message: "Add files to the drop box")
                    }
                } else {
                    Section("Works for") {
                        Picker("Works for", selection: $days) { Text("1 day").tag(1); Text("1 week").tag(7); Text("1 month").tag(30) }.pickerStyle(.segmented)
                    }
                    Section("Who can add files") {
                        Picker("Who", selection: $login) { Text("Anyone with the link").tag(false); Text("Signed-in people").tag(true) }.pickerStyle(.inline).labelsHidden()
                    }
                    Section { BusyButton("Make the link") { token = model.createDropLink(id, days: days, login: login) } }
                }
            }
            .navigationTitle("Drop box link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

struct SettingsTab: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var name = ""
    @State private var about = ""
    @State private var inbox = false
    @State private var closed = false
    @State private var prompt = ""
    @State private var loaded = false
    @State private var saved = false

    var body: some View {
        let g = model.group(id)
        Section("Name") { TextField("Name", text: $name).font(.body) }
        Section("Description") { TextField("What is it about? (Markdown)", text: $about, axis: .vertical).lineLimit(3...8).font(.body) }
        if g?.isPod == true {
            Section {
                Picker("Who can join", selection: $closed) { Text("Anyone here").tag(false); Text("By application").tag(true) }
                if closed { TextField(Actions.defaultPrompt, text: $prompt, axis: .vertical).lineLimit(1...4).font(.body) }
            }
        }
        Section {
            Toggle("E-mails from anyone", isOn: $inbox).tint(Theme.toggle)
        } footer: {
            Text(inbox ? "Anyone can e-mail \(id)@\(model.config.domain). Mails land here as cards and the channel's admins answer as the channel."
                 : "Only members can e-mail \(id)@\(model.config.domain); their mail shows as their message.")
        }
        Section {
            BusyButton(saved ? "Saved" : "Save") {
                let n = name.jsTrim(), a = about.jsTrim()
                if g?.isPod == true { model.editPod(id, name: n, about: a, closed: closed, prompt: prompt) }
                else { model.editChannel(id, name: n, about: a, inbox: nil) }
                if inbox != model.derive.isInbox(g) { model.editChannelInbox(id, inbox) }
                saved = true
            }
            .disabled(name.jsTrim().isEmpty)
        }
        .onAppear {
            guard !loaded, let g else { return }
            loaded = true
            name = g.name
            about = g.about
            inbox = model.derive.isInbox(g)
            closed = g.closed
            prompt = g.prompt ?? ""
        }
    }
}

/// A link as rows of a list section: its QR code with the address under it, "Copy link"
/// (a checkmark and a tap of the haptic engine) and "Share…" (the system share sheet). Each is its
/// own row, so one tap never reaches the other.
struct LinkBlock: View {
    let url: String
    let title: String
    let message: String
    var body: some View {
        QRRow(url: url)
        CopyRow(text: url, title: "Copy link")
        if let u = URL(string: url) {
            ShareLink(item: u, subject: Text(title), message: Text(message)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// A QR code on white (scannable in dark mode too) and its text.
struct QRRow: View {
    let url: String
    var body: some View {
        VStack(spacing: 10) {
            if let img = QR.image(url) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 184, height: 184)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("QR code of the link")
            }
            Text(url).font(.footnote.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled).multilineTextAlignment(.center).lineLimit(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

/// "Copy …" as a list row: copies at once, turns into a checkmark for two seconds.
struct CopyRow: View {
    let text: String
    var title = "Copy"
    @State private var copied = false
    var body: some View {
        Button {
            guard !copied else { return }
            UIPasteboard.general.string = text
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .accessibilityLabel(copied ? "Copied" : title)
    }
}
