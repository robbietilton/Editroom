import AppKit

/// Editroom's alerts: the system's, with dark text on the main button (the one Return presses), which reads
/// better on its grey than white does. Its colour can't be set here: the system paints it in the accent colour,
/// which is a mid grey on the dark themes and a light one on Light (Assets › AccentColor).
final class EditroomAlert: NSAlert {
    @discardableResult
    override func runModal() -> NSApplication.ModalResponse {
        // Clicks and keys still waiting from before it opened (made while an import kept the app busy, or the
        // click that brought Editroom to the front) were meant for the window behind it: let go of, rather than
        // turned away with macOS's beep once the alert is up.
        if let now = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                        subtype: 0, data1: 0, data2: 0) {
            NSApp.discardEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
                                           .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                           .keyDown, .keyUp, .scrollWheel], before: now)
        }
        // Run here rather than by NSAlert, which puts it high on the screen: centred on Editroom's window.
        guard let parent = Self.appWindow else {
            styleButtons()
            // NSAlert sets its buttons up again as it opens, so they're styled once more once it's showing.
            RunLoop.main.perform(inModes: [.modalPanel, .default]) { [weak self] in self?.styleButtons() }
            return super.runModal()
        }
        prepare(action: #selector(stopModal(_:)))
        center(over: parent)
        RunLoop.main.perform(inModes: [.modalPanel]) { [weak self] in
            self?.styleButtons()
            self?.center(over: parent)
        }
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)
        return response
    }

    @objc private func stopModal(_ sender: NSButton) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: sender.tag))
    }

    /// Editroom's window, the one alerts are centred on.
    private static var appWindow: NSWindow? {
        if let w = NSApp.mainWindow, w.isVisible { return w }
        return NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    /// Laid out, with each button answering through `action` (its tag is its response).
    private func prepare(action: Selector) {
        layout()
        for (i, button) in buttons.enumerated() {
            button.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + i
            button.target = self
            button.action = action
        }
        styleButtons()
    }

    /// Centred on `parent`, across and up and down.
    private func center(over parent: NSWindow) {
        let f = parent.frame, size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (f.midX - size.width / 2).rounded(), y: (f.midY - size.height / 2).rounded()))
    }

    override func beginSheetModal(for sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        styleButtons()
        super.beginSheetModal(for: sheetWindow, completionHandler: handler)
        DispatchQueue.main.async { [weak self] in self?.styleButtons() }
    }

    /// Shown over `parent` without holding up the app: clicks, keys and files dropped on the editor while it's up go
    /// there as usual, rather than being turned away with macOS's beep. It looks as `runModal` shows it.
    func show(over parent: NSWindow, then handler: @escaping (NSApplication.ModalResponse) -> Void) {
        prepare(action: #selector(pressed(_:)))
        answer = handler
        Self.showing.insert(self)
        center(over: parent)
        parent.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        // Its size can settle once it's showing: centred again then.
        DispatchQueue.main.async { [weak self] in
            self?.styleButtons()
            self?.center(over: parent)
        }
    }

    private var answer: ((NSApplication.ModalResponse) -> Void)?
    /// Kept while showing (nothing else holds an alert that isn't run modally).
    private static var showing: Set<EditroomAlert> = []

    @objc private func pressed(_ sender: NSButton) {
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        let handler = answer
        answer = nil
        Self.showing.remove(self)
        handler?(NSApplication.ModalResponse(rawValue: sender.tag))
    }

    private func styleButtons() {
        guard let main = buttons.first(where: { $0.keyEquivalent == "\r" }) ?? buttons.first else { return }
        main.attributedTitle = NSAttributedString(string: main.title, attributes: [
            .foregroundColor: NSColor.black,
            .font: main.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        main.needsDisplay = true
    }
}
