import BelfryCore
import Foundation
import UIKit

// Demo mode (-demo or "Try the demo"): a made-up community kept on this device, used by the
// screenshot job in CI. Nothing leaves the device.

typealias Channel = BelfryCore.Group

/// The demo's pictures, drawn on the device and put in the image cache (nothing is fetched).
enum DemoPictures {
    static func url(_ name: String) -> String { "https://demo.belfry.sh/media/\(name).jpg" }

    static func prepare() {
        let names = ["cover-repair", "p1", "p2", "p3", "p4", "p5"]
        for (i, n) in names.enumerated() {
            ImageCache.shared.put(url(n), draw(i, wide: n.hasPrefix("cover")))
        }
    }

    /// A simple scene: a sky, a sun, the ground, a few shapes, in one of five palettes.
    static func draw(_ i: Int, wide: Bool) -> UIImage {
        let size = wide ? CGSize(width: 1600, height: 900) : CGSize(width: 900, height: 900)
        let palettes: [(UIColor, UIColor, UIColor)] = [
            (UIColor(red: 0.98, green: 0.72, blue: 0.45, alpha: 1), UIColor(red: 0.55, green: 0.32, blue: 0.45, alpha: 1), UIColor(red: 0.25, green: 0.22, blue: 0.3, alpha: 1)),
            (UIColor(red: 0.62, green: 0.82, blue: 0.95, alpha: 1), UIColor(red: 0.3, green: 0.55, blue: 0.8, alpha: 1), UIColor(red: 0.3, green: 0.5, blue: 0.3, alpha: 1)),
            (UIColor(red: 0.95, green: 0.88, blue: 0.7, alpha: 1), UIColor(red: 0.85, green: 0.6, blue: 0.35, alpha: 1), UIColor(red: 0.45, green: 0.3, blue: 0.2, alpha: 1)),
            (UIColor(red: 0.8, green: 0.9, blue: 0.85, alpha: 1), UIColor(red: 0.4, green: 0.65, blue: 0.6, alpha: 1), UIColor(red: 0.2, green: 0.35, blue: 0.35, alpha: 1)),
            (UIColor(red: 0.92, green: 0.8, blue: 0.9, alpha: 1), UIColor(red: 0.6, green: 0.45, blue: 0.7, alpha: 1), UIColor(red: 0.3, green: 0.25, blue: 0.4, alpha: 1)),
        ]
        let (top, bottom, ground) = palettes[i % palettes.count]
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { r in
            let c = r.cgContext
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.85).setFill()
            let sunX = wide ? 0.62 : 0.15 + 0.12 * CGFloat(i % 4)
            c.fillEllipse(in: CGRect(x: size.width * sunX, y: size.height * 0.3, width: size.height * 0.2, height: size.height * 0.2))
            ground.setFill()
            c.fill(CGRect(x: 0, y: size.height * 0.68, width: size.width, height: size.height * 0.32))
            UIColor.white.withAlphaComponent(0.25).setFill()
            for k in 0..<3 {
                let w = size.width * 0.16
                let x = size.width * (0.18 + 0.27 * CGFloat(k))
                let h = size.height * (0.16 + 0.05 * CGFloat((i + k) % 3))
                UIBezierPath(roundedRect: CGRect(x: x, y: size.height * 0.68 - h, width: w, height: h), cornerRadius: 18).fill()
            }
        }
    }
}

enum Demo {
    static func secret(_ name: String) -> Data { Crypto.sha256("belfry-ios-demo:" + name) }
    static let meSecret = secret("you")
    /// Guest mode's demo: someone who opened a guest link of #general and reads (SPEC 19.26).
    static let readerSecret = secret("reader")
    /// SPEC 19.30 in the demo: a group whose card is in #general and that the relay no longer has,
    /// and an archived one.
    static let deletedGroup = "pod-canal-clean-up-41ec"
    static let archivedGroup = "pod-winter-market-2c9e"
    static let people: [(String, String)] = [
        ("ana", "Ana Silva"), ("ben", "Ben Okafor"), ("chloe", "Chloé Martin"), ("dev", "Dev Patel"), ("emma", "Emma Lind"),
    ]

    static func signer(_ name: String) -> LocalSigner { try! LocalSigner(secret: secret(name)) }

    static func seed(engine: SyncEngine, dms: DirectMessages) async {
        // Sam is the demo's member; on the guest-mode demo this phone is a reader, not Sam
        let me = try! LocalSigner(secret: meSecret).pubkey
        let reader = engine.me != me
        let now = Int.now
        let day = 86400
        var evs = [NostrEvent]()
        func ev(_ who: LocalSigner, _ kind: Int, _ at: Int, _ tags: [Tag], _ content: String = "") -> NostrEvent {
            try! who.signNow(EventTemplate(kind: kind, content: content, tags: tags, createdAt: at))
        }
        let ps = Dictionary(uniqueKeysWithValues: people.map { ($0.0, signer($0.0)) })
        let relay = signer("relay")
        let groupsKey = signer("groups")
        let you = try! LocalSigner(secret: meSecret)
        evs.append(ev(you, 0, now - 30 * day, [], "{\"name\":\"Sam Rivera\",\"nip05\":\"sam@demo.belfry.sh\"}"))
        for (k, n) in people { evs.append(ev(ps[k]!, 0, now - 30 * day, [], "{\"name\":\"\(n)\",\"nip05\":\"\(k)@demo.belfry.sh\"}")) }
        let all = [me] + people.map { ps[$0.0]!.pubkey }
        func channel(_ id: String, _ name: String, _ about: String, admins: [String], members: [String], at: Int) {
            evs.append(ev(relay, 39000, at, [["d", id], ["name", name], ["about", about]]))
            evs.append(ev(relay, 39001, at, [["d", id]] + admins.map { ["p", $0, "admin"] }))
            evs.append(ev(relay, 39002, at, [["d", id]] + members.map { ["p", $0] }))
        }
        channel("general", "general", "Everything about Riverside Commons. Say hi 👋", admins: [me, ps["ana"]!.pubkey], members: all, at: now - 30 * day)
        channel("garden-3f2a", "Garden", "Beds, seeds and the watering rota", admins: [ps["ben"]!.pubkey], members: all, at: now - 20 * day)
        channel("repair-cafe-91bc", "Repair café", "First Saturday of the month, bring what's broken", admins: [ps["dev"]!.pubkey], members: Array(all.prefix(4)), at: now - 10 * day)
        channel("kitchen-7d10", "Shared kitchen", "Who cooks, who cleans", admins: [ps["emma"]!.pubkey], members: all, at: now - 5 * day)
        // 2026-11-17 (SPEC 19.35): a channel nobody wrote in yet, so Settings → Channels offers Delete
        channel("tools-2b8e", "Tool library", "Borrow and lend tools", admins: [me], members: all, at: now - 2 * day)
        // 2026-11-18 (SPEC 19.38): a closed channel: people ask to join, its steward (Emma) lets
        // them in; Ben has asked. Sam is in no member list: in `-member` Sam sees "Ask to join".
        channel("board-5d1e", "Board", "Budget, contracts and the association's paperwork", admins: [ps["emma"]!.pubkey],
                members: [ps["emma"]!.pubkey, ps["ana"]!.pubkey, ps["dev"]!.pubkey], at: now - 4 * day)
        evs.append(ev(ps["emma"]!, 9002, now - 4 * day + 10, [["h", "board-5d1e"], ["name", "Board"], ["about", "Budget, contracts and the association's paperwork"], ["closed"], ["prompt", Actions.defaultPrompt]]))
        evs.append(ev(ps["emma"]!, 9, now - 3 * day, Actions.postMessage("board-5d1e", text: "The insurance renewal is due in December.").tags, "The insurance renewal is due in December."))
        evs.append(ev(ps["ben"]!, 9021, now - 5 * 3600, [["h", "board-5d1e"]], "I'd like to help with the budget, I did it for the football club."))
        // the repair café's page is public (Public channels in the drawer); the admins' order
        evs.append(ev(relay, 30078, now - 10 * day, [["d", "belfry:web:repair-cafe-91bc"], ["h", "repair-cafe-91bc"]],
                      "{\"on\":true,\"slug\":\"repair-cafe\",\"visibility\":\"public\"}"))

        func msg(_ who: LocalSigner, _ g: String, _ at: Int, _ text: String) -> NostrEvent {
            let d = Actions.postMessage(g, text: text)
            let e = ev(who, 9, at, d.tags, text)
            evs.append(e)
            return e
        }
        let y = now - day
        let welcome = msg(ps["ana"]!, "general", y - 7200, "Welcome to our belfry! Everything we say here stays on **our own server**.")
        msg(ps["ben"]!, "general", y - 7000, "Finally 🎉 No more group chat in someone else's app.")
        let ladder = msg(ps["chloe"]!, "general", y - 3600, "Does anyone have a long ladder? The gutter above the #garden shed is full of leaves.")
        let mine = msg(you, "general", y - 3000, "I can bring mine on Saturday, it's 4 m.")
        evs.append(ev(you, 1010, y - 2900, Actions.editMessage("general", Derive.parseMedia(mine), text: "I can bring mine on Saturday, it's 5 m.").tags,
                      "I can bring mine on Saturday, it's 5 m."))
        msg(ps["dev"]!, "general", now - 5400, "Reminder: repair café today. Bring lamps, bikes, toasters…\n\n- coffee is on us\n- spare parts welcome")
        let budget = msg(ps["emma"]!, "general", now - 3000, "Draft budget for 2027 is in the shared folder. Comments before Friday please, nostr:\(Bech32.npub(me)!)")
        msg(ps["ana"]!, "general", now - 1200, "Thanks Emma! I'll read it tonight.")
        // a thread on the ladder message, its latest reply after later messages: it resurfaces
        func reply(_ who: LocalSigner, _ root: NostrEvent, _ at: Int, _ text: String) {
            let d = Actions.postThreadReply("general", rootId: root.id, rootPubkey: root.pubkey, text: text)
            evs.append(ev(who, 1111, at, d.tags, text))
        }
        reply(ps["ben"]!, ladder, y - 3300, "Mine is 6 m if Sam's is too short")
        reply(you, ladder, y - 3100, "Let's try mine first")
        reply(ps["chloe"]!, ladder, now - 600, "Done! Gutter is clean, thank you both 🙏")
        reply(ps["dev"]!, budget, now - 2400, "Can we add a line for the repair café tools?")
        func react(_ who: LocalSigner, _ target: NostrEvent, _ emoji: String, _ at: Int) {
            let d = Actions.react("general", messageId: target.id, author: target.pubkey, emoji: emoji)
            evs.append(ev(who, 7, at, d.tags, emoji))
        }
        react(ps["ben"]!, welcome, "🎉", y - 7100)
        react(ps["chloe"]!, welcome, "🎉", y - 7000)
        react(you, welcome, "❤️", y - 6900)
        react(ps["dev"]!, welcome, "❤️", y - 6800)
        react(ps["emma"]!, budget, "👀", now - 2900)
        // a guest joins
        evs.append(ev(groupsKey, 9000, now - 2000, [["h", "general"], ["p", signer("guest").pubkey, "member"], ["guest", "2026-12-09"], ["invited-by", ps["ana"]!.pubkey], ["name", "Lou (neighbour)"]]))
        // seen events: who is active this month
        for (i, k) in ["ana", "ben", "chloe", "dev", "emma"].enumerated() {
            evs.append(ev(ps[k]!, 30078, now - i * 3600, [["d", "seen:general"], ["h", "general"]]))
        }
        // SPEC 19 in the demo: a pin, to-dos, a pod, a proposal under vote, a Belfry event, a channel
        // reference, an announcement, an agent guest, pinned topics
        evs.append(ev(ps["ana"]!, 1985, y - 7000, Actions.pinMessage("general", messageId: welcome.id, pin: true).tags))
        evs.append(ev(you, 2100, now - 2800, Actions.addTask("general", title: "Comment on the 2027 budget", from: budget.id).tags, "Comment on the 2027 budget"))
        let compost = ev(ps["ben"]!, 2100, now - 3 * day, Actions.addTask("general", title: "Order compost for the beds").tags, "Order compost for the beds")
        evs.append(compost)
        evs.append(ev(ps["chloe"]!, 2101, now - 2 * day, Actions.taskAction("general", taskId: compost.id, action: "claim").tags))
        evs.append(ev(ps["dev"]!, 2100, now - day, Actions.addTask("general", title: "Fix the hall's front door lock").tags, "Fix the hall's front door lock"))
        let pod = "pod-seed-swap-5e1d"
        evs.append(ev(ps["ben"]!, 9007, now - 6 * day, [["h", pod]]))
        evs.append(ev(ps["ben"]!, 9002, now - 6 * day, [["h", pod], ["name", "Seed swap"], ["about", "Saving and swapping seeds"], ["closed"], ["prompt", "Which seeds would you bring?"]]))
        channel(pod, "Seed swap", "Saving and swapping seeds", admins: [ps["ben"]!.pubkey], members: [ps["ben"]!.pubkey, ps["chloe"]!.pubkey, ps["emma"]!.pubkey, ps["dev"]!.pubkey], at: now - 6 * day)
        msg(ps["ben"]!, "general", now - 6 * day, "⬡ New group: Seed swap · Saving and swapping seeds")
        evs[evs.count - 1] = ev(ps["ben"]!, 9, now - 6 * day, [["h", "general"], ["pod", pod]], "⬡ New group: Seed swap · Saving and swapping seeds")
        msg(ps["chloe"]!, pod, now - 5 * day, "I have three kinds of beans to share 🫘")
        // SPEC 19.30: a group that was deleted (its card stays; the relay has nothing about it:
        // `AppModel.startDemo` marks it absent) and an archived one (read only, in no list)
        evs.append(ev(ps["ana"]!, 9, now - 4 * day, [["h", "general"], ["pod", Demo.deletedGroup]], "⬡ New group: Canal clean-up · Saturday mornings along the water"))
        let market = Demo.archivedGroup
        evs.append(ev(ps["emma"]!, 9007, now - 9 * day, [["h", market]]))
        evs.append(ev(ps["emma"]!, 9002, now - 9 * day, [["h", market], ["name", "Winter market"], ["about", "Stalls, lights and soup for the December market"], ["open"]]))
        channel(market, "Winter market", "Stalls, lights and soup for the December market", admins: [ps["emma"]!.pubkey], members: [me, ps["emma"]!.pubkey, ps["ana"]!.pubkey, ps["dev"]!.pubkey], at: now - 9 * day)
        evs.append(ev(ps["emma"]!, 9, now - 4 * day + 600, [["h", "general"], ["pod", market]], "⬡ New group: Winter market · Stalls, lights and soup for the December market"))
        msg(ps["emma"]!, market, now - 8 * day, "Who can lend trestle tables? We need twelve.")
        msg(ps["dev"]!, market, now - 8 * day + 1800, "The repair café has four, and I can ask the school for more.")
        msg(ps["ana"]!, market, now - 7 * day, "Soup is sorted: pumpkin and a big pot of lentils 🍲")
        msg(ps["emma"]!, market, now - 3 * day, "That was a lovely market. Thank you all! Archiving this group until next year.")
        evs.append(ev(ps["emma"]!, 9002, now - 3 * day + 60, [["h", market], ["name", "Winter market"], ["about", "Stalls, lights and soup for the December market"], ["open"], ["archived", "1"]]))
        let (pid, pdrafts) = Actions.createProposal(NewProposal(title: "Quiet hours after 22:00", summary: "No loud work in the yard after ten", text: "From Monday to Saturday, no drilling or music in the yard after **22:00**.", status: .voting),
                                                    parent: "general", me: ps["emma"]!.pubkey, groupsRelay: "wss://groups-relay.demo.belfry.sh", mainRelay: "wss://relay.demo.belfry.sh", now: now - 2 * day, x: "7f3a2b")
        let propGroup = pid // prop-quiet-hours-after-22-00-7f3a2b
        var pollId = ""
        for (i, dr) in pdrafts.enumerated() {
            let e = ev(ps["emma"]!, dr.kind, now - 2 * day + i, dr.tags, dr.content)
            evs.append(e)
            if dr.kind == 1068 { pollId = e.id }
        }
        evs.append(ev(ps["ana"]!, 1018, now - day, [["h", propGroup], ["e", pollId], ["response", "yes"]]))
        evs.append(ev(ps["ben"]!, 1018, now - day + 60, [["h", propGroup], ["e", pollId], ["response", "no"]]))
        msg(ps["ana"]!, propGroup, now - day, "Fine by me, but what about the summer party?")
        let dd = "2026-rpcafe"
        // the repair café is on today (Sam is its steward: "Check people in" shows on its header)
        var form = EventForm(title: "Repair café")
        form.description = "Bring lamps, bikes, toasters. Coffee is on us.\n\n**What we fix**: small electrics, bikes, clothes.\nSpare parts welcome."
        form.start = (now / 900) * 900 - 3600
        form.end = form.start + 4 * 3600
        form.cover = DemoPictures.url("cover-repair")
        form.tz = TimeZone.current.identifier
        form.location = "Community hall"
        form.slug = "repair-cafe"
        for (i, dr) in EventActions.create(form, d: dd, me: ps["dev"]!.pubkey, groupsRelay: "wss://groups-relay.demo.belfry.sh", mainRelay: "wss://relay.demo.belfry.sh").enumerated() {
            evs.append(ev(ps["dev"]!, dr.kind, now - 3 * day + i, dr.tags, dr.content))
        }
        let coord = "31923:\(ps["dev"]!.pubkey):\(dd)"
        evs.append(ev(ps["dev"]!, 9, now - 3 * day + 10, [["h", "general"], ["a", coord, "wss://relay.demo.belfry.sh"]], "Today's repair café has its page: https://demo.belfry.sh/events/repair-cafe"))
        evs.append(ev(ps["ana"]!, 31925, now - 2 * day, [["d", "a1"], ["a", coord], ["status", "accepted"], ["p", ps["dev"]!.pubkey]]))
        evs.append(ev(ps["ben"]!, 31925, now - 2 * day, [["d", "b1"], ["a", coord], ["status", "accepted"], ["p", ps["dev"]!.pubkey]]))
        // its ticket types, Emma co-hosting, tickets, Sam as steward, two check-ins, photos (SPEC 19.29)
        let rgroup = "ev-" + dd
        channel(rgroup, "Repair café", "Bring lamps, bikes, toasters. Coffee is on us.", admins: [ps["dev"]!.pubkey, ps["emma"]!.pubkey],
                members: [ps["dev"]!.pubkey, ps["emma"]!.pubkey, ps["ana"]!.pubkey, ps["ben"]!.pubkey, ps["chloe"]!.pubkey, me], at: now - 3 * day + 3)
        for (i, t) in [("seat", "Workshop seat", "A table and a fixer for one hour", "12"), ("volunteer", "Volunteer", "Help at the door or fix things", "")].enumerated() {
            var tags: [Tag] = [["d", "\(dd):\(t.0)"], ["a", coord, "wss://relay.demo.belfry.sh"], ["h", rgroup], ["title", t.1], ["t", "ticket"], ["position", String(i + 1)], ["summary", t.2]]
            if !t.3.isEmpty { tags.append(["quantity", t.3]) }
            evs.append(ev(ps["dev"]!, 30402, now - 3 * day + 5 + i, tags, t.2))
        }
        for (i, (who, t)) in [(me, "volunteer"), (ps["ana"]!.pubkey, "seat"), (ps["ben"]!.pubkey, "seat"), (ps["chloe"]!.pubkey, "seat")].enumerated() {
            evs.append(ev(groupsKey, 9000, now - 2 * day + i, [["h", rgroup], ["p", who, "member"], ["ticket", "\(dd):\(t)"], ["paid", "free"], ["a", coord]]))
        }
        evs.append(ev(ps["chloe"]!, 31925, now - day, [["d", "c1"], ["a", coord], ["status", "tentative"], ["p", ps["dev"]!.pubkey]]))
        evs.append(ev(groupsKey, 1985, now - day, [["L", Derive.groupRoleNS], ["l", "steward", Derive.groupRoleNS], ["p", me], ["h", rgroup], ["by", ps["dev"]!.pubkey]]))
        for (i, k) in ["ana", "ben"].enumerated() {
            evs.append(ev(groupsKey, 1985, now - 1500 + i * 300, [["L", Derive.ticketNS], ["l", "checked-in", Derive.ticketNS], ["p", ps[k]!.pubkey], ["h", rgroup], ["by", me]]))
        }
        msg(ps["dev"]!, rgroup, now - 3000, "Doors open in an hour. Coffee is ready ☕")
        msg(ps["ana"]!, rgroup, now - 1400, "I'm here with my toaster 🍞")
        func photos(_ who: LocalSigner, _ at: Int, _ text: String, _ names: [String]) {
            let tags: [Tag] = [["h", rgroup]] + names.map { ["imeta", "url " + DemoPictures.url($0), "m image/jpeg", "dim 900x900"] }
            evs.append(ev(who, 9, at, tags, text))
        }
        photos(ps["ben"]!, now - 1200, "The first bikes are done 🚲", ["p1", "p2", "p3"])
        photos(ps["chloe"]!, now - 600, "", ["p4", "p5"])
        msg(ps["emma"]!, rgroup, now - 300, "We need one more fixer at the electrics table.")
        DemoPictures.prepare()
        // an event I host, by application, with someone asking
        let dd2 = "2026-gwday1"
        var form2 = EventForm(title: "Garden work day")
        form2.description = "Digging the new beds. Lunch for everyone who helps."
        form2.start = form.start + 5 * day
        form2.end = form2.start + 5 * 3600
        form2.tz = TimeZone.current.identifier
        form2.location = "The garden"
        form2.applicationPrompt = "What can you bring (tools, food)?"
        for (i, dr) in EventActions.create(form2, d: dd2, me: me, groupsRelay: "wss://groups-relay.demo.belfry.sh", mainRelay: "wss://relay.demo.belfry.sh", ticketId: "help").enumerated() {
            evs.append(ev(you, dr.kind, now - 2 * day + i, dr.tags, dr.content))
        }
        evs.append(ev(ps["emma"]!, 9021, now - day, [["h", "ev-" + dd2], ["ticket", dd2 + ":help"]], "Two spades and a quiche"))
        evs.append(ev(you, 9, now - 2 * day + 20, [["h", "garden-3f2a"], ["a", "31923:\(me):\(dd2)", "wss://relay.demo.belfry.sh"]], "Work day next week, by application: https://demo.belfry.sh/events/\(dd2)"))
        // a meeting I made from #general (SPEC 19.23): Ana and Ben invited, Ana checked in, Lou
        // added by name (an account I hold), starting in half an hour
        let md = "2026-mtg001"
        var mf = MeetingForm(topic: "Budget 2027 review", start: (now / 1800 + 1) * 1800)
        mf.people = [ps["ana"]!.pubkey, ps["ben"]!.pubkey]
        mf.minutes = 45
        mf.place = "Community hall, room 2"
        mf.tz = TimeZone.current.identifier
        for (i, dr) in Meetings.create(mf, channel: "general", d: md, me: me, groupsRelay: "wss://groups-relay.demo.belfry.sh").enumerated() {
            evs.append(ev(you, dr.kind, now - 7200 + i, dr.tags, dr.content))
        }
        let lou = signer("lou-meeting").pubkey
        evs.append(ev(groupsKey, 9000, now - 7100, [["h", "ev-" + md], ["p", lou, "member"], ["guest", ""], ["invited-by", me], ["name", "Lou"], ["unsaved", "1"]]))
        let mcoord = "31923:\(me):\(md)"
        if let v = Meetings.create(mf, channel: "general", d: md, me: me, groupsRelay: "wss://groups-relay.demo.belfry.sh").first(where: { $0.target == .main }) {
            evs.append(ev(you, v.kind, now - 7000, v.tags + [["p", lou, "", "invited"]], v.content))
        }
        evs.append(ev(you, 1985, now - 600, [["h", "ev-" + md], ["L", Meetings.attendanceNS], ["l", "attended", Meetings.attendanceNS], ["p", ps["ana"]!.pubkey], ["a", mcoord]]))
        evs.append(ev(ps["ben"]!, 31925, now - 3000, [["d", "m1"], ["a", mcoord], ["status", "tentative"], ["p", me]]))
        evs.append(ev(you, 9, now - 6900, [["h", "general"], ["a", mcoord, "wss://relay.demo.belfry.sh"]], "Meeting: https://demo.belfry.sh/events/\(md)"))
        let gardenRef = Nip19.naddr(Nip19.Addr(kind: 39000, pubkey: relay.pubkey, identifier: "garden-3f2a", relays: ["wss://groups-relay.demo.belfry.sh"])) ?? ""
        msg(ps["ben"]!, "general", now - 4000, "Seed talk carries on in nostr:\(gardenRef) 🌱")
        // a reference at the very end: its preview box (board channels/link-preview-end)
        msg(ps["ana"]!, "general", now - 3950, "The watering rota lives here nostr:\(gardenRef)")
        let ann = Actions.postMessage("general", text: "The hall is closed on Sunday for cleaning.", announce: true)
        evs.append(ev(ps["ana"]!, 9, now - 5000, ann.tags, ann.content))
        evs.append(ev(groupsKey, 1985, now - 1900, [["h", "general"], ["L", "belfry/guest"], ["l", "saved", "belfry/guest"], ["p", signer("guest").pubkey]]))
        evs.append(ev(groupsKey, 9000, now - 1500, [["h", "general"], ["p", signer("helper").pubkey, "member"], ["invited-by", me], ["agent", "1"], ["name", "Minutes helper"]]))
        evs.append(ev(ps["ana"]!, 1985, now - 10 * day, Actions.setTopics("general", ["garden"]).tags))
        let rota = msg(ps["ben"]!, "garden-3f2a", now - 4 * day, "Tomatoes are in. Watering rota: Mon Ana, Wed me, Fri Chloé.")
        msg(ps["chloe"]!, "garden-3f2a", now - 2 * day, "The basil did not survive the cold night 🥲")
        // links to things of the belfry (SPEC 19.61): a person and a message named inside the
        // text, a message and a to-do as boxes; the last line is plain so one-line previews stay words
        let chat = "https://chat.demo.belfry.sh/#/"
        msg(ps["ana"]!, "garden-3f2a", now - 2 * day + 100, "Ask \(chat)u/\(Bech32.npub(ps["ben"]!.pubkey) ?? "") about \(chat)c/garden-3f2a/m/\(rota.id) if your day doesn't work.")
        msg(ps["dev"]!, "garden-3f2a", now - 2 * day + 200, "The rota is still this one \(chat)c/garden-3f2a/m/\(rota.id)")
        msg(ps["ana"]!, "garden-3f2a", now - 2 * day + 300, "Who can help Chloé with this? \(chat)c/general/todo/\(compost.id)")
        msg(ps["chloe"]!, "garden-3f2a", now - 2 * day + 400, "Thanks, the compost comes on Friday.")
        msg(ps["dev"]!, "repair-cafe-91bc", now - 3 * day, "Who can fix a **sewing machine**? Asking for Mrs. Dupont.")
        msg(ps["emma"]!, "kitchen-7d10", now - 6 * 3600, "Soup on Thursday, I need two helpers to chop.")
        // 2026-11-16 (bottom bar): #proposals (under its default name: shown as is since 2026-11-17), a group Sam is in
        // with news, a to-do on Sam, and the charter (six agreements Sam wrote; the newest not
        // ticked by Sam yet: Home shows "1 new agreement to read")
        channel("proposals", "proposals", "Proposals and votes", admins: [ps["emma"]!.pubkey], members: all, at: now - 25 * day)
        msg(ps["emma"]!, "proposals", now - 2 * day, "Quiet hours are up for a vote in their own proposal.")
        let crew = "pod-garden-crew-8a1c"
        evs.append(ev(ps["ben"]!, 9007, now - 8 * day, [["h", crew]]))
        evs.append(ev(ps["ben"]!, 9002, now - 8 * day, [["h", crew], ["name", "Garden crew"], ["about", "The people who keep the beds alive"], ["open"]]))
        channel(crew, "Garden crew", "The people who keep the beds alive", admins: [ps["ben"]!.pubkey],
                members: [me, ps["ben"]!.pubkey, ps["chloe"]!.pubkey, ps["ana"]!.pubkey], at: now - 8 * day)
        evs.append(ev(ps["ben"]!, 9, now - 8 * day, [["h", "garden-3f2a"], ["pod", crew]], "⬡ New group: Garden crew · The people who keep the beds alive"))
        msg(ps["chloe"]!, crew, now - 3 * 3600, "Who waters on Sunday?")
        msg(ps["ben"]!, crew, now - 2 * 3600, "I'll bring the compost sieve on Saturday")
        if let lock = evs.first(where: { $0.kind == 2100 && $0.content == "Fix the hall's front door lock" }) {
            evs.append(ev(you, 2101, now - 3600, Actions.taskAction("general", taskId: lock.id, action: "claim").tags))
        }
        for dr in Actions.createCharter() { evs.append(ev(you, dr.kind, now - 20 * day, dr.tags, dr.content)) }
        let rules: [(String, String)] = [
            // the board's texts (onboarding/welcome-charter): most run past two lines, so "more" shows
            ("We look after each other", "Kind words and good faith, also when we disagree. Speak up when someone isn't treated well, and help them first."),
            ("What's said here stays here", "Ask before sharing a message, a photo or a name outside the belfry. Public channels are the exception: they say so at the top."),
            ("Shared things come back", "Return tools within a week, clean and working. Broken? Say so in #Tool library so someone can fix it."),
            ("Quiet hours after 22:00", "In the hall and the garden, every day. Neighbours live above the hall."),
            ("Big changes are proposed first", "Anything that changes the place for everyone is proposed and voted on, not just done."),
            ("Leave it better than you found it", "Tidy the hall and the kitchen after use, take your rubbish home, and put the chairs back where they were."),
        ]
        for (i, r) in rules.enumerated() {
            let newest = i == rules.count - 1
            let at = newest ? now - day : now - 20 * day + i
            let rule = ev(you, 2100, at, Actions.addAgreement(title: r.0, about: r.1, order: i + 1).tags, r.0)
            evs.append(rule)
            let who = newest ? ["ana", "dev"] : (i == 3 ? ["ana", "ben", "dev", "emma"] : ["ana", "ben", "chloe", "dev", "emma"])
            for (k, name) in who.enumerated() { evs.append(ev(ps[name]!, 2101, at + 600 + k, Actions.agree(rule.id, true).tags)) }
            if !newest { evs.append(ev(you, 2101, at + 900, Actions.agree(rule.id, true).tags)) }
        }
        // SPEC 19.33: a shared inbox (#Hello, hello@): two e-mail threads, an answer, the team's
        // talk, and a member's own mail in #general ("via e-mail")
        let inbox = "hello-79f0"
        evs.append(ev(you, 9007, now - 15 * day, [["h", inbox]]))
        channel(inbox, "Hello", "What the world writes to hello@", admins: [me, ps["ana"]!.pubkey], members: all, at: now - 15 * day)
        evs.append(ev(you, 30078, now - 15 * day + 5, Actions.setInbox(inbox, on: true).tags, "{\"on\":true}"))
        // SPEC 19.34: Sam (an admin of the belfry) sorted the channels into categories; the repair
        // café sits in a category of its own
        let layout: [String: Any] = ["order": ["general", "garden-3f2a", "kitchen-7d10", inbox, "repair-cafe-91bc", "proposals", "website", "requests", "board-5d1e"],
                                     "categories": [["id": "life", "channels": ["garden-3f2a", "kitchen-7d10", inbox]],
                                                    ["id": "making-4b1c", "name": "Making & mending", "channels": ["repair-cafe-91bc"]],
                                                    ["id": "building", "channels": ["proposals", "website", "requests", "board-5d1e"]]],
                                     // Navigation v2: pinned for everyone, at the top of every menu
                                     "pinned": ["general", "kitchen-7d10"]]
        evs.append(ev(you, 30078, now - 14 * day, [["d", Derive.orderD]], JSON.encode(layout)))
        // the same by Ana, who is the belfry's admin in the `-member` demo
        evs.append(ev(ps["ana"]!, 30078, now - 14 * day, [["d", Derive.orderD]], JSON.encode(layout)))
        func mailIn(_ at: Int, _ from: String, _ name: String, _ subject: String, _ mid: String, _ text: String, irt: String? = nil) -> NostrEvent {
            var tags: [Tag] = [["h", inbox], ["client", "belfry-mail"], ["mail-from", from], ["mail-name", name], ["subject", subject], ["message-id", mid], ["belfry-auth", "pass"],
                               ["mail-original", "https://blossom.demo.belfry.sh/demo", "AAAA", "AAAA"]]
            if let irt { tags += [["in-reply-to", irt], ["references", irt]] }
            let e = ev(groupsKey, 9, at, tags, text)
            evs.append(e)
            return e
        }
        let hall = mailIn(now - 2 * day, "lena@townhall.example", "Lena Brandt", "Using the hall for a choir", "<hall1@townhall.example>",
                          "Hello! Our choir is looking for a room on Tuesday evenings. Could we use your hall? We are twelve people.")
        evs.append(ev(groupsKey, 9, now - 2 * day + 3600, [["h", inbox], ["client", "belfry-mail-out"], ["mail-to", "lena@townhall.example"], ["subject", "Re: Using the hall for a choir"],
                                                            ["message-id", "<out1@demo.belfry.sh>"], ["sent-by", me], ["e", hall.id, "", "reply"]],
                      "Hi Lena, Tuesdays from 19:00 are free. Come and see the hall on Saturday?"))
        let hallRe = mailIn(now - 5400, "lena@townhall.example", "Lena Brandt", "Re: Using the hall for a choir", "<hall2@townhall.example>",
                            "Saturday works. Is there a piano?", irt: "<out1@demo.belfry.sh>")
        let r = Actions.postThreadReply(inbox, rootId: hallRe.id, rootPubkey: hallRe.pubkey, text: "The old upright is in the back room. I can tune it.")
        evs.append(ev(ps["ana"]!, 1111, now - 3000, r.tags, "The old upright is in the back room. I can tune it."))
        _ = mailIn(now - 9000, "bert@bakery.example", "Bert", "Bread for the street party", "<bread1@bakery.example>",
                   "We can bake 40 loaves for the party on the 14th. Shall I bring them at 10?")
        evs.append(ev(ps["dev"]!, 9, now - 7000, [["h", generalId], ["client", "belfry-mail"], ["subject", "Minutes of the meeting"], ["message-id", "<min@dev>"],
                                                  ["mail-original", "https://blossom.demo.belfry.sh/min", "AAAA", "AAAA"]],
                      "Here are the minutes: we keep the café on Saturdays and buy a second ladder."))
        // SPEC 19.36: #website with an agent's versions: one to approve (a `belfry:` button), one
        // whose press got an error, one published (closed for everyone); links in every form
        channel("website", "website", "Versions of our website", admins: [me, ps["ana"]!.pubkey], members: all, at: now - 12 * day)
        let helper = signer("helper")
        let site = "35128:\(helper.pubkey):website"
        let preview = "https://preview.demo.belfry.sh/p/\(Bech32.npub(helper.pubkey)!)@website"
        let button: Tag = ["button", "publish", "Approve and publish", "primary", Buttons.websitePublish]
        let v1 = ev(helper, 9, now - 3 * day, [["h", "website"], ["a", site], button],
                    "**Website updated**: the opening hours are on the front page. Preview: \(preview)")
        let v2 = ev(helper, 9, now - day, [["h", "website"], ["a", site], button],
                    "New version with the summer photos (see the preview: \(preview)). An admin can approve it here or at https://belfry.demo.belfry.sh/website.")
        let v3 = ev(helper, 9, now - 3600, [["h", "website"], ["a", site], button],
                    "**Website updated**: the repair café has its own page, https://demo.belfry.sh/events/repair-cafe, and the map works again! Preview: \(preview) · live now at https://demo.belfry.sh")
        evs += [v1, v2, v3]
        let p1 = ev(ps["ana"]!, 1985, now - 3 * day + 600, Buttons.press(messageId: v1.id, author: helper.pubkey, group: "website", button: "publish").tags)
        evs.append(p1)
        evs.append(ev(groupsKey, 1985, now - 3 * day + 605, [["L", Buttons.resultNS], ["l", "ok", Buttons.resultNS], ["e", v1.id], ["press", p1.id], ["p", p1.pubkey], ["h", "website"], ["closed", "1"]],
                      "Published by Ana."))
        let p2 = ev(you, 1985, now - day + 600, Buttons.press(messageId: v2.id, author: helper.pubkey, group: "website", button: "publish").tags)
        evs.append(p2)
        evs.append(ev(groupsKey, 1985, now - day + 604, [["L", Buttons.resultNS], ["l", "error", Buttons.resultNS], ["e", v2.id], ["press", p2.id], ["p", p2.pubkey], ["h", "website"], ["code", "failed"]],
                      "Couldn't publish: the preview has no front page."))
        // request cards (docs/actions.md section 4): one closed by Ana, one open with its Close button
        channel("requests", "requests", "Requests from the website's form", admins: [me, ps["ana"]!.pubkey], members: all, at: now - 10 * day)
        let closeButton: Tag = ["button", "close", "Close", "primary", Buttons.requestClose]
        let r1 = ev(ps["chloe"]!, 9, now - 4 * day, [["h", "requests"], closeButton],
                    "**Repair café talk**\n*Talk or workshop*\nCould I give a short talk on fixing bikes at the next repair café?")
        let r2 = ev(ps["dev"]!, 9, now - 5400, [["h", "requests"], closeButton],
                    "**Sponsoring the summer fair**\n*Sponsoring*\nOur bakery would like to sponsor the summer fair. Who can we talk to?")
        let r3 = ev(signer("guest"), 9, now - 1800, [["h", "requests"], closeButton],
                    "**Room for a choir rehearsal**\n*General enquiry*\nIs the hall free on Thursday evenings for a small choir?")
        let rp2 = ev(ps["emma"]!, 1985, now - 1700, Buttons.press(messageId: r3.id, author: r3.pubkey, group: "requests", button: "close").tags)
        evs += [r1, r2, r3, rp2]
        evs.append(ev(groupsKey, 1985, now - 1697, [["L", Buttons.resultNS], ["l", "ok", Buttons.resultNS], ["e", r3.id], ["press", rp2.id], ["p", rp2.pubkey], ["h", "requests"], ["closed", "1"]],
                      "Closed by Emma Lind."))
        let rp = ev(ps["ana"]!, 1985, now - 3 * day, Buttons.press(messageId: r1.id, author: r1.pubkey, group: "requests", button: "close").tags)
        evs.append(rp)
        evs.append(ev(groupsKey, 1985, now - 3 * day + 3, [["L", Buttons.resultNS], ["l", "ok", Buttons.resultNS], ["e", r1.id], ["press", rp.id], ["p", rp.pubkey], ["h", "requests"], ["closed", "1"]],
                      "Closed by Ana Silva."))
        // guest mode: two people opened a guest link of #general and only read ("2 guests are reading")
        for k in ["reader-1", "reader-2"] {
            evs.append(ev(groupsKey, 9000, now - 900, [["h", "general"], ["p", signer(k).pubkey, "member"], ["guest", "2026-12-12"], ["invited-by", ps["ana"]!.pubkey], ["unsaved", "1"], ["reading", "1"]]))
        }
        if reader {
            evs.append(ev(groupsKey, 9000, now - 60, [["h", "general"], ["p", engine.me, "member"], ["guest", "2026-12-12"], ["invited-by", ps["ana"]!.pubkey], ["unsaved", "1"], ["reading", "1"]]))
            engine.add(evs, verify: false)
            return
        }
        // (two statements: `channel` appends to evs while the call runs)
        let oneShape = Demo.oneShapeEvents(now: now, ben: ps["ben"]!, others: [ps["emma"]!, ps["ana"]!], me: you, ev: ev,
                                       channel: { channel($0, $1, $2, admins: $3, members: $4, at: $5) })
        evs += oneShape
        engine.add(evs, verify: false)
        engine.add([ev(you, 30078, now - 3 * day, [["d", "seen:general"], ["h", "general"]])], verify: false)

        dms.myAddress = "sam@demo.belfry.sh"
        // sealed conversations (boards messages/encryption-*): Lina (a profile, not a member of the
        // channels: the other screens keep their people), and a group of five
        let lina = signer("lina")
        engine.add([ev(lina, 0, now - 30 * day, [], "{\"name\":\"Lina Moreau\",\"nip05\":\"lina@demo.belfry.sh\"}")], verify: false)
        try? await dms.demoDM(from: lina, text: "Can you bring the long ladder on Saturday?", at: now - 26 * 3600)
        try? await dms.demoSent(to: lina.pubkey, text: "Yes, I'll drop it at the hall at 8:30.", at: now - 26 * 3600 + 120)
        try? await dms.demoDM(from: lina, text: "Thanks! The key is under the blue pot.", at: now - 2 * 3600 - 600)
        try? await dms.demoDM(from: lina, text: "Writing from my new phone 👋", at: now - 1800)
        try? await dms.demoDM(from: ps["emma"]!, text: "Who brings the soup pots on Sunday?", at: now - 3 * day,
                              others: [ps["ana"]!.pubkey, ps["ben"]!.pubkey, lina.pubkey])
        try? await dms.demoDM(from: ps["ana"]!, text: "Hi Sam! Can you open the hall on Saturday at 9?", at: now - 7200, reaction: "👍")
        try? await dms.demoDM(from: ps["dev"]!, text: "I found the spare bike parts you asked about.", at: now - 2 * day)
        try? await dms.demoMail(bridgeSecret: secret("bridge"), sender: "\"Town Hall\" <events@townhall.example>", subject: "Street party permit",
                                text: "Hello,\n\nYour request for the street party on 14 June is approved.\n\nKind regards,\nTown Hall", at: now - 5 * 3600)
        await dms.process()
        // board messages/encryption-shared-history: Dev shared the earlier messages with this device
        dms.demoShared(conv: "n:" + ps["dev"]!.pubkey, by: ps["dev"]!.pubkey)
        // board messages/encryption-thread: one message that came without the lock ("Not sealed")
        dms.demoUnsealed(conv: "n:" + lina.pubkey, text: "Thanks! The key is under the blue pot.")
        // the screenshots of a send that is not out yet (SPEC 19.50): my last message to Ana waits
        let args = ProcessInfo.processInfo.arguments
        // pictures, files and a recording in the conversation with Ana (boards messages/attach-*)
        if let i = args.firstIndex(of: "-screen"), i + 1 < args.count, args[i + 1].hasPrefix("dmfiles") {
            let ana = "n:" + ps["ana"]!.pubkey
            func jpeg(_ n: Int) -> Data { DemoPictures.draw(n, wide: false).jpegData(compressionQuality: 0.7) ?? Data() }
            dms.demoFile(jpeg(1), mime: "image/jpeg", name: nil, dim: "900x900", in: ana, from: ps["ana"]!.pubkey, at: now - 5000)
            let g = "5f0c3a9e1b7d2c48"
            for (k, n) in [2, 3, 4].enumerated() {
                dms.demoFile(jpeg(n), mime: "image/jpeg", name: nil, dim: "900x900", group: g, in: ana, from: me, at: now - 3000 + k)
            }
            dms.demoText("The seedlings came up!", group: g, in: ana, from: me, at: now - 2996)
            var pdf = Data("%PDF-1.4 demo".utf8); pdf.append(Data(count: 1_200_000))
            dms.demoFile(pdf, mime: "application/pdf", name: "Garden plan 2027.pdf", in: ana, from: ps["ana"]!.pubkey, at: now - 2000)
            dms.demoFile(Data(count: 60_000), mime: "audio/mp4", name: nil, duration: 42, in: ana, from: me, at: now - 1000)
            if args[i + 1] == "dmfilessending" { dms.demoPendingFiles(in: ana) }
        }
        if let i = args.firstIndex(of: "-screen"), i + 1 < args.count, ["sendstill", "sendnotyet"].contains(args[i + 1]) {
            dms.demoPending(conv: "n:" + ps["ana"]!.pubkey, text: "Yes, I'll be there at 9 with the keys.", at: now - 40)
        }

        // ---- 0.8.0 (g), one shape's e-mail thread (boards one-shape/email-*): Lou's e-mail to
        // hello@ with To and Cc, Ana took it, the team's talk, Sam's internal draft. It is the
        // oldest thread, so the screenshots' `mailthread` / `mailreply` / `mailcomment` open it.
        if !reader {
            let inbox = "hello-79f0"
            let start = now - 3 * day
            let lou = ev(groupsKey, 9, start, [["h", inbox], ["client", "belfry-mail"], ["mail-from", "lou@example.org"], ["mail-name", "Lou"],
                                               ["subject", "Park cleaning on Saturday"], ["message-id", "<park1@example.org>"], ["belfry-auth", "pass"],
                                               ["to", "hello@demo.belfry.sh", "Riverside Commons"], ["cc", "dev@example.net", "Dev Patel"], ["cc", "park@example.org", ""]],
                         "Hello! Could Riverside Commons lend us rakes and gloves for the park cleaning on Saturday? We'd be about 15.")
            let took = ev(ps["ana"]!, 1985, start + 360, Actions.assignCard(inbox, card: lou.id, assignee: ps["ana"]!.pubkey).tags)
            let t1 = Actions.postThreadReply(inbox, rootId: lou.id, rootPubkey: lou.pubkey, text: "I know Lou, I'll answer. Ben, are the rakes in the shed?")
            let t2 = Actions.postThreadReply(inbox, rootId: lou.id, rootPubkey: lou.pubkey, text: "Yes, 12 rakes and a box of gloves.")
            let draftText = "Hi Lou, yes! We can lend you 12 rakes and a box of gloves…"
            let draft = Actions.mailDraft(inbox, card: lou, text: draftText)
            engine.add([lou, took, ev(ps["ana"]!, 1111, start + 420, t1.tags, t1.content), ev(ps["ben"]!, 1111, start + 960, t2.tags, t2.content),
                        ev(you, 1111, start + 1500, draft.tags, draftText)], verify: false)
        }
        // ---- one shape, 0.8.0 (canvas one-shape/dm-thread): a thread in the conversation with Ana
        if let root = try? await dms.demoDM(from: ps["ana"]!, text: "And could you bring the extension cable from the store room?", at: now - 7100) {
            try? await dms.demoSent(to: ps["ana"]!.pubkey, text: "The long orange one or the reel?", at: now - 6600, root: root)
            try? await dms.demoDM(from: ps["ana"]!, text: "The reel, the bike stands need two plugs.", at: now - 6480, root: root)
            try? await dms.demoSent(to: ps["ana"]!.pubkey, text: "Yes to both.", at: now - 6300)
            await dms.process()
        }
    }
}

// ---- one shape, events (0.8.0, boards one-shape/event-default-online) --------------------------
extension Demo {
    /// An online event that has just started (Join is open): Garden planning on Jitsi, hosted by
    /// Ben; Emma, Ana and Sam going.
    static func oneShapeEvents(now: Int, ben: LocalSigner, others: [LocalSigner], me: LocalSigner,
                               ev: (LocalSigner, Int, Int, [Tag], String) -> NostrEvent,
                               channel: (String, String, String, [String], [String], Int) -> Void) -> [NostrEvent] {
        var out = [NostrEvent]()
        let d = "2026-gplan01"
        var f = EventForm(title: "Garden planning")
        f.description = "Bring your seed list, we'll plan the beds for spring."
        f.start = (now / 300) * 300 - 300
        f.end = f.start + 3600
        f.tz = TimeZone.current.identifier
        f.online = "https://meet.jit.si/garden-planning-4c1d2"
        f.slug = "garden-planning"
        for (i, dr) in EventActions.create(f, d: d, me: ben.pubkey, groupsRelay: "wss://groups-relay.demo.belfry.sh", mainRelay: "wss://relay.demo.belfry.sh").enumerated() {
            out.append(ev(ben, dr.kind, now - 2 * 86400 + i, dr.tags, dr.content))
        }
        channel("ev-" + d, "Garden planning", f.description, [ben.pubkey], [ben.pubkey, me.pubkey] + others.map(\.pubkey), now - 2 * 86400 + 5)
        let coord = "31923:\(ben.pubkey):\(d)"
        for (i, who) in (others + [me]).enumerated() {
            out.append(ev(who, 31925, now - 86400 + i * 600, [["d", "gp\(i)"], ["a", coord], ["status", "accepted"], ["p", ben.pubkey]], ""))
        }
        out.append(ev(ben, 9, now - 3600, [["h", "ev-" + d]], "Bring your seed list, we'll plan the beds for spring."))
        return out
    }
}
