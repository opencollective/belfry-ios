import BelfryCore
import SwiftUI

// Belfry settings → Roles (web Settings.tsx / RolePicker.tsx, docs/roles.md): every role with its
// line, the default for new members, add / rename / describe / delete (Member and Admin are
// built in). Belfry admins only; errors are fixed words per code.

struct RolesSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Role?
    @State private var adding = false

    var body: some View {
        let info = model.roles
        List {
            Section {
                ForEach(info.roles) { r in
                    Button { editing = r } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(r.label).foregroundStyle(.primary)
                                    if r.isDefault { Text("Default").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 1).background(Color.secondary.opacity(0.12), in: Capsule()) }
                                }
                                if !r.description.isEmpty { Text(r.description).font(.footnote).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            let n = info.members.values.filter { $0 == r.id }.count
                            if n > 0 { Text("\(n)").foregroundStyle(.secondary).monospacedDigit() }
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: { Text("Every member has one role: a label people see on profiles and in member lists. Steward is the only role with powers.") }
            Section {
                Button { adding = true } label: { Label("New role", systemImage: "plus") }
            }
        }
        .navigationTitle("Roles")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadRoles(force: true) }
        .refreshable { await model.loadRoles(force: true) }
        .sheet(item: $editing) { r in RoleForm(role: r) }
        .sheet(isPresented: $adding) { RoleForm(role: nil) }
    }
}

struct RoleForm: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let role: Role?
    @State private var label = ""
    @State private var about = ""
    @State private var makeDefault = false
    @State private var error: String?
    @State private var loaded = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label).font(.body)
                    TextField("What it means (optional)", text: $about, axis: .vertical).lineLimit(2...4).font(.body)
                }
                if role?.id != Role.admin {
                    Section {
                        Toggle("Default for new members", isOn: $makeDefault).tint(Theme.toggle)
                    } footer: { Text("Invites start on it. Changing it never relabels people who have a role.") }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
                if let role, !role.builtin {
                    Section {
                        Button("Delete this role", role: .destructive) { confirmDelete = true }
                    } footer: { Text("Who has it gets the default role.") }
                }
            }
            .navigationTitle(role == nil ? "New role" : role!.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton(role == nil ? "Add" : "Save") { await save() }.disabled(label.jsTrim().isEmpty)
                }
            }
            .confirmationDialog("Delete \(role?.label ?? "")?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: { Text("Who has this role gets the default role.") }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                label = role?.label ?? ""; about = role?.description ?? ""; makeDefault = role?.isDefault ?? false
            }
        }
        .presentationDetents([.medium, .large])
        .solidSheet()
    }

    private func save() async {
        error = nil
        if model.engine?.localOnly == true {
            var list = model.roles
            if let role, let i = list.roles.firstIndex(where: { $0.id == role.id }) {
                list.roles[i].label = label.jsTrim(); list.roles[i].description = about.jsTrim()
            } else {
                list.roles.insert(Role(id: label.lowercased(), label: label.jsTrim(), description: about.jsTrim()), at: max(0, list.roles.count - 1))
            }
            model.roles = list
            dismiss()
            return
        }
        do {
            model.roles = try await model.api.saveRole(id: role?.id, label: label.jsTrim(), description: about.jsTrim(),
                                                       makeDefault: role?.id == Role.admin ? nil : makeDefault)
            dismiss()
        } catch let e as ApiError { error = e.message } catch { self.error = BelfryAPI.network }
    }

    private func delete() async {
        guard let role else { return }
        do {
            model.roles = try await model.api.deleteRole(role.id)
            dismiss()
        } catch let e as ApiError { error = e.message } catch { self.error = BelfryAPI.network }
    }
}
