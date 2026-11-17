import Foundation

// Buttons on messages (SPEC 19.36; collective-belfry docs/actions.md, vectors/message-actions.json).
// The message carries up to four ["button", id, label, style, action] tags; a press is a kind 1985
// label (L belfry/action) signed by whoever tapped; the handler answers with a kind 1985 label
// (L belfry/action-result). Only the handler's answers count: the message's author for a button
// without action, the belfry key or the groups key for a `belfry:` action.

public struct MessageButton: Hashable, Sendable, Identifiable {
    public enum Style: String, Sendable { case plain = "", primary, danger }
    public let id: String
    public let label: String
    public let style: Style
    /// "" = the message's author handles it; "belfry:<name>" = the belfry does.
    public let action: String

    public init(id: String, label: String, style: Style = .plain, action: String = "") {
        self.id = id
        self.label = label
        self.style = style
        self.action = action
    }

    public var isBelfry: Bool { action.hasPrefix("belfry:") }
    /// A `belfry:` action this app knows (else: disabled, "Update the app to use this.").
    public var known: Bool { !isBelfry || Buttons.knownActions.contains(action) }
}

public struct ButtonState: Hashable, Sendable {
    public enum Status: String, Sendable { case waiting, ok, error }
    public struct Mine: Hashable, Sendable {
        public var status: Status
        public var code: String?
        public var text: String
        /// The press it answers (or waits for).
        public var press: String
        public var button: String
        public var pressedAt: Int
    }
    /// Finished for everyone: the latest closing answer's text replaces the buttons.
    public var closed = false
    public var closedText = ""
    /// My latest press and its latest answer (nil: I never pressed).
    public var mine: Mine?

    /// Locked: my press has no answer yet and is younger than 20 seconds.
    public func locked(now: Int) -> Bool {
        guard let m = mine, m.status == .waiting else { return false }
        return now - m.pressedAt < Buttons.answerWait
    }

    /// My press has no answer after 20 seconds: "No answer yet." and the buttons unlock.
    public func timedOut(now: Int) -> Bool {
        guard let m = mine, m.status == .waiting else { return false }
        return now - m.pressedAt >= Buttons.answerWait
    }
}

public enum Buttons {
    public static let actionNS = "belfry/action"
    public static let resultNS = "belfry/action-result"
    public static let maxButtons = 4
    public static let answerWait = 20
    public static let websitePublish = "belfry:website-publish"
    /// The `belfry:` actions this app knows (docs/actions.md section 4).
    public static let knownActions: Set<String> = [websitePublish]

    /// Fixed sentences (vectors `fixed_text`): by error code, "" = an unknown code.
    public static let fixed: [String: String] = [
        "not_allowed": "You're not allowed to do this.",
        "unknown_action": "This belfry doesn't know this button yet.",
        "no_target": "This message doesn't say what to act on.",
        "gone": "This is no longer there.",
        "expired": "That took too long. Try again.",
        "failed": "That didn't work. Try again.",
        "": "That didn't work.",
    ]
    public static let timeoutText = "No answer yet."
    public static let unknownActionText = "Update the app to use this."
    public static let unsentText = "Couldn't send. Check the connection and try again."

    static let idRx = Rx("^[a-z0-9-]{1,32}$")

    /// The buttons of a message's TAGS, in tag order: broken tags, a repeated id and a fifth
    /// button are ignored; an unknown style reads as plain; the label is trimmed (1–40 characters).
    public static func parse(_ tags: [Tag]) -> [MessageButton] {
        var out = [MessageButton]()
        for t in tags where t.first == "button" && t.count >= 3 {
            let id = t[1]
            let label = t[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard idRx.test(id), !label.isEmpty, label.count <= 40, !out.contains(where: { $0.id == id }) else { continue }
            let style = MessageButton.Style(rawValue: t.count > 3 ? t[3] : "") ?? .plain
            out.append(MessageButton(id: id, label: label, style: style, action: t.count > 4 ? t[4] : ""))
            if out.count == maxButtons { break }
        }
        return out
    }

    /// The press of BUTTON on message ID by AUTHOR in GROUP (sent at once, not through the outbox).
    public static func press(messageId: String, author: String, group: String, button: String) -> Draft {
        Draft(kind: 1985, tags: [["L", actionNS], ["l", button, actionNS], ["e", messageId], ["p", author], ["h", group]])
    }

    /// The question asked before a `belfry:` action: the app's own text, never the button's label.
    public static func confirmText(_ action: String, domain: String) -> String? {
        switch action {
        case websitePublish: return "Publish this version as the website? Everyone will see it at https://\(domain)."
        default: return nil
        }
    }

    /// The confirming button of that question.
    public static func confirmVerb(_ action: String) -> String {
        action == websitePublish ? "Publish" : "Continue"
    }

    /// The sentence for an error answer: its content, else the fixed text of its code.
    public static func errorText(code: String?, content: String) -> String {
        let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { return c }
        return fixed[code ?? ""] ?? fixed[""]!
    }

    /// Who may answer a press of BUTTON on a message by AUTHOR.
    public static func handlers(_ button: MessageButton?, author: String, belfryKeys: Set<String>) -> Set<String> {
        guard let button else { return [] }
        return button.isBelfry ? belfryKeys : [author]
    }

    static func isPress(_ e: NostrEvent) -> Bool { e.kind == 1985 && e.tags.contains { $0.count >= 2 && $0[0] == "L" && $0[1] == actionNS } }
    static func isAnswer(_ e: NostrEvent) -> Bool { e.kind == 1985 && e.tags.contains { $0.count >= 2 && $0[0] == "L" && $0[1] == resultNS } }
    static func label(_ e: NostrEvent, _ ns: String) -> String? {
        e.tags.first { $0.count >= 3 && $0[0] == "l" && $0[2] == ns }?[1]
    }

    /// The state of the buttons of MESSAGE (id, author) for ME, from the presses and answers that
    /// point at it (`e` = the message id). BELFRYKEYS = the belfry key and the groups key.
    public static func state(messageId: String, author: String, buttons: [MessageButton], me: String,
                             events: [NostrEvent], belfryKeys: Set<String>) -> ButtonState {
        var st = ButtonState()
        let presses = events.filter { isPress($0) && $0.tag("e") == messageId }
        let byId = Dictionary(presses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func button(_ id: String?) -> MessageButton? { buttons.first { $0.id == id } }
        // an answer counts when its signer handles the button pressed; for a press this device
        // never saw (someone else's), when its signer handles one of the message's buttons
        func trusted(_ a: NostrEvent) -> Bool {
            if let p = a.tag("press"), let press = byId[p] {
                return handlers(button(label(press, actionNS)), author: author, belfryKeys: belfryKeys).contains(a.pubkey)
            }
            return buttons.contains { handlers($0, author: author, belfryKeys: belfryKeys).contains(a.pubkey) }
        }
        let answers = events.filter { isAnswer($0) && $0.tag("e") == messageId && trusted($0) }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
        if let c = answers.last(where: { label($0, resultNS) == "ok" && $0.tag("closed") == "1" }) {
            st.closed = true
            st.closedText = c.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let mine = presses.filter { $0.pubkey == me && button(label($0, actionNS)) != nil }
            .max { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
        if let p = mine {
            var m = ButtonState.Mine(status: .waiting, code: nil, text: "", press: p.id, button: label(p, actionNS) ?? "", pressedAt: p.createdAt)
            if let a = answers.last(where: { $0.tag("press") == p.id }) {
                if label(a, resultNS) == "ok" {
                    m.status = .ok
                    m.text = a.content.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    m.status = .error
                    m.code = a.tag("code")
                    m.text = errorText(code: m.code, content: a.content)
                }
            }
            st.mine = m
        }
        return st
    }
}

extension Derive {
    /// The keys that answer `belfry:` buttons: the belfry key and the groups key.
    public var belfryKeys: Set<String> { Set([ctx.belfryKey, ctx.groupsKey].compactMap { $0 }) }

    /// The buttons of message M (none on e-mail cards and other special messages).
    public func buttons(_ m: Message) -> [MessageButton] {
        guard m.ev.kind == 9 || m.ev.kind == 1111 else { return [] }
        return Buttons.parse(m.ev.tags)
    }

    /// The state of M's buttons for me.
    public func buttonState(_ m: Message) -> ButtonState {
        let bs = buttons(m)
        if bs.isEmpty { return ButtonState() }
        return Buttons.state(messageId: m.ev.id, author: m.ev.pubkey, buttons: bs, me: ctx.me,
                             events: actionLabels[m.ev.id] ?? [], belfryKeys: belfryKeys)
    }
}
