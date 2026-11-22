import BelfryCore
import SwiftUI

// Navigation v2 screens (canvas, approved 2026-11-22): Add a channel (nav2/channel-new,
// channel-new-typing), the channel's bell (one-shape/anatomy: top right, off by default = push
// level default; on = all), the preview bar (nav2/channel-preview) and its toast (seq-3-interact).

/// The ＋ on CHANNELS: one field "# Name"; typing filters the channels this device knows (works
/// offline), with the typed part highlighted; "Create #name" comes last. Any member may create.
struct AddChannelScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    @State private var name = ""
    @State private var creating = false
    @FocusState private var focused: Bool

    private var query: String { Derive.slugify(name.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        let all = model.derive.townChannels().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let q = query
        let hits = q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) || Derive.slugify($0.name).contains(q) }
        let exact = all.contains { Derive.slugify($0.name) == q }
        List {
            Section {
                HStack(spacing: 6) {
                    Text("#").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("Name", text: $name)
                        .font(.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .accessibilityIdentifier("add-channel-name")
                }
            } footer: {
                Button { hideKeyboard(); model.createFirst = .group; model.showCreate = true } label: {
                    (Text("Everyone in \(model.config.name) can read channels. For a smaller circle, ") + Text("start a group").foregroundColor(.brand) + Text("."))
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Starts a group")
            }
            Section {
                ForEach(hits) { g in
                    Button { openChannel(g.id, nil) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "number").foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                highlighted(g.named ? g.name : BelfryCore.Group.kindTitle(g.id), q).font(.body).lineLimit(1)
                                Text(busy(g.id)).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if model.inMenu(g.id) { Text("In your menu").font(.footnote).foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("add-channel-row-" + g.id)
                }
            } header: {
                if !q.isEmpty { Text("Already there · \(hits.count)") }
            }
            if !q.isEmpty && !exact && !model.derive.amGuest {
                Section {
                    BusyButton(action: create) {
                        Label("Create #\(q)", systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-channel-create")
                } header: { Text("New") } footer: {
                    Text(hits.isEmpty ? "No channel has that name yet." : "Only if none of the above fits.")
                }
            }
        }
        .navigationTitle("Add a channel")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if let t = model.launch.screen, t.hasPrefix("addchannel"), t != "addchannel" { name = "gar" }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true } }
        }
    }

    private func create() async {
        let id = model.createChannel(name: name.trimmingCharacters(in: .whitespaces), about: "")
        hideKeyboard()
        try? await Task.sleep(nanoseconds: 300_000_000)
        openChannel(id, nil)
    }

    /// "8 messages this week", else this month, else "Quiet".
    private func busy(_ id: String) -> String {
        let now = Int.now
        let msgs = model.derive.messages(id)
        let week = msgs.filter { $0.ev.createdAt > now - 7 * 86400 }.count
        if week > 0 { return week == 1 ? "1 message this week" : "\(week) messages this week" }
        let month = msgs.filter { $0.ev.createdAt > now - 30 * 86400 }.count
        if month > 0 { return month == 1 ? "1 message this month" : "\(month) messages this month" }
        return "Quiet lately"
    }

    /// NAME with the typed part in bold.
    private func highlighted(_ name: String, _ q: String) -> Text {
        guard !q.isEmpty, let r = name.lowercased().range(of: q) else { return Text(name) }
        let lo = name.distance(from: name.startIndex, to: r.lowerBound), n = q.count
        let a = String(name.prefix(lo)), b = String(name.dropFirst(lo).prefix(n)), c = String(name.dropFirst(lo + n))
        return Text(a) + Text(b).bold() + Text(c)
    }
}

/// The bell at a channel's top right: off (default) = mentions and replies to me; on = every
/// message (push level all). Applied at once, put back if the belfry says no.
struct BellButton: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var level: String?
    @State private var busy = false
    @State private var error: String?

    private var memoKey: String { model.config.domain + "|" + model.me }
    private var on: Bool { level == "all" }

    var body: some View {
        Button(action: toggle) {
            Image(systemName: on ? "bell.fill" : "bell")
        }
        .disabled(busy || level == nil)
        .accessibilityLabel(on ? "Notify me of everything: on" : "Notify me of everything: off")
        .accessibilityIdentifier("channel-bell")
        .sensoryFeedback(.impact(weight: .light), trigger: level)
        .alert("Not saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task(id: id) {
            if level == nil { level = NotifyMemo.levels[memoKey]?[id] ?? (model.isDemo ? "default" : nil) }
            guard !model.isDemo else { return }
            if case .success(let s) = await model.loadNotificationSettings() {
                if !busy { level = s.level(id) }
                NotifyMemo.levels[memoKey] = s.channels.merging([id: s.level(id)]) { a, _ in a }
            }
        }
    }

    private func toggle() {
        guard !busy, let was = level else { return }
        let next = was == "all" ? "default" : "all"
        busy = true
        level = next
        if model.isDemo { NotifyMemo.levels[memoKey, default: [:]][id] = next; busy = false; return }
        Task {
            switch await model.setNotificationSettings(["channels": [id: next]]) {
            case .success(let s):
                level = s.level(id)
                NotifyMemo.levels[memoKey, default: [:]][id] = s.level(id)
            case .failure(let e):
                level = was
                error = e.message
            }
            busy = false
        }
    }
}

/// Above the composer of a channel that isn't in my menu.
struct PreviewBar: View {
    let label: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "eye").foregroundStyle(.secondary).padding(.top, 2)
            (Text("You're previewing \(label).").fontWeight(.semibold) + Text(" Write or react and it joins your menu, or pin it for yourself in its settings."))
                .font(.footnote).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("preview-bar")
    }
}

/// A channel's "In your menu" (board nav2/channel-pin): Pin for me; Pin for everyone (the
/// belfry's admins); then Notify me of everything (the bell).
struct PinSection: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var busy = false

    var body: some View {
        let mine = model.myPins.contains(id)
        let everyone = model.pinnedForEveryone.contains(id)
        Section("In your menu") {
            if id == generalId {
                Label("Always first in everyone's menu", systemImage: "pin.fill").foregroundStyle(.secondary)
            } else {
            Toggle(isOn: Binding(get: { mine }, set: { _ in toggleMine() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Pin for me", systemImage: "pin")
                    Text("Always in your menu, at the top").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.toggle)
            .disabled(busy)
            .accessibilityIdentifier("pin-mine")
            if model.derive.isCommunityAdmin && model.derive.group(id)?.type == .channel {
                Toggle(isOn: Binding(get: { everyone }, set: { _ in model.togglePinEveryone(id) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Pin for everyone", systemImage: "pin.fill")
                        Text("Admins only: at the top of everyone's menu").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .tint(Theme.toggle)
                .accessibilityIdentifier("pin-everyone")
            }
            }
        }
        Section("Notifications") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notify me of everything")
                    Text("Off: you hear about mentions and replies to you only").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                BellButton(id: id).buttonStyle(.bordered)
            }
        }
    }

    private func toggleMine() {
        guard !busy else { return }
        busy = true
        Task {
            await model.togglePinMine(id)
            model.previewCheck(id)
            busy = false
        }
    }
}
