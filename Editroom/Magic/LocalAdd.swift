import Foundation

/// Local's "add one more clip to the end", "add two shots at the beginning", "add one after @selected", "add @Beach
/// before the third clip", "add a clip at 0:12": clips put into the edit that's there, where they ask. What comes
/// after moves along to make room (a clip that's there is cut in two first). Files named in the request are used;
/// otherwise library clips not in the edit yet, in library order. Each is a shot as long as the edit's own
/// (2–5 seconds), from the middle of its file.
@MainActor
enum LocalAdd {
    static func asks(_ request: String, project p: Project) -> Bool {
        let t = " " + request.lowercased() + " "
        let verb = [" add ", " put ", " append ", " insert ", " stick ", " throw in ", " include "].contains { t.contains($0) }
        let thing = [" clip", " shot", " video", " photo", " picture", " image"].contains { t.contains($0) }
        let more = [" more ", " another ", " extra ", " end", " start", " beginning", " begin", " front", " last", " first",
                    " after ", " before ", " between ", "playhead", "selected", " here", "@"].contains { t.contains($0) }
        let hasEdit = p.clips.contains { $0.kind == .video || $0.kind == .image }
        // A new cut ("make a new video with 5 clips") is Local's cut, not clips added to this one.
        let newCut = ["new cut", "new edit", "new video", "montage", "recut", "re-cut", "from scratch", "start over",
                      "make a", "make an", "make me", "create", "build a"].contains { t.contains($0) }
        return verb && thing && more && hasEdit && !newCut
    }

    /// How many they asked for ("one more", "two shots", "3 clips"); one when it doesn't say.
    static func count(_ request: String) -> Int {
        let words = request.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let named = ["one": 1, "a": 1, "an": 1, "another": 1, "two": 2, "couple": 2, "three": 3, "few": 3, "four": 4, "five": 5,
                     "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
        for (i, w) in words.enumerated() {
            guard i + 1 < words.count || Int(w) != nil else { continue }
            let rest = words[(i + 1)...].prefix(3)
            guard rest.contains(where: { ["clip", "clips", "shot", "shots", "video", "videos", "photo", "photos", "more"].contains($0) }) else { continue }
            if let n = Int(w) { return min(max(n, 1), 20) }
            if let n = named[w] { return n }
        }
        return 1
    }

    /// Where the new clips go: a time on the timeline, and how to say it.
    struct Spot {
        var time: Double
        var label: String
    }

    private static let ordinals = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
                                   "eighth": 8, "ninth": 9, "tenth": 10]

    /// Where they mean: before or after a clip they point at (@selected, @clip:, a file in the edit, "the third
    /// clip", "the last shot"), a marker, the playhead, a typed time, the start; the end when nothing says.
    static func spot(request: String, typed: String, pointers: MagicPointers, project p: Project) -> Spot {
        let t = " " + typed.lowercased() + " "
        let visual = p.clips.filter { $0.kind == .video || $0.kind == .image }
        let story = visual.filter { $0.trackID == p.videoTracks.first?.id }.sorted { $0.start < $1.start }
        let shots = story.isEmpty ? visual.sorted { $0.start < $1.start } : story
        let first = visual.map(\.start).min() ?? 0, last = visual.map(\.end).max() ?? 0
        let before = [" before ", " in front of ", " ahead of ", " just before "].contains { t.contains($0) }
        func around(_ clips: [Clip], _ what: String) -> Spot? {
            let seen = clips.filter { $0.kind != .audio }
            let use = seen.isEmpty ? clips : seen
            guard let a = use.map(\.start).min(), let b = use.map(\.end).max() else { return nil }
            return before ? Spot(time: a, label: "before " + what) : Spot(time: b, label: "after " + what)
        }

        // Pointed at with @.
        let ns = typed as NSString
        for (range, m) in MagicMention.find(in: typed, media: p.assets, clips: MagicMention.clipLabels(p), markers: MagicMention.markerLabels(p)) {
            switch m {
            case .selected:
                let picked = p.clips.filter { pointers.selected.contains($0.id) }
                if let s = around(picked, picked.filter { $0.kind != .audio }.count > 1 ? "the selected clips" : "the selected clip") { return s }
            case .clip(let id):
                if let c = p.clip(id), let s = around([c], p.name(of: c)) { return s }
            case .marker(let id):
                if let mk = p.markerList.first(where: { $0.id == id }) { return Spot(time: mk.time, label: "at the marker") }
            case .playhead:
                return Spot(time: pointers.playhead, label: "at the playhead")
            case .media(let id):
                // "after @Beach": a file already in the edit, as a place (the other files named are what to add).
                let lead = ns.substring(to: range.location).lowercased().suffix(16)
                guard lead.contains("after") || lead.contains("before") || lead.contains("front of") || lead.contains("ahead of") else { continue }
                let uses = visual.filter { $0.assetID == id }.sorted { $0.start < $1.start }
                if let c = before ? uses.first : uses.last, let s = around([c], p.asset(id)?.name ?? "it") { return s }
            case .range:
                if let r = pointers.range { return before ? Spot(time: r.start, label: "before the marked range") : Spot(time: r.end, label: "after the marked range") }
            case .folder:
                continue
            }
        }
        // "the selected clip" in words.
        if t.contains("selected"), !pointers.selected.isEmpty {
            let picked = p.clips.filter { pointers.selected.contains($0.id) }
            if let s = around(picked, "the selected clip") { return s }
        }
        // "the third clip", "clip 2", "the last shot".
        let words = t.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for (i, w) in words.enumerated() where i + 1 < words.count && ["clip", "shot"].contains(where: { words[i + 1].hasPrefix($0) }) {
            var n = ordinals[w] ?? Int(w.filter(\.isNumber)).flatMap { w.hasSuffix("st") || w.hasSuffix("nd") || w.hasSuffix("rd") || w.hasSuffix("th") ? $0 : nil }
            if w == "last" { n = shots.count }
            guard let k = n, k >= 1, k <= shots.count else { continue }
            let pointed = t.contains(" after ") || t.contains(" before ") || t.contains(" in front of ")
            if !pointed { return k == 1 ? Spot(time: first, label: "at the start") : Spot(time: last, label: "at the end") }
            if let s = around([shots[k - 1]], w == "last" ? "the last clip" : "clip \(k)") { return s }
        }
        for (i, w) in words.enumerated() where w == "clip" || w == "shot" {
            guard i + 1 < words.count, let k = Int(words[i + 1]), k >= 1, k <= shots.count, t.contains(" after ") || t.contains(" before ") else { continue }
            if let s = around([shots[k - 1]], "clip \(k)") { return s }
        }
        if t.contains("playhead") || t.contains(" here ") { return Spot(time: pointers.playhead, label: "at the playhead") }
        // A typed time: "at 0:12", "at 12s".
        if let at = MagicTimes.times(in: request, fps: p.fps).first(where: { typedTime in
            !typedTime.unitOnly || (request as NSString).substring(to: typedTime.range.location).lowercased().hasSuffix("at ")
        }) {
            return Spot(time: min(max(first, at.seconds), last), label: "at " + MagicMention.clock(at.seconds))
        }
        if [" beginning", " begin", " start", " front", " opening", " open with", " first "].contains(where: { t.contains($0) }) {
            return Spot(time: first, label: "at the start")
        }
        return Spot(time: last, label: "at the end")
    }

    static func plan(request: String, typed: String, pointers: MagicPointers, project p: Project) -> LocalPointed.Outcome {
        let visual = p.clips.filter { $0.kind == .video || $0.kind == .image }
        guard !visual.isEmpty else { return LocalPointed.Outcome(said: "There's no edit on the timeline to add to.") }
        let spot = spot(request: request, typed: typed, pointers: pointers, project: p)
        let at = p.snapFrame(spot.time)

        // The files they named to add (not ones named as the place); else what isn't in the edit yet.
        let ns = typed as NSString
        let folders = MagicMention.folderLabels(p)
        let named = MagicMention.find(in: typed, media: p.assets, folders: folders).flatMap { (range, m) -> [UUID] in
            let lead = ns.substring(to: range.location).lowercased().suffix(16)
            let place = lead.contains("after") || lead.contains("before") || lead.contains("front of") || lead.contains("ahead of")
            switch m {
            case .media(let id): return place ? [] : [id]
            // Every file in a folder they named.
            case .folder(let path, let only): return folders.first { $0.path == path }?.files(for: typed, only: only) ?? []
            default: return []
            }
        }
        let used = Set(p.clips.compactMap(\.assetID))
        let pool = named.isEmpty
            ? p.assets.filter { ($0.kind == .video || $0.kind == .image) && !used.contains($0.id) }.map(\.id)
            : named.filter { id in p.asset(id).map { $0.kind != .audio } ?? false }
        guard !pool.isEmpty else {
            return LocalPointed.Outcome(said: named.isEmpty
                ? "Every clip in your library is already in the edit. Import more, or name the one to use with @."
                : "Those are sound files, not clips to show.")
        }
        let n = named.isEmpty ? min(count(request), pool.count) : pool.count

        // As long as the edit's shots (their middle length), 2 to 5 seconds.
        let lengths = visual.map(\.duration).sorted()
        let typical = min(5, max(2, lengths[lengths.count / 2]))
        let v1 = p.videoTracks[0].id
        var shots: [Clip] = []
        var end = at
        for id in pool.prefix(n) {
            guard let asset = p.asset(id) else { continue }
            let d = p.snapFrame(asset.kind == .image ? typical : min(typical, asset.duration))
            guard d > 0 else { continue }
            let source = asset.kind == .image ? 0 : max(0, (asset.duration - d) / 2)
            var v = Clip(trackID: v1, kind: asset.kind == .image ? .image : .video, assetID: id, start: end, duration: d, sourceStart: source)
            if asset.kind == .video, asset.hasAudio {
                let link = UUID()
                v.linkID = link
                var a = Clip(trackID: p.audioTracks[0].id, kind: .audio, assetID: id, start: end, duration: d, sourceStart: source)
                a.linkID = link
                shots += [v, a]
            } else {
                shots.append(v)
            }
            end += d
        }
        guard !shots.isEmpty else { return LocalPointed.Outcome(said: "Those clips are too short to use.") }
        let added = end - at

        var edits: [MagicEdit] = []
        // A clip on V1 running across the spot (and its sound) is cut in two there.
        let crossing = p.clips.filter { c in
            c.start < at - 1e-6 && c.end > at + 1e-6 && !p.isLocked(c.trackID) && (c.trackID == v1 || p.linked([c.id]).contains { id in p.clip(id)?.trackID == v1 })
        }
        var pieces: [UUID: UUID] = [:]
        for c in crossing { pieces[c.id] = UUID() }
        if !crossing.isEmpty { edits.append(.blade(crossing.map(\.id), at: at, pieces: pieces, link: UUID())) }
        // Everything from the spot on moves along to make room.
        let later = p.clips.filter { $0.start >= at - 1e-6 && !p.isLocked($0.trackID) }.map(\.id) + Array(pieces.values)
        if !later.isEmpty { edits.append(.move(later, from: at, to: at + added, tracks: [:])) }

        // The new clips' sound on A1 if it's free there by then; else a free audio track, or a new one.
        var after = p
        for e in edits { e.apply(&after, 1) }
        func free(_ track: UUID) -> Bool { !after.clips.contains { $0.trackID == track && $0.start < end - 1e-6 && $0.end > at + 1e-6 } }
        if shots.contains(where: { $0.kind == .audio }), !free(p.audioTracks[0].id) {
            let track: UUID
            if let open = p.audioTracks.first(where: { !$0.locked && free($0.id) }) {
                track = open.id
            } else {
                track = UUID()
                edits.append(.change(nil, "Add audio track") { q in
                    var t = Track(kind: .audio)
                    t.id = track
                    q.audioTracks.append(t)
                })
            }
            for i in shots.indices where shots[i].kind == .audio { shots[i].trackID = track }
        }
        // One file at a time, dragged in from the library.
        var placed: [Clip] = []
        for c in shots where c.kind != .audio {
            let pair = [c] + shots.filter { $0.kind == .audio && $0.linkID != nil && $0.linkID == c.linkID }
            edits.append(.place(pair, asset: c.assetID))
            placed.append(c)
        }
        let names = placed.compactMap { p.asset($0.assetID)?.name }
        let list = names.count <= 3 ? names.joined(separator: ", ") : "\(names.count) clips"
        let said = "Added \(list) \(spot.label), \(String(format: "%.1f", added)) seconds."
        return LocalPointed.Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: said)
    }
}
