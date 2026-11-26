import Foundation

/// Local's speed ramps: a slow-motion moment in a shot ("speed ramp", "slow-mo moment"), or ramping up
/// into each cut and back down out of it ("ramp into the cuts").
@MainActor
enum LocalRamp {
    static func asks(_ request: String) -> Bool {
        let t = request.lowercased()
        let moment = ["slow-mo moment", "slow mo moment", "slowmo moment", "slow motion moment", "slow-motion moment"].contains { t.contains($0) }
        return t.contains("ramp") || moment
    }

    /// Ramping between shots rather than within one.
    static func atCuts(_ request: String) -> Bool {
        let t = request.lowercased()
        return ["cut", "transition", "between", "into each", "into the next", "whip"].contains { t.contains($0) }
    }

    static func plan(request: String, pointers ptr: MagicPointers, project p: Project) -> LocalPointed.Outcome {
        let t = request.lowercased()
        guard let track = p.videoTracks.first(where: { tr in p.clips.contains { $0.trackID == tr.id && $0.kind == .video } }) else {
            return LocalPointed.Outcome(said: L10n.tr("There are no video shots on the timeline."))
        }
        let shots = p.clips.filter { $0.trackID == track.id && $0.kind == .video && $0.playsSource && !p.isLocked($0.trackID) }
            .sorted { $0.start < $1.start }
        guard !shots.isEmpty else { return LocalPointed.Outcome(said: L10n.tr("The main video track is locked, so nothing was changed.")) }
        // Pointed at: @clip names and selected clips.
        let found = MagicMention.find(in: request, media: p.assets, clips: MagicMention.clipLabels(p))
        var pointed = Set(found.compactMap { m -> UUID? in if case .clip(let id) = m.mention { return id } else { return nil } })
        if found.contains(where: { $0.mention == .selected }) || t.contains("selected") || pointed.isEmpty { pointed.formUnion(ptr.selected) }
        let chosen = p.clips.filter { pointed.contains($0.id) && $0.kind == .video && $0.playsSource && !p.isLocked($0.trackID) }
            .sorted { $0.start < $1.start }
        let asked = LocalBrain.speed(in: request)
        var edits: [MagicEdit] = []

        if atCuts(request) {
            // Each cut between touching shots: the shot before speeds up into it, the one after slows out of it.
            let fast = asked.map { $0 > 1 ? $0 : 4 } ?? 4
            let set = chosen.count >= 2 ? chosen : shots
            var cuts = 0
            for (i, c) in set.enumerated() {
                let before = i > 0 && abs(set[i - 1].end - c.start) < 0.5 / p.fps
                let after = i + 1 < set.count && abs(set[i + 1].start - c.end) < 0.5 / p.fps
                guard before || after else { continue }
                if after { cuts += 1 }
                let points = (0.0, before ? 0.25 : 0, after ? 0.75 : 1, 1.0)
                let ids = p.unlocked(p.linked([c.id]))
                edits.append(.change(c.id, "Speed ramp") { q in
                    guard let now = q.clip(c.id) else { return }
                    q.setRamp(ids: ids, speed: now.speed, points: points, start: fast, end: fast)
                })
            }
            guard !edits.isEmpty else { return LocalPointed.Outcome(said: L10n.tr("There are no cuts between shots to ramp into.")) }
            return LocalPointed.Outcome(plan: MCPDraft.plan(base: p, edits: edits),
                                        said: L10n.fmt("Ramped up to %lld%% around %lld cuts.", Int((fast * 100).rounded()), cuts))
        }

        // A moment within a shot: the selected shots, else the one at the playhead, else the longest.
        let atPlayhead = shots.first { ptr.playhead >= $0.start && ptr.playhead < $0.end }
        let targets = !chosen.isEmpty ? chosen : [atPlayhead ?? shots.max { $0.duration < $1.duration }!]
        let speed = asked.map { $0 == 1 ? 0.3 : $0 } ?? (t.contains("fast") || t.contains("speed up") ? 3 : 0.3)
        for c in targets {
            // Around the playhead when it's in the shot, else the middle: a fifth of the footage, eased over a tenth each side.
            let L = max(1e-6, c.sourceLength)
            var mid = 0.5
            if ptr.playhead > c.start, ptr.playhead < c.end { mid = (c.sourceTime(at: ptr.playhead) - c.sourceStart) / L }
            mid = min(max(mid, 0.2), 0.8)
            let points = (mid - 0.2, mid - 0.1, mid + 0.1, mid + 0.2)
            let ids = p.unlocked(p.linked([c.id]))
            let around = c.speed
            edits.append(.change(c.id, speed < 1 ? "Slow-mo ramp" : "Speed ramp") { q in
                q.setRamp(ids: ids, speed: speed, points: points, start: around, end: around)
            })
        }
        let n = targets.count
        return LocalPointed.Outcome(plan: MCPDraft.plan(base: p, edits: edits),
                                    said: L10n.fmt("Eased a moment in %@ to %lld%% speed and back.",
                                                 n == 1 ? L10n.tr("the shot") : L10n.fmt("%lld shots", n),
                                                 Int((speed * 100).rounded())))
    }
}
