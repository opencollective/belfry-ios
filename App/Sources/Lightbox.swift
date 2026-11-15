import SwiftUI

// Photos as big as possible (web dabedd9 / 9768c93): swipe through a message's photos, pinch or
// double-tap to zoom, drag down or ✕ to close.

struct Lightbox: Identifiable, Equatable {
    let urls: [String]
    let index: Int
    var id: String { urls.joined() + "#\(index)" }
}

struct LightboxView: View {
    @Environment(\.dismiss) private var dismiss
    let box: Lightbox
    @State private var page = 0
    @State private var drag: CGFloat = 0
    @State private var zoomed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(1 - min(0.6, abs(drag) / 600)).ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(box.urls.enumerated()), id: \.offset) { i, u in
                    ZoomablePhoto(url: URL(string: u), zoomed: $zoomed).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: box.urls.count > 1 ? .automatic : .never))
            .offset(y: drag)
            .simultaneousGesture(zoomed ? nil : DragGesture(minimumDistance: 20)
                .onChanged { v in if abs(v.translation.height) > abs(v.translation.width) { drag = v.translation.height } }
                .onEnded { v in
                    if abs(v.translation.height) > 140 || abs(v.predictedEndTranslation.height) > 400 { dismiss() } else { withAnimation(.snappy) { drag = 0 } }
                })
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).glass(in: Circle(), interactive: true)
            }
            .padding(.trailing, 16).padding(.top, 8)
            .accessibilityLabel("Close")
        }
        .statusBarHidden()
        .onAppear { page = box.index }
    }
}

struct ZoomablePhoto: View {
    let url: URL?
    @Binding var zoomed: Bool
    @State private var scale: CGFloat = 1
    @State private var last: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        CachedImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFit()
            case .failure: Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
            default: ProgressView().tint(.white)
            }
        }
        .scaleEffect(scale)
        .offset(offset)
        .gesture(MagnifyGesture()
            .onChanged { v in scale = max(1, min(5, last * v.magnification)) }
            .onEnded { _ in last = scale; zoomed = scale > 1.01; if !zoomed { reset() } })
        .simultaneousGesture(zoomed ? DragGesture()
            .onChanged { v in offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height) }
            .onEnded { _ in lastOffset = offset } : nil)
        .onTapGesture(count: 2) {
            withAnimation(.snappy) {
                if zoomed { reset() } else { scale = 2.5; last = 2.5; zoomed = true }
            }
        }
        .accessibilityLabel("Photo")
        .accessibilityAddTraits(.isImage)
    }

    private func reset() {
        scale = 1; last = 1; offset = .zero; lastOffset = .zero; zoomed = false
    }
}
