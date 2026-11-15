import BelfryCore
import Foundation

// Several accounts on one device (SPEC 19.24). The list (no secrets) is in UserDefaults; each
// account's session is in the Keychain under its slot ("session" / "session@<slot>"), with its own
// SQLite file, drafts, settings and push key K. One account is live: switching stops the open
// session (relays, signer) and starts the other from its store. A device of an earlier version
// keeps its one session as the account in slot "": same Keychain item, same database file, same
// outbox; nothing is moved or signed again.

extension AppModel {
    static let accountsKey = "belfry-accounts"

    static func loadAccounts() -> AccountList? {
        guard let d = UserDefaults.standard.data(forKey: accountsKey) else { return nil }
        return try? JSONDecoder().decode(AccountList.self, from: d)
    }

    func saveAccounts() {
        if let d = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(d, forKey: AppModel.accountsKey) }
    }

    /// At launch: the open account's saved session (the list made from the one saved session of
    /// earlier versions when there is no list yet). An entry whose session can't be read is dropped.
    func restoreAccounts() -> StoredSession? {
        if let l = AppModel.loadAccounts() {
            accounts = l
        } else {
            let old = Keychain.load(slot: "")
            accounts = AccountList.migrated(existing: old.map { ($0.domain, $0.pubkey) })
            saveAccounts()
        }
        while let open = accounts.open ?? accounts.accounts.first {
            accounts.current = open.slot
            if let s = Keychain.load(slot: open.slot) {
                Keychain.slot = open.slot
                saveAccounts()
                return s
            }
            _ = accounts.remove(open.slot)
            saveAccounts()
        }
        return nil
    }

    /// A session that just signed in: its slot (its own when that identity is on the device, else
    /// a new one with an emptied store), saved there; it becomes the open account.
    func store(_ s: StoredSession) {
        let got = accounts.adopt(domain: s.domain, pubkey: s.pubkey)
        if got.isNew {
            try? FileManager.default.removeItem(at: AppModel.dbURL(s.domain, slot: got.slot))
        }
        Keychain.slot = got.slot
        Keychain.save(s, slot: got.slot)
        saveAccounts()
        addingAccount = false
    }

    /// The open account learnt its key (sessions stored before the signer said it).
    func accountKnown(_ pubkey: String) {
        guard !isDemo, accounts.open?.pubkey != pubkey else { return }
        accounts.setPubkey(pubkey, slot: Keychain.slot)
        saveAccounts()
    }

    /// What the switcher shows of the open account.
    func describeAccount() {
        guard !isDemo, accounts.open != nil else { return }
        let before = accounts
        accounts.describe(Keychain.slot, name: realName(me), address: derive.myAddress ?? "", community: config.name,
                          picture: profiles[me]?.picture ?? "", guest: derive.amGuest || guestReading)
        if accounts != before { saveAccounts() }
    }

    /// Opens another account on this device.
    func switchAccount(_ slot: String) {
        guard slot != Keychain.slot || session == nil, let s = Keychain.load(slot: slot) else { return }
        closeLive()
        accounts.current = slot
        Keychain.slot = slot
        saveAccounts()
        open(s)
    }

    /// Stops the open session without forgetting it (switching, adding an account).
    func closeLive() {
        engine?.stop()
        if let b = engine?.signer as? BunkerSigner { b.disconnect() }
        resetLive()
    }

    /// The UserDefaults key of a per-account setting.
    static func perAccount(_ base: String) -> String { AccountList.defaultsKey(base, slot: Keychain.slot) }
}
