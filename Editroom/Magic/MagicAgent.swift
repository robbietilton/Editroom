import AppKit
import Foundation

/// Magic with an AI: Claude (through Claude Code), ChatGPT (through Codex, which the ChatGPT app
/// ships) or OpenCode works out the edit in the background on a hidden draft of the project, using
/// Editroom's agent tools and the person's own AI account. Nothing moves while it thinks; when it's
/// done, the Magic swarm plays its edits onto the timeline as one undo step.
@MainActor
final class MagicAgent: ObservableObject {
    static let shared = MagicAgent()

    enum Kind: String, CaseIterable, Identifiable {
        case claude, chatgpt, opencode
        var id: String { rawValue }
        var name: String {
            switch self {
            case .claude: "Claude"
            case .chatgpt: "ChatGPT"
            case .opencode: "OpenCode"
            }
        }
    }

    /// The Magic popover's tabs: an AI, or the built-in cut on this Mac.
    enum Tab: String, CaseIterable, Identifiable {
        case claude, chatgpt, opencode, local
        var id: String { rawValue }
        var kind: Kind? {
            switch self {
            case .claude: .claude
            case .chatgpt: .chatgpt
            case .opencode: .opencode
            case .local: nil
            }
        }
        var name: String { kind?.name ?? "Local" }
    }

    /// What an AI said when it finished, shown under the Magic button.
    struct Note: Identifiable {
        let id = UUID()
        /// Who made the edit: Claude, ChatGPT or OpenCode, or nil for Local.
        let agent: Kind?
        let text: String
        /// It changed the timeline (so there's something to undo).
        let changed: Bool
        /// "Opus 5.5 · Low · 54s"
        var detail = ""
    }

    @Published private(set) var running = false
    @Published private(set) var agent: Kind?
    /// What the AI is doing, for the Magic button.
    @Published private(set) var status: String?
    @Published var note: Note?
    /// The Magic button's "what should it make?" popover is open.
    @Published var asking = false
    /// Finished while the person was in another app: shown on the button until they come back.
    @Published private(set) var ready: String?
    /// The popover's tab, remembered.
    /// The prompt being typed in the Magic box, kept while it's closed and cleared when it's sent.
    @Published var prompt = ""
    @Published var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "magicTab") ?? "") ?? .claude {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "magicTab") }
    }
    /// The model and effort of the run in progress, for its note.
    private var runDetail = ""
    private var lastSeconds = 0.0

    private var process: Process?
    private var stopped = false
    private var pending = Data()
    private var errorText = Data()
    private var draft: MCPDraft?
    private weak var model: EditorModel?
    private var started = Date()
    /// From the AI's output: its last words, and whether it said it failed.
    private var lastMessage = ""
    private var failure: String?
    private var startedServer = false
    private var openCodeCalls = Set<String>()
    private var openCodeAssistantMessages = Set<String>()
    @Published private(set) var openCodeModels: [ModelOption] = []
    @Published private(set) var loadingOpenCodeModels = false
    @Published private(set) var openCodeModelError: String?
    private var loadedOpenCodeModels = false

    /// The AIs on this Mac that Magic can use.
    /// Only the AIs connected in AI Agents (and only while AI Agents is on): Claude through the Claude
    /// app or Claude Code, ChatGPT through Codex, or OpenCode.
    var available: [Kind] { Kind.allCases.filter { connected($0) && runnable($0) } }

    /// Connected in AI Agents (or from the Magic popover), with AI Agents on.
    func connected(_ kind: Kind) -> Bool {
        let c = AgentConnect.shared
        guard MCPServer.shared.enabled else { return false }
        switch kind {
        case .claude: return c.states[.claude] == .connected || c.states[.claudeCode] == .connected
        case .chatgpt: return c.states[.chatgpt] == .connected
        case .opencode: return c.states[.opencode] == .connected
        }
    }

    /// The program Magic runs is on this Mac: Claude Code, Codex, or OpenCode.
    func runnable(_ kind: Kind) -> Bool {
        switch kind {
        case .claude: AgentConnect.shared.claudeCLI != nil
        case .chatgpt: AgentConnect.shared.codexCLI != nil
        case .opencode: AgentConnect.shared.openCodeCLI != nil
        }
    }

    /// The app (or its program) is on this Mac at all.
    func installed(_ kind: Kind) -> Bool {
        switch kind {
        case .claude: return AgentConnect.appURL(AgentConnect.claudeBundleID) != nil || AgentConnect.shared.claudeCLI != nil
        case .chatgpt: return AgentConnect.chatgptBundleIDs.contains { AgentConnect.appURL($0) != nil } || AgentConnect.shared.codexCLI != nil
        case .opencode: return AgentConnect.shared.openCodeCLI != nil
        }
    }

    // MARK: Model and effort

    struct ModelOption: Identifiable, Hashable {
        /// What the program is given.
        let id: String
        let name: String
        var blurb = ""
        let efforts: [String]
        var defaultEffort = "medium"
    }

    static func effortName(_ e: String) -> String {
        switch e {
        case "xhigh": "Extra high"
        default: e.prefix(1).uppercased() + e.dropFirst()
        }
    }

    static func effortBlurb(_ e: String) -> String {
        switch e {
        case "low": "Quickest"
        case "max": "Slowest"
        default: ""
        }
    }

    /// The models each AI offers. ChatGPT's come from Codex's own list on this Mac.
    func models(for kind: Kind) -> [ModelOption] {
        switch kind {
        case .claude:
            let efforts = ["low", "medium", "high", "xhigh", "max"]
            return [
                ("claude-opus-5-5", "Opus 5.5", "Best edits"), ("claude-sonnet-5-5", "Sonnet 5.5", "Fast"),
                ("claude-haiku-5-5", "Haiku 5.5", "Fastest"), ("claude-fable-5-2", "Fable 5.2", "Most capable"),
            ].map { ModelOption(id: $0.0, name: $0.1, blurb: $0.2, efforts: efforts) }
        case .chatgpt:
            // Just these, in this order. Names and efforts come from Codex's own list when it has them.
            let picks = [("gpt-6.2-sol", "GPT-6.2-Sol"), ("gpt-6.2-astra", "GPT-6.2-Astra"),
                         ("gpt-6.1-terra", "GPT-6.1-Terra"), ("gpt-6-luna", "GPT-6-Luna")]
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
            var known: [String: [String: Any]] = [:]
            if let data = try? Data(contentsOf: file),
               let models = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] {
                for m in models { if let slug = m["slug"] as? String { known[slug] = m } }
            }
            return picks.compactMap { slug, name in
                let m = known[slug]
                // Not listed by Codex on this Mac: this plan doesn't offer it.
                if !known.isEmpty, m == nil { return nil }
                // Not "ultra": it hands parts of the job to more agents, which costs much more.
                let efforts = (m?["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String }.filter { $0 != "ultra" }
                return ModelOption(id: slug, name: name, efforts: efforts ?? ["low", "medium", "high", "xhigh"],
                                   defaultEffort: m?["default_reasoning_level"] as? String ?? "medium")
            }
        case .opencode:
            loadOpenCodeModels()
            if !openCodeModels.isEmpty { return openCodeModels }
            let title = loadingOpenCodeModels ? "Loading models…" : openCodeModelError == nil ? "OpenCode default" : "Model unavailable"
            return [ModelOption(id: "", name: title, efforts: [], defaultEffort: "")]
        }
    }

    /// OpenCode's own available-model list, with its configured default first. Loaded off the main thread.
    func loadOpenCodeModels() {
        guard !loadedOpenCodeModels, !loadingOpenCodeModels, let cli = AgentConnect.shared.openCodeCLI else { return }
        loadingOpenCodeModels = true
        openCodeModelError = nil
        Task {
            let out = await run(cli, ["models"], timeout: 12)
            let options = Self.openCodeModelOptions(output: out, preferred: AgentConnect.shared.openCodeModel)
            if options.isEmpty {
                // Stop automatic retries; the menu offers an explicit Refresh Models action.
                loadedOpenCodeModels = true
                openCodeModelError = "Couldn't load models. Check OpenCode, then refresh."
            } else {
                openCodeModels = options
                loadedOpenCodeModels = true
            }
            loadingOpenCodeModels = false
        }
    }

    func refreshOpenCodeModels() {
        guard !loadingOpenCodeModels else { return }
        loadedOpenCodeModels = false
        openCodeModelError = nil
        loadOpenCodeModels()
    }

    static func openCodeModelOptions(output: String, preferred: String?) -> [ModelOption] {
        var seen = Set<String>()
        let ids = output.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { id in
            let parts = id.split(separator: "/", maxSplits: 1)
            return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && !id.contains(" ") && seen.insert(id).inserted
        }
        var options = ids.map { id -> ModelOption in
            let parts = id.split(separator: "/", maxSplits: 1)
            let provider = String(parts[0])
            let model = String(parts[1])
            let name = model.prefix(1).uppercased() + model.dropFirst()
            return ModelOption(id: id, name: name, blurb: provider, efforts: [], defaultEffort: "")
        }
        guard !options.isEmpty else { return [] }
        if let preferred {
            if !options.contains(where: { $0.id == preferred }) {
                let model = preferred.split(separator: "/").last.map(String.init) ?? preferred
                options.insert(ModelOption(id: preferred, name: model.prefix(1).uppercased() + model.dropFirst(),
                                           blurb: "Configured default", efforts: [], defaultEffort: ""), at: 0)
            } else if let index = options.firstIndex(where: { $0.id == preferred }) {
                options.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
            }
        } else {
            options.insert(ModelOption(id: "", name: "OpenCode default", blurb: "Configured in OpenCode",
                                       efforts: [], defaultEffort: ""), at: 0)
        }
        return options
    }

    /// The chosen model: the one picked last time if it's still offered, or the first.
    func model(for kind: Kind) -> String {
        let options = models(for: kind)
        let saved = UserDefaults.standard.string(forKey: "magicModel.\(kind.rawValue)") ?? ""
        return options.contains { $0.id == saved } ? saved : options.first?.id ?? ""
    }

    func effort(for kind: Kind) -> String {
        let option = models(for: kind).first { $0.id == model(for: kind) }
        let saved = UserDefaults.standard.string(forKey: "magicEffort.\(kind.rawValue)") ?? ""
        if let option, option.efforts.contains(saved) { return saved }
        return option?.defaultEffort ?? ""
    }

    func modelName(for kind: Kind) -> String {
        let id = model(for: kind)
        return models(for: kind).first { $0.id == id }?.name ?? (id.isEmpty ? "Default" : id)
    }

    func setModel(_ id: String, effort: String, for kind: Kind) {
        objectWillChange.send()
        UserDefaults.standard.set(id, forKey: "magicModel.\(kind.rawValue)")
        UserDefaults.standard.set(effort, forKey: "magicEffort.\(kind.rawValue)")
    }

    /// "Opus 5.5 · Low"
    func modelLabel(for kind: Kind) -> String {
        let e = effort(for: kind)
        return e.isEmpty ? modelName(for: kind) : "\(modelName(for: kind)) · \(Self.effortName(e))"
    }

    /// The AI the popover's tab is on, if it's ready to use.
    var choice: Kind? { tab.kind.flatMap { available.contains($0) ? $0 : nil } }

    // MARK: The brief

    static func brief(request: String, project p: Project, pointers: MagicPointers? = nil) -> String {
        let ask = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let onTimeline = p.clips.filter { $0.kind != .audio }
        let hasEdit = !onTimeline.isEmpty
        var lines: [String] = []
        lines.append("""
        You're the editor in Editroom, the video editor open on this Mac. Use only the editroom tools, and don't stop \
        to ask anything: nobody can answer until you've finished. If what they wrote isn't about the video (a \
        question, a chat), just answer it in a sentence or two: don't look at the media or change anything.
        """)
        if ask.isEmpty {
            lines.append(hasEdit
                ? "They didn't ask for anything in particular: make the edit on the timeline better, the way a skilled editor would."
                : "They didn't ask for anything in particular: make the best short video you can from the library, the way a skilled editor would cut it to share.")
        } else {
            lines.append("What they asked for: \"\(ask)\"")
        }
        if let pointers, let said = pointing(pointers, request: ask, project: p) { lines.append(said) }
        if hasEdit {
            lines.append(String(format: """
            The timeline already has an edit (%d clips, about %.0f seconds). Work on that edit: change it to do what they \
            asked, and keep what already works. Don't delete it and start again unless they asked for something new.
            """, onTimeline.count, p.duration))
        } else {
            lines.append("The timeline is empty: build the video from the library.")
        }
        lines.append("""
        Use what's in the library (list_media) and Editroom's own titles, transitions, colour and sound levels. \
        The one thing you can add is music or sound you find online, with download_media (see below). If what \
        they asked for needs something else the library doesn't have (a logo, more footage), do the best you can \
        without it, and say what was missing at the end.

        Finding music or sound: only when they ask for it, or the edit clearly needs music and the library has \
        none. Search the web for tracks that are royalty-free and need no attribution (for example CC0, or a \
        site licence that says no credit is required), and read the licence to make sure. Choose one that suits \
        the footage's mood and pace. Then download_media the direct link to the audio file (not the web page), \
        with the page you found it on and what the licence says, and use it like any other music. Never take \
        music from a place that doesn't clearly allow it. At the end, name the track, where it's from and its \
        licence.

        Your edits go into a draft that the person sees all at once, played onto their timeline, when you finish. \
        So take the time to get it right; if a step goes wrong, history undoes it.

        How to work:
        1. get_project and list_media.
        2. list_media says what each clip "shows" (seen on this Mac): a quick guide to find shots by what's in \
        them, and search_media finds shots by what they show or what's said in them, with times. Look at the footage with look_at_media to see what's in each shot, then save what you saw with note_media. A clip whose list_media "notes" already say what's in it needn't be looked at again unless you need an exact frame. If people talk in it (list_media \
        says "speech"), get_transcript gives what's said with times: cut pauses, retakes and filler between \
        sentences, keep sentences whole, and put other shots over the talking where it helps. For captions or subtitles, use \
        set_captions, never add_title: it captions what's said, timed to the speech, and keeps up with every later edit; its \
        edit option fixes a misheard word or takes a caption out. analyze_media finds a clip's best \
        moments, or a song's tempo and bar starts.
        3. Choose. Leave out shots that are blurry, dark, shaky, accidental, near-duplicates of a better one, or \
        screenshots. Find an order that tells something: an opening that sets the scene, a build, the best moments, \
        and a shot that feels like an ending. Prefer moments where something happens, faces and expressions, and \
        variety of framing.
        4. Cut. Shots on V1 back to back with no gaps, using source_start and duration (or trim_clip) to keep just \
        the best part of each. With music: the song on A1 from 0, cut on bar starts or beats, shorter shots where \
        the music is busy and longer where it's calm, end on a bar start, and turn the clips' own sound down to \
        about -20 dB unless someone is talking and it matters. Without music: keep the clips' sound and cut where \
        the action or sound makes a natural break. If most of the footage is vertical and the timeline is empty, \
        set_sequence to 1080 by 1920 first.
        5. To make an edit shorter or keep people watching: open on the strongest moment, cut the slow starts and \
        ends of shots, drop weak or repeated shots, and close every gap (delete_clips with ripple, or move clips).
        6. Speed: set_speed speeds a clip up (4 to 20 times for a timelapse) or slows it down. Turn a sped-up \
        clip's own sound right down (set_audio gain_db -60) unless they asked to keep it. set_speed_ramp eases \
        the speed within a clip: a slow-motion moment on the best part of an action (look at the frames to find \
        it), fast-normal-fast on travel shots, or ramping up into a cut and down out of it on the next shot. \
        Use ramps when asked, or sparingly where they make the moment. set_transform's zoom pushes in on a \
        moment or follows the action in a screen recording (focus_x and focus_y say where to look): use it \
        when asked, or sparingly. For a long video like a \
        vlog, keep what people say whole, and use short titles to mark each part.
        7. Finish. Colour only when they asked for it, or when the footage clearly needs it (look at the frames): \
        shots from different cameras or light that don't match, or shots too dark or washed out. Then one look \
        from list_looks, or small set_grade fixes, on every shot so it feels like one film. Otherwise leave colour \
        as it is, and on an existing edit don't change colour unless they asked. set_transform reframes a shot \
        (to keep a subject in a vertical frame); set_title_style sets a title's font, size, colour and place. \
        Markers (set_marker), the in/out range, freeze frames, reversing, detaching sound, track switches and \
        solids only when they ask for them. Titles and text only when \
        they asked for them, or the kind of video needs them (a vlog's parts); most videos don't. Fade music out over the last 2 seconds. A dissolve or dip to black only where it helps, never on \
        every cut.
        8. Check a few moments with get_frame and fix what's wrong.

        When you're done, write one or two short sentences for the person: what you made or changed, and anything \
        you couldn't do and why. Plain words, no lists, no ids.
        """)
        return lines.joined(separator: "\n\n")
    }

    /// Where they were pointing when they asked (the playhead, the selection, the in/out range), and what
    /// each @ in the request means. Used only when their words point at it.
    static func pointing(_ ptr: MagicPointers, request: String, project p: Project) -> String? {
        let labels = MagicMention.clipLabels(p)
        let marks = MagicMention.markerLabels(p)
        let mentions = MagicMention.find(in: request, media: p.assets, clips: labels, markers: marks)
        guard !p.clips.isEmpty || !mentions.isEmpty else { return nil }
        func t(_ s: Double) -> String { String(format: "%.2fs", s) }
        func track(_ c: Clip) -> String {
            if let i = p.videoTracks.firstIndex(where: { $0.id == c.trackID }) { return "V\(i + 1)" }
            return "A\((p.audioTracks.firstIndex { $0.id == c.trackID } ?? 0) + 1)"
        }
        func clip(_ c: Clip) -> String { "\"\(p.name(of: c))\" on \(track(c)) \(t(c.start))-\(t(c.end)) (id \(c.id.uuidString))" }
        var where_: [String] = []
        if !p.clips.isEmpty {
            let under = p.clips.filter { $0.start <= ptr.playhead + 1e-6 && ptr.playhead < $0.end - 1e-6 && $0.kind != .audio }
                .sorted { p.trackOrder($0.trackID) < p.trackOrder($1.trackID) }
            where_.append("- Playhead: \(t(ptr.playhead))" + (under.isEmpty ? "" : ", over " + under.map(clip).joined(separator: "; ")))
            let sel = ptr.selected.compactMap { id in p.clips.first { $0.id == id } }
            where_.append("- Selected: " + (sel.isEmpty ? "nothing" : "\(sel.count) clip\(sel.count == 1 ? "" : "s"): " + sel.map(clip).joined(separator: "; ")))
            where_.append("- In/out range: " + (ptr.range.map { "\(t($0.start)) to \(t($0.end))" } ?? "none"))
        }
        var meant: [String] = []
        for m in Set(mentions.map(\.mention)) {
            switch m {
            case .playhead: meant.append("@playhead means the playhead above.")
            case .selected: meant.append(ptr.selected.isEmpty ? "@selected: nothing was selected, so do the best you can from the rest of what they said."
                                                               : "@selected means exactly the selected clips above, no others.")
            case .range: meant.append(ptr.range == nil ? "@in-out: no in/out range was set, so do the best you can from the rest of what they said."
                                                        : "@in-out means the in/out range above.")
            case .media(let id):
                if let a = p.assets.first(where: { $0.id == id }) { meant.append("@\(a.name) means the library file \(a.name) (asset_id \(a.id.uuidString)).") }
            case .clip(let id):
                if let c = p.clips.first(where: { $0.id == id }), let l = labels.first(where: { $0.id == id }) {
                    meant.append("@clip:\(l.name) means exactly one clip on the timeline: \(clip(c)).")
                }
            case .marker(let id):
                if let l = marks.first(where: { $0.id == id }) {
                    meant.append("@\(l.name) (or @marker:\(l.name)) means the marker \"\(l.name)\" at \(t(l.time)) on the timeline.")
                }
            }
        }
        var out = ""
        if !where_.isEmpty {
            out = "Where they were in the editor when they asked:\n" + where_.joined(separator: "\n") + "\n"
        }
        if !meant.isEmpty {
            out += "They pointed with @: " + meant.sorted().joined(separator: " ") + " Act on exactly what they pointed at.\n"
        }
        // Times they typed, in timeline seconds, with what's there (the viewer's timecode ends in frames).
        var timed: [String] = []
        let request = MagicMention.markersAsTimes(request, project: p)
        let span = MagicTimes.span(in: request, fps: p.fps)
        if let span {
            let over = p.clips.filter { $0.kind != .audio && $0.start < span.end - 1e-6 && $0.end > span.start + 1e-6 }
                .sorted { ($0.start, p.trackOrder($0.trackID)) < ($1.start, p.trackOrder($1.trackID)) }
            timed.append("\"\(span.text)\" is \(t(span.start)) to \(t(span.end)) on the timeline" + (over.isEmpty ? "" : ", over " + over.map(clip).joined(separator: "; ")) + ".")
        }
        for typed in MagicTimes.times(in: request, fps: p.fps) where !typed.unitOnly {
            if let span, span.text.contains(typed.text) { continue }
            let under = p.clips.filter { $0.kind != .audio && $0.start <= typed.seconds + 1e-6 && typed.seconds < $0.end - 1e-6 }
                .sorted { p.trackOrder($0.trackID) < p.trackOrder($1.trackID) }
            timed.append("\"\(typed.text)\" is \(t(typed.seconds)) (if it's a place on the timeline" + (under.isEmpty ? "" : ", over " + under.map(clip).joined(separator: "; ")) + "; it may be a length instead).")
        }
        if !timed.isEmpty {
            out += "Times in their request: " + timed.joined(separator: " ") + "\n"
        }
        if !where_.isEmpty {
            out += """
            Use the playhead, selection and range only when their words point at them ("here", "this clip", \
            "these", "this spot", "from here on", or an @). Otherwise the request is about the whole edit, \
            whatever happens to be selected.
            """
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Running

    func start(request: String, with kind: Kind, model: EditorModel) {
        guard !running, !MagicShow.isRunning else { return }
        // Disconnected in AI Agents means Magic doesn't use it either.
        AgentConnect.shared.refresh()
        guard available.contains(kind) else {
            log("MAGIC AI \(kind.rawValue) isn't connected")
            return
        }
        let cli: URL?
        switch kind {
        case .claude: cli = AgentConnect.shared.claudeCLI
        case .chatgpt: cli = AgentConnect.shared.codexCLI
        case .opencode: cli = AgentConnect.shared.openCodeCLI
        }
        guard let cli else { return }
        self.model = model
        // What they're pointing at, before Magic locks the window and clears the selection.
        let pointers = MagicPointers.now(model)
        // Nothing plays while the AI works out the edit.
        model.pause()
        stopped = false
        running = true
        agent = kind
        note = nil
        status = "\(kind.name) is starting"
        started = Date()
        runDetail = modelLabel(for: kind)
        log("MAGIC AI \(kind.rawValue) request \"\(request)\"")
        Task {
            guard await serverReady() else {
                alert("Couldn't start Magic", "Editroom couldn't open its connection for \(kind.name).")
                return done()
            }
            guard await signIn(kind, cli) else { return done() }
            guard !stopped, let endpoint = MCPServer.shared.localEndpoint else { return done() }
            let major: Int
            if kind == .opencode {
                do { major = try await AgentConnect.shared.openCodeMajorVersion(cli) }
                catch {
                    alert("Couldn't start OpenCode", error.localizedDescription)
                    return done()
                }
            } else {
                major = 0
            }
            let d = MCPDraft.open(model.project, model: model)
            d.playhead = pointers.playhead
            draft = d
            status = "\(kind.name) is thinking"
            // The thinking show, driven by its tool calls (see MCPHandler).
            MagicThinking.begin(model: model, name: kind.name, color: MCPTools.color(for: kind.name))
            launch(kind, cli, url: "\(endpoint)?draft=\(d.token)", brief: Self.brief(request: request, project: model.project, pointers: pointers), openCodeMajor: major)
        }
    }

    /// Stops the AI (or, once it's finished, its edit from being played), with nothing changed.
    func stop() {
        MagicThinking.current?.end()
        stopped = true
        ready = nil
        process?.terminate()
        if process == nil, running { done() }
    }

    private func done() {
        draft?.close()
        draft = nil
        process = nil
        running = false
        status = nil
        if startedServer, !MCPServer.shared.enabled { MCPServer.shared.stop() }
        startedServer = false
    }

    /// Magic needs Editroom's connection even when other apps aren't allowed in (AI Agents off).
    private func serverReady() async -> Bool {
        let server = MCPServer.shared
        if !server.running {
            server.start()
            startedServer = true
        }
        for _ in 0..<40 where server.localEndpoint == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        return server.localEndpoint != nil
    }

    /// Signed in already, or signs in now (once, in the browser) if the person wants to.
    private func signIn(_ kind: Kind, _ cli: URL) async -> Bool {
        if await signedIn(kind, cli) { return true }
        let ask = EditroomAlert()
        ask.messageText = "Sign in to \(kind.name)"
        switch kind {
        case .claude:
            ask.informativeText = "Magic uses Claude through Claude Code on this Mac, with your Claude plan. It needs signing in once, in your browser."
        case .chatgpt:
            ask.informativeText = "Magic uses ChatGPT through Codex, which comes with the ChatGPT app, with your ChatGPT plan. It needs signing in once, in your browser."
        case .opencode:
            ask.informativeText = "Magic uses the providers configured in OpenCode. Sign in with opencode auth login in Terminal, then try Magic again."
        }
        ask.addButton(withTitle: kind == .opencode ? "Open Terminal" : "Sign In")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return false }
        if kind == .opencode {
            openOpenCodeLogin(cli)
            alert("Finish signing in to OpenCode", "Complete the sign-in in Terminal, then come back and try Magic again.")
            return false
        }
        status = "Signing in to \(kind.name)"
        let out = await run(cli, kind == .claude ? ["auth", "login", "--claudeai"] : ["login"])
        guard !stopped else { return false }
        if await signedIn(kind, cli) { return true }
        alert("\(kind.name) isn't signed in", out.isEmpty ? "Signing in didn't finish." : String(out.prefix(600)))
        return false
    }

    private func signedIn(_ kind: Kind, _ cli: URL) async -> Bool {
        switch kind {
        case .claude:
            let out = await run(cli, ["auth", "status", "--json"])
            guard let data = out.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["loggedIn"] as? Bool ?? false
        case .chatgpt:
            let out = await run(cli, ["login", "status"])
            return out.localizedCaseInsensitiveContains("logged in") && !out.localizedCaseInsensitiveContains("not logged in")
        case .opencode:
            let out = await run(cli, ["auth", "list"], timeout: 12)
            if let data = out.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [Any], !json.isEmpty { return true }
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && !text.lowercased().contains("no credentials") && !text.lowercased().contains("not authenticated")
        }
    }

    private func openOpenCodeLogin(_ cli: URL) {
        let command = "'" + cli.path.replacingOccurrences(of: "'", with: "'\\''") + "' auth login"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to activate\ntell application \"Terminal\" to do script \"\(escaped)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    /// Runs a program to the end (stoppable) and returns what it printed.
    private func run(_ cli: URL, _ args: [String], timeout: TimeInterval? = nil) async -> String {
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        p.environment = Self.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return error.localizedDescription }
        process = p
        let data = await Task.detached { () -> Data in
            if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } } }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return d
        }.value
        if process === p { process = nil }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        return env
    }

    /// A private OpenCode agent: Editroom's MCP tools and the web, with no shell, files or subagents.
    static func openCodeConfigContent(url: String, major: Int) -> [String: Any] {
        if major >= 2 {
            let permissions: [[String: String]] = [
                ["action": "*", "resource": "*", "effect": "deny"],
                ["action": "editroom_*", "resource": "*", "effect": "allow"],
                ["action": "webfetch", "resource": "*", "effect": "allow"],
                ["action": "websearch", "resource": "*", "effect": "allow"],
                ["action": "external_directory", "resource": "*", "effect": "allow"],
            ]
            let server: [String: Any] = ["type": "remote", "url": url, "oauth": false, "codemode": false,
                                         "timeout": ["startup": 30_000, "execution": 300_000]]
            let agent: [String: Any] = ["description": "Edit videos through Editroom's MCP tools.", "mode": "primary", "permissions": permissions]
            return ["mcp": ["servers": ["editroom": server]], "permissions": permissions, "agents": ["editroom": agent]]
        }
        let permission: [String: String] = [
            "*": "deny", "editroom_*": "allow", "webfetch": "allow", "websearch": "allow", "external_directory": "allow",
        ]
        let tools: [String: Bool] = ["editroom_*": true, "webfetch": true, "websearch": true]
        let server: [String: Any] = ["type": "remote", "url": url, "oauth": false, "enabled": true, "timeout": 300_000]
        let agent: [String: Any] = ["description": "Edit videos through Editroom's MCP tools.", "mode": "primary",
                                    "tools": tools, "permission": permission]
        return ["mcp": ["editroom": server], "tools": tools, "permission": permission, "agent": ["editroom": agent]]
    }

    private func launch(_ kind: Kind, _ cli: URL, url: String, brief: String, openCodeMajor: Int) {
        let fm = FileManager.default
        // An empty folder of its own, so the AI reads no project's settings or notes.
        let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Editroom/Magic", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = cli
        p.currentDirectoryURL = folder
        var environment = Self.environment
        switch kind {
        case .claude:
            let config = #"{"mcpServers":{"editroom":{"type":"http","url":"\#(url)"}}}"#
            p.arguments = [
                "-p", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
                "--mcp-config", config, "--strict-mcp-config",
                // Editroom's tools, and web search and reading pages (to find music). None of Claude
                // Code's others: no files, no shell.
                "--tools", "WebSearch,WebFetch",
                "--allowedTools", "mcp__editroom", "WebSearch", "WebFetch",
                "--disallowedTools", "mcp__editroom__auto_edit", "mcp__editroom__import_media", "mcp__editroom__save_project",
                "mcp__editroom__export",
            ]
            if !model(for: kind).isEmpty { p.arguments! += ["--model", model(for: kind)] }
            if !effort(for: kind).isEmpty { p.arguments! += ["--effort", effort(for: kind)] }
        case .chatgpt:
            p.arguments = [
                // Web search (to find music); the shell stays read-only and offline.
                "--search",
                "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
                "-s", "read-only", "-C", folder.path,
                "-c", "mcp_servers.editroom.url=\"\(url)\"",
                "-c", "mcp_servers.editroom.tool_timeout_sec=300",
                "-c", "mcp_servers.editroom.startup_timeout_sec=30",
                "-c", "approval_policy=\"never\"",
            ]
            if !model(for: kind).isEmpty { p.arguments! += ["-m", model(for: kind)] }
            if !effort(for: kind).isEmpty { p.arguments! += ["-c", "model_reasoning_effort=\"\(effort(for: kind))\""] }
            p.arguments! += ["-"]
        case .opencode:
            let config = Self.openCodeConfigContent(url: url, major: openCodeMajor)
            guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else {
                alert("Couldn't start OpenCode", "Couldn't make OpenCode's temporary settings.")
                return done()
            }
            environment["OPENCODE_CONFIG_CONTENT"] = String(decoding: data, as: UTF8.self)
            environment["OPENCODE_DISABLE_PROJECT_CONFIG"] = "true"
            environment["OPENCODE_DISABLE_DEFAULT_PLUGINS"] = "true"
            environment["OPENCODE_DISABLE_EXTERNAL_SKILLS"] = "true"
            environment["OPENCODE_DISABLE_CLAUDE_CODE"] = "true"
            environment["OPENCODE_DISABLE_AUTOUPDATE"] = "true"
            // V2's shared background service owns configuration; a private server guarantees ours is used.
            p.arguments = (openCodeMajor >= 2 ? ["--standalone"] : []) + [
                "run", "--format", "json", "--auto", "--agent", "editroom", "--title", "Editroom Magic",
            ]
            if !model(for: kind).isEmpty { p.arguments! += ["--model", model(for: kind)] }
            p.arguments! += [brief]
        }
        p.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors

        pending = Data()
        errorText = Data()
        lastMessage = ""
        failure = nil
        openCodeCalls.removeAll()
        openCodeAssistantMessages.removeAll()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // At the end, stop listening, or this is called again and again.
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in self.read(data, kind) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in self.errorText.append(data.prefix(20_000)) }
        }
        p.terminationHandler = { proc in
            Task { @MainActor in
                // Let the last lines of output land first.
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.finish(code: proc.terminationStatus)
            }
        }
        do {
            try p.run()
        } catch {
            alert("Couldn't start \(kind.name)", error.localizedDescription)
            return done()
        }
        if kind == .opencode {
            try? input.fileHandleForWriting.close()
        } else {
            input.fileHandleForWriting.write(Data(brief.utf8))
            try? input.fileHandleForWriting.close()
        }
        process = p
    }

    /// The AI's progress, one JSON object a line.
    private func read(_ data: Data, _ kind: Kind) {
        pending.append(data)
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch kind {
            case .claude: readClaude(json)
            case .chatgpt: readCodex(json)
            case .opencode: readOpenCode(json)
            }
        }
    }

    private func readClaude(_ json: [String: Any]) {
        switch json["type"] as? String {
        case "result":
            lastMessage = json["result"] as? String ?? lastMessage
            if (json["is_error"] as? Bool ?? false) || json["subtype"] as? String != "success" {
                failure = lastMessage.isEmpty ? "Claude stopped (\(json["subtype"] as? String ?? "error"))." : lastMessage
            }
        case "assistant":
            guard let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            if let tool = content.last(where: { $0["type"] as? String == "tool_use" })?["name"] as? String {
                toolCalled(tool.replacingOccurrences(of: "mcp__editroom__", with: ""))
            }
            if let text = content.last(where: { $0["type"] as? String == "text" })?["text"] as? String, !text.isEmpty {
                lastMessage = text
            }
        default: break
        }
    }

    private func readCodex(_ json: [String: Any]) {
        let type = json["type"] as? String ?? ""
        let item = json["item"] as? [String: Any] ?? [:]
        switch (type, item["type"] as? String) {
        case ("item.started", "mcp_tool_call"):
            toolCalled(item["tool"] as? String ?? "")
        case ("item.completed", "agent_message"):
            if let text = item["text"] as? String, !text.isEmpty { lastMessage = text }
        case ("turn.failed", _):
            failure = ((json["error"] as? [String: Any])?["message"] as? String) ?? "ChatGPT stopped."
        case ("error", _):
            failure = json["message"] as? String ?? failure
        default: break
        }
    }

    private func readOpenCode(_ json: [String: Any]) {
        let type = json["type"] as? String ?? ""
        let properties = json["properties"] as? [String: Any] ?? [:]
        switch type {
        case "message.updated":
            let info = properties["info"] as? [String: Any] ?? [:]
            if info["role"] as? String == "assistant", let id = info["id"] as? String { openCodeAssistantMessages.insert(id) }
        case "message.part.updated":
            let part = properties["part"] as? [String: Any] ?? [:]
            let messageID = part["messageID"] as? String ?? ""
            switch part["type"] as? String {
            case "text":
                if openCodeAssistantMessages.contains(messageID), let text = part["text"] as? String, !text.isEmpty {
                    lastMessage = text
                }
            case "tool":
                let state = part["state"] as? [String: Any] ?? [:]
                let status = state["status"] as? String ?? ""
                let call = part["callID"] as? String ?? part["id"] as? String ?? ""
                if status == "running" || status == "completed", openCodeCalls.insert(call).inserted {
                    var tool = part["tool"] as? String ?? ""
                    tool = tool.replacingOccurrences(of: "mcp__editroom__", with: "")
                    tool = tool.replacingOccurrences(of: "editroom_", with: "")
                    toolCalled(tool)
                }
            default: break
            }
        case "session.error":
            failure = Self.openCodeError(properties["error"]) ?? "OpenCode stopped."
        case "permission.asked", "permission.v2.asked":
            failure = "OpenCode asked for permission, which Magic can't approve."
        case "error":
            failure = Self.openCodeError(json["error"]) ?? json["message"] as? String ?? failure
        default: break
        }
    }

    private static func openCodeError(_ raw: Any?) -> String? {
        if let text = raw as? String, !text.isEmpty { return text }
        guard let error = raw as? [String: Any] else { return nil }
        if let message = error["message"] as? String, !message.isEmpty { return message }
        if let data = error["data"] as? [String: Any], let message = data["message"] as? String, !message.isEmpty { return message }
        if let name = error["name"] as? String { return name }
        return nil
    }

    private func toolCalled(_ tool: String) {
        guard let kind = agent else { return }
        log("MAGIC AI tool \(tool)")
        status = "\(kind.name) is " + Self.doing(tool)
    }

    private static func doing(_ tool: String) -> String {
        switch tool {
        case "list_media", "get_project", "list_looks": "reading"
        case "look_at_media": "watching"
        case "note_media": "noting"
        case "analyze_media": "studying"
        case "get_transcript": "listening"
        case "add_clip", "trim_clip", "move_clip", "split_clip", "delete_clips", "set_sequence", "add_track": "cutting"
        case "set_grade": "grading"
        case "add_title", "set_title_style": "titling"
        case "search_media": "searching"
        case "set_marker", "delete_markers", "set_in_out": "marking"
        case "set_transform", "freeze_frame", "reverse_clip", "detach_audio", "duplicate_clip", "add_solid", "set_solid_color", "set_track": "editing"
        case "set_audio", "set_transition": "finishing"
        case "get_frame", "playback", "history": "checking"
        default: "thinking"
        }
    }

    private func finish(code: Int32) {
        guard running, let kind = agent else { return }
        let draft = self.draft
        let edits = draft?.edits ?? []
        let seconds = Date().timeIntervalSince(started)
        lastSeconds = seconds
        done()
        if stopped { return log("MAGIC AI stopped") }
        let stderr = String(data: errorText, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log(String(format: "MAGIC AI finished code %d in %.0fs, %d tool calls, %d edits; said: %@", code, seconds,
                   draft?.calls ?? 0, edits.count, lastMessage))
        if edits.isEmpty { MagicThinking.current?.end() }
        if let failure, edits.isEmpty {
            log("MAGIC AI failure: \(failure) \(stderr.suffix(400))")
            return alert("\(kind.name) couldn't make the edit", String(failure.prefix(600)))
        }
        if edits.isEmpty, code != 0 {
            log("MAGIC AI failure: exit \(code) \(stderr.suffix(400))")
            return alert("\(kind.name) couldn't make the edit", String((stderr.isEmpty ? "It stopped (code \(code))." : stderr).suffix(600)))
        }
        let said = lastMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        // Played now, even from another app: it doesn't wait to be watched (the Dock icon bounces to say so).
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        reveal(kind, edits, said)
    }

    /// Plays the AI's edits onto the timeline with the swarm, then shows what it said.
    private func reveal(_ kind: Kind, _ edits: [MagicEdit], _ said: String) {
        guard !stopped else { return }
        guard let model, !edits.isEmpty else {
            note = Note(agent: kind, text: said.isEmpty ? "\(kind.name) didn't change anything." : said, changed: false, detail: noteDetail)
            return
        }
        // Played onto the timeline as it is now (in case it changed while the AI was thinking).
        // Shown as its result (every new clip flying in at once, like Local), not step by step as it worked.
        let plan = MCPDraft.resultPlan(base: model.project, edits: edits)
        log("MAGIC AI playing \(plan.tasks.count) edits")
        let detail = noteDetail
        let play = { [weak self] in
            guard self?.stopped == false else { return }
            // The same multicolour swarm as Local's: who made it is said before (the thinking show) and after (the note).
            let shown = MagicShow.play(model: model, plan: plan) { [weak self] in
                self?.note = Note(agent: kind, text: said, changed: true, detail: detail)
            }
            if !shown {
                model.mutate { p in for e in edits { e.apply(&p, 1) } }
                self?.note = Note(agent: kind, text: said, changed: true, detail: detail)
            }
        }
        // The thinking show hands over to the swarm, which sets off as it fades: the timeline laid out
        // for the finished cut first, so the sketched clips move with it to where they'll land.
        if let thinking = MagicThinking.current {
            MagicShow.fit(model: model, plan: plan)
            thinking.handOver()
        }
        play()
    }

    private var noteDetail: String {
        "\(runDetail) · \(Int(lastSeconds.rounded()))s"
    }

    private func alert(_ title: String, _ text: String) {
        let a = EditroomAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private func log(_ s: String) {
        guard CommandLine.arguments.contains("--magic-ai") else { return }
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}
