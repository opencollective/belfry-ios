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
    @State private var state = MailForwardLoad.loading

    var body: some View {
        NavigationLink { MailForwardScreen(channel: channel, forward: $forward, state: $state) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Forward e-mails")
                Text(state.line(forward)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityIdentifier("settings-forward")
        // the server's state, asked each time the row shows; a call cut short (the row scrolled
        // away, the screen pushed) is asked again, and a failure never reads as "Off"
        .task { if state != .loaded { await MailForwardLoad.load(model, channel, $forward, $state) } }
    }
}

/// Where the forward's state stands: asked, known (the server's answer), or not known (a failure).
enum MailForwardLoad: Equatable {
    case loading, loaded, failed

    func line(_ f: MailForward?) -> String {
        switch self {
        case .loading: return " "
        case .loaded: return MailForward.line(f)
        case .failed: return "Couldn't check. Open to try again."
        }
    }

    @MainActor static func load(_ model: AppModel, _ channel: String, _ forward: Binding<MailForward?>, _ state: Binding<MailForwardLoad>) async {
        guard model.engine?.localOnly == false else { return }
        do {
            let f = try await model.api.mailForward(channel: channel)
            forward.wrappedValue = f
            state.wrappedValue = .loaded
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            if state.wrappedValue != .loaded { state.wrappedValue = .failed }
        }
    }
}

struct MailForwardScreen: View {
    @EnvironmentObject var model: AppModel
    let channel: String
    @Binding var forward: MailForward?
    @Binding var state: MailForwardLoad
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
            if state == .failed {
                Section {
                    Label("Couldn't check where e-mails are forwarded.", systemImage: "exclamationmark.triangle")
                    BusyButton("Try again") { await MailForwardLoad.load(model, channel, $forward, $state) }
                }
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
        // the server's state, asked again on opening: the field and the line follow its answer
        .task { await MailForwardLoad.load(model, channel, $forward, $state) }
        .onChange(of: forward) { _, f in if address.isEmpty, let f { address = f.address } }
    }

    /// One call to the belfry; its refusal shows in fixed words.
    private func run(_ work: () async throws -> Void) async {
        error = nil
        note = nil
        hideKeyboard()
        if model.engine?.localOnly != false { error = BelfryAPI.mailForwardErrors["unsupported"]; return }
        do { try await work(); state = .loaded }
        catch let e as ApiError { self.error = e.message }
        catch { self.error = BelfryAPI.network }
    }
}

// ---- the channel's address (Settings → E-mail; docs/mail.md "A channel's address") ---------------

/// "hello@riverside.example": the belfry's word for the channel's address, shown to whoever
/// edits the channel; the belfry's stewards open it to change the part before the @.
struct MailAliasRow: View {
    @EnvironmentObject var model: AppModel
    let channel: String
    /// Worked out on the device: shown until the belfry answers, and on a belfry without the call.
    let fallback: String
    @State private var alias: MailAlias?

    var body: some View {
        let address = alias?.address ?? fallback
        SwiftUI.Group {
            if alias?.maySet == true {
                NavigationLink { MailAliasScreen(channel: channel, alias: $alias) } label: { line(address) }
            } else {
                line(address)
            }
        }
        .accessibilityIdentifier("settings-address")
        .task {
            guard alias == nil, !model.isDemo else { return }
            alias = try? await model.api.mailAlias(channel: channel)
        }
    }

    private func line(_ address: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Address")
            Text(address).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

/// The part before the @, with the belfry's check as it is typed (available / taken / reserved /
/// invalid) and Save; "Use the automatic address" goes back.
struct MailAliasScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: String
    @Binding var alias: MailAlias?
    @State private var name = ""
    @State private var check = ""
    @State private var checked = ""
    @State private var error: String?

    private var domain: String { alias.flatMap { $0.address.split(separator: "@").last.map(String.init) } ?? model.config.domain }
    private var typed: String { name.trimmingCharacters(in: .whitespaces).lowercased() }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 2) {
                    TextField("name", text: $name)
                        .font(.body)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                        .accessibilityIdentifier("alias-name")
                    Text("@" + domain).foregroundStyle(.secondary).lineLimit(1)
                }
            } footer: {
                let line = typed == alias?.alias ? "This is the channel's address now." : MailAlias.checkLine(checked == typed ? check : "", address: typed + "@" + domain)
                Text(line.isEmpty ? " " : line).foregroundStyle(check == "available" || typed == alias?.alias ? Color.secondary : Color.red)
            }
            if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            Section {
                BusyButton("Save") { await save(typed) }
                    .disabled(typed.isEmpty || typed == alias?.alias || checked != typed || check != "available")
                    .accessibilityIdentifier("alias-save")
                if alias?.custom == true {
                    BusyButton("Use the automatic address", role: .destructive) { await save(nil) }
                        .accessibilityIdentifier("alias-clear")
                }
            }
        }
        .navigationTitle("Address")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if name.isEmpty { name = alias?.alias ?? "" } }
        // the live check, a moment after the typing stops
        .task(id: typed) {
            guard !typed.isEmpty, typed != alias?.alias else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let r = try? await model.api.checkMailAlias(channel: channel, name: typed), !Task.isCancelled else { return }
            check = r.state
            checked = typed
        }
    }

    private func save(_ value: String?) async {
        hideKeyboard()
        do {
            alias = try await model.api.setMailAlias(channel: channel, alias: value)
            error = nil
            dismiss()
        } catch let e as ApiError { error = e.message } catch { error = BelfryAPI.network }
    }
}
