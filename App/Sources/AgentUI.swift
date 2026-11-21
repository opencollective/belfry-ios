import BelfryCore
import SwiftUI

// Add an agent (the owner, 2026-11-16): on my own profile, members only. An agent is an AI
// (ChatGPT, Claude, Grok…) that follows conversations for me and posts as my agent, always shown
// as mine. The sheet makes a one-agent link (POST /api/v1/channel-invites {"channel": "general",
// "agent": true}: it joins as my own agent and the belfry mirrors it into my channels) and shows
// a one-line prompt with the instructions' address from the belfry's answer (`agent_url`), never
// built from typed text. With my agent there already (one per member by default), the section
// shows it with "Remove this agent…" instead of the button; stewards may have more.

struct AgentSection: View {
    @EnvironmentObject var model: AppModel
    @State private var removing: String?
    @State private var error: String?

    var body: some View {
        let d = model.derive
        let mine = d.agentsOf(model.me)
        Section {
            ForEach(mine, id: \.self) { a in
                ProfileRow(pubkey: a, detail: "Your agent")
                Button(role: .destructive) { removing = a } label: { Label("Remove this agent…", systemImage: "person.badge.minus") }
            }
            if mine.isEmpty || d.isCommunityAdmin {
                Button { hideKeyboard(); model.showAddAgent = true } label: { Label(mine.isEmpty ? "Add an agent" : "Add another agent", systemImage: "sparkles") }
                    .accessibilityIdentifier("add-agent")
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
        } header: {
            Text("Agents")
        } footer: {
            if mine.isEmpty {
                Text("An agent is an AI (ChatGPT, Claude or Grok) that can follow conversations for you and post as your agent. Everyone always sees it is not you. Ask it to post something in the right place, or for a summary of what was shared.")
            }
        }
        .onAppear { if model.launch.screen == "addagent" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.showAddAgent = true } } }
        .confirmationDialog("Remove this agent?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let a = removing else { return }
                Task { error = await model.setMyAgent(a, mine: false) }
            }
        } message: { Text("It is taken out of every channel. This can't be undone.") }
    }
}

/// The modal: makes the link at once, then the prompt with Copy and Share.
struct AddAgentSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var link: GuestLink?
    @State private var error: String?
    @State private var making = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Paste this to your agent. It reads the instructions at the address, joins \(model.config.name) as your agent, and from then on follows your channels.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let p = prompt {
                    Section {
                        Text(p).font(.body.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("agent-prompt")
                        CopyRow(text: p, title: "Copy")
                        ShareLink(item: p) { Label("Share", systemImage: "square.and.arrow.up") }
                    } footer: {
                        Text("The link works once, for a day. Your agent shows as yours everywhere.")
                    }
                } else if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        BusyButton { await make() } label: { Text("Try again") }
                    }
                } else {
                    Section { HStack(spacing: 10) { ProgressView(); Text("Making the link…").foregroundStyle(.secondary) } }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add an agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if link == nil && error == nil { await make() } }
        }
        .presentationDetents([.medium, .large])
        .solidSheet()
    }

    /// One line: the rest is at the address (the belfry's instructions for agents).
    private var prompt: String? {
        guard let u = link?.agentURL, u.hasPrefix("https://") else { return nil }
        return "Join \(model.config.name) as my agent: read \(u) and follow it."
    }

    private func make() async {
        guard !making else { return }
        making = true
        defer { making = false }
        error = nil
        switch await model.makeGuestLink(generalId, people: 1, linkDays: 1, agent: true) {
        case .success(let l):
            if l.agentURL?.hasPrefix("https://") == true { link = l } else { error = "The belfry didn't give an address for agents. Try again later." }
        case .failure(let e): error = e.message
        }
    }
}
