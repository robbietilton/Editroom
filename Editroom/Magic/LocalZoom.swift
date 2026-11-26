import Foundation

/// Local's zooms, as the zoom button on Scale makes them: "zoom in on @selected", "add a zoom", "push in",
/// "zoom out", "zoom in and out", or "remove the zoom". On the clips pointed at or selected, else the one at the
/// playhead.
@MainActor
enum LocalZoom {
    static func asks(_ request: String) -> Bool {
        let t = request.lowercased()
        return ["zoom", "push in", "punch in", "push-in", "punch-in", "ken burns"].contains { t.contains($0) }
    }

    static func plan(request: String, pointers ptr: MagicPointers, project p: Project) -> LocalPointed.Outcome {
        let t = " " + request.lowercased() + " "
        let found = MagicMention.find(in: request, media: p.assets, clips: MagicMention.clipLabels(p))
        var pointed = Set(found.compactMap { m -> UUID? in if case .clip(let id) = m.mention { return id } else { return nil } })
        if found.contains(where: { $0.mention == .selected }) || t.contains("selected") || pointed.isEmpty { pointed.formUnion(ptr.selected) }
        var targets = p.clips.filter { pointed.contains($0.id) && $0.isTransformable && !p.isLocked($0.trackID) }
        if targets.isEmpty {
            // The picture under the playhead: the top video track that has one there.
            let order = p.videoTracks.reversed().map(\.id)
            let under = p.clips.filter { $0.isTransformable && !p.isLocked($0.trackID) && ptr.playhead >= $0.start && ptr.playhead < $0.end }
            if let top = order.lazy.compactMap({ id in under.first { $0.trackID == id } }).first { targets = [top] }
        }
        guard !targets.isEmpty else {
            return LocalPointed.Outcome(said: L10n.tr("Select a clip, or put the playhead on one, to zoom."))
        }

        let off = [" remove", " take off", " turn off", " no zoom", " without zoom", " stop zoom", " get rid of", " undo the zoom"].contains { t.contains($0) }
        let mode: ZoomMove.Mode = [" in and out", " in & out", " in/out", " in then out", " in, then out", " back out"].contains { t.contains($0) }
            ? .inOut : (t.contains("zoom out") || t.contains("zoom-out") || t.contains("pull out") || t.contains("pull back")) ? .zoomOut : .zoomIn
        let even = [" linear", " steady", " even pace", " constant"].contains { t.contains($0) }
        let amount = scale(in: t)

        var edits: [MagicEdit] = []
        for c in targets {
            let id = c.id
            edits.append(.change(id, off ? "Zoom off" : "Zoom") { q in
                guard let i = q.index(of: id) else { return }
                var tf = q.clips[i].transform ?? ClipTransform()
                if off {
                    tf.zoom = nil
                } else {
                    if let amount { tf.scale = amount } else if tf.scale <= 1.01 { tf.scale = 2 }
                    var move = ZoomMove.starter(mode, length: q.clips[i].duration)
                    move.smooth = !even
                    tf.zoom = move
                    if tf.fills { (tf.x, tf.y) = tf.zoomedOffset }
                }
                q.clips[i].transform = tf.isIdentity ? nil : tf
            })
        }
        let n = targets.count
        let shots = n == 1 ? L10n.tr("the shot") : L10n.fmt("%lld shots", n)
        let said: String
        if off {
            said = L10n.fmt("Removed zoom from %@.", shots)
        } else {
            let how = switch mode {
            case .zoomIn: L10n.fmt("Zooms in on %@.", shots)
            case .zoomOut: L10n.fmt("Zooms out of %@.", shots)
            case .inOut: L10n.fmt("Zooms in and back out on %@.", shots)
            }
            let pace = even ? " " + L10n.tr("Moves at a steady pace.") : ""
            said = how + pace + " " + L10n.tr("Change it with the zoom button on Scale.")
        }
        return LocalPointed.Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: said)
    }

    /// How far in, when it's said: "2x", "1.5×", "150%".
    private static func scale(in t: String) -> Double? {
        if let r = t.range(of: #"(\d+(\.\d+)?)\s*[x×]"#, options: .regularExpression),
           let v = Double(t[r].filter { $0.isNumber || $0 == "." }), v > 1, v <= 10 { return v }
        if let r = t.range(of: #"(\d+)\s*%"#, options: .regularExpression),
           let v = Double(t[r].filter(\.isNumber)), v > 100, v <= 1000 { return v / 100 }
        return nil
    }
}
