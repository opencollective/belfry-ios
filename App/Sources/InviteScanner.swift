import AVFoundation
import BelfryCore
import SwiftUI
import VisionKit

// "Scan an invitation" (Android SPEC 19.24): the camera reads QR codes; only one whose text is a
// guest link (https://chat.<domain>/join/<token>, /#/join/ too; at most 512 characters) counts
// and goes where an opened link goes. Anything else: "This isn’t a Belfry invitation." for three
// seconds, scanning goes on. No text of a code is ever shown. VisionKit's DataScanner.

struct InviteScanner: View {
    @Environment(\.dismiss) private var dismiss
    let found: (URL) -> Void
    @State private var notInvite = false
    @State private var hideAt = Date.distantPast

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if DataScannerViewController.isSupported {
                    if DataScannerViewController.isAvailable {
                        QRScannerView { text in check(text) }.ignoresSafeArea()
                    } else {
                        ContentUnavailableView("The camera is off for Belfry", systemImage: "camera",
                                               description: Text("Turn it on in Settings › Belfry › Camera."))
                    }
                } else {
                    ContentUnavailableView("This phone can’t scan here", systemImage: "qrcode.viewfinder",
                                           description: Text("Open the invitation's link instead: the camera app reads it too."))
                }
                if notInvite {
                    Text("This isn’t a Belfry invitation or login code.")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glass(in: Capsule())
                        .padding(.bottom, 40)
                        .transition(.opacity)
                }
            }
            .navigationTitle("Scan an invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { _ = await AVCaptureDevice.requestAccess(for: .video) }
        }
    }

    private func check(_ text: String) {
        // an invitation, or a "Link your phone" code of the web chat (SPEC 19.56)
        if (text as NSString).length <= 512, let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           InviteLink.parse(u) != nil || LoginLink.parse(u) != nil {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            found(u)
            return
        }
        guard Date() > hideAt else { return }
        hideAt = Date().addingTimeInterval(3)
        withAnimation { notInvite = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { notInvite = false } }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) { vc.stopScanning() }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let b) = item, let text = b.payloadStringValue { onCode(text) }
            }
        }
    }
}
