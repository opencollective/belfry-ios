import BelfryCore
import CoreImage
import SwiftUI

// The pieces of the channel's screens (ChannelPlaces.swift; Channel info, the tabbed sheet, is
// gone since 2026-11-17): the Log, the follow settings, Members, To-dos, Files (photos, files,
// drop box links), Settings (admins). And the invite sheet: someone who is here already, the member link, a guest link (1 / 50 people; 1 day /
// 1 week / 1 month), "My own agent".


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

    var body: some View {
        let d = model.derive
        let rows = d.memberRows(id)
        let readingN = d.readingCount(id)
        Section {
            // a row: the face, the name, the role here as secondary text when it isn't the
            // default; a tap pushes the profile, which shows (and lets admins change) the role
            ForEach(rows) { r in
                PersonRow(pubkey: r.pubkey, title: r.pubkey == model.me ? "You" : r.name, detail: detail(r, d)) { open(r.pubkey) }
            }
        } header: {
            Text("\(rows.count) \(rows.count == 1 ? "person" : "people")")
        } footer: {
            // guest mode (SPEC 19.26): people who opened an invite link and have not joined are a number
            if readingN > 0 {
                Text("\(readingN == 1 ? "1 guest is reading" : "\(readingN) guests are reading"): they opened an invite link and have not joined yet.")
            }
        }
    }

    /// "Admin", "Guest · invited by Ana", "Ana's agent"… (nil for a plain member).
    private func detail(_ r: MemberRow, _ d: Derive) -> String? {
        var parts = [String]()
        if let w = d.adminWord(id, r.pubkey) { parts.append(w) }
        if let k = d.kindLabel(r.pubkey) { parts.append(k) } else if let c = r.guest?.chip { parts.append(c.prefix(1).uppercased() + c.dropFirst()) }
        if let by = r.guest?.by { parts.append("invited by " + model.name(by)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct TodosTab: View {
    @EnvironmentObject var model: AppModel
    let id: String
    /// Opens a to-do's own screen (pushed by the screen this list is in).
    let open: (TodoTask) -> Void
    @State private var newTodo = ""

    var body: some View {
        let tasks = model.derive.tasks(id)
        let locked = model.locked(id) || model.guestReading
        if !locked {
        Section {
            HStack {
                TextField("Add a to-do", text: $newTodo, axis: .vertical).lineLimit(1...6).font(.body)
                    .submitLabel(.done)
                    .accessibilityIdentifier("todo-new")
                BusyButton { model.addTodo(newTodo, in: id); newTodo = "" } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(newTodo.jsTrim().isEmpty || Actions.taskOver(newTodo) > 0)
                    .accessibilityLabel("Add the to-do")
            }
        } footer: {
            if let line = Actions.taskLimitLine(newTodo) {
                Text(line).foregroundStyle(Actions.taskOver(newTodo) > 0 ? Color.red : Color.secondary)
            }
        }
        }
        Section("To do") {
            let todo = tasks.filter { !$0.done }
            if todo.isEmpty { Text("Nothing to do.").foregroundStyle(.secondary) }
            ForEach(todo) { t in TodoRow(t: t, group: id) { open(t) } }
        }
        let done = tasks.filter(\.done)
        if !done.isEmpty { Section("Done") { ForEach(done) { t in TodoRow(t: t, group: id) { open(t) } } } }
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
            if !model.locked(id) {
                Button { drop = true } label: { ActionRow(icon: "tray.and.arrow.down", title: "New drop box link", detail: "Anyone with the link can add photos and files here") }
            }
            ForEach(links) { l in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.dropURL(l.token)).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled)
                        Text("\(l.login ? "Signed-in people" : "Anyone") · until \(Date(timeIntervalSince1970: TimeInterval(l.expires)).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if l.author == model.me && !model.locked(id) { BusyButton("End", role: .destructive) { model.endDropLink(l) }.font(.caption).buttonStyle(.borderless) }
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
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var name = ""
    @State private var about = ""
    @State private var inbox = false
    /// The person moved the switch: Save sends it even when the channel already reads the same.
    @State private var inboxTouched = false
    @State private var closed = false
    @State private var prompt = ""
    @State private var loaded = false
    @State private var saved = false
    /// Who reads it (channels: members only / public / closed; SPEC 19.38)
    @State private var access = ChannelAccess.members
    /// A group's "Who can join" (Open / Closed / Private).
    @State private var join = GroupAccess.open
    @State private var askPublic = false
    @State private var vouches = 0
    /// What can be posted: "" = anything, else thread / event / proposal (/ request when it is set so).
    @State private var posts = ""

    var body: some View {
        let g = model.group(id)
        Section("Name") { TextField("Name", text: $name).font(.body) }
        Section("Description") { TextField("What is it about? (Markdown)", text: $about, axis: .vertical).lineLimit(3...8).font(.body) }
        // a private group stays private: only invited people, nothing to choose and no question
        // (one-shape.md "Groups: open, closed, private")
        if g?.isPod == true {
            // a group: the same three choices as the New group form (board groups/settings-closed)
            Section("Who can join") {
                ForEach(GroupAccess.allCases, id: \.self) { a in
                    Button { join = a } label: {
                        HStack(spacing: 12) {
                            Image(systemName: a == .open ? "door.left.hand.open" : a == .closed ? "hand.raised" : "lock").frame(width: 24).foregroundStyle(.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.title).foregroundStyle(.primary)
                                Text(a.line).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if join == a { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.brand).accessibilityLabel("Selected") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("join-" + a.rawValue)
                    .accessibilityAddTraits(join == a ? .isSelected : [])
                }
            }
        } else if g?.type == .channel { whoReads(g) }
        if g?.isPod == true && join == .closed {
            // a closed group's question and how requests are accepted (web ClosedFields)
            Section("Question people answer when they ask") {
                TextField(Actions.defaultPrompt, text: $prompt, axis: .vertical).lineLimit(1...4).font(.body)
            }
            Section {
                Picker("Requests are accepted", selection: Binding(get: { vouches > 0 }, set: { vouches = $0 ? max(vouches, 2) : 0 })) {
                    Text("By its stewards").tag(false)
                    Text("When members vouch").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if vouches > 0 {
                    Stepper(vouches == 1 ? "One vouch" : "\(vouches) vouches", value: $vouches, in: 1...5)
                }
            } header: {
                Text("Requests are accepted")
            } footer: {
                Text(vouches > 0 ? "Once enough of its members vouch (not guests, not agents), they're in. Stewards can still answer." : "A steward accepts or declines each request.")
            }
        }
        if g?.type == .channel {
            Section {
                Picker("Posts", selection: $posts) {
                    Text("Anything").tag("")
                    Text("Threads").tag("thread")
                    Text("Events").tag("event")
                    Text("Proposals").tag("proposal")
                    if posts == "request" { Text("Requests").tag("request") }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings-posts")
            } header: { Text("Posts") } footer: {
                Text(posts.isEmpty ? "People post messages, and anything else." : "Only this kind of post starts something here; people answer in its thread.")
            }
        }
        Section {
            Toggle("E-mails from anyone", isOn: Binding(get: { inbox }, set: { inbox = $0; inboxTouched = true })).tint(Theme.toggle)
            // a copy of every e-mail to an outside address (channels only; saved at once, apart from Save)
            if g?.type == .channel, !model.isDemo { MailForwardRow(channel: id) }
        } footer: {
            Text(inbox ? "Anyone can e-mail \(id)@\(model.config.domain). Mails land here as cards and the channel's admins answer as the channel."
                 : "Only members can e-mail \(id)@\(model.config.domain); their mail shows as their message.")
        }
        // Save (SPEC 19.37): applied here at once and queued; back to the channel, which shows the
        // new name and description. Only a final refusal shows (the mark by the channel's name).
        Section {
            Button {
                guard !saved else { return }
                saved = true
                hideKeyboard()
                let n = name.jsTrim(), a = about.jsTrim()
                if g?.isPod == true {
                    // Open = open + public; Closed = closed + public (its question, who accepts);
                    // Private = closed + private
                    model.editGroupMeta(id, name: n, about: a, closed: join != .open, prompt: join == .closed ? prompt : "",
                                        vouches: join == .closed ? vouches : 0, isPrivate: join == .private)
                } else if let g, g.type == .channel, (access == .closed) != g.closed {
                    // closed or open again (one 9002 with the name and description)
                    model.editGroupMeta(id, name: n, about: a, closed: access == .closed, prompt: g.prompt ?? "")
                } else { model.editChannel(id, name: n, about: a, inbox: nil) }
                if g?.type == .channel { model.setVisibility(id, public: access == .public) }
                if g?.type == .channel { model.setPosts(id, posts.isEmpty ? nil : posts) }
                if Actions.inboxToSend(chosen: inbox, reads: model.derive.isInbox(g), touched: inboxTouched) { model.editChannelInbox(id, inbox) }
                dismiss()
            } label: {
                Text("Save").frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand)
            .controlSize(.large)
            .disabled(name.jsTrim().isEmpty || saved)
            .accessibilityIdentifier("settings-save")
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            // archiving sits under Save as a plain centred link (SPEC 19.30)
            if model.derive.mayArchive(g) {
                ArchiveLink(id: id)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
            }
        }
        .onAppear {
            guard !loaded, let g else { return }
            loaded = true
            name = g.name
            about = g.about
            inbox = model.derive.isInbox(g)
            closed = g.closed
            prompt = g.prompt ?? ""
            vouches = g.vouches
            access = model.derive.channelAccess(g)
            join = g.isPrivate ? .private : g.closed ? .closed : .open
            posts = model.derive.webPage(g)?.posts ?? ""
            if model.launch.screen == "chpublic" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { askPublic = true } }
        }
        .alert("Make \(label(g)) public?", isPresented: $askPublic) {
            Button("Make it public") { access = .public }
            Button("Keep it for members", role: .cancel) {}
        } message: {
            Text("From now on, anyone on the web can read what is posted here, with the names of the people who post. Earlier messages stay for members only.")
        }
    }

    private func label(_ g: Channel?) -> String {
        guard let g else { return model.derive.label(id) }
        return g.label
    }

    /// "Who can read it": three choices (the owner's mock-ups Settings-A / B); Public asks first.
    @ViewBuilder private func whoReads(_ g: Channel?) -> some View {
        Section {
            accessRow(.members, icon: "lock", title: "Members only", line: "Everyone with a pass in this belfry")
            accessRow(.public, icon: "globe", title: "Public", line: "Anyone on the web can read it. Only members write.")
            if model.derive.mayClose(g) {
                accessRow(.closed, icon: "person.badge.plus", title: "Closed", line: "People ask to join. A steward of this \(g?.isPod == true ? "group" : "channel") approves.")
            }
        } header: {
            Text("Who can read it")
        } footer: {
            Text("A change counts from now on. Messages keep the visibility they were posted with.")
        }
    }

    private func accessRow(_ a: ChannelAccess, icon: String, title: String, line: String) -> some View {
        Button {
            guard access != a else { return }
            if a == .public { hideKeyboard(); askPublic = true } else { access = a }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body).frame(width: 24).foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if access == a { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.brand).accessibilityLabel("Selected") }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("access-" + a.rawValue)
        .accessibilityAddTraits(access == a ? .isSelected : [])
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

/// Two buttons side by side under a link (Copy link · Share…): equal widths, the system's
/// bordered style at its large size (at least 44 pt tall). Xavier 2026-11-21: they were short and
/// uneven (the label alone took the bordered capsule's width).
struct LinkButtons: View {
    let url: String
    var copyTitle = "Copy link"
    var subject = ""
    var message = ""
    var body: some View {
        HStack(spacing: 10) {
            CopyRow(text: url, title: copyTitle, wide: true)
                .disabled(url.isEmpty)
            if let u = URL(string: url), !url.isEmpty {
                ShareLink(item: u, subject: Text(subject), message: Text(message)) {
                    Label("Share…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 34)
                }
            } else {
                Button {} label: { Label("Share…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 34) }
                    .disabled(true)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
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
    /// Side by side with another button: as wide as it can be (the pair gets equal widths).
    var wide = false
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
                .frame(maxWidth: wide ? .infinity : nil, minHeight: wide ? 34 : nil)
        }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .accessibilityLabel(copied ? "Copied" : title)
    }
}
