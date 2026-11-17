import BelfryCore
import SwiftUI

// Create (the bar's ＋, board iOS-Home 3): one sheet, an icon list. Where = the channel on screen
// (Town), else the Townsquare; tap it to pick another channel. Each row opens its form in the same
// sheet (the forms are the composer's own); Message opens that channel with the keyboard up.
// Inside a channel, the composer's own ＋ keeps photo, audio and announcement.

enum CreateWhat: String, CaseIterable, Identifiable, Hashable {
    case message, event, meeting, todo, group, proposal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .message: return "Message"
        case .event: return "Event"
        case .meeting: return "Meeting"
        case .todo: return "To-do"
        case .group: return "Group"
        case .proposal: return "Proposal"
        }
    }

    var icon: String {
        switch self {
        case .message: return "message"
        case .event: return "calendar"
        case .meeting: return "video"
        case .todo: return "checkmark.circle"
        case .group: return "hexagon"
        case .proposal: return "doc.text"
        }
    }

    var tint: Color {
        switch self {
        case .message: return .blue
        case .event: return .orange
        case .meeting: return .pink
        case .todo: return .green
        case .group: return .purple
        case .proposal: return .gray
        }
    }

    func detail(_ place: String) -> String {
        switch self {
        case .message: return "Post in " + place
        case .event: return "A date, a place, who's coming"
        case .meeting: return "In a room, online, or both"
        case .todo: return "Something someone can take on"
        case .group: return "A smaller circle inside the channel"
        case .proposal: return "Something to decide together"
        }
    }
}

struct CreateMenuSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let start: String
    let first: CreateWhat
    let message: (String) -> Void
    @State private var place: String = generalId
    @State private var chosen: CreateWhat?
    @State private var started = false

    var body: some View {
        SwiftUI.Group {
            switch chosen {
            case .event: EventFormSheet(editing: nil, channel: place)
            case .meeting: MeetingFormSheet(channel: place)
            case .todo: CreateSheet(kind: .todo, parent: place)
            case .group: CreateSheet(kind: .pod, parent: place)
            case .proposal: CreateSheet(kind: .proposal, parent: place)
            case .message, nil: menu
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            place = model.group(start).map { $0.type == .channel && !model.locked($0.id) ? $0.id : generalId } ?? generalId
        }
    }

    private var menu: some View {
        let order = [first] + CreateWhat.allCases.filter { $0 != first }
        let name = placeName(place)
        return NavigationStack {
            List {
                Section {
                    Menu {
                        ForEach(channels()) { g in
                            Button { place = g.id } label: {
                                if g.id == place { Label("#" + g.name, systemImage: "checkmark") } else { Text("#" + g.name) }
                            }
                        }
                    } label: {
                        HStack {
                            Text("Where").foregroundStyle(.secondary)
                            Spacer()
                            Text("# " + (model.group(place)?.name ?? place)).foregroundStyle(Color.brand)
                            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Color.brand)
                        }
                    }
                    .accessibilityIdentifier("create-where")
                }
                Section {
                    ForEach(order) { w in
                        Button { pick(w) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: w.icon).font(.body.weight(.semibold)).foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(w.tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(w.title).foregroundStyle(.primary)
                                    Text(w.detail(name)).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("create-" + w.rawValue)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Create")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func pick(_ w: CreateWhat) {
        if w == .message {
            dismiss()
            message(place)
        } else {
            withAnimation(.snappy) { chosen = w }
        }
    }

    /// "the Townsquare" for the Townsquare, else "#name".
    private func placeName(_ id: String) -> String {
        let n = model.group(id)?.name ?? id
        return id == generalId && n == PlaceNames.defaults[generalId] ? "the Townsquare" : "#" + n
    }

    private func channels() -> [Channel] {
        let d = model.derive
        let s = d.channelSections()
        return (s.pub + s.members).filter { d.inChannel($0, model.me) && !model.locked($0.id) }
    }
}
