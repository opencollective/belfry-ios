import BelfryCore
import SwiftUI

// The charter (SPEC 19.32, boards Charter and Join-Member 2): a short list of agreements every
// person ticks for themselves. Members: "You agreed · <date>", their own ticks, a count under each
// rule. Stewards also write, edit, reorder and remove rules, and a count opens Agreed / Not yet.
// No charter yet: stewards see "Write the first agreement"; nobody else has a Charter row.
// Also: My to-dos (Home's tile), across the channels and groups I'm in.

struct CharterView: View {
    @EnvironmentObject var model: AppModel
    @State private var writing = false
    @State private var editing: Agreement?
    @State private var ordering = false
    @State private var who: Agreement?

    var body: some View {
        let _ = model.version
        let d = model.derive
        // the group's own agreements, or the public copy for those who can't read it (guests)
        let rules = model.charterRules
        let readable = d.charterGroup != nil || !d.charter().isEmpty
        let steward = d.isCommunityAdmin
        let members = model.memberKeys
        List {
            if rules.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No agreements yet", systemImage: "checkmark.seal")
                    } description: {
                        Text("A charter is a short list of agreements. Everyone who joins ticks each one; members see new ones on Home.")
                    } actions: {
                        if steward {
                            Button("Write the first agreement") { hideKeyboard(); writing = true }.buttonStyle(.brand)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Our charter").font(.title2.bold())
                        Text(header(rules)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(rules) { r in
                        AgreementRow(rule: r, members: members, steward: steward && readable, showCount: readable,
                                     edit: { editing = r }, who: { who = r })
                    }
                } footer: {
                    if steward { Text("Changing a rule's words asks everyone to agree to that rule again.") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Charter")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if steward && !rules.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { writing = true } label: { Label("New agreement", systemImage: "plus") }
                        Button { ordering = true } label: { Label("Reorder or remove", systemImage: "arrow.up.arrow.down") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Edit the charter")
                }
            }
        }
        .sheet(isPresented: $writing) { AgreementForm(editing: nil) }
        .sheet(item: $editing) { AgreementForm(editing: $0) }
        .sheet(isPresented: $ordering) { CharterOrderSheet() }
        .navigationDestination(item: $who) { WhoAgreed(rule: $0).overRoot() }
        .task { await model.loadPublicCharter() }
        .onAppear {
            switch model.launch.screen {
            case "whoagreed": DispatchQueue.main.asyncAfter(deadline: .now() + 3) { who = model.derive.charter().last }
            case "agreement": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { writing = true }
            default: break
            }
        }
    }

    private func header(_ rules: [Agreement]) -> String {
        let d = model.derive
        if let at = d.charterAgreedAt() {
            return "You agreed · " + Date(timeIntervalSince1970: TimeInterval(at)).formatted(.dateTime.day().month(.abbreviated))
        }
        let left = rules.filter { $0.agreed[model.me] == nil }.count
        if d.amGuest { return "\(rules.count) short agreements" }
        return left == rules.count ? "Tick each one you agree to." : (left == 1 ? "1 new since you agreed" : "\(left) to read")
    }
}

/// One rule: my tick, its title and line, how many members agreed (a steward taps it for who).
private struct AgreementRow: View {
    @EnvironmentObject var model: AppModel
    let rule: Agreement
    let members: Set<String>
    let steward: Bool
    var showCount = true
    let edit: () -> Void
    let who: () -> Void

    var body: some View {
        let mine = rule.agreed[model.me] != nil
        let isNew = !mine
        let count = rule.agreed.keys.filter { members.contains($0) }.count
        HStack(alignment: .top, spacing: 12) {
            if !model.derive.amGuest {
                Button { model.agree(rule, !mine) } label: {
                    Image(systemName: mine ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(mine ? Color.brand : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mine ? "Agreed: \(rule.title)" : "Agree: \(rule.title)")
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.title).font(.body.weight(.semibold))
                    if isNew && !model.derive.amGuest { Chip(text: rule.stale.contains(model.me) ? "CHANGED" : "NEW", tint: .orange) }
                }
                if !rule.about.isEmpty { AgreementAbout(title: rule.title, text: rule.about) }
                if showCount { Button(action: steward ? who : {}) {
                    HStack(spacing: 4) {
                        Text(countLine(count))
                        if steward { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)) }
                    }
                    .font(.caption).foregroundStyle(steward ? Color.brand : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!steward) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .listRowBackground(isNew && !model.derive.amGuest ? Color.orange.opacity(0.08) : nil)
        .contextMenu {
            if steward {
                Button { edit() } label: { Label("Edit", systemImage: "pencil") }
            }
        }
        .swipeActions(edge: .trailing) {
            if steward { Button { edit() } label: { Label("Edit", systemImage: "pencil") }.tint(.gray) }
        }
    }

    private func countLine(_ n: Int) -> String {
        var s = "\(n) of \(max(members.count, n)) agreed"
        if rule.textAt > rule.addedAt || Int.now - rule.addedAt < 14 * 86400 {
            s = (rule.textAt > rule.addedAt ? "Changed " : "Added ") + Date(timeIntervalSince1970: TimeInterval(rule.textAt)).formatted(.dateTime.day().month(.abbreviated)) + " · " + s
        }
        return s
    }
}

/// A steward writes or edits a rule: a title and an optional one-line explanation.
struct AgreementForm: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: Agreement?
    @State private var title = ""
    @State private var about = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("A short rule", text: $title, axis: .vertical).lineLimit(1...3).font(.body)
                    TextField("One line to explain it (optional)", text: $about, axis: .vertical).lineLimit(1...3).font(.body)
                } footer: {
                    Text(editing == nil ? "Everyone ticks it for themselves; members see it on Home until they do."
                                        : "Changing the words asks everyone to agree to this rule again.")
                }
                if let editing {
                    Section {
                        BusyButton(role: .destructive) { model.removeAgreement(editing); dismiss() } label: { Text("Remove this agreement") }
                    }
                }
            }
            .navigationTitle(editing == nil ? "New agreement" : "Edit agreement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton(editing == nil ? "Add" : "Save") {
                        model.saveAgreement(editing, title: title, about: about)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                title = editing?.title ?? ""
                about = editing?.about ?? ""
            }
        }
        .presentationDetents([.medium, .large])
        .solidSheet()
    }
}

/// Reorder or remove the rules (stewards).
private struct CharterOrderSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rules = [Agreement]()
    @State private var removed = [Agreement]()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(rules) { r in Text(r.title) }
                    .onMove { rules.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { idx in removed += idx.map { rules[$0] }; rules.remove(atOffsets: idx) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder or remove")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Save") {
                        model.reorderCharter(rules, removed: removed)
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                rules = model.derive.charter()
            }
        }
    }
}

/// Who has and hasn't agreed to one rule (members). A tap opens their profile.
private struct WhoAgreed: View {
    @EnvironmentObject var model: AppModel
    let rule: Agreement
    @State private var tab = 0

    var body: some View {
        let members = model.memberKeys
        let yes = members.filter { rule.agreed[$0] != nil }.sorted { model.name($0) < model.name($1) }
        let not = members.filter { rule.agreed[$0] == nil }.sorted { model.name($0) < model.name($1) }
        List {
            Section {
                Picker("Who", selection: $tab) {
                    Text("Agreed · \(yes.count)").tag(0)
                    Text("Not yet · \(not.count)").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(tab == 0 ? yes : not, id: \.self) { pk in
                    ProfileRow(pubkey: pk, detail: rule.stale.contains(pk) && tab == 1 ? "before the change" : nil)
                }
            } footer: {
                if tab == 1 { Text("Members who haven't agreed see the rule on their Home. Guests aren't counted.") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(rule.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ---- My to-dos --------------------------------------------------------------------------------

struct MyTodosView: View {
    @EnvironmentObject var model: AppModel
    @State private var open: TodoKey?
    var body: some View {
        let _ = model.version
        let t = model.myTodos
        List {
            if t.onMe.isEmpty && t.open.isEmpty {
                ContentUnavailableView("No to-dos", systemImage: "checkmark.circle",
                                       description: Text("To-dos made in your channels and groups show here."))
                    .listRowBackground(Color.clear)
            }
            if !t.onMe.isEmpty { Section("On you") { ForEach(t.onMe) { r in TodoLine(ref: r) { open = TodoKey(group: r.group, task: r.task.id) } } } }
            if !t.open.isEmpty { Section("Open · nobody on it yet") { ForEach(t.open) { r in TodoLine(ref: r) { open = TodoKey(group: r.group, task: r.task.id) } } } }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("My to-dos")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $open) { k in TodoScreen(key: k).overRoot() }
    }
}

private struct TodoLine: View {
    @EnvironmentObject var model: AppModel
    let ref: TodoRef
    let open: () -> Void
    var body: some View {
        let name = model.derive.label(ref.group)
        TodoRow(t: ref.task, group: ref.group, subtitle: name, open: open)
    }
}

/// An agreement's explanation: up to two lines; when it is cut, "more" opens the whole text (Xavier,
/// 2026-11-18: the charter, the first minutes, the apply sheet, the Home reminder). The full height is
/// measured once on a hidden copy (a short static list, not a hot path).
struct AgreementAbout: View {
    let title: String
    let text: String
    var font: Font = .subheadline
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    @State private var reading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(font).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                .background(alignment: .topLeading) {
                    Text(text).font(font).fixedSize(horizontal: false, vertical: true).hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                        .accessibilityHidden(true)
                }
            if fullHeight > shownHeight + 1 {
                Button("more") { reading = true }
                    .font(font.weight(.medium))
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Read all of \(title)")
            }
        }
        .sheet(isPresented: $reading) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title).font(.title3.weight(.semibold))
                        Text(text).font(.body).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle("Agreement")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { reading = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// A row of agreements to tick (the first minutes, the apply sheet): the tick, the title, two lines
/// of the explanation with "more". The row toggles the tick; "more" is its own button.
struct TickAgreementRow: View {
    let rule: Agreement
    let on: Bool
    var titleWeight: Font.Weight = .semibold
    var tickFont: Font = .title2
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle").font(tickFont).foregroundStyle(on ? Color.brand : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.title).font(.body.weight(titleWeight)).foregroundStyle(.primary)
                if !rule.about.isEmpty { AgreementAbout(title: rule.title, text: rule.about) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: on ? "Untick" : "Tick", toggle)
    }
}
