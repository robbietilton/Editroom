import AppKit
import SwiftUI

/// The Magic prompt's text: plain text where each `@` mention (`@playhead`, `@selected`, `@in-out`,
/// `@` + a library file) shows in the accent colour. Typing `@` reports what's typed after it, so the
/// box can offer what to point at; the arrows, Return, Tab and esc work that list while it's open.
struct MentionField: NSViewRepresentable {
    enum Key { case up, down, accept, escape, submit }

    @Binding var text: String
    /// Library files, for colouring their names.
    let media: [MediaAsset]
    /// Clips on the timeline, for colouring `@clip:` names.
    let clips: [MagicMention.ClipLabel]
    /// Markers on the timeline, for colouring their names.
    var markers: [MagicMention.MarkerLabel] = []
    /// Folders in Media, for colouring `@folder:` names.
    var folders: [MagicMention.FolderLabel] = []
    /// What's typed after an `@` at the caret, or nil when the caret isn't in one.
    let onQuery: (String?) -> Void
    /// A key while typing; true if it was used.
    let onKey: (Key) -> Bool
    let controller: MentionController

    static let font = NSFont.systemFont(ofSize: 12.5)
    static let mentionFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.font = Self.font
        tv.textColor = Theme.NS.text
        tv.insertionPointColor = Theme.NS.text
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 5
        tv.typingAttributes = context.coordinator.plainAttributes
        tv.string = text
        context.coordinator.recolor(tv)
        controller.textView = tv
        // The cursor in the box as soon as it's shown.
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv); tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0)) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        controller.textView = tv
        // Mid-composition (Pinyin, Japanese, a dead key): the input method owns the text until a choice is made.
        if tv.hasMarkedText() { return }
        if tv.string != text {
            // Set from outside (an idea, or cleared after sending): the cursor at the end, ready to type.
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            tv.window?.makeFirstResponder(tv)
            context.coordinator.recolor(tv)
            context.coordinator.report(tv)
        } else {
            context.coordinator.recolor(tv)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MentionField
        /// An `@` they closed the list on with esc: no list for it until they type somewhere else.
        /// An `@` whose list is closed (esc, or something picked from it): it stays closed while the cursor is in it.
        var dismissed: Int?

        init(_ parent: MentionField) { self.parent = parent }

        var plainAttributes: [NSAttributedString.Key: Any] { [.font: MentionField.font, .foregroundColor: Theme.NS.text] }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            // Still composing (Pinyin syllables, say): left alone, so the candidate list stays; it's all
            // passed on and coloured once a candidate is chosen. Plain typing never composes, so it updates at once.
            if tv.hasMarkedText() { return }
            parent.text = tv.string
            // An `@` just typed is a new one, even where a closed one was: the list opens for it.
            let caret = tv.selectedRange().location
            if caret > 0, caret <= (tv.string as NSString).length, (tv.string as NSString).character(at: caret - 1) == 0x40 { dismissed = nil }
            recolor(tv)
            report(tv)
        }

        func textViewDidChangeSelection(_ note: Notification) {
            guard let tv = note.object as? NSTextView, !tv.hasMarkedText() else { return }
            report(tv)
        }

        func recolor(_ tv: NSTextView) {
            guard let storage = tv.textStorage, !tv.hasMarkedText() else { return }
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(plainAttributes, range: all)
            for (r, _) in MagicMention.find(in: storage.string, media: parent.media, clips: parent.clips, markers: parent.markers, folders: parent.folders) where NSMaxRange(r) <= storage.length {
                storage.addAttributes([.font: MentionField.mentionFont, .foregroundColor: Theme.NS.text], range: r)
            }
            // Times Magic understands ("0:05", "between 5s and 8s"), bold the same way.
            for r in MagicTimes.recognised(in: storage.string) where NSMaxRange(r) <= storage.length {
                storage.addAttributes([.font: MentionField.mentionFont], range: r)
            }
            storage.endEditing()
            tv.typingAttributes = plainAttributes
        }

        /// The `@` the caret is in, and what's typed after it.
        func report(_ tv: NSTextView) {
            let found = Self.query(in: tv)
            // Closed with esc: only until the cursor leaves that `@`.
            if found == nil || found?.at != dismissed { dismissed = nil }
            let q = found.flatMap { $0.at == dismissed ? nil : $0.query }
            parent.controller.at = q == nil ? nil : found?.at
            DispatchQueue.main.async { self.parent.onQuery(q) }
        }

        static func query(in tv: NSTextView) -> (at: Int, query: String)? {
            let sel = tv.selectedRange()
            guard sel.length == 0 else { return nil }
            let s = tv.string as NSString
            var i = sel.location - 1
            // Back to the `@`, on this line and not far.
            while i >= 0, sel.location - i <= 60 {
                let c = s.character(at: i)
                if c == 0x0A || c == 0x0D { return nil }
                if c == 0x40 {
                    if i > 0, let u = Unicode.Scalar(s.character(at: i - 1)), CharacterSet.alphanumerics.contains(u) { return nil }
                    return (i, s.substring(with: NSRange(location: i + 1, length: sel.location - i - 1)))
                }
                i -= 1
            }
            return nil
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)): return parent.onKey(.accept)
            case #selector(NSResponder.insertNewline(_:)):
                if parent.onKey(.accept) { return true }
                // ⇧Return adds a line; Return sends.
                if shift { return false }
                return parent.onKey(.submit)
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.onKey(.escape) {
                    dismissed = parent.controller.at
                    parent.controller.at = nil
                    DispatchQueue.main.async { self.parent.onQuery(nil) }
                    return true
                }
                // Not the text view's word completion: esc goes on to whatever holds the box (the popover closes).
                _ = tv.nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
                return true
            default: return false
            }
        }
    }
}

/// Lets the box put a picked mention in place of what's typed after the `@`.
@MainActor final class MentionController {
    weak var textView: NSTextView?
    /// Where the `@` being typed is.
    var at: Int?

    func insert(_ name: String, space: Bool = true) {
        guard let tv = textView, let at else { return }
        let caret = tv.selectedRange().location
        guard caret >= at else { return }
        let s = tv.string as NSString
        // A space after it, unless one's there already.
        let spaced = !space || (caret < s.length && s.character(at: caret) == 0x20) ? "" : " "
        // Picked: the list closes and stays closed, even though what's after the `@` could still match more
        // ("@folder:footage " is the start of "footage / _stills").
        if space { (tv.delegate as? MentionField.Coordinator)?.dismissed = at }
        tv.insertText("@" + name + spaced, replacementRange: NSRange(location: at, length: caret - at))
        if spaced.isEmpty, space { tv.setSelectedRange(NSRange(location: at + (name as NSString).length + 2, length: 0)) }
        if space { self.at = nil }
        tv.window?.makeFirstResponder(tv)
    }
}
