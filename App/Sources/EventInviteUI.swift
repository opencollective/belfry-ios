import SwiftUI
import BelfryCore

extension AppModel {
    /// A host invites members to an event: a new version naming them, and one line in its chat.
    func inviteToEvent(_ e: CalEvent, _ keys: [String]) {
        for dr in EventInvites.invite(e, keys) { engine?.enqueue(dr) }
    }
}

/// "Invite people" to an event (board events/event-invite; a pushed screen on iPhone): members
/// only, search and ticks, no roles. Invite is top right.
struct EventInviteScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let e: CalEvent
    @State private var q = ""
    @State private var picked = [String]()

    var body: some View {
        let people = model.derive.invitable(e, q)
        List {
            if people.isEmpty {
                Text(q.isEmpty ? "Every member is invited or going already." : "No member with that name.")
                    .foregroundStyle(.secondary)
            }
            ForEach(people, id: \.self) { k in
                Button {
                    if let i = picked.firstIndex(of: k) { picked.remove(at: i) } else { picked.append(k) }
                } label: {
                    HStack(spacing: 10) {
                        Avatar(pubkey: k, size: 32)
                        Text(model.name(k)).foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        Image(systemName: picked.contains(k) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(picked.contains(k) ? Color.brand : Color.secondary.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked.contains(k) ? .isSelected : [])
            }
        }
        .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search members")
        .navigationTitle("Invite people")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(picked.isEmpty ? "Invite" : "Invite \(picked.count)") {
                    model.inviteToEvent(e, picked)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                }
                .disabled(picked.isEmpty)
                .accessibilityIdentifier("event-invite-send")
            }
        }
        .onAppear {
            if model.launch.screen == "eventinvite", picked.isEmpty { picked = Array(people.prefix(2)) }
        }
    }
}

/// "‹host› invited ‹names›" in an event's chat (board events/event-invited-line): a system line,
/// names never ids.
struct InvitedLine: View {
    @EnvironmentObject var model: AppModel
    let by: String
    let people: [String]
    let at: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "envelope.open").font(.footnote).foregroundStyle(.secondary).frame(width: 22)
            Text(text).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Text(Format.time(at)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        let names = people.map(model.name)
        let list = names.count <= 1 ? (names.first ?? "") : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return (by == model.me ? "You" : model.name(by)) + " invited " + list
    }
}

/// An event chat with nothing said yet (Xavier, 2026-11-22; board events/event-empty-menu): a
/// short menu in place of "… is new · Invite people": Copy URL, QR code, the public page (not
/// for a members-only event), and for hosts Invite a co-host and Invite people.
struct EventQuickMenu: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    @State private var qr = false
    @State private var inviting = false
    @State private var copied = false
    @State private var coHost: String?
    @State private var error: String?

    var body: some View {
        let d = model.derive
        let url = d.eventURL(e)
        let host = d.isHost(e)
        VStack(alignment: .leading, spacing: 0) {
            row(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy URL", id: "quick-copy") {
                UIPasteboard.general.string = url
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            }
            Divider().padding(.leading, 52)
            row("qrcode", "QR code", id: "quick-qr") { hideKeyboard(); qr = true }
            if e.visibility != .members, let u = URL(string: url) {
                Divider().padding(.leading, 52)
                row("safari", "Open the public page", id: "quick-public") { UIApplication.shared.open(u) }
            }
            if host, !e.meeting {
                Divider().padding(.leading, 52)
                BusyButton {
                    switch await model.coHostLink(e) {
                    case .success(let u): coHost = u; UIPasteboard.general.string = u; UINotificationFeedbackGenerator().notificationOccurred(.success)
                    case .failure(let x): error = x.message
                    }
                } label: { label("person.badge.plus", coHost == nil ? "Invite a co-host" : "Co-host link copied") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("quick-cohost")
                Divider().padding(.leading, 52)
                row("person.2", "Invite people", id: "quick-invite") { hideKeyboard(); inviting = true }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 16).padding(.top, 6) }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .navigationDestination(isPresented: $inviting) { EventInviteScreen(e: e) }
        .sheet(isPresented: $qr) {
            NavigationStack {
                List { QRRow(url: url).listRowBackground(Color.clear) }
                    .navigationTitle(e.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { qr = false } } }
            }
            .presentationDetents([.medium])
        }
    }

    private func label(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .contentShape(Rectangle())
    }

    private func row(_ symbol: String, _ title: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { label(symbol, title) }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
    }
}
