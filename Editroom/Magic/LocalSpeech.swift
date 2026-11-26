import Foundation

/// Local's cut for people talking: the pauses (and the "um"s, which the transcript leaves out, so they're
/// pauses too) taken out of every shot where someone talks, each shot's own sound with it. Shots with no
/// talking are left alone.
@MainActor
enum LocalSpeech {
    /// "Cut the pauses", "remove the dead space", "tighten the talking", "take out the ums".
    static func asks(_ request: String) -> Bool {
        let t = request.lowercased()
        return ["dead space", "dead air", "pause", "silence", "silent", " um", "ums", "uhs", "filler", "jump cut", "jumpcut",
                "tighten the talk", "tighten the speech", "tighten what"].contains { t.contains($0) }
    }

    /// Talking closer than this runs together; a gap must be at least this long to be cut.
    static let join = 0.45, keepBefore = 0.12, keepAfter = 0.2, shortest = 0.3

    /// The cut, for these shots (nil: every shot on the main picture track).
    static func plan(project p: Project, only: Set<UUID>?, transcript: (UUID) -> Transcript?) -> LocalPointed.Outcome {
        guard let track = p.videoTracks.first(where: { t in p.clips.contains { $0.trackID == t.id && $0.kind == .video } }) else {
            return LocalPointed.Outcome(said: L10n.tr("There are no video shots on the timeline."))
        }
        guard !p.isLocked(track.id) else { return LocalPointed.Outcome(said: L10n.tr("The main video track is locked, so nothing was changed.")) }
        let shots = p.clips.filter { $0.trackID == track.id && $0.kind == .video && (only?.contains($0.id) ?? true) }
            .sorted { $0.start < $1.start }
        // Timeline stretches to take out, latest first so earlier ones keep their place.
        var cuts: [(start: Double, end: Double)] = []
        var talking = 0, unheard = 0
        for c in shots {
            guard let id = c.assetID else { continue }
            guard let t = transcript(id) else { unheard += 1; continue }
            guard abs(c.speed - 1) < 1e-3, !c.isReversed else { continue }
            let s0 = c.sourceStart, s1 = c.sourceStart + c.duration
            let talk = t.speech(gap: join).filter { $0.end > s0 && $0.start < s1 }
            guard !talk.isEmpty else { continue }
            talking += 1
            // Keep each stretch of talking with a little air around it; everything else in the shot goes.
            var keep: [(Double, Double)] = []
            for s in talk {
                let a = max(s0, s.start - keepBefore), b = min(s1, s.end + keepAfter)
                if let last = keep.last, a <= last.1 { keep[keep.count - 1].1 = max(last.1, b) } else { keep.append((a, b)) }
            }
            var at = s0
            for (a, b) in keep {
                if a - at >= shortest { cuts.append((c.start + (at - s0), c.start + (a - s0))) }
                at = b
            }
            if s1 - at >= shortest { cuts.append((c.start + (at - s0), c.start + (s1 - s0))) }
        }
        guard talking > 0 else {
            return LocalPointed.Outcome(said: unheard > 0
                ? L10n.tr("Editroom is still listening to your clips. Try again in a moment.")
                : L10n.tr("No speech was heard, so there were no pauses to cut."))
        }
        guard !cuts.isEmpty else { return LocalPointed.Outcome(said: L10n.tr("The talking is already tight: no pauses long enough to cut.")) }
        let total = cuts.reduce(0) { $0 + ($1.end - $1.start) }
        let ordered = cuts.sorted { $0.start > $1.start }
        // The main picture track and the tracks its shots' own sound is on: cut together, moved together,
        // so picture and sound stay in sync. (Music and titles on other tracks stay where they are.)
        let trackID = track.id
        let soundLinks = Set(p.clips.filter { $0.trackID == trackID }.compactMap(\.linkID))
        let tracks = Set([trackID] + p.clips.filter { $0.trackID != trackID && $0.linkID.map(soundLinks.contains) == true }.map(\.trackID))
            .filter { !p.isLocked($0) }
        let edit = MagicEdit.change(shots.first!.id, "Cut pauses") { q in
            for cut in ordered {
                _ = q.split(ids: Set(q.clips.filter { tracks.contains($0.trackID) }.map(\.id)), at: cut.start)
                _ = q.split(ids: Set(q.clips.filter { tracks.contains($0.trackID) }.map(\.id)), at: cut.end)
                q.clips.removeAll { tracks.contains($0.trackID) && $0.start >= cut.start - 1e-6 && $0.end <= cut.end + 1e-6 }
                let length = cut.end - cut.start
                for i in q.clips.indices where tracks.contains(q.clips[i].trackID) && q.clips[i].start >= cut.end - 1e-6 {
                    q.clips[i].start -= length
                }
            }
        }
        return LocalPointed.Outcome(plan: MCPDraft.plan(base: p, edits: [edit]),
                                    said: L10n.fmt("Cut %lld pauses (%.1f seconds) from %lld shots with talking.",
                                                  cuts.count, total, talking))
    }
}
