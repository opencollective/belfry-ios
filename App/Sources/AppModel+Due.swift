import BelfryCore
import Foundation

// The to-do's due date (one shape, docs/one-shape.md §3): its author's kind 1010 edit, which keeps
// the 2100's text and every other tag and carries ["due", unix seconds] (none clears it).

extension AppModel {
    func setTodoDue(_ t: TodoTask, in group: String, due: Int?) {
        guard t.author == me, let e = derive.todoEvent(t.id) else { return }
        engine?.enqueue(Actions.setTaskDue(e, title: e.content, due: due, current: derive.todoCurrentTags(t.id)))
    }

    /// The author's description (Markdown, ≤ 2000); empty removes it. The due date stays.
    func setTodoDescription(_ t: TodoTask, in group: String, _ text: String) {
        guard t.author == me, let e = derive.todoEvent(t.id) else { return }
        engine?.enqueue(Actions.editTask(e, current: derive.todoCurrentTags(t.id), title: e.content, due: t.due, description: text))
    }
}
