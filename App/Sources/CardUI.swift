import BelfryCore
import SwiftUI

// A printed card's screens (canvas "Belfry · Group cards": cards/claim-*, confirm-code, states-*,
// contribute-*, steward, townsquare-new-topic; web chat-source f10e6b2 Card.tsx): what
// https://chat.<domain>/g/<id> opens. A free card: "Start this group" / "Start this topic"
// (signed in: straight in; not signed in: name and e-mail, the 6-digit code, then in). A claimed
// card is a guest link: its invite takes the usual way in. Dead ends say why. Every text is
// fixed or comes from the belfry's answer; nothing of the address is shown.

struct CardScreen: View {
    @EnvironmentObject var model: AppModel
    let card: PendingCard
    @State private var info: CardInfo?
    @State private var offline = false
    @State private var tries = 0
    /// The card was retired while its form was open.
    @State private var retired = false
    /// The e-mail's Confirm button: asking, done on another device, or refused.
    @State private var confirmed: CardConfirmOutcome?
    @State private var confirming = false

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { model.cardDone() }.accessibilityIdentifier("card-close")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: tries) { await load() }
    }

    private func load() async {
        // the e-mail's Confirm button opened the card: that, and nothing else
        if let token = card.confirm {
            guard confirmed == nil, !confirming else { return }
            confirming = true
            confirmed = await model.cardConfirm(card, token: token)
            confirming = false
            return
        }
        guard model.cardIsHere(card) else { return }
        offline = false
        switch await model.cardInfo(card) {
        case .success(let i):
            info = i
            if case .claimed(let kind, let group, _, let invite) = i { model.joinCard(card, kind: kind, group: group, invite: invite) }
        case .failure(let f):
            if f.code == .offline { offline = true } else { info = .unknown }
        }
    }

    @ViewBuilder private var content: some View {
        if card.confirm != nil {
            switch confirmed {
            case .elsewhere:
                // cards/onb-confirmed-elsewhere
                CardDead(title: "Confirmed", text: "It’s created. Go back to the page where you scanned the card: it opens there by itself.", domain: nil)
            case .failed(let f):
                CardDead(title: "Not confirmed", text: f.code == .expired ? "This link has expired or was used already. On the page where you scanned the card, send a new code." : f.text(),
                         domain: nil, again: f.code == .offline || f.code == .signer ? { confirmed = nil; tries += 1 } : nil)
            case .signedIn, nil:
                VStack(spacing: 18) {
                    ProgressView().controlSize(.large)
                    Text("Confirming…").font(.title3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            }
        } else if !model.cardIsHere(card) {
            CardDead(title: "This card is from another belfry", text: "Open it with your account there, or sign out here, and scan the card again.", domain: nil)
        } else if offline {
            CardDead(title: "No connection", text: "The card needs the internet to open. What you typed stays here.", domain: nil) { tries += 1 }
        } else if retired {
            CardDead(title: "This card is closed to new people", text: "The card was retired.", domain: card.domain)
        } else if let info {
            switch info {
            case .unclaimed(let kind):
                CardStartForm(card: card, kind: kind) { retired = true }
            case .claimed:
                opening
            case .retired(let kind, let title):
                CardDead(title: (title.isEmpty ? "This \(kind.word)" : title) + " is closed to new people",
                         text: "The card was retired. People already in the \(kind.word) carry on there.", domain: card.domain)
            case .archived(let kind, let title):
                CardDead(title: (title.isEmpty ? "This \(kind.word)" : title) + " has ended", text: "The \(kind.word) was archived.", domain: card.domain)
            case .unknown:
                CardDead(title: "This card isn’t known here", text: "Check that you scanned a card of this belfry.", domain: card.domain)
            }
        } else {
            opening
        }
    }

    private var opening: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text("Opening the card…").font(.title3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A card that can't go the usual way: why, and the belfry's page (states-closed, -archived, -offline).
struct CardDead: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let text: String
    /// The belfry whose public page "Visit" opens (nil: no such button).
    let domain: String?
    var again: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BelfryMark().frame(width: 56, height: 56).accessibilityHidden(true)
                Text(title).font(.title.bold()).accessibilityIdentifier("card-dead-title")
                Text(text).foregroundStyle(.secondary)
                if let again {
                    Button(action: again) { Text("Try again").frame(maxWidth: .infinity).padding(.vertical, 6) }.buttonStyle(.brand)
                }
                if let domain, let url = URL(string: "https://" + domain) {
                    Link(destination: url) { Text("Visit the belfry’s page").frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }
}

/// "Start this group" / "Start this topic", the code step for a visitor, and "someone was first".
struct CardStartForm: View {
    @EnvironmentObject var model: AppModel
    let card: PendingCard
    let kind: CardKind
    let onRetired: () -> Void

    enum Step { case form, code, taken }
    @State private var step = Step.form
    @State private var f = CardForm()
    @State private var loaded = false
    @State private var error: String?
    @State private var note: String?
    @State private var digits = ""
    @State private var verifying = false
    @State private var tag: HashtagState?
    @State private var checking = false
    @State private var recheck = 0
    @State private var taken: (group: String, invite: String)?
    @FocusState private var codeFocused: Bool
    @FocusState private var tagFocused: Bool

    private var signedIn: Bool { model.phase == .ready }
    private var word: String { kind.word }
    private var ready: Bool { f.ready(kind, tag: checking ? nil : tag, signedIn: signedIn) }

    var body: some View {
        SwiftUI.Group {
            switch step {
            case .form: form
            case .code: code
            case .taken: takenView
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let k = model.keptCardForm(card) { f = k }
            if model.launch.screen == "cardcode" { f = CardForm(title: "Sourdough starters", about: "", name: "Lou", email: "lou@example.org"); step = .code }
            if model.launch.screen == "cardtaken" { taken = (generalId, AppModel.demoCardInvite("CXAWMS")); step = .taken }
        }
        .onChange(of: f) { _, v in model.keepCardForm(card, v) }
    }

    // ---- the form ---------------------------------------------------------------------------------

    /// What is being created, in a sentence: "Sourdough starters", "#tool-library".
    private var made: String { kind == .topic ? "#" + Cards.hashtagSlug(f.hashtag) : Cards.label(f.title, 80) }

    // the approved flow (canvas Cards, onb-group-form, onb-topic-form, claim-signed-in,
    // onb-topic-signed-in; Xavier, 24 Nov): a group asks its name and description, a topic its
    // hashtag (the channel's name) and description; a visitor adds their name and e-mail
    private var form: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start a \(word)").font(.title2.bold()).accessibilityIdentifier("card-start-title")
                    Text("Nobody has scanned this card yet. The \(word) starts with you.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }
            if kind == .topic {
                Section {
                    HStack(spacing: 4) {
                        Text("#").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("tool-library", text: Binding(get: { f.hashtag }, set: { v in
                            // cleaned as it is typed and pasted: spaces become dashes, nothing else gets in
                            f.hashtag = Cards.hashtagTyping(v)
                        }))
                        .focused($tagFocused)
                        .onChange(of: tagFocused) { _, on in if !on { f.hashtag = Cards.hashtagSlug(f.hashtag) } }
                        .font(.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("card-hashtag")
                    }
                } header: { Text("Hashtag") } footer: { tagLine }
            } else {
                Section("Group name") {
                    TextField("What you wrote on the card", text: Binding(get: { f.title }, set: { f.title = String($0.prefix(80)) }))
                        .font(.body)
                        .accessibilityIdentifier("card-title")
                }
            }
            Section("Description") {
                TextField(kind == .topic ? "What people share here" : "What is it about?", text: Binding(get: { f.about }, set: { f.about = String($0.prefix(500)) }), axis: .vertical)
                    .lineLimit(3...6).font(.body)
                    .accessibilityIdentifier("card-about")
            }
            // no Summary row when starting a topic (Xavier, Cards v80): the belfry starts it
            // weekly; the topic's Notifications change it
            if !signedIn {
                Section("Your name") {
                    TextField("Your name", text: Binding(get: { f.name }, set: { f.name = String($0.prefix(100)) }))
                        .font(.body).textContentType(.name)
                        .accessibilityIdentifier("card-name")
                }
                Section("Your e-mail") {
                    TextField("Your e-mail", text: $f.email, prompt: Text(verbatim: "you@example.org"))
                        .font(.body).textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("card-email")
                }
            }
            Section {
                BusyButton { await start() } label: { Text("Create the \(word)").frame(maxWidth: .infinity) }
                    .buttonStyle(.brand)
                    .disabled(!ready)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("card-start")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("card-error") }
                    if !signedIn { Text("You’ll look after this \(word). We’ll send a 6-digit code to confirm your e-mail.") }
                }
            }
            if signedIn {
                // who you are, under the button, with Log out to start it as someone else
                Section {
                    HStack(spacing: 10) {
                        Avatar(pubkey: model.me, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.myName).font(.subheadline.weight(.semibold))
                            if let a = myAddress { Text(a).font(.footnote).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 8)
                        Button("Log out") { model.signOut() }
                            .font(.subheadline)
                            .accessibilityIdentifier("card-logout")
                    }
                } footer: {
                    Text(kind == .topic ? "You’ll look after this topic."
                         : "You’ll be the group’s first steward. People who scan the same QR code again will be invited to join this group so that you can remain connected after this event without having to share your email address publicly.")
                }
            }
        }
        .task(id: Cards.hashtagSlug(f.hashtag) + "/\(recheck)") { await checkTag() }
    }

    /// My address here (name@domain), when the profile says it.
    private var myAddress: String? {
        guard let n = model.profiles[model.me]?.nip05?.lowercased(), n.contains("@") else { return nil }
        return n
    }

    @ViewBuilder private var tagLine: some View {
        if checking { Text("Checking…") } else {
            switch tag {
            case .free: Text("✓ Available · this is the channel’s name").foregroundStyle(.green)
            case .taken: Text("Taken: try another one").foregroundStyle(.red)
            case .invalid: Text("Letters, digits and dashes, 2 to 30")
            case .unknown:
                HStack(spacing: 4) {
                    Text("Couldn’t check just now ·")
                    Button("Try again") { recheck += 1 }.font(.footnote)
                }
            case nil: EmptyView()
            }
        }
    }

    /// The hashtag's live check, 350 ms after the last key.
    private func checkTag() async {
        guard kind == .topic else { return }
        let slug = Cards.hashtagSlug(f.hashtag)
        guard slug.count >= 2 else { checking = false; tag = f.hashtag.isEmpty ? nil : .invalid; return }
        checking = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        let st = await model.hashtagState(card, slug)
        if Task.isCancelled { return }
        tag = st
        checking = false
    }

    private func fail(_ x: CardFailure) {
        if x.code == .retired { onRetired(); return }
        if x.code == .claimed, let g = x.group, let i = x.invite { taken = (g, i); step = .taken; return }
        if x.code == .hashtagTaken { tag = .taken; step = .form }
        if x.clearsCode { digits = "" }
        error = x.text(kind)
    }

    private func start() async {
        error = nil
        if kind == .topic { f.hashtag = Cards.hashtagSlug(f.hashtag) }
        guard ready else { return }
        hideKeyboard()
        if signedIn {
            if let x = await model.claimCard(card, kind: kind, form: f) { fail(x) }
            return
        }
        if let x = await model.cardStart(card, kind: kind, form: f) { fail(x) } else { digits = ""; note = nil; step = .code; codeFocused = true }
    }

    // ---- the code ---------------------------------------------------------------------------------

    private var code: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Check your e-mail").font(.title2.bold())
                Text("To create \(made), enter the 6-digit code we sent to ") + Text(f.email.jsTrim()).bold() + Text(".")
                CodeBoxes(digits: $digits, enabled: !verifying, focused: $codeFocused, bad: error != nil) { Task { await verify() } }
                SwiftUI.Group {
                    if verifying { Text("Creating \(made)…") }
                    else if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("card-error") }
                    else if let note { Text(note) }
                    else { Text("or click Confirm in the e-mail. This page moves on by itself once you have.") }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    BusyButton {
                        error = nil
                        if let x = await model.cardStart(card, kind: kind, form: f) { fail(x) } else { note = "A new code is on its way to your e-mail." }
                    } label: { Text("Send a new code") }
                    Spacer()
                    Button("Use another address") { step = .form; error = nil; note = nil; digits = "" }
                }
                .font(.subheadline)
                .disabled(verifying)
                Text("Not there? Look in your spam folder.").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .onAppear { codeFocused = true }
        // the e-mail's Confirm button clicked on another device: this screen moves on by itself
        .task(id: step) {
            guard step == .code else { return }
            while !Task.isCancelled, step == .code {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled || step != .code || verifying { continue }
                switch await model.cardPoll(card) {
                case .signedIn: return
                case .gone:
                    // ran out (or confirmed on this phone already, which has left this screen)
                    if step == .code, model.pendingCard == card { error = CardFailure(.expired).text(kind) }
                    return
                case .pending, .later: continue
                }
            }
        }
    }

    private func verify() async {
        guard !verifying, digits.count == 6 else { return }
        verifying = true
        error = nil
        note = nil
        if let x = await model.cardVerify(card, kind: kind, form: f, code: digits) { fail(x) }
        verifying = false
    }

    // ---- someone was first -----------------------------------------------------------------------

    private var takenView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BelfryMark().frame(width: 56, height: 56).accessibilityHidden(true)
                Text("Someone just started this \(word)").font(.title.bold())
                Text("Your text wasn’t used; you can join theirs.").foregroundStyle(.secondary)
                Button {
                    if let t = taken { model.joinCard(card, kind: kind, group: t.group, invite: t.invite) }
                } label: { Text(kind == .topic ? "Open the topic" : "Join").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.brand)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }
}

// ---- a topic reached through a card, as a reading guest (cards/follow-channel, contribute-*) ------

/// The composer to share at once, "Sending as a guest · Log in" under it; after the first post,
/// one card: "Shared. Don't lose your account" (name + e-mail: the Join sheet).
struct GuestTopicComposer: View {
    @EnvironmentObject var model: AppModel
    let group: String
    let sent: () -> Void
    @State private var later = false

    private var laterKey: String { "belfry-topic-save-no:" + group }

    var body: some View {
        let _ = model.version
        VStack(spacing: 0) {
            if !later, model.postedHere(group) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Shared. Don’t lose your account").font(.subheadline.weight(.semibold))
                    Text("Add your e-mail to keep what you shared, get replies and follow this topic.").font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button { hideKeyboard(); model.joinAsked = true } label: { Text("Save").frame(maxWidth: .infinity) }
                            .buttonStyle(.brand).accessibilityIdentifier("guest-topic-save")
                        Button { later = true; UserDefaults.standard.set(true, forKey: laterKey) } label: { Text("Not now").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 12).padding(.top, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Save your account")
            }
            Composer(group: group, placeholder: "Share a link, a message, a photo", draftKey: "c:" + group, plain: true) { text, attachments, _ in
                model.postAsGuest(text, in: group, attachments: attachments.filter { $0.mime.lowercased().hasPrefix("image/") })
                sent()
            }
            HStack(spacing: 4) {
                Text("Sending as a guest ·").foregroundStyle(.secondary)
                BusyButton { await model.signInInstead(channel: group, moved: false) } label: { Text("Log in") }
                    .accessibilityIdentifier("guest-topic-login")
            }
            .font(.footnote)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .onAppear { later = UserDefaults.standard.bool(forKey: laterKey) }
    }
}

/// "Summary by e-mail: Weekly | Monthly" where a topic is followed.
struct SummaryPicker: View {
    @Binding var choice: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary by e-mail").font(.subheadline.weight(.semibold))
            Picker("Summary by e-mail", selection: $choice) {
                Text("Weekly").tag("weekly")
                Text("Monthly").tag("monthly")
            }
            .pickerStyle(.segmented)
            Text(choice == "monthly" ? "What was said, once a month. Change it any time." : "What was said, once a week. Change it any time.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// The first open of the group or topic I just started from a card (cards/claim-done).
struct CardWelcome: View {
    @EnvironmentObject var model: AppModel
    let group: String

    var body: some View {
        let g = model.group(group)
        let topic = g?.followsIt ?? (BelfryCore.Group.typeOf(group) == .channel)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(topic ? "\(model.derive.label(group)) is open!" : "Welcome to \(model.derive.label(group))!").font(.subheadline.weight(.semibold))
                Text(topic ? "You created it and you look after it. Share the first tip, link or question."
                           : "You created it and you look after it. Say hi and share something to get it going.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { model.cardWelcome = nil } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                .buttonStyle(.borderless).accessibilityLabel("Close")
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12).padding(.top, 8)
        .accessibilityIdentifier("card-welcome")
    }
}

// ---- the Townsquare's card of a new topic (cards/townsquare-new-topic) ---------------------------

struct TopicCardView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let channel: String
    let by: String
    let text: String

    var body: some View {
        let g = model.group(channel)
        // the topic's own description when it is known here; else what the post says
        let about = g.map(\.about) ?? {
            let w = CardTopicWords.parts(about: nil, post: text)
            return [w.topic, w.about].filter { !$0.isEmpty }.joined(separator: " · ")
        }()
        // canvas Cards onb-town-topic: New topic · #tag · its description · Steward: … · N following · Open
        CardFrame {
            VStack(alignment: .leading, spacing: 4) {
                Label("New topic", systemImage: "tag").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("#" + channel).font(.subheadline.weight(.semibold))
                if !about.isEmpty { Text(about).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                Text("Steward: \(model.name(by))" + (g.map { " · \($0.members.count) following" } ?? "")).font(.caption).foregroundStyle(.secondary)
                Button("Open") { openChannel(channel, nil) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("topic-card-open")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New topic")
    }
}

// ---- for the group's stewards: Settings → The card (cards/steward) -------------------------------

struct CardSettingsSection: View {
    @EnvironmentObject var model: AppModel
    let group: String
    let card: CardOfGroup
    @State private var asking = false
    @State private var retired = false
    @State private var error: String?

    var body: some View {
        let word = BelfryCore.Group.typeOf(group) == .pod ? "group" : "topic"
        SwiftUI.Group {
                Section {
                    if retired {
                        Text("This card is retired: its QR says the \(word) is closed to new people. The belfry’s admins can reset it.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Card \(card.id)").font(.body.weight(.semibold))
                            Text(card.line).font(.footnote).foregroundStyle(.secondary)
                        }
                        NavigationLink { CardQRScreen(card: card, domain: model.config.domain) } label: {
                            ActionRow(icon: "qrcode", title: "Show the card’s QR", detail: "To print it again")
                        }
                        Button(role: .destructive) { asking = true } label: {
                            ActionRow(icon: "xmark.octagon", title: "Retire this card", detail: "The QR then says the \(word) is closed to new people")
                        }
                        .accessibilityIdentifier("card-retire")
                        if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    }
                } header: { Text("The card") } footer: {
                    Text("Only the \(word)’s stewards and the belfry’s admins see this.")
                }
                .alert("Retire this card?", isPresented: $asking) {
                    Button("Retire", role: .destructive) {
                        Task {
                            if let x = await model.retireCard(card.id) { error = x.text(card.kind) } else { retired = true }
                        }
                    }
                    Button("Keep it", role: .cancel) {}
                } message: {
                    Text("Its QR will say the \(word) is closed to new people. People already in it carry on here.")
                }
        }
    }
}

/// The card's QR, big, to print again.
struct CardQRScreen: View {
    let card: CardOfGroup
    let domain: String

    var body: some View {
        let url = CardLink.url(domain: domain, id: card.id)
        List {
            Section {
                VStack(spacing: 10) {
                    if let img = QR.image(url) {
                        Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 240, height: 240)
                            .padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityLabel("The QR of card \(card.id)")
                    }
                    Text("Card \(card.id)").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section {
                if let img = QR.image(url) {
                    ShareLink(item: Image(uiImage: img), preview: SharePreview("Card \(card.id)", image: Image(uiImage: img))) {
                        Label("Share or print", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("The card’s QR")
        .navigationBarTitleDisplayMode(.inline)
    }
}
