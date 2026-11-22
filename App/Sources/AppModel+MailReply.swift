import BelfryCore
import Foundation

// One shape's e-mail thread (collective-belfry docs/one-shape.md §4): Reply all is the only reply
// (one rcpt-to per person: the sender, then To and Cc of its latest e-mail, ours left out), an
// internal draft is a kind 1111 with ["mail-draft","1"], and the app that sent a reply labels the
// thread `answered` once the delivery report says delivered.

extension AppModel {
    /// "Re: …", the recipients and the draft a reply all would use.
    func replyAllSend(_ t: InboxThread, in group: String, text: String, subject: String, draft: String?) async -> Result<String, ApiError> {
        guard let dms, let last = t.lastIn else { return .failure(ApiError("signer", 0, "Not signed in.")) }
        let r = t.replyAll(domain: config.domain)
        guard let to = r.to else { return .failure(ApiError("mail", 0, "There is nobody to answer.")) }
        let d = derive
        let refs = t.refs.filter { $0 != last.messageId }.suffix(10).joined(separator: " ")
        let subj = subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppModel.replySubject(t) : subject
        if isDemo {
            // what the bridge would post, and the label the delivered report would bring
            let mid = "<\(UUID().uuidString.lowercased())@\(config.domain)>"
            var tags: [Tag] = [["h", group], ["subject", subj], ["mail-to", to], ["sent-by", me], ["message-id", mid], ["e", last.m.id, "", "reply"],
                               ["client", "belfry-mail-out"], ["to", to, last.name]]
            tags += r.cc.map { a in ["cc", a, last.ccList.first { $0.address == a }?.name ?? last.toList.first { $0.address == a }?.name ?? ""] }
            if let draft { tags.append(["draft", draft]) }
            if let e = try? Demo.signer("groups").signNow(EventTemplate(kind: 9, content: text, tags: tags, createdAt: Int.now)) {
                engine?.add([e], verify: false)
            }
            engine?.enqueue(Actions.markAnswered(group, card: t.id))
            return .success("")
        }
        do {
            let id = try await dms.sendAsChannel(channel: group, local: d.mailLocal(group), channelName: self.group(group)?.name ?? group, to: to,
                                                 subject: subj, text: text, inReplyTo: last.messageId, references: refs.isEmpty ? nil : refs,
                                                 cardId: last.m.id, myName: realName(me), cc: r.cc, draft: draft)
            watchAnswered(id, card: t.id, in: group)
            return .success(id)
        } catch let e as BelfryError {
            return .failure(ApiError("mail", 0, e.errorDescription ?? "The e-mail could not be prepared. Try again."))
        } catch {
            return .failure(ApiError("mail", 0, "The e-mail could not be prepared. Try again."))
        }
    }

    /// Answered is automatic: once the delivery report says delivered, label the first card.
    private func watchAnswered(_ emailId: String, card: String, in group: String) {
        Task { @MainActor [weak self] in
            for wait in [5, 10, 20, 30, 60, 90, 120] {
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                guard let self, let r = self.dms?.report(emailId) else { return }
                if r.status == "delivered" {
                    self.engine?.enqueue(Actions.markAnswered(group, card: card))
                    return
                }
                if r.status == "failed" { return }
            }
        }
    }

    /// Save an internal draft (new) or change mine (the author's 1010 edit).
    func saveMailDraft(_ t: InboxThread, in group: String, text: String, editing: Message?) {
        if let editing { edit(editing, in: group, text: text); return }
        guard let card = t.root?.ev else { return }
        engine?.enqueue(Actions.mailDraft(group, card: card, text: text))
    }

    func markAnswered(_ t: InboxThread, in group: String) {
        engine?.enqueue(Actions.markAnswered(group, card: t.id))
    }
}
