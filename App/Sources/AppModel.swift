import BelfryCore
import Foundation
import SwiftUI
import UserNotifications

// The app's state: the session (Keychain), the sync engine and direct messages, and a cached
// Derive over the event log that views read. Every user action goes through here into the outbox.

struct StoredSession: Codable, Equatable {
    var domain: String
    var bunkerURL: String?
    var clientSecret: String // hex, this device's key for the bunker
    var pubkey: String?
    var demo: Bool = false
    /// Guest mode (SPEC 19.26): this session opened a guest link and reads until it joins.
    var reading: Bool? = nil
    /// The channel the guest link opened.
    var guestChannel: String? = nil
    /// The link was a belfry member link (SPEC 19.43): joining makes this key a member.
    var memberLink: MemberLinkInfo? = nil
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case signedOut, ready }

    @Published var phase: Phase = .signedOut
    @Published var version = 0 { didSet { LoopWatch.tick("model.version") } }
    /// A guest link waiting to be used (kept through sign-in; only its domain and token).
    @Published var pendingInvite: PendingInvite? = (UserDefaults.standard.data(forKey: "belfry-invite")).flatMap { try? JSONDecoder().decode(PendingInvite.self, from: $0) } {
        didSet { UserDefaults.standard.set(pendingInvite.flatMap { try? JSONEncoder().encode($0) }, forKey: "belfry-invite") }
    }
    /// Someone's profile to show, from a face, a name or a mention anywhere.
    @Published var openProfile: String?
    /// The channel a guest link just brought me into (opened once).
    @Published var joinedChannel: String?
    /// A co-host link used by someone new: once their e-mail is proven, the link is used again.
    @Published var coHostToken: String?
    var demoFollows = [String: String]()
    /// Push notifications on this phone (AppModel+Push).
    @Published var pushState: PushState = .unknown
    /// A tapped notification to open (a channel at a message, or Messages).
    @Published var pushOpen: PushOpen?
    var demoNotifications = NotificationSettings()
    /// What is on screen (foreground notifications stay quiet for it).
    var visibleConversation: String?
    var visibleChannel: String?
    var messagesOpen = false
    /// A thread to open in its channel (a tapped thread-reply notification).
    @Published var openThread: ThreadRoute?
    /// Events read through the belfry's API, by link (a minute).
    var remoteEvents = [String: (at: Date, event: ApiEvent)]()
    /// Text to put in a channel's composer (an event's URL after making it from the channel's ＋).
    @Published var composerPrefill = [String: String]()
    @Published var config: BelfryConfig = .defaults(domain: "belfry.sh") {
        didSet { if config.branding != oldValue.branding { Theme.branding = config.branding } }
    }
    /// The belfry's roles and membership settings (docs/roles.md, docs/membership.md).
    @Published var roles = RolesInfo()
    var rolesAt: Date?
    @Published var membership = MembershipSettings()
    /// Requests waiting (Requests screen): people and agents asking to join the belfry.
    @Published var belfryRequests = [BelfryRequest]()
    @Published var agentRequests = [AgentRequest]()
    var demoRequestsSeeded = false
    var requestsAt: Date?
    /// Photos full screen (a message's photos, swiped through).
    @Published var lightbox: Lightbox?
    /// A group's page to show (its card in the parent channel): pushed on the main stack.
    @Published var openGroup: String?
    /// Groups the relay said it does not have (SPEC 19.30; stored as `groups-absent`).
    @Published var groupsAbsent = [String: Int]()
    /// When each group was last put to the relay (SPEC 19.30; memory only).
    var presenceAsked = [String: Int]()
    var presenceAt: Date?
    /// The drawer's search field (all channels).
    @Published var drawerQuery = ""
    /// When I last opened @Mentions (the badge counts the ones after).
    @Published var mentionsSeenAt = UserDefaults.standard.integer(forKey: AppModel.perAccount("belfry-mentions-seen"))
    /// The accounts on this device (SPEC 19.24, AppModel+Accounts).
    @Published var accounts = AccountList()
    /// "Add an account": the sign-in over the app; the open account stays until the new one is in.
    @Published var addingAccount = false
    /// iPhone: the bottom bar's place (Home · Calendar · Groups · Town; Create is a sheet).
    @Published var tab: AppTab = .home
    /// The Create sheet (the bar's ＋).
    @Published var showCreate = false
    /// The selected place's bar item tapped again: back to its root.
    @Published var tabReselected = 0
    /// The accounts / belfries switcher (the belfry's name at the top of a place, ⇅ in the drawer).
    @Published var showAccounts = false
    /// A channel whose composer takes the keyboard when it appears (Create → Message).
    @Published var focusComposer: String?
    /// A guest's request to become a member as the belfry last told it (stored per account).
    @Published var applyState: ApplyStatus? = AppModel.loadStored(ApplyStatus.self, "belfry-apply-status")
    /// The charter for people who can't read its group (GET /charter), stored per account.
    @Published var publicCharter: [PublicAgreement] = AppModel.loadStored([PublicAgreement].self, "belfry-public-charter") ?? []
    /// The belfry's public events (GET /events?visibility=public) as the API gives them, stored.
    @Published var publicEventsRaw: Data? = UserDefaults.standard.data(forKey: AppModel.perAccount("belfry-public-events"))
    /// A new member's first minutes are on screen (Welcome → charter → name and photo).
    @Published var welcomeShown = false
    /// A screen to push on the place on screen (Home's tiles).
    @Published var pushRoute: PlaceRoute?
    /// The Add an agent sheet (own profile).
    @Published var showAddAgent = false
    /// "Full e-mail": the whole message on Blossom.
    @Published var fullMail: FullMailRef?
    /// The Create sheet's first row (Calendar: Event; Groups: Group; else Message).
    @Published var createFirst: CreateWhat = .message
    /// The channel open in Town (Create's "Where" starts there when Town is the place).
    var townChannel = generalId
    private var cachedMentions: (Int, [NostrEvent])?
    var mentions: [NostrEvent] {
        if let c = cachedMentions, c.0 == version { return c.1 }
        let m = derive.mentionsOfMe()
        cachedMentions = (version, m)
        return m
    }
    var newMentions: Int {
        guard let r = readSync?.state else { return mentions.prefix(99).filter { $0.createdAt > mentionsSeenAt }.count }
        let now = Int.now
        return mentions.prefix(99).filter { $0.createdAt > mentionsSeenAt && Derive.mentionIsNew(r, $0, now: now) }.count
    }

    /// The shared read state (SPEC 19.27), per session.
    var readSync: ReadSync?
    var readState: ReadState { readSync?.state ?? .empty }

    /// Unread top-level messages of a channel (the drawer's count).
    func unread(_ groupId: String) -> Int { readSync == nil ? 0 : derive.unreadIn(groupId, readState, now: Int.now) }

    /// A channel on screen at its newest message: read up to it; its notifications go away.
    func markChannelRead(_ groupId: String) {
        guard let rs = readSync, let at = derive.channelMark(groupId) else { return }
        rs.mark("c", groupId, at)
    }

    func markThreadRead(_ groupId: String, _ rootId: String) {
        guard let rs = readSync, let at = derive.threadMark(groupId, rootId) else { return }
        rs.mark("t", rootId, at)
    }

    func markConversationRead(_ conv: String) {
        dms?.markRead(conv)
        if let at = dms?.thread(conv).last?.at { readSync?.mark("d", conv, at) }
    }

    /// A mark arrived (here or from another device): counts follow, delivered notifications of
    /// what is read now go away.
    func readChanged(_ r: ReadState) {
        version += 1
        let now = Int.now
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { list in
            var gone = [String]()
            for n in list {
                let tid = n.request.content.threadIdentifier
                guard tid != "dm", tid != "belfry", !tid.isEmpty else { continue }
                if Int(n.date.timeIntervalSince1970) <= r.readUpTo("c", tid, now: now) { gone.append(n.request.identifier) }
            }
            if !gone.isEmpty { center.removeDeliveredNotifications(withIdentifiers: gone) }
        }
    }

    func markMentionsSeen() {
        if let newest = mentions.first?.createdAt { readSync?.mark("m", "", newest) }
        mentionsSeenAt = Int.now
        UserDefaults.standard.set(mentionsSeenAt, forKey: AppModel.perAccount("belfry-mentions-seen"))
    }
    /// Redraws everything when the belfry's colour changes (Theme).
    var brandKey: String { config.branding?.primary ?? "" }
    @Published var signInError: String?
    /// The native sign-in waiting for its code (SPEC 19.20): screen 2. Kept in the Keychain by
    /// `nativeFlow`, so it is back after the app was killed while the person read the e-mail.
    @Published var pendingCode: PendingCode?
    let nativeFlow = NativeSignInFlow(vault: KeychainVault())
    @Published var busy = false
    /// Guest mode (SPEC 19.26): reading only; the composer's place says so, with Join.
    @Published var guestReading = false
    /// The Join sheet (the guest bar's Join, or anything that writes while reading).
    @Published var joinAsked = false
    /// One loading screen from a guest link to its channel; nothing else is drawn meanwhile.
    @Published var opening: Opening?
    /// A guest link that can't be used: its own screen (fixed messages).
    @Published var inviteProblem: InviteProblem?
    /// "I have an account: sign in" on that screen: the sign-in first, the link after.
    @Published var inviteSignInFirst = false
    /// A belfry member link opened signed out, not used yet (SPEC 19.43): "You're invited to …"
    /// with Sign up / Log in, no channel behind it.
    @Published var memberInvite: MemberInvite?
    /// Sign up from a member invite is under way: the Join sheet opens as soon as the link is used.
    var signUpForMember = false
    /// The domain to suggest on the sign-in screen (after "Sign in instead").
    @Published var signInDomainHint: String?
    /// A fixed line on the sign-in screen after "Sign in instead" (no address to prefill).
    @Published var signInNote: String?
    var openingToken: String?

    private(set) var engine: SyncEngine?
    private(set) var dms: DirectMessages?
    private(set) var session: StoredSession?
    /// (model version, the engine's outbox version, snapshot): the outbox's too, so a screen opened
    /// right after my own action (a group I just made, a saved setting) sees it in the same frame
    /// (the model's own bump is debounced; incoming events only bump the model).
    private var cachedDerive: (Int, Int, Derive)?
    private var cachedGroups: (Int, [BelfryCore.Group])?
    private var cachedProfiles: (Int, [String: Profile])?
    private var seenSentHere = [String: Int]()
    /// `_groups@<domain>`: posts e-mail cards, answers sent as the channel, guest joins.
    @Published var groupsKey: String?
    /// What the register says people are (`POST /whois`), this session.
    @Published var kinds = [String: String]()
    private var whoisAsked = Set<String>()
    private var configCheckedAt = Date.distantPast
    private var bump: DispatchWorkItem?
    let launch = LaunchOptions()

    static let redirectScheme = "sh.belfry.app"
    static let redirectURI = "sh.belfry.app://connect"

    private var watchChanges: Any?

    init() {
        if LoopWatch.on { watchChanges = objectWillChange.sink { _ in LoopWatch.tick("model.objectWillChange") } }
        if let g = launch.guest {
            pendingInvite = nil
            if g == "opening" { opening = Opening(channel: "garden-3f2a", name: "Garden") } else { startDemo(reader: true) }
            if g == "join" || g == "code" { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.joinAsked = true } }
        } else if ProcessInfo.processInfo.arguments.contains("-join") {
            pendingInvite = PendingInvite(domain: "demo.belfry.sh", token: "demoinvite0123456789abcd")
        } else if launch.demo {
            pendingInvite = nil
            startDemo()
        } else if launch.signin == "code" {
            pendingInvite = nil
            pendingCode = PendingCode(address: "maya@riverside.example", to: "m\u{2022}\u{2022}\u{2022}@example.org")
        } else if launch.signin != nil {
            // a screenshot of screen 1
            pendingInvite = nil
        } else if let s = restoreAccounts() {
            open(s)
        } else {
            pendingCode = nativeFlow.pending
            // a guest link kept from before: the loading screen at once
            if pendingCode == nil, let inv = pendingInvite { openInvite(inv) }
        }
    }

    // ---- reading -----------------------------------------------------------------------------------

    var me: String { engine?.me ?? "" }
    var isDemo: Bool { session?.demo ?? false }

    var derive: Derive {
        let ev = engine?.outboxVersion ?? -1
        if let c = cachedDerive, c.0 == version, c.1 == ev { return c.2 }
        let pendingIds = Set((engine?.outboxItems() ?? []).filter { $0.signed == nil }.map(\.localId))
        var ctx = WorldContext(me: me, domain: config.domain, communityName: config.name, communityAdmins: Set(config.admins),
                               groupsKey: groupsKey, bridgeKey: dms?.bridge, groupsRelay: config.groupsRelay,
                               agents: config.agents, kinds: kinds, pending: pendingIds, groupsAbsent: groupsAbsent)
        ctx.belfryKey = isDemo ? Demo.signer("belfry").pubkey : config.belfryKey
        ctx.placeNames = true // #general reads Townsquare (SPEC 19.31)
        let list = engine?.snapshot() ?? []
        let d = Derive(events: list, context: ctx)
        // offline first: the channels nothing arrived in keep what the last snapshot worked out
        if let prev = cachedDerive?.2, list.count >= prev.events.count, list.count - prev.events.count < 500 {
            let known = prev.idSet
            let fresh = list.filter { !known.contains($0.id) }
            if fresh.count == list.count - prev.events.count { d.carry(from: prev, newEvents: fresh) }
        }
        cachedDerive = (version, ev, d)
        // nothing is queued for an archived or deleted group (SPEC 19.30)
        engine?.setLocked(d.lockedGroups)
        return d
    }

    var groups: [BelfryCore.Group] {
        if let c = cachedGroups, c.0 == version { return c.1 }
        let g = derive.groups()
        cachedGroups = (version, g)
        return g
    }

    var profiles: [String: Profile] {
        if let c = cachedProfiles, c.0 == version { return c.1 }
        let p = derive.profiles()
        cachedProfiles = (version, p)
        return p
    }

    /// Any group that is there, archived ones too (`groups` has only the listed ones).
    func group(_ id: String) -> BelfryCore.Group? { derive.group(id) }
    func name(_ pk: String) -> String { derive.displayName(pk, profiles) }
    func realName(_ pk: String) -> String { Derive.realName(pk, profiles) }
    func pending(_ id: String) -> OutboxItem? { engine?.pending(id) }
    var online: Bool { engine?.online ?? true }
    var access: AccessState { engine?.access ?? .unknown }
    var unreadDMs: Int { dms?.unreadTotal ?? 0 }

    private func changed() {
        bump?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.version += 1 }
        bump = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
    }

    // ---- session -----------------------------------------------------------------------------------

    func signIn(domain raw: String, auth: WebAuth) async {
        let domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        signInError = nil
        guard Discovery.isDomain(domain) else { signInError = "Type your community's address, like belfry.sh."; return }
        busy = true
        defer { busy = false }
        let cfg = (try? await Discovery.fetch(domain: domain)) ?? .defaults(domain: domain)
        let flow = SignIn(config: cfg, redirectURI: AppModel.redirectURI)
        do {
            let callback = try await auth.start(url: flow.authorizeURL, scheme: AppModel.redirectScheme)
            let code = try flow.code(from: callback)
            let token = try await flow.exchange(code: code)
            guard BunkerURL(token.bunkerURL) != nil else { throw SignIn.Failure.refused }
            let s = StoredSession(domain: domain, bunkerURL: token.bunkerURL, clientSecret: Keys.generateSecret().hex, pubkey: token.pubkey)
            store(s)
            config = cfg
            open(s, config: cfg)
        } catch let f as SignIn.Failure {
            signInError = f.message
        } catch WebAuth.Cancelled.cancelled {
            signInError = SignIn.Failure.cancelled.message
        } catch {
            signInError = SignIn.Failure.unknown.message
        }
    }

    func open(_ s: StoredSession, config cfg: BelfryConfig? = nil) {
        if engine != nil { closeLive() } // another account was open (added or switched to)
        session = s
        mentionsSeenAt = UserDefaults.standard.integer(forKey: AppModel.perAccount("belfry-mentions-seen"))
        // this account's stored copies (offline first)
        applyState = s.demo ? nil : AppModel.loadStored(ApplyStatus.self, "belfry-apply-status")
        publicCharter = s.demo ? [] : AppModel.loadStored([PublicAgreement].self, "belfry-public-charter") ?? []
        publicEventsRaw = s.demo ? nil : UserDefaults.standard.data(forKey: AppModel.perAccount("belfry-public-events"))
        let db: Database
        if s.demo {
            db = (try? .memory())!
        } else {
            db = (try? Database(path: AppModel.dbURL(s.domain, slot: Keychain.slot).path)) ?? (try! .memory())
        }
        config = cfg ?? db.get("config", as: BelfryConfig.self) ?? .defaults(domain: s.domain)
        db.set("config", config)
        let signer: Signer
        if s.demo {
            signer = try! LocalSigner(secretHex: s.clientSecret)
        } else if let b = s.bunkerURL.flatMap(BunkerURL.init), let secret = Data(hex: s.clientSecret),
                  let bs = try? BunkerSigner(bunker: b, clientSecret: secret, pubkey: s.pubkey ?? db.get("pubkey", as: String.self)) {
            signer = bs
        } else {
            signOut()
            return
        }
        let e = SyncEngine(config: config, db: db, signer: signer, localOnly: s.demo, attachmentsDir: AppModel.attachmentsDir)
        let d = DirectMessages(engine: e)
        e.onChange = { [weak self] in DispatchQueue.main.async { self?.changed() } }
        d.onChange = { [weak self] in DispatchQueue.main.async { self?.changed() } }
        // read state across devices (SPEC 19.27): guests, guest mode and the demo keep it here
        let rs = ReadSync(engine: e, seedD: { d.readMarks })
        rs.shared = { [weak e] in !s.demo && s.reading != true && !(e?.guestMode.reading ?? false) }
        rs.onChange = { [weak self] r in DispatchQueue.main.async { self?.readChanged(r) } }
        d.readFloor = { [weak rs] conv in rs?.state.readUpTo("d", conv, now: Int.now) ?? 0 }
        readSync = rs
        e.onNewEvents = { [weak d, weak rs] list in
            if list.contains(where: { $0.kind == 1059 || $0.kind == 4 }) { Task { await d?.process() } }
            rs?.offer(list)
        }
        e.onEOSE = { [weak rs, weak self] t in
            if t == .main { rs?.relayAnswered() }
            // the groups relay answered: does it still have the groups this device knows?
            if t == .groups { Task { @MainActor in await self?.checkGroups() } }
        }
        e.onSent = { [weak d] item, _ in d?.outboxSent(item) }
        e.onFailed = { [weak d] item in d?.outboxFailed(item) }
        d.onSend = { Push.markSent() }
        // guest mode: nothing is sent until joining; a refused write opens the Join sheet
        e.guestMode.reading = s.reading == true
        e.guestMode.onRefused = { [weak self] in DispatchQueue.main.async { self?.joinAsked = true } }
        guestReading = s.reading == true
        if let ch = UserDefaults.standard.string(forKey: AppModel.openAfterSignInKey) {
            // signed in after guest mode said "this address has an account": the channel they read
            UserDefaults.standard.removeObject(forKey: AppModel.openAfterSignInKey)
            joinedChannel = ch
        }
        engine = e
        dms = d
        // offline first: the last copies at once, refreshed in the background
        roles = db.get("roles", as: RolesInfo.self) ?? RolesInfo()
        kinds = s.demo ? [:] : db.get("kinds", as: [String: String].self) ?? [:]
        groupsAbsent = db.get("groups-absent", as: [String: Int].self) ?? [:]
        presenceAt = nil
        membership = db.get("membership", as: MembershipSettings.self) ?? MembershipSettings()
        phase = .ready
        if !s.demo {
            Task {
                if let bs = signer as? BunkerSigner, s.pubkey == nil, let pk = try? await bs.ensurePubkey() { db.set("pubkey", pk) }
                if let pk = s.pubkey ?? db.get("pubkey", as: String.self) { self.accountKnown(pk) }
                await self.revalidateConfig(force: true)
                if let k = db.get("groups-key", as: String.self) { self.groupsKey = k }
                // belfry.json `groups_key` first; `_groups@domain` for a belfry not yet updated
                if let k = self.config.groupsKeyHex {
                    db.set("groups-key", k)
                    self.groupsKey = k
                } else if let k = await Discovery.nip05(name: "_groups", domain: s.domain) {
                    db.set("groups-key", k)
                    self.groupsKey = k
                }
                self.version += 1
                await self.askWhois()
                await d.loadBridge()
                self.updateAddress()
                self.describeAccount()
                await d.process()
            }
        }
        e.start()
        updateAddress()
        Task { await self.checkPush() }
    }

    /// belfry.json again (ETag, no-cache; SPEC 19.15): at start, after an admin / agent change, and
    /// when a profile or members list opens (at most every 30 s unless FORCE).
    func revalidateConfig(force: Bool = false) async {
        guard let engine, !engine.localOnly else { return }
        if !force && Date().timeIntervalSince(configCheckedAt) < 30 { return }
        configCheckedAt = Date()
        let current = config
        do {
            if let fresh = try await Discovery.revalidate(domain: current.domain, etag: current.etag) {
                engine.db.set("config", fresh)
                config = fresh
                version += 1
            }
        } catch {}
    }

    /// Ask the register who the people brought in by links or as agents are (once per session per
    /// key; KEYS again when a profile or members list opens).
    func askWhois(_ keys: [String]? = nil) async {
        guard let engine, !engine.localOnly else { return }
        let list = (keys ?? derive.guestJoinKeys).filter { keys != nil || !whoisAsked.contains($0) }
        guard !list.isEmpty else { return }
        whoisAsked.formUnion(list)
        if let got = try? await api.whois(list) {
            var k = kinds
            for p in list { k[p] = got[p] }
            // what I became through a member link stays until the register says otherwise
            if got[me] == nil, list.contains(me), kinds[me] == "member" { k[me] = "member" }
            kinds = k
            engine.db.set("kinds", k)
            version += 1
        }
    }

    /// The belfry's HTTP API, signed as me.
    var api: BelfryAPI { BelfryAPI(config: config, signer: engine?.signer, guestMode: engine?.guestMode) }

    func updateAddress() {
        guard let dms else { return }
        if let n5 = profiles[me]?.nip05, n5.contains("@") { dms.myAddress = n5.lowercased() }
        else if isDemo { dms.myAddress = "you@\(config.domain)" }
    }

    /// Signs out of the open account only (its session, store, drafts, push key are forgotten) and
    /// opens the next one on the device; the sign-in screen only when none is left.
    func signOut() {
        engine?.stop()
        if let b = engine?.signer as? BunkerSigner { b.disconnect() }
        let slot = Keychain.slot
        let wasDemo = session?.demo ?? false
        if let s = session, !s.demo {
            Drafts.clearAll()
            let cfg = config
            Task.detached {
                var req = URLRequest(url: URL(string: cfg.revoke)!, timeoutInterval: 3)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["client_id": SignIn.clientId])
                _ = try? await URLSession.shared.data(for: req)
            }
            try? FileManager.default.removeItem(at: AppModel.dbURL(s.domain, slot: slot))
            UserDefaults.standard.removeObject(forKey: AppModel.perAccount("belfry-mentions-seen"))
            // the demo is not in the list and has no Keychain item: never clear the real account's
            Keychain.clear(slot: slot)
        }
        nativeFlow.cancel()
        pendingCode = nil
        resetLive()
        var next: AccountEntry?
        if !wasDemo {
            next = accounts.remove(slot)
            saveAccounts()
        } else {
            next = accounts.open
        }
        if let next, let s = Keychain.load(slot: next.slot) {
            Keychain.slot = next.slot
            open(s)
            return
        }
        // the last one: the files waiting in the outbox went with it
        try? FileManager.default.removeItem(at: AppModel.attachmentsDir)
        Keychain.slot = ""
        phase = .signedOut
        version += 1
    }

    /// Changes the open session and keeps it (the Keychain copy of the open slot).
    func updateSession(_ change: (inout StoredSession) -> Void) {
        guard var s = session else { return }
        change(&s)
        session = s
        if !s.demo { Keychain.save(s) }
    }

    /// Forgets what the open session held in memory (its engine, caches, guest state).
    func resetLive() {
        readSync?.flush()
        readSync = nil
        engine = nil
        dms = nil
        session = nil
        cachedDerive = nil
        groupsKey = nil
        kinds = [:]
        whoisAsked = []
        cachedGroups = nil
        cachedProfiles = nil
        cachedMentions = nil
        guestReading = false
        joinAsked = false
        version += 1
    }

    static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func dbURL(_ domain: String, slot: String) -> URL { supportDir.appendingPathComponent(AccountList.dbName(domain: domain, slot: slot)) }

    static var attachmentsDir: URL {
        let u = supportDir.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // ---- demo --------------------------------------------------------------------------------------

    /// READER: as someone who opened a guest link of #general (guest mode), not as Sam.
    func startDemo(reader: Bool = false) {
        Drafts.clearAll() // the demo starts empty (only offered signed out, where drafts are gone already)
        let s = StoredSession(domain: "demo.belfry.sh", bunkerURL: nil, clientSecret: (reader ? Demo.readerSecret : Demo.meSecret).hex, pubkey: nil, demo: true,
                              reading: reader ? true : nil, guestChannel: reader ? generalId : nil)
        var cfg = BelfryConfig.defaults(domain: "demo.belfry.sh")
        cfg.name = "Riverside Commons"
        // Sam administers the demo belfry (settings, roles, requests, the charter show); the reader is a guest
        // `-member`: the same demo as a plain member (no Belfry settings, no dragging)
        cfg.admins = launch.member ? [Demo.signer("ana").pubkey] : [(try! LocalSigner(secret: Demo.meSecret)).pubkey]
        open(s, config: cfg)
        groupsKey = Demo.signer("groups").pubkey
        groupsAbsent = [Demo.deletedGroup: 0] // what the relay's answer would leave (SPEC 19.30)
        if reader { joinedChannel = generalId }
        if let e = engine, let d = dms {
            Task {
                await Demo.seed(engine: e, dms: d)
                self.updateAddress()
                // SPEC 19.37: a settings change the relay refused (the mark by the channel's name)
                if self.launch.screen?.hasPrefix("settingsfailed") == true {
                    e.demoPut(OutboxItem(target: .groups, kind: 9002, content: "",
                                         tags: [["h", "garden-3f2a"], ["name", "Garden & orchard"], ["about", "Beds, seeds, fruit trees and the watering rota"], ["open"], SyncEngine.clientTag],
                                         createdAt: Int.now - 30, status: .failed, tries: 1, error: "restricted: not an admin of this group"))
                }
            }
        }
    }

    // ---- actions -----------------------------------------------------------------------------------

    func post(_ text: String, in group: String, attachments: [Attachment] = [], announce: Bool = false, topic: String? = nil) {
        let tags = derive.eventTagsFor(text, mainRelay: config.mainRelay)
        engine?.enqueue(Actions.postMessage(group, text: text, topic: topic, announce: announce, eventTags: tags), attachments: attachments)
    }

    /// The admins' order of the channel list.
    func setChannelOrder(_ ids: [String]) { engine?.enqueue(Actions.channelOrder(ids)) }

    /// The admins' categories (SPEC 19.34): the same event, with `categories` and the flattened order.
    func setChannelLayout(_ cats: [ChannelCategory], extra: Set<String> = []) {
        let d = derive
        engine?.enqueue(Actions.channelLayout(cats, previous: d.channelLayout(), known: Set(d.townChannels().map(\.id)).union(extra)))
    }

    /// A post in a threads-only channel: a bold title line and the details, with a `subject` tag
    /// (as the web's New thread, so the channel's page and the chat read it the same).
    func postThread(title: String, text: String, in group: String, attachments: [Attachment] = []) {
        let t = String(title.jsTrim().split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(140))
        guard !t.isEmpty else { return }
        let body = "**\(t)**" + (text.jsTrim().isEmpty ? "" : "\n\n" + text.jsTrim())
        var d = Actions.postMessage(group, text: body)
        d.tags.append(["subject", t])
        engine?.enqueue(d, attachments: attachments)
    }

    /// Edit my own message or thread reply (kind 1010; SPEC 19.1).
    func edit(_ m: Message, in group: String, text: String) {
        guard derive.canEdit(m) else { return }
        engine?.enqueue(Actions.editMessage(group, m, text: text))
    }

    func pin(_ m: Message, in group: String, _ on: Bool) {
        engine?.enqueue(Actions.pinMessage(group, messageId: m.id, pin: on))
    }

    /// "Turn into a todo" (SPEC 19.11).
    func makeTodo(_ m: Message, in group: String) {
        guard derive.canMakeTodo(group, m) else { return }
        engine?.enqueue(Actions.addTask(group, title: derive.todoTitle(m), from: m.id))
    }

    func addTodo(_ title: String, in group: String) {
        let t = title.jsTrim()
        guard !t.isEmpty else { return }
        engine?.enqueue(Actions.addTask(group, title: t))
    }

    /// ACTION: claim | unclaim | done | undone | delete
    func todo(_ t: TodoTask, in group: String, _ action: String) {
        engine?.enqueue(Actions.taskAction(group, taskId: t.id, action: action))
    }

    /// Who a to-do is on (SPEC 19.41): TO = me claims it; nil lets it go / unassigns it.
    func assignTodo(_ t: TodoTask, in group: String, to: String?) {
        engine?.enqueue(Actions.assignTask(group, task: t, to: to, me: me))
    }

    func commentTodo(_ t: TodoTask, in group: String, text: String) {
        engine?.enqueue(Actions.commentTask(group, taskId: t.id, text: text))
    }

    func createPod(name: String, about: String, parent: String, closed: Bool, prompt: String) -> String {
        let id = Actions.newPodId(name)
        for d in Actions.createPod(id: id, name: name, about: about, parent: parent, access: PodAccess(closed: closed, prompt: prompt)) { engine?.enqueue(d) }
        return id
    }

    func editPod(_ id: String, name: String, about: String, closed: Bool, prompt: String) {
        editGroupMeta(id, name: name, about: about, closed: closed, prompt: prompt)
    }

    func createProposal(_ n: NewProposal, parent: String) -> String {
        let (id, drafts) = Actions.createProposal(n, parent: parent, me: me, groupsRelay: config.groupsRelay, mainRelay: config.mainRelay, now: .now)
        for d in drafts { engine?.enqueue(d) }
        return id
    }

    func reviseProposal(_ p: Proposal, title: String, summary: String, text: String, note: String) {
        for d in Actions.reviseProposal(p, title: title, summary: summary, text: text, note: note, groupsRelay: config.groupsRelay, mainRelay: config.mainRelay, now: .now) { engine?.enqueue(d) }
    }

    func vote(_ p: Proposal, _ option: String) {
        if let d = Actions.vote(p, option: option) { engine?.enqueue(d) }
    }

    func setStatus(_ p: Proposal, _ status: ProposalStatus) {
        for d in Actions.setProposalStatus(p, status) { engine?.enqueue(d) }
    }

    func apply(_ id: String, answer: String) { engine?.enqueue(Actions.join(id, answer: answer)) }
    func leave(_ id: String) { engine?.enqueue(Actions.leave(id)) }
    func admit(_ id: String, _ pk: String) { engine?.enqueue(Actions.admit(id, pubkey: pk)) }
    func declineApplicant(_ id: String, _ pk: String) { engine?.enqueue(Actions.decline(id, pubkey: pk)) }

    func pinTopic(_ topic: String, in group: String, _ on: Bool) {
        engine?.enqueue(Actions.pinTopic(group, pinned: derive.pinnedTopics(group), topic: topic, pin: on))
    }

    func setMemberLabels(_ pk: String, in group: String, labels: [String]) {
        engine?.enqueue(Actions.setMemberLabels(group, pubkey: pk, labels: labels))
    }

    /// Drop a message that could not be sent (its outbox item).
    func discard(_ localId: String) { engine?.cancel(localId) }

    func assignCard(_ card: Message, in group: String, to assignee: String) {
        engine?.enqueue(Actions.assignCard(group, card: card.id, assignee: assignee))
    }

    func setCard(_ card: Message, in group: String, closed: Bool) {
        engine?.enqueue(Actions.setCardStatus(group, card: card.id, closed: closed))
    }

    /// Answer an inbox card by e-mail as the channel (after the 8 s undo). Fixed messages only.
    /// "Re: <the subject of the latest e-mail received>" (as mail programs do).
    static func replySubject(_ t: InboxThread) -> String {
        let base = MailThreads.baseSubject(t.lastIn?.subject)
        return "Re: " + (base.isEmpty ? (t.subject.isEmpty ? "(no subject)" : t.subject) : base)
    }

    /// Answer an e-mail thread by e-mail as the channel (its admins; SPEC 19.33): from the
    /// channel's plain address, In-Reply-To = the latest e-mail received, References = the thread's
    /// earlier ones. The demo posts what the bridge would.
    func sendThreadMail(_ t: InboxThread, in group: String, text: String) async -> Result<String, ApiError> {
        guard let dms, let to = t.lastIn else { return .failure(ApiError("signer", 0, "Not signed in.")) }
        let d = derive
        let subject = AppModel.replySubject(t)
        let refs = t.refs.filter { $0 != to.messageId }.suffix(10).joined(separator: " ")
        if isDemo {
            let mid = "<\(UUID().uuidString.lowercased())@\(config.domain)>"
            if let e = try? Demo.signer("groups").signNow(EventTemplate(kind: 9, content: text, tags: [["h", group], ["subject", subject], ["mail-to", to.address],
                ["sent-by", me], ["message-id", mid], ["e", to.m.id, "", "reply"], ["client", "belfry-mail-out"]], createdAt: Int.now)) {
                engine?.add([e], verify: false)
            }
            return .success("")
        }
        do {
            let id = try await dms.sendAsChannel(channel: group, local: d.mailLocal(group), channelName: self.group(group)?.name ?? group, to: to.address,
                                                 subject: subject, text: text, inReplyTo: to.messageId, references: refs.isEmpty ? nil : refs,
                                                 cardId: to.m.id, myName: realName(me))
            return .success(id)
        } catch let e as BelfryError {
            return .failure(ApiError("mail", 0, e.errorDescription ?? "The e-mail could not be prepared. Try again."))
        } catch {
            return .failure(ApiError("mail", 0, "The e-mail could not be prepared. Try again."))
        }
    }

    /// "Kofi", or the start of their key (never "You").
    func realNameOrKey(_ pk: String) -> String {
        let n = realName(pk)
        return n.isEmpty ? Derive.shortKey(pk) : n
    }

    /// Someone to write to (a NIP-17 conversation), from a message menu or a profile.
    @Published var messageAuthor: String?
    /// The last "Make this the website" answer (a fixed message), shown once.
    @Published var website: String?

    func publishWebsite(ref: String, message: String) async -> String {
        guard let engine, !engine.localOnly else { return "Demo mode publishes nothing." }
        do {
            try await api.publishWebsite(ref: ref, messageId: message)
            return "Published: it is the website now."
        } catch let e as ApiError {
            return e.message
        } catch {
            return BelfryAPI.generic
        }
    }

    /// Bring someone who is here already into a channel (SPEC 19.15): a guest becomes its guest
    /// (`/channel-guests`); a member gets a direct message with the link (in a closed group I
    /// administer they are let in first). Returns a fixed line saying what happened.
    func inviteHere(_ pk: String, to groupId: String) async -> String {
        let d = derive
        let g = d.group(groupId)
        if d.isGuest(pk) {
            if engine?.localOnly == true { return "Added as a guest (demo)." }
            do {
                let r = try await api.addChannelGuest(channel: groupId, pubkey: pk)
                if !r.member { return r.already ? "They're in already." : "Added as a guest." }
            } catch let e as ApiError {
                return e.message
            } catch {
                return BelfryAPI.generic
            }
        }
        var asked = false
        if let g, g.closed {
            if d.canAdmin(g) { engine?.enqueue(Actions.admit(groupId, pubkey: pk)) } else { asked = true }
        }
        guard let dms else { return "Not signed in." }
        do {
            try await dms.send(d.inviteText(groupId, asked: asked), in: MailThreads.nostrConv(author: pk, pTags: [], me: me))
            return asked ? "Sent: they can ask to join." : "Invited: they got a message with the link."
        } catch {
            return "The invite could not be sent. Try again."
        }
    }

    /// RSVP: a member's on the community relay, a guest's on the groups relay (SPEC 19.18).
    func rsvp(_ e: CalEvent, _ r: Rsvp) {
        let d = derive
        let ticket = e.isNew ? d.eventPeople(e).holders[me] : nil
        engine?.enqueue(EventActions.rsvp(e, r, me: me, ticketD: ticket, onGroups: e.remote || d.amGuest, eventPending: d.isPending(e.ev.id)))
    }

    /// Opens a channel's events list (All events of that channel), from the pull-down.
    @Published var showEvents: String?

    /// An event to show (its coordinate or link), from a card anywhere: pushed on the main stack.
    @Published var openEvent: String?
    /// With `openEvent`: a ticket's code from a scanned / opened ticket link (never shown).
    var openEventTicket: String?
    /// What the belfry said about me per event (`viewer`), kept on the phone (SPEC 19.29).
    @Published var eventViewers = [String: EventViewer]()
    /// The check-in list per event (its d), from the last answer.
    @Published var attendeeLists = [String: AttendeeList]()
    /// Screenshots: the event screen's level / tab / sheet to show.
    var launchEventDone = false
    /// Screenshots: open the delete confirmation / the ＋ menu once.
    @Published var launchDelete = false
    @Published var launchAdd = false
    @Published var launchSettings = false
    @Published var launchMeetingForm = false
    @Published var launchEventForm = false

    // ---- pins I hid on this phone ("Got it, hide"; at most 200; SPEC 19.10) ---------------------

    @Published private(set) var hiddenPins: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "belfry-pins-hidden") ?? [])

    func hidePin(_ id: String) {
        var list = UserDefaults.standard.stringArray(forKey: "belfry-pins-hidden") ?? []
        list.removeAll { $0 == id }
        list.append(id)
        list = Array(list.suffix(200))
        UserDefaults.standard.set(list, forKey: "belfry-pins-hidden")
        hiddenPins = Set(list)
    }

    func reply(_ text: String, in group: String, to root: Message) {
        engine?.enqueue(Actions.postThreadReply(group, rootId: root.ev.id, rootPubkey: root.ev.pubkey, rootKind: root.ev.kind, text: text))
    }

    func toggleReaction(_ emoji: String, on m: Message, in group: String) {
        guard let engine else { return }
        let mine = derive.reactions(group)[m.id]?.first { $0.emoji == emoji }?.mine
        if let mine {
            if engine.pending(mine) != nil { engine.cancel(mine); return }
            engine.enqueue(Actions.unreact(group, reactionId: mine))
        } else {
            EmojiUsage.used(emoji)
            engine.enqueue(Actions.react(group, messageId: m.ev.id, author: m.ev.pubkey, emoji: emoji))
        }
    }

    func delete(_ m: Message, in group: String) {
        if let p = engine?.pending(m.id) { engine?.cancel(p.localId); return }
        engine?.enqueue(Actions.deleteMessage(group, id: m.id))
    }

    func retry(_ localId: String) { engine?.retry(localId) }

    func createChannel(name: String, about: String, category: String? = nil) -> String {
        let id = Actions.newChannelId(name)
        for d in Actions.createChannel(id: id, name: name, about: about) { engine?.enqueue(d) }
        // made with a category's ＋ by a belfry admin: the order event puts it at the end of that
        // category (queued after the channel's own events; an id not yet known is kept, not lost)
        if let category, derive.isCommunityAdmin {
            setChannelLayout(Categories.put(id, in: category, derive.channelCategories()), extra: [id])
        }
        return id
    }

    func editChannel(_ id: String, name: String, about: String, inbox: Bool?) {
        editGroupMeta(id, name: name, about: about)
        if let inbox, inbox != derive.isInbox(group(id)) { engine?.enqueue(Actions.setInbox(id, on: inbox)) }
    }

    func join(_ id: String) { engine?.enqueue(Actions.join(id)) }
    func editChannelInbox(_ id: String, _ on: Bool) { engine?.enqueue(Actions.setInbox(id, on: on)) }

    /// Public or members only (SPEC 19.38): the channel's web settings, never retroactive.
    func setVisibility(_ id: String, public pub: Bool) {
        guard let g = group(id), let d = Actions.setVisibility(g, public: pub, derive: derive, now: .now) else { return }
        engine?.enqueue(d)
    }

    /// Opening a channel tells it, at most every 6 hours.
    func markSeen(_ id: String) {
        if guestReading { return } // guest mode: reading leaves no trace
        guard let g = group(id), !(g.type == .pod && g.closed && !g.members.contains(me)) else { return }
        let now = Int.now
        guard Actions.shouldMarkSeen(now: now, mySeen: derive.mySeen(id), lastSentHere: seenSentHere[id] ?? 0) else { return }
        seenSentHere[id] = now
        engine?.enqueue(Actions.seen(id))
    }

    func refresh() async {
        await engine?.refresh()
        await dms?.process()
    }

    func wake() { engine?.wake() }

    /// A guest link for a channel (SPEC 13). Errors are fixed messages chosen by the server's code.
    func guestLink(_ channel: String) async -> Result<String, GuestLinkError> {
        guard let engine else { return .failure(.network) }
        if engine.localOnly { return .success("https://\(config.domain)/invite/demo-guest-link") }
        do {
            let (data, status) = try await engine.signedRequest(config.channelInvites, method: "POST", json: ["channel": channel])
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if status == 200, let u = obj["url"] as? String, u.hasPrefix("https://") { return .success(u) }
            return .failure(GuestLinkError(code: obj["error"] as? String))
        } catch {
            return .failure(.network)
        }
    }

    // ---- attachments -------------------------------------------------------------------------------

    func saveAttachment(_ data: Data, name: String, mime: String, width: Int?, height: Int?) -> Attachment? {
        let file = Crypto.random(8).hex + "-" + name.replacingOccurrences(of: "/", with: "_")
        do { try data.write(to: AppModel.attachmentsDir.appendingPathComponent(file)) } catch { return nil }
        return Attachment(file: file, name: name, mime: mime, size: data.count, width: width, height: height)
    }
}

enum GuestLinkError: Error, Equatable {
    case network, guest, notAllowed, noChannel, unsupported, refused, unknown

    init(code: String?) {
        switch code {
        case "guest": self = .guest
        case "not_allowed": self = .notAllowed
        case "no_channel": self = .noChannel
        case "unsupported": self = .unsupported
        case "refused": self = .refused
        default: self = .unknown
        }
    }

    var message: String {
        switch self {
        case .network: return "No connection to the belfry."
        case .guest: return "Guests can't invite guests."
        case .notAllowed: return "You can't invite guests here."
        case .noChannel: return "This channel isn't on the belfry yet. Try again in a moment."
        case .unsupported: return "This belfry doesn't offer guest links yet."
        case .refused: return "The belfry refused to make a guest link."
        case .unknown: return "The guest link could not be made."
        }
    }
}

/// The emojis you use most come first.
enum EmojiUsage {
    static let key = "belfry-emoji-usage"
    static func used(_ e: String) {
        var u = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        u[e, default: 0] += 1
        UserDefaults.standard.set(u, forKey: key)
    }
    static func top(_ n: Int = 6) -> [String] {
        let u = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        var out = [String]()
        for e in u.sorted(by: { $0.value > $1.value }).map(\.key) + Actions.defaultEmojis where !out.contains(e) { out.append(e) }
        return Array(out.prefix(n))
    }
}

/// Launch arguments for tests and screenshots: -demo, -screen <name>.
struct LaunchOptions {
    let demo: Bool
    let screen: String?
    /// `-signin code` / `-signin older`: the sign-in screens with made-up state, for screenshots.
    let signin: String?
    /// `-guest opening|feed|join|code`: guest mode's screens in demo mode (SPEC 19.26).
    let guest: String?
    /// `-member`: the demo's Sam is not an admin of the belfry (the member's drawer).
    let member: Bool
    /// `-join member`: the demo invite is a belfry member link (SPEC 19.43).
    let joinMember: Bool

    init() {
        let args = ProcessInfo.processInfo.arguments
        demo = args.contains("-demo")
        member = args.contains("-member")
        if let i = args.firstIndex(of: "-join"), i + 1 < args.count { joinMember = args[i + 1] == "member" } else { joinMember = false }
        if let i = args.firstIndex(of: "-screen"), i + 1 < args.count { screen = args[i + 1] } else { screen = nil }
        if let i = args.firstIndex(of: "-signin"), i + 1 < args.count { signin = args[i + 1] } else { signin = nil }
        if let i = args.firstIndex(of: "-guest"), i + 1 < args.count { guest = args[i + 1] } else { guest = nil }
    }
}
