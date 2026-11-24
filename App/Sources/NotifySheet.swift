import BelfryCore
import SwiftUI
import UIKit

// A channel's notifications in one sheet (the owner's mock-up Notif-C, 2026-11-18; SPEC 19.38).
// The pull-down's Notifications row presents it (medium detent, grabber): the one exception to
// "rows open screens, never sheets", chosen by the owner for this row. Three large choices, applied
// at once on tap with a light haptic, no Save; under them the switch for its announcements by
// e-mail. Storage unchanged: the push level per channel (all / default / mentions / off) and the
// e-mail follow (asap / monthly / stop).

/// The last settings read, per account, so the sheet opens showing them (offline first).
@MainActor enum NotifyMemo {
    static var levels = [String: [String: String]]()
}

struct NotifySheet: View {
    @EnvironmentObject var model: AppModel
    let id: String
    /// The stored level ("default" when the channel has none), nil until known.
    @State private var level: String?
    @State private var follow: String?
    @State private var followLoaded = false
    @State private var busy = false
    @State private var followBusy = false
    @State private var error: String?
    @State private var tapped = 0

    private var memoKey: String { model.config.domain + "|" + model.me }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Notify me about \(channelLabel)")
                    .font(.title3.bold())
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                pushState
                ForEach(NotifyChoice.allCases, id: \.self) { c in option(c) }
                if let error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red).padding(.horizontal, 4) }
                Toggle(isOn: Binding(get: { follow != nil }, set: { setFollow($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also e-mail me its announcements")
                        Text(follow == "monthly" ? "What admins mark as an announcement · once a month" : follow == "weekly" ? "What admins mark as an announcement · once a week" : "What admins mark as an announcement")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .tint(Theme.toggle)
                .disabled(!followLoaded || followBusy)
                .padding(.horizontal, 4)
                .padding(.top, 12)
                .accessibilityIdentifier("notify-email")
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .sensoryFeedback(.impact(weight: .light), trigger: tapped)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .solidSheet()
        .task {
            if level == nil { level = NotifyMemo.levels[memoKey]?[id] }
            if case .success(let s) = await model.loadNotificationSettings() {
                if !busy { level = s.level(id) }
                NotifyMemo.levels[memoKey] = s.channels.merging([id: s.level(id)]) { a, _ in a }
            }
        }
        .task {
            follow = await model.follow(id)
            followLoaded = true
        }
        .onAppear { if level == nil { level = NotifyMemo.levels[memoKey]?[id] } }
    }

    private var channelLabel: String {
        model.derive.label(id)
    }

    /// Push isn't on on this phone: say so above the choices (they are kept for when it is).
    @ViewBuilder private var pushState: some View {
        switch model.pushState {
        case .notAsked:
            HStack {
                Text("Notifications aren't on for this phone yet.").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                BusyButton("Turn on") { await model.turnOnPush() }.buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 4)
        case .denied:
            HStack {
                Text("Notifications are off for Belfry in the iPhone's Settings.").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let u = URL(string: UIApplication.openSettingsURLString) {
                    Link("Settings", destination: u).font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 4)
        default: EmptyView()
        }
    }

    private func icon(_ c: NotifyChoice) -> String {
        switch c {
        case .everything: return "bell.badge"
        case .forMe: return "at"
        case .nothing: return "bell.slash"
        }
    }

    private func option(_ c: NotifyChoice) -> some View {
        let on = level.map { NotifyChoice.of(level: $0) == c } ?? false
        return Button { pick(c) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon(c))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(on ? Color(uiColor: .systemBackground) : Color.primary)
                    .frame(width: 40, height: 40)
                    .background(on ? Color.primary : Color(uiColor: .tertiarySystemFill), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.body.weight(on ? .semibold : .regular)).foregroundStyle(.primary)
                    Text(c.line(stored: level)).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if busy && on { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .background(on ? Color(uiColor: .secondarySystemGroupedBackground) : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? Color.primary : Color(uiColor: .separator), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy || level == nil)
        .accessibilityIdentifier("notify-" + c.rawValue)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Applied at once: shown chosen, saved, put back if the belfry says no.
    private func pick(_ c: NotifyChoice) {
        guard !busy, let was = level, NotifyChoice.of(level: was) != c else { return }
        busy = true
        error = nil
        tapped += 1
        level = c.level
        Task {
            switch await model.setNotificationSettings(["channels": [id: c.level]]) {
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

    private func setFollow(_ on: Bool) {
        guard !followBusy else { return }
        followBusy = true
        error = nil
        let was = follow
        follow = on ? "asap" : nil
        Task {
            switch await model.setFollow(id, on ? "asap" : "stop") {
            case .success(let f): follow = f
            case .failure(let e): follow = was; error = e.message
            }
            followBusy = false
        }
    }
}
