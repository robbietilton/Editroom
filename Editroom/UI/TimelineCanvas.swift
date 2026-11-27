import AppKit
import Combine
import SwiftUI

struct TimelineCanvasView: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> TimelineCanvas { TimelineCanvas(model: model) }
    func updateNSView(_ nsView: TimelineCanvas, context: Context) {}
}

/// The playhead lives in its own layer-backed view so moving it never redraws the clips.
final class PlayheadView: NSView {
    static let width: CGFloat = 16

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let mid = bounds.midX
        let l = mid - 5.5, r = mid + 5.5
        let top: CGFloat = 5, shoulder: CGFloat = 13, tip: CGFloat = 19, rad: CGFloat = 3
        // One closed shape: rounded cap narrowing to a point, with the stem running straight out of the tip.
        let p = CGMutablePath()
        p.move(to: CGPoint(x: l, y: top + rad))
        p.addArc(tangent1End: CGPoint(x: l, y: top), tangent2End: CGPoint(x: l + rad, y: top), radius: rad)
        p.addLine(to: CGPoint(x: r - rad, y: top))
        p.addArc(tangent1End: CGPoint(x: r, y: top), tangent2End: CGPoint(x: r, y: top + rad), radius: rad)
        p.addLine(to: CGPoint(x: r, y: shoulder))
        p.addLine(to: CGPoint(x: mid + 0.5, y: tip))
        p.addLine(to: CGPoint(x: mid + 0.5, y: bounds.height))
        p.addLine(to: CGPoint(x: mid - 0.5, y: bounds.height))
        p.addLine(to: CGPoint(x: mid - 0.5, y: tip))
        p.addLine(to: CGPoint(x: l, y: shoulder))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(Theme.NS.accent.cgColor)
        ctx.fillPath()
    }
}

final class TimelineCanvas: NSView {
    private let model: EditorModel
    private var view: TimelineViewState { model.view }
    private var bag = Set<AnyCancellable>()
    private let playheadView = PlayheadView()
    private var layout = TimelineLayout(project: Project(), rowHeight: 62)

    // MARK: Interaction state

    private enum Zone { case body, left, right, fadeIn, fadeOut, gain }

    private struct Hit {
        let clip: Clip
        let zone: Zone
        let rect: CGRect
    }

    private enum Lane {
        case track(Track, Int)
        case newVideo
        case newAudio
        case none
    }

    private enum Drag {
        case none
        case scrub
        case pendingMove(grabbed: Clip, point: CGPoint, time: Double)
        case move(grabbed: Clip, time: Double, originals: [Clip])
        case trim(grabbed: Clip, left: Bool, time: Double, originals: [Clip])
        case fade(id: UUID, fadeIn: Bool)
        case gain(id: UUID, startY: CGFloat, startNorm: CGFloat, height: CGFloat)
        case marquee(origin: CGPoint, base: Set<UUID>, captionBase: Set<String>)
        /// Dragging out a box on the caption track: picks the captions it touches.
        case captionMarquee(origin: CGPoint, base: Set<String>)
        /// A marker's flag: a click opens its panel, a drag moves it.
        case marker(id: UUID, startX: CGFloat, moved: Bool)
        /// One end of the in/out range.
        case rangeEdge(isIn: Bool)
    }

    private var drag = Drag.none
    private var overrides: [UUID: Clip] = [:]
    private var ghosts: [Clip] = []
    /// Files being dragged in from Finder: their name, shown on the drop's outline (it has no library item yet,
    /// which would otherwise read "Missing").
    private var fileGhostLabel: String?
    private var hover: (id: UUID, zone: Zone)?
    /// Where the current drag has snapped to. Landing on a new edge gives a light tap on the trackpad.
    private var snapLine: Double? {
        didSet {
            if let s = snapLine, s != oldValue { Self.tap() }
        }
    }
    /// While dragging the playhead, the time shown beside it on the ruler.
    private var scrubReadout: Double?
    private var lastShownTime: Double?
    /// ⌥ held during a move: drop copies instead of moving the clips.
    private var duplicating = false
    private var lastScrubSnap: Double?

    private static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    private var cutHover: (id: UUID, time: Double)?
    private var marquee: CGRect?
    private var bubble: (text: String, point: CGPoint)?
    private var moveTrackDelta = 0
    private var dropInfo: (video: UUID, audio: UUID, start: Double)?
    private var cursor = NSCursor.arrow
    private var lastDragPoint = CGPoint.zero
    private var autoscrollTimer: Timer?
    private var autoscrollVelocity: CGFloat = 0

    // MARK: Setup

    /// The track headers beside the timeline, in window coordinates: a drop over them lands at the start of that row.
    var headersInWindow: CGRect {
        let frame = convert(bounds, to: nil)
        return CGRect(x: frame.minX - TimelineLayout.headerWidth - 1, y: frame.minY, width: TimelineLayout.headerWidth + 1, height: frame.height)
    }

    /// The window's timeline, for the magic overlay.
    static weak var current: TimelineCanvas?

    /// What the magic show's cursors are doing, drawn the way a real drag is.
    var magicMarks = MagicMarks() {
        didSet { if magicMarks != oldValue { needsDisplay = true } }
    }

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        Self.current = self
        wantsLayer = true
        clipsToBounds = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        playheadView.wantsLayer = true
        playheadView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(playheadView)
        registerForDraggedTypes([.fileURL, .string])

        model.objectWillChange.sink { [weak self] _ in self?.needsDisplay = true }.store(in: &bag)
        model.$editingMarker.receive(on: DispatchQueue.main).sink { [weak self] id in self?.showMarkerPanel(id) }.store(in: &bag)
        model.view.objectWillChange.sink { [weak self] _ in self?.needsDisplay = true }.store(in: &bag)
        // Magic starting with the pointer on a clip: its highlight and cursor go.
        MagicState.shared.$stage.receive(on: DispatchQueue.main).sink { [weak self] stage in
            if stage != nil { self?.clearHover() }
        }.store(in: &bag)
        model.media.onVisualUpdate = { [weak self] in self?.needsDisplay = true }
        model.tickHandlers.append { [weak self] in self?.tick() }

        // The track headers sit beside this view; scrolling over them should scroll the timeline too.
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window else { return event }
                let frame = self.convert(self.bounds, to: nil)
                let headers = CGRect(x: frame.minX - TimelineLayout.headerWidth - 1, y: frame.minY,
                                     width: TimelineLayout.headerWidth + 1, height: frame.height)
                guard headers.contains(event.locationInWindow) else { return event }
                if event.type == .magnify { self.magnify(with: event) } else { self.scrollWheel(with: event) }
                return nil
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let state = view
        DispatchQueue.main.async {
            if state.viewWidth != newSize.width { state.viewWidth = newSize.width }
            if state.viewHeight != newSize.height { state.viewHeight = newSize.height }
            if state.needsInitialCentering, newSize.height > 0 {
                state.needsInitialCentering = false
                self.model.fitRows()
            }
            self.model.clampView()
        }
        playheadView.frame.size = CGSize(width: PlayheadView.width, height: newSize.height)
        playheadView.needsDisplay = true
        // In place now, not on the next screen refresh: a timeline made afresh (a theme change rebuilds
        // the window) otherwise showed its playhead at the far left for a frame.
        tick()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keep keyboard focus on the timeline rather than the first text field SwiftUI finds (the Media search):
        // the window starts on the timeline, so the search never flashes into focus as Editroom opens.
        if let window {
            window.initialFirstResponder = self
            if !(window.firstResponder is NSText) || !window.isVisible { window.makeFirstResponder(self) }
        }
        for delay in [0.0, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let window = self.window, !(window.firstResponder is NSText) || delay > 0 else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    // MARK: Geometry

    private var pps: CGFloat { view.pps }

    private func x(_ time: Double) -> CGFloat { CGFloat(time) * pps - view.scrollX }
    private func time(atX x: CGFloat) -> Double { Double((x + view.scrollX) / pps) }

    private func rect(for c: Clip) -> CGRect? {
        guard let band = layout.band(for: c.trackID) else { return nil }
        return CGRect(x: x(c.start), y: TimelineLayout.ruler + band.y - view.scrollY,
                      width: max(CGFloat(c.duration) * pps, 1), height: band.height)
    }

    /// A caption's block on the caption track.
    private func captionRect(_ b: CaptionBlock) -> CGRect? {
        guard let cy = layout.captionY else { return nil }
        return CGRect(x: x(b.start), y: TimelineLayout.ruler + cy - view.scrollY,
                      width: max(CGFloat(b.end - b.start) * pps, 2), height: TimelineLayout.captionRow)
    }

    /// Whether a point is on the caption track's row.
    private func inCaptionRow(_ p: CGPoint) -> Bool {
        guard let cy = layout.captionY, p.y >= TimelineLayout.ruler else { return false }
        let y = p.y - TimelineLayout.ruler + view.scrollY
        return y >= cy && y < cy + TimelineLayout.captionRow
    }

    private func captionHit(at p: CGPoint) -> CaptionBlock? {
        guard inCaptionRow(p) else { return nil }
        return model.captionBlocks.last { captionRect($0)?.insetBy(dx: -2, dy: 0).contains(p) == true }
    }

    private func lane(atY y: CGFloat) -> Lane {
        let cy = y - TimelineLayout.ruler + view.scrollY
        if cy < layout.videoZoneY + TimelineLayout.zone { return .newVideo }
        if cy >= layout.audioZoneY { return .newAudio }
        for row in layout.rows where cy >= row.y && cy < row.y + row.height + TimelineLayout.gap {
            return .track(row.track, row.index)
        }
        return .none
    }

    private func setScroll(x: CGFloat, y: CGFloat) {
        model.setView(scrollX: x, scrollY: y)
    }

    private func tick() {
        // A graph dot dragged in the inspector moves the playhead; its time tag goes with it.
        if model.showPlayheadTime, lastShownTime != model.playhead {
            lastShownTime = model.playhead
            needsDisplay = true
        }
        var px = x(model.playhead)
        if model.isPlaying, px > bounds.width - 28 || px < 0 {
            model.setView(scrollX: CGFloat(model.playhead) * pps - 48)
            px = x(model.playhead)
        }
        let origin = CGPoint(x: ((px - PlayheadView.width / 2) * 2).rounded() / 2, y: 0)
        let hidden = px < -PlayheadView.width || px > bounds.width + PlayheadView.width
        if playheadView.isHidden != hidden { playheadView.isHidden = hidden }
        if playheadView.frame.origin != origin {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playheadView.setFrameOrigin(origin)
            CATransaction.commit()
        }
    }

    // MARK: Snapping

    private var snappingActive: Bool {
        model.snapping != NSEvent.modifierFlags.contains(.command)
    }

    private func snap(_ candidates: [Double], to targets: [Double], pixels: CGFloat = 8) -> (delta: Double, target: Double)? {
        guard snappingActive else { return nil }
        let threshold = Double(pixels / pps)
        var best: (delta: Double, target: Double)?
        for c in candidates {
            for t in targets {
                let d = t - c
                if abs(d) <= threshold, best == nil || abs(d) < abs(best!.delta) { best = (d, t) }
            }
        }
        return best
    }

    // MARK: Hit testing

    private func fadeHandleX(_ c: Clip, _ r: CGRect, fadeIn: Bool) -> CGFloat {
        let raw = fadeIn ? r.minX + CGFloat(c.fadeIn) * pps : r.maxX - CGFloat(c.fadeOut) * pps
        return min(max(raw, r.minX + 6), r.maxX - 6)
    }

    private static func gainNorm(_ db: Double) -> CGFloat {
        db >= 0 ? 0.3 - CGFloat(db / 12) * 0.2 : 0.3 + CGFloat(-db / 60) * 0.62
    }

    private static func gainDB(norm: CGFloat) -> Double {
        let n = min(max(norm, 0.1), 0.92)
        let db = n <= 0.3 ? Double((0.3 - n) / 0.2) * 12 : -Double((n - 0.3) / 0.62) * 60
        return (db * 10).rounded() / 10
    }

    private func hit(at p: CGPoint) -> Hit? {
        guard p.y >= TimelineLayout.ruler else { return nil }
        for c in model.project.clips where !model.project.isLocked(c.trackID) {
            guard let r = rect(for: c), r.contains(p) else { continue }
            // Fade dots only for fades set (in the inspector): an unset fade has no dot to catch the
            // mouse, so a clip's edges always trim.
            let showHandles = r.width > 36 && (c.fadeIn > 0 || c.fadeOut > 0)
            if showHandles, p.y < r.minY + 17 {
                let hi = fadeHandleX(c, r, fadeIn: true), ho = fadeHandleX(c, r, fadeIn: false)
                let di = c.fadeIn > 0 ? abs(p.x - hi) : .infinity, dout = c.fadeOut > 0 ? abs(p.x - ho) : .infinity
                if min(di, dout) <= 7 {
                    var takeIn = di <= dout
                    // Overlapping dots: the one with the longer fade (the one dragged there) is on
                    // top and takes the click; with equal fades, the side clicked decides.
                    if abs(hi - ho) < 8, c.fadeIn > 0, c.fadeOut > 0 {
                        takeIn = c.fadeIn != c.fadeOut ? c.fadeIn > c.fadeOut : p.x < hi
                    }
                    return Hit(clip: c, zone: takeIn ? .fadeIn : .fadeOut, rect: r)
                }
            }
            let edge = min(7, max(2, r.width / 4))
            if p.x - r.minX <= edge { return Hit(clip: c, zone: .left, rect: r) }
            if r.maxX - p.x <= edge { return Hit(clip: c, zone: .right, rect: r) }
            if c.kind == .audio, abs(p.y - (r.minY + Self.gainNorm(c.gainDB) * r.height)) <= 3.5 {
                return Hit(clip: c, zone: .gain, rect: r)
            }
            return Hit(clip: c, zone: .body, rect: r)
        }
        return nil
    }

    // MARK: Mouse

    /// While Magic works the editor is locked: clips don't react to the pointer (no highlight, no trim
    /// or level cursors, no skimming).
    private var magicLocked: Bool { MagicState.shared.stage != nil }

    override func mouseMoved(with event: NSEvent) {
        guard !magicLocked else { return clearHover() }
        let p = convert(event.locationInWindow, from: nil)
        updateHover(at: p)
        if model.skimming, !model.isPlaying {
            model.skim(to: time(atX: p.x))
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if model.skimTime != nil {
            model.skim(to: nil)
            needsDisplay = true
        }
        if hover != nil || cutHover != nil {
            hover = nil
            cutHover = nil
            needsDisplay = true
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        (magicLocked ? NSCursor.arrow : cursor).set()
    }

    private func clearHover() {
        if model.skimTime != nil { model.skim(to: nil) }
        if hover != nil || cutHover != nil {
            hover = nil
            cutHover = nil
            needsDisplay = true
        }
        cursor = .arrow
        if window?.isKeyWindow == true, let w = window, bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) {
            NSCursor.arrow.set()
        }
    }

    private func updateHover(at p: CGPoint) {
        var newHover: (id: UUID, zone: Zone)?
        var newCut: (id: UUID, time: Double)?
        var newCursor = NSCursor.arrow

        if p.y < TimelineLayout.ruler {
            newCursor = .arrow
        } else if model.tool == .cut {
            newCursor = Cursors.cut
            if let h = hit(at: p) {
                var t = time(atX: p.x)
                let others = model.project.snapTargets(excluding: [h.clip.id]) + [model.playhead]
                if let s = snap([t], to: others, pixels: 6) { t += s.delta } else { t = model.project.snapFrame(t) }
                let minDur = 0.5 / model.project.fps
                if t > h.clip.start + minDur, t < h.clip.end - minDur {
                    newCut = (h.clip.id, t)
                    newHover = (h.clip.id, .body)
                }
            }
        } else if let h = hit(at: p) {
            newHover = (h.clip.id, h.zone)
            switch h.zone {
            case .left, .right: newCursor = .resizeLeftRight
            case .fadeIn, .fadeOut: newCursor = .pointingHand
            case .gain: newCursor = .resizeUpDown
            case .body: newCursor = .arrow
            }
        }

        let changed = newHover?.id != hover?.id || newHover?.zone != hover?.zone
            || newCut?.id != cutHover?.id || newCut?.time != cutHover?.time
        hover = newHover
        cutHover = newCut
        if changed { needsDisplay = true }
        if newCursor !== cursor {
            cursor = newCursor
        }
        cursor.set()
    }

    override func mouseDown(with event: NSEvent) {
        // Working on the timeline: Delete is for clips again, not Media panel items.
        model.mediaSelection = []
        model.folderSelection = []
        model.incomingSelection = []
        model.skim(to: nil)
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        lastDragPoint = p
        let extend = event.modifierFlags.contains(.shift)

        if p.y < TimelineLayout.ruler {
            // The playhead sits on top of markers, so near it a click takes the playhead; a marker
            // under it can still be clicked by its name.
            let onPlayhead = abs(p.x - x(model.playhead)) <= 6
            if !onPlayhead, let id = markerHit(at: p) {
                drag = .marker(id: id, startX: p.x, moved: false)
                return
            }
            if !onPlayhead, let isIn = rangeEdgeHit(at: p) {
                drag = .rangeEdge(isIn: isIn)
                return
            }
            drag = .scrub
            scrub(to: p)
            return
        }

        // The caption track: pick captions (⇧ adds); a double-click goes to one to retype it.
        if inCaptionRow(p) {
            drag = .none
            guard let b = captionHit(at: p) else {
                if !extend { model.selectCaptions([]) }
                drag = .captionMarquee(origin: CGPoint(x: p.x + view.scrollX, y: p.y + view.scrollY), base: model.captionSelection)
                return
            }
            if extend {
                var picked = model.captionSelection
                if picked.contains(b.id) { picked.remove(b.id) } else { picked.insert(b.id) }
                model.selectCaptions(picked)
            } else {
                model.selectCaptions([b.id])
            }
            if event.clickCount == 2 {
                model.selectCaptions([b.id])
                model.seek(to: (b.start + b.end) / 2)
                model.captionEditRequest = b.id
            } else {
                // Captions don't move, so a drag from one boxes in more.
                drag = .captionMarquee(origin: CGPoint(x: p.x + view.scrollX, y: p.y + view.scrollY),
                                       base: extend ? model.captionSelection : [])
            }
            needsDisplay = true
            return
        }

        if model.tool == .cut {
            updateHover(at: p)
            if let cut = cutHover {
                model.split(clip: cut.id, at: cut.time)
                cutHover = nil
                needsDisplay = true
            }
            return
        }

        guard let h = hit(at: p) else {
            if !extend { model.selection = []; model.releaseCaptions() }
            drag = .marquee(origin: CGPoint(x: p.x + view.scrollX, y: p.y + view.scrollY), base: model.selection,
                            captionBase: extend ? model.captionSelection : [])
            return
        }

        let group = model.project.unlocked(model.project.linked([h.clip.id]))
        switch h.zone {
        case .body:
            if extend {
                if model.selection.contains(h.clip.id) { model.selection.subtract(group) } else { model.selection.formUnion(group) }
                return
            }
            if !model.selection.contains(h.clip.id) { model.selection = group }
            drag = .pendingMove(grabbed: h.clip, point: p, time: time(atX: p.x))
        case .left, .right:
            if !model.selection.contains(h.clip.id) { model.selection = group }
            // Every selected clip's same edge moves together (any track, lined up or not), as in Premiere;
            // with nothing else selected, that's this clip and what's linked to it.
            let trimmed = model.project.unlocked(model.project.linked(model.selection.union(group)))
            let originals = model.project.clips.filter { trimmed.contains($0.id) }
            drag = .trim(grabbed: h.clip, left: h.zone == .left, time: time(atX: p.x), originals: originals)
        case .fadeIn, .fadeOut:
            drag = .fade(id: h.clip.id, fadeIn: h.zone == .fadeIn)
        case .gain:
            if event.clickCount == 2 {
                model.mutate { proj in
                    if let i = proj.index(of: h.clip.id) { proj.clips[i].gainDB = 0 }
                }
                return
            }
            drag = .gain(id: h.clip.id, startY: p.y, startNorm: Self.gainNorm(h.clip.gainDB), height: h.rect.height)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        lastDragPoint = p
        handleDrag(at: p)
        switch drag {
        case .scrub, .move, .trim, .marquee, .captionMarquee: updateAutoscroll(p)
        default: break
        }
    }

    private func handleDrag(at p: CGPoint) {
        switch drag {
        case .none:
            break
        case .scrub:
            scrub(to: p)
        case .pendingMove(let grabbed, let start, let t0):
            guard abs(p.x - start.x) > 3 || abs(p.y - start.y) > 3 else { return }
            let ids = model.project.unlocked(model.project.linked(model.selection))
            let originals = model.project.clips.filter { ids.contains($0.id) }
            moveTrackDelta = 0
            drag = .move(grabbed: grabbed, time: t0, originals: originals)
            NSCursor.closedHand.set()
            updateMove(grabbed: grabbed, startTime: t0, originals: originals, p: p)
        case .move(let grabbed, let t0, let originals):
            updateMove(grabbed: grabbed, startTime: t0, originals: originals, p: p)
        case .trim(let grabbed, let left, let t0, let originals):
            updateTrim(grabbed: grabbed, left: left, startTime: t0, originals: originals, p: p)
        case .fade(let id, let fadeIn):
            let t = time(atX: p.x)
            model.live(autoCommit: false) { proj in
                guard let i = proj.index(of: id) else { return }
                var c = proj.clips[i]
                if fadeIn {
                    c.fadeIn = min(max(0, proj.snapFrame(t - c.start)), c.duration - c.fadeOut)
                } else {
                    c.fadeOut = min(max(0, proj.snapFrame(c.end - t)), c.duration - c.fadeIn)
                }
                proj.clips[i] = c
            }
            if let c = model.project.clip(id) {
                bubble = (String(format: "%.2fs", fadeIn ? c.fadeIn : c.fadeOut), CGPoint(x: p.x, y: p.y - 22))
            }
            needsDisplay = true
        case .gain(let id, let startY, let startNorm, let height):
            let db = Self.gainDB(norm: startNorm + (p.y - startY) / height)
            let value = db <= -59.5 ? -60 : db
            model.live(autoCommit: false) { proj in
                if let i = proj.index(of: id) { proj.clips[i].gainDB = value }
            }
            bubble = (formatDB(value), CGPoint(x: p.x + 12, y: p.y - 22))
            needsDisplay = true
        case .marker(let id, let startX, var moved):
            if !moved, abs(p.x - startX) < 3 { return }
            if !moved { moved = true; drag = .marker(id: id, startX: startX, moved: true) }
            var t = max(0, time(atX: p.x))
            let others = model.project.snapTargets(excluding: []).filter { abs($0 - (model.project.markers?.first { $0.id == id }?.time ?? -1)) > 1e-9 } + [model.playhead]
            if let s = snap([t], to: others, pixels: 6) { t += s.delta }
            let snapped = model.project.snapFrame(t)
            model.updateMarkerLive(id) { $0.time = snapped }
            scrubReadout = snapped
            needsDisplay = true
        case .rangeEdge(let isIn):
            var t = max(0, time(atX: p.x))
            if let s = snap([t], to: model.project.snapTargets(excluding: []) + [model.playhead], pixels: 6) { t += s.delta }
            let snapped = model.project.snapFrame(t)
            model.setRangeEdgeLive(isIn: isIn, to: snapped)
            scrubReadout = snapped
            needsDisplay = true
        case .marquee(let origin, let base, let captionBase):
            let current = CGPoint(x: p.x + view.scrollX, y: p.y + view.scrollY)
            let content = CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                                 width: abs(origin.x - current.x), height: abs(origin.y - current.y))
            let r = content.offsetBy(dx: -view.scrollX, dy: -view.scrollY)
            marquee = r
            var ids = base
            for c in model.project.clips where !model.project.isLocked(c.trackID) {
                if let cr = rect(for: c), cr.intersects(r) { ids.insert(c.id) }
            }
            ids = model.project.unlocked(model.project.linked(ids))
            // A box drawn up over the caption track, touching no clips, picks the captions in it.
            let boxed = Set(model.captionBlocks.filter { captionRect($0)?.intersects(r) == true }.map(\.id))
            let captions = boxed.isEmpty ? boxed : boxed.union(captionBase)
            if ids == base, !captions.isEmpty {
                if captions != model.captionSelection { model.selectCaptions(captions) }
            } else {
                if !model.captionSelection.isEmpty, ids != base { model.releaseCaptions() }
                if ids != model.selection { model.selection = ids }
            }
            needsDisplay = true
        case .captionMarquee(let origin, let base):
            let current = CGPoint(x: p.x + view.scrollX, y: p.y + view.scrollY)
            let r = CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                           width: abs(origin.x - current.x), height: abs(origin.y - current.y))
                .offsetBy(dx: -view.scrollX, dy: -view.scrollY)
            marquee = r
            var ids = base
            for b in model.captionBlocks { if let br = captionRect(b), br.intersects(r) { ids.insert(b.id) } }
            if ids != model.captionSelection { model.selectCaptions(ids) }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        let finished = drag
        drag = .none
        // A trim showed its edge's frame in the viewer: back to the edit.
        if case .trim = finished {
            model.sourcePreview.clear()
            model.engine.endStill()
        }
        switch finished {
        case .move where duplicating:
            // ⌥-drag: the clips stay where they were and copies land where they were dropped.
            let moved = Array(overrides.values)
            overrides = [:]
            duplicating = false
            if !moved.isEmpty, let t0 = moved.map(\.start).min() {
                let copies = model.placed(moved.map { c in var c = c; c.start -= t0; return c }, at: t0)
                    .enumerated().map { i, c -> Clip in var c = c; c.trackID = moved[i].trackID; return c }
                model.insert(copies)
            }
        case .move, .trim:
            let moved = overrides
            overrides = [:]
            if !moved.isEmpty {
                model.mutate { proj in
                    for (id, c) in moved {
                        if let i = proj.index(of: id) { proj.clips[i] = c }
                    }
                    proj.materializeTokens()
                    proj.resolveOverlaps(keeping: Set(moved.keys))
                }
            }
        case .marker(let id, _, let moved):
            scrubReadout = nil
            if moved { model.commitLive() } else { model.editingMarker = id }
        case .rangeEdge:
            scrubReadout = nil
            model.commitLive()
        case .fade, .gain:
            model.commitLive()
        default:
            break
        }
        snapLine = nil
        marquee = nil
        bubble = nil
        scrubReadout = nil
        lastScrubSnap = nil
        needsDisplay = true
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    private func scrub(to p: CGPoint) {
        var t = max(0, time(atX: p.x))
        let s = snap([t], to: model.project.snapTargets(excluding: []), pixels: 6)
        if let s { t += s.delta }
        if let target = s?.target, target != lastScrubSnap { Self.tap() }
        lastScrubSnap = s?.target
        model.scrub(to: t)
        model.scrubSound(at: model.playhead)
        scrubReadout = model.playhead
        needsDisplay = true
    }

    private func updateMove(grabbed: Clip, startTime: Double, originals: [Clip], p: CGPoint) {
        duplicating = NSEvent.modifierFlags.contains(.option)
        (duplicating ? NSCursor.dragCopy : NSCursor.closedHand).set()
        let project = model.project
        let ids = Set(originals.map(\.id))
        let minStart = originals.map(\.start).min() ?? 0
        var dt = max(time(atX: p.x) - startTime, -minStart)
        snapLine = nil
        var snapped = false
        var candidates: [Double] = []
        for c in originals {
            candidates.append(c.start + dt)
            candidates.append(c.end + dt)
        }
        // Moving, the clips' own edges aren't something to snap to. Duplicating (Option), the originals stay where
        // they are, so their edges are: a copy goes straight against the end of the clip it's copied from.
        if let s = snap(candidates, to: project.snapTargets(excluding: duplicating ? [] : ids) + [model.playhead]), minStart + dt + s.delta >= -1e-9 {
            dt += s.delta
            snapLine = s.target
            snapped = true
        }
        if !snapped {
            dt = max(project.snapFrame(grabbed.start + dt) - grabbed.start, -minStart)
        }

        let kind = grabbed.kind.trackKind
        let tracks = project.tracks(kind)
        let previousDelta = moveTrackDelta
        if let gi = project.trackIndex(grabbed.trackID, kind: kind) {
            switch lane(atY: p.y) {
            case .track(let t, let i) where t.kind == kind: moveTrackDelta = i - gi
            case .newVideo where kind == .video: moveTrackDelta = tracks.count - gi
            case .newAudio where kind == .audio: moveTrackDelta = tracks.count - gi
            default: break
            }
        }
        let indices = originals.filter { $0.kind.trackKind == kind }.compactMap { project.trackIndex($0.trackID, kind: kind) }
        if let lo = indices.min(), let hi = indices.max() {
            moveTrackDelta = max(-lo, min(moveTrackDelta, tracks.count - hi))
        }
        // Clips can't be moved onto a locked track.
        if indices.contains(where: { i in tracks.indices.contains(i + moveTrackDelta) && tracks[i + moveTrackDelta].locked }) {
            moveTrackDelta = previousDelta
        }

        // Linked partners on the other kind of track move the same number of tracks, so a clip
        // taken from V1 to V2 has its sound go from A1 to A2 (and back), when they're on matching tracks to
        // start with — but only into space that's free: with other sound already there (music on A2), the
        // sound stays on its own track rather than writing over it.
        let movedLinks = Set(originals.filter { $0.kind.trackKind == kind }.compactMap(\.linkID))
        let otherKind: TrackKind = kind == .video ? .audio : .video
        let otherTracks = project.tracks(otherKind)
        // What the dragged clips land on: a picture taken onto V1 over a clip there may take its sound onto A1 over
        // that same clip's sound (one drag, as Premiere does); sound that isn't theirs (music) still holds it back.
        var overwritten = Set<UUID>()
        for c in originals where c.kind.trackKind == kind {
            guard let i = project.trackIndex(c.trackID, kind: kind) else { continue }
            let ni = i + moveTrackDelta
            guard tracks.indices.contains(ni) else { continue }
            let start = max(0, c.start + dt), end = start + c.duration
            for o in project.clips where o.trackID == tracks[ni].id && !ids.contains(o.id) && o.start < end - 1e-6 && o.end > start + 1e-6 {
                if let link = o.linkID { overwritten.insert(link) }
            }
        }
        func taken(_ track: UUID, from start: Double, to end: Double) -> Bool {
            project.clips.contains { $0.trackID == track && !ids.contains($0.id) && $0.start < end - 1e-6 && $0.end > start + 1e-6
                && !($0.linkID.map(overwritten.contains) ?? false) }
        }

        // Where each dragged clip's track is (V1 = 0), by link: its partner follows only from the matching track (A1
        // with V1), keeping them matched. On another track (a picture on V2 with its sound on A1), it stays put.
        var draggedTrack: [UUID: Int] = [:]
        for c in originals where c.kind.trackKind == kind {
            if let link = c.linkID, let i = project.trackIndex(c.trackID, kind: kind) { draggedTrack[link] = i }
        }
        var out: [UUID: Clip] = [:]
        for var c in originals {
            c.start = max(0, c.start + dt)
            if c.kind.trackKind == kind, let i = project.trackIndex(c.trackID, kind: kind) {
                let ni = i + moveTrackDelta
                c.trackID = ni >= tracks.count ? (kind == .video ? TrackToken.newVideo : TrackToken.newAudio) : tracks[max(0, ni)].id
            } else if c.kind.trackKind == otherKind, let link = c.linkID, movedLinks.contains(link),
                      let i = project.trackIndex(c.trackID, kind: otherKind), draggedTrack[link] == i {
                let ni = max(0, i + moveTrackDelta)
                if ni >= otherTracks.count {
                    c.trackID = otherKind == .video ? TrackToken.newVideo : TrackToken.newAudio
                } else if ni != i, !otherTracks[ni].locked, !taken(otherTracks[ni].id, from: c.start, to: c.end) {
                    c.trackID = otherTracks[ni].id
                }
            }
            out[c.id] = c
        }
        overrides = out
        needsDisplay = true
    }

    private func updateTrim(grabbed: Clip, left: Bool, startTime: Double, originals: [Clip], p: CGPoint) {
        // Sticky keeps touching clips together. A left edge with nothing against it (no clip touching
        // it on its track, for the clip or its linked audio, and not at the very start) has nothing
        // to stay attached to, so it trims freely.
        if model.sticky, !left || Self.attachedOnLeft(originals, in: model.project) {
            return updateStickyTrim(grabbed: grabbed, left: left, startTime: startTime, originals: originals, p: p)
        }
        let project = model.project
        let ids = Set(originals.map(\.id))
        let edge = left ? grabbed.start : grabbed.end
        var d = time(atX: p.x) - startTime
        snapLine = nil
        var snapTarget: Double?
        if let s = snap([edge + d], to: project.snapTargets(excluding: ids) + [model.playhead]) {
            d += s.delta
            snapTarget = s.target
        } else {
            d = project.snapFrame(edge + d) - edge
        }
        var lo = -Double.infinity, hi = Double.infinity
        for c in originals {
            let range = project.trimLimits(c, left: left, excluding: ids)
            lo = max(lo, range.lowerBound)
            hi = min(hi, range.upperBound)
        }
        let clamped = min(max(d, lo), max(lo, hi))
        if clamped == d { snapLine = snapTarget }
        d = clamped

        var out: [UUID: Clip] = [:]
        for var c in originals {
            if left { c.trimHead(to: c.start + d) } else { c.trimTail(to: c.end + d) }
            out[c.id] = c
        }
        overrides = out
        if let g = out[grabbed.id] {
            bubble = (Timecode.string(g.duration, fps: project.fps), CGPoint(x: p.x, y: p.y - 22))
        }
        showTrimFrame(grabbed, left: left)
        needsDisplay = true
    }

    /// Trimming with sticky edges: the clip keeps its start (trimming the head takes content off the
    /// front instead of moving the clip), and everything touching its end follows the new end.
    static func attachedOnLeft(_ clips: [Clip], in project: Project) -> Bool {
        let ids = Set(clips.map(\.id))
        let tolerance = 0.5 / project.fps
        return clips.contains { c in
            c.start <= tolerance || project.clips.contains { o in
                !ids.contains(o.id) && o.trackID == c.trackID && abs(o.end - c.start) <= tolerance
            }
        }
    }

    /// While an edge is dragged, the viewer shows the frame it lands on: a clip's new first frame
    /// trimming its start, its new last frame trimming its end (a video's own, also when its sound is
    /// the edge being dragged).
    private func showTrimFrame(_ grabbed: Clip, left: Bool) {
        let p = model.project
        let video: Clip? = {
            if let c = overrides[grabbed.id], c.kind == .video { return c }
            guard let link = grabbed.linkID else { return nil }
            return overrides.values.first { $0.linkID == link && $0.kind == .video }
        }()
        guard let c = video, let id = c.assetID, let asset = p.asset(id), asset.kind == .video, asset.duration > 0 else { return }
        let t = left ? c.start : max(c.start, c.end - 1 / max(1, p.fps))
        let src = c.isFreeze ? c.sourceStart : c.sourceTime(at: t)
        let shown = min(max(0, c.playsBackwards ? asset.duration - src : src), max(0, asset.duration - 0.02))
        // From the made-ahead frames (as sharp as the viewer's picture), drawn on the GPU straight into
        // the viewer like scrubbing, so it keeps up with the drag; the overlay just says the time. Without
        // them, frames are decoded one after another and shown as they come.
        if let still = model.media.scrubCache.image(id, at: shown), let rt = model.media.runtimes[id] {
            model.engine.showStill(still, orientation: rt.orientation, time: shown)
            model.sourcePreview.label(asset, at: shown, note: left ? "In" : "Out")
        } else {
            model.sourcePreview.show(asset, at: shown, media: model.media, note: left ? "In" : "Out")
        }
    }

    private func updateStickyTrim(grabbed: Clip, left: Bool, startTime: Double, originals: [Clip], p: CGPoint) {
        let project = model.project
        let ids = Set(originals.map(\.id))
        let edge = left ? grabbed.start : grabbed.end
        var d = time(atX: p.x) - startTime
        snapLine = nil
        var snapTarget: Double?
        if let s = snap([edge + d], to: project.snapTargets(excluding: ids) + [model.playhead]) {
            d += s.delta
            snapTarget = s.target
        } else {
            d = project.snapFrame(edge + d) - edge
        }
        // Only the clip's own length and source limit what's possible; neighbours move out of the way.
        let minDur = max(Project.minClip, 1 / project.fps)
        var lo = -Double.infinity, hi = Double.infinity
        for c in originals {
            if left {
                if c.playsSource { lo = max(lo, -c.timelineSpan(from: 0, to: c.sourceStart)) }
                hi = min(hi, c.duration - minDur)
            } else {
                lo = max(lo, minDur - c.duration)
                if let limit = project.sourceLimit(c) { hi = min(hi, c.timelineSpan(from: c.sourceStart, to: limit) - c.duration) }
            }
        }
        let clamped = min(max(d, lo), max(lo, hi))
        if clamped == d { snapLine = snapTarget }

        func result(_ d: Double) -> [UUID: Clip] {
            var edited: [UUID: Clip] = [:]
            for var c in originals {
                if left {
                    let start = c.start
                    c.trimHead(to: c.start + d)
                    c.start = start
                } else {
                    c.trimTail(to: c.end + d)
                }
                edited[c.id] = c
            }
            return edited.merging(project.carried(by: edited)) { a, _ in a }
        }
        var out = result(clamped)
        if !project.fits(out) {
            // Something carried along would hit a clip that isn't moving: go as far as fits.
            snapLine = nil
            var ok = 0.0, bad = clamped
            for _ in 0..<24 {
                let mid = (ok + bad) / 2
                if project.fits(result(mid)) { ok = mid } else { bad = mid }
            }
            out = result(ok)
        }
        overrides = out
        if let g = out[grabbed.id] {
            bubble = (Timecode.string(g.duration, fps: project.fps), CGPoint(x: p.x, y: p.y - 22))
        }
        showTrimFrame(grabbed, left: left)
        needsDisplay = true
    }

    // MARK: Autoscroll while dragging

    private func updateAutoscroll(_ p: CGPoint) {
        let margin: CGFloat = 26
        var v: CGFloat = 0
        if p.x > bounds.width - margin {
            v = min(34, (p.x - (bounds.width - margin)) * 0.6 + 4)
        } else if p.x < margin, view.scrollX > 0 {
            v = -min(34, (margin - p.x) * 0.6 + 4)
        }
        autoscrollVelocity = v
        if v == 0 {
            stopAutoscroll()
        } else if autoscrollTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setScroll(x: self.view.scrollX + self.autoscrollVelocity, y: self.view.scrollY)
                    self.handleDrag(at: self.lastDragPoint)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            autoscrollTimer = timer
        }
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    // MARK: Scrolling & zoom

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let dy = event.scrollingDeltaY * (precise ? 1 : 8)
            model.zoom(by: exp(dy * 0.012))
            return
        }
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !precise {
            dx *= 12
            dy *= 12
            if abs(dx) < 0.01 {
                dx = dy
                dy = 0
            }
        }
        // Lock to the dominant axis so a sideways swipe never nudges the rows (and vice versa).
        if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 }
        setScroll(x: view.scrollX - dx, y: view.scrollY - dy)
    }

    override func magnify(with event: NSEvent) {
        model.zoom(by: 1 + event.magnification)
    }

    // MARK: Responder actions

    override func selectAll(_ sender: Any?) {
        model.selectAll()
    }

    // Edit › Cut, Copy and Paste act on clips while the timeline has focus.
    @objc func copy(_ sender: Any?) { model.copySelection() }
    @objc func cut(_ sender: Any?) { model.cutSelection() }
    @objc func paste(_ sender: Any?) { model.paste() }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)): return !model.selection.isEmpty
        case #selector(paste(_:)): return !model.clipboard.isEmpty
        default: return true
        }
    }

    @objc func delete(_ sender: Any?) {
        model.deleteSelection()
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let model = self.model

        if inCaptionRow(p) {
            if let b = captionHit(at: p) {
                if !model.captionSelection.contains(b.id) { model.selectCaptions([b.id]) }
                menu.addItem(ActionItem("Edit Caption") {
                    model.seek(to: (b.start + b.end) / 2)
                    model.captionEditRequest = b.id
                })
                menu.addItem(ActionItem(model.captionSelection.count > 1 ? "Delete Captions" : "Delete Caption") { model.deleteSelectedCaptions() })
                menu.addItem(ActionItem("Remove Captions from Clip") { model.removeCaptions(from: [b.clipID]) })
                menu.addItem(.separator())
            }
            let hidden = model.project.captions?.hidden ?? false
            menu.addItem(ActionItem(hidden ? "Show Captions" : "Hide Captions") { model.setCaptionsHidden(!hidden) })
            menu.addItem(ActionItem("Delete Caption Track") { model.removeCaptionTrack() })
            return menu
        }

        if let h = hit(at: p) {
            if !model.selection.contains(h.clip.id) { model.selection = model.project.linked([h.clip.id]) }
            let t = model.playhead
            menu.addItem(ActionItem("Split at Playhead", enabled: t > h.clip.start && t < h.clip.end) { model.splitAtPlayhead() })
            menu.addItem(ActionItem("Detach Audio", enabled: model.selectionIsLinked) { model.detachAudio() })
            menu.addItem(ActionItem("Reveal in Media", enabled: h.clip.assetID.flatMap { model.project.asset($0) } != nil) { model.revealInMedia(h.clip.id) })
            if h.clip.kind.usesSource {
                menu.addItem(ActionItem("Freeze Frame at Playhead", enabled: h.clip.kind == .video && !h.clip.isFreeze && t >= h.clip.start && t < h.clip.end) { model.freezeFrame() })
                menu.addItem(ActionItem(!h.clip.isReversed ? "Reverse" : "Play Forwards", enabled: !h.clip.isFreeze) { model.reverseSelection() })
            }
            if h.clip.playsSource {
                let speed = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.autoenablesItems = false
                for pct in [25, 50, 100, 200, 400, 800, 1600, 3000] {
                    sub.addItem(ActionItem("\(pct)%", checked: abs(h.clip.speed * 100 - Double(pct)) < 0.5) { model.setSpeed(Double(pct) / 100) })
                }
                speed.submenu = sub
                menu.addItem(speed)
            }
            // Transitions on the cuts either side of this clip.
            if h.clip.kind != .audio {
                let project = model.project
                func transitionMenu(_ title: String, into clip: Clip) -> NSMenuItem {
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    let sub = NSMenu()
                    sub.autoenablesItems = false
                    sub.addItem(ActionItem("None", checked: clip.transitionIn == nil) { model.setTransition(into: clip.id, nil) })
                    sub.addItem(.separator())
                    for kind in TransitionKind.allCases {
                        sub.addItem(ActionItem(kind.label, checked: clip.transitionIn?.kind == kind) {
                            var t = clip.transitionIn ?? Transition()
                            t.kind = kind
                            model.setTransition(into: clip.id, t)
                        })
                    }
                    item.submenu = sub
                    return item
                }
                if project.previous(touching: h.clip) != nil { menu.addItem(transitionMenu("Transition In", into: h.clip)) }
                if let next = project.next(touching: h.clip) { menu.addItem(transitionMenu("Transition Out", into: next)) }
            }
            if h.clip.kind == .audio {
                menu.addItem(ActionItem("Even Out Levels") { model.evenOutLevels() })
            }
            // Captions from what's said in the clip's sound.
            if !model.project.captionTargets(model.selection).isEmpty {
                if model.hasCaptions(model.selection) {
                    menu.addItem(ActionItem("Remove Captions") { model.removeCaptions() })
                } else {
                    menu.addItem(ActionItem("Add Captions", enabled: Transcripts.available) { model.addCaptions() })
                }
            }
            if h.clip.fadeIn > 0 || h.clip.fadeOut > 0 {
                menu.addItem(ActionItem("Remove Fades") {
                    let ids = model.selection
                    model.mutate { proj in
                        for i in proj.clips.indices where ids.contains(proj.clips[i].id) {
                            proj.clips[i].fadeIn = 0
                            proj.clips[i].fadeOut = 0
                        }
                    }
                })
            }
            if h.clip.kind != .audio {
                menu.addItem(.separator())
                menu.addItem(ActionItem("Copy Grade", enabled: model.canCopyGrade) { model.copyGrade() })
                let count = model.project.clips.filter { model.selection.contains($0.id) && $0.kind != .audio }.count
                menu.addItem(ActionItem(count > 1 ? "Paste Grade to \(count) Clips" : "Paste Grade", enabled: model.canPasteGrade) { model.pasteGrade() })
            }
            if h.clip.kind == .video, let asset = model.project.asset(h.clip.assetID ?? UUID()) {
                menu.addItem(.separator())
                menu.addItem(ActionItem("Match Sequence to Clip", enabled: !model.sequenceMatches(asset)) { model.matchSequence(to: asset) })
            }
            menu.addItem(.separator())
            menu.addItem(ActionItem("Delete") { model.deleteSelection() })
            menu.addItem(ActionItem("Ripple Delete") { model.deleteSelection(ripple: true) })
        } else {
            // Empty space on a track: offer to close the gap here, or every gap on the track.
            if case .track(let track, _) = lane(atY: p.y), !track.locked {
                let t = time(atX: p.x)
                menu.addItem(ActionItem("Delete Gap", enabled: model.project.gap(on: track.id, at: t) != nil) {
                    model.deleteGap(on: track.id, at: t)
                })
                menu.addItem(ActionItem("Close All Gaps on Track") { model.closeAllGaps(on: [track.id]) })
                menu.addItem(.separator())
            }
            menu.addItem(ActionItem("Add Video Track") { model.addTrack(.video) })
            menu.addItem(ActionItem("Add Audio Track") { model.addTrack(.audio) })
            if case .track(let track, _) = lane(atY: p.y), model.project.tracks(track.kind).count > 1 {
                menu.addItem(.separator())
                menu.addItem(ActionItem("Delete Track") { model.removeTrack(track.id) })
            }
        }
        return menu
    }

    // MARK: Drag & drop

    /// What's being dragged in from the Media panel: one item, or several picked ones, which land end to end.
    private func payloads(from sender: NSDraggingInfo) -> [DragPayload] {
        if let s = sender.draggingPasteboard.string(forType: .string), s.hasPrefix("editroom:") {
            let body = String(s.dropFirst("editroom:".count))
            if body == "solid" { return [.solid] }
            if body == "text" { return [.text] }
            let ids = body.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            if !ids.isEmpty { return ids.map { .asset($0) } }
        }
        return model.dragPayload.map { [$0] } ?? []
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let hasFiles = sender.draggingPasteboard.types?.contains(.fileURL) ?? false
        let payloads = hasFiles ? [] : self.payloads(from: sender)
        guard hasFiles || !payloads.isEmpty else { return [] }

        let project = model.project
        let vTracks = project.videoTracks, aTracks = project.audioTracks
        guard !vTracks.isEmpty, !aTracks.isEmpty else { return [] }
        var vTrack = vTracks[0].id, aTrack = aTracks[0].id
        var overAudio = false
        switch lane(atY: p.y) {
        case .track(let t, let i) where t.kind == .video:
            vTrack = t.id
            aTrack = aTracks[min(i, aTracks.count - 1)].id
        case .track(let t, let i):
            aTrack = t.id
            vTrack = vTracks[min(i, vTracks.count - 1)].id
            overAudio = true
        case .newVideo:
            vTrack = TrackToken.newVideo
            aTrack = aTracks[min(vTracks.count, aTracks.count - 1)].id
        case .newAudio:
            aTrack = TrackToken.newAudio
            vTrack = vTracks[min(aTracks.count, vTracks.count - 1)].id
            overAudio = true
        case .none:
            break
        }

        // Nothing lands on a locked track: use the nearest open one, or a new track.
        func open(_ id: UUID, _ kind: TrackKind) -> UUID {
            guard project.isLocked(id) else { return id }
            return project.tracks(kind).first { !$0.locked }?.id ?? (kind == .video ? TrackToken.newVideo : TrackToken.newAudio)
        }
        vTrack = open(vTrack, .video)
        aTrack = open(aTrack, .audio)

        let duration = payloads.isEmpty ? 5 : payloads.reduce(0) { $0 + model.payloadDuration($1) }
        // Over the track headers (left of the first frame): the very start of the timeline, on the row it's over.
        var start = p.x < 0 ? 0 : max(0, time(atX: p.x))
        if let s = snap([start, start + duration], to: project.snapTargets(excluding: []) + [model.playhead]), start + s.delta >= -1e-9 {
            start = max(0, start + s.delta)
            snapLine = s.target
        } else {
            snapLine = nil
            start = project.snapFrame(start)
        }

        if !payloads.isEmpty {
            var t = start
            ghosts = []
            for payload in payloads {
                ghosts += model.makeClips(payload, at: t, videoTrack: vTrack, audioTrack: aTrack)
                t = project.snapFrame(t + model.payloadDuration(payload))
            }
        } else {
            ghosts = [Clip(trackID: overAudio ? aTrack : vTrack, kind: overAudio ? .audio : .video, start: start, duration: duration)]
            let files = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            fileGhostLabel = files.first.map { f in
                let name = f.deletingPathExtension().lastPathComponent
                return files.count > 1 ? "\(name) + \(files.count - 1) more" : name
            }
        }
        dropInfo = (vTrack, aTrack, start)
        needsDisplay = true
        return .copy
    }

    private func clearDrop() {
        ghosts = []
        fileGhostLabel = nil
        dropInfo = nil
        snapLine = nil
        needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearDrop() }
    override func draggingEnded(_ sender: NSDraggingInfo) { clearDrop() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        _ = updateDrop(sender)
        guard let info = dropInfo else { return false }
        let urls = fileURLs(from: sender)
        let pending = ghosts
        clearDrop()
        if !urls.isEmpty {
            let model = self.model
            model.importFiles(urls) { assets in
                var t = info.start
                var clips: [Clip] = []
                for a in assets {
                    let payload = DragPayload.asset(a.id)
                    clips += model.makeClips(payload, at: t, videoTrack: info.video, audioTrack: info.audio)
                    t += model.payloadDuration(payload)
                }
                model.insert(clips)
                // Only the new timeline clips are picked, so Delete takes them off the timeline, not out of Media.
                model.clearMediaPicks()
            }
            return true
        }
        guard !pending.isEmpty else { return false }
        model.insert(pending)
        model.dragPayload = nil
        // Only the new timeline clips are picked, so Delete takes them off the timeline, not out of Media.
        model.clearMediaPicks()
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: Drawing

    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
        .foregroundColor: NSColor(white: 1, alpha: 0.95),
        // Keeps names readable where the waveform runs up behind them.
        .shadow: {
            let s = NSShadow()
            s.shadowColor = NSColor(white: 0, alpha: 0.8)
            s.shadowBlurRadius = 2.5
            s.shadowOffset = NSSize(width: 0, height: -0.5)
            return s
        }(),
    ]
    private static var rulerAttrs: [NSAttributedString.Key: Any] { [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: Theme.NS.textFaint,
    ] }
    private static let bubbleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let project = model.project
        layout = TimelineLayout(project: project, rowHeight: view.rowHeight)
        let ruler = TimelineLayout.ruler

        Theme.NS.bg.setFill()
        bounds.fill()

        // Lanes
        for row in layout.rows {
            let r = CGRect(x: 0, y: ruler + row.y - view.scrollY, width: bounds.width, height: row.height)
            guard r.maxY > ruler, r.minY < bounds.height else { continue }
            let off = row.track.locked || (row.track.kind == .video ? row.track.hidden : !project.isAudible(row.track))
            (off ? Theme.NS.bg.blended(withFraction: 0.4, of: Theme.NS.lane)! : Theme.NS.lane).setFill()
            r.fill()
        }

        // The caption track: its captions as blocks of their words.
        if let cy = layout.captionY {
            let lane = CGRect(x: 0, y: ruler + cy - view.scrollY, width: bounds.width, height: TimelineLayout.captionRow)
            if lane.maxY > ruler, lane.minY < bounds.height {
                let hidden = project.captions?.hidden ?? false
                (hidden ? Theme.NS.bg.blended(withFraction: 0.4, of: Theme.NS.lane)! : Theme.NS.lane).setFill()
                lane.fill()
                drawCaptions(ctx, lane: lane, dim: hidden)
            }
        }

        // An empty timeline says how to fill it, across V1.
        if project.clips.isEmpty, ghosts.isEmpty, let v1 = project.videoTracks.first, let band = layout.band(for: v1.id) {
            let hint = NSAttributedString(string: "Drag media here, or double-click it in the library", attributes: Self.hintAttrs)
            let size = hint.size()
            let y = ruler + band.y - view.scrollY + (band.height - size.height) / 2
            hint.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: y))
        }

        // "New track" drop zones
        let targets = Set(ghosts.map(\.trackID)).union(overrides.values.map(\.trackID))
        for (token, zoneY) in [(TrackToken.newVideo, layout.videoZoneY), (TrackToken.newAudio, layout.audioZoneY)] where targets.contains(token) {
            let r = CGRect(x: 0, y: ruler + zoneY - view.scrollY, width: bounds.width, height: TimelineLayout.zone)
            Theme.NS.accent.withAlphaComponent(0.1).setFill()
            r.fill()
        }
        // Highlight the lanes a drag will land on
        for row in layout.rows where targets.contains(row.track.id) {
            let r = CGRect(x: 0, y: ruler + row.y - view.scrollY, width: bounds.width, height: row.height)
            Theme.NS.ink(0.035).setFill()
            r.fill()
        }

        // Clips
        // While ⌥-dragging, the originals stay put and the dragged ones are the copies.
        let lifted = duplicating ? Set<UUID>() : Set(overrides.keys)
        for c in project.clips where !lifted.contains(c.id) {
            drawClip(c, ctx: ctx, alpha: project.isLocked(c.trackID) ? 0.45 : 1)
        }
        for c in overrides.values {
            drawClip(c, ctx: ctx, alpha: 0.82)
        }
        for c in ghosts {
            drawClip(c, ctx: ctx, alpha: 0.55)
        }

        // Transitions: a hatched block over the stretch each one covers.
        for b in project.clips where b.transitionIn != nil && !lifted.contains(b.id) {
            guard let a = project.previous(touching: b), !lifted.contains(a.id),
                  let span = project.transitionSpan(from: a, into: b), let band = rect(for: b) else { continue }
            let r = CGRect(x: x(span.start), y: band.minY + 3, width: max(4, x(span.end) - x(span.start)), height: band.height - 6)
            guard r.maxX > 0, r.minX < bounds.width else { continue }
            let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
            ctx.setLineWidth(2)
            var sx = r.minX - r.height
            while sx < r.maxX {
                ctx.move(to: CGPoint(x: sx, y: r.maxY))
                ctx.addLine(to: CGPoint(x: sx + r.height, y: r.minY))
                sx += 7
            }
            ctx.strokePath()
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(model.selection.contains(b.id) ? 1 : 0.75).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }

        // Skim line: where the viewer is showing, while the playhead stays put.
        if let t = model.skimTime {
            let sx = x(t)
            ctx.setFillColor(Theme.NS.ink(0.55).cgColor)
            ctx.fill(CGRect(x: sx - 0.5, y: TimelineLayout.ruler, width: 1, height: bounds.height - TimelineLayout.ruler))
            ctx.fill(CGRect(x: sx - 3, y: TimelineLayout.ruler - 6, width: 6, height: 6))
        }

        // Cut preview
        if let cut = cutHover {
            let group = project.linked([cut.id])
            for c in project.clips where group.contains(c.id) && cut.time > c.start && cut.time < c.end {
                guard let r = rect(for: c) else { continue }
                let cx = x(cut.time)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: cx - 0.75, y: r.minY, width: 1.5, height: r.height))
            }
        }

        // Snap guide
        if let s = snapLine {
            // A white line with a dot at each end of the clips it joins.
            let sx = x(s)
            let ys = (Array(overrides.values) + ghosts).compactMap { rect(for: $0) }
            let top = max(ruler, (ys.map(\.minY).min() ?? ruler) - 4)
            let bottom = min(bounds.height, (ys.map(\.maxY).max() ?? bounds.height) + 4)
            ctx.setFillColor(Theme.NS.ink(0.9).cgColor)
            ctx.fill(CGRect(x: sx - 0.5, y: top, width: 1, height: bottom - top))
            for y in [top, bottom] { ctx.fillEllipse(in: CGRect(x: sx - 3, y: y - 3, width: 6, height: 6)) }
        }

        // The magic show's snap guides and blade lines.
        for line in magicMarks.snaps {
            guard let c = project.clip(line.clip), let r = rect(for: c) else { continue }
            let sx = x(line.time)
            let top = max(ruler, r.minY - 4), bottom = min(bounds.height, r.maxY + 4)
            ctx.setFillColor(Theme.NS.ink(0.9).cgColor)
            ctx.fill(CGRect(x: sx - 0.5, y: top, width: 1, height: bottom - top))
            for y in [top, bottom] { ctx.fillEllipse(in: CGRect(x: sx - 3, y: y - 3, width: 6, height: 6)) }
        }
        for line in magicMarks.cuts {
            guard let c = project.clip(line.clip), let r = rect(for: c) else { continue }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: x(line.time) - 0.75, y: r.minY + 2, width: 1.5, height: r.height - 4))
        }

        // Marquee
        if let m = marquee {
            ctx.setFillColor(Theme.NS.accent.withAlphaComponent(0.12).cgColor)
            ctx.fill(m)
            ctx.setStrokeColor(Theme.NS.accent.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(m.insetBy(dx: 0.5, dy: 0.5))
        }

        // Outside the in/out range is dimmed; markers run a faint line down through the tracks.
        if let r = project.playRange {
            ctx.setFillColor(NSColor(white: 0, alpha: 0.32).cgColor)
            let a = x(r.start), b = x(r.end)
            if a > 0 { ctx.fill(CGRect(x: 0, y: ruler, width: a, height: bounds.height - ruler)) }
            if b < bounds.width { ctx.fill(CGRect(x: b, y: ruler, width: bounds.width - b, height: bounds.height - ruler)) }
        }
        for m in project.markerList {
            let mx = x(m.time).rounded()
            guard mx > -1, mx < bounds.width + 1 else { continue }
            ctx.setFillColor(NSColor(hex: m.tint.hex).withAlphaComponent(0.45).cgColor)
            ctx.fill(CGRect(x: mx, y: ruler, width: 1, height: bounds.height - ruler))
        }

        drawRuler(ctx, project: project)

        // Value bubble
        if let b = bubble {
            let text = NSAttributedString(string: b.text, attributes: Self.bubbleAttrs)
            let size = text.size()
            var r = CGRect(x: b.point.x - size.width / 2 - 7, y: b.point.y - size.height / 2 - 3, width: size.width + 14, height: size.height + 6)
            r.origin.x = min(max(4, r.origin.x), bounds.width - r.width - 4)
            r.origin.y = max(ruler + 2, r.origin.y)
            ctx.setFillColor(NSColor(white: 0.05, alpha: 0.92).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            text.draw(at: CGPoint(x: r.minX + 7, y: r.minY + 3))
        }

        // The playhead's time beside its flag while it's being dragged.
        if let t = scrubReadout ?? (model.showPlayheadTime ? model.playhead : nil) {
            let text = NSAttributedString(string: Timecode.string(t, fps: project.fps), attributes: Self.readoutAttrs)
            let size = text.size()
            var r = CGRect(x: x(t) + 10, y: 4, width: size.width + 12, height: size.height + 4)
            if r.maxX > bounds.width - 4 { r.origin.x = x(t) - 10 - r.width }
            ctx.setFillColor(Theme.NS.accent.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            text.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 2))
        }
    }

    /// The captions as they'll be: while clips are dragged or trimmed, laid out from where they are now.
    private var shownCaptions: [CaptionBlock] {
        guard !overrides.isEmpty else { return model.captionBlocks }
        var q = model.project
        for (id, c) in overrides {
            if duplicating {
                // ⌥-drag: the copies, as well as the originals where they were.
                var copy = c
                copy.id = UUID()
                q.clips.append(copy)
            } else if let i = q.index(of: id) {
                q.clips[i] = c
            }
        }
        return CaptionLayout.blocks(q) { model.media.transcript($0.id) }
    }

    private func drawCaptions(_ ctx: CGContext, lane: CGRect, dim: Bool) {
        let blocks = shownCaptions
        if blocks.isEmpty {
            let note = model.captionsWaiting ? "Listening for what's said…"
                : Transcripts.shared.unsupportedLanguage.map { "\($0) speech can't be transcribed on this Mac yet" }
                ?? "No speech heard in the captioned clips"
            let hint = NSAttributedString(string: note, attributes: Self.hintAttrs)
            hint.draw(at: CGPoint(x: 12, y: lane.midY - hint.size().height / 2))
            return
        }
        let fill = Theme.NS.textClip
        for b in blocks {
            guard let full = captionRect(b), full.maxX > -4, full.minX < bounds.width + 4 else { continue }
            let r = full.insetBy(dx: min(0.5, full.width / 4), dy: 3)
            let path = CGPath(roundedRect: r, cornerWidth: min(5, r.width / 2), cornerHeight: min(5, r.width / 2), transform: nil)
            let selected = model.captionSelection.contains(b.id)
            ctx.saveGState()
            ctx.setAlpha(dim ? 0.45 : 1)
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
            if r.width > 18 {
                ctx.addPath(path)
                ctx.clip()
                let text = NSAttributedString(string: b.text, attributes: Self.captionAttrs)
                text.draw(at: CGPoint(x: max(r.minX, 0) + 6, y: r.midY - text.size().height / 2))
            }
            ctx.restoreGState()
            if selected {
                ctx.addPath(path)
                ctx.setStrokeColor(Theme.NS.selection.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokePath()
            }
        }
    }

    private static var captionAttrs: [NSAttributedString.Key: Any] { [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ] }

    private static var hintAttrs: [NSAttributedString.Key: Any] { [
        .font: NSFont.systemFont(ofSize: 11.5),
        .foregroundColor: Theme.NS.hint,
    ] }

    private static let readoutAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    private func drawRuler(_ ctx: CGContext, project: Project) {
        let ruler = TimelineLayout.ruler
        Theme.NS.panel.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: ruler).fill()
        ctx.setFillColor(Theme.NS.stroke.cgColor)
        ctx.fill(CGRect(x: 0, y: ruler - 1, width: bounds.width, height: 1))

        let fps = project.fps
        let f = 1 / fps
        let steps: [(Double, Int)] = [
            (f, 1), (2 * f, 2), (5 * f, 5), (10 * f, 5), (1, 4), (2, 4), (5, 5), (10, 5), (15, 3), (30, 6),
            (60, 6), (120, 4), (300, 5), (600, 5), (900, 3), (1800, 6), (3600, 6), (7200, 4), (18000, 5), (36000, 5),
        ]
        var step = steps.last!
        for s in steps where CGFloat(s.0) * pps >= 86 && (s.0 >= 1 || s.0 < 0.5) {
            step = s
            break
        }
        let (major, subdivisions) = step
        let t0 = time(atX: 0), t1 = time(atX: bounds.width)
        var k = Int(floor(t0 / major))
        let showFrames = major < 1
        while Double(k) * major <= t1 {
            let t = Double(k) * major
            let px = x(t)
            if t >= 0 {
                ctx.setFillColor(Theme.NS.ink(0.28).cgColor)
                ctx.fill(CGRect(x: px.rounded(), y: ruler - 9, width: 1, height: 8))
                var label = Timecode.short(t)
                if showFrames {
                    if TimeStyle.current == .simple {
                        // Zoomed in, with plain times: hundredths, as the viewer shows them.
                        label = Timecode.simple(t)
                    } else {
                        let frames = Int((t * fps).rounded()) % max(1, Int(fps.rounded()))
                        label = Timecode.short(floor(t + 1e-6)) + String(format: ":%02d", frames)
                    }
                }
                (label as NSString).draw(at: CGPoint(x: px + 5, y: 5), withAttributes: Self.rulerAttrs)
            }
            if subdivisions > 1 {
                ctx.setFillColor(Theme.NS.ink(0.13).cgColor)
                for j in 1..<subdivisions {
                    let mt = t + major * Double(j) / Double(subdivisions)
                    if mt >= 0 { ctx.fill(CGRect(x: x(mt).rounded(), y: ruler - 5, width: 1, height: 4)) }
                }
            }
            k += 1
        }

        // Markers: a coloured flag with the name beside it.
        for m in project.markerList {
            let mx = x(m.time).rounded()
            let label = markerLabel(m)
            guard mx + 12 + label.size().width > 0, mx < bounds.width + 1 else { continue }
            let color = NSColor(hex: m.tint.hex)
            let size = label.size()
            ctx.setFillColor(Theme.NS.panel.cgColor)
            ctx.fill(CGRect(x: mx + 1, y: 3, width: size.width + 14, height: ruler - 5))
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: mx, y: 4, width: 1, height: ruler - 5))
            let flag = CGMutablePath()
            flag.move(to: CGPoint(x: mx, y: 4))
            flag.addLine(to: CGPoint(x: mx + 8, y: 4))
            flag.addLine(to: CGPoint(x: mx + 6, y: 8))
            flag.addLine(to: CGPoint(x: mx + 8, y: 12))
            flag.addLine(to: CGPoint(x: mx, y: 12))
            flag.closeSubpath()
            ctx.addPath(flag)
            ctx.fillPath()
            label.draw(at: CGPoint(x: mx + 11, y: 5))
        }

        // In/out: the stretch between is lit, with a white bracket at each end.
        if project.inPoint != nil || project.outPoint != nil {
            let a = project.inPoint.map { x($0) }, b = project.outPoint.map { x($0) }
            if let r = project.playRange {
                ctx.setFillColor(Theme.NS.ink(0.06).cgColor)
                ctx.fill(CGRect(x: x(r.start), y: 0, width: x(r.end) - x(r.start), height: ruler - 1))
            }
            ctx.setFillColor(Theme.NS.ink.cgColor)
            for (edge, inward) in [(a, CGFloat(1)), (b, CGFloat(-1))] {
                guard let ex = edge?.rounded() else { continue }
                ctx.fill(CGRect(x: ex - 1, y: 2, width: 2, height: ruler - 3))
                ctx.fill(CGRect(x: inward > 0 ? ex - 1 : ex - 5, y: 2, width: 6, height: 2))
                ctx.fill(CGRect(x: inward > 0 ? ex - 1 : ex - 5, y: ruler - 3, width: 6, height: 2))
            }
        }
    }

    private static var markerAttrs: [NSAttributedString.Key: Any] { [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: Theme.NS.text.withAlphaComponent(0.92),
    ] }

    private func markerLabel(_ m: Marker) -> NSAttributedString {
        NSAttributedString(string: m.name, attributes: Self.markerAttrs)
    }

    /// The marker whose flag or name is under a point on the ruler (the last drawn wins).
    private func markerHit(at p: CGPoint) -> UUID? {
        for m in model.project.markerList.reversed() {
            let mx = x(m.time)
            if p.x >= mx - 4, p.x <= mx + 12 + markerLabel(m).size().width { return m.id }
        }
        return nil
    }

    private func rangeEdgeHit(at p: CGPoint) -> Bool? {
        let project = model.project
        if let i = project.inPoint, abs(p.x - x(i)) < 5 { return true }
        if let o = project.outPoint, abs(p.x - x(o)) < 5 { return false }
        return nil
    }

    // MARK: Marker panel

    private var markerPopover: NSPopover?

    private func showMarkerPanel(_ id: UUID?) {
        guard let id else {
            markerPopover?.performClose(nil)
            return
        }
        guard let m = model.project.markers?.first(where: { $0.id == id }), window != nil else { return }
        if let open = markerPopover, open.isShown, let host = open.contentViewController as? NSHostingController<MarkerPanel> {
            host.rootView = MarkerPanel(model: model, id: id)
            open.contentSize = host.view.fittingSize
            open.positioningRect = markerAnchor(m)
            return
        }
        let host = NSHostingController(rootView: MarkerPanel(model: model, id: id))
        // Sized to its content before showing, so it opens right at the flag and doesn't shrink
        // away from it afterwards.
        host.sizingOptions = [.preferredContentSize]
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.appearance = NSAppearance(named: Theme.current.isLight ? .aqua : .darkAqua)
        pop.contentViewController = host
        pop.contentSize = host.view.fittingSize
        pop.delegate = self
        markerPopover = pop
        // Above the flag (this view is flipped, so minY is its top edge): the timeline sits at the
        // bottom of the window, so there's rarely room below.
        pop.show(relativeTo: markerAnchor(m), of: self, preferredEdge: .minY)
    }

    fileprivate func markerPopoverClosed() {
        markerPopover = nil
        if model.editingMarker != nil { model.editingMarker = nil }
        // Hand focus back to the editor window, so keys and menus go where they should.
        if let window, NSApp.isActive {
            window.makeKey()
            window.makeFirstResponder(self)
        }
    }

    private func markerAnchor(_ m: Marker) -> CGRect {
        let mx = min(max(4, x(m.time)), bounds.width - 4)
        return CGRect(x: mx, y: 0, width: 8, height: TimelineLayout.ruler)
    }

    private func drawClip(_ c: Clip, ctx: CGContext, alpha: CGFloat) {
        guard let full = rect(for: c) else { return }
        guard full.maxX > -4, full.minX < bounds.width + 4, full.maxY > TimelineLayout.ruler, full.minY < bounds.height else { return }
        let r = full.insetBy(dx: 0, dy: 2).insetBy(dx: min(0.5, full.width / 4), dy: 0)
        let thumbs = model.thumbnails
        let base = thumbs ? Theme.NS.clip(c.kind) : Theme.NS.clipType(c.kind)
        let selected = model.selection.contains(c.id) || magicMarks.selected.contains(c.id)
        let hovered = hover?.id == c.id
        var zone = hovered ? hover?.zone : magicZone(c.id)
        // Hovering a selected clip's edge shows that edge on every selected clip too, since a drag trims them
        // all; and while trimming, every clip being trimmed keeps its edge lit.
        if !hovered, let h = hover, h.zone == .left || h.zone == .right, model.selection.contains(h.id),
           model.selection.contains(c.id), !model.project.isLocked(c.trackID) {
            zone = h.zone
        }
        if case .trim(_, let left, _, let originals) = drag, originals.contains(where: { $0.id == c.id }) {
            zone = left ? .left : .right
        }
        let radius = min(7, r.width / 2)
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let visible = r.intersection(bounds.insetBy(dx: -2, dy: 0))
        let asset = model.project.asset(c.assetID)
        let offline = c.kind.usesSource || c.kind == .image ? (asset.map { model.media.looksOffline($0) } ?? true) : false

        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.addPath(path)
        ctx.clip()

        let fill = offline && !ghosts.contains(where: { $0.id == c.id })
            ? Theme.NS.offline
            : base
        ctx.setFillColor(fill.cgColor)
        ctx.fill(r)

        switch c.kind {
        case .video:
            if thumbs, let asset { drawFilmstrip(c, asset: asset, in: r, visible: visible, ctx: ctx) }
        case .image:
            if thumbs, let img = model.media.still(c.assetID).map({ graded($0, c.grade) }) {
                let tileW = max(20, r.height * CGFloat(img.width) / CGFloat(max(1, img.height)))
                var tx = r.minX + floor(max(0, visible.minX - r.minX) / tileW) * tileW
                ctx.setAlpha(alpha * 0.85)
                while tx < visible.maxX {
                    drawImage(img, fill: CGRect(x: tx, y: r.minY, width: tileW, height: r.height), ctx: ctx)
                    tx += tileW
                }
                ctx.setAlpha(alpha)
            }
        case .audio:
            drawWaveform(c, in: r, visible: visible, ctx: ctx)
        case .solid:
            ctx.setFillColor(c.color.nsColor.cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.maxY - 5, width: r.width, height: 5))
        case .text:
            break
        }

        // Title strip
        if r.width > 26, r.height > 20 {
            if thumbs, c.kind == .video || c.kind == .image {
                ctx.setFillColor(NSColor(white: 0, alpha: 0.45).cgColor)
                ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 17))
            }
            // Files from Finder being dropped have no library item yet: their outline shows the file's name, not "Missing".
            var label = c.assetID == nil && c.kind.usesSource && ghosts.contains(where: { $0.id == c.id })
                ? (fileGhostLabel ?? "") : model.project.name(of: c)
            if c.isFreeze { label += "   Freeze" } else if abs(c.speed - 1) > 0.001 { label += "   \(Int((c.speed * 100).rounded()))%" }
            if c.isReversed { label += "   Reversed" }
            if c.kind == .audio, abs(c.gainDB) > 0.05 { label += "   " + formatDB(c.gainDB) }
            var lx = max(r.minX, 0) + 8
            if r.width > 36, c.fadeIn > 0 { lx = max(lx, fadeHandleX(c, r, fadeIn: true) + 10) }
            ctx.saveGState()
            ctx.clip(to: CGRect(x: r.minX, y: r.minY, width: max(0, r.width - 16), height: 18))
            (label as NSString).draw(at: CGPoint(x: lx, y: r.minY + 2.5), withAttributes: Self.labelAttrs)
            // A graded clip says so, and which Look: "● Warm film", or "● Graded" for adjustments only. A grade
            // that's off is still there, faint and struck through, so it isn't forgotten.
            if let grade = c.grade, !grade.isNeutral, c.kind != .audio {
                let x = lx + (label as NSString).size(withAttributes: Self.labelAttrs).width + 9
                ctx.saveGState()
                if grade.off { ctx.setAlpha(0.45) }
                drawGradeWheel(center: CGPoint(x: x + 4.5, y: r.minY + 9.5), radius: 4.5, ctx: ctx)
                let tag = grade.look != nil ? grade.lookLabel : "Graded"
                var attrs = Self.labelAttrs
                if grade.off { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                (tag as NSString).draw(at: CGPoint(x: x + 13, y: r.minY + 2.5), withAttributes: attrs)
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }

        // Fades
        for isIn in [true, false] {
            let w = CGFloat(isIn ? c.fadeIn : c.fadeOut) * pps
            guard w > 0.5 else { continue }
            let curve = isIn ? c.inCurve : c.outCurve
            let edge = isIn ? r.minX : r.maxX
            let dir: CGFloat = isIn ? 1 : -1
            let line = CGMutablePath()
            let steps = 24
            for i in 0...steps {
                let n = Double(i) / Double(steps)
                let pt = CGPoint(x: edge + dir * CGFloat(n) * w, y: r.maxY - CGFloat(curve.apply(n)) * r.height)
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            if let shade = line.mutableCopy() {
                shade.addLine(to: CGPoint(x: edge, y: r.minY))
                shade.closeSubpath()
                ctx.addPath(shade)
                ctx.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
                ctx.fillPath()
            }
            ctx.addPath(line)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }

        // Gain line
        if c.kind == .audio, r.width > 8 {
            let gy = (r.minY + Self.gainNorm(c.gainDB) * r.height).rounded() + 0.5
            let hot = zone == .gain
            ctx.setStrokeColor(NSColor(white: 1, alpha: hot ? 1 : 0.5).cgColor)
            ctx.setLineWidth(hot ? 2 : 1)
            ctx.move(to: CGPoint(x: r.minX, y: gy))
            ctx.addLine(to: CGPoint(x: r.maxX, y: gy))
            ctx.strokePath()
        }

        // Edge affordance
        if zone == .left || zone == .right {
            ctx.setFillColor(NSColor.white.cgColor)
            let ex = zone == .left ? r.minX : r.maxX - 3.5
            ctx.fill(CGRect(x: ex, y: r.minY, width: 3.5, height: r.height))
        }
        ctx.restoreGState()

        // Border
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        if selected {
            ctx.setStrokeColor(Theme.NS.selection.cgColor)
            ctx.setLineWidth(1.5)
        } else if hovered {
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.6).cgColor)
            ctx.setLineWidth(1)
        } else {
            // Flat colour clips are edged in a lighter tone of their own colour, so cuts between
            // clips of one type still show.
            let edge = thumbs ? Theme.NS.clipStroke : (base.blended(withFraction: 0.18, of: .white) ?? base)
            ctx.setStrokeColor(edge.cgColor)
            ctx.setLineWidth(1)
        }
        ctx.strokePath()

        // Fade handles
        // Only for fades that are set (in the inspector, or dragged after).
        if r.width > 36, alpha == 1, c.fadeIn > 0 || c.fadeOut > 0 {
            // The longer fade's dot is drawn last, on top, matching which one takes the click.
            for isIn in c.fadeIn > c.fadeOut ? [false, true] : [true, false] {
                let active = (isIn ? c.fadeIn : c.fadeOut) > 0
                guard active else { continue }
                let hot = zone == (isIn ? .fadeIn : .fadeOut)
                let hx = fadeHandleX(c, r, fadeIn: isIn)
                let rad: CGFloat = hot ? 5.5 : 4
                let dot = CGRect(x: hx - rad, y: r.minY + 8 - rad, width: rad * 2, height: rad * 2)
                ctx.setFillColor((hot ? Theme.NS.accent : NSColor.white).cgColor)
                ctx.fillEllipse(in: dot)
                ctx.setStrokeColor(NSColor(white: 0, alpha: 0.55).cgColor)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: dot)
            }
        }
        ctx.restoreGState()
    }

    // MARK: Graded thumbnails

    /// A small colour wheel: the mark for a graded clip.
    private func drawGradeWheel(center: CGPoint, radius: CGFloat, ctx: CGContext) {
        let hues: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.35, 0.29), (1, 0.82, 0.29), (0.35, 0.86, 0.42), (0.29, 0.72, 1), (0.6, 0.42, 1), (1, 0.35, 0.6)]
        ctx.saveGState()
        ctx.setFillColor(NSColor(white: 0, alpha: 0.5).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - radius - 0.75, y: center.y - radius - 0.75, width: (radius + 0.75) * 2, height: (radius + 0.75) * 2))
        for (i, h) in hues.enumerated() {
            let a0 = CGFloat(i) / CGFloat(hues.count) * 2 * .pi - .pi / 2
            let a1 = CGFloat(i + 1) / CGFloat(hues.count) * 2 * .pi - .pi / 2
            ctx.move(to: center)
            ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1 + 0.02, clockwise: false)
            ctx.closePath()
            ctx.setFillColor(NSColor(srgbRed: h.0, green: h.1, blue: h.2, alpha: 1).cgColor)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    private struct GradedKey: Hashable {
        let image: ObjectIdentifier
        let grade: ColorGrade
    }

    /// Thumbnails with their clip's grade applied, so the timeline shows clips as they'll look.
    private var gradedThumbs: [GradedKey: (source: CGImage, graded: CGImage)] = [:]

    /// A thumbnail with a grade applied: the same colour cube the viewer and export use.
    private func graded(_ img: CGImage, _ grade: ColorGrade?) -> CGImage {
        guard let grade, let cube = GradeBaker.cube(for: grade) else { return img }
        let key = GradedKey(image: ObjectIdentifier(img), grade: grade)
        if let hit = gradedThumbs[key], hit.source === img { return hit.graded }
        let out = CIImage(cgImage: img).applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": GradeCube.dimension,
            "inputCubeData": cube,
        ])
        guard let result = TimelineCompositor.context.createCGImage(out, from: CGRect(x: 0, y: 0, width: img.width, height: img.height),
                                                                    format: .RGBA8, colorSpace: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
        else { return img }
        // Dragging a grade slider makes a new grade every frame; old ones are let go in bulk.
        if gradedThumbs.count > 600 { gradedThumbs.removeAll() }
        gradedThumbs[key] = (img, result)
        return result
    }

    private func drawImage(_ img: CGImage, fill rect: CGRect, ctx: CGContext) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0 else { return }
        let s = max(rect.width / iw, rect.height / ih)
        let dw = iw * s, dh = ih * s
        let dr = CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: 0, y: dr.minY + dr.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: dr)
        ctx.restoreGState()
    }

    private func drawFilmstrip(_ c: Clip, asset: MediaAsset, in r: CGRect, visible: CGRect, ctx: CGContext) {
        guard visible.width > 0, asset.height > 0 else { return }
        let aspect = CGFloat(asset.width) / CGFloat(asset.height)
        let tileW = max(24, r.height * aspect)
        if c.isRamped {
            // Speed changes across it: evenly spaced frames from the clip's start, each showing the
            // footage playing at that moment, taken from a fixed grid of times in the file (so while a
            // ramp is dragged the same frames are reused rather than new ones asked for each moment).
            // Until a frame is made, a neighbour on the grid stands in, so nothing blinks.
            let average = max(0.01, c.sourceLength / max(1e-6, c.duration))
            var grid = 1.0 / 16
            while CGFloat(grid / average) * pps < tileW, grid < 16384 { grid *= 2 }
            func frame(_ ts: Double) -> CGImage? {
                let k = (ts / grid).rounded()
                let at = { (k: Double) -> Double in
                    let s = k * grid
                    let shown = c.playsBackwards ? asset.duration - s : s
                    return min(max(0, shown), max(0, asset.duration - 0.05))
                }
                if let img = model.media.thumbnail(asset: asset.id, time: at(k)) { return img }
                for d in [1.0, -1, 2, -2] {
                    if let img = model.media.cachedThumbnail(asset: asset.id, time: at(k + d)) { return img }
                }
                return nil
            }
            var x = r.minX + floor(max(0, visible.minX - r.minX) / tileW) * tileW
            var drawn = 0
            ctx.saveGState()
            ctx.setAlpha(0.88)
            while x < min(r.maxX, visible.maxX), drawn < 240 {
                let t = c.start + Double((x + tileW / 2 - r.minX) / pps)
                if let img = frame(c.sourceTime(at: min(t, c.end))).map({ graded($0, c.grade) }) {
                    drawImage(img, fill: CGRect(x: x, y: r.minY, width: max(1, tileW - 1), height: r.height), ctx: ctx)
                }
                x += tileW
                drawn += 1
            }
            ctx.restoreGState()
            return
        }
        // Source seconds per tile: the smallest power of two that keeps tiles at least one thumbnail wide.
        var step = 1.0 / 16
        while CGFloat(step / c.speed) * pps < tileW, step < 16384 { step *= 2 }
        let srcAt = { (px: CGFloat) -> Double in c.sourceStart + Double((px - r.minX) / self.pps) * c.speed }
        var k = Int(floor(srcAt(visible.minX) / step))
        let kEnd = Int(ceil(srcAt(visible.maxX) / step))
        let w = CGFloat(step / c.speed) * pps
        var drawn = 0
        ctx.saveGState()
        ctx.setAlpha(0.88)
        while k <= kEnd, drawn < 240 {
            let ts = Double(k) * step
            let tx = r.minX + CGFloat((ts - c.sourceStart) / c.speed) * pps
            let shown = c.playsBackwards ? asset.duration - ts : ts
            let sample = c.isFreeze ? c.sourceStart : min(max(0, shown), max(0, asset.duration - 0.05))
            if let img = model.media.thumbnail(asset: asset.id, time: sample).map({ graded($0, c.grade) }) {
                // Frames sit side by side with a 1pt dark gap, like a contact sheet.
                drawImage(img, fill: CGRect(x: tx, y: r.minY, width: max(1, w - 1), height: r.height), ctx: ctx)
            }
            k += 1
            drawn += 1
        }
        ctx.restoreGState()
    }

    /// The sound as one smooth filled shape of average loudness, growing up from the bottom of the
    /// clip, so taller is louder. It uses the clip's whole height, running up behind the name, so it
    /// still shows on the smallest rows. Silence drops to a thin line, so pauses are easy to find and
    /// cut on. Samples sit on a grid tied to the source, so the shape doesn't shimmer while scrolling.
    private func drawWaveform(_ c: Clip, in r: CGRect, visible: CGRect, ctx: CGContext) {
        guard let wf = model.media.waveform(c), visible.width > 0, !wf.peaks.isEmpty else { return }
        let top = r.minY + 2, base = r.maxY - 1
        guard base - top > 4 else { return }
        let room = base - top
        let gain = dbToLinear(c.gainDB)
        // Average loudness sits well under the peaks, so it's lifted to fill the lane, with headroom.
        let lift = 2.0, headroom: CGFloat = 0.92
        let step: CGFloat = 1
        let secPerPx = Double(1 / pps) * c.speed
        // A ramped clip's footage doesn't run evenly across it: its grid starts at the clip.
        let origin = c.isRamped ? r.minX : r.minX - CGFloat(c.sourceStart / secPerPx)
        // Worked out every few points across what's shown, and read in between.
        let every: CGFloat = 4, from = visible.minX - 16
        let table: [Double] = c.isRamped
            ? stride(from: from, through: visible.maxX + 24, by: every).map { c.sourceTime(at: c.start + Double(($0 - r.minX) / pps)) }
            : []
        func source(_ x: CGFloat) -> Double {
            guard c.isRamped, !table.isEmpty else { return Double(x - origin) * secPerPx }
            let f = Double((x - from) / every)
            let i = min(max(0, Int(f)), table.count - 2)
            guard i >= 0, table.count > 1 else { return table[0] }
            return table[i] + (table[i + 1] - table[i]) * (f - Double(i))
        }
        let levels = wf.rms.isEmpty ? wf.peaks : wf.rms
        let count = levels.count

        func level(at k: Int) -> Double {
            let x = origin + CGFloat(k) * step
            let i0 = Int(source(x) * wf.peaksPerSecond)
            let i1 = Int(source(x + step) * wf.peaksPerSecond)
            guard i0 < count, i1 >= 0 else { return 0 }
            let a = max(0, i0), b = min(count - 1, max(i0, i1 - 1))
            guard a <= b else { return 0 }
            let stride = max(1, (b - a) / 32)
            var sum = 0.0, n = 0, i = a
            while i <= b {
                let v = Double(levels[i])
                sum += v * v
                n += 1
                i += stride
            }
            var v = (sum / Double(max(1, n))).squareRoot()
            if wf.rms.isEmpty { v /= lift }
            return v
        }

        // A couple of extra samples each side, so the smoothing reaches past the visible edges.
        let k0 = Int(floor((visible.minX - origin) / step)) - 2
        let k1 = Int(ceil((visible.maxX - origin) / step)) + 2
        guard k1 > k0 else { return }
        let raw = (k0...k1).map { level(at: $0) }
        var xs: [CGFloat] = [], hs: [CGFloat] = []
        for j in 2..<(raw.count - 2) {
            // Light smoothing over five samples keeps the edge soft without blurring beats.
            let v = (raw[j - 2] + raw[j - 1] + raw[j] + raw[j + 1] + raw[j + 2]) / 5
            let x = min(max(origin + CGFloat(k0 + j) * step, visible.minX), visible.maxX)
            xs.append(x)
            hs.append(max(0.75, CGFloat(min(1, v * lift * gain)) * room * headroom))
        }
        guard xs.count > 1 else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: xs[0], y: base))
        for i in 0..<xs.count { path.addLine(to: CGPoint(x: xs[i], y: base - hs[i])) }
        path.addLine(to: CGPoint(x: xs[xs.count - 1], y: base))
        path.closeSubpath()
        ctx.addPath(path)
        // On green (thumbnails off) the shape is a pale green tint, so it sits in the clip's colour.
        let tint = model.thumbnails ? NSColor(srgbRed: 0.80, green: 0.80, blue: 0.78, alpha: 0.7)
                                    : NSColor(srgbRed: 0.88, green: 0.97, blue: 0.90, alpha: 0.55)
        ctx.setFillColor(tint.cgColor)
        ctx.fillPath()
    }

}

extension TimelineCanvas: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        markerPopoverClosed()
    }
}

/// The panel a marker's flag opens: its name and colour, and every marker to jump to.
struct MarkerPanel: View {
    @ObservedObject var model: EditorModel
    let id: UUID
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var marker: Marker? { model.project.markers?.first { $0.id == id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MARKER").font(Theme.label()).tracking(1.2).foregroundStyle(Theme.textFaint)
                Spacer()
                if let m = marker {
                    Text(Timecode.string(m.time, fps: model.project.fps))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(nameFocused ? Theme.text.opacity(0.85) : Theme.stroke, lineWidth: 1))
                .focused($nameFocused)
                .onSubmit { model.editingMarker = nil }
                .onChange(of: name) { _, new in
                    guard new != marker?.name else { return }
                    model.renameMarker(id, to: new)
                }
            HStack(spacing: 9) {
                ForEach(Marker.Tint.allCases, id: \.self) { tint in
                    let on = marker?.tint == tint
                    Button { model.updateMarker(id) { $0.tint = tint } } label: {
                        Circle().fill(Color(hex: tint.hex))
                            .frame(width: 15, height: 15)
                            .padding(3)
                            .overlay(Circle().strokeBorder(Theme.text.opacity(on ? 0.9 : 0), lineWidth: 1.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(tint.rawValue.capitalized)
                }
                Spacer()
                Button { model.deleteMarker(id) } label: {
                    Glyph(symbol: "trash", size: 12).foregroundStyle(Theme.textDim).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete Marker")
            }
            let all = model.project.markerList
            if all.count > 1 {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                ScrollView(showsIndicators: all.count > 7) {
                    VStack(spacing: 2) {
                        ForEach(all) { m in
                            MarkerRow(marker: m, fps: model.project.fps, current: m.id == id) {
                                model.seek(to: m.time)
                                model.editingMarker = m.id
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(all.count) * 28, 196))
            }
        }
        .padding(14)
        .frame(width: 270)
        .background(Theme.panel)
        .onAppear { name = marker?.name ?? ""; nameFocused = true }
        .onChange(of: id) { _, _ in name = marker?.name ?? "" }
    }
}

private struct MarkerRow: View {
    let marker: Marker
    let fps: Double
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle().fill(Color(hex: marker.tint.hex)).frame(width: 7, height: 7)
                Text(marker.name).font(.system(size: 12)).foregroundStyle(current ? Theme.text : Theme.textDim).lineLimit(1)
                Spacer()
                Text(Timecode.string(marker.time, fps: fps))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering || current ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Magic overlay geometry

/// Highlights for the magic show: clips its cursors have hold of, and the edges, lines and
/// handles they're dragging.
struct MagicMarks: Equatable {
    struct Line: Equatable {
        var time: Double
        var clip: UUID
    }
    var selected: Set<UUID> = []
    var left: Set<UUID> = []
    var right: Set<UUID> = []
    var gain: Set<UUID> = []
    var fadeIn: Set<UUID> = []
    var fadeOut: Set<UUID> = []
    var snaps: [Line] = []
    var cuts: [Line] = []
}

extension TimelineCanvas {
    private func magicZone(_ id: UUID) -> Zone? {
        if magicMarks.left.contains(id) { return .left }
        if magicMarks.right.contains(id) { return .right }
        if magicMarks.gain.contains(id) { return .gain }
        if magicMarks.fadeIn.contains(id) { return .fadeIn }
        if magicMarks.fadeOut.contains(id) { return .fadeOut }
        return nil
    }

    /// A clip's rectangle in window coordinates, laid out for `project`.
    func magicWindowRect(of c: Clip, in project: Project) -> NSRect? {
        let layout = TimelineLayout(project: project, rowHeight: view.rowHeight)
        guard let band = layout.band(for: c.trackID) else { return nil }
        let r = CGRect(x: x(c.start), y: TimelineLayout.ruler + band.y - view.scrollY,
                       width: max(CGFloat(c.duration) * pps, 1), height: band.height)
        return convert(r, to: nil)
    }

    /// A time's x position in window coordinates.
    func magicWindowX(_ time: Double) -> CGFloat { convert(NSPoint(x: x(time), y: 0), to: nil).x }

    /// Where the gain line sits for a level, as a fraction of the clip's height from its top.
    static func magicGainNorm(_ db: Double) -> CGFloat { gainNorm(db) }
}
