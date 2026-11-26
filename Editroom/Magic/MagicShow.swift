import AppKit
import QuartzCore
import SwiftUI

// MARK: - Anchors

/// Marks a SwiftUI view so the magic overlay can find where it is in the window.
struct MagicAnchor: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.key = key
        return v
    }

    func updateNSView(_ v: AnchorView, context: Context) { v.key = key }

    final class AnchorView: NSView {
        var key = "" { didSet { MagicAnchors.register(self, key) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        // A lazy grid makes its items again as they scroll back into view: each copy says where it is
        // once it's in the window.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { MagicAnchors.register(self, key) }
        }
    }
}

@MainActor
enum MagicAnchors {
    private struct Weak { weak var view: NSView? }
    /// Every view that has said it's this key: a scrolled list can briefly hold old copies, out of the window.
    private static var views: [String: [Weak]] = [:]

    static func register(_ v: NSView, _ key: String) {
        guard !key.isEmpty else { return }
        var list = (views[key] ?? []).filter { $0.view != nil && $0.view !== v }
        list.append(Weak(view: v))
        views[key] = list
    }

    /// Where the view is, in window coordinates: the newest copy that's in a window and shown.
    static func rect(_ key: String) -> NSRect? {
        guard let list = views[key] else { return nil }
        for w in list.reversed() {
            guard let v = w.view, v.window != nil, !v.isHiddenOrHasHiddenAncestor else { continue }
            return v.convert(v.bounds, to: nil)
        }
        return nil
    }
}

// MARK: - The show

/// Whether magic is working, and what to say on its button meanwhile.
@MainActor
final class MagicState: ObservableObject {
    static let shared = MagicState()
    @Published var busy = false
    @Published var status: String?
    /// The thinking show's stage ("Looking", "Analyzing", "Thinking"), or "Editing" during the swarm.
    @Published var stage: String?
    /// What an AI's latest tool call is doing ("looking at kareoke", "placing boat_wide"), shown on
    /// the button in place of the stage while it's fresh.
    @Published var activity: String?
    private var activityID = 0

    /// Shows what a tool call is doing; when the call is done, the button goes back to the stage
    /// ("Claude is thinking") after a moment unless another call has started.
    func begin(activity: String?) -> Int {
        activityID += 1
        self.activity = activity
        return activityID
    }

    func finish(activity id: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.activityID == id else { return }
            self.activity = nil
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Plays an edit plan as a swarm of cursors: each edit is handed to one of many fake cursors, which
/// travels to the control and drags it, while the change happens on the real timeline. The whole cut
/// is one undo step.
@MainActor
final class MagicShow: NSObject {
    static private(set) var current: MagicShow?
    static var isRunning: Bool { current != nil }
    /// Goes up each time Magic is stopped, so work started before then knows to drop what it found.
    static private(set) var runID = 0

    /// Whether Magic is shown at work (the cursors, scans and sketch), from Settings > Magic.
    static var animated: Bool { UserDefaults.standard.object(forKey: "magicShowWork") as? Bool ?? true }

    /// The edit made at once, without the show: one undo step, the timeline fitted to it.
    static func applyAtOnce(model: EditorModel, plan: MagicPlan) {
        model.mutate { q in
            q = plan.base
            for task in plan.tasks { task.edit.apply(&q, 1) }
        }
        model.zoomToFit()
    }

    /// Stop (the Magic button) or esc: whatever Magic is doing stops. While it's still working out the
    /// edit nothing has changed; mid-edit, everything the swarm has done so far is put back.
    static func stopAll() {
        runID += 1
        if let show = current, !show.agentMode { show.abort() }
        MagicAgent.shared.stop()
        MagicThinking.current?.end()
        MagicState.shared.busy = false
        MagicState.shared.status = nil
    }

    /// Someone outside the app (an AI agent connected over MCP) whose edits are played by one named
    /// cursor that stays where it stops.
    struct Performer {
        let name: String
        let color: NSColor
        /// Where its cursor was left last time; nil starts from the Magic button.
        let start: CGPoint?
        let done: (CGPoint?) -> Void
    }

    /// Plays some edits, one after another, with one agent's cursor. Calls `done` with where the
    /// cursor ended up. Waits for any other show to finish first.
    static func perform(model: EditorModel, edits: [MagicEdit], as performer: Performer) async {
        while current != nil || MagicState.shared.busy { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard !edits.isEmpty else {
            performer.done(performer.start)
            return
        }
        // No timeline on screen to show it on: just make the change.
        guard let canvas = TimelineCanvas.current, let window = canvas.window, window.isVisible else {
            model.mutate { p in for e in edits { e.apply(&p, 1) } }
            performer.done(performer.start)
            return
        }
        var tasks: [MagicTask] = []
        for (i, e) in edits.enumerated() { tasks.append(MagicTask(edit: e, after: i > 0 ? [i - 1] : [])) }
        let show = MagicShow(model: model, plan: MagicPlan(base: model.project, tasks: tasks), window: window, canvas: canvas,
                             click: nil, performer: performer)
        current = show
        show.begin()
    }

    /// What a new cut is, in terms of what they asked and in the app's own words (clips on the
    /// timeline, from files in Media): "Made a 12-second cut of the little girl eating: 5 clips from
    /// IMG_1838, cut to the beat."
    static func madeNote(_ d: EditDecision, length: Double, recipe: LocalRecipe) -> String {
        var names: [String] = []
        for s in d.shots where !names.contains(s.asset.name) { names.append(s.asset.name) }
        let of = recipe.asked.isEmpty ? "" : L10n.fmt(" of %@", recipe.asked)
        let n = d.shots.count
        let clips = n == 1 ? L10n.tr("1 clip") : L10n.fmt("%lld clips", n)
        let from: String
        if names.count == 1 {
            from = L10n.fmt(" from %@", names[0])
        } else if names.count <= 3 || ((!recipe.asked.isEmpty || !recipe.keepOnly.isEmpty) && names.count <= 5) {
            from = L10n.fmt(" from %@ and %@", names.dropLast().joined(separator: ", "), names.last!)
        } else {
            from = d.shots.allSatisfy { $0.asset.kind == .video }
                ? L10n.fmt(" from %lld videos in your Media", names.count)
                : L10n.fmt(" from %lld files in your Media", names.count)
        }
        return L10n.fmt("Made a %.0f-second cut", length) + of + L10n.tr(": ") + clips + from + (d.music == nil ? "" : L10n.tr(", cut to the beat")) + L10n.tr(".")
    }

    /// Looks at the media, plans a cut, and plays it. `fromMouse` spawns the cursors from where the
    /// mouse was when this was called; otherwise from the Magic button.
    /// `recipe` is what the person asked for in the Local tab (read by Apple's on-device model); `done` gets
    /// a sentence on what changed (and anything it couldn't do) once the show is over, and whether it changed anything.
    static func start(model: EditorModel, fromMouse: Bool, recipe: LocalRecipe = .plain, done: ((String, Bool) -> Void)? = nil) {
        let state = MagicState.shared
        guard current == nil, !state.busy, let canvas = TimelineCanvas.current, let window = canvas.window else { return }
        let click = fromMouse ? window.mouseLocationOutsideOfEventStream : nil
        let project = model.project
        let offline = Set(project.assets.filter { model.media.isOffline($0) }.map(\.id))
        // With an edit on the timeline, Magic improves that edit (its shots, its song) rather than
        // starting over from the whole library.
        let onTimeline = Set(project.clips.filter { $0.kind == .video || $0.kind == .image }.compactMap(\.assetID))
        // Unless they asked for the whole library ("use most of the clips"): then a new cut, in place of the edit.
        let improving = !onTimeline.isEmpty && !recipe.wholeLibrary
        let visuals = project.assets.filter { a in
            !offline.contains(a.id) && (a.kind == .image || (a.kind == .video && a.duration >= 1))
                && (!improving || onTimeline.contains(a.id))
                // Media they named: only those, or not those.
                && (recipe.keepOnly.isEmpty || recipe.keepOnly.contains(a.id)) && !recipe.takeOut.contains(a.id)
        }
        guard !visuals.isEmpty else {
            if let done, recipe.isFocused {
                done(recipe.mediaNames.count == 1
                    ? (improving
                        ? L10n.fmt("%@ isn't in your edit, so there was nothing to keep.", recipe.mediaNames[0])
                        : L10n.fmt("%@ isn't in your Media, so there was nothing to keep.", recipe.mediaNames[0]))
                    : (improving
                        ? L10n.fmt("%@ aren't in your edit, so there was nothing to keep.", recipe.mediaNames.joined(separator: ", "))
                        : L10n.fmt("%@ aren't in your Media, so there was nothing to keep.", recipe.mediaNames.joined(separator: ", "))), false)
            } else {
                NSSound.beep()
            }
            return
        }
        // The song: the one the edit uses, or (for a new cut) the longest in the library.
        // (A song, not a sound effect: 8 seconds or more.)
        let songOnTimeline = project.clips.filter { $0.kind == .audio && $0.linkID == nil }
            .compactMap { c in project.assets.first { $0.id == c.assetID && $0.kind == .audio && $0.duration >= 8 } }
            .max { $0.duration < $1.duration }
        let librarySong = project.assets.filter { $0.kind == .audio && !offline.contains($0.id) && $0.duration >= 8 }.max { $0.duration < $1.duration }
        // Music they asked to add when the edit has none: the longest song in the library.
        let newSong = improving && recipe.music == .add && songOnTimeline == nil ? librarySong : nil
        let song: MediaAsset? = recipe.music == .off ? nil
            : improving ? (newSong ?? songOnTimeline.flatMap { offline.contains($0.id) ? nil : $0 })
            : librarySong
        state.busy = true
        state.status = nil
        // The thinking show while it studies the clips (one already running, for a request being read, carries on).
        let thinking = MagicThinking.current ?? MagicThinking.begin(model: model, name: L10n.tr("Local"), color: NSColor(white: 0.95, alpha: 1))
        thinking?.look()
        let visualIDs = Set(visuals.map(\.id))
        let run = runID
        // `--magic-lock-test` (testing): what the lock lets through while it's working the edit out.
        if CommandLine.arguments.contains("--magic-lock-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let w = window, h = w.frame.height
                let b = MagicAnchors.rect("magicButton") ?? .zero
                func mouse(_ x: CGFloat, _ y: CGFloat) -> NSEvent? {
                    NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                func key(_ code: UInt16, _ c: String, _ mods: NSEvent.ModifierFlags = []) -> NSEvent? {
                    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: w.windowNumber,
                                     context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)
                }
                let cases: [(String, NSEvent?)] = [
                    ("click timeline", mouse(w.frame.width / 2, 120)), ("click viewer", mouse(w.frame.width / 2, h / 2)),
                    ("click Magic button", mouse(b.midX, b.midY)), ("click Export", mouse(b.maxX + 40, b.midY)),
                    ("click title strip", mouse(300, h - 15)), ("space", key(49, " ")), ("delete", key(51, "\u{7f}")),
                    ("cmd-z", key(6, "z", .command)), ("cmd-q", key(12, "q", .command)), ("esc", key(53, "\u{1b}")),
                ]
                let said = cases.map { name, e in "\(name): \(e.map { "\(MagicLock.judge($0, in: w, allowSpace: true))" } ?? "no event")" }
                FileHandle.standardError.write("MAGIC LOCK \(said.joined(separator: ", "))\n".data(using: .utf8)!)
            }
        }
        // `--magic-stop <seconds>` (testing): Stop that long after starting, as esc or the button would.
        if let i = CommandLine.arguments.firstIndex(of: "--magic-stop"), i + 1 < CommandLine.arguments.count,
           let after = Double(CommandLine.arguments[i + 1]) {
            let before = model.project.clips.count
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                let mid = current != nil ? "mid-edit" : "while working it out"
                stopAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    FileHandle.standardError.write("MAGIC STOP TEST \(mid): clips \(before) before, \(model.project.clips.count) after, show \(current == nil ? "gone" : "still running"), busy \(state.busy)\n".data(using: .utf8)!)
                }
            }
        }
        Task { @MainActor in
            let started = CACurrentMediaTime()
            // Looking for a moment, then Analyzing (with progress on the button).
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard run == runID else { return }
            MagicThinking.current?.analyze(assets: visualIDs)
            let found = await analyze(visuals, song: song) { done, total in
                guard run == runID else { return }
                state.status = done < total ? L10n.fmt("Analyzing %lld of %lld", done, total) : nil
            }
            // Stopped meanwhile: nothing to do.
            guard run == runID else { return }
            state.status = nil
            var plan: MagicPlan?
            var said = ""
            var notes = recipe.cannotDo.isEmpty ? [] : [recipe.cannotDo]
            if improving {
                let analyses = Dictionary(found.clips.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
                let outcome = LocalImprover.plan(project: model.project, analyses: analyses, music: found.music?.1,
                                                 recipe: recipe, newSong: newSong)
                plan = outcome.flatMap { $0.plan.tasks.isEmpty ? nil : $0.plan }
                said = outcome.map { o in
                    if let message = o.message { return message }
                    // "Kept only IMG_1607 (2 shots out); everything else off the timeline." for a focused request.
                    return o.focused ? o.summary.prefix(1).uppercased() + o.summary.dropFirst() + L10n.tr(".") : L10n.fmt("Improved your edit: %@.", o.summary)
                } ?? L10n.tr("Your edit already looks good; nothing to change.")
                if outcome?.message == nil { notes += outcome?.notes ?? [] }
                if CommandLine.arguments.contains("--magic") {
                    FileHandle.standardError.write("MAGIC IMPROVE \(outcome?.summary ?? "nothing to change") (\(outcome?.plan.tasks.count ?? 0) edits) recipe: \(recipe.summary)\n".data(using: .utf8)!)
                }
            } else {
                let decision = AutoPlanner.decide(project: model.project, clips: found.clips, music: found.music, recipe: recipe)
                plan = decision.flatMap { Choreographer.plan(project: model.project, decision: $0) }
                if let decision {
                    let length = decision.shots.reduce(0) { $0 + $1.duration }
                    said = Self.madeNote(decision, length: length, recipe: recipe)
                    if let s = recipe.seconds, length < s - 1 { notes.append(L10n.fmt("your Media only had enough good footage for about %lld seconds", Int(length.rounded()))) }
                    if recipe.every {
                        let used = Set(decision.shots.map(\.asset.id)).count
                        if used < found.clips.count { notes.append(L10n.fmt("%lld of your clips were too short to use", found.clips.count - used)) }
                        if let s = recipe.seconds, length > s + 0.5 {
                            notes.append(L10n.fmt("fitting every clip in made it %.0f seconds", length))
                        }
                    }
                    if CommandLine.arguments.contains("--magic-local") {
                        FileHandle.standardError.write("MAGIC PLAN \(decision.shots.count) shots from \(Set(decision.shots.map(\.asset.id)).count) of \(found.clips.count) clips, \(String(format: "%.1f", length))s, every=\(recipe.every)\n".data(using: .utf8)!)
                    }
                }
                // The frame shape they asked for, from the start.
                let size: (Int, Int)? = switch recipe.frame {
                case .vertical: (1080, 1920)
                case .horizontal: (1920, 1080)
                case .square: (1080, 1080)
                case .unchanged: nil
                }
                if let size, plan != nil {
                    plan!.base.width = size.0
                    plan!.base.height = size.1
                    plan!.base.settingsLocked = true
                }
                if CommandLine.arguments.contains("--magic"), let decision {
                    log(decision, found.music?.1, seconds: CACurrentMediaTime() - started)
                }
            }
            if !notes.isEmpty { said += " " + L10n.fmt("It couldn't do everything you asked: %@.", notes.joined(separator: "; ")) }
            guard let plan, current == nil, let canvas = TimelineCanvas.current, let window = canvas.window else {
                state.busy = false
                state.status = nil
                MagicThinking.current?.end()
                if let done, plan == nil { done(said.isEmpty ? L10n.tr("Magic couldn't find anything to make a cut from.") : said, false) } else { NSSound.beep() }
                return
            }
            // Spawn from the click if it was quick; after a wait (or after the thinking show), from the button.
            let fromClick = CACurrentMediaTime() - started < 1.5 && MagicThinking.current == nil ? click : nil
            let launch = {
                guard run == runID else { return }
                // Not shown at work (Settings > Magic): the edit at once.
                guard animated else {
                    applyAtOnce(model: model, plan: plan)
                    state.busy = false
                    state.status = nil
                    done?(said, true)
                    return
                }
                let show = MagicShow(model: model, plan: plan, window: window, canvas: canvas, click: fromClick, performer: nil)
                if let done { show.onFinish = { done(said, true) } }
                current = show
                state.status = nil
                show.begin()
            }
            if let thinking = MagicThinking.current {
                // Long enough to see the scouting (cached analysis is instant).
                let watched = CACurrentMediaTime() - started
                if watched < 2.4 { try? await Task.sleep(nanoseconds: UInt64((2.4 - watched) * 1e9)) }
                // The timeline laid out for the finished cut first, so the sketch is where the clips will land.
                Self.fit(model: model, plan: plan)
                var final = plan.base
                for task in plan.tasks { task.edit.apply(&final, 1) }
                thinking.plan(final)
                // Until the sketch is drawn, and a beat to take it in; then the swarm sets off as the
                // thinking show fades around it.
                let hold = min(2.0, max(0.8, thinking.secondsUntilDrawn + 0.35))
                try? await Task.sleep(nanoseconds: UInt64(hold * 1e9))
                guard run == runID else { return }
                state.status = nil
                thinking.handOver()
                launch()
            } else {
                launch()
            }
        }
    }

    /// Plays a finished plan (an AI agent's Magic edit) with the swarm, as one undo step. Calls
    /// `done` when the show is over. Returns false if there's no timeline to play it on.
    @discardableResult
    static func play(model: EditorModel, plan: MagicPlan, done: (() -> Void)? = nil) -> Bool {
        if !animated, !plan.tasks.isEmpty, current == nil {
            applyAtOnce(model: model, plan: plan)
            done?()
            return true
        }
        guard current == nil, !plan.tasks.isEmpty, let canvas = TimelineCanvas.current, let window = canvas.window, window.isVisible else {
            return false
        }
        let show = MagicShow(model: model, plan: plan, window: window, canvas: canvas, click: nil, performer: nil)
        show.onFinish = done
        current = show
        show.begin()
        return true
    }

    /// Analyses the clips (a few at a time) and the song, reporting progress.
    private static func analyze(_ visuals: [MediaAsset], song: MediaAsset?,
                                progress: @escaping @MainActor (Int, Int) -> Void) async
        -> (clips: [(MediaAsset, ClipAnalysis)], music: (MediaAsset, MusicAnalysis)?) {
        let total = visuals.count + (song == nil ? 0 : 1)
        var done = 0
        progress(0, total)
        var clips: [UUID: ClipAnalysis] = [:]
        var music: MusicAnalysis?
        await withTaskGroup(of: (UUID, ClipAnalysis?, MusicAnalysis?).self) { group in
            var queue = visuals.map { ($0.id, $0.url, $0.kind, false) }
            if let song { queue.insert((song.id, song.url, song.kind, true), at: 0) }
            var running = 0
            func next() {
                guard !queue.isEmpty else { return }
                let (id, url, kind, isSong) = queue.removeFirst()
                running += 1
                group.addTask {
                    isSong ? (id, nil, await MediaAnalyzer.music(url)) : (id, await MediaAnalyzer.clip(url, kind: kind), nil)
                }
            }
            for _ in 0..<3 { next() }
            for await (id, clip, beat) in group {
                if let clip { clips[id] = clip }
                if let beat { music = beat }
                done += 1
                progress(done, total)
                next()
            }
        }
        return (visuals.compactMap { a in clips[a.id].map { (a, $0) } }, song.flatMap { s in music.map { (s, $0) } })
    }

    private static func log(_ d: EditDecision, _ m: MusicAnalysis?, seconds: Double) {
        var lines = [String(format: "MAGIC PLAN %.2fs analysis, %d shots, %.2fs long, title \"%@\"", seconds, d.shots.count,
                            d.shots.reduce(0) { $0 + $1.duration }, d.title)]
        if !d.title.isEmpty { lines[0] += d.titleAtEnd ? " at the end" : " at the start" }
        if let m, let music = d.music {
            lines.append(String(format: "MAGIC MUSIC %.1f bpm, %d beats, bar phase %d, starts %.2fs", m.bpm, m.beats.count, m.barPhase, music.source))
        }
        for s in d.shots {
            lines.append(String(format: "MAGIC SHOT %@ %.2f+%.2f score %.2f exp %+.1f%@", s.asset.name, s.source, s.duration, s.score,
                                s.exposure, s.dissolve ? " dissolve" : ""))
        }
        FileHandle.standardError.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    }

    private struct Slot {
        let edit: MagicEdit
        let agent: Int
        let travelStart: Double
        let start: Double
        let end: Double
        var grab: CGPoint?
        var release: CGPoint?
        /// Where the cursor waits nearby if it gets there early, from where things will be.
        var hover: CGPoint?
    }

    private final class Agent {
        let color: NSColor
        let cursor = CALayer()
        let tag = CALayer()
        let tagText = CATextLayer()
        let ghost = CALayer()
        /// The right-click menu it opens to pick a transition.
        let menu = CALayer()
        let menuHighlight = CALayer()
        var slots: [Int] = []
        var label = ""
        var birth = 0.0
        var angle = 0.0
        /// Each cursor moves at its own pace.
        var speed = 1.0
        /// When it heads back to the button, and when it's gone.
        var home = 0.0
        var gone = 0.0
        init(color: NSColor) { self.color = color }
    }

    private final class Card {
        let clip: UUID
        let row: Int
        var slots: [Int] = []
        var frame: CGRect?
        var appear = 0.0
        var vanish = 0.0
        let layer = CALayer()
        let title = CATextLayer()
        let chip = CALayer()
        let chipText = CATextLayer()
        var knobs: [MagicGradeKey: (fill: CALayer, knob: CALayer, value: CATextLayer)] = [:]
        init(clip: UUID, row: Int) { self.clip = clip; self.row = row }
    }

    private let model: EditorModel
    private let plan: MagicPlan
    private let window: NSWindow
    private let canvas: TimelineCanvas
    /// Where the Magic button was clicked, in window coordinates.
    private let click: NSPoint?
    private var slots: [Slot] = []
    private var order: [Int] = []
    private var agents: [Agent] = []
    private var cards: [UUID: Card] = [:]
    private let overlay: NSWindow
    private let root = CALayer()
    private var link: CADisplayLink?
    /// The show's clock when its window can't be seen (behind another app, minimised, on another
    /// Space): the display stops calling `step` then, but the show carries on and finishes.
    private var unseen: Timer?
    private var monitor: Any?
    private var t0 = CACurrentMediaTime()
    private var skip = 0.0
    private var workEnd = 0.0
    private var showEnd = 0.0
    private var spawn = CGPoint.zero
    private var done = false
    /// The finished cut, and every clip as it's first dropped, for working out where things will be.
    private var finalProject = Project()
    private var staged: [UUID: Clip] = [:]
    /// The first shot shows a second in, not the moment the cursors come out (that jump is jarring).
    private var lastFlash = 0.7
    private var flashIndex = -1
    private var frames = 0
    private var longestFrame = 0.0
    private var lastFrame = 0.0

    static let outro = 0.34
    static let homeTrip = 0.42
    static let cardHeight: CGFloat = 96
    static let cardGap: CGFloat = 6
    /// Grade panels sit in the inspector, stacked; this many fit at once.
    private var cardSlots = 4
    private var cardSize = CGSize(width: 290, height: 106)
    private var trackWidth: CGFloat { cardSize.width - Self.trackX - 46 }
    private static let trackX: CGFloat = 84
    private let backdrop = CALayer()
    private let backdropTitle = CATextLayer()
    private let backdropCount = CATextLayer()
    private var backdropSpan = (0.0, 0.0)
    /// The show runs slower than it's planned, so it lasts about this long.
    static let targetLength = 7.0
    private var pace = 1.0
    /// Until then (the first steps) the show plays in real time; after, at `pace`.
    private var quickEnd = 0.0
    /// Timeline zoom during the show, and zoomed to fit the finished cut at the end.
    private var startPPS: CGFloat = 1
    /// Where a transition menu's Dissolve item is, from where the menu was opened.
    static let menuItem = CGPoint(x: 62, y: 20)
    static let menuItems = TransitionKind.allCases.map(\.label)

    private let performer: Performer?
    private var agentMode: Bool { performer != nil }
    /// Called once a played plan's show is over.
    private var onFinish: (() -> Void)?

    private init(model: EditorModel, plan: MagicPlan, window: NSWindow, canvas: TimelineCanvas, click: NSPoint?, performer: Performer?) {
        self.performer = performer
        self.model = model
        // Magic's own edits in the steps a person would take, a cursor each (an outside agent's are
        // played as they came, by its one cursor).
        self.plan = performer == nil ? plan.inSteps() : plan
        if CommandLine.arguments.contains("--magic") {
            func describe(_ e: MagicEdit) -> String {
                switch e {
                case .place(let c, _): return "place×\(c.count)"
                case .trimHead(let ids, _, _): return "trimHead×\(ids.count)"
                case .trimTail(let ids, _, _): return "trimTail×\(ids.count)"
                case .move(let ids, _, _, _): return "move×\(ids.count)"
                case .blade(let ids, _, _, _): return "blade×\(ids.count)"
                case .remove(let ids, let r): return "remove×\(ids.count)\(r ? " ripple" : "")"
                default: return e.label
                }
            }
            FileHandle.standardError.write("MAGIC STEPS \(plan.tasks.map { describe($0.edit) }.joined(separator: ", ")) -> \(self.plan.tasks.map { describe($0.edit) + "<\($0.after)" }.joined(separator: ", "))\n".data(using: .utf8)!)
        }
        self.window = window
        self.canvas = canvas
        self.click = click
        overlay = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
    }

    // MARK: Setup

    private func begin() {
        if !agentMode { MagicState.shared.stage = L10n.tr("Editing") }
        model.pause()
        model.selection = []
        model.rebuildSuspended = true

        // Lay the timeline out for the finished cut before anything lands on it. An agent's edits
        // happen on the timeline as the person left it.
        model.live(autoCommit: false) { $0 = plan.base }
        if !agentMode { fitTimeline() }

        spawn = performer?.start ?? spawnPoint()
        schedule()
        // Make the grades' colour cubes now, not mid-show.
        for g in Set(finalProject.clips.compactMap(\.grade)) { _ = GradeBaker.cube(for: g) }
        buildOverlay()
        startShow()
    }

    private func fitTimeline() {
        startPPS = Self.fit(model: model, plan: plan)
    }

    /// Lays the timeline out for a plan's finished cut (and the rough cut on its way there). Returns the zoom.
    @discardableResult
    static func fit(model: EditorModel, plan: MagicPlan) -> CGFloat {
        var final = plan.base
        for task in plan.tasks { task.edit.apply(&final, 1) }
        let total = max(final.duration, plan.base.duration, plan.tasks.compactMap { task -> Double? in
            if case .place(let clips, _) = task.edit { return clips.map(\.end).max() }
            return nil
        }.max() ?? 0, 4)
        let tracks = CGFloat(plan.base.videoTracks.count + plan.base.audioTracks.count)
        let fit = (model.rowsVisible - TimelineLayout.fixedHeight - TimelineLayout.captionSpace(plan.base) - 8) / tracks - TimelineLayout.gap
        model.setView(rowHeight: min(62, fit))
        model.setView(pps: (model.view.viewWidth - 60) / CGFloat(total), scrollX: 0)
        model.centerRows()
        return model.view.pps
    }

    private func startShow() {
        let watching: NSEvent.EventTypeMask = agentMode ? [.leftMouseDown, .rightMouseDown, .keyDown] : MagicLock.events
        monitor = NSEvent.addLocalMonitorForEvents(matching: watching) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, !self.done else { return e }
                // An agent's edits from outside: any click or key skips to the end.
                guard !self.agentMode else {
                    self.fastForward()
                    return nil
                }
                // Magic's own edit: the editor is locked (see MagicLock). Esc, or Stop on the Magic
                // button, stops and puts back what it's done so far.
                switch MagicLock.judge(e, in: self.window, allowSpace: false) {
                case .pass: return e
                case .stop:
                    Self.stopAll()
                    return nil
                case .blocked:
                    return nil
                }
            }
        }
        t0 = CACurrentMediaTime()
        let link = overlay.contentView!.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
        let unseen = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.window.occlusionState.contains(.visible) || self.window.isMiniaturized else { return }
                self.step()
            }
        }
        RunLoop.main.add(unseen, forMode: .common)
        self.unseen = unseen
        step()
    }

    /// How slow things are at a moment in the show: it starts unhurried and gets quicker.
    static func tempo(_ t: Double) -> Double { 0.72 + 1.1 * exp(-t / 0.8) }

    /// Hands every edit to a cursor. Cursors leave the button one at a time, each as it's needed, and
    /// each takes the next edit it can reach soonest, so they work and finish independently.
    private func schedule() {
        let tasks = plan.tasks
        // Every clip as it first appears (dropped, or cut off by the blade), and the finished cut.
        finalProject = plan.base
        for t in tasks {
            t.edit.apply(&finalProject, 1)
            for c in finalProject.clips where staged[c.id] == nil { staged[c.id] = c }
        }

        let insp = inspectorRect
        cardSize = CGSize(width: insp.width - 24, height: Self.cardHeight)
        cardSlots = max(2, Int((insp.height - 60) / (Self.cardHeight + Self.cardGap)))
        // Grade panels take turns in the inspector's places.
        var slotFree = Array(repeating: 0.0, count: cardSlots)
        var cardLeft: [UUID: Int] = [:]
        var cardLast: [UUID: Double] = [:]
        for t in tasks where t.edit.isGradeCard { if let id = t.edit.clipID { cardLeft[id, default: 0] += 1 } }

        few = tasks.count <= 6
        let count = agentMode ? 1 : min(64, max(14, Int(Double(tasks.count) / 2.4)))
        var rng = SeededRandom(seed: UInt64(tasks.count))
        for i in 0..<count {
            let hue = (Double(i) * 0.61803398875).truncatingRemainder(dividingBy: 1)
            let a = Agent(color: performer?.color ?? NSColor(hue: hue, saturation: 0.68, brightness: 0.97, alpha: 1))
            // Out of the button one after another, slowly at first, then faster.
            // Out of the button one after another: slowly at first, then faster, never quite evenly.
            a.birth = max(0, 2.4 * pow(Double(i) / Double(count), 0.7) + (rng.next() - 0.5) * 0.12)
            a.angle = rng.next() * 2 * .pi
            a.speed = 0.65 + rng.next() * 0.7
            if agentMode { a.birth = 0; a.speed = 1 }
            agents.append(a)
        }
        // Each edit gets a moment's thought before it starts, so cursors don't move in step. The
        // cursors on one grade panel think together and keep their tight stagger.
        var panelThought: [UUID: Double] = [:]
        // The first step or two start at once and at full speed, so the edit begins the moment the
        // thinking show hands over.
        let quick = agentMode ? [] : Set(tasks.indices.filter { tasks[$0].after.isEmpty && !tasks[$0].edit.isGradeCard }
            .sorted { tasks[$0].delay < tasks[$1].delay }.prefix(2))
        for a in agents.prefix(2) { a.speed = max(1, a.speed) }
        let think = tasks.indices.map { i -> Double in
            let t = tasks[i]
            if t.edit.isGradeCard, let id = t.edit.clipID {
                if let v = panelThought[id] { return v }
                let v = rng.next() * 0.35
                panelThought[id] = v
                return v
            }
            return agentMode || quick.contains(i) ? 0 : pow(rng.next(), 1.5) * 0.45
        }
        var free = agents.map(\.birth)
        var pos = Array(repeating: spawn, count: count)
        var used = Array(repeating: false, count: count)
        var end = Array(repeating: -1.0, count: tasks.count)
        var remaining = Set(tasks.indices)
        var firstDone = 0.0
        slots = []

        func travel(_ a: Int, _ from: CGPoint, _ to: CGPoint, at t: Double, quick: Bool) -> Double {
            let d = Double(hypot(to.x - from.x, to.y - from.y))
            return min(0.65, max(0.14, d / (2200 * agents[a].speed / (quick ? 1 : pace(at: t)))))
        }

        while !remaining.isEmpty {
            var best: (task: Int, ready: Double)?
            for i in remaining where tasks[i].after.allSatisfy({ end[$0] >= 0 }) {
                var ready = (tasks[i].after.map { end[$0] }.max() ?? 0) + (quick.contains(i) ? 0 : tasks[i].delay) + think[i]
                if tasks[i].edit.isGradeCard, let id = tasks[i].edit.clipID {
                    // Waits for its panel to be in the inspector, or for a place to open up.
                    if let card = cards[id] { ready = max(ready, card.appear + 0.18 + tasks[i].delay) }
                    else { ready = max(ready, (slotFree.min() ?? 0) + 0.18 + tasks[i].delay) }
                }
                if best == nil || ready < best!.ready { best = (i, ready) }
            }
            guard let (ti, ready) = best else { break }
            let edit = tasks[ti].edit
            if edit.isGradeCard, let id = edit.clipID, cards[id] == nil {
                let j = slotFree.indices.min { slotFree[$0] < slotFree[$1] } ?? 0
                let card = Card(clip: id, row: j)
                card.appear = max(slotFree[j], ready - 0.18 - tasks[ti].delay)
                cards[id] = card
                slotFree[j] = .infinity
            }
            let (grab, release) = computePoints(edit)
            // The cursor that can get there first; a cursor already out beats a new one.
            var pick = 0, pickStart = Double.infinity, pickTravel = 0.0
            for a in 0..<count {
                let tr = travel(a, pos[a], grab, at: free[a], quick: quick.contains(ti))
                let start = max(ready, free[a] + tr)
                let better = start < pickStart - 1e-6 || (abs(start - pickStart) <= 1e-6 && used[a] && !used[pick])
                if better { pick = a; pickStart = start; pickTravel = tr }
            }
            let perform = edit.performTime * (quick.contains(ti) ? 1 : pace(at: pickStart)) * (agentMode ? 1 : edit.isGradeCard ? 0.85 + rng.next() * 0.3 : 0.7 + rng.next() * 0.8)
            let finish = pickStart + perform
            if quick.contains(ti) { firstDone = max(firstDone, finish) }
            slots.append(Slot(edit: edit, agent: pick, travelStart: pickStart - pickTravel, start: pickStart, end: finish))
            agents[pick].slots.append(slots.count - 1)
            free[pick] = finish + 0.03
            pos[pick] = release
            used[pick] = true
            end[ti] = finish
            remaining.remove(ti)
            if edit.isGradeCard, let id = edit.clipID, let card = cards[id] {
                card.slots.append(slots.count - 1)
                cardLast[id] = max(cardLast[id] ?? 0, finish)
                cardLeft[id, default: 1] -= 1
                if cardLeft[id] == 0 {
                    // Done: it leaves for its clip, and the next panel can take its place.
                    card.vanish = cardLast[id]! + 0.12
                    slotFree[card.row] = card.vanish + 0.18
                }
            }
        }
        order = slots.indices.sorted { slots[$0].start < slots[$1].start }
        workEnd = (slots.map(\.end).max() ?? 0) + 0.06

        // Each cursor goes home once it has nothing left to do. An agent's cursor stays put.
        for a in agents {
            guard let last = a.slots.last else { continue }
            a.birth = slots[a.slots[0]].travelStart
            a.home = agentMode ? .infinity : slots[last].end + 0.08 + rng.next() * 0.12
            a.gone = agentMode ? .infinity : a.home + Self.homeTrip
        }
        showEnd = agentMode ? workEnd + 0.05 : max(workEnd, agents.map(\.gone).max() ?? workEnd) + 0.05

        if let first = cards.values.map(\.appear).min(), let last = cards.values.map(\.vanish).max() {
            backdropSpan = (first - 0.15, last + 0.3)
        }
        // Stretched to last about targetLength, but not the first steps: those play in real time.
        quickEnd = min(showEnd, firstDone)
        // A few cursors (an AI's small edit, a clip added) aren't stretched: that only slowed one cursor
        // down, the trip back to the button included. A swarm is, so it reads as a show.
        pace = agentMode || few || showEnd <= quickEnd ? 1 : max(1, (Self.targetLength - quickEnd) / (showEnd - quickEnd))
    }

    /// A small edit (a handful of steps, so only a cursor or three ever work on it).
    private var few = false

    /// How slow things are at a moment: the show starts unhurried and speeds up; an agent works at
    /// a steady, quick pace.
    private func pace(at t: Double) -> Double { agentMode || few ? 0.85 : Self.tempo(t) }

    // MARK: Overlay

    private func buildOverlay() {
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        // A flipped, layer-backed view: AppKit keeps its layer's sublayers in top-left coordinates.
        let host = FlippedView(frame: NSRect(origin: .zero, size: window.frame.size))
        host.wantsLayer = true
        host.layer?.addSublayer(root)
        root.frame = host.bounds
        root.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        overlay.contentView = host
        window.addChildWindow(overlay, ordered: .above)

        let scale = window.backingScaleFactor

        backdrop.backgroundColor = Theme.NS.panel.cgColor
        backdrop.opacity = 0
        for (layer, text, x, size, color) in [(backdropTitle, L10n.tr("Grade"), 16.0, 13.0, Theme.NS.text), (backdropCount, "", 0.0, 11.0, Theme.NS.textDim)] {
            layer.contentsScale = scale
            layer.string = text
            layer.font = NSFont.systemFont(ofSize: size, weight: x > 0 ? .semibold : .medium)
            layer.fontSize = size
            layer.foregroundColor = color.cgColor
            layer.alignmentMode = x > 0 ? .left : .right
            backdrop.addSublayer(layer)
        }
        let insp = inspectorRect
        backdropTitle.frame = CGRect(x: 16, y: 15, width: 120, height: 17)
        backdropCount.frame = CGRect(x: insp.width - 136, y: 17, width: 120, height: 15)
        root.addSublayer(backdrop)
        for c in cards.values {
            buildCard(c, scale: scale)
            root.addSublayer(c.layer)
        }
        for a in agents {
            a.ghost.cornerRadius = 4
            a.ghost.masksToBounds = true
            a.ghost.borderWidth = 1.5
            a.ghost.borderColor = a.color.cgColor
            a.ghost.contentsGravity = .resizeAspectFill
            a.ghost.isHidden = true
            root.addSublayer(a.ghost)
        }
        for a in agents {
            a.menu.bounds = CGRect(x: 0, y: 0, width: 116, height: 70)
            a.menu.anchorPoint = .zero
            a.menu.backgroundColor = NSColor(hex: 0x262626).cgColor
            a.menu.cornerRadius = 7
            a.menu.borderWidth = 1
            a.menu.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
            a.menu.shadowColor = NSColor.black.cgColor
            a.menu.shadowOpacity = 0.5
            a.menu.shadowRadius = 8
            a.menuHighlight.frame = CGRect(x: 4, y: 4, width: 108, height: 20)
            a.menuHighlight.cornerRadius = 4
            a.menuHighlight.backgroundColor = a.color.withAlphaComponent(0.85).cgColor
            a.menu.addSublayer(a.menuHighlight)
            for (k, item) in Self.menuItems.enumerated() {
                let tl = CATextLayer()
                tl.contentsScale = scale
                tl.string = item
                tl.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                tl.fontSize = 11
                tl.foregroundColor = Theme.NS.text.cgColor
                tl.frame = CGRect(x: 12, y: 7 + CGFloat(k) * 21, width: 96, height: 15)
                a.menu.addSublayer(tl)
            }
            a.menu.isHidden = true
            root.addSublayer(a.menu)
        }
        for a in agents {
            a.cursor.contents = Self.cursorImage(a.color, scale: scale)
            a.cursor.contentsScale = scale
            a.cursor.bounds = CGRect(x: 0, y: 0, width: 18, height: 24)
            a.cursor.anchorPoint = CGPoint(x: 2 / 18, y: 2 / 24)
            a.cursor.isHidden = true
            a.tag.backgroundColor = a.color.blended(withFraction: 0.18, of: .black)?.cgColor
            a.tag.cornerRadius = 4
            a.tag.isHidden = true
            a.tagText.contentsScale = scale
            a.tagText.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            a.tagText.fontSize = 10
            a.tagText.foregroundColor = NSColor.white.cgColor
            a.tagText.alignmentMode = .center
            a.tag.addSublayer(a.tagText)
            root.addSublayer(a.tag)
            root.addSublayer(a.cursor)
        }

    }

    private func buildCard(_ c: Card, scale: CGFloat) {
        let size = cardSize
        c.layer.bounds = CGRect(origin: .zero, size: size)
        c.layer.backgroundColor = NSColor(hex: 0x181818).cgColor
        c.layer.cornerRadius = 8
        c.layer.borderWidth = 1
        c.layer.borderColor = NSColor(white: 1, alpha: 0.09).cgColor
        c.layer.opacity = 0

        func text(_ s: String, _ frame: CGRect, size: CGFloat = 10, weight: NSFont.Weight = .medium,
                  color: NSColor = Theme.NS.textDim, align: CATextLayerAlignmentMode = .left) -> CATextLayer {
            let t = CATextLayer()
            t.contentsScale = scale
            t.string = s
            t.font = NSFont.systemFont(ofSize: size, weight: weight)
            t.fontSize = size
            t.foregroundColor = color.cgColor
            t.alignmentMode = align
            t.frame = frame
            c.layer.addSublayer(t)
            return t
        }

        let name = finalProject.clip(c.clip).map { finalProject.displayName(of: $0) } ?? L10n.tr("Clip")
        c.title.contentsScale = scale
        _ = text(L10n.tr("GRADE"), CGRect(x: 10, y: 8, width: 44, height: 12), size: 9, weight: .bold, color: Theme.NS.textFaint)
        let t = text(name, CGRect(x: 52, y: 7, width: size.width - 62, height: 13), size: 10.5, weight: .semibold, color: Theme.NS.text)
        t.truncationMode = .middle

        _ = text(L10n.tr("Look"), CGRect(x: 10, y: 27, width: 56, height: 13))
        c.chip.frame = CGRect(x: Self.trackX - 6, y: 24, width: size.width - Self.trackX - 4, height: 18)
        c.chip.cornerRadius = 5
        c.chip.backgroundColor = NSColor(hex: 0x232323).cgColor
        c.chip.borderWidth = 1
        c.chip.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        c.layer.addSublayer(c.chip)
        c.chipText.contentsScale = scale
        c.chipText.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        c.chipText.fontSize = 10
        c.chipText.foregroundColor = Theme.NS.textDim.cgColor
        c.chipText.frame = CGRect(x: 8, y: 2.5, width: c.chip.frame.width - 16, height: 13)
        let before = plan.base.clip(c.clip)?.grade
        c.chipText.string = before?.look == nil ? L10n.tr("None") : before!.localizedLookLabel
        c.chip.addSublayer(c.chipText)

        for (i, key) in MagicGradeKey.allCases.enumerated() {
            let y = Self.rowY(i)
            _ = text(key.label, CGRect(x: 10, y: y - 7, width: 70, height: 13))
            let track = CALayer()
            track.frame = CGRect(x: Self.trackX, y: y - 1, width: trackWidth, height: 2)
            track.cornerRadius = 1
            track.backgroundColor = NSColor(white: 1, alpha: 0.13).cgColor
            c.layer.addSublayer(track)
            let fill = CALayer()
            fill.backgroundColor = Theme.NS.text.cgColor
            fill.cornerRadius = 1
            c.layer.addSublayer(fill)
            let knob = CALayer()
            knob.bounds = CGRect(x: 0, y: 0, width: 11, height: 11)
            knob.cornerRadius = 5.5
            knob.backgroundColor = Theme.NS.text.cgColor
            knob.borderWidth = 2
            knob.borderColor = NSColor(hex: 0x161616).cgColor
            c.layer.addSublayer(knob)
            let value = text("0", CGRect(x: size.width - 40, y: y - 7, width: 30, height: 13), size: 9.5, color: Theme.NS.textFaint, align: .right)
            value.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
            c.knobs[key] = (fill, knob, value)
            // Where it starts: the clip's grade as it is now.
            let v = key.value(before), x = knobX(key, v), mid = knobX(key, 0)
            knob.position = CGPoint(x: x, y: y)
            fill.frame = CGRect(x: min(x, mid), y: y - 1, width: abs(x - mid), height: 2)
            value.string = key == .exposure ? String(format: "%+.2f", v) : String(format: "%+.0f", v)
        }
    }

    private static func rowY(_ i: Int) -> CGFloat { 54 + CGFloat(i) * 15 }

    private func knobX(_ key: MagicGradeKey, _ v: Double) -> CGFloat {
        let r = key.range
        return Self.trackX + CGFloat((v - r.lowerBound) / (r.upperBound - r.lowerBound)) * trackWidth
    }

    static func cursorImage(_ color: NSColor, scale: CGFloat) -> CGImage? {
        let w = 18, h = 24
        guard let ctx = CGContext(data: nil, width: Int(CGFloat(w) * scale), height: Int(CGFloat(h) * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Drawn top-down.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let p = CGMutablePath()
        let pts: [CGPoint] = [(2, 2), (2, 18.5), (6.2, 14.6), (9.1, 21), (11.6, 19.9), (8.8, 13.6), (14.4, 13.6)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        p.addLines(between: pts)
        p.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.5, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.addPath(p)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.addPath(p)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.3)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        return ctx.makeImage()
    }

    // MARK: Geometry

    /// Window coordinates to the overlay's, which run from the top-left.
    private func toOverlay(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: window.frame.height - r.maxY, width: r.width, height: r.height)
    }

    private func toOverlay(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: window.frame.height - p.y) }

    private func spawnPoint() -> CGPoint {
        let button = MagicAnchors.rect("magicButton").map { toOverlay($0) }
        if let click {
            let m = toOverlay(click)
            if CGRect(origin: .zero, size: window.frame.size).contains(m) { return m }
        }
        if let button { return CGPoint(x: button.midX, y: button.midY) }
        return CGPoint(x: window.frame.width - 140, y: 26)
    }

    private func clipRect(_ c: Clip) -> CGRect? {
        canvas.magicWindowRect(of: c, in: model.project).map { toOverlay($0) }
    }

    /// A clip as it is now, or as it will be dropped if it isn't on the timeline yet.
    private func clip(_ id: UUID) -> Clip? { model.project.clip(id) ?? staged[id] }

    private func clipRect(_ id: UUID) -> CGRect? {
        clip(id).flatMap { clipRect($0) }
    }

    private var inspectorRect: CGRect {
        MagicAnchors.rect("inspector").map { toOverlay($0) }
            ?? CGRect(x: window.frame.width - 320, y: 52, width: 320, height: max(300, timelineRect.minY - 60))
    }

    private var timelineRect: CGRect { toOverlay(canvas.convert(canvas.bounds, to: nil)) }

    private func tileRect(_ asset: UUID?) -> CGRect {
        let library = MagicAnchors.rect("library").map { toOverlay($0) } ?? CGRect(x: 0, y: 80, width: 250, height: 400)
        // A title comes from the Text button.
        guard let asset else {
            return MagicAnchors.rect("addText").map { toOverlay($0) } ?? CGRect(x: library.maxX - 90, y: library.minY + 10, width: 26, height: 26)
        }
        // The list of thumbnails (under the search field).
        let list = MagicAnchors.rect("libraryList").map { toOverlay($0) }
            ?? CGRect(x: library.minX, y: library.minY + 80, width: library.width, height: library.height - 80)
        let r = MagicAnchors.rect(asset.uuidString).map { toOverlay($0) }
        // In sight: its own thumbnail.
        if let r, list.contains(CGPoint(x: r.midX, y: r.midY)) { return r }
        // Out of sight: from the middle of the list's top (under the search field) or bottom edge,
        // whichever side it's scrolled past, never from another clip's thumbnail.
        let below: Bool
        if let r {
            below = r.midY > list.midY
        } else {
            // Not drawn at all (far out of sight): after the last one in sight is below.
            let order = model.project.assets.map(\.id)
            let shown = order.indices.filter { i in
                MagicAnchors.rect(order[i].uuidString).map { list.contains(CGPoint(x: toOverlay($0).midX, y: toOverlay($0).midY)) } ?? false
            }
            below = (order.firstIndex(of: asset) ?? 0) > (shown.max() ?? -1)
        }
        let size = CGSize(width: 64, height: 36)
        return CGRect(x: list.midX - size.width / 2, y: below ? list.maxY - size.height + 6 : list.minY + 20,
                      width: size.width, height: size.height)
    }

    private func cardFrame(_ c: Card) -> CGRect {
        if let f = c.frame { return f }
        // Its place in the inspector's stack.
        let insp = inspectorRect
        let f = CGRect(x: insp.minX + 12, y: insp.minY + 52 + CGFloat(c.row) * (cardSize.height + Self.cardGap),
                       width: cardSize.width, height: cardSize.height)
        c.frame = f
        return f
    }

    /// Where a cursor picks up and lets go for an edit, worked out when it sets off.
    private func points(_ i: Int, cache: Bool = true) -> (CGPoint, CGPoint) {
        if let g = slots[i].grab, let r = slots[i].release { return (g, r) }
        let (grab, release) = computePoints(slots[i].edit)
        if cache {
            slots[i].grab = grab
            slots[i].release = release
        }
        return (grab, release)
    }

    private func computePoints(_ edit: MagicEdit) -> (CGPoint, CGPoint) {
        let tl = timelineRect
        var grab = CGPoint(x: tl.midX, y: tl.midY), release = grab
        let project = model.project
        func x(_ t: Double) -> CGFloat { toOverlay(NSPoint(x: canvas.magicWindowX(t), y: 0)).x }
        switch edit {
        case .place(let clips, let asset):
            let tile = tileRect(asset)
            grab = CGPoint(x: tile.midX, y: tile.midY)
            if let c = clips.first, let r = clipRect(c) {
                release = CGPoint(x: r.minX + min(r.width, 260) * 0.3, y: r.midY)
            }
        case .trimHead(let ids, let from, let to), .trimTail(let ids, let from, let to):
            if let id = ids.first, let r = clipRect(id) {
                grab = CGPoint(x: x(from), y: r.midY)
                release = CGPoint(x: x(to), y: r.midY)
            }
        case .move(let ids, let from, let to, let tracks):
            if let id = ids.first, let c = clip(id), let r = clipRect(c) {
                var moved = c
                moved.start = to
                if let t = tracks[id] { moved.trackID = t }
                let dx = x(c.start + c.duration / 2) - x(from + c.duration / 2)
                grab = CGPoint(x: r.midX - dx, y: r.midY)
                if let r2 = clipRect(moved) { release = CGPoint(x: r2.midX, y: r2.midY) }
            }
        case .gain(let id, let from, let to):
            if let r = clipRect(id) {
                let px = r.minX + min(r.width * 0.5, 70)
                grab = CGPoint(x: px, y: r.minY + TimelineCanvas.magicGainNorm(from) * r.height)
                release = CGPoint(x: px, y: r.minY + TimelineCanvas.magicGainNorm(to) * r.height)
            }
        case .fadeIn(let id, let to):
            if let r = clipRect(id), let c = clip(id) {
                grab = CGPoint(x: r.minX + 6, y: r.minY + 8)
                release = CGPoint(x: max(r.minX + 6, x(c.start + to)), y: r.minY + 8)
            }
        case .fadeOut(let id, let to):
            if let r = clipRect(id), let c = clip(id) {
                grab = CGPoint(x: r.maxX - 6, y: r.minY + 8)
                release = CGPoint(x: min(r.maxX - 6, x(c.end - to)), y: r.minY + 8)
            }
        case .look(let id, _):
            if let card = cards[id] {
                let f = cardFrame(card)
                grab = CGPoint(x: f.minX + 119, y: f.minY + 35)
                release = grab
            } else if let r = finalRect(id) {
                grab = CGPoint(x: r.midX, y: tl.minY - 160)
                release = grab
            }
        case .grade(let id, let key, let to):
            if let card = cards[id] {
                let f = cardFrame(card)
                let y = f.minY + Self.rowY(MagicGradeKey.allCases.firstIndex(of: key) ?? 0)
                grab = CGPoint(x: f.minX + knobX(key, key.value(project.clip(id)?.grade)), y: y)
                release = CGPoint(x: f.minX + knobX(key, to), y: y)
            } else if let r = finalRect(id) {
                grab = CGPoint(x: r.midX, y: tl.minY - 160)
                release = grab
            }
        case .transition(let id, _):
            if let c = clip(id), let r = clipRect(c) {
                // Right-clicks the cut, then picks Dissolve from the menu.
                grab = CGPoint(x: r.minX, y: r.midY)
                release = CGPoint(x: grab.x + Self.menuItem.x, y: grab.y + Self.menuItem.y)
            }
        case .blade(let ids, let at, _, _):
            if let id = ids.first, let r = clipRect(id) {
                grab = CGPoint(x: x(at), y: r.midY)
                release = grab
            }
        case .remove(let ids, _):
            if let id = ids.first, let r = clipRect(id) {
                grab = CGPoint(x: r.midX, y: r.midY)
                release = grab
            }
        case .change(let id, _, _):
            // A click on the clip, or for the sequence, on the inspector.
            if let id, let r = clipRect(id) {
                grab = CGPoint(x: r.minX + min(r.width / 2, 80), y: r.midY)
            } else {
                let insp = inspectorRect
                grab = CGPoint(x: insp.midX, y: insp.minY + 60)
            }
            release = grab
        case .type(let id, _):
            if let r = clipRect(id) {
                grab = CGPoint(x: r.minX + min(r.width / 2, 60), y: r.midY)
                release = grab
            }
        }
        return (grab, release)
    }

    private func finalRect(_ id: UUID) -> CGRect? {
        finalProject.clip(id).flatMap { canvas.magicWindowRect(of: $0, in: finalProject) }.map { toOverlay($0) }
    }

    // MARK: Frames

    /// An AI's edit is played by one cursor, at four times the swarm's pace (one cursor at swarm speed drags).
    static let agentSpeed = 4.0

    private var now: Double {
        let r = (CACurrentMediaTime() - t0) * (agentMode ? Self.agentSpeed : 1)
        return (r <= quickEnd ? r : quickEnd + (r - quickEnd) / pace) + skip
    }

    private func fastForward() {
        let t = now
        if t < workEnd {
            skip += workEnd - t
            // Everyone heads home together.
            for a in agents where a.home > workEnd { a.home = workEnd + 0.02; a.gone = a.home + Self.homeTrip }
            showEnd = workEnd + Self.homeTrip + 0.1
        }
    }

    private var overlayFrame = NSRect.zero
    @objc private func step() {
        let t = now
        // Follow the window if it moves or resizes.
        if window.frame != overlayFrame {
            overlayFrame = window.frame
            overlay.setFrame(window.frame, display: false)
        }

        // The project at this moment: every edit applied as far as it has got.
        var p = plan.base
        for i in order where t >= slots[i].start {
            let s = slots[i]
            // A clip's grade changes once its whole card is done: each new grade means re-grading its thumbnails.
            if s.edit.isGradeCard { continue }
            s.edit.apply(&p, (t - s.start) / (s.end - s.start))
        }
        for c in cards.values where t >= c.vanish - 0.1 {
            for i in c.slots { slots[i].edit.apply(&p, 1) }
        }
        model.live(autoCommit: false) { $0 = p }
        canvas.magicMarks = marks(t)
        if !agentMode, t > workEnd, finalProject.duration > 0 {
            // Zoom out to fit the finished cut as the cursors head home.
            let u = CGFloat(MagicEase.inOut(min(1, (t - workEnd) / max(0.1, showEnd - workEnd - 0.05))))
            let fit = (model.view.viewWidth - 80) / CGFloat(finalProject.duration)
            model.setView(pps: startPPS + (fit - startPPS) * u, scrollX: 0)
        }
        if !agentMode { flashViewer(t) }
        let wall = CACurrentMediaTime()
        if frames > 0 { longestFrame = max(longestFrame, wall - lastFrame) }
        lastFrame = wall
        frames += 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawAgents(t)
        drawCards(t)
        CATransaction.commit()

        if t >= showEnd { finish() }
    }

    private func drawAgents(_ t: Double) {
        for a in agents {
            guard !a.slots.isEmpty, t >= a.birth, t < a.gone else {
                a.cursor.isHidden = true
                a.tag.isHidden = true
                a.ghost.isHidden = true
                a.menu.isHidden = true
                continue
            }
            let work = min(t, a.home)
            let pop = agentMode && performer?.start != nil ? 1 : MagicEase.out((t - a.birth) / 0.12)
            let out = t > a.home ? MagicEase.inOut(min(1, (t - a.home) / Self.homeTrip)) : 0
            let dir = CGPoint(x: cos(a.angle), y: sin(a.angle))
            let start = spawn
            var pos = start
            var label = ""
            var ghost: (CGRect, CGImage?)?
            var pressed = false
            var menu: (at: CGPoint, open: CGFloat, picked: Bool, shown: Bool)?

            // The edit this cursor is on: the first it hasn't finished, or its last.
            if let k = a.slots.firstIndex(where: { slots[$0].end > work }) ?? (a.slots.isEmpty ? nil : a.slots.count - 1) {
                let i = a.slots[k]
                let s = slots[i]
                // A cursor's first trip starts the moment it leaves the button.
                let prevEnd = k > 0 ? slots[a.slots[k - 1]].end : s.travelStart - 0.03
                let prev = k > 0 ? points(a.slots[k - 1]).1 : start
                let leave = max(prevEnd + 0.03, k > 0 ? prevEnd + 0.03 : s.travelStart)
                let approach = 0.14
                if work >= s.end {
                    pos = points(i).1
                    if work - s.end < 0.12 { label = s.edit.label }
                } else if work < leave {
                    pos = prev
                } else if work < s.start - approach, s.start - leave > s.start - s.travelStart + 0.3 {
                    // Early: head over, then wait just off the control.
                    let hover = hoverPoint(i, a)
                    if work < leave + 0.3 {
                        let u = MagicEase.inOut((work - leave) / 0.3)
                        pos = Self.bezier(prev, travelControl(prev, hover, a, first: k == 0, dir: dir), hover, CGFloat(u))
                    } else {
                        let w = work * 6 + a.angle * 3
                        pos = CGPoint(x: hover.x + CGFloat(sin(w)) * 3, y: hover.y + CGFloat(cos(w * 0.8)) * 3)
                    }
                    label = s.edit.label
                } else if work < s.start {
                    // Aims at where the control is now; it's pinned down when the drag starts, as
                    // what it's heading for may still be moving.
                    let (grab, _) = points(i, cache: false)
                    let early = s.start - leave > s.start - s.travelStart + 0.3
                    let from = early ? hoverPoint(i, a) : prev
                    // Otherwise it sets off when it needs to, at its own pace.
                    let t0 = early ? s.start - approach : max(leave, s.travelStart)
                    let u = MagicEase.inOut((work - t0) / max(0.01, s.start - t0))
                    pos = Self.bezier(from, early ? CGPoint(x: (from.x + grab.x) / 2, y: (from.y + grab.y) / 2)
                                      : travelControl(from, grab, a, first: k == 0, dir: dir), grab, CGFloat(u))
                    label = s.edit.label
                } else {
                    let (grab, release) = points(i)
                    let raw = (work - s.start) / (s.end - s.start)
                    var u = CGFloat(MagicEase.inOut(raw))
                    if case .transition = s.edit {
                        // Right-click, the menu opens, slide down to Dissolve, click.
                        let m = CGFloat(MagicEase.inOut(min(1, max(0, (raw - 0.3) / 0.45))))
                        u = m
                        menu = (grab, CGFloat(min(1, raw / 0.15)), raw > 0.6, raw < 0.9)
                    }
                    pos = CGPoint(x: grab.x + (release.x - grab.x) * u, y: grab.y + (release.y - grab.y) * u)
                    label = s.edit.label((work - s.start) / (s.end - s.start))
                    pressed = true
                    if case .place(let clips, let asset) = s.edit {
                        let tile = tileRect(asset)
                        let target = clips.first.flatMap { clipRect($0) } ?? tile
                        let w0 = tile.width, h0 = tile.height
                        let w1 = min(target.width, 260), h1 = target.height
                        let w = w0 + (w1 - w0) * u, h = h0 + (h1 - h0) * u
                        let poster = asset.flatMap { model.media.posters[$0] }?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                        ghost = (CGRect(x: pos.x - w * 0.3, y: pos.y - h / 2, width: w, height: h), poster)
                    }
                }
            }
            if let performer { label = label.isEmpty ? performer.name : performer.name + " · " + label }
            if out > 0 {
                // Back into the button.
                let ctrl = onScreen(CGPoint(x: (pos.x + spawn.x) / 2 + dir.x * 120, y: (pos.y + spawn.y) / 2 + dir.y * 120))
                pos = Self.bezier(pos, ctrl, spawn, CGFloat(out))
                label = ""
            }

            a.cursor.isHidden = false
            a.cursor.position = pos
            let fade = out > 0.6 ? (1 - out) / 0.4 : 1
            a.cursor.opacity = Float(min(1, pop * 2) * fade)
            let scale = (0.45 + 0.55 * pop) * (1 - 0.5 * out) * (pressed ? 0.88 : 1)
            a.cursor.transform = CATransform3DMakeScale(scale, scale, 1)

            if label.isEmpty {
                a.tag.isHidden = true
            } else {
                if label != a.label {
                    a.label = label
                    a.tagText.string = label
                    let w = ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width) + 12
                    a.tag.bounds = CGRect(x: 0, y: 0, width: w, height: 16)
                    a.tagText.frame = CGRect(x: 0, y: 1.5, width: w, height: 14)
                }
                a.tag.isHidden = false
                a.tag.position = CGPoint(x: pos.x + 10 + a.tag.bounds.width / 2, y: pos.y + 26)
                a.tag.opacity = a.cursor.opacity
            }

            if let menu, menu.shown {
                a.menu.isHidden = false
                a.menu.position = CGPoint(x: menu.at.x + 4, y: menu.at.y + 6)
                a.menu.opacity = Float(menu.open)
                let sc = 0.85 + 0.15 * menu.open
                a.menu.transform = CATransform3DMakeScale(sc, sc, 1)
                a.menuHighlight.opacity = menu.picked ? 1 : 0
            } else if !a.menu.isHidden {
                a.menu.isHidden = true
            }

            if let (frame, poster) = ghost {
                a.ghost.isHidden = false
                a.ghost.frame = frame
                if a.ghost.contents == nil {
                    if let poster { a.ghost.contents = poster } else { a.ghost.backgroundColor = a.color.withAlphaComponent(0.3).cgColor }
                }
                a.ghost.opacity = 0.9
            } else if !a.ghost.isHidden {
                a.ghost.isHidden = true
                a.ghost.contents = nil
                a.ghost.backgroundColor = nil
            }
        }
    }

    private func drawCards(_ t: Double) {
        let project = model.project
        drawBackdrop(t)
        for c in cards.values {
            guard t >= c.appear, t < c.vanish + 0.16 else {
                c.layer.opacity = 0
                continue
            }
            let f = cardFrame(c)
            let target = CGPoint(x: f.midX, y: f.midY)
            if t < c.appear + 0.16 {
                // Slides into its place in the inspector.
                let u = CGFloat(MagicEase.out((t - c.appear) / 0.16))
                c.layer.position = CGPoint(x: target.x + 40 * (1 - u), y: target.y)
                c.layer.transform = CATransform3DIdentity
                c.layer.opacity = Float(u)
            } else if t > c.vanish {
                // Done: shrinks away down onto its clip.
                let u = CGFloat(MagicEase.inOut((t - c.vanish) / 0.16))
                let clip = clipRect(c.clip).map { CGPoint(x: $0.midX, y: $0.midY) } ?? target
                c.layer.position = CGPoint(x: target.x + (clip.x - target.x) * u, y: target.y + (clip.y - target.y) * u)
                let s = 1 - 0.7 * u
                c.layer.transform = CATransform3DMakeScale(s, s, 1)
                c.layer.opacity = Float(1 - u)
            } else {
                c.layer.position = target
                c.layer.transform = CATransform3DIdentity
                c.layer.opacity = 1
            }

            // Controls follow the cursors dragging them.
            let grade = project.clip(c.clip)?.grade
            for i in c.slots {
                let s = slots[i]
                let u = t < s.start ? 0 : MagicEase.inOut(min(1, (t - s.start) / (s.end - s.start)))
                switch s.edit {
                case .look(_, let name):
                    let picked = t >= s.end
                    let was = plan.base.clip(c.clip)?.grade
                    c.chipText.string = picked ? BuiltInLook.displayName(name)
                        : (was?.look == nil ? L10n.tr("None") : was!.localizedLookLabel)
                    c.chipText.foregroundColor = (picked ? Theme.NS.text : Theme.NS.textDim).cgColor
                    c.chip.borderColor = (t >= s.start && t < s.end + 0.1 ? NSColor.white.withAlphaComponent(0.5) : NSColor(white: 1, alpha: 0.08)).cgColor
                case .grade(_, let key, let to):
                    guard let k = c.knobs[key] else { continue }
                    let start = key.value(plan.base.clip(c.clip)?.grade)
                    let v = t >= s.end ? key.value(grade) : start + (to - start) * u
                    let x = knobX(key, v), mid = knobX(key, 0)
                    let y = Self.rowY(MagicGradeKey.allCases.firstIndex(of: key) ?? 0)
                    k.knob.position = CGPoint(x: x, y: y)
                    k.fill.frame = CGRect(x: min(x, mid), y: y - 1, width: abs(x - mid), height: 2)
                    k.value.string = key == .exposure ? String(format: "%+.2f", v) : String(format: "%+.0f", v)
                    k.value.foregroundColor = (abs(v) > 0.001 ? Theme.NS.text : Theme.NS.textFaint).cgColor
                default: break
                }
            }
        }
    }

    /// What the timeline highlights: the clips cursors have hold of, the edges and handles they're
    /// dragging, snap guides as they land, and the blade's line.
    private func marks(_ t: Double) -> MagicMarks {
        var m = MagicMarks()
        for i in order where t >= slots[i].start && t < slots[i].end + 0.12 {
            let s = slots[i]
            let u = min(1, (t - s.start) / (s.end - s.start))
            let live = t < s.end
            switch s.edit {
            case .place(let clips, _):
                if !live { m.selected.formUnion(clips.map(\.id)) }
            case .trimHead(let ids, _, let to):
                m.selected.formUnion(ids)
                if live { m.left.formUnion(ids) }
                if live, u > 0.7, let id = ids.first { m.snaps.append(.init(time: to, clip: id)) }
            case .trimTail(let ids, _, let to):
                m.selected.formUnion(ids)
                if live { m.right.formUnion(ids) }
                if live, u > 0.7, let id = ids.first { m.snaps.append(.init(time: to, clip: id)) }
            case .move(let ids, _, let to, _):
                m.selected.formUnion(ids)
                if live, u > 0.6, let id = ids.first { m.snaps.append(.init(time: to, clip: id)) }
            case .blade(let ids, let at, _, _):
                if live { m.cuts += ids.map { .init(time: at, clip: $0) } }
            case .remove(let ids, _):
                m.selected.formUnion(ids)
            case .type(let id, _), .transition(let id, _):
                m.selected.insert(id)
            case .gain(let id, _, _):
                m.selected.insert(id)
                if live { m.gain.insert(id) }
            case .fadeIn(let id, _):
                m.selected.insert(id)
                if live { m.fadeIn.insert(id) }
            case .fadeOut(let id, _):
                m.selected.insert(id)
                if live { m.fadeOut.insert(id) }
            case .change(let id, _, _):
                if let id { m.selected.insert(id) }
            case .look, .grade:
                break
            }
        }
        return m
    }

    /// The viewer shows the shots as they're picked, one after another.
    private func flashViewer(_ t: Double) {
        let preview = model.sourcePreview
        // Not too often: each is a full-size frame for the viewer, and they cost smoothness.
        guard t < workEnd, t - lastFlash > 0.3 else { return }
        // Step through the shots already on the timeline, in order.
        let shots = model.project.clips.filter { $0.kind == .video }.sorted { ($0.start, $0.trackID.uuidString) < ($1.start, $1.trackID.uuidString) }
        guard !shots.isEmpty else { return }
        flashIndex = (flashIndex + 1) % shots.count
        let c = shots[flashIndex]
        guard let a = model.project.asset(c.assetID) else { return }
        lastFlash = t
        let time = c.sourceStart + c.duration * 0.6
        // Swapped in only once the frame has arrived, so the viewer never goes black.
        model.media.viewerFrame(asset: a.id, time: time) { [weak self] img in
            guard let self, !self.done else { return }
            preview.show(a, at: time, image: img)
        }
    }

    /// Covers the real inspector while grade panels are stacked in it.
    private func drawBackdrop(_ t: Double) {
        let (a, b) = backdropSpan
        let u = t < a ? 0 : t < a + 0.15 ? (t - a) / 0.15 : t < b ? 1 : max(0, 1 - (t - b) / 0.15)
        backdrop.opacity = Float(u)
        guard u > 0 else { return }
        backdrop.frame = inspectorRect
        let active = cards.values.filter { t >= $0.appear && t < $0.vanish }.count
        backdropCount.string = active == 0 ? "" : (active == 1 ? L10n.tr("1 clip") : L10n.fmt("%lld clips", active))
    }

    /// A gentle curve between two points; the first trip fans out from where the cursors appeared.
    /// Keeps a curve's control point in the window: the curve stays inside the triangle its ends and
    /// control point make, so it never leaves the screen.
    private func onScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 12), window.frame.width - 12), y: min(max(p.y, 40), window.frame.height - 12))
    }

    private func travelControl(_ a: CGPoint, _ b: CGPoint, _ agent: Agent, first: Bool, dir: CGPoint) -> CGPoint {
        onScreen(rawControl(a, b, agent, first: first))
    }

    private func rawControl(_ a: CGPoint, _ b: CGPoint, _ agent: Agent, first: Bool) -> CGPoint {
        if first {
            // Swings out of the button toward its target, curving one way or the other.
            let dx = b.x - a.x, dy = b.y - a.y
            let turn = (agent.angle > .pi ? 0.6 : -0.6) * (0.6 + 0.4 * sin(agent.angle * 3))
            return CGPoint(x: a.x + (dx * cos(turn) - dy * sin(turn)) * 0.45, y: a.y + (dx * sin(turn) + dy * cos(turn)) * 0.45)
        }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let bend: CGFloat = agent.angle.truncatingRemainder(dividingBy: 0.7) > 0.35 ? 0.16 : -0.16
        return CGPoint(x: mid.x - (b.y - a.y) * bend, y: mid.y + (b.x - a.x) * bend)
    }

    private func hoverPoint(_ i: Int, _ agent: Agent) -> CGPoint {
        if let h = slots[i].hover { return h }
        let g = points(i, cache: false).0
        let h = CGPoint(x: g.x + CGFloat(cos(agent.angle)) * 28, y: g.y - 22 + CGFloat(sin(agent.angle)) * 12)
        slots[i].hover = h
        return h
    }

    private static func bezier(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ u: CGFloat) -> CGPoint {
        let v = 1 - u
        return CGPoint(x: v * v * a.x + 2 * v * u * c.x + u * u * b.x, y: v * v * a.y + 2 * v * u * c.y + u * u * b.y)
    }

    // MARK: End

    /// Stopped part-way: the overlay goes, and the timeline is put back as it was before the show (the
    /// show's changes were never committed, so there's no undo step either).
    private func abort() {
        guard !done else { return }
        done = true
        link?.invalidate()
        link = nil
        unseen?.invalidate()
        unseen = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onFinish = nil
        model.discardLive()
        model.sourcePreview.clear()
        canvas.magicMarks = MagicMarks()
        window.removeChildWindow(overlay)
        overlay.orderOut(nil)
        model.rebuildSuspended = false
        Self.current = nil
        MagicState.shared.busy = false
        MagicState.shared.status = nil
        if MagicThinking.current == nil { MagicState.shared.stage = nil }
        if CommandLine.arguments.contains("--magic") {
            FileHandle.standardError.write("MAGIC STOPPED clips back to \(model.project.clips.count), can undo \(model.canUndo)\n".data(using: .utf8)!)
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        link?.invalidate()
        link = nil
        unseen?.invalidate()
        unseen = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        var p = plan.base
        for i in order { slots[i].edit.apply(&p, 1) }
        model.live(autoCommit: false) { $0 = p }
        model.commitLive()
        model.sourcePreview.clear()
        canvas.magicMarks = MagicMarks()
        if let performer {
            // The agent's edits are done: one undo step, the timeline left as it was, and its cursor
            // parked where it stopped until its next call.
            window.removeChildWindow(overlay)
            overlay.orderOut(nil)
            model.rebuildSuspended = false
            Self.current = nil
            let end = agents.first?.slots.last.map { points($0).1 }
            if let end { AgentPresence.shared.park(performer.name, color: performer.color, at: end, in: window) }
            performer.done(end)
            return
        }
        model.zoomToFit()
        if CommandLine.arguments.contains("--magic") {
            FileHandle.standardError.write(String(format: "MAGIC agents %d edits %d work %.2fs frames %d longest %.0fms\n",
                         agents.count, slots.count, workEnd, frames, longestFrame * 1000).data(using: .utf8)!)
        }
        window.removeChildWindow(overlay)
        overlay.orderOut(nil)
        model.rebuildSuspended = false
        model.seek(to: 0)
        Self.current = nil
        MagicState.shared.busy = false
        if MagicThinking.current == nil { MagicState.shared.stage = nil }
        let callback = onFinish
        onFinish = nil
        // A moment after the overlay closes, or a popover opened now (the finished note) closes with it.
        if let callback { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { callback() } }
        // Left at the start, paused: the person plays it when they're ready.
        // `--magic-undo` (testing): check one undo takes the whole cut away.
        if CommandLine.arguments.contains("--magic-undo") {
            let built = model.project.clips.count
            model.undo()
            FileHandle.standardError.write("MAGIC UNDO built \(built) clips, after undo \(model.project.clips.count)\n".data(using: .utf8)!)
        }
    }
}
