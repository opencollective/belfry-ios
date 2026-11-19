import Foundation

// Several accounts on one device (SPEC 19.24; Android core/accounts). An account is one identity
// in one belfry, id `<pubkey>@<domain>`. Everything of it is kept under its SLOT ("" for the first,
// then "a2", "a3"…; a numbered slot is never given twice): the session in the Keychain, its own
// SQLite file, its drafts and settings, the push device key K. This list holds no secret.

public struct AccountEntry: Codable, Hashable, Sendable, Identifiable {
    public var slot: String
    public var domain: String
    /// nil until the signer said who this is (a session stored before the key was known)
    public var pubkey: String?
    public var name: String = ""
    public var address: String = ""
    public var community: String = ""
    public var picture: String = ""
    public var guest: Bool = false
    /// Their role's name there ("Steward", "Member", "Gardener"), as last seen; nil before that.
    public var role: String?

    public init(slot: String, domain: String, pubkey: String?) {
        self.slot = slot; self.domain = domain; self.pubkey = pubkey
    }

    public var id: String { (pubkey ?? "?") + "@" + domain }
    /// What the switcher writes under the name: name@domain, "Guest · community", or the community.
    public var line: String {
        let place = community.isEmpty ? domain : community
        if guest { return "Guest · " + place }
        return address.isEmpty ? place : address
    }
    /// The accounts screen's line (board home/accounts): "Riverside Commons · Steward",
    /// "Guest · Riverside Commons", or the community alone while the role is not known.
    public var placeLine: String {
        let place = community.isEmpty ? domain : community
        if guest { return "Guest · " + place }
        guard let role, !role.isEmpty else { return place }
        return place + " · " + role
    }
}

public struct AccountList: Codable, Hashable, Sendable {
    public var accounts: [AccountEntry] = []
    /// the open account's slot
    public var current: String?
    /// the next numbered slot ("a2" first)
    public var nextSlot = 2

    public init() {}

    public var open: AccountEntry? { accounts.first { $0.slot == current } }
    public func entry(_ slot: String) -> AccountEntry? { accounts.first { $0.slot == slot } }

    /// A device of earlier versions: its one saved session becomes the account in slot "", whose
    /// names are the old ones (nothing moved, nothing signed again).
    public static func migrated(existing: (domain: String, pubkey: String?)?) -> AccountList {
        var l = AccountList()
        if let e = existing {
            l.accounts = [AccountEntry(slot: "", domain: e.domain, pubkey: e.pubkey)]
            l.current = ""
        }
        return l
    }

    /// The slot for an identity signing in: its own when it is on the device already (same
    /// domain and key), else "" when free, else a new numbered one. It becomes the open account.
    public mutating func adopt(domain: String, pubkey: String?) -> (slot: String, isNew: Bool) {
        if let pubkey, let e = accounts.first(where: { $0.domain == domain && $0.pubkey == pubkey }) {
            current = e.slot
            return (e.slot, false)
        }
        let slot: String
        if !accounts.contains(where: { $0.slot == "" }) {
            slot = ""
        } else {
            slot = "a\(nextSlot)"
            nextSlot += 1
        }
        accounts.append(AccountEntry(slot: slot, domain: domain, pubkey: pubkey))
        current = slot
        return (slot, true)
    }

    /// An account learnt its key (a session stored before the signer said it).
    public mutating func setPubkey(_ pubkey: String, slot: String) {
        guard let i = accounts.firstIndex(where: { $0.slot == slot }) else { return }
        accounts[i].pubkey = pubkey
    }

    /// What the switcher shows of SLOT (name, address, community, picture, guest).
    public mutating func describe(_ slot: String, name: String, address: String, community: String, picture: String, guest: Bool, role: String? = nil) {
        guard let i = accounts.firstIndex(where: { $0.slot == slot }) else { return }
        if let role { accounts[i].role = role }
        accounts[i].name = name; accounts[i].address = address; accounts[i].community = community
        accounts[i].picture = picture; accounts[i].guest = guest
    }

    /// Takes SLOT off the list; returns the account to open next (the one after it, else the one
    /// before), nil when none is left.
    public mutating func remove(_ slot: String) -> AccountEntry? {
        guard let i = accounts.firstIndex(where: { $0.slot == slot }) else { return open }
        accounts.remove(at: i)
        guard !accounts.isEmpty else { current = nil; return nil }
        let next = accounts[min(i, accounts.count - 1)]
        current = next.slot
        return next
    }

    // ---- where each account's things are kept --------------------------------------------------

    /// The Keychain account of its session.
    public static func sessionKey(_ slot: String) -> String { slot.isEmpty ? "session" : "session@" + slot }
    /// Its SQLite file name (slot "" keeps the earlier name).
    public static func dbName(domain: String, slot: String) -> String { slot.isEmpty ? "belfry-\(domain).sqlite" : "belfry-\(domain)@\(slot).sqlite" }
    /// A per-account UserDefaults key (slot "" keeps the earlier name).
    public static func defaultsKey(_ base: String, slot: String) -> String { slot.isEmpty ? base : base + "@" + slot }
}
