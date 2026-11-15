import BelfryCore
import PhotosUI
import SwiftUI

// The composer: @ picker (marks people who can't read the channel, with Invite / Add as a guest
// above the field), # picker for channel references (SPEC 19.14), photos, the ＋ menu (a
// Discord-style list: Photo, To-do, Pod, Proposal, Announcement), Send that can't fire twice.

struct Composer: View {
    @EnvironmentObject var model: AppModel
    var group: String = ""
    var placeholder = "Message"
    var canAnnounce = false
    var compact = false
    var autoFocus = false
    var threadMode = false
    var topic: String?
    /// Changes when something asks for the box (Reply in a thread's menu).
    var focusTrigger = 0
    /// Where unsent text is kept on this phone (per channel, per thread; web f845d47).
    var draftKey: String?
    let onSend: (String, [Attachment], Bool) -> Void
    @State private var text = ""
    @State private var picked = [(name: String, pubkey: String)]()
    @State private var refs = [(label: String, ref: String)]()
    @State private var photos = [PhotosPickerItem]()
    @State private var attachments = [Attachment]()
    @State private var announce = false
    @State private var sent = 0
    @State private var photoPicker = false
    @State private var create: CreateKind?
    @State private var makeEvent = false
    @State private var recording = false
    @State private var meeting = false
    @State private var notes = [String: String]()
    @FocusState private var focused: Bool
    /// The field's one-line height, and so the ＋ circle's: grows with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var h: CGFloat = 38

    var body: some View {
        let d = model.derive
        let g = model.group(group)
        VStack(spacing: 6) {
            if let q = Mentions.query(beforeCaret: text) {
                let list = people(q)
                if !list.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(list, id: \.pubkey) { p in
                            Button { pick(p.pubkey, p.name) } label: {
                                HStack(spacing: 10) {
                                    Avatar(pubkey: p.pubkey, size: 26)
                                    Text(p.name).font(.subheadline)
                                    if let k = d.kindLabel(p.pubkey) { Text(k).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    if g != nil && !d.inChannel(g, p.pubkey) { Text("not in this channel").font(.caption).foregroundStyle(.secondary) }
                                }
                                .padding(.vertical, 6).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Mention \(p.name)")
                        }
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            } else if !threadMode, let q = ChannelRefs.query(beforeCaret: text) {
                let list = d.channelCandidates(q)
                if !list.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(list, id: \.group.id) { c in
                            Button { pickChannel(c, query: q) } label: {
                                HStack(spacing: 10) {
                                    ChannelGlyph(group: c.group, size: 20)
                                    Text(c.group.name).font(.subheadline)
                                    Spacer()
                                }
                                .padding(.vertical, 6).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Link the channel \(c.group.name)")
                        }
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            ForEach(outsiders(g), id: \.self) { pk in
                OutsiderNote(pubkey: pk, group: group, note: notes[pk]) { notes[pk] = $0 }
            }
            if announce {
                HStack {
                    Label("Announcement: sent to the channel and e-mailed to its followers", systemImage: "megaphone").font(.caption)
                    Spacer()
                    Button { announce = false } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Not an announcement")
                }.foregroundStyle(Color.brand)
            }
            if !attachments.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(attachments, id: \.file) { a in
                        HStack(spacing: 4) {
                            Image(systemName: a.mime.hasPrefix("image/") ? "photo" : "paperclip")
                            Text(a.name).lineLimit(1).font(.caption)
                            Button { attachments.removeAll { $0.file == a.file } } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel("Remove \(a.name)")
                        }
                        .padding(6).background(.thinMaterial, in: Capsule())
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if !compact && !threadMode { addMenu }
                // iMessage's shape: a capsule that grows with the lines, Send inside its trailing edge
                HStack(alignment: .bottom, spacing: 0) {
                    TextField(announce ? "Announcement" : placeholder, text: $text, axis: .vertical)
                        .font(.body)
                        .lineLimit(1...6)
                        .focused($focused)
                        .accessibilityIdentifier("composer-field")
                        .padding(.leading, 14).padding(.trailing, 6)
                        .padding(.vertical, 8)
                        .frame(minHeight: h)
                    sendButton.padding(4)
                }
                .composerField(radius: h / 2)
            }
        }
        .padding(.horizontal, compact ? 0 : 12)
        .padding(.top, compact ? 0 : 6)
        .padding(.bottom, compact ? 0 : 8)
        .composerBackground(compact: compact)
        .sensoryFeedback(.impact(weight: .light), trigger: sent)
        .onChange(of: model.launchEventForm) { _, on in
            if on, !compact, !threadMode { model.launchEventForm = false; makeEvent = true }
        }
        .onChange(of: model.composerPrefill[group]) { _, v in
            if let v, !compact, !threadMode { text = text.isEmpty ? v + " " : text + " " + v; model.composerPrefill[group] = nil }
        }
        .onAppear {
            if let k = draftKey, text.isEmpty, let saved = Drafts.get(k) { text = saved }
            if autoFocus { focused = true }
            if !compact && !threadMode && model.launchEventForm { model.launchEventForm = false; makeEvent = true }
        }
        .onChange(of: photos) { _, items in load(items) }
        .onChange(of: focusTrigger) { _, _ in focused = true }
        .onChange(of: text) { _, t in if let k = draftKey { Drafts.set(k, t) } }
        .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: 6, matching: .images)
        .sheet(item: $create) { k in CreateSheet(kind: k, parent: group) }
        .sheet(isPresented: $makeEvent) { EventFormSheet(editing: nil, channel: group) }
        .sheet(isPresented: $recording) { RecorderSheet(group: group) }
        .sheet(isPresented: $meeting) { MeetingFormSheet(channel: group) }
        .onChange(of: model.launchMeetingForm) { _, on in
            if on, !compact, !threadMode { model.launchMeetingForm = false; meeting = true }
        }
    }

    static let height: CGFloat = 38

    private var canSend: Bool { !(text.jsTrim().isEmpty && attachments.isEmpty) }

    /// Send, inside the field: filled with the tint when there is something to send.
    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(canSend ? Theme.onAccent : Color.secondary)
                .frame(width: h - 8, height: h - 8)
                .background(canSend ? Theme.accent : Color.secondary.opacity(0.18), in: Circle())
                .padding(4).contentShape(Circle()).padding(-4) // a 38 pt target around a 30 pt mark
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .animation(.easeOut(duration: 0.15), value: canSend)
        .accessibilityLabel("Send")
    }

    /// ＋: a native menu with icons, the same height as the field and on its centre line.
    private var addMenu: some View {
        let guest = model.derive.amGuest
        return Menu {
            Section {
                Button { choose(.photo) } label: { Label("Photo", systemImage: "photo.on.rectangle") }
                Button { choose(.create(.todo)) } label: { Label("Todo", systemImage: "checklist") }
            }
            if !guest {
                Section {
                    Button { choose(.event) } label: { Label("Event", systemImage: "calendar") }
                    Button { choose(.meeting) } label: { Label("Meeting", systemImage: "person.2") }
                    Button { choose(.create(.proposal)) } label: { Label("Proposal", systemImage: "doc.text") }
                    Button { choose(.create(.pod)) } label: { Label("Group", systemImage: "hexagon") }
                }
                Section {
                    Button { choose(.audio) } label: { Label("Audio recording", systemImage: "mic") }
                }
            }
            if canAnnounce {
                Section {
                    Button { choose(.announcement) } label: { Label("Announcement", systemImage: "megaphone") }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: h, height: h)
                .glass(in: Circle(), interactive: true)
                .padding(3).contentShape(Circle()).padding(-3) // 44 pt target
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Add a photo, a todo, an event, a proposal…")
        .accessibilityIdentifier("composer-add")
    }

    func choose(_ choice: AddChoice) {
        hideKeyboard()
        switch choice {
        case .photo: photoPicker = true
        case .announcement: announce = true; focused = true
        case .create(let k): create = k
        case .event: makeEvent = true
        case .audio: recording = true
        case .meeting: meeting = true
        }
    }

    func people(_ q: String) -> [(pubkey: String, name: String)] {
        let ql = q.lowercased()
        return Array(model.derive.people.filter { p in ql.isEmpty || p.name.lowercased().split(separator: " ").contains { $0.hasPrefix(ql) } }.prefix(6))
    }

    /// People picked here who can't read this channel (each gets a note with Invite).
    func outsiders(_ g: Channel?) -> [String] {
        guard let g else { return [] }
        var out = [String]()
        for p in picked where text.contains("@" + p.name) && !model.derive.inChannel(g, p.pubkey) && !out.contains(p.pubkey) { out.append(p.pubkey) }
        return out
    }

    func pick(_ pk: String, _ name: String) {
        guard let q = Mentions.query(beforeCaret: text) else { return }
        text = String(text.dropLast(q.count + 1)) + "@" + name + " "
        picked.append((name, pk))
    }

    func pickChannel(_ c: ChannelPick, query q: String) {
        let label = "#" + c.group.name
        text = String(text.dropLast(q.count + 1)) + label + " "
        if !refs.contains(where: { $0.label == label }) { refs.append((label, c.ref)) }
    }

    func send() {
        let typed = text.jsTrim()
        guard !typed.isEmpty || !attachments.isEmpty else { return }
        let t = ChannelRefs.substitute(Mentions.substitute(typed, picked: picked), picked: refs)
        onSend(t, attachments, canAnnounce && announce)
        text = ""
        if let k = draftKey { Drafts.set(k, "") }
        picked = []
        refs = []
        attachments = []
        announce = false
        notes = [:]
        sent += 1
    }

    func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photos = []
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let img = UIImage(data: data)
                let jpeg = img?.jpegData(compressionQuality: 0.85) ?? data
                let name = "photo-\(Int.now).jpg"
                if let a = model.saveAttachment(jpeg, name: name, mime: "image/jpeg", width: img.map { Int($0.size.width * $0.scale) }, height: img.map { Int($0.size.height * $0.scale) }) {
                    attachments.append(a)
                }
            }
        }
    }
}

/// "<name> can't read this channel" with Invite (a member: a direct message with the link; a
/// closed pod I administer: let in first) or Add as a guest (a guest of another channel).
struct OutsiderNote: View {
    @EnvironmentObject var model: AppModel
    let pubkey: String
    let group: String
    let note: String?
    let set: (String) -> Void
    var body: some View {
        let guest = model.derive.isGuest(pubkey)
        HStack(spacing: 8) {
            Image(systemName: "eye.slash").foregroundStyle(.secondary)
            Text(note ?? "\(model.realNameOrKey(pubkey)) can't read this channel.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if note == nil {
                BusyButton(guest ? "Add as a guest" : "Invite") {
                    set(await model.inviteHere(pubkey, to: group))
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

enum CreateKind: String, Identifiable { case todo, pod, proposal; var id: String { rawValue } }
enum AddChoice { case photo, announcement, event, audio, meeting, create(CreateKind) }

/// Unsent text on this phone, per channel and per thread (and per form).
enum Drafts {
    /// Per account (SPEC 19.24): slot "" keeps the earlier prefix.
    static var prefix: String { Keychain.slot.isEmpty ? "belfry-draft:" : "belfry-draft@" + Keychain.slot + ":" }
    static func key(_ k: String) -> String { prefix + k }
    static func get(_ k: String) -> String? {
        let v = UserDefaults.standard.string(forKey: key(k))
        return v?.isEmpty == false ? v : nil
    }
    static func set(_ k: String, _ v: String) {
        if v.isEmpty { UserDefaults.standard.removeObject(forKey: key(k)) } else { UserDefaults.standard.set(v, forKey: key(k)) }
    }
    /// A form's fields (new event, proposal, to-do, channel, thread) as JSON.
    static func getForm(_ k: String) -> [String: String] {
        guard let s = get("form:" + k), let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return o
    }
    static func setForm(_ k: String, _ v: [String: String]) {
        let empty = v.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        set("form:" + k, empty ? "" : (try? JSONSerialization.data(withJSONObject: v)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }
    /// Signing out forgets every draft.
    static func clearAll() {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix(prefix) { UserDefaults.standard.removeObject(forKey: k) }
    }
}

extension View {
    /// The message field: a glass capsule on iOS 26, a bordered one before.
    @ViewBuilder func composerField(radius: CGFloat = Composer.height / 2) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color(uiColor: .separator)))
        }
        #else
        self.background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color(uiColor: .separator)))
        #endif
    }

    /// iOS 26: the composer floats over the feed (the bar's scroll edge effect does the rest);
    /// before: a bar material.
    @ViewBuilder func composerBackground(compact: Bool) -> some View {
        if compact {
            self
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26, *) { self } else { self.background(.bar) }
            #else
            self.background(.bar)
            #endif
        }
    }
}

/// Make a to-do, a pod or a proposal in this channel.
struct CreateSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openChannel) private var openChannel
    let kind: CreateKind
    let parent: String
    /// "Propose as the website": the version's nsite ref and who made it (web 6d267c1).
    var website: (ref: String, by: String)? = nil
    @State private var title = ""
    @State private var about = ""
    @State private var text = ""
    @State private var closed = false
    @State private var prompt = ""
    @State private var status: ProposalStatus = .draft

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .todo:
                    Section { TextField("What needs doing?", text: $title, axis: .vertical).lineLimit(1...4).font(.body) }
                case .pod:
                    Section {
                        TextField("Name", text: $title).font(.body)
                        TextField("What is it for?", text: $about, axis: .vertical).lineLimit(2...5).font(.body)
                    }
                    Section {
                        Picker("Who can join", selection: $closed) {
                            Text("Anyone here").tag(false)
                            Text("By application").tag(true)
                        }
                        if closed { TextField(Actions.defaultPrompt, text: $prompt, axis: .vertical).lineLimit(1...4).font(.body) }
                    } footer: { Text(closed ? "People answer the question; the group's members let them in." : "Anyone in the channel can join.") }
                case .proposal:
                    Section {
                        TextField("Title", text: $title).font(.body)
                        TextField("In one line", text: $about).font(.body)
                        TextField("The proposal (Markdown)", text: $text, axis: .vertical).lineLimit(4...12).font(.body)
                    }
                    Section {
                        Picker("Start as", selection: $status) {
                            Text("Draft").tag(ProposalStatus.draft)
                            Text("Open for feedback").tag(ProposalStatus.feedback)
                        }
                    }
                }
            }
            .onAppear {
                if let w = website, title.isEmpty {
                    title = "A new version of the website"
                    about = "By \(w.by)"
                    text = "Preview it: \(websitePreviewLink(w.ref, domain: model.config.domain) ?? w.ref)\n\nWhat changes:\n- "
                    status = .feedback
                    return
                }
                let f = Drafts.getForm(formKey)
                if title.isEmpty { title = f["title"] ?? ""; about = f["about"] ?? ""; text = f["text"] ?? ""; prompt = f["prompt"] ?? "" }
            }
            .onChange(of: [title, about, text, prompt]) { _, v in if website == nil { Drafts.setForm(formKey, ["title": v[0], "about": v[1], "text": v[2], "prompt": v[3]]) } }
            .navigationTitle(kind == .todo ? "New todo" : kind == .pod ? "New group" : "New proposal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton(kind == .todo ? "Add" : "Create") { make() }.disabled(title.jsTrim().isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .solidSheet()
    }

    private var formKey: String { "\(kind.rawValue):\(parent)" }

    func make() {
        let t = title.jsTrim()
        Drafts.setForm(formKey, [:])
        switch kind {
        case .todo:
            model.addTodo(t, in: parent)
            dismiss()
        case .pod:
            let id = model.createPod(name: t, about: about.jsTrim(), parent: parent, closed: closed, prompt: prompt)
            dismiss()
            openChannel(id, nil)
        case .proposal:
            let id = model.createProposal(NewProposal(title: t, summary: about.jsTrim(), text: text.jsTrim(), status: status, website: website?.ref), parent: parent)
            dismiss()
            openChannel(id, nil)
        }
    }
}
