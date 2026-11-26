import Foundation

/// Grade controls a cursor can drag on a floating grade card.
enum MagicGradeKey: CaseIterable {
    case exposure, contrast, saturation

    var label: String {
        switch self {
        case .exposure: return L10n.tr("Exposure")
        case .contrast: return L10n.tr("Contrast")
        case .saturation: return L10n.tr("Saturation")
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -2...2
        case .contrast: return -50...50
        case .saturation: return -100...100
        }
    }

    func value(_ g: ColorGrade?) -> Double {
        switch self {
        case .exposure: return g?.exposure ?? 0
        case .contrast: return g?.contrast ?? 0
        case .saturation: return g?.saturation ?? 0
        }
    }

    func set(_ g: inout ColorGrade, _ v: Double) {
        switch self {
        case .exposure: g.exposure = v
        case .contrast: g.contrast = v
        case .saturation: g.saturation = v
        }
    }
}

/// One small edit, the kind a person makes with one drag or click. Applied with a progress from 0 to
/// 1 so a drag can be shown happening.
enum MagicEdit {
    /// Drops new clips (a video and its linked audio, or a title) on the timeline. `asset` is the
    /// library item they're dragged from; nil for a title, which comes from the Text button.
    case place([Clip], asset: UUID?)
    case trimHead([UUID], from: Double, to: Double)
    case trimTail([UUID], from: Double, to: Double)
    /// Moves clips in time and onto other tracks.
    case move([UUID], from: Double, to: Double, tracks: [UUID: UUID])
    /// Cuts clips in two with the blade; the right-hand pieces get the given ids.
    case blade([UUID], at: Double, pieces: [UUID: UUID], link: UUID?)
    case remove([UUID], ripple: Bool = false)
    /// Any other change, made with a click on the clip (or nowhere, for the sequence).
    case change(UUID?, String, (inout Project) -> Void)
    /// Types a title's text.
    case type(UUID, String)
    case gain(UUID, from: Double, to: Double)
    case fadeIn(UUID, to: Double)
    case fadeOut(UUID, to: Double)
    case look(UUID, name: String)
    case grade(UUID, MagicGradeKey, to: Double)
    case transition(UUID, Transition)

    /// What the cursor's tag says while it does this, `p` of the way through.
    func label(_ p: Double = 1) -> String {
        switch self {
        case .place(let clips, _):
            switch clips.first?.kind {
            case .audio: return L10n.tr("Music")
            case .text: return L10n.tr("Title")
            default: return L10n.tr("Place")
            }
        case .trimHead, .trimTail: return L10n.tr("Trim")
        case .move: return L10n.tr("Move")
        case .blade: return L10n.tr("✂ Cut")
        case .remove: return L10n.tr("Delete")
        case .change(_, let label, _): return L10n.tr(label)
        case .type(_, let text):
            let n = Int((Double(text.count) * min(1, max(0, p))).rounded(.down))
            return String(text.prefix(n)) + (n < text.count ? "|" : "")
        case .gain(_, _, let to): return String(format: "%.0f dB", to).replacingOccurrences(of: "-", with: "−")
        case .fadeIn: return L10n.tr("Fade in")
        case .fadeOut: return L10n.tr("Fade out")
        case .look(_, let name): return BuiltInLook.displayName(name)
        case .grade(_, let key, _): return key.label
        case .transition(_, let t): return t.kind.label
        }
    }

    var label: String { label(1) }

    /// How long the drag or click itself takes, in seconds.
    var performTime: Double {
        switch self {
        case .place: return 0.5
        case .trimHead, .trimTail: return 0.28
        case .move: return 0.42
        case .blade: return 0.16
        case .remove: return 0.14
        case .change: return 0.16
        case .type(_, let text): return 0.12 + Double(text.count) * 0.045
        case .gain: return 0.24
        case .fadeIn, .fadeOut: return 0.22
        case .look: return 0.1
        case .grade: return 0.2
        case .transition: return 0.46
        }
    }

    /// The clip this edit happens on, for grouping and drawing.
    var clipID: UUID? { clipIDs.first }

    /// Every clip it changes.
    var clipIDs: [UUID] {
        switch self {
        case .place(let clips, _): return clips.map(\.id)
        case .trimHead(let ids, _, _), .trimTail(let ids, _, _), .move(let ids, _, _, _), .blade(let ids, _, _, _),
             .remove(let ids, _): return ids
        case .change(let id, _, _): return id.map { [$0] } ?? []
        case .type(let id, _), .gain(let id, _, _), .fadeIn(let id, _), .fadeOut(let id, _), .look(let id, _),
             .grade(let id, _, _), .transition(let id, _): return [id]
        }
    }

    var isGradeCard: Bool {
        switch self {
        case .look, .grade: return true
        default: return false
        }
    }

    /// Applies the edit, `p` of the way through.
    func apply(_ project: inout Project, _ p: Double) {
        let e = MagicEase.inOut(min(1, max(0, p)))
        func each(_ ids: [UUID], _ body: (inout Clip) -> Void) {
            for id in ids { if let i = project.index(of: id) { body(&project.clips[i]) } }
        }
        switch self {
        case .place(let clips, _):
            guard p >= 1 else { return }
            project.clips.append(contentsOf: clips)
            // Dropped on something: it overwrites it, as on the timeline.
            project.resolveOverlaps(keeping: Set(clips.map(\.id)))
        case .trimHead(let ids, let from, let to):
            let t = project.snapFrame(from + (to - from) * e)
            each(ids) { $0.trimHead(to: t) }
            if p >= 1 { project.resolveOverlaps(keeping: Set(ids)) }
        case .trimTail(let ids, let from, let to):
            let t = project.snapFrame(from + (to - from) * e)
            each(ids) { $0.trimTail(to: t) }
            if p >= 1 { project.resolveOverlaps(keeping: Set(ids)) }
        case .move(let ids, let from, let to, let tracks):
            let delta = project.snapFrame(from + (to - from) * e) - from
            each(ids) { c in
                c.start += delta
                if e >= 0.5, let t = tracks[c.id] { c.trackID = t }
            }
            if p >= 1 { project.resolveOverlaps(keeping: Set(ids)) }
        case .blade(let ids, let at, let pieces, let link):
            guard p >= 1 else { return }
            for id in ids {
                guard let i = project.index(of: id), let newID = pieces[id] else { continue }
                var right = project.clips[i]
                guard at > right.start, at < right.end else { continue }
                right.id = newID
                right.linkID = project.clips[i].linkID == nil ? nil : link
                right.fadeIn = 0
                right.trimHead(to: at)
                project.clips[i].fadeOut = 0
                project.clips[i].trimTail(to: at)
                project.clips.append(right)
            }
        case .remove(let ids, let ripple):
            guard p >= 1 else { return }
            project.remove(ids: Set(ids), ripple: ripple)
        case .change(_, _, let body):
            guard p >= 1 else { return }
            body(&project)
        case .type(let id, let text):
            let n = Int((Double(text.count) * min(1, max(0, p))).rounded(.down))
            each([id]) { $0.text.string = String(text.prefix(n)) }
        case .gain(let id, let from, let to):
            each([id]) { $0.gainDB = ((from + (to - from) * e) * 10).rounded() / 10 }
        case .fadeIn(let id, let to):
            each([id]) { $0.fadeIn = to * e; $0.clampFades() }
        case .fadeOut(let id, let to):
            each([id]) { $0.fadeOut = to * e; $0.clampFades() }
        case .look(let id, let name):
            // Grades change at the end of a drag: each new value re-grades the clip's thumbnails.
            guard p >= 1 else { return }
            each([id]) { var g = $0.grade ?? ColorGrade(); g.look = name; $0.grade = g }
        case .grade(let id, let key, let to):
            guard p >= 1 else { return }
            each([id]) { var g = $0.grade ?? ColorGrade(); key.set(&g, to); $0.grade = g }
        case .transition(let id, let t):
            guard p >= 0.85 else { return }
            each([id]) { $0.transitionIn = t }
        }
    }
}

enum MagicEase {
    static func inOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func out(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }
}

/// An edit with the edits that have to be finished before it can start.
struct MagicTask {
    var edit: MagicEdit
    var after: [Int] = []
    /// Extra wait after its dependencies are done, so a group of cursors arrives with a slight stagger.
    var delay = 0.0
}

/// A finished edit plan: the project to start from and the edits that build the cut.
struct MagicPlan {
    var base: Project
    var tasks: [MagicTask]

    /// The same edit, in the steps a person would take: a trim or a delete across several clips becomes
    /// one per clip (a video and its linked audio stay one step, as they'd be one click), each with its
    /// own cursor, side by side. Placing, the blade and moves stay whole: a moved group is dragged
    /// together, and moving its clips one at a time would let them run over each other on the way.
    func inSteps() -> MagicPlan {
        // Every clip's link, including clips made along the way.
        var links: [UUID: UUID] = [:]
        var p = base
        func note() { for c in p.clips { if let l = c.linkID { links[c.id] = l } } }
        note()
        for t in tasks { t.edit.apply(&p, 1); note() }
        func groups(_ ids: [UUID]) -> [[UUID]] {
            var out: [[UUID]] = []
            var at: [UUID: Int] = [:]
            for id in ids {
                if let l = links[id], let i = at[l] { out[i].append(id); continue }
                if let l = links[id] { at[l] = out.count }
                out.append([id])
            }
            return out
        }
        var out: [MagicTask] = []
        var newIndex: [[Int]] = []
        for t in tasks {
            let parts: [MagicEdit]
            switch t.edit {
            case .trimHead(let ids, let from, let to): parts = groups(ids).map { .trimHead($0, from: from, to: to) }
            case .trimTail(let ids, let from, let to): parts = groups(ids).map { .trimTail($0, from: from, to: to) }
            case .remove(let ids, let ripple): parts = groups(ids).map { .remove($0, ripple: ripple) }
            default: parts = [t.edit]
            }
            let after = t.after.flatMap { newIndex[$0] }
            var made: [Int] = []
            for (k, e) in parts.enumerated() {
                made.append(out.count)
                // Side by side, a touch apart.
                out.append(MagicTask(edit: e, after: after, delay: t.delay + Double(k) * 0.07))
            }
            newIndex.append(made)
        }
        return MagicPlan(base: base, tasks: out)
    }
}

/// Turns an edit decision into the edits the cursors perform, the way an editor would build it by
/// hand. A rough cut goes down first: shots long, in no particular order, on V2. Handles are trimmed
/// (some heads cut off with the blade) and each shot is dragged down into its place on V1. Then a
/// title, dissolves, sound levels and fades, and a grade on each shot as soon as it's in place.
enum Choreographer {
    static func plan(project: Project, decision: EditDecision) -> MagicPlan? {
        guard !decision.shots.isEmpty else { return nil }
        var base = project
        base.clips = []
        base.inPoint = nil
        base.outPoint = nil
        while base.videoTracks.count < 2 { base.videoTracks.append(Track(kind: .video)) }
        while base.audioTracks.count < (decision.music == nil ? 2 : 3) { base.audioTracks.append(Track(kind: .audio)) }
        for i in base.videoTracks.indices { base.videoTracks[i].locked = false }
        for i in base.audioTracks.indices { base.audioTracks[i].locked = false }
        let v1 = base.videoTracks[0].id, v2 = base.videoTracks[1].id
        let a1 = base.audioTracks[0].id, a2 = base.audioTracks[1].id
        let fps = base.fps
        func frames(_ t: Double) -> Double { (t * fps).rounded() / fps }
        var rng = SeededRandom(seed: UInt64(decision.shots.count * 7919 + project.assets.count))

        // Where each shot ends up on V1: cuts on whole frames, as close to the plan (the beat) as can be.
        let shots = decision.shots
        var finalStart: [Double] = []
        var finalLength: [Double] = []
        var t = 0.0
        for s in shots {
            let a = frames(t), b = frames(t + s.duration)
            finalStart.append(a)
            finalLength.append(max(1 / fps, b - a))
            t += s.duration
        }
        let total = frames(t)

        // Handles: shots go down long and get trimmed, with what the file has either side.
        var head: [Double] = [], tail: [Double] = []
        for (i, s) in shots.enumerated() {
            var h = 0.35 + rng.next() * 0.45, tl = 0.35 + rng.next() * 0.5
            if s.asset.kind == .video {
                h = min(h, s.source)
                tl = min(tl, s.asset.duration - s.source - finalLength[i])
            }
            head.append(max(0, (h * fps).rounded(.down) / fps))
            tail.append(max(0, (tl * fps).rounded(.down) / fps))
        }

        // The rough cut: the same shots, long, shuffled, one after another on V2.
        var rough = Array(shots.indices)
        for i in stride(from: rough.count - 1, to: 0, by: -1) { rough.swapAt(i, Int(rng.next() * Double(i + 1))) }
        var roughStart = Array(repeating: 0.0, count: shots.count)
        t = 0
        for i in rough { roughStart[i] = t; t += head[i] + finalLength[i] + tail[i] }

        var tasks: [MagicTask] = []
        func add(_ e: MagicEdit, after: [Int] = [], delay: Double = 0) -> Int {
            tasks.append(MagicTask(edit: e, after: after, delay: delay))
            return tasks.count - 1
        }

        // Music first, so it's under everything from the start.
        if let m = decision.music {
            var c = Clip(trackID: base.audioTracks[2].id, kind: .audio, assetID: m.asset.id, start: 0, duration: frames(m.duration))
            c.sourceStart = m.source
            let p = add(.place([c], asset: m.asset.id))
            _ = add(.fadeIn(c.id, to: 0.3), after: [p], delay: 0.1)
            _ = add(.fadeOut(c.id, to: min(m.fadeOut, m.duration / 3)), after: [p], delay: 0.2)
            _ = add(.gain(c.id, from: 0, to: -2), after: [p], delay: 0.4)
        }

        struct Cut { var video: UUID; var audio: UUID?; var moved: Int; var roughFrom: Double }
        var cuts = Array(repeating: Cut(video: UUID(), audio: nil, moved: 0, roughFrom: 0), count: shots.count)
        for (order, i) in rough.enumerated() {
            let s = shots[i]
            let r = roughStart[i]
            let long = head[i] + finalLength[i] + tail[i]
            var v = Clip(trackID: v2, kind: s.asset.kind == .image ? .image : .video, assetID: s.asset.id, start: r, duration: long)
            v.sourceStart = s.asset.kind == .image ? 0 : s.source - head[i]
            var group = [v]
            if s.asset.kind == .video, s.asset.hasAudio {
                let link = UUID()
                group[0].linkID = link
                var au = Clip(trackID: a2, kind: .audio, assetID: s.asset.id, start: r, duration: long)
                au.sourceStart = v.sourceStart
                au.linkID = link
                group.append(au)
            }
            var ids = group.map(\.id)
            let place = add(.place(group, asset: s.asset.id), delay: Double(order) * 0.09 + rng.next() * 0.25)
            var ready = [place]
            let headAt = r + head[i]
            if head[i] > 0.2, i % 3 == 1 {
                // Cut the head off with the blade and delete it.
                var pieces: [UUID: UUID] = [:]
                for id in ids { pieces[id] = UUID() }
                let blade = add(.blade(ids, at: headAt, pieces: pieces, link: UUID()), after: [place])
                let remove = add(.remove(ids), after: [blade], delay: 0.03)
                ids = ids.map { pieces[$0]! }
                ready = [blade, remove]
            } else if head[i] > 0.5 / fps {
                ready.append(add(.trimHead(ids, from: r, to: headAt), after: [place]))
            }
            if tail[i] > 0.5 / fps {
                ready.append(add(.trimTail(ids, from: r + long, to: headAt + finalLength[i]), after: ready, delay: 0.02))
            }
            var tracks = [ids[0]: v1]
            if ids.count > 1 { tracks[ids[1]] = a1 }
            let moved = add(.move(ids, from: headAt, to: finalStart[i], tracks: tracks), after: ready)
            cuts[i] = Cut(video: ids[0], audio: ids.count > 1 ? ids[1] : nil, moved: moved, roughFrom: headAt)
        }

        // A title on V2 once the rough cut has cleared from under it (only one they asked for).
        if !decision.title.isEmpty {
            let titleLength = min(3, max(2, total * 0.12))
            // At the start, or over the last seconds when they asked for it at the end.
            let titleStart = decision.titleAtEnd ? frames(max(0, total - titleLength)) : 0
            // (At the end: once every shot has settled, since the rough cut can run on past it.)
            let clearing = decision.titleAtEnd ? cuts.map(\.moved) : cuts.filter { $0.roughFrom < titleLength }.map(\.moved)
            var title = Clip(trackID: v2, kind: .text, start: titleStart, duration: frames(titleLength))
            title.text.string = ""
            title.text.size = 130
            let placed = add(.place([title], asset: nil), after: clearing)
            let typed = add(.type(title.id, decision.title), after: [placed])
            _ = add(.fadeIn(title.id, to: 0.4), after: [typed])
            _ = add(.fadeOut(title.id, to: 0.5), after: [typed], delay: 0.05)
        }

        for (i, c) in cuts.enumerated() {
            let s = shots[i]
            // Sound: the shot's level, with little fades on and off.
            if let a = c.audio {
                if s.gainDB != 0 { _ = add(.gain(a, from: 0, to: s.gainDB), after: [c.moved], delay: 0.03) }
                _ = add(i % 2 == 0 ? .fadeIn(a, to: 0.2) : .fadeOut(a, to: 0.25), after: [c.moved], delay: 0.08)
            }
            // Dissolves picked from the right-click menu.
            if i > 0, s.dissolve {
                _ = add(.transition(c.video, Transition(kind: .dissolve, duration: 0.5)), after: [c.moved, cuts[i - 1].moved], delay: 0.1)
            }
            // The last shot fades to black.
            if i == cuts.count - 1 { _ = add(.fadeOut(c.video, to: 0.6), after: [c.moved], delay: 0.12) }
            // Colour only where it's wanted, as soon as the shot is in place: the look they asked for (with a
            // little punch), and exposure for a shot clearly darker or brighter than the rest.
            if !decision.look.isEmpty {
                _ = add(.look(c.video, name: decision.look), after: [c.moved], delay: 0.1)
                _ = add(.grade(c.video, .contrast, to: 12), after: [c.moved], delay: 0.15)
                _ = add(.grade(c.video, .saturation, to: 18), after: [c.moved], delay: 0.175)
            }
            if abs(s.exposure) >= 0.2 { _ = add(.grade(c.video, .exposure, to: s.exposure), after: [c.moved], delay: 0.125) }
        }
        return MagicPlan(base: base, tasks: tasks)
    }
}

/// Repeatable randomness, so the same media always gives the same cut.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}
