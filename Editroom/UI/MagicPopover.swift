import AppKit
import SwiftUI

/// The Magic button's popover. A switch (like the timeline's select and cut tools) picks Claude,
/// ChatGPT or Local. An AI that's ready shows the prompt; one that isn't walks through connecting it
/// right here. Disconnecting lives in AI Agents.
struct MagicPopover: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var ai: MagicAgent
    @ObservedObject var connections = AgentConnect.shared
    @ObservedObject var server = MCPServer.shared
    let close: () -> Void

    /// What they're typing: kept on MagicAgent, so closing the popover to look around doesn't lose it.
    private var request: String {
        get { ai.prompt }
        nonmutating set { ai.prompt = newValue }
    }
    /// Just connected from here: a moment to say so before the prompt.
    @State private var justConnected: MagicAgent.Kind?
    /// Connecting started from here (so finishing it shows "connected").
    @State private var connecting: MagicAgent.Kind?

    private var hasEdit: Bool { model.project.clips.contains { $0.kind != .audio } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AITabs(selection: $ai.tab)
            content
                .padding(.top, 12)
        }
        .padding(14)
        .frame(width: 380)
        .background(Theme.panel)
        .onAppear { connections.refresh() }
        .onChange(of: ai.available) { _, now in
            if let k = connecting, now.contains(k) {
                justConnected = k
                connecting = nil
            }
        }
    }

    // MARK: What the tab shows

    @ViewBuilder private var content: some View {
        if let kind = ai.tab.kind {
            if justConnected == kind {
                Centered(logo: AppLogo(kind: kind, size: 36), title: "\(kind.name) is connected",
                         text: kind == .claude ? "Tell it what to make. You can disconnect any time in AI Agents."
                                               : "Tell it what to make. To edit from the ChatGPT app as well, quit and reopen it once.") {
                    PillButton(title: "Continue", prominent: true) { justConnected = nil }
                }
            } else if !ai.installed(kind) {
                Centered(logo: AppLogo(kind: kind, size: 36), title: "Get the \(kind.name) app",
                         text: kind == .claude ? "Claude edits for you through the Claude app on this Mac. Install it, then come back to connect."
                                               : "ChatGPT edits for you through Codex in the ChatGPT app on this Mac. Install it, then come back to connect.") {
                    PillButton(title: "Download \(kind.name)", prominent: true) {
                        if let url = (kind == .claude ? AgentApp.claude : AgentApp.chatgpt).download { NSWorkspace.shared.open(url) }
                    }
                }
            } else if kind == .claude, connections.states[.claude] == .waiting {
                Centered(logo: AppLogo(kind: kind, size: 36), title: "Finish in the Claude app",
                         text: "Claude is asking whether to add Editroom. Click Install there and this updates by itself.") {
                    HStack(spacing: 8) {
                        PillButton(title: "Cancel", prominent: false) {
                            connecting = nil
                            connections.cancelWaiting()
                        }
                        PillButton(title: "Open Claude again", prominent: false) { connections.reopenClaude() }
                    }
                }
            } else if !ai.connected(kind) {
                Centered(logo: AppLogo(kind: kind, size: 36), title: "Connect \(kind.name)",
                         text: kind == .claude ? "Let Claude edit for you, with your Claude plan. Nothing is shared until you ask it to make an edit."
                                               : "Let ChatGPT edit for you, with your ChatGPT plan. It works through Codex in the ChatGPT app.") {
                    VStack(spacing: 7) {
                        PillButton(title: "Connect \(kind.name)", prominent: true) { connect(kind) }
                        Text("No API key needed").font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                    }
                }
                if case .failed(let why) = connections.states[app(for: kind)] {
                    Text(why).font(.system(size: 11)).foregroundStyle(Color(hex: 0xE5735C)).frame(maxWidth: .infinity).padding(.top, 6)
                }
            } else if !ai.runnable(kind) {
                // Connected for use from the Claude app, but Magic runs Claude Code, which the Claude
                // app installs the first time its Code tab is opened.
                Centered(logo: AppLogo(kind: kind, size: 36), title: "Open Claude Code once",
                         text: "Magic uses Claude Code, which comes with the Claude app. Open the Claude app's Code tab once, then come back.") {
                    PillButton(title: "Open Claude", prominent: true) {
                        if let url = AgentConnect.appURL(AgentConnect.claudeBundleID) {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
            } else {
                PromptForm(model: model, ai: ai, kind: kind, request: $ai.prompt, hasEdit: hasEdit,
                           manage: { close(); model.showAgents = true }) { go(kind) }
            }
        } else {
            // Laid out like the AI tabs, with ideas Local can do.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(hasEdit ? "What should change?" : "What should it make?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    if LocalBrain.available {
                        HStack(spacing: 5) {
                            IdeasMenu(sections: LocalIdeas.sections(hasEdit: hasEdit)) { idea in
                                request = idea
                            }
                            HistoryMenu(model: model) { request = $0 }
                        }
                    }
                }
                .padding(.bottom, 8)
                if LocalBrain.available {
                    // Apple's on-device model reads the request into settings Local follows.
                    PromptBox(model: model, text: $ai.prompt,
                              placeholder: hasEdit
                                ? "Describe what to change (length, pace, look, music, vertical), or leave this empty to improve the edit."
                                : "Describe the video you want (length, pace, look, music, vertical), or leave this empty for the best cut.",
                              submit: goLocal)
                        .padding(.bottom, 11)
                } else if let why = LocalBrain.unavailableReason {
                    Text(why)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 11)
                }
                HStack(alignment: .center, spacing: 5) {
                    // Where the AI tabs pick a model: Local always uses Apple's, so plain text, not a chip.
                    if LocalBrain.available {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Image(systemName: "apple.logo").font(.system(size: 10, weight: .semibold))
                                Text("Apple Intelligence").font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Theme.textDim)
                            .padding(.leading, 2)
                            PlanNote(text: "On this Mac")
                        }
                    }
                    Spacer()
                    PillButton(title: "Make it", prominent: true, action: goLocal)
                        // Return in the box sends (it's the box's, so the @ list can use it).
                }
            }
        }
    }

    // MARK: Actions

    private func app(for kind: MagicAgent.Kind) -> AgentApp {
        switch kind {
        case .chatgpt: .chatgpt
        // The Claude app's extension; Claude Code when there's no Claude app.
        case .claude: AgentConnect.appURL(AgentConnect.claudeBundleID) != nil ? .claude : .claudeCode
        }
    }

    private func connect(_ kind: MagicAgent.Kind) {
        connecting = kind
        // Connecting an AI here means letting AI apps in.
        if !server.enabled { server.enabled = true }
        let app = app(for: kind)
        if connections.states[app] == .connected {
            connections.refresh()
            justConnected = kind
            connecting = nil
        } else {
            connections.connect(app)
        }
    }

    private func goLocal() {
        close()
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        request = ""
        model.addMagicPrompt(text, tab: .local)
        LocalMagic.run(text, model: model)
    }

    private func go(_ kind: MagicAgent.Kind) {
        close()
        model.addMagicPrompt(request, tab: kind == .claude ? .claude : .chatgpt)
        ai.start(request: request, with: kind, model: model)
        request = ""
    }
}

// MARK: Pieces

/// Claude, ChatGPT or Local, in the style of the timeline's select and cut switch.
private struct AITabs: View {
    @Binding var selection: MagicAgent.Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MagicAgent.Tab.allCases) { tab in
                AITab(tab: tab, on: selection == tab) { selection = tab }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.bg))
    }
}

private struct AITab: View {
    let tab: MagicAgent.Tab
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let kind = tab.kind {
                    AppLogo(kind: kind, size: 15).opacity(on ? 1 : 0.8)
                } else {
                    // Local runs on Apple Intelligence: Apple's mark, as the other tabs show their maker's.
                    Image(systemName: "apple.logo").font(.system(size: 12.5, weight: .semibold))
                        .frame(width: 15, height: 15)
                        .offset(y: -1.5)
                }
                Text(tab.name).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(on || hovering ? Theme.text : Theme.textDim)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.raised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.ink.opacity(on ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// An AI's own app icon, from the app on this Mac.
struct AppLogo: View {
    let kind: MagicAgent.Kind
    let size: CGFloat

    private var icon: NSImage? {
        let ids = kind == .claude ? [AgentConnect.claudeBundleID] : AgentConnect.chatgptBundleIDs
        guard let url = ids.lazy.compactMap(AgentConnect.appURL).first else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(kind == .claude ? Color(hex: 0xD97757) : Color(hex: 0xF2F2F0))
                .frame(width: size, height: size)
                .overlay(Image(systemName: kind == .claude ? "asterisk" : "circle.dashed")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(kind == .claude ? .white : .black))
        }
    }
}

/// A centred step: logo, title, a line or two, and its buttons.
private struct Centered<Buttons: View>: View {
    let logo: AppLogo
    let title: String
    let text: String
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 0) {
            logo.padding(.bottom, 9)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 4)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            buttons()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// What should the AI make? Typed, or picked from a few ideas. Empty makes the best cut it can.
private struct PromptForm: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var ai: MagicAgent
    let kind: MagicAgent.Kind
    @Binding var request: String
    let hasEdit: Bool
    let manage: () -> Void
    let go: () -> Void

    private static let make: [Idea] = [
        ("Story", "book",
         "Make the best story you can from this footage: a clear beginning, middle and end, the strongest moments where they land hardest, and shots left to breathe where it matters."),
        ("Highlight reel", "sparkles",
         "Make a 30 to 60 second highlight reel of the best moments, cut to the beat of the music, opening on the strongest shot and ending on a bar."),
        ("Timelapse", "timer",
         "Make a timelapse over the music: speed the footage up, cut out the dead space where nothing changes, keep the moments where something happens, and end on the strongest shot."),
        ("Vlog", "person.wave.2",
         "Make an engaging vlog, up to 8 minutes: hook in the first few seconds, keep the parts where someone is talking or something happens, cut pauses, retakes and repeats, and add short titles to mark each part."),
        ("Vertical reel", "iphone",
         "Make a fast, punchy 15 to 30 second vertical video for Reels and TikTok: 1080 by 1920, a hook in the first second, quick cuts on the beat."),
    ]

    private static let improve: [Idea] = [
        ("Tighten it", "scissors",
         "Make this shorter so people keep watching: open on the strongest moment, cut the slow starts and ends of shots, and drop weak or repeated shots."),
        ("Cut to the beat", "metronome",
         "Recut this to the beat of the music: cuts on beats, the biggest moments on bar starts, and end on a bar."),
        ("Smooth it out", "wind",
         "Smooth this out: fix jumpy cuts, add a dissolve only where the scene changes, even out the sound, and fade in and out."),
        ("One look", "camera.filters",
         "Give it one consistent look: the same warm film grade on every shot, matched in brightness so it feels like one film."),
    ]

    private static let sound: [Idea] = [
        ("Find music", "magnifyingglass",
         "Find music that suits this video and add it to the timeline. Make sure the music is royalty free and does not require attribution."),
        ("Music and levels", "music.note",
         "Pick the best music in my Media for this edit, cut so the music and pictures land together, keep voices clear over it, and fade in and out."),
    ]

    private var placeholder: String {
        hasEdit
            ? "Describe what to change, or leave this empty and \(kind.name) will make the best video it can from your Media."
            : "Describe the video you want, or leave this empty and \(kind.name) will make the best video it can from the clips and music in your Media."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hasEdit ? "What should change?" : "What should it make?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                // Ideas fill the box, to send as they are or change first.
                HStack(spacing: 5) {
                    IdeasMenu(sections: (hasEdit ? [("Improve", Self.improve)] : []) + [("Create", Self.make), ("Sound", Self.sound)],
                              use: use)
                    HistoryMenu(model: model, use: use)
                }
            }
            .padding(.bottom, 8)
            PromptBox(model: model, text: $request, placeholder: placeholder, submit: go)
                .padding(.bottom, 11)
            HStack(alignment: .center, spacing: 5) {
                // The model, and whose plan it uses, under it.
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        ModelChip(ai: ai, kind: kind, manage: manage)
                        EffortChip(ai: ai, kind: kind)
                    }
                    PlanNote(text: "Uses your \(kind.name) plan")
                }
                Spacer()
                PillButton(title: "Make it", prominent: true, action: go)
                    // Return in the box sends (it's the box's, so the @ list can use it).
            }
        }
    }

    private func use(_ idea: String) {
        request = idea
    }
}

/// A name for the menu, and the prompt it fills the box with (to send as it is, or change first).
private typealias Idea = (name: String, symbol: String, prompt: String)

/// Ideas for Local: only what it can do (length, pace, a look, music on or off, frame shape, speed,
/// sound effects, levels), said the short way its reader understands best.
private enum LocalIdeas {
    static let improve: [Idea] = [
        ("Tighten it", "scissors", "Make it shorter and faster."),
        ("Cut to the beat", "metronome", "Cut it to the beat of the music."),
        ("One look", "camera.filters", "Give every shot the Film print look."),
        ("Clean it up", "sparkles", "Take out repeats and weak shots, and trim long shots."),
    ]
    static let make: [Idea] = [
        ("Quick cut", "wand.and.stars", "Make a new quick cut of the best moments, to the beat."),
        ("30-second highlight", "star", "Make a fast 30 second highlight cut to the beat."),
        ("Vertical reel", "iphone", "Make a 20 second vertical video, fast."),
        ("Timelapse", "timer", "Speed every shot up 8x, over the music."),
        ("Slow and calm", "tortoise", "Make a calm 60 second cut."),
    ]
    static let sound: [Idea] = [
        ("Even out levels", "slider.horizontal.3", "Make all audio clips the same output level."),
    ]
    static func sections(hasEdit: Bool) -> [(String, [Idea])] {
        (hasEdit ? [("Improve", improve)] : []) + [("Create", make), ("Sound", sound)]
    }
}

/// The Ideas menu: sections of ideas, each filling the prompt box.
private struct IdeasMenu: View {
    let sections: [(String, [Idea])]
    let use: (String) -> Void
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button(action: open) { MenuIcon(symbol: "lightbulb") }
            .buttonStyle(.plain)
            .fixedSize()
            .background(AnchorView(anchor: anchor))
            .help("Ideas")
    }

    /// Made by hand like History's, so the two open in exactly the same place.
    private func open() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, (title, ideas)) in sections.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: title))
            for idea in ideas {
                let item = ActionItem(idea.name) { use(idea.prompt) }
                item.image = NSImage(systemSymbolName: idea.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        anchor.popUp(menu)
    }
}

/// Prompts sent before (newest first, the AI each went to on the right): one fills the box. A menu
/// made by hand, so each prompt can wrap to two lines and keep the menu narrow.
private struct HistoryMenu: View {
    let model: EditorModel
    let use: (String) -> Void

    /// The button's own view, so the menu opens under it (as Ideas does).
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button(action: open) { MenuIcon(symbol: "clock.arrow.circlepath") }
            .buttonStyle(.plain)
            .fixedSize()
            .background(AnchorView(anchor: anchor))
            .help("History")
            .onAppear {
                // `--magic-history-menu` (testing): opens the menu by itself.
                if CommandLine.arguments.contains("--magic-history-menu") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { open() }
                }
            }
    }

    private func open() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem.sectionHeader(title: "History"))
        let entries = model.magicHistory
        if entries.isEmpty {
            menu.addItem(ActionItem("Prompts you send show up here.", enabled: false) {})
        }
        if !entries.isEmpty {
            // In a list of its own that scrolls past the latest few (a menu can't be given a height).
            let list = NSMenuItem()
            list.view = HistoryList(entries: entries, rows: Self.shown) { [weak menu] text in
                menu?.cancelTracking()
                use(text)
            }
            menu.addItem(list)
        }
        anchor.popUp(menu)
    }

    /// How many prompts show before the list scrolls.
    static let shown = 8

    /// At most two lines of about `width` characters, broken between words, with … if there's more.
    static func wrapped(_ text: String, width: Int = 34) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var lines: [String] = [""]
        var rest = words[...]
        while let w = rest.first {
            let line = lines[lines.count - 1]
            if line.isEmpty || line.count + 1 + w.count <= width {
                lines[lines.count - 1] = line.isEmpty ? String(w.prefix(width)) : line + " " + w
                rest = rest.dropFirst()
            } else if lines.count < 2 {
                lines.append("")
            } else {
                break
            }
        }
        if !rest.isEmpty {
            var last = lines[lines.count - 1]
            if last.count > width - 1 { last = String(last.prefix(width - 1)).trimmingCharacters(in: .whitespaces) }
            lines[lines.count - 1] = last + "…"
        }
        return lines.joined(separator: "\n")
    }
}

/// Holds the view a hand-made menu opens from, and opens it there: its top level with the top of the
/// prompt box below the button (Ideas and History alike).
private final class MenuAnchor {
    weak var view: NSView?
    /// The box is 8pt under the buttons; macOS draws a menu about 3.5pt above where it's put.
    static let gap: CGFloat = 12

    @MainActor func popUp(_ menu: NSMenu) {
        guard let view, let window = view.window else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY - Self.gap), in: nil)
    }
}

private struct AnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        anchor.view = v
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { anchor.view = v }
}

/// The round icon button Ideas and History open from.
private struct MenuIcon: View {
    let symbol: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(hovering ? Theme.text : Theme.chip)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Theme.ink.opacity(hovering ? 0.12 : 0.07)))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Small grey line under the model: whose plan it uses, or that it's on this Mac.
private struct PlanNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textFaint)
            .padding(.leading, 4)
    }
}

/// The prompt box. It's as tall as its text, three lines at least, up to three times that; past that it
/// scrolls. Return sends; ⇧Return adds a line. Typing `@` lists what to point at: the playhead, the
/// selected clips, the in/out range and the files in Media.
private struct PromptBox: View {
    @ObservedObject var model: EditorModel
    @Binding var text: String
    let placeholder: String
    let submit: () -> Void

    @State private var textHeight: Double = 0
    /// What's typed after an `@` at the caret; nil when there's no list.
    @State private var query: String?
    @State private var picked = 0
    @State private var controller = MentionController()

    static let baseHeight = 66.0
    static let maxHeight = baseHeight * 3
    private static let font = Font.system(size: 12.5)

    private var height: Double { min(Self.maxHeight, max(Self.baseHeight, textHeight)) }
    private var options: [MentionOption] { query.map { MentionOption.list(for: $0, model: model) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            box
            if !options.isEmpty {
                MentionList(options: options, picked: picked) { accept($0) }
            }
        }
        // A new list (typed more, or what's on the timeline changed): the first row that can be picked.
        .onChange(of: options.map(\.id)) { _, _ in picked = options.firstIndex(where: \.enabled) ?? 0 }
        .onAppear {
            // Clips selected: the prompt starts pointing at them (easy to delete for a whole-edit ask).
            // A leftover "@selected" alone, with nothing selected now, goes.
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "@selected" {
                text = model.selection.contains(where: { id in model.project.clips.contains { $0.id == id } }) ? "@selected " : ""
            }
            // `--magic-type "text"` (testing): types into the box, as a person would.
            let args = CommandLine.arguments
            // `--magic-esc-test` (testing): @, esc, delete it, @ again; the list should be open.
            if args.contains("--magic-esc-test") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let tv = controller.textView else { return }
                    tv.insertText("@", replacementRange: tv.selectedRange())
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let before = query != nil
                        tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            let closed = query == nil
                            tv.deleteBackward(nil)
                            tv.insertText("@", replacementRange: tv.selectedRange())
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                FileHandle.standardError.write("MENTION ESC open=\(before) closed=\(closed) reopened=\(query != nil)\n".data(using: .utf8)!)
                            }
                        }
                    }
                }
            }
            if let k = args.firstIndex(of: "--magic-type"), args.count > k + 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    controller.textView?.insertText(args[k + 1], replacementRange: controller.textView?.selectedRange() ?? NSRange())
                }
            }
        }
    }

    private var box: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(Self.font)
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
            MentionField(text: $text, media: model.project.assets, clips: MagicMention.clipLabels(model.project),
                         markers: MagicMention.markerLabels(model.project), folders: MagicMention.folderLabels(model.project), onQuery: { query = $0 }, onKey: key, controller: controller)
                .padding(.vertical, 9)
        }
        .frame(height: height, alignment: .topLeading)
        // The text laid out at this width, unseen and behind, to measure how tall it wants to be. (Behind,
        // not in the box: in it, a tall text made the box's layout taller and the editor never scrolled.)
        .background(alignment: .topLeading) {
            Text(text.isEmpty ? placeholder : text + " ")
                .font(Self.font)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { textHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in textHeight = h }
                })
                .allowsHitTesting(false)
        }
        .clipped()
        .transaction { $0.animation = nil }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func key(_ k: MentionField.Key) -> Bool {
        let list = options
        let open = !list.isEmpty
        let usable = list.indices.filter { list[$0].enabled }
        switch k {
        case .up, .down:
            // No list open: ↑ in an empty box brings back the last prompt, and each ↑ the one before;
            // ↓ comes forward again, to an empty box.
            guard open else { return recall(back: k == .up) }
            guard !usable.isEmpty else { return true }
            let at = usable.firstIndex(of: picked) ?? 0
            picked = usable[(at + (k == .down ? 1 : usable.count - 1)) % usable.count]
            return true
        case .accept:
            guard open else { return false }
            if list.indices.contains(picked), list[picked].enabled { accept(list[picked]) } else { query = nil }
            return true
        case .escape:
            guard open else { return false }
            query = nil
            return true
        case .submit:
            submit()
            return true
        }
    }

    private func recall(back: Bool) -> Bool {
        let past = model.magicHistory.map(\.text)
        guard !past.isEmpty else { return false }
        let now = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if now.isEmpty {
            guard back else { return false }
            text = past[0]
            return true
        }
        guard let i = past.firstIndex(of: now) else { return false }
        if back {
            if i + 1 < past.count { text = past[i + 1] }
        } else {
            text = i > 0 ? past[i - 1] : ""
        }
        return true
    }

    private func accept(_ option: MentionOption) {
        guard option.enabled else { return }
        // "@media:" opens the list of every file, so the list stays open (no space after it).
        controller.insert(option.name, space: !option.opensList)
        if !option.opensList { query = nil }
    }
}

/// One thing the `@` list offers. Only what there is: no `@selected` with nothing selected, no
/// `@in-out` without a range.
private struct MentionOption: Identifiable {
    let id: String
    /// What goes in the text after the `@`.
    let name: String
    let detail: String
    var enabled = true
    /// `@media:`, which lists every file.
    var opensList = false
    /// A marker's colour, shown as a dot before its name.
    var tint: UInt32? = nil

    /// Words after `@media:` that pick a kind of file rather than a name.
    private static let kinds: [String: MediaKind] = [
        "video": .video, "videos": .video, "audio": .audio, "sound": .audio, "music": .audio,
        "photo": .image, "photos": .image, "image": .image, "images": .image,
    ]

    @MainActor static func list(for query: String, model: EditorModel) -> [MentionOption] {
        let p = model.project
        let q = query.lowercased()
        func clock(_ t: Double) -> String {
            let s = max(0, t)
            return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
        }
        func file(_ a: MediaAsset) -> MentionOption {
            let s = Int(a.duration.rounded())
            let length = String(format: "%d:%02d", s / 60, s % 60)
            // What kind it is, in words, like the Media list: a length for video, "Audio" and "Photo" said.
            let detail = switch a.kind {
            case .video: length + "  ·  Video"
            case .audio: length + "  ·  Audio"
            case .image: "Photo"
            }
            return MentionOption(id: a.id.uuidString, name: a.name, detail: detail)
        }
        /// Files by name: names starting with it first, then names with it inside.
        func files(matching text: String, in assets: [MediaAsset]) -> [MediaOption] {
            guard !text.isEmpty else { return assets.map(file) }
            let starts = assets.filter { $0.name.lowercased().hasPrefix(text) }
            let inside = text.contains(" ") ? [] : assets.filter { !$0.name.lowercased().hasPrefix(text) && $0.name.lowercased().contains(text) }
            return (starts + inside).map(file)
        }

        // "@clip:" and after: every clip on the timeline, in time order, narrowed by name or kind ("@clip:text").
        if q.hasPrefix("clip:") {
            let rest = String(q.dropFirst("clip:".count))
            let labels = MagicMention.clipLabels(p)
            let clipKinds: [String: Set<ClipKind>] = [
                "text": [.text], "texts": [.text], "title": [.text], "titles": [.text], "solid": [.solid], "solids": [.solid],
                "video": [.video], "videos": [.video], "audio": [.audio], "sound": [.audio], "music": [.audio],
                "photo": [.image], "photos": [.image], "image": [.image],
            ]
            func row(_ l: MagicMention.ClipLabel) -> MentionOption {
                let kind = switch l.kind {
                case .video: "Video"
                case .audio: "Audio"
                case .image: "Photo"
                case .solid: "Solid"
                case .text: "Text"
                }
                return MentionOption(id: l.id.uuidString, name: "clip:" + l.name, detail: "\(l.track)  ·  \(clock(l.start))  ·  \(kind)")
            }
            if let kinds = clipKinds[rest] { return labels.filter { kinds.contains($0.kind) }.map(row) }
            let starts = labels.filter { $0.name.lowercased().hasPrefix(rest) }
            let inside = rest.isEmpty || rest.contains(" ") ? [] : labels.filter { !$0.name.lowercased().hasPrefix(rest) && $0.name.lowercased().contains(rest) }
            return (starts + inside).map(row)
        }

        // "@marker:" and after: every marker, in time order, narrowed by name.
        let markers = MagicMention.markerLabels(p)
        func mark(_ l: MagicMention.MarkerLabel) -> MentionOption {
            MentionOption(id: l.id.uuidString, name: "marker:" + l.name, detail: "Marker  ·  \(clock(l.time))", tint: l.tint.hex)
        }
        if q.hasPrefix("marker:") {
            let rest = String(q.dropFirst("marker:".count))
            let starts = markers.filter { $0.name.lowercased().hasPrefix(rest) }
            let inside = rest.isEmpty || rest.contains(" ") ? [] : markers.filter { !$0.name.lowercased().hasPrefix(rest) && $0.name.lowercased().contains(rest) }
            return (starts + inside).map(mark)
        }

        // "@folder:" and after: every folder in Media (and the folders inside them), narrowed by name.
        let folders = MagicMention.folderLabels(p)
        func files(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }
        /// A folder, and after it, for one with folders inside, the same folder without them (`:only`).
        func folder(_ f: MagicMention.FolderLabel) -> [MentionOption] {
            let all = MentionOption(id: f.path, name: "folder:" + f.name, detail: (f.label == f.name ? "" : f.label + "  ·  ") + files(f.files.count))
            guard f.hasSubfolders else { return [all] }
            return [all, MentionOption(id: f.path + ":only", name: "folder:" + f.name + ":only", detail: "no sub-folders, " + files(f.direct.count))]
        }
        if q.hasPrefix("folder:") {
            let rest = String(q.dropFirst("folder:".count))
            // "@folder:footage:" and on: just that folder's two rows.
            let whole = folders.filter { f in rest.hasPrefix(f.name.lowercased() + ":") && (f.name.lowercased() + ":only").hasPrefix(rest) }
            if !whole.isEmpty { return whole.flatMap(folder).filter { $0.name.lowercased().hasPrefix("folder:" + rest) } }
            let starts = folders.filter { $0.name.lowercased().hasPrefix(rest) }
            let inside = rest.isEmpty ? [] : folders.filter { !$0.name.lowercased().hasPrefix(rest) && $0.label.lowercased().contains(rest) }
            return (starts + inside).flatMap(folder)
        }

        // "@media:" and after: every file, narrowed by name, or by kind ("@media:audio").
        if q.hasPrefix("media:") {
            let rest = String(q.dropFirst("media:".count))
            if let kind = kinds[rest] { return p.assets.filter { $0.kind == kind }.map(file) }
            return files(matching: rest, in: p.assets)
        }

        let selected = p.clips.filter { c in
            model.selection.contains(c.id)
                // A video's own sound selected with it isn't another clip.
                && !(c.kind == .audio && c.linkID != nil && p.clips.contains { $0.linkID == c.linkID && $0.id != c.id && model.selection.contains($0.id) })
        }.count
        // First the one people point with most; always there, greyed out with nothing selected, so
        // people find out it exists.
        var pointers: [MentionOption] = [selected > 0
            ? MentionOption(id: "selected", name: "selected", detail: "\(selected) clip\(selected == 1 ? "" : "s")")
            : MentionOption(id: "selected", name: "selected", detail: "Select clips first", enabled: false)]
        pointers.append(MentionOption(id: "playhead", name: "playhead", detail: clock(model.playhead)))
        if let r = p.playRange {
            pointers.append(MentionOption(id: "in-out", name: "in-out", detail: "\(clock(r.start)) to \(clock(r.end))"))
        }
        if !p.assets.isEmpty {
            let n = p.assets.count
            pointers.append(MentionOption(id: "media", name: "media:", detail: "\(n) file\(n == 1 ? "" : "s")  ›", opensList: true))
        }
        if !folders.isEmpty {
            pointers.append(MentionOption(id: "folder", name: "folder:", detail: "\(folders.count) folder\(folders.count == 1 ? "" : "s")  ›", opensList: true))
        }
        let onTimeline = MagicMention.clipLabels(p).count
        if onTimeline > 0 {
            pointers.append(MentionOption(id: "clip", name: "clip:", detail: "\(onTimeline) on the timeline  ›", opensList: true))
        }
        if !markers.isEmpty {
            pointers.append(MentionOption(id: "marker", name: "marker:", detail: "\(markers.count) on the timeline  ›", opensList: true))
        }
        let shown = pointers.filter { $0.name.hasPrefix(q) }
        // Typed a few letters: markers and files by name straight away too.
        return q.isEmpty ? shown : shown + markers.filter { $0.name.lowercased().hasPrefix(q) }.map(mark) + files(matching: q, in: p.assets)
    }
}

private typealias MediaOption = MentionOption

/// The `@` list under the box: arrows move, Return or Tab picks, a click picks.
private struct MentionList: View {
    let options: [MentionOption]
    let picked: Int
    let pick: (MentionOption) -> Void

    private static let rowHeight = 25.0
    private static let rows = 7

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                rowsView
            }
            .scrollIndicators(options.count > Self.rows ? .visible : .hidden)
            .frame(height: min(Double(options.count), Double(Self.rows) + 0.5) * Self.rowHeight + 6)
            .onChange(of: picked) { _, i in
                if options.indices.contains(i) { scroller.scrollTo(options[i].id) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
    }

    private var rowsView: some View {
        VStack(spacing: 1) {
            ForEach(Array(options.enumerated()), id: \.element.id) { i, option in
                Button { pick(option) } label: {
                    HStack(spacing: 7) {
                        if let tint = option.tint {
                            Circle().fill(Color(hex: tint)).frame(width: 7, height: 7)
                        }
                        Text("@" + option.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(!option.enabled ? Theme.textFaint : i == picked ? Theme.text : Theme.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(option.detail)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(i == picked && option.enabled ? Theme.ink.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!option.enabled)
                .id(option.id)
            }
        }
        .padding(3)
    }
}

/// A small rounded chip that opens a menu.
private struct ChipLabel: View {
    var symbol: String?
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(title).font(.system(size: 11, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
        }
        .foregroundStyle(Theme.chip)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(Theme.ink.opacity(0.07)))
        .contentShape(Capsule())
    }
}

private struct ModelChip: View {
    @ObservedObject var ai: MagicAgent
    let kind: MagicAgent.Kind
    let manage: () -> Void

    var body: some View {
        let options = ai.models(for: kind)
        Menu {
            Picker("Model", selection: Binding(
                get: { ai.model(for: kind) },
                set: { id in
                    // Keep the effort if the new model has it.
                    let e = ai.effort(for: kind)
                    let option = options.first { $0.id == id }
                    ai.setModel(id, effort: option?.efforts.contains(e) == true ? e : option?.defaultEffort ?? e, for: kind)
                })) {
                ForEach(options) { m in
                    Text(m.name).badge(m.blurb.isEmpty ? nil : Text(m.blurb)).tag(m.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ChipLabel(title: ai.modelName(for: kind))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which \(kind.name) model makes the edit")
    }
}

private struct EffortChip: View {
    @ObservedObject var ai: MagicAgent
    let kind: MagicAgent.Kind

    var body: some View {
        let efforts = ai.models(for: kind).first { $0.id == ai.model(for: kind) }?.efforts ?? []
        Menu {
            Picker("Effort", selection: Binding(
                get: { ai.effort(for: kind) },
                set: { ai.setModel(ai.model(for: kind), effort: $0, for: kind) })) {
                ForEach(efforts, id: \.self) { e in
                    let blurb = MagicAgent.effortBlurb(e)
                    Text(MagicAgent.effortName(e)).badge(blurb.isEmpty ? nil : Text(blurb)).tag(e)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ChipLabel(symbol: "gauge.with.dots.needle.33percent", title: MagicAgent.effortName(ai.effort(for: kind)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How hard \(kind.name) thinks: higher is slower and uses more of your plan")
    }
}

/// What the AI said when it finished: what it made, and anything it couldn't do.
struct MagicNoteView: View {
    let note: MagicAgent.Note
    @ObservedObject var model: EditorModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if let agent = note.agent {
                    AppLogo(kind: agent, size: 18)
                } else {
                    // Local runs on Apple Intelligence: Apple's mark, as on its Magic tab.
                    Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        .frame(width: 18, height: 18)
                        .offset(y: -1.5)
                }
                Text(note.agent?.name ?? "Local").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                if !note.detail.isEmpty {
                    Text(note.detail).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
            }
            // AIs write links in Markdown ([CC0](https://…)): shown as links you can click.
            Text((try? AttributedString(markdown: note.text.isEmpty ? "Done." : note.text,
                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(note.text))
                .tint(Color(hex: 0x8AB4FF))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                if note.changed {
                    PillButton(title: "Undo", prominent: false) {
                        close()
                        model.undo()
                    }
                }
                Spacer()
                // Return closes it (given to the pill itself: one put around it doesn't reach its button).
                PillButton(title: "Done", prominent: true, shortcut: .defaultAction, action: close)
            }
        }
        // Space plays and pauses, as it does in the edit, so the result can be watched straight away
        // (the note stays up, Undo with it).
        .background(
            Button("") { model.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
        )
        // esc closes it too, like Done.
        .background(
            Button("", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
        )
        .padding(14)
        .frame(width: 340)
        .background(Theme.panel)
    }
}

/// Local Magic with or without a request: the request is read by Apple's on-device model into a recipe,
/// then Local's own planner makes the edit. With a request, a note says what it did.
@MainActor
enum LocalMagic {
    static func run(_ typedWithMarkers: String, model: EditorModel) {
        // Markers named with @ are read as their times ("from @Jump to @Landing" is "from 0:12 to 0:18").
        let typed = MagicMention.markersAsTimes(typedWithMarkers, project: model.project)
        // What they're pointing at, before Magic locks the window and clears the selection; and the
        // request in plain words for Apple's model ("@selected" reads "the selected clips").
        let pointers = MagicPointers.now(model)
        let media = model.project.assets
        let folders = MagicMention.folderLabels(model.project)
        // Files named with @, and every file in a folder named with @folder:.
        let pointed = Set(MagicMention.find(in: typed, media: media, folders: folders).flatMap { m -> [UUID] in
            switch m.mention {
            case .media(let id): [id]
            case .folder(let path, let only): folders.first { $0.path == path }?.files(for: typed, only: only) ?? []
            default: []
            }
        })
        let request = MagicMention.plain(typed, media: media, clips: MagicMention.clipLabels(model.project), folders: folders)
        let namedFolder = MagicMention.find(in: typed, media: media, folders: folders).contains { if case .folder = $0.mention { return true } else { return false } }
        // No request: Local's own improvement, with the same note at the end (Undo, Done).
        guard !request.isEmpty else {
            let started = Date()
            return MagicShow.start(model: model, fromMouse: false) { said, changed in
                if CommandLine.arguments.contains("--magic-local") { logTitles(model) }
                note(said, changed: changed, detail: ["On this Mac", "\(Int(Date().timeIntervalSince(started).rounded()))s"])
            }
        }
        let state = MagicState.shared
        guard !state.busy, !MagicShow.isRunning else { return }
        state.busy = true
        state.status = "Reading your request"
        // The thinking show (Looking) while Apple's model reads it.
        MagicThinking.begin(model: model, name: "Local", color: NSColor(white: 0.95, alpha: 1))
        let run = MagicShow.runID
        Task {
            // Pauses in the talking: from what's said (heard on this Mac), not from Apple's reading of the request.
            if LocalSpeech.asks(request) {
                state.status = "Listening"
                let p = model.project
                let found = MagicMention.find(in: typed, media: p.assets, clips: MagicMention.clipLabels(p))
                var only = Set(found.compactMap { m -> UUID? in if case .clip(let id) = m.mention { return id } else { return nil } })
                if found.contains(where: { $0.mention == .selected }) || typed.lowercased().contains("selected") { only.formUnion(pointers.selected) }
                // Hear the clips in the edit that aren't heard yet.
                for id in Set(p.clips.filter { $0.kind == .video }.compactMap(\.assetID)) {
                    if let url = model.media.soundURL(id) { _ = await Transcripts.shared.ready(url, limit: 60) }
                    guard run == MagicShow.runID else { return }
                }
                state.busy = false
                state.status = nil
                let outcome = LocalSpeech.plan(project: model.project, only: only.isEmpty ? nil : only) { model.media.transcript($0) }
                if CommandLine.arguments.contains("--magic-local") {
                    FileHandle.standardError.write("MAGIC LOCAL speech: \(outcome.said) (\(outcome.plan?.tasks.count ?? 0) edits)\n".data(using: .utf8)!)
                }
                await perform(outcome, model: model, run: run)
                return
            }
            // A zoom on a shot ("@selected add a zoom", "push in"): before adding clips, so "add" here isn't a new clip.
            if LocalZoom.asks(request) {
                state.busy = false
                state.status = nil
                let outcome = LocalZoom.plan(request: typed, pointers: pointers, project: model.project)
                if CommandLine.arguments.contains("--magic-local") {
                    FileHandle.standardError.write("MAGIC LOCAL zoom: \(outcome.said) (\(outcome.plan?.tasks.count ?? 0) edits)\n".data(using: .utf8)!)
                }
                await perform(outcome, model: model, run: run)
                return
            }
            // More than one thing asked ("add @Beach to the end, add captions and a title"): all of them, in turn.
            let parts = LocalCombined.parts(request, project: model.project)
            if parts.count > 1 {
                let outcome = await LocalCombined.plan(parts, request: request, typed: typed, pointers: pointers, model: model) {
                    state.status = "Listening"
                }
                guard run == MagicShow.runID else { return }
                state.busy = false
                state.status = nil
                if CommandLine.arguments.contains("--magic-local") {
                    FileHandle.standardError.write("MAGIC LOCAL combined \(parts): \(outcome.said) (\(outcome.plan?.tasks.count ?? 0) edits)\n".data(using: .utf8)!)
                }
                await perform(outcome, model: model, run: run)
                return
            }
            // Captions from what's said (heard on this Mac first), or taking them off.
            if LocalCaptions.asks(request, project: model.project) {
                let p = model.project
                if !LocalCaptions.removes(request) {
                    state.status = "Listening"
                    for c in p.clips where LocalCaptions.targets(pointers: pointers, project: p).contains(c.id) {
                        if let id = c.assetID, let url = model.media.soundURL(id) { _ = await Transcripts.shared.ready(url, limit: 60) }
                        guard run == MagicShow.runID else { return }
                    }
                }
                state.busy = false
                state.status = nil
                let outcome = LocalCaptions.plan(request: request, pointers: pointers, project: model.project) { model.media.transcript($0.id) }
                if CommandLine.arguments.contains("--magic-local") {
                    FileHandle.standardError.write("MAGIC LOCAL captions: \(outcome.said) (\(outcome.plan?.tasks.count ?? 0) edits)\n".data(using: .utf8)!)
                }
                await perform(outcome, model: model, run: run)
                return
            }
            // Clips added to the edit that's there: at the end, or the start.
            if LocalAdd.asks(request, project: model.project) {
                state.busy = false
                state.status = nil
                let outcome = LocalAdd.plan(request: request, typed: typed, pointers: pointers, project: model.project)
                if CommandLine.arguments.contains("--magic-local") {
                    FileHandle.standardError.write("MAGIC LOCAL add: \(outcome.said) (\(outcome.plan?.tasks.count ?? 0) edits)\n".data(using: .utf8)!)
                }
                await perform(outcome, model: model, run: run)
                return
            }
            // A title on the edit that's there: at the start, the end or the playhead, nothing else changed.
            if LocalTitle.asks(request, project: model.project) {
                state.busy = false
                state.status = nil
                let outcome = LocalTitle.plan(request: request, playhead: pointers.playhead, project: model.project)
                if CommandLine.arguments.contains("--magic-local") {
                    FileHandle.standardError.write("MAGIC LOCAL title: \(outcome.said) (\(outcome.plan?.tasks.count ?? 0) edits)\n".data(using: .utf8)!)
                }
                await perform(outcome, model: model, run: run)
                return
            }
            // Speed ramps: a slow-motion moment, or ramping into the cuts.
            if LocalRamp.asks(request) {
                state.busy = false
                state.status = nil
                let outcome = LocalRamp.plan(request: typed, pointers: pointers, project: model.project)
                if CommandLine.arguments.contains("--magic-local") {
                    FileHandle.standardError.write("MAGIC LOCAL ramp: \(outcome.said) (\(outcome.plan?.tasks.count ?? 0) edits)\n".data(using: .utf8)!)
                }
                await perform(outcome, model: model, run: run)
                return
            }
            var recipe: LocalRecipe
            do {
                recipe = try await LocalBrain.recipe(for: request, media: media, pointed: pointed,
                                                     hasEdit: model.project.clips.contains { $0.kind == .video || $0.kind == .image },
                                                     folder: namedFolder,
                                                     shows: { model.media.sceneTags($0) })
                // Stopped while it was reading: nothing to do.
                guard run == MagicShow.runID else { return }
                recipe.speed = LocalBrain.speed(in: request)
                recipe.soundEffects = LocalBrain.wantsSoundEffects(request)
                recipe.askedJudgement = LocalBrain.asksJudgement(request)
                recipe.title = LocalBrain.titleAsked(request)
                recipe.titleAtEnd = LocalTitle.atEnd(request)
                recipe.wholeLibrary = LocalBrain.wantsLibrary(request)
                recipe.shots = LocalBrain.shotCount(request)
                recipe.every = LocalBrain.wantsEvery(request)
                if recipe.every { recipe.wholeLibrary = true }
                if recipe.title != nil {
                    // A title is handled now, so it isn't something it couldn't do.
                    recipe.cannotDo = recipe.cannotDo.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { p in !["title", "text", "caption", "heading", "name"].contains { p.lowercased().contains($0) } }.joined(separator: ", ")
                }
                if LocalCaptions.wantedWithCut(request) {
                    // Captions are added once the cut is made, so they aren't something it couldn't do.
                    recipe.cannotDo = recipe.cannotDo.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { p in !["caption", "subtitle"].contains { p.lowercased().contains($0) } }.joined(separator: ", ")
                }
                if LocalBrain.wantsLevels(request) {
                    recipe.levelAudio = true
                    // Every audio clip on a track that's on, measured now, so they all read the same on the output meters.
                    let clips = model.project.clips.filter { c in
                        c.kind == .audio && !model.project.isLocked(c.trackID) && (model.project.track(c.trackID)?.muted != true)
                    }
                    recipe.levelGains = model.levelGains(of: clips, matchOutput: true)
                    recipe.levelSilent = Array(Set(clips.filter { recipe.levelGains[$0.id] == nil }
                        .compactMap { model.project.asset($0.assetID ?? UUID())?.name })).sorted()
                    if CommandLine.arguments.contains("--magic-local") {
                        let said = clips.map { c in
                            let name = model.project.asset(c.assetID ?? UUID())?.name ?? "?"
                            let level = AudioLevels.envelopeDB(c, media: model.media).map { String(format: "%.1f", $0) } ?? "none"
                            let peak = AudioLevels.peakDB(c, media: model.media).map { String(format: "%.1f", $0) } ?? "none"
                            return "\(name)@\(String(format: "%.1f", c.start)) level \(level) peak \(peak) gain \(c.gainDB) -> \(recipe.levelGains[c.id].map { String(format: "%.1f", $0) } ?? "-")"
                        }
                        FileHandle.standardError.write("MAGIC LEVELS \(said.joined(separator: "; "))\n".data(using: .utf8)!)
                    }
                    // Levels are handled now, so they aren't something it couldn't do.
                    recipe.cannotDo = recipe.cannotDo.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { p in !["level", "volume", "loud", "equaliz", "equalis", "normaliz", "normalis", "balance", "db", "gain", "audio"]
                            .contains { p.lowercased().contains($0) } }.joined(separator: ", ")
                }
                if recipe.soundEffects {
                    // Sound effects are handled now, so they aren't something it couldn't do.
                    recipe.cannotDo = recipe.cannotDo.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { p in !["sound", "sfx", "effect", "whoosh"].contains { p.lowercased().contains($0) } }.joined(separator: ", ")
                }
                if recipe.speed != nil {
                    // Speed is handled now, so it isn't something it couldn't do.
                    recipe.cannotDo = recipe.cannotDo.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { p in !["speed", "fast", "slow", "%"].contains { p.lowercased().contains($0) } }.joined(separator: ", ")
                }
                // Asked for something specific: do just that, not the general clean-up as well.
                recipe.onlyAsked = !LocalBrain.isGeneral(request)
            } catch {
                guard run == MagicShow.runID else { return }
                state.busy = false
                state.status = nil
                MagicThinking.current?.end()
                let a = EditroomAlert()
                a.messageText = "Local couldn't read that"
                a.informativeText = (error as? LocalBrain.Failure)?.message ?? error.localizedDescription
                a.runModal()
                return
            }
            if CommandLine.arguments.contains("--magic") || CommandLine.arguments.contains("--magic-local") {
                FileHandle.standardError.write("MAGIC LOCAL \"\(request)\" -> \(recipe.summary.isEmpty ? "no settings" : recipe.summary)\(recipe.cannotDo.isEmpty ? "" : " | can't: " + recipe.cannotDo)\n".data(using: .utf8)!)
            }
            state.busy = false
            state.status = nil
            // About the selected clips, the playhead or the in/out range: just that, directly.
            if let pointedEdit = LocalPointed.plan(request: typed, recipe: recipe, pointers: pointers, project: model.project) {
                if CommandLine.arguments.contains("--magic-local") {
                    FileHandle.standardError.write("MAGIC LOCAL pointed: \(pointedEdit.said) (\(pointedEdit.plan?.tasks.count ?? 0) edits)\n".data(using: .utf8)!)
                }
                guard let plan = pointedEdit.plan, !plan.tasks.isEmpty else {
                    MagicThinking.current?.end()
                    MagicAgent.shared.note = MagicAgent.Note(agent: nil, text: pointedEdit.said, changed: false, detail: "On this Mac")
                    return
                }
                let started = Date()
                if let thinking = MagicThinking.current {
                    MagicShow.fit(model: model, plan: plan)
                    var final = plan.base
                    for task in plan.tasks { task.edit.apply(&final, 1) }
                    thinking.plan(final)
                    let hold = min(2.0, max(0.8, thinking.secondsUntilDrawn + 0.35))
                    try? await Task.sleep(nanoseconds: UInt64(hold * 1e9))
                    guard run == MagicShow.runID else { return }
                    thinking.handOver()
                }
                let played = MagicShow.play(model: model, plan: plan) {
                    if CommandLine.arguments.contains("--magic-local") {
                        FileHandle.standardError.write("MAGIC LOCAL said: \(pointedEdit.said)\n".data(using: .utf8)!)
                    }
                    note(pointedEdit.said, changed: true, detail: ["On this Mac", "\(Int(Date().timeIntervalSince(started).rounded()))s"])
                }
                if !played {
                    model.mutate { q in for task in plan.tasks { task.edit.apply(&q, 1) } }
                    note(pointedEdit.said, changed: true, detail: ["On this Mac"])
                }
                return
            }
            // Nothing in it Local can do (and it isn't just "make it better"): say so, edit nothing.
            if recipe.isEmpty, !LocalBrain.isGeneral(request) {
                MagicThinking.current?.end()
                let what = recipe.cannotDo.isEmpty ? "that" : recipe.cannotDo
                // A question (not about the edit): Local only edits, so it says so and leaves the edit alone.
                let question = request.contains("?") && recipe.cannotDo.isEmpty
                MagicAgent.shared.note = MagicAgent.Note(agent: nil, text: question ? """
                    Local only edits your video, so it left it as it was. To ask a question, use Claude or ChatGPT.
                    """ : """
                    Local can't do \(what). It can change the length, the pace, the look, the music, the frame shape \
                    (vertical, square), and which files to use or take out, by name. For anything that needs \
                    understanding what's in your shots, use Claude or ChatGPT.
                    """, changed: false, detail: "On this Mac")
                if CommandLine.arguments.contains("--magic-local") {
                    FileHandle.standardError.write("MAGIC LOCAL said: (nothing done) \(what)\n".data(using: .utf8)!)
                }
                return
            }
            let started = Date()
            let captions = LocalCaptions.wantedWithCut(request)
            MagicShow.start(model: model, fromMouse: false, recipe: recipe) { said, changed in
                // Captions asked for with the cut: put on the cut once it's made.
                Task { @MainActor in
                    var said = said
                    if captions, changed {
                        state.status = "Listening"
                        said += (said.isEmpty ? "" : " ") + (await LocalCaptions.addToCut(model: model))
                        state.status = nil
                    }
                    if CommandLine.arguments.contains("--magic-local") {
                        FileHandle.standardError.write("MAGIC LOCAL said: \(said)\n".data(using: .utf8)!)
                        logTitles(model)
                        FileHandle.standardError.write("MAGIC LOCAL captions \(model.captionBlocks.count)\n".data(using: .utf8)!)
                    }
                    note(said, changed: changed, detail: ["On this Mac", "\(Int(Date().timeIntervalSince(started).rounded()))s"])
                }
            }
        }
    }

    /// Plays a ready-made Local edit with the thinking show's sketch and the swarm, then its note; or just
    /// the note, when there's nothing to change.
    private static func perform(_ outcome: LocalPointed.Outcome, model: EditorModel, run: Int) async {
        guard let plan = outcome.plan, !plan.tasks.isEmpty else {
            MagicThinking.current?.end()
            MagicAgent.shared.note = MagicAgent.Note(agent: nil, text: outcome.said, changed: false, detail: "On this Mac")
            return
        }
        let started = Date()
        if let thinking = MagicThinking.current {
            MagicShow.fit(model: model, plan: plan)
            var final = plan.base
            for task in plan.tasks { task.edit.apply(&final, 1) }
            thinking.plan(final)
            let hold = min(2.0, max(0.8, thinking.secondsUntilDrawn + 0.35))
            try? await Task.sleep(nanoseconds: UInt64(hold * 1e9))
            guard run == MagicShow.runID else { return }
            thinking.handOver()
        }
        let played = MagicShow.play(model: model, plan: plan) {
            if CommandLine.arguments.contains("--magic-local") {
                FileHandle.standardError.write("MAGIC LOCAL said: \(outcome.said)\n".data(using: .utf8)!)
                logTitles(model)
            }
            note(outcome.said, changed: true, detail: ["On this Mac", "\(Int(Date().timeIntervalSince(started).rounded()))s"])
        }
        if !played {
            model.mutate { q in for task in plan.tasks { task.edit.apply(&q, 1) } }
            note(outcome.said, changed: true, detail: ["On this Mac"])
        }
    }

    /// (Testing) Where the titles are, next to the edit.
    private static func logTitles(_ model: EditorModel) {
        let p = model.project
        let edit = p.clips.filter { $0.kind == .video || $0.kind == .image }
        for t in p.clips where t.kind == .text {
            FileHandle.standardError.write(String(format: "MAGIC LOCAL title \"%@\" %.2f-%.2f (edit %.2f-%.2f)\n", t.text.string,
                t.start, t.end, edit.map(\.start).min() ?? 0, edit.map(\.end).max() ?? 0).data(using: .utf8)!)
        }
    }

    /// The note on the Magic button once it's done: what it did, with Undo and Done.
    private static func note(_ said: String, changed: Bool, detail: [String]) {
        if CommandLine.arguments.contains("--magic") {
            FileHandle.standardError.write("MAGIC NOTE \(changed ? "changed" : "unchanged"): \(said)\n".data(using: .utf8)!)
        }
        MagicAgent.shared.note = MagicAgent.Note(agent: nil, text: said, changed: changed,
                                                detail: detail.filter { !$0.isEmpty }.joined(separator: " · "))
    }
}


/// The history menu's prompts, as menu items look (wrapped to two lines, the AI's badge on the right,
/// highlighted under the pointer), in a list as tall as `rows` of them that scrolls to the rest.
private final class HistoryList: NSView {
    private let scroll = NSScrollView()

    init(entries: [MagicHistory.Entry], rows: Int, pick: @escaping (String) -> Void) {
        let width: CGFloat = 330
        let doc = FlippedDoc()
        var y: CGFloat = 0
        var heights: [CGFloat] = []
        for e in entries {
            let row = HistoryRow(entry: e, width: width, pick: pick)
            row.frame.origin = CGPoint(x: 0, y: y)
            doc.addSubview(row)
            y += row.frame.height
            heights.append(row.frame.height)
        }
        doc.frame = CGRect(x: 0, y: 0, width: width, height: y)
        let visible = heights.prefix(rows).reduce(0, +)
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: visible))
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = entries.count > rows
        scroll.scrollerStyle = .overlay
        scroll.documentView = doc
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    private final class FlippedDoc: NSView {
        override var isFlipped: Bool { true }
    }
}

private final class HistoryRow: NSView {
    private let text = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let entry: MagicHistory.Entry
    private let pick: (String) -> Void
    private var lit = false { didSet { needsDisplay = true; recolor() } }

    init(entry: MagicHistory.Entry, width: CGFloat, pick: @escaping (String) -> Void) {
        self.entry = entry
        self.pick = pick
        let font = NSFont.menuFont(ofSize: 0)
        text.stringValue = HistoryMenu.wrapped(entry.text)
        text.font = font
        text.maximumNumberOfLines = 2
        let lines = CGFloat(text.stringValue.split(separator: "\n").count)
        let height = ceil(font.boundingRectForFont.height * lines) + 8
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: height))
        badge.stringValue = MagicAgent.Tab(rawValue: entry.tab)?.name ?? ""
        badge.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .center
        badge.sizeToFit()
        let bw = badge.frame.width + 14, bh: CGFloat = 18
        let holder = NSView(frame: CGRect(x: width - 14 - bw, y: (height - bh) / 2, width: bw, height: bh))
        holder.wantsLayer = true
        holder.layer?.cornerRadius = bh / 2
        holder.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        badge.frame = CGRect(x: 0, y: (bh - badge.frame.height) / 2, width: bw, height: badge.frame.height)
        holder.addSubview(badge)
        addSubview(holder)
        text.frame = CGRect(x: 14, y: 4, width: holder.frame.minX - 22, height: height - 8)
        addSubview(text)
        toolTip = entry.text
        recolor()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func recolor() {
        text.textColor = lit ? .selectedMenuItemTextColor : .labelColor
        badge.textColor = lit ? .selectedMenuItemTextColor : .secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard lit else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
    }

    override func mouseEntered(with event: NSEvent) { lit = true }
    override func mouseExited(with event: NSEvent) { lit = false }
    override func mouseUp(with event: NSEvent) { pick(entry.text) }
}
