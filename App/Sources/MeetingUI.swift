import BelfryCore
import SwiftUI

// A new meeting in a few taps (web ui/Meeting.tsx): the composer's ＋ → Meeting. Topic, people
// (a grid of faces: the channel's most active members first; tap to pick, + to add someone by
// name or e-mail), when (the next full hour), how long, where (the last place by default; a video
// link). Members only. And the meeting's people on its page: who is there, check-in, add, hand over.

struct MeetingFormSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: String
    @State private var topic = ""
    @State private var people = [String]()
    @State private var named = [NamedPerson]()
    @State private var start = MeetingFormSheet.nextHour()
    @State private var minutes = 60
    @State private var place = ""
    @State private var online = ""
    @State private var error: String?
    @State private var adding = false
    @State private var loaded = false

    static func nextHour() -> Date {
        let c = Calendar.current
        let d = c.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return c.date(bySettingHour: c.component(.hour, from: d), minute: 0, second: 0, of: d) ?? d
    }

    var body: some View {
        let d = model.derive
        let faces = faceList(d)
        NavigationStack {
            Form {
                Section("Topic") {
                    TextField("e.g. Plan the garden day", text: $topic).font(.body)
                        .onChange(of: topic) { _, t in if t.count > 200 { topic = String(t.prefix(200)) } }
                }
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 8)], spacing: 12) {
                        ForEach(faces, id: \.self) { k in face(k, name: model.name(k), on: people.contains(k)) { toggle(k) } }
                        ForEach(Array(named.enumerated()), id: \.offset) { i, n in
                            face(nil, name: n.name, on: true) { named.remove(at: i) }
                        }
                        Button { hideKeyboard(); adding = true } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 48, height: 48)
                                    .background(Color.secondary.opacity(0.12), in: Circle())
                                Text("Add").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add someone")
                    }
                    .padding(.vertical, 4)
                } header: { Text("People") } footer: { Text(peopleHint) }
                Section("When") {
                    DatePicker("Starts", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    Picker("How long", selection: $minutes) {
                        ForEach(Meetings.lengths, id: \.self) { Text(Meetings.lengthLabel($0)).tag($0) }
                    }
                }
                Section {
                    TextField("A room, an address", text: $place).font(.body)
                    ForEach(d.meetingPlaces().filter { $0 != place }, id: \.self) { p in
                        Button { place = p } label: { Label(p, systemImage: "mappin") }
                    }
                    Toggle(isOn: Binding(get: { !online.isEmpty }, set: { on in online = on ? Actions.jitsiLink(topic.isEmpty ? "meeting" : topic) : "" })) {
                        Label(online.isEmpty ? "Add a video link" : "Video link added", systemImage: "video")
                    }
                    .tint(Theme.toggle)
                } header: { Text("Where") }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .navigationTitle("New meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Create") { await create() }.disabled(topic.jsTrim().isEmpty)
                }
            }
            .sheet(isPresented: $adding) {
                AddPersonSheet(channel: channel, exclude: people) { pick in
                    switch pick {
                    case .member(let k): if !people.contains(k) { people.append(k) }
                    case .named(let n): named.append(n)
                    }
                }
            }
            .onAppear(perform: load)
            .onChange(of: [topic, place]) { _, v in Drafts.setForm(formKey, ["topic": v[0], "place": v[1]]) }
        }
    }

    private var formKey: String { "meeting:" + channel }

    private var peopleHint: String {
        var s = "Members only. "
        if people.isEmpty {
            s += "The people you invite see it in their upcoming events and get its chat."
        } else if people.count == 1 {
            s += model.name(people[0]) + " sees it in their upcoming events and gets its chat."
        } else {
            s += "\(people.count) people see it in their upcoming events and get its chat."
        }
        if !named.isEmpty { s += " Someone added by name gets an account; without an e-mail, it stays yours to hand over." }
        return s
    }

    private func faceList(_ d: Derive) -> [String] {
        var out = people
        for k in d.findPeople(channel, "", limit: 12) where !out.contains(k) { out.append(k) }
        return out
    }

    private func toggle(_ k: String) {
        if let i = people.firstIndex(of: k) { people.remove(at: i) } else { people.append(k) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func face(_ pk: String?, name: String, on: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    if let pk {
                        Avatar(pubkey: pk, size: 48)
                    } else {
                        Text(String(name.prefix(1)).uppercased()).font(.title3.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 48, height: 48).background(Color.gray, in: Circle())
                    }
                    if on {
                        Image(systemName: "checkmark.circle.fill").font(.body).symbolRenderingMode(.palette).foregroundStyle(Theme.onAccent, Theme.accent)
                            .background(Circle().fill(Color(uiColor: .systemBackground)))
                    }
                }
                .opacity(on ? 1 : 0.55)
                Text(name).font(.caption).lineLimit(1).foregroundStyle(on ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let f = Drafts.getForm(formKey)
        topic = f["topic"] ?? ""
        place = f["place"] ?? model.derive.lastMeetingPlace()
        if model.launch.screen == "meetingform" {
            topic = "Plan the garden day"
            people = Array(model.derive.findPeople(channel, "", limit: 2))
        }
    }

    private func create() async {
        error = nil
        var m = MeetingForm(topic: topic, start: Int(start.timeIntervalSince1970))
        m.people = people
        m.minutes = minutes
        m.place = place
        m.online = online
        m.tz = TimeZone.current.identifier
        let (d, x) = await model.createMeeting(m, named: named, channel: channel)
        Drafts.setForm(formKey, [:])
        model.composerPrefill[channel] = EventLinks.url(domain: model.config.domain, link: d)
        if let x { error = x; return }
        dismiss()
    }
}

enum PersonPick { case member(String), named(NamedPerson) }

/// "+": a name or an e-mail; the people here who match; then the other of the two (optional).
struct AddPersonSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: String
    var exclude: [String] = []
    let pick: (PersonPick) -> Void
    @State private var who = ""
    @State private var more = ""
    @State private var second = false

    var body: some View {
        let isEmail = Meetings.isEmail(who.jsTrim())
        let matches = who.jsTrim().isEmpty || isEmail ? [] : model.derive.findPeople(channel, who, limit: 6).filter { !exclude.contains($0) }
        NavigationStack {
            Form {
                Section {
                    TextField("Name or e-mail", text: $who).font(.body).textInputAutocapitalization(.words).autocorrectionDisabled()
                        .disabled(second)
                }
                if !second && !matches.isEmpty {
                    Section("Already here") {
                        ForEach(matches, id: \.self) { k in
                            Button { pick(.member(k)); dismiss() } label: {
                                HStack(spacing: 10) { Avatar(pubkey: k, size: 28); Text(model.name(k)).foregroundStyle(.primary) }
                            }
                        }
                    }
                }
                if second {
                    Section {
                        TextField(isEmail ? "Name (optional)" : "E-mail (optional)", text: $more).font(.body)
                            .keyboardType(isEmail ? .default : .emailAddress)
                            .textInputAutocapitalization(isEmail ? .words : .never)
                    } footer: {
                        Text(isEmail ? "Adding \(who.jsTrim()). Their name?" : "Adding \(who.jsTrim()), who isn't here yet: an account is made for them. Their e-mail?")
                    }
                }
            }
            .navigationTitle("Add someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if second {
                        Button("Add") { pick(.named(NamedPerson.from(who, more))); dismiss() }
                            .disabled(!isEmail && !more.jsTrim().isEmpty && !Meetings.isEmail(more.jsTrim()))
                    } else {
                        Button("Next") { second = true }.disabled(who.jsTrim().isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .solidSheet()
    }
}

/// On a meeting's page: "People · N · M there", each with their state; hosts check people in,
/// add someone, hand over an account they hold.
struct MeetingPeopleSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.showProfile) private var showProfile
    let e: CalEvent
    @State private var adding = false
    @State private var handing: String?
    @State private var error: String?
    @State private var removing: String?

    var body: some View {
        let d = model.derive
        let host = d.isHost(e)
        let people = d.meetingPeople(e)
        // check-in opens at the start; before it the maker (or a belfry admin) can take someone off
        let started = Meetings.checkInOpen(e)
        let mayRemove = d.mayRemoveFromMeeting(e)
        Section {
            ForEach(people) { p in
                HStack(spacing: 10) {
                    Avatar(pubkey: p.pubkey, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name(p.pubkey))
                        // the status has its own mark, never colour alone
                        HStack(spacing: 4) {
                            Image(systemName: p.status.symbol).font(.caption2.weight(.semibold))
                            Text(p.heldByMe ? p.state + " · account held by you" : p.state)
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if host, started {
                        if p.there {
                            BusyButton { model.checkIn(e, p.pubkey, on: false) } label: { Label("Checked in", systemImage: "checkmark") }
                                .buttonStyle(.bordered).tint(.green)
                        } else {
                            BusyButton("Check in") { model.checkIn(e, p.pubkey, on: true) }.buttonStyle(.bordered)
                        }
                    } else if mayRemove, p.pubkey != e.creator {
                        Button { removing = p.pubkey } label: {
                            Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(width: 32, height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(model.name(p.pubkey))")
                        .accessibilityIdentifier("meeting-remove")
                    }
                }
                .controlSize(.small)
                .swipeActions {
                    if p.heldByMe { Button("Hand over") { handing = p.pubkey }.tint(.blue) }
                }
                .contextMenu {
                    if p.heldByMe { Button { handing = p.pubkey } label: { Label("Hand over the account", systemImage: "person.crop.circle.badge.checkmark") } }
                    Button { OpenProfile(env: showProfile, model: model)(p.pubkey) } label: { Label("Profile", systemImage: "person") }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.footnote) }
        } header: { Text(d.meetingPeopleLine(e)) }
        .alert("Remove \(removing.map(model.name) ?? "") from this meeting?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let k = removing { model.removeFromMeeting(e, k) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("They leave its chat and are no longer invited.") }
        // "add one" is an icon top right, never a row (Xavier, 2026-11-22)
        .toolbar {
            if host {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { hideKeyboard(); adding = true } label: { Image(systemName: "person.badge.plus") }
                        .accessibilityLabel("Add someone")
                        .accessibilityIdentifier("meeting-add-person")
                }
            }
        }
        .sheet(isPresented: $adding) {
            AddPersonSheet(channel: e.originChannel ?? e.groupId, exclude: people.map(\.pubkey)) { pick in
                switch pick {
                case .member(let k): model.inviteToMeeting(e, [k])
                case .named(let n): Task { error = await model.addByName(e, n) }
                }
            }
        }
        .sheet(item: Binding(get: { handing.map { ProfileKey(pubkey: $0) } }, set: { handing = $0?.pubkey })) { k in
            HandOverSheet(e: e, pubkey: k.pubkey)
        }
    }
}

/// Give a name-only account I made to its person: their e-mail goes on it.
struct HandOverSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let e: CalEvent
    let pubkey: String
    @State private var email = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Their e-mail", text: $email).font(.body).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: { Text("\(model.name(pubkey)) signs in with this address from then on; the account is no longer yours.") }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .navigationTitle("Hand over")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Hand over") {
                        if let x = await model.handOver(e, pubkey: pubkey, email: email) { error = x } else { dismiss() }
                    }
                    .disabled(!Meetings.isEmail(email.jsTrim()))
                }
            }
        }
        .presentationDetents([.medium])
        .solidSheet()
    }
}
