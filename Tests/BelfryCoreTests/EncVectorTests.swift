import XCTest
@testable import BelfryCore

// vectors/encrypted.json (the web's, written by its tools/vectors/gen-encrypted.mjs, copied byte for
// byte): every check of the web's tools/vectors/check.mjs, then the envelopes, messages and packs
// REBUILT here from the same fixed keys, nonces and dates, compared byte for byte (as the server's
// enc.py does).

private func sk(_ name: String) -> Data { Crypto.sha256(Data(("belfry-vector:" + name).utf8)) }
private let aux = Data(count: 32)
private func fixed(_ label: String, _ at: Int, sealAt: Int? = nil) -> Enc.Fixed {
    Enc.Fixed(at: at, sealAt: sealAt ?? at - 100, oneTime: sk("once:" + label), nonce: { i in Crypto.sha256(Data("nonce:\(label):\(i)".utf8)) }, aux: aux)
}

final class EncVectorTests: XCTestCase {
    var v: [String: Any] = [:]
    var B = ""
    var K: [String: String] = [:]

    override func setUpWithError() throws {
        v = try vector("encrypted")
        B = v.str("belfry") ?? ""
        K = (v["keys"] as? [String: String]) ?? [:]
    }

    func sec(_ n: String) -> Data { Data(hex: (v["secrets"] as? [String: String])?[n] ?? "") ?? Data() }
    func evs(_ any: Any?) throws -> [NostrEvent] { try events(any) }
    func chain(_ any: Any?, _ a: String) throws -> Enc.Chain? { Enc.chainOf(try evs(any), belfry: B, account: a) }
    func chains(_ any: Any?) throws -> (String) -> Enc.Devices {
        let list = try evs(any)
        let b = B
        return { a in a == b ? .service : Enc.chainOf(list, belfry: b, account: a).map { .chain($0) } ?? .unknown }
    }
    func devs(_ c: Enc.Chain?) -> Enc.Devices { c.map { .chain($0) } ?? .unknown }
    func nb(_ b: Bool?) -> Any { b.map { $0 as Any } ?? NSNull() }
    func same(_ a: Any?, _ b: Any?) -> Bool {
        let x = a ?? NSNull(), y = b ?? NSNull()
        if x is NSNull || y is NSNull { return x is NSNull && y is NSNull }
        return (x as AnyObject).isEqual(y)
    }
    func view(_ c: Enc.Chain?) -> Any {
        guard let c else { return NSNull() }
        return ["lists": c.lists.map(\.id), "current": c.current.id, "devices": c.current.devices, "readers": c.current.readers, "gaps": c.gaps, "fork": c.fork, "invalidAbove": c.invalidAbove] as NSDictionary
    }

    func testFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("vectors/encrypted.json"))
        XCTAssertEqual(Crypto.sha256(data).hex, "16efbbc822d1e3e87e64fc6db6f6ee81cc6d1734364a411ab55e92472ebd42fe", "the web's file, byte for byte")
    }

    func testLists() throws {
        for (n, c) in (v.dict("lists").dict("valid") as [String: Any]) {
            let c = c as! [String: Any]
            let l = Enc.parseList(try event(c["event"]), belfry: B)
            XCTAssertEqual(l != nil, c["valid"] as? Bool, n)
            if let l { XCTAssertEqual(l.devices.count, c.int("devices"), n); XCTAssertEqual(l.readers.count, c.int("readers"), n) }
        }
        for c in v.dict("lists").list("chains") {
            XCTAssertTrue(same(view(try chain(c["events"], c.str("account")!)), c["expect"]), c.str("name") ?? "")
        }
        let ch = try XCTUnwrap(try chain(v.dict("changes")["lists"], K["sam"]!))
        let got = Enc.changes(ch).map { ["list": $0.list, "n": $0.n, "added": $0.added, "removed": $0.removed, "readersAdded": $0.readersAdded] as NSDictionary }
        XCTAssertTrue(same(got as NSArray, v.dict("changes")["expect"]), "changes")
        let lb = try XCTUnwrap(try chain(v.dict("listed_before")["lists"], K["sam"]!))
        for x in v.dict("listed_before").list("cases") {
            XCTAssertEqual(Enc.listedBefore(lb, older: x.str("older")!, device: x.str("device")!), x["expect"] as? Bool)
        }
        let at: [(String, (Enc.Chain, String, Int) -> Bool?)] = [
            ("signs_at", Enc.signsAt), ("signs_at_gap", Enc.signsAt), ("signs_at_relisted", Enc.signsAt), ("signs_at_slow_clock", Enc.signsAt),
            ("signs_at_behind", Enc.signsAt), ("listed_at_gap", Enc.listedAt), ("listed_at", Enc.listedAt),
        ]
        for (name, f) in at {
            let c = try XCTUnwrap(try chain(v.dict(name)["lists"], K["sam"]!))
            for x in v.dict(name).list("cases") {
                XCTAssertTrue(same(nb(f(c, x.str("device")!, x.int("at")!)), x["expect"]), "\(name) \(x.str("device")!.prefix(6)) @\(x.int("at")!)")
            }
        }
        for x in v["group_key_slow_clock"] as? [[String: Any]] ?? [] {
            let key = Enc.GroupKey(k: String(repeating: "1", count: 64), K: String(repeating: "a", count: 64), group: "pod-garden-7f3a", maker: x.str("maker")!, account: x.str("account")!, at: x.int("at")!, set: String(repeating: "b", count: 64))
            XCTAssertEqual(Enc.acceptGroupKey(key, devices: devs(try chain(x["lists"], x.str("account")!)), now: x.int("now")!).rawValue, x.str("expect"))
        }
        let ia = try XCTUnwrap(try chain(v.dict("invalid_above")["events"], K["sam"]!))
        XCTAssertEqual(ia.invalidAbove, v.dict("invalid_above")["invalid_above"] as? Bool)
        XCTAssertTrue(same(view(ia), v.dict("invalid_above")["expect"]))
    }

    func testNames() throws {
        for x in v["alias"] as? [[String: Any]] ?? [] { XCTAssertEqual(Enc.alias(x.str("K")!, x.str("account")!), x.str("expect")) }
        let lh = v.dict("lists_hash")
        let lists = (lh["lists"] as? [[String: String]] ?? []).map { (account: $0["account"]!, id: $0["id"]!) }
        XCTAssertEqual(Enc.listsHash(lists), lh.str("expect"))
        for x in v["people_of"] as? [[String: Any]] ?? [] { XCTAssertEqual(Enc.peopleOf(try event(x["rumor"])), x.str("expect"), x.str("name") ?? "") }
        var book = [String: String]()
        for x in v["declare"] as? [[String: Any]] ?? [] { XCTAssertEqual(Enc.declare(&book, x.str("K")!, x.str("conv")!), x["expect"] as? Bool) }
        for x in v["clear_after_key"] as? [[String: Any]] ?? [] { XCTAssertEqual(Enc.clearAfterKey(x.int("first_key_at"), x.int("at")!), x["expect"] as? Bool) }
        for x in v.dict("limits").list("people") { XCTAssertEqual(Enc.peopleLimit(x.int("devices")!, everEncrypted: x["ever_encrypted"] as! Bool).rawValue, x.str("expect")) }
        for x in v.dict("limits").list("group") { XCTAssertEqual(Enc.groupLimit(x.int("devices")!), x.str("expect")) }
    }

    func testPeopleKey() throws {
        let pk = v.dict("people_key")
        let envs = try evs(pk["envelopes"])
        for x in pk.list("open") {
            var got: Any = NSNull()
            do {
                if let o = try Enc.openPeopleEnvelope(device: sec(x.str("device")!), envs[x.int("envelope")!]) {
                    got = ["rumor_id": o.rumor.id, "K": o.rumor.tag("K")!] as NSDictionary
                }
            } catch { got = ["error": true] as NSDictionary }
            XCTAssertTrue(same(got, x["expect"]), "people envelope \(x.str("device")!)")
        }
        for x in pk.list("accept") {
            let got = Enc.acceptKeyRumor(Enc.withId(try event(x["rumor"])), receiver: x.str("receiver")!, devices: try chains(x["lists"]), now: x.int("now")!)
            XCTAssertEqual(got.rawValue, x.str("expect"), x.str("name") ?? "")
        }
    }

    func testGroupKey() throws {
        let gk = v.dict("group_key")
        let envs = try evs(gk["envelopes"])
        let group = gk.str("group")!
        XCTAssertEqual(envs.count, gk.int("expect_events"))
        XCTAssertTrue(envs.allSatisfy { $0.content.utf8.count <= 60000 })
        let secrets = v["secrets"] as? [String: String] ?? [:]
        for x in gk.list("find") where secrets[x.str("device")!] != nil {
            var got: Any = NSNull()
            for (i, e) in envs.enumerated() {
                do { if let g = try Enc.openGroupEnvelope(device: sec(x.str("device")!), e, group: group) { got = ["envelope": i, "K": g.K, "maker": g.maker] as NSDictionary; break } }
                catch { got = ["error": true] as NSDictionary; break }
            }
            XCTAssertTrue(same(got, x["expect"]), "group envelope \(x.str("device")!)")
        }
        XCTAssertThrowsError(try Enc.openGroupEnvelope(device: sec("c1"), envs[0], group: gk.dict("wrong_group").str("group")!))
        let g = try XCTUnwrap(try Enc.openGroupEnvelope(device: sec("c1"), envs[0], group: group))
        XCTAssertEqual(g.set, gk.str("expect_set"))
        XCTAssertEqual(Enc.deviceSet(Enc.entryKeys(envs)) == g.set, gk["expect_set_all_events"] as? Bool)
        XCTAssertEqual(Enc.deviceSet(Enc.entryKeys([envs[0]])) == g.set, gk["expect_set_first_event_only"] as? Bool)
        for x in gk.list("accept") {
            let key = Enc.GroupKey(k: g.k, K: g.K, group: g.group, maker: x.str("maker")!, account: g.account, at: x.int("at")!, set: g.set)
            XCTAssertEqual(Enc.acceptGroupKey(key, devices: devs(try chain(x["lists"], x.str("account")!)), now: x.int("now")!).rawValue, x.str("expect"))
        }
    }

    func testMessages() throws {
        let pm = v.dict("people_messages")
        let msgs = try evs(pm["messages"])
        XCTAssertEqual(msgs.map(\.tags), (pm["expect_tags"] as? [[[String]]]) ?? [])
        for (i, m) in msgs.enumerated() {
            var got: Any
            do { let o = try Enc.openPeopleMessage(k: pm.str("k")!, m); got = ["seal_signer": o.seal.pubkey, "rumor_id": o.rumor.id] as NSDictionary }
            catch { got = ["error": true] as NSDictionary }
            XCTAssertTrue(same(got, pm.list("open")[i]["expect"]))
        }
        XCTAssertThrowsError(try Enc.openPeopleMessage(k: String(repeating: "11", count: 32), msgs[1]))
        for x in pm.list("accept") {
            let m = try event(x["message"])
            let o = try Enc.openPeopleMessage(k: pm.str("k")!, m)
            let lists = (x["lists_without_lina"] as? Bool) == true ? v.dict("signs_at")["lists"] : v.dict("people_key").list("accept")[0]["lists"]
            let got = Enc.acceptPeopleMessage(outer: m, seal: o.seal, rumor: o.rumor, keyPeople: x.str("key_people") ?? pm.str("key_people")!, devices: try chains(lists)(o.rumor.pubkey))
            XCTAssertEqual(got.rawValue, x.str("expect"), x.str("name") ?? "")
        }
        let gm = v.dict("group_messages")
        let c3 = try chain(v.dict("signs_at")["lists"], K["sam"]!)
        for x in gm.list("cases") {
            let m = try event(x["message"])
            let o = try Enc.openGroupMessage(k: gm.str("k")!, m)
            XCTAssertEqual(Enc.acceptGroupMessage(outer: m, seal: o.seal, rumor: o.rumor, group: gm.str("group")!, devices: devs(c3)).rawValue, x.str("expect"), x.str("name") ?? "")
            if let t = x["expect_tags"] as? [[String]] { XCTAssertEqual(m.tags, t) }
        }
        // §23 a file in a private group
        let gf = v.dict("group_file")
        let o = try Enc.openGroupMessage(k: gf.str("k")!, try event(gf["message"]))
        XCTAssertEqual(o.rumor.id, gf.str("rumor_id"))
        let im = try XCTUnwrap(o.rumor.tags.first { $0.first == "imeta" })
        var f = [String: String]()
        for p in im.dropFirst() { if let sp = p.firstIndex(of: " ") { f[String(p[..<sp])] = String(p[p.index(after: sp)...]) } }
        let file = DmFile(url: f["url"] ?? "", mime: f["m"] ?? "", key: f["decryption-key"]!, nonce: f["decryption-nonce"]!, x: f["x"]!, ox: f["ox"]!, size: Int(f["size"] ?? "0") ?? 0)
        let cipher = try XCTUnwrap(Data(hex: gf.str("ciphertext_hex")!))
        XCTAssertEqual(DmFiles.open(file, downloaded: cipher)?.hex, gf.str("plain_hex"))
        var bad = cipher; bad[bad.startIndex] ^= 1
        XCTAssertNil(DmFiles.open(file, downloaded: bad))
    }

    func testPacksAsksPick() throws {
        let c = try chain(v.dict("packs")["lists"], K["sam"]!)
        func pv(_ p: NostrEvent) -> Any {
            guard let o = Enc.openPack(device: sec("d4"), account: K["sam"]!, p, chain: c) else { return NSNull() }
            let keys: [NSDictionary] = o.keys.map {
                switch $0 {
                case .people(let r): return ["kind": "people", "rumor_id": r.id]
                case .group(_, let K, let g): return ["kind": "group", "K": K, "group": g]
                case .v1(_, let lb): return ["kind": "v1", "lb": lb]
                }
            }
            return ["from": o.from, "keys": keys] as NSDictionary
        }
        for x in v.dict("packs").list("cases") { XCTAssertTrue(same(pv(try event(x["pack"])), x["expect"]), x.str("name") ?? "") }
        let pk = v.dict("pick_key")
        let held: [Enc.HeldKey] = (pk["held"] as? [[String: Any]] ?? []).map {
            Enc.HeldKey(K: $0.str("K")!, k: $0.str("k")!, conv: $0.str("conv")!, mine: $0["mine"] as? Bool ?? false, service: $0["service"] as? Bool ?? false,
                        lists: $0.str("lists")!, group: $0["group"] as? Bool ?? false, at: $0.int("at")!)
        }
        for x in pk.list("cases") {
            let got = Enc.pickKey(held, conv: x.str("conv") ?? pk.str("conv")!, lists: x.str("lists") ?? pk.str("lists")!, now: x.int("now")!)?.K
            XCTAssertTrue(same(got, x["expect"]), x.str("name") ?? "")
        }
        let ac = try chain(v.dict("asks")["lists"], K["sam"]!)
        for x in v.dict("asks").list("cases") {
            let e = try event(x["event"])
            let got: Any
            if e.kind == 8574 { got = Enc.readAsk(e, account: K["sam"]!, chain: ac).map { ["device": $0.device, "id": $0.id, "at": $0.at] as NSDictionary } ?? NSNull() }
            else {
                got = Enc.readAnswer(e, account: K["sam"]!, chain: ac, about: x.str("about")).map {
                    let d: NSMutableDictionary = ["by": $0.by, "answer": $0.answer, "at": $0.at]
                    if let a = $0.ask { d["ask"] = a }
                    if let dv = $0.device { d["device"] = dv }
                    return d
                } ?? NSNull()
            }
            XCTAssertTrue(same(got, x["expect"]), x.str("name") ?? "")
        }
    }

    // ---- byte for byte: what this app writes is what the web wrote ----------------------------------

    func list(_ name: String) throws -> NostrEvent { try event(v.dict("lists").dict("valid").dict(name)["event"]) }

    func testPeopleEnvelopesAndMessagesByteForByte() throws {
        let L1 = try list("L1"), L2 = try list("L2"), L3 = try list("L3")
        let c3 = try XCTUnwrap(Enc.chainOf([L1, L2, L3], belfry: B, account: K["sam"]!))
        let kr = try event(v.dict("people_key")["key_rumor"])
        let kp = Enc.newKey(sk("conv-key-1"))
        // the key rumor itself
        let LC1 = try list("LC1")
        let mine = Enc.keyRumor(maker: K["d2"]!, k: kp.k, people: [(K["sam"]!, L3.id), (K["lina"]!, LC1.id)], at: 3100)
        XCTAssertEqual(mine.id, kr.id)
        XCTAssertEqual(mine.tags, kr.tags)
        let envs = try Enc.peopleEnvelopes(maker: sk("d2"), rumor: mine, people: [(K["sam"]!, Enc.receivers(c3.current)), (K["lina"]!, [K["c1"]!])], fixed: fixed("env1", 3100))
        let want = try evs(v.dict("people_key")["envelopes"])
        XCTAssertEqual(envs.count, want.count)
        for (a, b) in zip(envs, want) { XCTAssertEqual(a.id, b.id); XCTAssertEqual(a.sig, b.sig); XCTAssertEqual(a.content, b.content) }
        let r1 = try event(v.dict("people_messages")["rumor"])
        let msgs = try Enc.peopleMessage(device: sk("d2"), rumor: r1, K: kp.K, people: [K["sam"]!, K["lina"]!], me: K["sam"]!, fixed: fixed("m1", 3300))
        let wantM = try evs(v.dict("people_messages")["messages"])
        for (a, b) in zip(msgs, wantM) { XCTAssertEqual(a.id, b.id); XCTAssertEqual(a.content, b.content); XCTAssertEqual(a.sig, b.sig) }
    }

    func testGroupEnvelopesAndMessageByteForByte() throws {
        let gk = Enc.newKey(sk("group-key-1"))
        let many = (0..<300).map { Enc.pub(sk("g\($0)")) }
        let L3 = try list("L3"), LC1 = try list("LC1")
        let devices = [K["d2"]!, K["c1"]!] + many
        let templ = try Enc.groupEnvelopes(maker: sk("d2"), k: gk.k, group: "pod-garden-7f3a", devices: devices,
                                           lists: Enc.listsHash([(K["sam"]!, L3.id), (K["lina"]!, LC1.id)]), fixed: fixed("genv", 3200))
        let signed = try templ.map { try Enc.signWith(sk("sam"), kind: $0.kind, createdAt: $0.createdAt, tags: $0.tags, content: $0.content, aux: aux) }
        let want = try evs(v.dict("group_key")["envelopes"])
        XCTAssertEqual(signed.count, want.count)
        for (a, b) in zip(signed, want) { XCTAssertEqual(a.id, b.id); XCTAssertEqual(a.content, b.content) }
        let gr = try XCTUnwrap(Enc.openGroupMessage(k: gk.k, try event(v.dict("group_messages").list("cases")[0]["message"])).rumor)
        let t = try Enc.groupMessage(device: sk("d2"), rumor: gr, K: gk.K, group: "pod-garden-7f3a", fixed: fixed("gm", 3400), mentions: [K["lina"]!])
        let gm = try Enc.signWith(sk("sam"), kind: t.kind, createdAt: t.createdAt, tags: t.tags, content: t.content, aux: aux)
        let wantG = try event(v.dict("group_messages").list("cases")[0]["message"])
        XCTAssertEqual(gm.id, wantG.id)
        XCTAssertEqual(gm.content, wantG.content)
    }

    func testPacksByteForByte() throws {
        let kr = try event(v.dict("people_key")["key_rumor"])
        let gk = Enc.newKey(sk("group-key-1"))
        let v1 = Enc.newKey(sk("letterbox-1"))
        let keys: [Enc.PackKey] = [.people(kr), .group(k: gk.k, K: gk.K, group: "pod-garden-7f3a"), .v1(secret: v1.k, lb: v1.K)]
        let p1 = try Enc.packs(sharer: sk("d2"), account: K["sam"]!, to: K["d4"]!, keys: keys, fixed: fixed("p1", 4100))
        let want = try event(v.dict("packs").list("cases")[0]["pack"])
        XCTAssertEqual(p1.first?.id, want.id)
        XCTAssertEqual(p1.first?.content, want.content)
        // 400 version-1 secrets split over several packs
        let manyV1: [Enc.PackKey] = (0..<400).map { let x = Enc.newKey(sk("lb\($0)")); return .v1(secret: x.k, lb: x.K) }
        let p4 = try Enc.packs(sharer: sk("d2"), account: K["sam"]!, to: K["d4"]!, keys: manyV1, fixed: fixed("p4", 4100))
        XCTAssertEqual(p4.count, v.dict("packs").dict("split").int("expect_packs"))
        let c = try chain(v.dict("packs")["lists"], K["sam"]!)
        let total = p4.reduce(0) { $0 + (Enc.openPack(device: sec("d4"), account: K["sam"]!, $1, chain: c)?.keys.count ?? 0) }
        XCTAssertEqual(total, v.dict("packs").dict("split").int("expect_total_keys"))
        // asks and answers too
        let ask4 = try Enc.askEvent(device: sk("d4"), account: K["sam"]!, at: 4050, aux: aux)
        XCTAssertEqual(ask4.id, try event(v.dict("asks").list("cases")[0]["event"]).id)
    }
}
