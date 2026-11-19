import BelfryCore
import SwiftUI

// "Forward e-mails" (board channels/settings; collective-belfry docs/mail.md "Forwarding"): a
// channel's admins send a copy of every e-mail the channel takes to an outside address. The
// belfry's own setting, asked and saved at once through its API; never an event. Nothing is
// forwarded until the outside address confirms.

/// The row in a channel's settings: "Forward e-mails", "Off" or where to.
struct MailForwardRow: View {
    @EnvironmentObject var model: AppModel
    let channel: String
    @State private var forward: MailForward?
    @State private var loaded = false

    var body: some View {
        NavigationLink { MailForwardScreen(channel: channel, forward: $forward) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Forward e-mails")
                Text(loaded ? MailForward.line(forward) : " ").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityIdentifier("settings-forward")
        .task {
            guard !loaded else { return }
            if model.engine?.localOnly == false { forward = try? await model.api.mailForward(channel: channel) }
            loaded = true
        }
    }
}

struct MailForwardScreen: View {
    @EnvironmentObject var model: AppModel
    let channel: String
    @Binding var forward: MailForward?
    @State private var address = ""
    @State private var note: String?
    @State private var error: String?

    private var typed: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("name@example.org", text: $address)
                    .font(.body)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Forward all e-mails to")
                    .accessibilityIdentifier("forward-address")
                    .onChange(of: address) { _, v in error = nil; note = nil; if v.count > 200 { address = String(v.prefix(200)) } }
            } header: { Text("Forward all e-mails to") } footer: {
                Text("E-mails still show up in the channel. A copy goes to this address, once it has confirmed.")
            }
            if let f = forward {
                Section {
                    Label(f.on ? "Forwarding to \(f.address)" : "Waiting for \(f.address) to confirm", systemImage: f.on ? "checkmark.circle" : "clock")
                        .accessibilityIdentifier("forward-state")
                    if !f.on {
                        BusyButton("Send the confirmation again") { await run { forward = try await model.api.resendMailForward(channel: channel); note = "Sent again." } }
                    }
                } footer: {
                    if f.sameDomainSkipped, let dom = f.address.split(separator: "@").last {
                        Text("E-mails sent from @\(String(dom)) addresses are not forwarded.")
                    }
                }
            }
            Section {
                BusyButton {
                    await run {
                        let n = try await model.api.setMailForward(channel: channel, address: typed)
                        forward = n
                        if let n, !n.on { note = "We sent a confirmation e-mail. Forwarding starts once it is confirmed." }
                    }
                } label: { Text("Save").frame(maxWidth: .infinity) }
                    .buttonStyle(.brand)
                    .disabled(typed.isEmpty || typed.lowercased() == forward?.address.lowercased())
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .accessibilityIdentifier("forward-save")
                if forward != nil {
                    BusyButton("Stop forwarding", role: .destructive) {
                        await run { forward = try await model.api.setMailForward(channel: channel, address: nil); address = "" }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let note { Text(note) }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Forward e-mails")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if address.isEmpty { address = forward?.address ?? "" } }
    }

    /// One call to the belfry; its refusal shows in fixed words.
    private func run(_ work: () async throws -> Void) async {
        error = nil
        note = nil
        hideKeyboard()
        if model.engine?.localOnly != false { error = BelfryAPI.mailForwardErrors["unsupported"]; return }
        do { try await work() }
        catch let e as ApiError { error = e.message }
        catch { error = BelfryAPI.network }
    }
}
