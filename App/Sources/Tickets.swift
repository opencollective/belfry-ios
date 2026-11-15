import AVFoundation
import BelfryCore
import SwiftUI
import VisionKit

// Tickets and check-in (SPEC 19.29, the belfry's contract of 2026-11-15):
// - my ticket: a full-screen QR (crisp, a white quiet zone in dark mode too) with my name, the
//   ticket, the event and its time, "Checked in at …"; the screen's brightness goes up while it
//   shows and back after. The code and its address are kept on the phone (offline first).
// - the check-in screen (hosts, co-hosts, stewards): the camera on top scanning without a tap
//   (the same code is ignored for 3 s), a result card for 2 s with a haptic, the counter, the
//   ticket holders to search and tap; list only when the camera is refused.
// - the card a scanned ticket link opens on the event screen for those who may check in.
// Nothing of a scanned text is shown: only a code shaped like a ticket's is sent.

enum Brightness {
    @MainActor static var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen
    }
}

struct MyTicketView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let e: CalEvent
    @State private var saved: CGFloat?

    var body: some View {
        let d = model.derive
        let v = model.viewer(e)
        let url = v?.ticketURL ?? v?.ticketCode.map { model.ticketURL(e, code: $0) }
        let checked = v?.checkedIn ?? d.checkIns(e.groupId)[model.me]
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let url, let img = QR.image(url) {
                        Image(uiImage: img)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280)
                            .padding(28)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .accessibilityLabel("Your ticket's QR code")
                            .accessibilityIdentifier("ticket-qr")
                    }
                    VStack(spacing: 4) {
                        Text(myName).font(.title2.bold())
                        Text(ticketTitle(d, v)).font(.headline).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    VStack(spacing: 4) {
                        Text(e.title).font(.headline)
                        Text(d.lineDay(e.start, now: .now) + " · " + d.lineWhen(e)).font(.subheadline).foregroundStyle(.secondary)
                        if let l = e.location, !l.isEmpty { Text(l).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    .multilineTextAlignment(.center)
                    if let at = checked {
                        Label("Checked in at \(Format.time(at))", systemImage: "checkmark.circle.fill")
                            .font(.headline).foregroundStyle(.green)
                    } else {
                        Text("Show this at the door.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Your ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear(perform: brighten)
        .onDisappear(perform: restore)
        .onChange(of: phase) { _, p in if p == .active { brighten() } else { restore() } }
    }

    private var myName: String {
        let n = model.realName(model.me)
        return n.isEmpty ? model.name(model.me) : n
    }

    private func ticketTitle(_ d: Derive, _ v: EventViewer?) -> String {
        let held = v?.ticket ?? d.eventPeople(e).holders[model.me]
        return d.tickets(e).first { $0.d == held }?.title ?? "Ticket"
    }

    private func brighten() {
        guard let s = Brightness.screen else { return }
        if saved == nil { saved = s.brightness }
        s.brightness = 1
    }

    private func restore() {
        guard let s = Brightness.screen, let b = saved else { return }
        s.brightness = b
        saved = nil
    }
}

/// What a scan or a tap gave, shown for 2 s.
struct ScanCard: Equatable, Identifiable {
    enum Kind { case ok, already, bad }
    let id = UUID()
    let kind: Kind
    let title: String
    var detail: String? = nil

    var color: Color {
        switch kind {
        case .ok: return Color(red: 0.12, green: 0.48, blue: 0.2)
        case .already: return Color(red: 0.68, green: 0.36, blue: 0.0)
        case .bad: return Color(red: 0.7, green: 0.15, blue: 0.12)
        }
    }

    var symbol: String {
        switch kind {
        case .ok: return "checkmark.circle.fill"
        case .already: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        }
    }

    static func == (a: ScanCard, b: ScanCard) -> Bool { a.id == b.id }

    static func of(_ r: CheckInResult, undo: Bool = false) -> ScanCard {
        let p = r.person
        let who = p.name.isEmpty ? "Someone" : p.name
        if undo { return ScanCard(kind: .already, title: "\(who) · not checked in any more") }
        if r.already, let at = p.checkedIn { return ScanCard(kind: .already, title: "Already checked in at \(Format.time(at))", detail: who + (p.ticketTitle.isEmpty ? "" : " · " + p.ticketTitle)) }
        let ticket = p.ticketTitle.isEmpty ? "" : " · " + p.ticketTitle
        return ScanCard(kind: .ok, title: "\(who)\(ticket) · checked in")
    }
}

struct ScanCardView: View {
    let card: ScanCard
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: card.symbol).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let d = card.detail { Text(d).font(.subheadline).opacity(0.9) }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(card.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct CheckInScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let e: CalEvent
    @State private var query = ""
    @State private var card: ScanCard?
    @State private var lastText = ""
    @State private var lastAt = Date.distantPast
    @State private var camera: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var busy = Set<String>()
    @State private var undo: Attendee?
    @State private var loadError: String?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let _ = model.version
        let list = model.attendees(e)
        let shown = filtered(list.people)
        NavigationStack {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    if showsCamera {
                        cameraArea.frame(height: geo.size.height * 0.45).clipped()
                    }
                    counter(list)
                    Divider()
                    List {
                        if !showsCamera { cameraNote }
                        if let loadError {
                            Label(loadError, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        }
                        if list.people.isEmpty {
                            Text("Nobody holds a ticket yet.").foregroundStyle(.secondary)
                        }
                        ForEach(shown) { p in row(p) }
                    }
                    .listStyle(.plain)
                    .refreshable { loadError = await model.loadAttendees(e) }
                    // without the camera the result card shows over the list
                    .overlay(alignment: .top) {
                        if !showsCamera, let card { ScanCardView(card: card).padding(12).transition(.move(edge: .top).combined(with: .opacity)) }
                    }
                }
            }
            .navigationTitle("Check people in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .searchable(text: $query, prompt: "Search ticket holders")
            .confirmationDialog("Undo check-in?", isPresented: Binding(get: { undo != nil }, set: { if !$0 { undo = nil } }), titleVisibility: .visible, presenting: undo) { p in
                Button("Undo check-in", role: .destructive) { run(p.pubkey, undo: true) }
            } message: { p in Text("\(displayName(p)) shows as not checked in.") }
        }
        .task {
            if camera == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                camera = AVCaptureDevice.authorizationStatus(for: .video)
            }
            loadError = await model.loadAttendees(e)
        }
        .onAppear {
            if model.launch.screen == "checkin" {
                let first = model.attendees(e).people.first { $0.checkedIn == nil } ?? model.attendees(e).people.first
                if let p = first { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { run(p.pubkey, undo: false, keepCard: true) } }
            }
        }
    }

    // ---- the camera ----------------------------------------------------------------------------

    /// The camera, when the phone has one and Belfry may use it (the demo shows the place).
    private var showsCamera: Bool {
        if model.isDemo { return true }
        return camera == .authorized && DataScannerViewController.isSupported
    }

    private var cameraArea: some View {
        ZStack(alignment: .bottom) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable && camera == .authorized {
                QRScannerView { text in Task { @MainActor in scanned(text) } }
            } else {
                // the simulator / the demo: where the camera shows
                Color.black
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "qrcode.viewfinder").font(.system(size: 56, weight: .light))
                            Text("Point the camera at a ticket").font(.subheadline)
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    }
            }
            if let card {
                ScanCardView(card: card)
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(card.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera: scans tickets without a tap")
    }

    @ViewBuilder private var cameraNote: some View {
        if camera == .denied || camera == .restricted {
            Button {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            } label: {
                Label("Turn on the camera in Settings to scan tickets", systemImage: "camera")
            }
        } else if !DataScannerViewController.isSupported {
            Label("This phone can’t scan here: check people in from the list.", systemImage: "camera")
                .foregroundStyle(.secondary)
        }
    }

    private func counter(_ list: AttendeeList) -> some View {
        let total = list.people.count
        let done = list.people.filter { $0.checkedIn != nil }.count
        return HStack(spacing: 12) {
            Text("\(done) of \(total) checked in").font(.headline).monospacedDigit()
            Spacer()
            ProgressView(value: Double(done), total: Double(max(1, total))).frame(width: 90)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func row(_ p: Attendee) -> some View {
        Button {
            if p.checkedIn != nil { undo = p } else { run(p.pubkey, undo: false) }
        } label: {
            HStack(spacing: 12) {
                Avatar(pubkey: p.pubkey, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName(p)).font(.body).foregroundStyle(.primary)
                    if !p.ticketTitle.isEmpty { Text(p.ticketTitle).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if busy.contains(p.pubkey) {
                    ProgressView()
                } else if let at = p.checkedIn {
                    HStack(spacing: 6) {
                        Text(Format.time(at)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                    }
                } else {
                    Image(systemName: "circle").font(.title3).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy.contains(p.pubkey))
        .accessibilityLabel(displayName(p) + (p.checkedIn != nil ? ", checked in" : ", not checked in"))
        .accessibilityHint(p.checkedIn != nil ? "Undo the check-in" : "Check in")
    }

    private func displayName(_ p: Attendee) -> String { p.name.isEmpty ? model.name(p.pubkey) : p.name }

    private func filtered(_ people: [Attendee]) -> [Attendee] {
        let q = query.jsTrim().folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard !q.isEmpty else { return people }
        return people.filter { p in
            let n = (displayName(p) + " " + p.ticketTitle).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return n.contains(q)
        }
    }

    // ---- checking in ---------------------------------------------------------------------------

    private func scanned(_ text: String) {
        let now = Date()
        if text == lastText && now.timeIntervalSince(lastAt) < 3 { return }
        lastText = text
        lastAt = now
        guard let code = TicketScan.code(text) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            show(ScanCard(kind: .bad, title: "Not a ticket for this event"))
            return
        }
        Task {
            let r = await model.checkIn(e, code: code)
            finish(r, undo: false)
        }
    }

    private func run(_ pk: String, undo: Bool, keepCard: Bool = false) {
        guard !busy.contains(pk) else { return }
        busy.insert(pk)
        Task {
            let r = await model.checkIn(e, pubkey: pk, undo: undo)
            busy.remove(pk)
            finish(r, undo: undo, keep: keepCard)
        }
    }

    private func finish(_ r: Result<CheckInResult, ApiError>, undo: Bool, keep: Bool = false) {
        switch r {
        case .success(let x):
            UINotificationFeedbackGenerator().notificationOccurred(x.already || undo ? .warning : .success)
            show(ScanCard.of(x, undo: undo), keep: keep)
        case .failure(let x):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            show(ScanCard(kind: .bad, title: x.code == "no_ticket" ? "Not a ticket for this event" : x.message), keep: keep)
        }
    }

    private func show(_ c: ScanCard, keep: Bool = false) {
        hideTask?.cancel()
        withAnimation(.snappy(duration: 0.2)) { card = c }
        guard !keep else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { if card?.id == c.id { card = nil } } }
        }
    }
}

/// A ticket link opened by someone who may check people in: a card on the event screen. The
/// belfry resolves the code only when checking in, so the name shows after "Check in".
struct CheckInCard: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let code: String
    let close: () -> Void
    @State private var result: CheckInResult?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("A ticket for this event", systemImage: "ticket").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close")
            }
            if let r = result {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.person.name.isEmpty ? model.name(r.person.pubkey) : r.person.name).font(.title3.bold())
                    if !r.person.ticketTitle.isEmpty { Text(r.person.ticketTitle).font(.subheadline).foregroundStyle(.secondary) }
                }
                if let at = r.person.checkedIn {
                    HStack {
                        Label(r.already ? "Already checked in at \(Format.time(at))" : "Checked in at \(Format.time(at))", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(r.already ? Color.orange : Color.green)
                        Spacer()
                        BusyButton("Undo") { await go(undo: true) }.buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    BusyButton { await go(undo: false) } label: { Text("Check in").frame(maxWidth: .infinity) }
                        .buttonStyle(.brand).controlSize(.large)
                }
            } else {
                BusyButton { await go(undo: false) } label: { Text("Check in").frame(maxWidth: .infinity) }
                    .buttonStyle(.brand).controlSize(.large)
                    .accessibilityIdentifier("checkin-card-button")
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.red) }
        }
        .padding(16)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func go(undo: Bool) async {
        error = nil
        let r: Result<CheckInResult, ApiError>
        if undo, let pk = result?.person.pubkey {
            r = await model.checkIn(e, pubkey: pk, undo: true)
        } else {
            r = await model.checkIn(e, code: code)
        }
        switch r {
        case .success(let x):
            UINotificationFeedbackGenerator().notificationOccurred(x.already || undo ? .warning : .success)
            result = x
        case .failure(let x):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            error = x.message
        }
    }
}
