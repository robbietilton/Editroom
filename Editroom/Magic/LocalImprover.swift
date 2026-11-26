import Foundation

/// Local Magic on a timeline that already has an edit: makes that edit better instead of starting
/// over, with no AI. It keeps the person's shots, order and music, and:
/// - takes out repeats (the same part of the same file twice) and the weakest shots;
/// - trims long shots to their best moment, inside the part already chosen;
/// - with music, puts every cut on a beat and ends on a bar (and trims and fades the song to fit);
/// - closes the gaps;
/// - gives every shot the look most of them already have, evens out exposure, and sets the sound
///   (clips under the music, fades in and out).
/// The result is a list of ordinary Magic edits, played by the swarm as one undo step.
@MainActor
enum LocalImprover {
    struct Outcome {
        var plan: MagicPlan
        /// What changed, in a sentence, for the log and the note.
        var summary: String
        /// What it couldn't do of what was asked.
        var notes: [String] = []
        /// It did just what was asked (named media), rather than a general improvement.
        var focused = false
        /// The whole reply, when there's nothing to summarise (it chose not to change anything).
        var message: String?
    }

    /// `recipe` is what the person asked for (from Apple's on-device model), if anything. `newSong` is a song
    /// from the library to put under the edit when they asked for music and it has none; `music` is then
    /// that song's beats (otherwise the beats of the song already on the timeline).
    static func plan(project p: Project, analyses: [UUID: ClipAnalysis], music: MusicAnalysis?,
                     recipe: LocalRecipe = .plain, newSong: MediaAsset? = nil) -> Outcome? {
        /// Each audio clip still on the timeline at the level the request asked for (a drag of its level).
        func levelEdits(_ q: Project) -> [MagicEdit] {
            q.clips.compactMap { c in
                guard let g = recipe.levelGains[c.id], abs(g - c.gainDB) > 0.05 else { return nil }
                return .gain(c.id, from: c.gainDB, to: g)
            }
        }
        func levelPart(_ edits: [MagicEdit]) -> String {
            let n = edits.filter { if case .gain = $0 { return true } else { return false } }.count
            let silent = recipe.levelSilent.isEmpty ? ""
                : L10n.fmt(" (%@ had no sound and were left unchanged)", recipe.levelSilent.joined(separator: ", "))
            return L10n.fmt("set %lld audio clips to the same level", n) + silent
        }
        // Only the audio levels (and maybe a look): just that.
        if recipe.onlyLevels {
            var edits = levelEdits(p)
            if let look = recipe.look, look != "none" {
                for c in p.clips where (c.kind == .video || c.kind == .image) && c.grade?.look != look { edits.append(.look(c.id, name: look)) }
            }
            if recipe.levelGains.isEmpty {
                return Outcome(plan: MagicPlan(base: p, tasks: []), summary: "", focused: true,
                               message: L10n.tr("There's no audio on the timeline to level."))
            }
            guard !edits.isEmpty else {
                return Outcome(plan: MagicPlan(base: p, tasks: []), summary: "", focused: true,
                               message: L10n.tr("Your audio clips are already at the same level."))
            }
            var parts = levelEdits(p).isEmpty ? [] : [levelPart(edits)]
            if let look = recipe.look, look != "none" { parts.append(L10n.fmt("one look (%@)", BuiltInLook.displayName(look))) }
            return Outcome(plan: MCPDraft.plan(base: p, edits: edits), summary: parts.joined(separator: L10n.tr(", ")), focused: true)
        }
        // The main picture track: the lowest video track with shots on it.
        guard let track = p.videoTracks.first(where: { t in p.clips.contains { $0.trackID == t.id && isShot($0) } }),
              !p.isLocked(track.id) else { return nil }
        let shots = p.clips.filter { $0.trackID == track.id && isShot($0) }.sorted { $0.start < $1.start }
        guard !shots.isEmpty else { return nil }

        let all = shots.compactMap { $0.assetID.flatMap { analyses[$0] } }.flatMap(\.samples)
        let score = all.isEmpty ? { (_: ClipAnalysis.Sample) in 0.5 } : AutoPlanner.scorer(all)
        let fps = p.fps
        func frames(_ t: Double) -> Double { (t * fps).rounded() / fps }

        /// The part of the file a shot plays, in file time.
        func sourceRange(_ c: Clip) -> ClosedRange<Double> { c.sourceStart...(c.sourceStart + c.sourceLength) }

        /// The best window of `length` (timeline seconds) inside a shot's current part of its file.
        func best(_ c: Clip, length: Double) -> (sourceStart: Double, score: Double) {
            guard c.kind == .video, let id = c.assetID, let a = analyses[id], !a.samples.isEmpty else {
                return (c.sourceStart, shotScore(c))
            }
            let r = sourceRange(c), span = length * c.speed
            var bestStart = c.sourceStart, bestScore = -Double.infinity
            var s = r.lowerBound
            while s + span <= r.upperBound + 1e-6 {
                let inside = a.samples.filter { $0.time >= s && $0.time <= s + span }.map(score)
                if !inside.isEmpty {
                    let v = inside.reduce(0, +) / Double(inside.count) * 0.75 + (inside.min() ?? 0) * 0.25
                    if v > bestScore { bestScore = v; bestStart = s }
                }
                s += 0.1
            }
            return (bestStart, bestScore.isFinite ? bestScore : shotScore(c))
        }

        func shotScore(_ c: Clip) -> Double {
            guard let id = c.assetID, let a = analyses[id] else { return 0.5 }
            let r = sourceRange(c)
            let inside = a.samples.filter { c.kind == .image || r.contains($0.time) }.map(score)
            return inside.isEmpty ? 0.5 : inside.reduce(0, +) / Double(inside.count)
        }

        // A speed for every shot: that (with any look or frame shape asked for too), and nothing else. Changing
        // speed keeps each track's clips butted up, so nothing needs moving.
        if let speed = recipe.speed {
            var edits: [MagicEdit] = []
            let ids = p.unlocked(p.linked(Set(shots.map(\.id))))
            if shots.contains(where: { $0.kind == .video && abs($0.speed - speed) > 1e-3 }) {
                edits.append(.change(shots.first!.id, L10n.fmt("Speed ×%g", speed)) { q in q.setSpeed(ids: ids, speed: speed) })
            }
            if let look = recipe.look, look != "none" {
                for c in shots where c.grade?.look != look { edits.append(.look(c.id, name: look)) }
            }
            var q = p
            for e in edits { e.apply(&q, 1) }
            let levels = levelEdits(q)
            edits += levels
            guard !edits.isEmpty else { return nil }
            let before = (shots.map(\.end).max() ?? 0) - shots.first!.start
            let after = (q.clips.filter { $0.trackID == track.id }.map(\.end).max() ?? 0) - shots.first!.start
            var parts = [L10n.fmt("set every clip to %g%% speed (%.1fs to %.1fs)", speed * 100, before, after)]
            if let look = recipe.look { parts.append(L10n.fmt("one look (%@)", BuiltInLook.displayName(look))) }
            if !levels.isEmpty { parts.append(levelPart(levels)) }
            return Outcome(plan: MCPDraft.plan(base: p, edits: edits), summary: parts.joined(separator: L10n.tr(", ")), focused: true)
        }

        // 0. Media they named: only those, or not those. A request like that is done on its own: nothing
        // else unasked (no repeats or weak shots out, no trimming, no look), just the gaps closed.
        let focused = recipe.isFocused
        var keep = shots
        var dropped: [Clip] = []
        if !recipe.keepOnly.isEmpty {
            dropped += keep.filter { !recipe.keepOnly.contains($0.assetID ?? UUID()) }
            keep.removeAll { !recipe.keepOnly.contains($0.assetID ?? UUID()) }
        }
        if !recipe.takeOut.isEmpty {
            dropped += keep.filter { recipe.takeOut.contains($0.assetID ?? UUID()) }
            keep.removeAll { recipe.takeOut.contains($0.assetID ?? UUID()) }
        }
        let named = dropped.count
        guard !keep.isEmpty else { return nil }

        // 1. Repeats: the same file, mostly the same part. Keep the better-scoring one.
        var i = focused ? keep.count : 0
        while i < keep.count {
            var j = i + 1
            while j < keep.count {
                let a = keep[i], b = keep[j]
                if a.assetID != nil, a.assetID == b.assetID, a.kind == b.kind {
                    let ra = sourceRange(a), rb = sourceRange(b)
                    let overlap = max(0, min(ra.upperBound, rb.upperBound) - max(ra.lowerBound, rb.lowerBound))
                    let shorter = max(0.01, min(ra.upperBound - ra.lowerBound, rb.upperBound - rb.lowerBound))
                    if a.kind == .image || overlap / shorter > 0.5 {
                        if shotScore(b) > shotScore(a) { dropped.append(a); keep[i] = b; keep.remove(at: j); continue }
                        dropped.append(b); keep.remove(at: j); continue
                    }
                }
                j += 1
            }
            i += 1
        }
        let repeats = dropped.count - named

        // 2. The weakest shots, when there are enough to spare: at most a quarter, never below four.
        if keep.count > 4, !focused {
            let scores = keep.map(shotScore)
            let floor = AutoPlanner.percentile(scores, 0.15) - 0.05
            let weak = keep.indices.filter { scores[$0] < floor }.sorted { scores[$0] < scores[$1] }
            let canDrop = min(weak.count, keep.count / 4, keep.count - 4)
            let gone = Set(weak.prefix(canDrop).map { keep[$0].id })
            dropped += keep.filter { gone.contains($0.id) }
            keep.removeAll { gone.contains($0.id) }
        }
        // Back in timeline order (keeping the better of a repeat can swap which one stays).
        keep.sort { $0.start < $1.start }

        // 3. How long each shot plays, never longer than now: long ones come down to about their best 60%
        // (calm keeps more, fast keeps less).
        func paced(_ c: Clip) -> Double {
            switch recipe.pace {
            case .calm: return c.duration > 6 ? max(4, c.duration * 0.8) : c.duration
            case .fast: return c.duration > 2 ? max(1.2, min(2.5, c.duration * 0.5)) : c.duration
            case .unchanged:
                if focused { return c.duration }
                return c.duration > 3.5 ? min(c.duration, max(2.5, min(4.5, c.duration * 0.6))) : c.duration
            }
        }
        // A length they asked for. Shorter: the weakest shots go while even shorter shots couldn't get
        // there, then every shot comes down evenly. Longer than the shots are now: they grow into the rest
        // of their files, the best parts.
        var notes: [String] = []
        var planned = Dictionary(keep.map { ($0.id, paced($0)) }, uniquingKeysWith: { a, _ in a })
        var growing = false
        /// The whole file, at the clip's speed.
        func fileLength(_ c: Clip) -> Double {
            c.kind == .image ? 30 : max(c.duration, (p.asset(c.assetID ?? UUID())?.duration ?? c.duration) / max(0.01, c.speed))
        }
        if let target = recipe.seconds {
            var pacedTotal = keep.map(paced).reduce(0, +)
            while pacedTotal * 0.6 > target, keep.count > 2,
                  let weakest = keep.indices.min(by: { shotScore(keep[$0]) < shotScore(keep[$1]) }) {
                dropped.append(keep.remove(at: weakest))
                pacedTotal = keep.map(paced).reduce(0, +)
            }
            let nowTotal = keep.map(\.duration).reduce(0, +)
            if target <= pacedTotal {
                for c in keep { planned[c.id] = max(0.8, paced(c) * target / max(0.01, pacedTotal)) }
            } else if target <= nowTotal {
                // Between the trimmed and the current lengths.
                let f = (target - pacedTotal) / max(0.01, nowTotal - pacedTotal)
                for c in keep { planned[c.id] = paced(c) + (c.duration - paced(c)) * f }
            } else {
                growing = true
                var lengths = Dictionary(keep.map { ($0.id, $0.duration) }, uniquingKeysWith: { a, _ in a })
                var need = target - nowTotal
                for _ in 0..<6 where need > 0.05 {
                    let open = keep.filter { fileLength($0) - lengths[$0.id]! > 0.05 }
                    guard !open.isEmpty else { break }
                    let share = need / Double(open.count)
                    for c in open {
                        let add = min(share, fileLength(c) - lengths[c.id]!)
                        lengths[c.id]! += add
                        need -= add
                    }
                }
                planned = lengths
                if need > 0.5 {
                    notes.append(L10n.fmt("the requested length is %lld seconds, but the footage adds up to about %lld seconds",
                                          Int(target), Int((target - need).rounded())))
                }
            }
        }
        func wanted(_ c: Clip) -> Double { planned[c.id] ?? paced(c) }
        let weakOut = dropped.count - repeats - named

        // The song: the longest sound-only clip from a music file; none if they asked for no music; or a
        // song from the library put under the edit if they asked for music and there wasn't any.
        let songOnTimeline = p.clips.filter { $0.kind == .audio && $0.linkID == nil && p.asset($0.assetID ?? UUID()).map { $0.kind == .audio && $0.duration >= 8 } == true }
            .max { $0.duration < $1.duration }
        // Where the edit starts: where its first shot was, even if that shot is gone.
        let firstStart = shots.first!.start
        var song = recipe.music == .off ? nil : songOnTimeline
        var placing: Clip?
        if recipe.music == .add, songOnTimeline == nil, let newSong, let m = music {
            // From its first bar, so the cut starts on a downbeat.
            let bar = m.beats.indices.first { m.isBarStart($0) }.map { m.beats[$0] } ?? 0
            var c = Clip(trackID: UUID(), kind: .audio, assetID: newSong.id, start: firstStart, duration: max(1, newSong.duration - bar))
            c.sourceStart = bar
            placing = c
            song = c
        } else if recipe.music == .add, songOnTimeline == nil {
            notes.append(L10n.tr("there's no music in your Media to add"))
        }
        var cuts: [Double] = [firstStart]   // where each kept shot starts, then where the last one ends
        var lengths: [Double] = []
        // Cut to the beat, unless it's a focused request that didn't ask for a length or pace.
        let snap = !focused || recipe.seconds != nil || recipe.pace != .unchanged || placing != nil
        if snap, let song, let m = music, m.beats.count > 8 {
            // Beats on the timeline.
            let beats = m.beats.map { song.start + ($0 - song.sourceStart) / max(0.01, song.speed) }.filter { $0 > firstStart + 0.2 }
            let minLen = max(0.8, 2 * m.period)
            for (k, c) in keep.enumerated() {
                let last = k == keep.count - 1
                let from = cuts.last!
                let target = from + wanted(c)
                // A beat near where it wants to end, no later than the shot can go (the last shot may stretch
                // to reach a bar, as far as its file allows).
                let room = growing ? fileLength(c) : last ? (c.kind == .image ? 3600 : sourceRoom(c, p)) : c.duration
                let options = beats.enumerated().filter { $0.element >= from + minLen - 1e-6 && $0.element <= from + room + 1e-6 }
                let pick: Double
                if last {
                    // End on a bar: the bar start nearest the target that it can reach.
                    let bars = options.filter { m.isBarStart(beatIndex($0.offset, of: $0.element, in: m, song: song)) }
                    pick = (bars.min { abs($0.element - target) < abs($1.element - target) }
                            ?? options.min { abs($0.element - target) < abs($1.element - target) })?.element ?? from + min(wanted(c), room)
                } else {
                    pick = options.min { abs($0.element - target) < abs($1.element - target) }?.element ?? from + wanted(c)
                }
                lengths.append(frames(pick - from))
                cuts.append(from + lengths.last!)
            }
        } else {
            for c in keep {
                lengths.append(frames(wanted(c)))
                cuts.append(cuts.last! + lengths.last!)
            }
        }
        let newEnd = cuts.last!
        let oldEnd = shots.map(\.end).max() ?? newEnd

        // 4. The edits, in an order that's always safe: the frame shape first; repeats and weak shots out;
        // then each shot trimmed to its moment and slid left into place, left to right.
        var edits: [MagicEdit] = []
        let size: (Int, Int)? = switch recipe.frame {
        case .vertical: (1080, 1920)
        case .horizontal: (1920, 1080)
        case .square: (1080, 1080)
        case .unchanged: nil
        }
        if let size, p.width != size.0 || p.height != size.1 {
            edits.append(.change(nil, recipe.frame.rawValue.capitalized) { q in
                q.width = size.0
                q.height = size.1
                q.settingsLocked = true
            })
        }
        for c in dropped {
            edits.append(.remove(Array(p.unlocked(p.linked([c.id])))))
        }
        var trimmed = 0
        if growing {
            // Longer shots can't slide into place without landing on each other, so they're lifted off and
            // laid back down at their new lengths, each the best part of its file that long.
            for c in keep { edits.append(.remove(Array(p.unlocked(p.linked([c.id]))))) }
            for (k, c) in keep.enumerated() {
                let length = lengths[k]
                var from = c.sourceStart
                if c.kind == .video, let id = c.assetID, let a = analyses[id], let asset = p.asset(id) {
                    let span = length * c.speed
                    var bestScore = -Double.infinity
                    var s0 = 0.0
                    while s0 + span <= asset.duration + 1e-6 {
                        let inside = a.samples.filter { $0.time >= s0 && $0.time <= s0 + span }.map(score)
                        if !inside.isEmpty {
                            // The best, nudged towards where the shot already was.
                            let v = inside.reduce(0, +) / Double(inside.count) * 0.75 + (inside.min() ?? 0) * 0.25 - abs(s0 - c.sourceStart) * 0.01
                            if v > bestScore { bestScore = v; from = s0 }
                        }
                        s0 += 0.1
                    }
                    if !bestScore.isFinite { from = min(c.sourceStart, max(0, asset.duration - span)) }
                }
                let group = p.clips.filter { $0.id == c.id || (c.linkID != nil && $0.linkID == c.linkID) }.map { g -> Clip in
                    var n = g
                    n.start = frames(cuts[k])
                    n.duration = frames(length)
                    if n.kind != .image { n.sourceStart = from }
                    n.clampFades()
                    return n
                }
                edits.append(.place(group, asset: c.assetID))
                trimmed += 1
            }
        }
        for (k, c) in keep.enumerated() where !growing {
            let ids = Array(p.unlocked(p.linked([c.id])))
            let length = lengths[k]
            var head = c.start
            if c.kind == .video, length < c.duration - 0.5 / fps {
                let w = best(c, length: length)
                head = frames(c.start + (w.sourceStart - c.sourceStart) / max(0.01, c.speed))
                if abs(head - c.start) > 0.5 / fps { edits.append(.trimHead(ids, from: c.start, to: head)) }
            }
            let tail = frames(head + length)
            let oldTail = c.end
            if abs(tail - oldTail) > 0.5 / fps {
                edits.append(.trimTail(ids, from: oldTail, to: tail))
                trimmed += 1
            }
            let target = frames(cuts[k])
            if abs(target - head) > 0.5 / fps {
                edits.append(.move(ids, from: head, to: target, tracks: [:]))
            }
        }

        // 5. Titles and overlays above: the same title twice at the same time goes (the lower one stays),
        // and anything past the new end is shortened or goes.
        let order = Dictionary(p.videoTracks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let titles = p.clips.filter { $0.kind == .text }.sorted { (order[$0.trackID] ?? 0) < (order[$1.trackID] ?? 0) }
        var doubled = Set<UUID>()
        // "Nothing else on the timeline": titles and overlays go.
        if recipe.clearRest {
            for c in p.clips where c.trackID != track.id && p.videoTracks.contains(where: { $0.id == c.trackID })
                && !p.isLocked(c.trackID) && !recipe.keepOnly.contains(c.assetID ?? UUID()) {
                doubled.insert(c.id)
                edits.append(.remove([c.id]))
            }
        }
        for (k, t) in titles.enumerated() where !doubled.contains(t.id) && !focused {
            for u in titles[(k + 1)...] where !doubled.contains(u.id) && u.text.string == t.text.string
                && u.start < t.end && u.end > t.start && !p.isLocked(u.trackID) {
                doubled.insert(u.id)
                edits.append(.remove([u.id]))
            }
        }
        for c in p.clips where c.trackID != track.id && p.videoTracks.contains(where: { $0.id == c.trackID })
            && !p.isLocked(c.trackID) && !doubled.contains(c.id) {
            if c.start >= newEnd - 0.2 {
                edits.append(.remove([c.id]))
            } else if c.end > newEnd {
                edits.append(.trimTail([c.id], from: c.end, to: newEnd))
            }
        }

        // 6. Sound: the song trimmed to the new end and faded out (or taken out, or put in); the clips' own
        // sound under it.
        let keptIDs = Set(keep.map(\.id))
        let keptAudio = p.clips.filter { a in a.kind == .audio && a.linkID != nil && keep.contains { $0.linkID == a.linkID } }
        // (Music goes too for "nothing else", unless it's one of the files they named.)
        let musicGoes = recipe.music == .off || (recipe.clearRest && recipe.music != .add && !recipe.keepOnly.contains(songOnTimeline?.assetID ?? UUID()))
        if musicGoes, let s = songOnTimeline, !p.isLocked(s.trackID) {
            edits.append(.remove([s.id]))
        }
        if var c = placing, let newSong {
            // On a sound track that's free for the whole edit, or a new one.
            if let free = p.audioTracks.first(where: { t in !p.isLocked(t.id) && !p.clips.contains { $0.trackID == t.id && $0.start < newEnd && $0.end > firstStart } }) {
                c.trackID = free.id
            } else {
                let id = UUID()
                edits.append(.change(nil, "Add audio track") { q in
                    var t = Track(kind: .audio)
                    t.id = id
                    q.audioTracks.append(t)
                })
                c.trackID = id
            }
            c.duration = frames(newEnd - firstStart)
            edits.append(.place([c], asset: newSong.id))
            edits.append(.fadeOut(c.id, to: min(2, c.duration * 0.15)))
            for a in keptAudio where a.gainDB > -10 { edits.append(.gain(a.id, from: a.gainDB, to: -16)) }
        } else if let song, !musicGoes, !p.isLocked(song.trackID) {
            if song.end > newEnd + 1e-3 { edits.append(.trimTail([song.id], from: song.end, to: newEnd)) }
            if song.fadeOut < 1.5 { edits.append(.fadeOut(song.id, to: min(2, max(0.5, (min(song.end, newEnd) - song.start) * 0.15)))) }
            for a in keptAudio where a.gainDB > -10 {
                edits.append(.gain(a.id, from: a.gainDB, to: -16))
            }
        } else if !focused, let first = keptAudio.min(by: { $0.start < $1.start }), let last = keptAudio.max(by: { $0.start < $1.start }) {
            if first.fadeIn < 0.2 { edits.append(.fadeIn(first.id, to: 0.3)) }
            if last.fadeOut < 0.3 { edits.append(.fadeOut(last.id, to: 0.6)) }
        }

        // 7. One look: the one they asked for, or the one most of the shots have, on all of them (or looks
        // off, if they asked); and exposure evened out.
        let looks = keep.compactMap { $0.grade?.look }
        let common = recipe.look ?? (focused ? nil : Dictionary(looks.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key)
        var graded = 0
        for c in keep where keptIDs.contains(c.id) && c.kind != .audio {
            if common == "none" {
                if c.grade?.look != nil {
                    let id = c.id
                    edits.append(.change(id, "No look") { q in
                        if let i = q.index(of: id) { var g = q.clips[i].grade ?? ColorGrade(); g.look = nil; q.clips[i].grade = g.isNeutral ? nil : g }
                    })
                    graded += 1
                }
            } else if let common, c.grade?.look != common {
                edits.append(.look(c.id, name: common))
                graded += 1
            }
            if !focused, (c.grade?.exposure ?? 0) == 0, let id = c.assetID, let a = analyses[id] {
                let r = sourceRange(c)
                let lumas = a.samples.filter { c.kind == .image || r.contains($0.time) }.map(\.luma)
                if !lumas.isEmpty {
                    let mean = lumas.reduce(0, +) / Double(lumas.count)
                    let exposure = ((log2(0.45 / max(0.05, mean)) * 0.5).clamped(to: -0.5...0.5) * 10).rounded() / 10
                    if abs(exposure) >= 0.2 { edits.append(.grade(c.id, .exposure, to: exposure)) }
                }
            }
        }

        var judgedNone = false
        // 8. Sound effects they asked for: the short sound files in their Media, on the cuts. Whooshes and
        // swishes lead into a cut; hits and impacts land on the first frame; anything else starts on a cut.
        var effectsPlaced = 0
        if recipe.soundEffects {
            let effects = LocalBrain.soundEffects(in: p)
            if effects.isEmpty {
                notes.append(L10n.tr("there are no sound effects in your Media (sound files under 10 seconds)"))
            } else {
                func named(_ a: MediaAsset, _ words: [String]) -> Bool { words.contains { a.name.lowercased().contains($0) } }
                let swooshes = effects.filter { named($0, ["whoosh", "swoosh", "swish", "woosh", "transition", "riser", "sweep"]) }
                let hits = effects.filter { named($0, ["hit", "impact", "boom", "thud", "punch", "slam", "bass drop", "drop"]) }
                let others = effects.filter { e in !swooshes.contains { $0.id == e.id } && !hits.contains { $0.id == e.id } }
                var spots: [(time: Double, effect: MediaAsset, lead: Bool)] = []
                let pool = swooshes.isEmpty ? (others.isEmpty ? hits : others) : swooshes
                if recipe.askedJudgement {
                    // Asked whether it should: only at strong moments (a cut where the picture changes a lot, or
                    // a sudden burst of motion), best first.
                    for (k, m) in strongMoments(keep: keep, cuts: cuts, analyses: analyses).prefix(8).enumerated() {
                        if m.kind == .motion, let hit = hits.first {
                            spots.append((m.time, hit, false))
                        } else {
                            let e = pool[k % pool.count]
                            spots.append((m.time, e, swooshes.contains { $0.id == e.id }))
                        }
                    }
                    spots.sort { $0.time < $1.time }
                    if spots.isEmpty {
                        judgedNone = true
                        notes.append(L10n.tr("Local found no strong changes in the picture for sound effects. Specify where to place them, or ask Claude or ChatGPT to watch the footage"))
                    }
                } else {
                    if let hit = hits.first { spots.append((firstStart, hit, false)) }
                    let cutTimes = Array(cuts.dropFirst().dropLast())
                    for (k, t) in cutTimes.enumerated() where spots.count < 8 {
                        let e = pool[k % pool.count]
                        spots.append((t, e, swooshes.contains { $0.id == e.id }))
                    }
                    if cutTimes.isEmpty, spots.isEmpty, let e = pool.first { spots.append((firstStart, e, false)) }
                }
                // One sound track for them all: a free one, or a new one.
                if !spots.isEmpty {
                let spans = spots.map { s -> (Double, Double) in
                    let start = max(firstStart, s.lead ? s.time - min(0.5, s.effect.duration * 0.6) : s.time - 0.03)
                    return (start, min(newEnd, start + s.effect.duration))
                }
                let lo = spans.map(\.0).min() ?? firstStart, hi = spans.map(\.1).max() ?? newEnd
                let trackID: UUID
                if let free = p.audioTracks.first(where: { t in
                    !p.isLocked(t.id) && t.id != songOnTimeline?.trackID && t.id != placing?.trackID
                        && !p.clips.contains { $0.trackID == t.id && $0.start < hi && $0.end > lo }
                }) {
                    trackID = free.id
                } else {
                    let id = UUID()
                    edits.append(.change(nil, "Add audio track") { q in
                        var t = Track(kind: .audio)
                        t.id = id
                        q.audioTracks.append(t)
                    })
                    trackID = id
                }
                var lastEnd = -Double.infinity
                let effectIDs = Set(effects.map(\.id))
                for (k, s) in spots.enumerated() {
                    var (start, end) = spans[k]
                    // A sound effect is already there: leave it.
                    if p.clips.contains(where: { effectIDs.contains($0.assetID ?? UUID()) && $0.start < end && $0.end > start }) { continue }
                    start = max(start, lastEnd)
                    guard end - start > 0.1 else { continue }
                    var c = Clip(trackID: trackID, kind: .audio, assetID: s.effect.id, start: frames(start), duration: frames(end - start))
                    c.gainDB = -6
                    c.fadeOut = min(0.15, c.duration / 3)
                    edits.append(.place([c], asset: s.effect.id))
                    lastEnd = end
                    effectsPlaced += 1
                }
                }
            }
        }

        // The audio levels, once everything else is in place.
        var final = p
        for e in edits { e.apply(&final, 1) }
        let levels = levelEdits(final)
        edits += levels

        if effectsPlaced == 0, recipe.soundEffects, !judgedNone, notes.isEmpty, recipe.isFocused {
            notes.append(L10n.tr("every cut already has a sound effect"))
        }
        if edits.isEmpty, judgedNone || !notes.isEmpty {
            let text = notes.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: L10n.tr(". "))
            return Outcome(plan: MagicPlan(base: p, tasks: []), summary: "", notes: notes, focused: true,
                           message: text.isEmpty ? L10n.tr("Your edit already looks good.") : text + L10n.tr("."))
        }
        guard !edits.isEmpty else { return nil }
        // The length only when it was part of the job: a focused request ("only IMG_1607") just says what it did.
        var parts: [String] = focused && recipe.seconds == nil ? []
            : [L10n.fmt("%.1fs to %.1fs", oldEnd - firstStart, newEnd - firstStart)]
        if effectsPlaced > 0 { parts.append(L10n.fmt("added %lld sound effects on the cuts", effectsPlaced)) }
        if !recipe.keepOnly.isEmpty { parts.append(L10n.fmt("kept only %@ (removed %lld shots)", recipe.mediaNames.joined(separator: ", "), named)) }
        if !recipe.takeOut.isEmpty { parts.append(L10n.fmt("removed %@ (%lld shots)", recipe.mediaNames.joined(separator: ", "), named)) }
        if recipe.clearRest { parts.append(L10n.tr("cleared everything else off the timeline")) }
        if repeats > 0 { parts.append(L10n.fmt("removed %lld repeated shots", repeats)) }
        if !doubled.isEmpty, !recipe.clearRest { parts.append(L10n.fmt("removed %lld duplicate titles", doubled.count)) }
        if weakOut > 0 { parts.append(L10n.fmt("removed %lld weak shots", weakOut)) }
        if trimmed > 0 {
            parts.append(growing ? L10n.fmt("lengthened %lld shots", trimmed) : L10n.fmt("trimmed %lld shots", trimmed))
        }
        if placing != nil { parts.append(L10n.tr("music added")) }
        else if recipe.music == .off && songOnTimeline != nil { parts.append(L10n.tr("music out")) }
        if snap, !musicGoes, song != nil, music != nil { parts.append(L10n.tr("cut to the beat")) }
        if graded > 0 { parts.append(common == "none" ? L10n.tr("looks off") : L10n.fmt("one look (%@)", BuiltInLook.displayName(common ?? ""))) }
        if recipe.frame != .unchanged, size != nil { parts.append(L10n.tr(recipe.frame.rawValue)) }
        if !levels.isEmpty { parts.append(levelPart(levels)) }
        return Outcome(plan: MCPDraft.plan(base: p, edits: edits), summary: parts.joined(separator: L10n.tr(", ")), notes: notes, focused: focused)
    }

    enum MomentKind { case cut, motion }

    /// Where a sound effect would land well: cuts where the picture changes a lot (brightness, colour), and
    /// sudden bursts of motion inside a shot. Best first; none if the footage is all much the same.
    static func strongMoments(keep: [Clip], cuts: [Double], analyses: [UUID: ClipAnalysis]) -> [(time: Double, kind: MomentKind, score: Double)] {
        func samples(_ c: Clip) -> [ClipAnalysis.Sample] {
            guard let id = c.assetID, let a = analyses[id] else { return [] }
            let r = c.sourceStart...(c.sourceStart + c.sourceLength)
            return a.samples.filter { c.kind == .image || r.contains($0.time) }
        }
        func edge(_ c: Clip, end: Bool) -> (luma: Double, color: Double)? {
            let s = samples(c)
            guard !s.isEmpty else { return nil }
            let part = end ? Array(s.suffix(2)) : Array(s.prefix(2))
            return (part.map(\.luma).reduce(0, +) / Double(part.count), part.map(\.color).reduce(0, +) / Double(part.count))
        }
        var out: [(Double, MomentKind, Double)] = []
        // Cuts: how much the picture jumps.
        for k in 0..<max(0, keep.count - 1) {
            guard let a = edge(keep[k], end: true), let b = edge(keep[k + 1], end: false) else { continue }
            let score = abs(a.luma - b.luma) * 3 + abs(a.color - b.color) * 1.5 + (keep[k].assetID != keep[k + 1].assetID ? 0.1 : 0)
            if score >= 0.5 { out.append((cuts[k + 1], .cut, score)) }
        }
        // Motion: a sample far busier than the footage around it.
        let all = keep.flatMap(samples).map(\.motion).sorted()
        if all.count >= 8 {
            let median = all[all.count / 2], p95 = all[Int(Double(all.count - 1) * 0.95)]
            let bar = max(p95, median * 3, 0.02)
            for (k, c) in keep.enumerated() {
                for s in samples(c) where s.motion >= bar {
                    let t = cuts[k] + (s.time - c.sourceStart) / max(0.01, c.speed)
                    if !out.contains(where: { abs($0.0 - t) < 1.5 }) { out.append((t, .motion, 0.5 + s.motion / max(bar, 1e-6) * 0.1)) }
                }
            }
        }
        return out.sorted { $0.2 > $1.2 }
    }

    /// Video and photo clips that make up the cut (not titles or solids).
    private static func isShot(_ c: Clip) -> Bool { (c.kind == .video || c.kind == .image) && c.assetID != nil }

    /// How long a shot could run from its start to the end of its file.
    private static func sourceRoom(_ c: Clip, _ p: Project) -> Double {
        guard let limit = p.sourceLimit(c) else { return c.duration }
        return max(c.duration, (limit - c.sourceStart) / max(0.01, c.speed))
    }

    /// The song's own beat number for a timeline beat (the list was filtered, so offsets shift).
    private static func beatIndex(_ offset: Int, of time: Double, in m: MusicAnalysis, song: Clip) -> Int {
        let sourceTime = song.sourceTime(at: time)
        return m.beats.indices.min { abs(m.beats[$0] - sourceTime) < abs(m.beats[$1] - sourceTime) } ?? offset
    }
}
