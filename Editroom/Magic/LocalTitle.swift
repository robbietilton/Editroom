import Foundation

/// Local's titles on an edit that's already there ("add a title at the end", "put 'Day one' at the start"):
/// a title over the start, the end or the playhead, and nothing else changed.
@MainActor
enum LocalTitle {
    /// A title for the edit on the timeline, not a new cut that happens to have one.
    static func asks(_ request: String, project p: Project) -> Bool {
        let hasEdit = p.clips.contains { $0.kind == .video || $0.kind == .image }
        return hasEdit && !newCut(request) && LocalBrain.titleAsked(request) != nil
    }

    /// A new cut to make ("make a 18s video…", "a new montage"), not a change to the edit that's there.
    static func newCut(_ request: String) -> Bool {
        let t = request.lowercased()
        return ["new cut", "new edit", "new video", "montage", "recut", "re-cut", "from scratch", "start over"].contains { t.contains($0) }
            || LocalBrain.wantsLibrary(request)
            // "make a 18s video…", "create an edit…": a cut to make, with a title in it.
            || (["make a", "make an", "make me", "create", "build a", "cut a", "edit a"].contains { t.contains($0) }
                && ["video", "cut", "edit", "montage", "reel", "recap", "vlog", "movie", "film"].contains { t.contains($0) })
    }

    enum Spot { case start, end, playhead, at(Double) }

    /// They want the title at the end ("add a title at the end", "an end card", "outro").
    static func atEnd(_ request: String) -> Bool {
        let t = request.lowercased()
        return ["at the end", "the end", "at end", "in the end", "to the end", "end of", "ending", "end screen", "end card",
                "end title", "outro", "closing", "at the close", "last shot", "at the finish", "final shot", "finale"]
            .contains(where: { t.contains($0) })
    }

    static func spot(_ request: String, fps: Double = 30) -> Spot {
        let t = request.lowercased()
        // A time they typed, or a marker (read as its time): "a title at 0:12", "a title at @Intro".
        if MagicTimes.span(in: request, fps: fps) == nil,
           let typed = MagicTimes.times(in: request, fps: fps).first(where: { !$0.unitOnly }) { return .at(typed.seconds) }
        if atEnd(request) { return .end }
        if ["playhead", "here", "right now", "this point"].contains(where: { t.contains($0) }) { return .playhead }
        return .start
    }

    static func plan(request: String, playhead: Double, project p: Project) -> LocalPointed.Outcome {
        let edit = p.clips.filter { $0.kind == .video || $0.kind == .image }
        guard let first = edit.map(\.start).min(), let last = edit.map(\.end).max() else {
            return LocalPointed.Outcome(said: L10n.tr("There's no edit on the timeline to put a title on."))
        }
        let where_ = spot(request, fps: p.fps)
        let length = min(3, max(1, (last - first) * 0.25))
        let start: Double
        switch where_ {
        case .start: start = first
        case .end: start = max(first, last - length)
        case .playhead: start = min(max(first, playhead), max(first, last - length))
        case .at(let t): start = min(max(first, t), max(first, last - length))
        }
        // Their words when quoted; otherwise a placeholder to type over.
        let words = LocalBrain.titleAsked(request).flatMap { $0.isEmpty ? nil : $0 } ?? "Title"

        // Above the picture: the first video track (not V1) that's free there, else a new one on top.
        var edits: [MagicEdit] = []
        let s = p.snapFrame(start), d = p.snapFrame(length)
        let track: UUID
        if let free = p.videoTracks.dropFirst().first(where: { t in
            !t.locked && !p.clips.contains { $0.trackID == t.id && $0.start < s + d && $0.end > s }
        }) {
            track = free.id
        } else {
            track = UUID()
            edits.append(.change(nil, "Add video track") { q in
                var t = Track(kind: .video)
                t.id = track
                q.videoTracks.append(t)
            })
        }
        var clip = Clip(trackID: track, kind: .text, start: s, duration: d)
        clip.text.string = ""
        clip.text.size = 130
        edits += [.place([clip], asset: nil), .type(clip.id, words), .fadeIn(clip.id, to: 0.4), .fadeOut(clip.id, to: 0.5)]
        let place: String = switch where_ {
        case .end: L10n.fmt("over the last %lld seconds", Int(length.rounded()))
        case .start: L10n.tr("at the start")
        case .playhead: L10n.tr("at the playhead")
        case .at: L10n.fmt("at %@", MagicMention.clock(start))
        }
        return LocalPointed.Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: L10n.fmt("Added the title “%@” %@.", words, place))
    }
}
