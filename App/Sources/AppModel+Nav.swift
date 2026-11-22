import BelfryCore
import Foundation

// Navigation v2 (canvas section of 2026-11-22; collective-belfry docs/one-shape.md §1): the menu's
// CHANNELS (pinned for everyone, then pinned for me, then recent), Pin for me (kind 30078
// d=belfry:pins, NIP-44 to myself, newest wins, through the outbox; guests, guest mode and the
// demo keep it on the device), Pin for everyone (admins: "pinned" in channel-order), the counts of
// the bottom bar and of ☰.

struct MyPinsState: Codable {
    var at: Int
    var id: String
    var ids: [String]
}

extension AppModel {
    static let kPins = "pins-mine"

    /// Pins can leave the device (a member, signed in for real).
    var pinsShared: Bool { !isDemo && !guestReading && !derive.amGuest && session?.reading != true }

    /// After each change of the log: my newest belfry:pins from another device, decrypted.
    func pinsCheck() {
        guard let engine else { return }
        if pinsState == nil {
            pinsState = engine.db.get(AppModel.kPins, as: MyPinsState.self) ?? MyPinsState(at: 0, id: "", ids: [])
            if myPins != pinsState!.ids { myPins = pinsState!.ids }
        }
        guard pinsShared, let e = derive.myNewest(kind: 30078, d: Pins.d), let st = pinsState,
              e.createdAt > st.at || (e.createdAt == st.at && e.id != st.id && st.id != "" && e.id < st.id) else { return }
        pinsState?.id = e.id
        pinsState?.at = e.createdAt
        let signer = engine.signer, me = self.me
        Task { @MainActor in
            guard let plain = try? await signer.nip44Decrypt(peer: me, payload: e.content) else { return }
            let ids = Pins.parse(plain)
            self.pinsState = MyPinsState(at: e.createdAt, id: e.id, ids: ids)
            engine.db.set(AppModel.kPins, self.pinsState!)
            if self.myPins != ids { self.myPins = ids }
        }
    }

    /// Pin for me / unpin: shown at once, kept on the device, sent (encrypted to myself) for my
    /// other devices. A newer copy replaces one still waiting in the outbox.
    func togglePinMine(_ id: String) async {
        guard let engine else { return }
        let ids = Pins.toggle(myPins, id)
        myPins = ids
        let at = max(Int.now, (pinsState?.at ?? 0) + 1)
        pinsState = MyPinsState(at: at, id: "", ids: ids)
        engine.db.set(AppModel.kPins, pinsState!)
        guard pinsShared, let content = try? await engine.signer.nip44Encrypt(peer: me, plaintext: Pins.serialize(ids)) else { return }
        for item in engine.outboxItems() where item.kind == 30078 && item.tags.contains(["d", Pins.d]) && item.signed == nil {
            engine.cancel(item.localId)
        }
        engine.enqueue(Actions.myPins(encrypted: content))
    }

    /// Pin for everyone (the belfry's admins).
    func togglePinEveryone(_ id: String) {
        engine?.enqueue(Actions.pinForEveryone(id, previous: derive.channelOrderObject()))
    }

    var pinnedForEveryone: [String] { derive.pinnedForEveryone() }

    /// The menu's channels, cached per snapshot and pins.
    var menu: (pinned: [String], recent: [String]) {
        if let c = menuCache, c.version == version, c.pins == myPins { return c.value }
        var v = derive.menuChannels(now: Int.now, pinsMine: myPins)
        // no channel pinned for everyone yet (a belfry whose admins haven't chosen): the main
        // channel stays on top so a new member always has one
        if derive.channelOrderObject()["pinned"] == nil, derive.group(generalId) != nil, !v.pinned.contains(generalId) {
            v.pinned.insert(generalId, at: 0)
            v.recent.removeAll { $0 == generalId }
        }
        menuCache = (version, myPins, v)
        return v
    }

    /// In my menu (pinned or recent): else it opens in preview.
    func inMenu(_ id: String) -> Bool {
        let m = menu
        return m.pinned.contains(id) || m.recent.contains(id)
    }

    /// The groups I'm in.
    var myGroups: [Channel] {
        derive.groups().filter { $0.isPod && ($0.members.contains(me) || $0.admins.contains(me)) && !derive.isArchived($0.id) }
    }

    /// The bar's Groups count: my groups with new messages.
    var groupsUnread: Int { myGroups.filter { unread($0.id) > 0 }.count }

    /// ☰: the new items across the menu's rows (channels, groups, messages); Today and Mentions
    /// are not added (a mention is counted in its row).
    var menuUnread: Int {
        let m = menu
        let chans = (m.pinned + m.recent).reduce(0) { $0 + unread($1) }
        let groups = myGroups.reduce(0) { $0 + unread($1.id) }
        return chans + groups + unreadDMs
    }

    /// A channel opened in preview gets into the menu (written, reacted, mentioned, pinned): the
    /// bar goes and a toast says so.
    func previewCheck(_ id: String) {
        guard previewing.contains(id), inMenu(id) else { return }
        previewing.remove(id)
        toast = "\(derive.label(id)) is in your menu"
    }
}
