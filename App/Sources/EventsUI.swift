import BelfryCore
import PhotosUI
import SwiftUI

// Belfry events (SPEC 19.18) and the older sessions (19.8): pieces of the event screen (the
// one line, RSVP, tickets, applications, decide), the event form (make / edit, cover, all day, where, online + Jitsi, who sees it, who can
// come, the URL checked as typed), tickets, co-host link, All events.

// The event's screen is EventScreen.swift (SPEC 19.29); it replaced the event page sheet.

/// The event's one line: cancelled / changed · still going? / people asking / my state.
struct EventLine: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let state: MyState
    let people: EventPeople
    let host: Bool
    var body: some View {
        let d = model.derive
        if e.status == .cancelled {
            Label("Cancelled" + (e.statusReason.map { ": " + $0 } ?? ""), systemImage: "xmark.octagon").foregroundStyle(.red)
        } else if d.stillGoing(e) {
            HStack {
                Text("Changed · still going?").font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
                BusyButton("Yes") { model.rsvp(e, .accepted) }.buttonStyle(.brand)
                BusyButton("No") { model.rsvp(e, .declined) }.buttonStyle(.bordered)
            }
            .controlSize(.small)
        } else if host && !people.applications.isEmpty {
            Text("\(people.applications.count) \(people.applications.count == 1 ? "person asks" : "people ask") for a place").font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
        } else if host {
            Text("You're hosting").font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
        } else if let l = state.line {
            Text(l).font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
        }
    }
}

struct RsvpButtons: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    var body: some View {
        let mine = model.derive.myRsvp(e)
        HStack {
            ForEach(Rsvp.allCases, id: \.self) { r in
                if mine == r {
                    BusyButton(r.label) { model.rsvp(e, r) }.buttonStyle(.brand)
                } else {
                    BusyButton(r.label) { model.rsvp(e, r) }.buttonStyle(.bordered)
                }
            }
        }
        .controlSize(.small)
    }
}

struct TicketRow: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let t: Ticket
    let people: EventPeople
    let held: Bool
    let apply: () -> Void
    @State private var error: String?
    var body: some View {
        let left = people.placesLeft(t)
        let guestBlocked = t.members && model.derive.amGuest
        // a priced ticket is asked for, never taken (board events/get-tickets)
        let price = t.price(now: .now)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.subheadline.weight(.semibold))
                    let bits = [t.summary.isEmpty ? nil : t.summary, price.priced ? price.line : (t.closed || t.implicit ? nil : "Free"),
                                left.map { $0 == 0 ? "Full" : "\($0) left" }, t.members ? "Members only" : nil,
                                t.closed && !price.priced ? "By application" : nil].compactMap { $0 }
                    if !bits.isEmpty { Text(bits.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    if price.priced, price.onSale, let until = price.until {
                        Text("This price until " + Date(timeIntervalSince1970: TimeInterval(until)).formatted(.dateTime.day().month(.abbreviated)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if held {
                    Chip(text: "Yours", tint: .green)
                } else if guestBlocked {
                    Text("Members only").font(.caption).foregroundStyle(.secondary)
                } else if price.priced && (left ?? 1) > 0 {
                    Button("Ask", action: apply).buttonStyle(.bordered).controlSize(.small).disabled(!price.onSale)
                        .accessibilityLabel(price.onSale ? "Ask for \(t.title)" : "\(t.title) is not on sale now")
                } else if t.closed || (left ?? 1) <= 0 {
                    Button((left ?? 1) <= 0 ? "Waitlist" : "Apply", action: apply).buttonStyle(.bordered).controlSize(.small)
                } else {
                    BusyButton("Take it") { error = await model.takeTicket(e, t) }.buttonStyle(.brand).controlSize(.small)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

/// An application (or a place on the waitlist), with the ticket's question.
struct ApplySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let e: CalEvent
    let t: Ticket
    let full: Bool
    @State private var answer = ""
    @State private var error: String?
    /// A priced ticket: asked for, paid to the hosts, theirs once the hosts confirm.
    private var price: TicketPrice { t.price(now: .now) }
    private var paying: Bool { price.priced && !full }
    var body: some View {
        NavigationStack {
            Form {
                if paying { Section { LabeledContent(t.title, value: price.line) } }
                Section {
                    Text(t.prompt.isEmpty ? (paying ? "A word for the hosts (optional)" : "Why would you like to come?") : t.prompt).font(.headline)
                    TextField("Your answer", text: $answer, axis: .vertical).lineLimit(3...8).font(.body)
                } footer: {
                    Text(full ? "This ticket is full: you join the waitlist and the hosts tell you."
                         : paying ? "You ask, you pay the hosts, and once they confirm your payment the place is yours."
                         : "The hosts read your answer and give you a place.")
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .navigationTitle(full ? "Join the waitlist" : paying ? "Ask for \(t.title)" : "Apply for \(t.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Send") {
                        if let x = await model.applyTicket(e, t, answer: answer.jsTrim(), waitlist: full) { error = x } else { dismiss() }
                    }
                    // a priced ticket without a question: nothing has to be written
                    .disabled(answer.jsTrim().isEmpty && !(paying && !t.closed && t.prompt.isEmpty))
                }
            }
        }
        .presentationDetents([.medium])
        .solidSheet()
    }
}

/// One application: Approve and Decline share one lock.
struct DecideRow: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let a: EventApplication
    let report: (String?) -> Void
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Avatar(pubkey: a.pubkey, size: 26); Text(model.name(a.pubkey)).font(.subheadline.weight(.semibold)); if busy { ProgressView().controlSize(.small) } }
            if !a.answer.isEmpty { Text(a.answer).font(.subheadline).foregroundStyle(.secondary) }
            HStack {
                Button("Approve") { go(true) }.buttonStyle(.brand)
                Button("Decline", role: .destructive) { go(false) }.buttonStyle(.bordered)
            }
            .controlSize(.small)
            .disabled(busy)
        }
    }
    func go(_ approve: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            report(await model.decide(e, a.pubkey, approve: approve, ticket: a.ticket, application: a.ev))
            busy = false
        }
    }
}

struct CancelEventSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let e: CalEvent
    @State private var reason = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("A line for the guests (optional)", text: $reason, axis: .vertical).lineLimit(2...5).font(.body)
                } footer: { Text("Everyone who answered sees that it is cancelled. You can reopen it.") }
            }
            .navigationTitle("Cancel \(e.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Cancel the event", role: .destructive) { model.setEventStatus(e, .cancelled, reason: reason.jsTrim()); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .solidSheet()
    }
}

/// Make or edit an event (SPEC 19.18): the URL is checked as it is typed.
struct EventFormSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: CalEvent?
    let channel: String?
    @State private var title = ""
    @State private var description = ""
    @State private var allDay = false
    @State private var start = Date().addingTimeInterval(86400)
    @State private var end = Date().addingTimeInterval(86400 + 7200)
    @State private var hasEnd = true
    @State private var location = ""
    @State private var online = ""
    @State private var visibility: BelfryCore.Visibility = .members
    @State private var byApplication = false
    @State private var prompt = ""
    @State private var slug = ""
    @State private var slugEdited = false
    @State private var slugState: SlugCheck?
    @State private var cover: String?
    @State private var coverItem: PhotosPickerItem?
    @State private var coverBusy = false
    @State private var error: String?
    @State private var loaded = false
    @State private var done = false

    var body: some View {
        let places = model.derive.eventPlaces(channel ?? generalId).filter { location.isEmpty || $0.lowercased().hasPrefix(location.lowercased()) && $0 != location }.prefix(4)
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title).font(.body)
                        .onChange(of: title) { _, t in if !slugEdited && editing == nil { slug = EventLinks.slugOf(t) } }
                    PhotosPicker(selection: $coverItem, matching: .images) {
                        HStack { Label(cover == nil ? "Add a cover" : "Change the cover", systemImage: "photo"); if coverBusy { ProgressView().controlSize(.small) } }
                    }
                }
                Section {
                    Toggle("All day", isOn: $allDay).tint(Theme.toggle)
                    DatePicker("Starts", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    Toggle("Ends", isOn: $hasEnd).tint(Theme.toggle)
                    if hasEnd { DatePicker("Ends", selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]) }
                }
                Section("Where") {
                    TextField("A place", text: $location).font(.body)
                    ForEach(Array(places), id: \.self) { p in Button(p) { location = p } }
                    TextField("Online link (https://…)", text: $online).font(.body).keyboardType(.URL).textInputAutocapitalization(.never)
                    if online.isEmpty { Button("Make a Jitsi link") { online = Actions.jitsiLink(title.isEmpty ? "meeting" : title) } }
                }
                Section("About") { TextField("What happens (Markdown)", text: $description, axis: .vertical).lineLimit(3...10).font(.body) }
                Section {
                    Picker("Who sees it", selection: $visibility) {
                        ForEach(BelfryCore.Visibility.allCases, id: \.self) { v in Text(v.label).tag(v) }
                    }
                    Text(visibility.hint).font(.caption).foregroundStyle(.secondary)
                    if editing == nil {
                        Picker("Who can come", selection: $byApplication) { Text("Anyone").tag(false); Text("By application").tag(true) }
                        if byApplication { TextField("Why would you like to come?", text: $prompt, axis: .vertical).lineLimit(1...4).font(.body) }
                    }
                }
                Section {
                    HStack(spacing: 2) {
                        Text("…/events/").foregroundStyle(.secondary)
                        TextField("name", text: $slug).font(.body).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: slug) { _, s in
                                let c = EventLinks.cleanSlug(s)
                                if c != s { slug = c }
                                slugEdited = true
                            }
                    }
                    if let st = slugState, !slug.isEmpty {
                        Text(st.free ? "Free" : st.problem ?? "Taken").font(.caption).foregroundStyle(st.free ? .green : .red)
                    }
                } header: { Text("Its address") }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .navigationTitle(editing == nil ? "New event" : "Edit the event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton(editing == nil ? "Make" : "Save") { await save() }
                        .disabled(title.jsTrim().isEmpty || done || coverBusy || (slugState.map { !$0.free } ?? false) && !slug.isEmpty)
                }
            }
            .task(id: slug) {
                guard !slug.isEmpty else { slugState = nil; return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                slugState = await model.slugCheck(slug, event: editing?.d ?? "")
            }
            .onChange(of: coverItem) { _, item in
                guard let item else { return }
                coverBusy = true
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let jpeg = Images.jpeg(data, max: 1600) {
                        cover = await model.uploadImage(jpeg, name: "cover.jpg")
                    }
                    coverBusy = false
                }
            }
            .onAppear(perform: load)
        }
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let e = editing else { return }
        title = e.title
        description = e.description
        allDay = e.allDay
        start = Date(timeIntervalSince1970: TimeInterval(e.start))
        if let x = e.end { end = Date(timeIntervalSince1970: TimeInterval(x)) } else { hasEnd = false }
        location = e.location ?? ""
        online = e.links.first ?? ""
        visibility = e.visibility
        slug = e.slug ?? ""
        slugEdited = true
        cover = e.cover
    }

    func save() async {
        error = nil
        var f = EventForm(title: title.jsTrim())
        f.description = description.jsTrim()
        f.allDay = allDay
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        if allDay {
            f.startDate = day.string(from: start)
            f.endDate = hasEnd ? day.string(from: end) : nil
        } else {
            f.start = Int(start.timeIntervalSince1970)
            f.end = hasEnd ? Int(end.timeIntervalSince1970) : nil
        }
        f.tz = TimeZone.current.identifier
        f.location = location
        f.online = online
        f.visibility = visibility
        f.slug = slug
        f.cover = cover
        if editing == nil && byApplication { f.applicationPrompt = prompt.jsTrim() }
        if let e = editing {
            if let x = await model.editEvent(e, f) { error = x; return }
            done = true
            dismiss()
        } else {
            let (d, x) = await model.createEvent(f)
            done = true
            if let channel, let d {
                model.composerPrefill[channel] = EventLinks.url(domain: model.config.domain, link: slug.isEmpty ? d : slug)
            }
            if let x { error = x; return }
            dismiss()
            if channel == nil, let d { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.openEvent = d } }
        }
    }
}

/// The event's ticket types: add, edit, delete (no prices in v1).
struct TicketsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let e: CalEvent
    @State private var editing: TicketForm?
    var body: some View {
        let list = model.derive.tickets(e).filter { !$0.implicit }
        NavigationStack {
            List {
                if list.isEmpty { Text("No tickets: anyone answers with an RSVP.").foregroundStyle(.secondary) }
                ForEach(list) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(t.title).font(.subheadline.weight(.semibold))
                            Text([t.quantity.map { "\($0) places" }, t.closed ? "by application" : "open", t.members ? "members only" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") {
                            var f = TicketForm(id: t.id, title: t.title)
                            f.summary = t.summary; f.quantity = t.quantity.map(String.init) ?? ""; f.closed = t.closed; f.prompt = t.prompt; f.members = t.members; f.position = t.position
                            editing = f
                        }
                        .buttonStyle(.borderless)
                        BusyButton("Delete", role: .destructive) { model.deleteTicket(t) }.buttonStyle(.borderless)
                    }
                }
                Button { var f = TicketForm(title: ""); f.position = list.count + 1; editing = f } label: { ActionRow(icon: "plus", title: "Add a ticket") }
            }
            .navigationTitle("Tickets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: Binding(get: { editing.map { TicketKey(form: $0) } }, set: { editing = $0?.form })) { k in TicketFormSheet(e: e, form: k.form) }
        }
    }
}

struct TicketKey: Identifiable { let form: TicketForm; var id: String { form.id ?? "new" } }

struct TicketFormSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let e: CalEvent
    @State var form: TicketForm
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $form.title).font(.body)
                    TextField("In one line", text: $form.summary).font(.body)
                    TextField("Places (empty: no limit)", text: $form.quantity).keyboardType(.numberPad).font(.body)
                }
                Section {
                    Toggle("Needs an application", isOn: $form.closed).tint(Theme.toggle)
                    if form.closed { TextField("Why would you like to come?", text: $form.prompt, axis: .vertical).lineLimit(1...4).font(.body) }
                    Toggle("Members only", isOn: $form.members).tint(Theme.toggle)
                }
            }
            .navigationTitle(form.id == nil ? "New ticket" : "Edit ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { BusyButton("Save") { model.saveTicket(e, form); dismiss() }.disabled(form.title.jsTrim().isEmpty) }
            }
        }
        .presentationDetents([.medium, .large])
        .solidSheet()
    }
}

/// Events of one channel, as a sheet (from a channel's pull-down).
struct EventsList: View {
    @Environment(\.dismiss) private var dismiss
    let channel: String?
    var body: some View {
        NavigationStack {
            EventsScreen(channel: channel, sheet: true)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Events (the drawer's Upcoming events): an open screen like a channel: ☰, "Events", ＋; the
/// Upcoming / Mine / Hosting / Past picker under the bar, then the events edge to edge; a tap
/// pushes the event's page.
struct EventsScreen: View {
    @EnvironmentObject var model: AppModel
    var channel: String? = nil
    var sheet = false
    @State private var tab: EventsTab = .upcoming
    @State private var make = false

    var body: some View {
        let _ = model.version
        let d = model.derive
        let list = d.eventsIn(tab, now: .now, channel: channel)
        List {
            if list.isEmpty {
                ContentUnavailableView(tab.label, systemImage: "calendar", description: Text(tab.empty))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(list) { e in
                NavigationLink(value: EventRoute(key: e.coord)) { EventRow(e: e) }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $tab) {
                ForEach(EventsTab.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
        }
        // on the drawer's screen the main stack shows the event; in a sheet, its own stack
        .modifier(EventDestination(on: sheet))
        .navigationTitle(channel.flatMap { model.group($0)?.name }.map { "Events in \($0)" } ?? "Events")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !sheet { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
            if !d.amGuest {
                ToolbarItem(placement: .topBarTrailing) { Button { make = true } label: { Image(systemName: "plus") }.accessibilityLabel("New event") }
            }
        }
        .sheet(isPresented: $make) { EventFormSheet(editing: nil, channel: channel) }
    }
}

struct EventDestination: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.navigationDestination(for: EventRoute.self) { r in EventScreen(key: r.key, ticket: r.ticket) } } else { content }
    }
}

struct EventRow: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent

    /// "Meeting · Going · 4 people" / "Going · 12 going".
    func rowLine(_ d: Derive) -> String {
        var parts = [String]()
        if e.meeting { parts.append("Meeting") }
        if let s = d.stateLabel(e) { parts.append(s) }
        if e.meeting {
            let n = d.meetingCount(e)
            parts.append(n == 1 ? "1 person" : "\(n) people")
        } else if e.going > 0 {
            parts.append("\(e.going) going")
        }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        let d = model.derive
        HStack(spacing: 10) {
            if let c = e.cover, let u = URL(string: c), c.hasPrefix("https://") {
                CachedImage(url: u) { $0.resizable().scaledToFill() } placeholder: { DateChip(at: e.start) }
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                DateChip(at: e.start)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(d.lineDay(e.start, now: .now) + " · " + d.lineWhen(e)).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if e.status == .cancelled { Chip(text: "Cancelled", tint: .red) }
                    Text(rowLine(d)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
