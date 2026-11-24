import BelfryCore
import Foundation

// Printed cards (collective-belfry docs/cards.md; web chat-source f10e6b2; canvas "Belfry · Group
// cards", boards cards/*). A card's QR is https://chat.<domain>/g/<id>: the first scan starts a
// group or a topic, later scans join it through the card's guest link (the usual guest-link path:
// `pendingInvite`). Nothing of the address is shown: its domain and id only pick what to ask.

/// A card scanned. `id` nil: a card's address with no id in it ("This card isn't known here").
struct PendingCard: Codable, Equatable {
    let domain: String
    let id: String?
    /// The e-mail's Confirm button (`?confirm=<token>`): in memory only, never stored.
    var confirm: String? = nil
    var key: String { domain + "/" + (id ?? "") }
    private enum CodingKeys: String, CodingKey { case domain, id }
}

/// What the e-mail's Confirm button did here.
enum CardConfirmOutcome: Equatable {
    /// This phone started the claim: it is signed in, the group opens.
    case signedIn
    /// Another device started it: "Confirmed", go back there (cards/onb-confirmed-elsewhere).
    case elsewhere
    case failed(CardFailure)
}

extension AppModel {
    static let demoDomain = "demo.belfry.sh"
    static let cardFormKey = "belfry-card-form"

    /// A card's address was opened. Signed in to another belfry: the card screen says so.
    func openCard(_ card: PendingCard) {
        hideKeyboard()
        pendingCard = card
    }

    /// Leave the card (Close, or it was dealt with).
    func cardDone() {
        pendingCard = nil
        UserDefaults.standard.removeObject(forKey: AppModel.cardFormKey)
    }

    /// Is the card of the belfry this phone is signed in to (or signed out: any belfry)?
    func cardIsHere(_ card: PendingCard) -> Bool { phase != .ready || card.domain == config.domain }

    private func isDemoCard(_ card: PendingCard) -> Bool { isDemo || card.domain == AppModel.demoDomain }

    /// The API of the card's belfry: mine when signed in there, else that belfry's, unsigned.
    private func cardAPI(_ card: PendingCard) async -> BelfryAPI {
        if phase == .ready, card.domain == config.domain { return api }
        let cfg = (try? await Discovery.fetch(domain: card.domain)) ?? .defaults(domain: card.domain)
        return BelfryAPI(config: cfg, signer: nil)
    }

    // ---- what was typed, kept between the code's two steps and a closed app -------------------------

    private struct KeptForm: Codable { let card: String; let form: CardForm }

    func keptCardForm(_ card: PendingCard) -> CardForm? {
        guard let d = UserDefaults.standard.data(forKey: AppModel.cardFormKey), let k = try? JSONDecoder().decode(KeptForm.self, from: d), k.card == card.key else { return nil }
        return k.form
    }

    func keepCardForm(_ card: PendingCard, _ f: CardForm) {
        UserDefaults.standard.set(try? JSONEncoder().encode(KeptForm(card: card.key, form: f)), forKey: AppModel.cardFormKey)
    }

    // ---- the calls -----------------------------------------------------------------------------------

    /// The demo's cards: K7Q2MX (a group card) and T9PC4H (a topic card) are free; CXAWMS is a
    /// claimed group card, TPCHAT a claimed topic card, RETRDX retired, ARCH9V archived (the web's).
    private func demoInfo(_ id: String) -> CardInfo {
        let kind: CardKind = id == "T9PC4H" || id == "TPCHAT" ? .topic : .group
        if let g = demoCards[id] { return .claimed(kind, group: g, title: derive.label(g), invite: AppModel.demoCardInvite(id)) }
        switch id {
        case "K7Q2MX", "T9PC4H": return .unclaimed(kind)
        case "CXAWMS", "TPCHAT": return .claimed(kind, group: generalId, title: "Townsquare", invite: AppModel.demoCardInvite(id))
        case "RETRDX": return .retired(kind, title: "Sourdough starters")
        case "ARCH9V": return .archived(kind, title: "Book club")
        default: return .unknown
        }
    }

    static func demoCardInvite(_ id: String) -> String { "demo-card-invite-" + id.lowercased() + "-xxxxxxxx" }

    /// What a guest link's card started, when this phone knows (the demo's, or a card opened in this run).
    func cardTopicKind(_ token: String) -> CardKind? {
        if let k = cardInvites[token] { return k }
        return token == AppModel.demoCardInvite("TPCHAT") || token == AppModel.demoCardInvite("T9PC4H") ? .topic : nil
    }

    func cardInfo(_ card: PendingCard) async -> Result<CardInfo, CardFailure> {
        guard let id = card.id else { return .success(.unknown) }
        if isDemoCard(card) { try? await Task.sleep(nanoseconds: 300_000_000); return .success(demoInfo(id)) }
        do { return .success(try await cardAPI(card).cardInfo(id)) }
        catch let f as CardFailure { return .failure(f) } catch { return .failure(CardFailure(.failed)) }
    }

    func hashtagState(_ card: PendingCard, _ hashtag: String) async -> HashtagState {
        let h = Cards.hashtagSlug(hashtag)
        guard h.count >= 2 else { return .invalid }
        if isDemoCard(card) { return ["general", "events", "market", "requests"].contains(h) || derive.group(h) != nil ? .taken : .free }
        return await cardAPI(card).hashtagState(h)
    }

    /// A claimed card: its guest link takes the usual way in. Signed out: guest mode, at once.
    /// Signed in: "Join with your account" (the sheet RootView shows for `pendingInvite`).
    func joinCard(_ card: PendingCard, kind: CardKind, group: String, invite: String) {
        cardInvites[invite] = kind
        cardDone()
        let inv = PendingInvite(domain: card.domain, token: invite)
        if phase == .ready, derive.group(group).map({ $0.members.contains(me) || $0.admins.contains(me) }) == true {
            // in it already: open it
            joinedChannel = group
            return
        }
        pendingInvite = inv
        if phase == .signedOut, pendingCode == nil { inviteSignInFirst = false; inviteProblem = nil; openInvite(inv) }
    }

    /// Signed in: start the group or topic now, and open it.
    func claimCard(_ card: PendingCard, kind: CardKind, form: CardForm) async -> CardFailure? {
        guard let id = card.id else { return CardFailure(.unknown) }
        let group: String
        if isDemoCard(card) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if case .claimed(_, let g, _, let i) = demoInfo(id) { return CardFailure(.claimed, group: g, invite: i) }
            if guestReading { return CardFailure(.guestNotSaved) }
            group = demoClaim(kind, form)
            demoCards[id] = group
        } else {
            do { group = try await api.claimCard(id, kind: kind, form: form) }
            catch let f as CardFailure { return f } catch { return CardFailure(.failed) }
        }
        cardDone()
        cardWelcome = group
        await refresh()
        joinedChannel = group
        return nil
    }

    /// The demo: what the belfry's groups key would write (docs/cards.md §2.2), here by me.
    private func demoClaim(_ kind: CardKind, _ f: CardForm) -> String {
        let title = Cards.label(f.title, 80), about = f.about.jsTrim()
        guard kind == .topic else { return createGroup(name: title, about: about, access: .open) }
        let tag = Cards.hashtagSlug(f.hashtag)
        let words = [title, about].filter { !$0.isEmpty }.joined(separator: " · ")
        for d in Actions.createChannel(id: tag, name: tag, about: words) { engine?.enqueue(d) }
        engine?.enqueue(Draft(kind: 9, content: "# New topic: #\(tag) · \(words)", tags: [["h", generalId], ["t", "new-topic"], ["channel", tag]]))
        return tag
    }

    /// The key a visitor's claim is signed with (it becomes the session's): one per card in the
    /// Keychain until the claim works; `key_taken`: a new one.
    private func cardSecret(_ card: PendingCard, fresh: Bool = false) -> String {
        let name = "card-" + card.key
        if !fresh, let s = Keychain.string(name) { return s }
        let s = Keys.generateSecret().hex
        Keychain.setString(s, name)
        return s
    }

    /// Not signed in: the 6-digit code and the Confirm button go to the e-mail; the belfry keeps
    /// the form (signed by this card's key, which becomes the session's).
    func cardStart(_ card: PendingCard, kind: CardKind, form: CardForm) async -> CardFailure? {
        guard let id = card.id else { return CardFailure(.unknown) }
        if isDemoCard(card) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if case .claimed(_, let g, _, let i) = demoInfo(id) { return CardFailure(.claimed, group: g, invite: i) }
            return nil
        }
        do { try await cardAPI(card).claimStart(id, kind: kind, form: form, secretHex: cardSecret(card)); return nil }
        catch let f as CardFailure {
            if f.code == .keyTaken { _ = cardSecret(card, fresh: true) }
            return f
        } catch { return CardFailure(.failed) }
    }

    /// The code: the group or topic is made, and this phone is signed in (as the account the
    /// address already had, or as a new guest who looks after this group).
    func cardVerify(_ card: PendingCard, kind: CardKind, form: CardForm, code: String) async -> CardFailure? {
        guard let id = card.id else { return CardFailure(.unknown) }
        if isDemoCard(card) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if code.jsTrim() != "123456" { return CardFailure(.wrongCode, triesLeft: 2) }
            cardDone()
            startDemo()
            let g = demoClaim(kind, form)
            demoCards[id] = g
            cardWelcome = g
            joinedChannel = g
            return nil
        }
        let secret = cardSecret(card)
        do {
            let api = await cardAPI(card)
            let r = try await api.claimVerify(id, kind: kind, form: form, code: code, secretHex: secret)
            signedInFromCard(card, r, secret: secret, config: api.config)
            return nil
        } catch let f as CardFailure {
            if f.code == .keyTaken { _ = cardSecret(card, fresh: true) }
            return f
        } catch { return CardFailure(.failed) }
    }

    /// The claim is made and the session is this card's key's: stored like any sign-in, the
    /// group opens with its welcome.
    private func signedInFromCard(_ card: PendingCard, _ r: CardSignedIn, secret: String, config cfg: BelfryConfig) {
        Keychain.removeString("card-" + card.key)
        cardDone()
        pendingInvite = nil
        inviteSignInFirst = false
        let st = StoredSession(domain: card.domain, bunkerURL: r.session.bunkerURL, clientSecret: secret, pubkey: r.session.pubkey)
        store(st)
        UserDefaults.standard.set(r.group, forKey: AppModel.openAfterSignInKey)
        cardWelcome = r.group
        open(st, config: cfg)
    }

    /// The waiting code screen asks whether the e-mail's button was clicked on another device.
    func cardPoll(_ card: PendingCard) async -> CardPoll {
        guard let id = card.id, !isDemoCard(card), let secret = Keychain.string("card-" + card.key) else { return .pending }
        let api = await cardAPI(card)
        let p = await api.claimPoll(id, secretHex: secret)
        if case .signedIn(let r) = p { signedInFromCard(card, r, secret: secret, config: api.config) }
        return p
    }

    /// The e-mail's Confirm button opened this card. Signed with this phone's key for the card
    /// when it started the claim (then the session comes back), else with a fresh key.
    func cardConfirm(_ card: PendingCard, token: String) async -> CardConfirmOutcome {
        guard let id = card.id else { return .failed(CardFailure(.unknown)) }
        if isDemoCard(card) { try? await Task.sleep(nanoseconds: 400_000_000); return .elsewhere }
        let mine = Keychain.string("card-" + card.key)
        let secret = mine ?? Keys.generateSecret().hex
        do {
            let api = await cardAPI(card)
            let c = try await api.claimConfirm(id, token: token, secretHex: secret)
            if let r = c.signedIn, mine != nil {
                signedInFromCard(card, r, secret: secret, config: api.config)
                return .signedIn
            }
            return .elsewhere
        } catch let f as CardFailure { return .failed(f) } catch { return .failed(CardFailure(.failed)) }
    }

    // ---- for the group's stewards (Settings → The card) ---------------------------------------------

    func groupCard(_ group: String) async -> CardOfGroup? {
        if isDemo {
            guard let id = demoCards.first(where: { $0.value == group })?.key ?? (launch.screen == "cardsteward" ? "K7Q2MX" : nil) else { return nil }
            return CardOfGroup(id: id, kind: BelfryCore.Group.typeOf(group) == .pod ? .group : .topic, startedBy: launch.screen == "cardsteward" ? "Lou" : name(me), joinedByScan: launch.screen == "cardsteward" ? 8 : 0)
        }
        return try? await api.groupCard(group)
    }

    func retireCard(_ id: String) async -> CardFailure? {
        if isDemo { try? await Task.sleep(nanoseconds: 300_000_000); demoCards[id] = nil; return nil }
        do { try await api.retireCard(id); return nil }
        catch let f as CardFailure { return f } catch { return CardFailure(.failed) }
    }

    // ---- a reading guest in a topic reached by a card -----------------------------------------------

    /// The topic this guest may post in while reading (nil: none).
    var guestCardTopic: String? { guestReading ? session?.cardTopic : nil }

    func postAsGuest(_ text: String, in group: String, attachments: [Attachment]) {
        engine?.enqueue(Actions.guestTopicPost(group, text: text), attachments: attachments)
    }

    /// Did I say something here (sent, or still on its way)?
    func postedHere(_ group: String) -> Bool {
        derive.messages(group).contains { $0.ev.pubkey == me } ||
            (engine?.outboxItems().contains { $0.kind == 9 && $0.tags.contains { $0.count > 1 && $0[0] == "h" && $0[1] == group } } ?? false)
    }
}
