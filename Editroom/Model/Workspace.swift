import SwiftUI
import AppKit
import Combine

/// The projects open in the window, one to a tab. Only the tab in front plays, rebuilds and talks to the
/// AI apps; the others are paused with their player let go, so a tab behind costs next to nothing.
@MainActor
final class Workspace: ObservableObject {
    static let shared = Workspace()

    @Published private(set) var tabs: [EditorModel]
    @Published private(set) var active: EditorModel
    /// The tab in front's changes are passed on, so the menus (which read it) stay current.
    private var activeWatch: AnyCancellable?

    private static let tabsKey = "tabSlots"
    private static let activeKey = "activeTab"
    /// Test launches (`--open`, `--selftest`) open one tab and leave the saved tabs alone.
    private let persists: Bool

    private init() {
        let args = CommandLine.arguments
        persists = !args.contains("--open") && !args.contains("--selftest")
        var slots = persists ? (UserDefaults.standard.stringArray(forKey: Self.tabsKey) ?? [""]) : [""]
        if slots.isEmpty { slots = [""] }
        let front = slots.firstIndex(of: UserDefaults.standard.string(forKey: Self.activeKey) ?? "") ?? 0
        let models = slots.enumerated().map { EditorModel(slot: $0.element, background: $0.offset != front) }
        tabs = models
        active = models[front]
        watchActive()
    }

    /// While Magic works on the tab in front, it stays in front.
    private var locked: Bool { MagicState.shared.stage != nil || MagicShow.isRunning }

    private func watchActive() {
        activeWatch = active.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func remember() {
        guard persists else { return }
        UserDefaults.standard.set(tabs.map(\.slot), forKey: Self.tabsKey)
        UserDefaults.standard.set(active.slot, forKey: Self.activeKey)
    }

    // MARK: Switching

    func select(_ model: EditorModel) {
        guard model !== active, tabs.contains(where: { $0 === model }), !locked else { return }
        if NSApp.keyWindow?.firstResponder is NSText { NSApp.keyWindow?.makeFirstResponder(nil) }
        active.suspend()
        active = model
        model.resume()
        watchActive()
        AppDelegate.shared?.model = model
        remember()
    }

    func selectNext() { step(1) }
    func selectPrevious() { step(-1) }

    private func step(_ by: Int) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0 === active }) else { return }
        select(tabs[(i + by + tabs.count) % tabs.count])
    }

    // MARK: Opening and closing

    /// A new, empty tab, just after the one in front.
    func newTab() {
        guard !locked else { return }
        let model = EditorModel(slot: String(UUID().uuidString.prefix(8)), background: true)
        let at = (tabs.firstIndex { $0 === active } ?? tabs.count - 1) + 1
        tabs.insert(model, at: at)
        select(model)
    }

    /// Opens a project: in front if it's already open, else in the tab in front when that's empty, else in a new tab.
    func open(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let open = tabs.first(where: { $0.openPath == path }) { select(open); return }
        guard FileManager.default.fileExists(atPath: path) else {
            active.importError = "“\(url.lastPathComponent)” can't be found. It may have been moved or deleted."
            return
        }
        guard !locked else { return }
        if !active.isBlank { newTab() }
        active.open(url: url)
    }

    /// Files opened from Finder or dropped on the Dock icon. Projects open in tabs; media goes into the tab in
    /// front, or, for files that opened Editroom, into a new tab unless the one in front is empty.
    func openFromOutside(_ urls: [URL], atLaunch: Bool) {
        Task {
            // What the tab in front had open is reopened first, so it's known whether it's empty.
            for _ in 0..<150 where active.needsRestore { try? await Task.sleep(nanoseconds: 20_000_000) }
            for url in urls where EditorModel.isProjectFile(url) { open(url) }
            let media = urls.filter { !EditorModel.isProjectFile($0) }
            if !media.isEmpty {
                if atLaunch, !active.isBlank { newTab() }
                active.importFiles(media)
            }
            NSApp.activate()
        }
    }

    /// Closes a tab, asking first about unsaved work as closing the project would. The last tab stays, with its
    /// project closed and an empty Untitled one in its place.
    func close(_ model: EditorModel) {
        if tabs.count == 1 {
            guard !locked else { return }
            model.closeProject()
            return
        }
        guard let i = tabs.firstIndex(where: { $0 === model }), !(locked && model === active) else { return }
        // Unsaved work in it is put in front before asking about it.
        model.restoreIfNeeded()
        if model.isDirty { select(model) }
        guard model.confirmDiscard() else { return }
        let wasActive = model === active
        model.suspend()
        model.forgetSlot()
        tabs.remove(at: i)
        if wasActive {
            let next = tabs[min(i, tabs.count - 1)]
            active = next
            next.resume()
            watchActive()
            AppDelegate.shared?.model = next
        }
        remember()
    }

    /// ⌘W: closes the window in front (Settings, About), or with the editor in front, its tab.
    func closeActive() {
        if let window = NSApp.keyWindow, window.identifier?.rawValue.hasPrefix("main") != true {
            // A sheet on the editor (Export) isn't closed this way; anything else in front is.
            if window.sheetParent == nil, window.styleMask.contains(.closable) { window.performClose(nil) }
            return
        }
        close(active)
    }

    /// Close Tab does something: there's another tab, or a project in this one.
    var canClose: Bool { tabs.count > 1 || !active.isBlank }

    func closeOthers(than model: EditorModel) {
        for other in tabs where other !== model { close(other) }
    }

    // MARK: Quitting

    /// Each tab with unsaved changes that need saving asks, in front, before Editroom quits.
    func confirmQuit() -> Bool {
        for model in [active] + tabs.filter({ $0 !== active }) {
            if !EditorModel.autosaves, model.isDirty { select(model) }
            guard model.confirmDiscard(quitting: true) else { return false }
        }
        return true
    }

    func autosaveAll() {
        for model in tabs { model.autosaveNow() }
    }
}

/// The panels' sizes, the same in every tab.
@MainActor
final class PanelLayout: ObservableObject {
    static let shared = PanelLayout()
    @Published var libraryWidth: CGFloat = 252
    @Published var timelineHeight: CGFloat = 360
}
