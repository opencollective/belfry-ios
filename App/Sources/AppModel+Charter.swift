import BelfryCore
import Foundation

// The charter's actions (SPEC 19.32): everything goes through the outbox into the `charter` group.

extension AppModel {
    /// My tick on RULE (or taking it back).
    func agree(_ rule: Agreement, _ on: Bool) {
        engine?.enqueue(Actions.agree(rule.id, on))
    }

    /// A steward adds a rule (making the charter's group with the first one) or edits one.
    func saveAgreement(_ editing: Agreement?, title: String, about: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let engine else { return }
        if let r = editing {
            engine.enqueue(Actions.editAgreement(r.id, title: t, about: about, order: r.order == Int.max ? 0 : r.order))
            return
        }
        if derive.charterGroup == nil {
            for dr in Actions.createCharter() { engine.enqueue(dr) }
        }
        let next = (derive.charter().map { $0.order == Int.max ? 0 : $0.order }.max() ?? 0) + 1
        engine.enqueue(Actions.addAgreement(title: t, about: about, order: next))
    }

    func removeAgreement(_ rule: Agreement) {
        engine?.enqueue(Actions.removeAgreement(rule.id))
    }

    /// A steward's new order (only the rules whose place changed get an edit) and removals.
    func reorderCharter(_ rules: [Agreement], removed: [Agreement]) {
        guard let engine else { return }
        for r in removed { engine.enqueue(Actions.removeAgreement(r.id)) }
        for (i, r) in rules.enumerated() where r.order != i + 1 {
            engine.enqueue(Actions.editAgreement(r.id, title: r.title, about: r.about, order: i + 1))
        }
    }
}
