import AppKit
import SwiftUI

/// A key and its modifiers, like ⌘⇧S or Space.
struct KeyCombo: Codable, Hashable {
    /// A lowercased character ("s", "=", "\\") or a named key ("space", "delete", "left"…).
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    static func cmd(_ key: String, shift: Bool = false, option: Bool = false) -> KeyCombo {
        KeyCombo(key, command: true, shift: shift, option: option)
    }

    private static let named: [UInt16: String] = [
        49: "space", 51: "delete", 117: "forwardDelete", 123: "left", 124: "right", 125: "down", 126: "up",
        115: "home", 119: "end", 36: "return", 48: "tab", 116: "pageUp", 121: "pageDown",
    ]

    /// The combo a key press makes (nil for Escape, which always cancels).
    init?(event e: NSEvent) {
        if e.keyCode == 53 { return nil }
        let f = e.modifierFlags
        if let name = Self.named[e.keyCode] {
            key = name
        } else if let c = e.charactersIgnoringModifiers?.lowercased(), !c.isEmpty {
            key = c
        } else {
            return nil
        }
        command = f.contains(.command)
        shift = f.contains(.shift)
        option = f.contains(.option)
        control = f.contains(.control)
    }

    /// Plain keys and ⌥/⇧ ones are typing in a text field; ⌘ and ⌃ ones never are.
    var typesText: Bool { !command && !control }

    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        switch key {
        case "space": s += "Space"
        case "delete": s += "⌫"
        case "forwardDelete": s += "⌦"
        case "left": s += "←"
        case "right": s += "→"
        case "up": s += "↑"
        case "down": s += "↓"
        case "home": s += "Home"
        case "end": s += "End"
        case "return": s += "↩"
        case "tab": s += "⇥"
        case "pageUp": s += "Page Up"
        case "pageDown": s += "Page Down"
        default: s += key.uppercased()
        }
        return s
    }

    /// For a menu item.
    var keyboardShortcut: KeyboardShortcut? {
        let k: KeyEquivalent
        switch key {
        case "space": k = .space
        case "delete": k = .delete
        case "forwardDelete": k = .deleteForward
        case "left": k = .leftArrow
        case "right": k = .rightArrow
        case "up": k = .upArrow
        case "down": k = .downArrow
        case "home": k = .home
        case "end": k = .end
        case "return": k = .return
        case "tab": k = .tab
        case "pageUp": k = .pageUp
        case "pageDown": k = .pageDown
        default:
            guard key.count == 1, let c = key.first else { return nil }
            k = KeyEquivalent(c)
        }
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return KeyboardShortcut(k, modifiers: m)
    }
}

/// Everything that has a keyboard shortcut.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case new, open, save, saveAs, importMedia, export
    case newTab, closeTab, previousTab, nextTab
    case undo, redo
    case playPause, stepBack, stepForward, previousEdit, nextEdit, goToStart, goToEnd, loop, fullScreenViewer
    case selectTool, cutTool
    case split, addDissolve, detachAudio, duplicate, freezeFrame, reverse, copyGrade, pasteGrade, delete, rippleDelete, rippleTrimStart, rippleTrimEnd, addText, revealInMedia
    case addMarker, setIn, setOut, clearInOut
    case zoomIn, zoomOut, zoomToFit, snapping, sticky, skimming, audioScrubbing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .new: "New"
        case .open: "Open…"
        case .save: "Save"
        case .saveAs: "Save As…"
        case .importMedia: "Import Media…"
        case .export: "Export…"
        case .newTab: "New Tab"
        case .closeTab: "Close Tab"
        case .previousTab: "Show Previous Tab"
        case .nextTab: "Show Next Tab"
        case .undo: "Undo"
        case .redo: "Redo"
        case .playPause: "Play / Pause"
        case .stepBack: "Back One Frame"
        case .stepForward: "Forward One Frame"
        case .previousEdit: "Previous Edit"
        case .nextEdit: "Next Edit"
        case .goToStart: "Go to Start"
        case .goToEnd: "Go to End"
        case .loop: "Loop Playback"
        case .fullScreenViewer: "Full Screen Viewer"
        case .selectTool: "Select Tool"
        case .cutTool: "Cut Tool"
        case .split: "Split at Playhead"
        case .addDissolve: "Add Dissolve"
        case .detachAudio: "Detach Audio"
        case .duplicate: "Duplicate"
        case .freezeFrame: "Freeze Frame"
        case .reverse: "Reverse"
        case .copyGrade: "Copy Grade"
        case .pasteGrade: "Paste Grade"
        case .delete: "Delete"
        case .rippleDelete: "Ripple Delete"
        case .rippleTrimStart: "Ripple Trim Start to Playhead"
        case .rippleTrimEnd: "Ripple Trim End to Playhead"
        case .revealInMedia: "Reveal in Media"
        case .addText: "Add Text"
        case .addMarker: "Add Marker"
        case .setIn: "Set In"
        case .setOut: "Set Out"
        case .clearInOut: "Clear In and Out"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomToFit: "Zoom to Fit"
        case .snapping: "Snapping"
        case .sticky: "Sticky Edges"
        case .skimming: "Skimming"
        case .audioScrubbing: "Audio Scrubbing"
        }
    }

    enum Group: String, CaseIterable {
        case file = "File", tabs = "Tabs", edit = "Edit", playback = "Playback", tools = "Tools", clip = "Clip", mark = "Mark", view = "View"
    }

    var group: Group {
        switch self {
        case .new, .open, .save, .saveAs, .importMedia, .export: .file
        case .newTab, .closeTab, .previousTab, .nextTab: .tabs
        case .undo, .redo: .edit
        case .playPause, .stepBack, .stepForward, .previousEdit, .nextEdit, .goToStart, .goToEnd, .loop, .fullScreenViewer: .playback
        case .selectTool, .cutTool: .tools
        case .split, .addDissolve, .detachAudio, .duplicate, .freezeFrame, .reverse, .copyGrade, .pasteGrade, .delete, .rippleDelete, .rippleTrimStart, .rippleTrimEnd, .addText, .revealInMedia: .clip
        case .addMarker, .setIn, .setOut, .clearInOut: .mark
        case .zoomIn, .zoomOut, .zoomToFit, .snapping, .sticky, .skimming, .audioScrubbing: .view
        }
    }

    /// Shown in a menu (which shows the first of its shortcuts).
    var inMenu: Bool {
        switch self {
        case .playPause, .stepBack, .stepForward, .previousEdit, .nextEdit, .goToStart, .goToEnd, .loop, .fullScreenViewer,
             .selectTool, .cutTool: false
        default: true
        }
    }

    var defaults: [KeyCombo] {
        switch self {
        case .new: [.cmd("n")]
        case .open: [.cmd("o")]
        case .save: [.cmd("s")]
        case .saveAs: [.cmd("s", shift: true)]
        case .importMedia: [.cmd("i")]
        case .export: [.cmd("e")]
        case .newTab: [.cmd("t")]
        case .closeTab: [.cmd("w")]
        case .previousTab: [.cmd("[", shift: true)]
        case .nextTab: [.cmd("]", shift: true)]
        case .undo: [.cmd("z")]
        case .redo: [.cmd("z", shift: true)]
        case .playPause: [KeyCombo("space")]
        case .stepBack: [KeyCombo("left")]
        case .stepForward: [KeyCombo("right")]
        case .previousEdit: [KeyCombo("up"), KeyCombo("left", shift: true)]
        case .nextEdit: [KeyCombo("down"), KeyCombo("right", shift: true)]
        case .goToStart: [KeyCombo("home")]
        case .goToEnd: [KeyCombo("end")]
        case .loop: [KeyCombo("l")]
        case .fullScreenViewer: [KeyCombo("f")]
        case .selectTool: [KeyCombo("v"), KeyCombo("a")]
        case .cutTool: [KeyCombo("c")]
        case .split: [.cmd("k")]
        case .addDissolve: [.cmd("d")]
        case .detachAudio: [.cmd("l", shift: true)]
        case .duplicate: [.cmd("d", shift: true)]
        case .freezeFrame: [KeyCombo("f", option: true)]
        case .reverse: [KeyCombo("r", option: true)]
        case .copyGrade: [.cmd("c", option: true)]
        case .pasteGrade: [.cmd("v", option: true)]
        case .delete: [KeyCombo("delete"), KeyCombo("forwardDelete")]
        case .rippleDelete: [KeyCombo("delete", shift: true), KeyCombo("forwardDelete", shift: true)]
        case .rippleTrimStart: [KeyCombo("q")]
        case .rippleTrimEnd: [KeyCombo("w")]
        // As in Final Cut Pro (Reveal in Browser).
        case .revealInMedia: [KeyCombo("f", shift: true)]
        // ⌃T, as in Final Cut Pro (⌘T is New Tab).
        case .addText: [KeyCombo("t", control: true)]
        case .addMarker: [KeyCombo("m")]
        case .setIn: [KeyCombo("i")]
        case .setOut: [KeyCombo("o")]
        case .clearInOut: [KeyCombo("x", shift: true)]
        case .zoomIn: [.cmd("="), KeyCombo("="), KeyCombo("+", shift: true)]
        case .zoomOut: [.cmd("-"), KeyCombo("-")]
        case .zoomToFit: [.cmd("0"), KeyCombo("z", shift: true), KeyCombo("\\")]
        case .snapping: [KeyCombo("s")]
        case .sticky: [KeyCombo("r")]
        case .skimming: [KeyCombo("k")]
        case .audioScrubbing: [KeyCombo("s", shift: true)]
        }
    }
}

/// The shortcuts in use: the defaults, with the person's changes (kept in UserDefaults).
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    private static let key = "shortcuts"

    @Published private(set) var changed: [ShortcutAction: [KeyCombo]] = [:]
    /// While Settings is recording a shortcut, no shortcut does anything.
    @Published var recording: ShortcutAction?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: [KeyCombo]].self, from: data) {
            for (k, v) in saved { if let a = ShortcutAction(rawValue: k) { changed[a] = v } }
        }
    }

    func combos(_ a: ShortcutAction) -> [KeyCombo] { changed[a] ?? a.defaults }
    func isChanged(_ a: ShortcutAction) -> Bool { changed[a] != nil }

    /// For the action's menu item: its first shortcut.
    func menu(_ a: ShortcutAction) -> KeyboardShortcut? {
        guard let c = combos(a).first else { return nil }
        // Plain Delete, Space, arrows and the like stay with the editor window (KeyCommands): as a menu
        // shortcut, ⌫ in Settings or a sheet would delete clips.
        if !c.command, !c.control, !c.option, c.key.count > 1 { return nil }
        return c.keyboardShortcut
    }

    /// The action a combo runs, if any.
    func action(for combo: KeyCombo) -> ShortcutAction? {
        ShortcutAction.allCases.first { combos($0).contains(combo) }
    }

    /// Menu shortcuts a text field would lose to the menu (plain keys like S): these are typed instead.
    func isTypedMenuKey(_ combo: KeyCombo) -> Bool {
        combo.typesText && ShortcutAction.allCases.contains { $0.inMenu && combos($0).first == combo }
    }

    /// Gives an action one shortcut. Another action using it loses it; returns that action.
    @discardableResult
    func set(_ a: ShortcutAction, to combo: KeyCombo) -> ShortcutAction? {
        var taken: ShortcutAction?
        for other in ShortcutAction.allCases where other != a && combos(other).contains(combo) {
            changed[other] = combos(other).filter { $0 != combo }
            taken = other
        }
        changed[a] = [combo]
        save()
        return taken
    }

    func clear(_ a: ShortcutAction) {
        changed[a] = []
        save()
    }

    func reset(_ a: ShortcutAction) {
        changed[a] = nil
        save()
    }

    func resetAll() {
        changed = [:]
        save()
    }

    private func save() {
        var out: [String: [KeyCombo]] = [:]
        for (k, v) in changed { out[k.rawValue] = v }
        if out.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(out) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
