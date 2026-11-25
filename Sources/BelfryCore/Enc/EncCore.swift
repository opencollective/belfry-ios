import Foundation

// Encrypted conversations, format 3: one key per conversation (collective-belfry docs/encrypted.md
// with its §16–§28 readings; SPEC 19.70). The pure rules: device lists (8570), conversation keys and
// their envelopes (8571), messages (8572), key packs (8573), asks and answers (8574, 8575). No
// storage, no network. A port of the web's src/core/enc/core.ts (chat c8703b4); Android's World/enc
// as a second reading; vectors/encrypted.json = the web's, copied byte for byte.
//
// Never log or throw a secret or a rumor's text: errors here say what failed only.

public enum Enc {
    public static let list = 8570, key = 8571, msg = 8572, pack = 8573, ask = 8574, answer = 8575
    public static let seal = 13
    public static let maxList = 20
    public static let maxPeopleDevices = 100
    public static let maxGroupDevices = 1000
    public static let keyAge = 30 * 86400
    public static let grace = 600
    public static let maxEnvelope = 60_000
    public static let maxPack = 40_000
    public static let maxRumor = 40_000
    public static let future = 900
    public static let skew = 300
    public static let silent: Tag = ["silent", "1"]

    /// What would otherwise be random (the vectors fix it).
    public struct Fixed: Sendable {
        public var at: Int?
        public var sealAt: Int?
        public var oneTime: Data?
        public var nonce: (@Sendable (Int) -> Data)?
        public var aux: Data?
        public init(at: Int? = nil, sealAt: Int? = nil, oneTime: Data? = nil, nonce: (@Sendable (Int) -> Data)? = nil, aux: Data? = nil) {
            self.at = at; self.sealAt = sealAt; self.oneTime = oneTime; self.nonce = nonce; self.aux = aux
        }
    }

    public enum Failure: Error, Equatable { case notAnEnvelope, entryDoesNotOpen, sealNotSigned, sealDoesNotOpen, notTheSigners, notThisGroup, notThisKey, notAMessage, tooLong, badKey }

    // ---- small tools -------------------------------------------------------------------------

    static let hex64 = Rx("^[0-9a-f]{64}$")
    public static func isKey(_ s: String?) -> Bool { s.map { hex64.test($0) } ?? false }
    static let nRx = Rx("^[1-9][0-9]{0,8}$")
    static func values(_ tags: [Tag], _ name: String) -> [String] { tags.filter { $0.count > 1 && $0[0] == name }.map { $0[1] } }
    static func one(_ tags: [Tag], _ name: String) -> String? { let v = values(tags, name); return v.count == 1 ? v[0] : nil }
    static func now0() -> Int { Int(Date().timeIntervalSince1970) }
    static func utf8(_ s: String) -> Int { s.utf8.count }

    public static func pub(_ secret: Data) -> String { (try? Keys.publicKeyHex(secret: secret)) ?? "" }
    public static func pub(hex: String) -> String? { Data(hex: hex).flatMap { try? Keys.publicKeyHex(secret: $0) } }

    static func conv(_ secret: Data, _ pub: String) throws -> Data {
        guard let p = Data(hex: pub), p.count == 32 else { throw Failure.badKey }
        return try NIP44.conversationKey(secret: secret, publicKey: p)
    }
    static func encrypt(_ text: String, _ secret: Data, _ pub: String, _ nonce: Data?) throws -> String {
        let c = try conv(secret, pub)
        if let nonce { return try NIP44.encrypt(text, conversationKey: c, nonce: nonce) }
        return try NIP44.encrypt(text, conversationKey: c)
    }
    static func decrypt(_ payload: String, _ secret: Data, _ pub: String) throws -> String {
        try NIP44.decrypt(payload, conversationKey: conv(secret, pub))
    }

    /// An event signed by SECRET (aux fixed by the vectors).
    public static func signWith(_ secret: Data, kind: Int, createdAt: Int, tags: [Tag], content: String, aux: Data? = nil) throws -> NostrEvent {
        var e = NostrEvent(pubkey: try Keys.publicKeyHex(secret: secret), createdAt: createdAt, kind: kind, tags: tags, content: content)
        e.id = e.computedId
        e.sig = try Keys.sign(message: Data(hex: e.id)!, secret: secret, aux: aux ?? Crypto.random(32)).hex
        return e
    }

    /// The JSON of a signed event as the web writes it (JSON.stringify of signWith's object):
    /// keys kind, created_at, tags, content, pubkey, id, sig.
    public static func eventJSON(_ e: NostrEvent) -> String {
        "{\"kind\":\(e.kind),\"created_at\":\(e.createdAt),\"tags\":[" + e.tags.map { "[" + $0.map(JSON.string).joined(separator: ",") + "]" }.joined(separator: ",")
            + "],\"content\":\(JSON.string(e.content)),\"pubkey\":\(JSON.string(e.pubkey)),\"id\":\(JSON.string(e.id)),\"sig\":\(JSON.string(e.sig))}"
    }

    /// A rumor with its id (unsigned).
    public static func withId(_ r: NostrEvent) -> NostrEvent { var x = r; x.sig = ""; x.id = x.computedId; return x }
    /// The rumor as it goes into a seal: id, pubkey, created_at, kind, tags, content.
    public static func rumorJSON(_ r: NostrEvent) -> String { Sealed.json(r) }

    /// A signed event from JSON, id and signature checked; nil otherwise.
    static func validEvent(_ json: String) -> NostrEvent? {
        guard let d = json.data(using: .utf8), let e = try? JSONDecoder().decode(NostrEvent.self, from: d), isKey(e.pubkey), isKey(e.id), e.isValid else { return nil }
        return e
    }
    static func valid(_ e: NostrEvent) -> Bool { isKey(e.pubkey) && isKey(e.id) && e.isValid }
    /// A rumor from JSON (any id given is recomputed).
    static func rumor(_ json: String) throws -> NostrEvent {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw Failure.notAnEnvelope }
        return try rumor(o)
    }
    static func rumor(_ o: [String: Any]) throws -> NostrEvent {
        guard let pk = o["pubkey"] as? String, isKey(pk), let at = (o["created_at"] as? NSNumber)?.intValue, let k = (o["kind"] as? NSNumber)?.intValue,
              let content = o["content"] as? String, let raw = o["tags"] as? [Any] else { throw Failure.notAnEnvelope }
        var tags = [Tag]()
        for t in raw { guard let a = t as? [String] else { throw Failure.notAnEnvelope }; tags.append(a) }
        return withId(NostrEvent(pubkey: pk, createdAt: at, kind: k, tags: tags, content: content))
    }

    // ---- §3 device lists ---------------------------------------------------------------------

    public struct DeviceList: Equatable, Sendable {
        public let id: String
        public let account: String
        public let n: Int
        public let prev: String?
        public let devices: [String]
        public let readers: [String]
        public let createdAt: Int
    }

    /// E as a device list of the belfry BELFRY, or nil (the web's parseList).
    public static func parseList(_ e: NostrEvent, belfry: String) -> DeviceList? {
        guard valid(e), e.kind == list, e.pubkey == belfry, e.content.isEmpty else { return nil }
        let prevs = values(e.tags, "prev")
        guard let account = one(e.tags, "p"), isKey(account), let n = one(e.tags, "n"), nRx.test(n), let num = Int(n) else { return nil }
        if num == 1 ? !prevs.isEmpty : (prevs.count != 1 || !isKey(prevs[0])) { return nil }
        var devices = [String](), readers = [String]()
        for t in e.tags where t.first == "device" {
            guard t.count >= 2, isKey(t[1]), t.count <= 3 else { return nil }
            if t.count == 3 && t[2] == "self" && t[1] != account { return nil }
            if t.count == 3 && t[2] != "reader" && t[2] != "self" { continue }
            if devices.contains(t[1]) || readers.contains(t[1]) { return nil }
            if t.count == 3 && t[2] == "reader" { readers.append(t[1]) } else { devices.append(t[1]) }
        }
        if devices.count > maxList { return nil }
        if e.tags.contains(where: { $0.count == 3 && $0[0] == "device" && $0[2] == "self" }) && devices.count != 1 { return nil }
        return DeviceList(id: e.id, account: account, n: num, prev: num > 1 ? prevs[0] : nil, devices: devices, readers: readers, createdAt: e.createdAt)
    }

    public struct Chain: Equatable, Sendable {
        public let account: String
        public let lists: [DeviceList]
        public let gaps: Bool
        public let fork: Bool
        public let invalidAbove: Bool
        public var current: DeviceList { lists[lists.count - 1] }
        public func list(_ id: String) -> DeviceList? { lists.first { $0.id == id } }
    }

    /// §20: an account's devices are its chain, the service key (its own device), or unknown (Held).
    public enum Devices: Equatable, Sendable { case chain(Chain), service, unknown }

    public static func chainOf(_ events: [NostrEvent], belfry: String, account: String) -> Chain? {
        var byN = [Int: [DeviceList]]()
        var badTop = 0
        for e in events {
            guard let l = parseList(e, belfry: belfry) else {
                if valid(e), e.kind == list, e.pubkey == belfry, e.tags.contains(where: { $0.count > 1 && $0[0] == "p" && $0[1] == account }),
                   let n = e.tags.first(where: { $0.first == "n" }).flatMap({ $0.count > 1 ? Int($0[1]) : nil }), n > badTop { badTop = n }
                continue
            }
            guard l.account == account else { continue }
            var at = byN[l.n] ?? []
            if !at.contains(where: { $0.id == l.id }) { at.append(l) }
            byN[l.n] = at
        }
        if byN.isEmpty { return nil }
        var fork = false
        let lists: [DeviceList] = byN.keys.sorted().map { n in
            let c = byN[n]!.sorted { $0.id < $1.id }
            if c.count > 1 { fork = true }
            return c[0]
        }
        for (i, l) in lists.enumerated() where i > 0 {
            let b = lists[i - 1]
            if b.n == l.n - 1 && l.prev != b.id { fork = true }
        }
        let top = lists[lists.count - 1].n
        return Chain(account: account, lists: lists, gaps: lists.count < top, fork: fork, invalidAbove: badTop > top)
    }

    public struct Change: Equatable, Sendable { public let list: String; public let n: Int; public let added: [String]; public let removed: [String]; public let readersAdded: [String] }

    /// §17.7 what each list added and removed against the one before.
    public static func changes(_ c: Chain) -> [Change] {
        guard c.lists.count > 1 else { return [] }
        return (1..<c.lists.count).map { i in
            let l = c.lists[i], b = c.lists[i - 1]
            return Change(list: l.id, n: l.n, added: l.devices.filter { !b.devices.contains($0) }, removed: b.devices.filter { !l.devices.contains($0) },
                          readersAdded: l.readers.filter { !b.readers.contains($0) })
        }
    }

    /// §17.6 / §20: OLDER was first listed before DEVICE first was.
    public static func listedBefore(_ c: Chain, older: String, device: String) -> Bool {
        let a = c.lists.firstIndex { $0.devices.contains(older) }, b = c.lists.firstIndex { $0.devices.contains(device) }
        guard let a, let b else { return false }
        return a < b
    }

    public static func receivers(_ l: DeviceList) -> [String] { l.devices + l.readers }

    /// §6 / §18.2 / §20 / §21: DEVICE may sign for the account at AT (the outer event's date).
    /// nil: can't tell yet.
    public static func signsAt(_ c: Chain, device: String, at: Int) -> Bool? {
        let v = listedAt(c, device: device, at: at)
        if v != false { return v }
        if !c.lists.contains(where: { $0.devices.contains(device) || $0.readers.contains(device) }) && at >= c.current.createdAt { return nil }
        return false
    }

    /// §16.2 / §21: DEVICE was on the list current at AT (with the graces). nil: a list around AT may be missing.
    public static func listedAt(_ c: Chain, device: String, at atIn: Int) -> Bool? {
        var at = atIn
        for (i, l) in c.lists.enumerated() {
            let before = i > 0 ? c.lists[i - 1].devices.contains(device) : false
            if l.devices.contains(device) && !before && at < l.createdAt && l.createdAt <= at + skew { at = l.createdAt; break }
        }
        var i = -1
        for (j, l) in c.lists.enumerated() where l.createdAt <= at { i = j }
        if i < 0 { return c.lists[0].n == 1 ? false : nil }
        if i + 1 < c.lists.count, c.lists[i + 1].n != c.lists[i].n + 1 { return nil }
        if c.lists[i].devices.contains(device) { return true }
        guard i > 0, c.lists[i - 1].n == c.lists[i].n - 1 else { return c.lists[i].n == 1 ? false : nil }
        return c.lists[i - 1].devices.contains(device) && at <= c.lists[i].createdAt + grace
    }

    // ---- §5 names ----------------------------------------------------------------------------

    public static func alias(_ K: String, _ account: String) -> String { Crypto.sha256(Data("belfry:key:\(K):\(account)".utf8)).hex }
    public static func listsHash(_ lists: [(account: String, id: String)]) -> String {
        Crypto.sha256(Data(lists.map { "\($0.account):\($0.id)" }.sorted().joined(separator: "\n").utf8)).hex
    }
    public static func peopleId(_ accounts: [String]) -> String { Array(Set(accounts)).sorted().joined(separator: ",") }
    public static func peopleOf(_ r: NostrEvent) -> String { peopleId([r.pubkey] + values(r.tags, "p").filter { isKey($0) }) }
    public static func peopleLists(_ lists: [(account: String, id: String)]) -> String { lists.map { "\($0.account):\($0.id)" }.sorted().joined(separator: "\n") }
    public static func deviceSet(_ devices: [String]) -> String { Crypto.sha256(Data(Array(Set(devices)).sorted().joined(separator: "\n").utf8)).hex }

    // ---- §5 conversation keys ----------------------------------------------------------------

    public static func newKey(_ secret: Data = Crypto.random(32)) -> (k: String, K: String) { (secret.hex, pub(secret)) }

    /// §5 the key rumor of a people conversation, made by the device MAKER.
    public static func keyRumor(maker: String, k: String, people: [(account: String, list: String?)], at: Int = now0()) -> NostrEvent {
        let K = pub(hex: k) ?? ""
        let tags: [Tag] = [["K", K]] + people.map { ["p", $0.account] } + people.compactMap { p in p.list.map { ["list", p.account, $0] } }
        return withId(NostrEvent(pubkey: maker, createdAt: at, kind: key, tags: tags, content: k))
    }

    public enum Verdict: String, Sendable { case ok, wait, no }

    /// §5 + §16.2 + §17 + §20: may RECEIVER take this people key rumor?
    public static func acceptKeyRumor(_ r: NostrEvent, receiver: String, devices: (String) -> Devices, now: Int = now0()) -> Verdict {
        guard r.kind == key, isKey(r.content), r.createdAt <= now + future, let K = one(r.tags, "K"), let p = pub(hex: r.content), K == p else { return .no }
        let people = values(r.tags, "p")
        guard people.contains(receiver), people.allSatisfy({ isKey($0) }) else { return .no }
        var wait = false
        for a in people {
            let c = devices(a)
            if c == .service { if r.pubkey == a { return .ok }; continue }
            guard let named = r.tags.first(where: { $0.count > 2 && $0[0] == "list" && $0[1] == a })?[2] else { continue }
            guard case .chain(let chain) = c else { wait = true; continue }
            guard let l = chain.list(named) else { wait = true; continue }
            if l.devices.contains(r.pubkey) { return .ok }
        }
        return wait ? .wait : .no
    }

    /// DEVICES' entries in chunks whose JSON stays under maxEnvelope bytes (the web's split).
    static func split(_ devices: [String], _ entry: (Int, String) throws -> String) rethrows -> [[(String, String)]] {
        var out: [[(String, String)]] = [[]]
        var size = 2
        for d in devices {
            var v = try entry(out.count - 1, d)
            let add = d.count + utf8(v) + 6
            if size + add > maxEnvelope && !out[out.count - 1].isEmpty { out.append([]); size = 2; v = try entry(out.count - 1, d) }
            out[out.count - 1].append((d, v))
            size += d.count + utf8(v) + 6
        }
        return out
    }
    static func mapJSON(_ m: [(String, String)], extra: [(String, String)] = []) -> String {
        "{" + (m + extra).map { JSON.string($0.0) + ":" + JSON.string($0.1) }.joined(separator: ",") + "}"
    }

    /// §5 people envelopes: per person, kind 8571 by a one-time key, ["p", account], ["d", alias],
    /// content {device: nip44(one-time → device, seal by MAKER of the key rumor)}.
    public static func peopleEnvelopes(maker: Data, rumor r: NostrEvent, people: [(account: String, devices: [String])], fixed f: Fixed? = nil) throws -> [NostrEvent] {
        guard let K = one(r.tags, "K") else { throw Failure.badKey }
        let now = f?.at ?? now0()
        var out = [NostrEvent]()
        var n = 0
        func nonce() -> Data? { defer { n += 1 }; return f?.nonce?(n) }
        for p in people {
            var seals = [String: String]()
            for d in p.devices {
                let s = try signWith(maker, kind: seal, createdAt: f?.sealAt ?? now, tags: [], content: try encrypt(rumorJSON(r), maker, d, nonce()), aux: f?.aux)
                seals[d] = eventJSON(s)
            }
            var onces = [Int: Data]()
            func onceOf(_ i: Int) -> Data { if let o = onces[i] { return o }; let o = f?.oneTime ?? Crypto.random(32); onces[i] = o; return o }
            let chunks = try split(p.devices) { i, d in try encrypt(seals[d]!, onceOf(i), d, nonce()) }
            for (i, content) in chunks.enumerated() {
                out.append(try signWith(onceOf(i), kind: key, createdAt: now, tags: [["p", p.account], ["d", alias(K, p.account)]], content: mapJSON(content), aux: f?.aux))
            }
        }
        return out
    }

    static func entries(_ content: String) -> [String: Any]? {
        guard let d = content.data(using: .utf8), let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return m
    }

    /// My entry of a people envelope: (seal, key rumor), nil when there is none for this device.
    public static func openPeopleEnvelope(device: Data, _ env: NostrEvent) throws -> (seal: NostrEvent, rumor: NostrEvent)? {
        guard valid(env), env.kind == key, let map = entries(env.content) else { throw Failure.notAnEnvelope }
        guard let entry = map[pub(device)] as? String else { return nil }
        guard let sealJSON = try? decrypt(entry, device, env.pubkey) else { throw Failure.entryDoesNotOpen }
        guard let s = validEvent(sealJSON), s.kind == seal else { throw Failure.sealNotSigned }
        guard let inner = try? decrypt(s.content, device, s.pubkey), let r = try? rumor(inner) else { throw Failure.sealDoesNotOpen }
        guard r.pubkey == s.pubkey else { throw Failure.notTheSigners }
        return (s, r)
    }

    /// §16.1 + §18.4 group envelopes, unsigned (the maker's account signs them through the signer).
    public static func groupEnvelopes(maker: Data, k: String, group: String, devices: [String], lists: String, fixed f: Fixed? = nil) throws -> [EventTemplate] {
        guard let K = pub(hex: k) else { throw Failure.badKey }
        let body = "{\"k\":\(JSON.string(k)),\"K\":\(JSON.string(K)),\"h\":\(JSON.string(group)),\"set\":\(JSON.string(deviceSet(devices)))}"
        var n = 0
        let tags: [Tag] = [["h", group], ["d", K], ["maker", pub(maker)], ["lists", lists]]
        let chunks = try split(devices) { _, d in defer { n += 1 }; return try encrypt(body, maker, d, f?.nonce?(n)) }
        return chunks.map { EventTemplate(kind: key, content: mapJSON($0), tags: tags, createdAt: f?.at ?? now0()) }
    }

    /// The device keys that have an entry, over every envelope event of one key.
    public static func entryKeys(_ envs: [NostrEvent]) -> [String] {
        var out = Set<String>()
        for e in envs where valid(e) && e.kind == key { for k in (entries(e.content) ?? [:]).keys where isKey(k) { out.insert(k) } }
        return out.sorted()
    }

    public struct GroupKey: Equatable, Sendable {
        public let k: String, K: String, group: String, maker: String, account: String, at: Int, set: String
    }

    /// My entry of a group envelope found in GROUP; nil when there is none for this device.
    public static func openGroupEnvelope(device: Data, _ env: NostrEvent, group: String) throws -> GroupKey? {
        guard valid(env), env.kind == key else { throw Failure.notAnEnvelope }
        guard one(env.tags, "h") == group, let d = one(env.tags, "d"), isKey(d), let maker = one(env.tags, "maker"), isKey(maker) else { throw Failure.notThisGroup }
        guard let map = entries(env.content) else { throw Failure.notAnEnvelope }
        guard let entry = map[pub(device)] as? String else { return nil }
        guard let plain = try? decrypt(entry, device, maker), let x = entries(plain) else { throw Failure.entryDoesNotOpen }
        guard let k = x["k"] as? String, isKey(k), x["K"] as? String == d, x["h"] as? String == group, let set = x["set"] as? String, isKey(set),
              pub(hex: k) == d else { throw Failure.notThisKey }
        return GroupKey(k: k, K: d, group: group, maker: maker, account: env.pubkey, at: env.createdAt, set: set)
    }

    /// §16.2: the maker was a device of the envelope's account at its date.
    public static func acceptGroupKey(_ key: GroupKey, devices: Devices, now: Int = now0()) -> Verdict {
        if key.at > now + future { return .no }
        switch devices {
        case .service: return key.maker == key.account ? .ok : .no
        case .unknown: return .wait
        case .chain(let c):
            guard let v = listedAt(c, device: key.maker, at: key.at) else { return .wait }
            return v ? .ok : .no
        }
    }

    // ---- §6 messages ---------------------------------------------------------------------------

    static func sealFor(_ device: Data, _ r: NostrEvent, _ K: String, _ f: Fixed?, _ i: Int) throws -> NostrEvent {
        let json = rumorJSON(r)
        guard utf8(json) <= maxRumor else { throw Failure.tooLong }
        return try signWith(device, kind: seal, createdAt: f?.sealAt ?? f?.at ?? now0(), tags: [], content: try encrypt(json, device, K, f?.nonce?(i)), aux: f?.aux)
    }

    /// §6 people: one 8572 per person (the sender's own copy silent), each under its own one-time key.
    public static func peopleMessage(device: Data, rumor: NostrEvent, K: String, people: [String], me: String, fixed f: Fixed? = nil) throws -> [NostrEvent] {
        let r = withId(rumor)
        let s = eventJSON(try sealFor(device, r, K, f, 0))
        return try people.enumerated().map { i, a in
            let once = f?.oneTime ?? Crypto.random(32)
            return try signWith(once, kind: msg, createdAt: f?.at ?? now0(), tags: [["p", a], ["d", alias(K, a)]] + (a == me ? [silent] : []),
                                content: try encrypt(s, once, K, f?.nonce?(100 + i)), aux: f?.aux)
        }
    }

    /// §6 group: one 8572 by the sender's account (unsigned: the signer signs it); p per mention (§17.14).
    public static func groupMessage(device: Data, rumor: NostrEvent, K: String, group: String, fixed f: Fixed? = nil, mentions: [String] = []) throws -> EventTemplate {
        let r = withId(rumor)
        var seen = Set<String>()
        let m = mentions.filter { isKey($0) && seen.insert($0).inserted }
        return EventTemplate(kind: msg, content: eventJSON(try sealFor(device, r, K, f, 0)), tags: [["h", group], ["d", K]] + m.map { ["p", $0] }, createdAt: f?.at ?? now0())
    }

    /// The key a message names (its d: an alias for people, K for a group).
    public static func named(_ e: NostrEvent) -> String? { one(e.tags, "d") }

    static func openSeal(_ k: String, _ sealJSON: String) throws -> (seal: NostrEvent, rumor: NostrEvent) {
        guard let s = validEvent(sealJSON), s.kind == seal else { throw Failure.sealNotSigned }
        guard let kd = Data(hex: k), let inner = try? decrypt(s.content, kd, s.pubkey), let r = try? rumor(inner) else { throw Failure.sealDoesNotOpen }
        return (s, r)
    }
    public static func openPeopleMessage(k: String, _ m: NostrEvent) throws -> (seal: NostrEvent, rumor: NostrEvent) {
        guard valid(m), m.kind == msg else { throw Failure.notAMessage }
        guard let kd = Data(hex: k), let s = try? decrypt(m.content, kd, m.pubkey) else { throw Failure.sealDoesNotOpen }
        return try openSeal(k, s)
    }
    public static func openGroupMessage(k: String, _ m: NostrEvent) throws -> (seal: NostrEvent, rumor: NostrEvent) {
        guard valid(m), m.kind == msg else { throw Failure.notAMessage }
        return try openSeal(k, m.content)
    }

    /// §6 + §18.2: people: the signer signs for rumor.pubkey at the outer date; the rumor's people are the key's.
    public static func acceptPeopleMessage(outer: NostrEvent, seal: NostrEvent, rumor: NostrEvent, keyPeople: String, devices: Devices) -> Verdict {
        guard peopleOf(rumor) == keyPeople else { return .no }
        return signer(outer, seal, rumor, devices)
    }
    /// §6: group: the outer event is the rumor's author, the rumor's h is the key's group.
    public static func acceptGroupMessage(outer: NostrEvent, seal: NostrEvent, rumor: NostrEvent, group: String, devices: Devices) -> Verdict {
        guard outer.pubkey == rumor.pubkey, one(rumor.tags, "h") == group, one(outer.tags, "h") == group else { return .no }
        return signer(outer, seal, rumor, devices)
    }
    static func signer(_ outer: NostrEvent, _ seal: NostrEvent, _ rumor: NostrEvent, _ devices: Devices) -> Verdict {
        if rumor.createdAt > outer.createdAt + skew { return .no }
        switch devices {
        case .service: return seal.pubkey == rumor.pubkey ? .ok : .no
        case .unknown: return .wait
        case .chain(let c):
            if seal.pubkey == rumor.pubkey && !c.lists.contains(where: { $0.devices.contains(seal.pubkey) }) { return .no }
            guard let v = signsAt(c, device: seal.pubkey, at: outer.createdAt) else { return .wait }
            return v ? .ok : .no
        }
    }

    // ---- §5 picking the key to send with -----------------------------------------------------

    public struct HeldKey: Equatable, Sendable, Codable {
        public var K: String, k: String, conv: String
        public var mine: Bool
        public var service: Bool
        public var lists: String
        public var group: Bool
        public var at: Int
        public init(K: String, k: String, conv: String, mine: Bool, service: Bool = false, lists: String, group: Bool = false, at: Int) {
            self.K = K; self.k = k; self.conv = conv; self.mine = mine; self.service = service; self.lists = lists; self.group = group; self.at = at
        }
    }

    /// §5 + §17.8 + §18.7: the newest key < 30 days, not future-dated, made for exactly LISTS (people:
    /// by my own account's devices; group: any member's key whose entry set is LISTS), never a service key.
    public static func pickKey(_ held: [HeldKey], conv: String, lists: String, now: Int = now0()) -> HeldKey? {
        held.filter { $0.conv == conv && $0.lists == lists && !$0.service && ($0.mine || $0.group) && now - $0.at < keyAge && $0.at <= now + future }
            .sorted { $0.at != $1.at ? $0.at > $1.at : $0.K < $1.K }.first
    }

    // ---- §7 a new device -----------------------------------------------------------------------

    public enum PackKey: Equatable, Sendable {
        case people(NostrEvent)
        case group(k: String, K: String, group: String)
        case v1(secret: String, lb: String)
    }

    static func packRumorJSON(_ sharer: String, _ account: String, _ p: PackKey, _ at: Int) -> String {
        func obj(_ pk: String, _ created: Int, _ tags: [Tag], _ content: String) -> String {
            "{\"kind\":\(key),\"pubkey\":\(JSON.string(pk)),\"created_at\":\(created),\"tags\":[" + tags.map { "[" + $0.map(JSON.string).joined(separator: ",") + "]" }.joined(separator: ",") + "],\"content\":\(JSON.string(content))}"
        }
        switch p {
        case .people(let r): return obj(r.pubkey, r.createdAt, r.tags, r.content)
        case .group(let k, let K, let g): return obj(sharer, at, [["K", K], ["h", g]], k)
        case .v1(let s, let lb): return obj(sharer, at, [["v1", lb], ["p", account]], s)
        }
    }

    /// §7.5 packs: 8573 by a one-time key, ["p", account], ["d", new device]; a seal by SHARER holding
    /// a JSON list of key rumors, at most maxPack bytes each.
    public static func packs(sharer: Data, account: String, to: String, keys: [PackKey], fixed f: Fixed? = nil) throws -> [NostrEvent] {
        let at = f?.at ?? now0()
        let me = pub(sharer)
        var groups: [[String]] = [[]]
        for k in keys {
            let r = packRumorJSON(me, account, k, at)
            let last = groups[groups.count - 1]
            if !last.isEmpty && utf8("[" + (last + [r]).joined(separator: ",") + "]") > maxPack { groups.append([r]) } else { groups[groups.count - 1].append(r) }
        }
        return try groups.enumerated().filter { !$0.element.isEmpty || $0.offset == 0 }.map { i, g in
            let s = try signWith(sharer, kind: seal, createdAt: f?.sealAt ?? at, tags: [], content: try encrypt("[" + g.joined(separator: ",") + "]", sharer, to, f?.nonce?(2 * i)), aux: f?.aux)
            let once = f?.oneTime ?? Crypto.random(32)
            return try signWith(once, kind: pack, createdAt: at, tags: [["p", account], ["d", to]], content: try encrypt(eventJSON(s), once, to, f?.nonce?(2 * i + 1)), aux: f?.aux)
        }
    }

    /// §16.3 + §17.6 + §18.3: the keys of a pack to this DEVICE of ACCOUNT, when sealed by another
    /// device on the account's current list, listed before this one; nil otherwise.
    public static func openPack(device: Data, account: String, _ p: NostrEvent, chain: Chain?) -> (from: String, keys: [PackKey])? {
        guard valid(p), p.kind == pack else { return nil }
        let me = pub(device)
        guard one(p.tags, "d") == me, one(p.tags, "p") == account else { return nil }
        guard let sj = try? decrypt(p.content, device, p.pubkey), let s = validEvent(sj), s.kind == seal,
              let lj = try? decrypt(s.content, device, s.pubkey), let ld = lj.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: ld) as? [Any] else { return nil }
        guard let chain, !chain.gaps, s.pubkey != me, chain.current.devices.contains(s.pubkey), listedBefore(chain, older: s.pubkey, device: me) else { return nil }
        var keys = [PackKey]()
        for x in list {
            guard let o = x as? [String: Any], let r = try? rumor(o), r.kind == key, isKey(r.content), let p = pub(hex: r.content) else { continue }
            let v1 = one(r.tags, "v1"), h = one(r.tags, "h"), K = one(r.tags, "K")
            if let v1 { if v1 == p && one(r.tags, "p") == account { keys.append(.v1(secret: r.content, lb: v1)) }; continue }
            guard K == p, let K else { continue }
            if let h { if !h.isEmpty { keys.append(.group(k: r.content, K: K, group: h)) }; continue }
            if values(r.tags, "p").contains(account) { keys.append(.people(r)) }
        }
        return (s.pubkey, keys)
    }

    public static func askEvent(device: Data, account: String, at: Int = now0(), aux: Data? = nil) throws -> NostrEvent {
        try signWith(device, kind: ask, createdAt: at, tags: [["p", account]], content: "", aux: aux)
    }
    public enum AnswerTo: Sendable { case ask(String), device(String) }
    public static func answerEvent(device: Data, account: String, to: AnswerTo, what: String, at: Int = now0(), aux: Data? = nil) throws -> NostrEvent {
        let t: Tag
        switch to { case .ask(let id): t = ["e", id]; case .device(let d): t = ["device", d] }
        return try signWith(device, kind: answer, createdAt: at, tags: [["p", account], t, ["answer", what]], content: "", aux: aux)
    }

    public struct Asked: Equatable, Sendable { public let device: String; public let id: String; public let at: Int }
    public static func readAsk(_ e: NostrEvent, account: String, chain: Chain?) -> Asked? {
        guard valid(e), e.kind == ask, one(e.tags, "p") == account, let chain, chain.current.devices.contains(e.pubkey) else { return nil }
        return Asked(device: e.pubkey, id: e.id, at: e.createdAt)
    }
    public struct Answered: Equatable, Sendable { public let by: String; public let ask: String?; public let device: String?; public let answer: String; public let at: Int }
    public static func readAnswer(_ e: NostrEvent, account: String, chain: Chain?, about: String? = nil) -> Answered? {
        guard valid(e), e.kind == answer, one(e.tags, "p") == account, let chain, chain.current.devices.contains(e.pubkey) else { return nil }
        guard let dev = one(e.tags, "device") ?? about, !chain.gaps, listedBefore(chain, older: e.pubkey, device: dev) else { return nil }
        let a = one(e.tags, "answer"), ask = one(e.tags, "e"), device = one(e.tags, "device")
        guard a == "shared" || a == "removed", (ask == nil) != (device == nil) else { return nil }
        if let ask, !isKey(ask) { return nil }
        if let device, !isKey(device) { return nil }
        return Answered(by: e.pubkey, ask: ask, device: device, answer: a!, at: e.createdAt)
    }

    // ---- §17.2, §17.12, §13, §16.9 ---------------------------------------------------------------

    /// §17.12: the first declaration of K stays.
    @discardableResult
    public static func declare(_ book: inout [String: String], _ K: String, _ conv: String) -> Bool {
        if book[K] != nil { return false }
        book[K] = conv
        return true
    }
    public static func clearAfterKey(_ firstKeyAt: Int?, _ at: Int) -> Bool { firstKeyAt.map { at > $0 } ?? false }
    public enum PeopleLimit: String, Sendable { case encrypt, clear, held }
    public static func peopleLimit(_ n: Int, everEncrypted: Bool) -> PeopleLimit { n <= maxPeopleDevices ? .encrypt : everEncrypted ? .held : .clear }
    public static func groupLimit(_ n: Int) -> String { n <= maxGroupDevices ? "encrypt" : "refuse" }

    /// §16.9: what stays in clear in a private group.
    public static func clearInGroup(kind: Int, pubkey: String, tags: [Tag], groupsKey: String) -> Bool {
        if [9000, 9001, 9002, 9005, 9007, 9008, 9021, 9022, 39000, 39001, 39002, 39003].contains(kind) { return true }
        if kind == 1985 { return (!groupsKey.isEmpty && pubkey == groupsKey) || tags.contains { $0.count > 1 && $0[0] == "L" && $0[1] == "belfry/vouch" } }
        if kind == 30078 { let d = tags.first { $0.first == "d" }.flatMap { $0.count > 1 ? $0[1] : nil } ?? ""; return d.hasPrefix("belfry:inbox:") || d.hasPrefix("seen:") }
        return false
    }
}
