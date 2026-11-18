import BelfryCore
import SwiftUI
import UIKit

// The composer's field (Xavier 2026-11-18: "make sure the @mentions are properly highlighted as
// part of the input message; when it has spaces it's very hard to see what's the mention"). A
// SwiftUI TextField can't style part of its text before iOS 26, so this is the system's own text
// view: each picked "@Name" / "#channel" is drawn semibold on a soft tint as it is typed (iMessage
// marks a mention the same way); the rest is the body font. Editing a name so it no longer matches
// a pick removes its mark: what is marked is exactly what will be sent as a mention.
//
// Layout (CLAUDE.md "layout that can freeze"): it reports one size for the width it is given
// (`sizeThatFits`), grows to MAXLINES and scrolls inside after that; no geometry is written to
// view state.
struct MessageField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    /// The labels to mark, as they stand in the text ("@OSV website agent", "#Garden").
    var marks: [String]
    var tint: UIColor
    /// What VoiceOver calls the field (the placeholder is drawn by the composer).
    var label = "Message"
    var maxLines = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.backgroundColor = .clear
        v.font = UIFont.preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.textColor = .label
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.isScrollEnabled = false
        v.showsVerticalScrollIndicator = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.accessibilityIdentifier = "composer-field"
        v.text = text
        context.coordinator.mark(v)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if v.accessibilityLabel != label { v.accessibilityLabel = label }
        if v.text != text {
            // the model changed the text (a pick, Send, a draft): the caret goes to its end
            v.text = text
            c.mark(v)
            v.invalidateIntrinsicContentSize()
        } else if c.marked != marks || c.tint != tint {
            c.mark(v)
        }
        if focused != v.isFirstResponder, !c.changingFocus {
            c.changingFocus = true
            DispatchQueue.main.async {
                if self.focused { v.becomeFirstResponder() } else { v.resignFirstResponder() }
                c.changingFocus = false
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: UITextView, context: Context) -> CGSize? {
        guard let w = proposal.width, w > 0, w.isFinite else { return nil }
        let line = (v.font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight
        let fit = v.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        let most = ceil(line * CGFloat(maxLines))
        let scroll = fit > most + 0.5
        if v.isScrollEnabled != scroll { v.isScrollEnabled = scroll }
        return CGSize(width: w, height: max(ceil(line), min(ceil(fit), most)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MessageField
        var marked = [String]()
        var tint: UIColor?
        var changingFocus = false
        init(_ p: MessageField) { parent = p }

        /// Body text everywhere, then the picked labels semibold on a soft tint. Attributes only:
        /// the characters and the selection are untouched. Never while a keyboard is composing
        /// (marked text of an input method).
        func mark(_ v: UITextView) {
            guard v.markedTextRange == nil else { return }
            let body = UIFont.preferredFont(forTextStyle: .body)
            let strong = UIFont(descriptor: body.fontDescriptor.withSymbolicTraits(.traitBold) ?? body.fontDescriptor, size: 0)
            let base: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: UIColor.label]
            let s = v.textStorage
            let all = NSRange(location: 0, length: s.length)
            s.beginEditing()
            s.setAttributes(base, range: all)
            for r in Mentions.ranges(in: s.string, labels: parent.marks) where NSMaxRange(r) <= s.length {
                s.addAttributes([.font: strong, .foregroundColor: parent.tint, .backgroundColor: parent.tint.withAlphaComponent(0.14)], range: r)
            }
            s.endEditing()
            v.typingAttributes = base // what is typed after a mention is plain again
            marked = parent.marks
            tint = parent.tint
        }

        func textViewDidChange(_ v: UITextView) {
            parent.text = v.text
            mark(v)
            v.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ v: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ v: UITextView) { if parent.focused { parent.focused = false } }
    }
}
