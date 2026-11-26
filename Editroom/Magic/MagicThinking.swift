import AppKit
import QuartzCore

/// The show while Magic works out an edit, before the swarm makes it (Editing), in the app's plain style.
/// The whole app dims (the Magic button, which offers Stop, stays bright; esc cancels), and it goes
/// through three stages, only ever forwards:
/// - Looking: scans loop over the items in the Media panel;
/// - Analyzing: scans loop over the clips, the Media items and the viewer, a few at a time. Each item
///   being scanned gets small corner brackets, which fade once its scan is done; the viewer keeps its own;
/// - Thinking: a dot field (drifting noise) shimmers over the viewer, while the coming edit appears as
///   dashed ghost clips (and a clip it goes back to look at gets scanned again);
/// then it all fades out where it is, and the swarm's cursors make the edit (cursors only appear for
/// that, doing things). Nothing on the timeline moves.
@MainActor
final class MagicThinking: NSObject {
    static private(set) var current: MagicThinking?
    /// A show that has handed over to the swarm: its outlines stay until their clips land.
    static private var leaving: MagicThinking?

    enum Stage: Int, Comparable {
        case looking, analyzing, thinking
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
        var word: String {
            switch self {
            case .looking: L10n.tr("Looking")
            case .analyzing: L10n.tr("Analyzing")
            case .thinking: L10n.tr("Thinking")
            }
        }
    }

    /// One item being scanned: brackets on its corners, a line sweeping across it, then it fades.
    private final class Scan {
        let rect: CGRect
        let start: Double
        let sweep: Double
        let box = CALayer()
        let bar = CALayer()
        let brackets = CAShapeLayer()
        init(_ r: CGRect, start: Double, sweep: Double) { rect = r; self.start = start; self.sweep = sweep }
        var end: Double { start + sweep + 0.55 }
    }

    /// A clip of the coming edit, outlined where it will be. It follows the timeline's layout, and once
    /// the swarm has taken over it stays until the real clip lands on it.
    private final class Ghost {
        let clip: Clip
        let project: Project
        var size = CGSize.zero
        let shape = CAShapeLayer()
        let fill = CALayer()
        var progress = 0.0
        let born: Double
        /// When its clip landed (or the show ended), and it began to go.
        var landed: Double?
        init(_ clip: Clip, in project: Project, born: Double) { self.clip = clip; self.project = project; self.born = born }
    }

    private weak var host: NSWindow?
    private weak var model: EditorModel?
    private let overlay: NSWindow
    private let root = CALayer()
    private let dim = CAShapeLayer()
    private let field = DotField()
    private let ghostLayer = CALayer()
    private let scanLayer = CALayer()
    private let viewerBrackets = CAShapeLayer()
    private let hint = CALayer()
    private let hintText = CATextLayer()
    private var scans: [Scan] = []
    private var lastScan = -1.0
    private var recent: [CGRect] = []
    private var ghosts: [Ghost] = []
    private var ghostKeys: [String] = []
    /// When each linked video's outline started drawing, for its sound to match.
    private var linkBorn: [UUID: Double] = [:]
    private var link: CADisplayLink?
    private var monitor: Any?
    private var t0 = CACurrentMediaTime()
    private var last = CACurrentMediaTime()
    private(set) var stage: Stage = .looking {
        didSet { MagicState.shared.stage = stage.word }
    }
    /// What the scans loop over, and which of those are wanted first.
    private var targets: [CGRect] = []
    private var focusQueue: [CGRect] = []
    private var fieldAlpha = 0.0
    private let color: NSColor
    private let label: String
    private var leaveDone: (() -> Void)?
    private var lastEvent = CACurrentMediaTime()

    static let dimming: CGFloat = 0.45

    // MARK: Starting and ending

    /// Starts the show over the editor window, or returns nil when there isn't one on screen.
    @discardableResult
    static func begin(model: EditorModel, name: String, color: NSColor) -> MagicThinking? {
        current?.cancel()
        leaving?.cancel()
        // Not shown at work (Settings > Magic): no scans or sketch; the button still says what it's doing.
        guard MagicShow.animated else { return nil }
        guard let window = TimelineCanvas.current?.window, window.isVisible else { return nil }
        let t = MagicThinking(window: window, model: model, name: name, color: color)
        current = t
        return t
    }

    private init(window: NSWindow, model: EditorModel, name: String, color: NSColor) {
        host = window
        self.model = model
        self.color = color
        label = name
        overlay = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        let view = FlippedHost(frame: NSRect(origin: .zero, size: window.frame.size))
        view.wantsLayer = true
        view.layer?.addSublayer(root)
        root.frame = view.bounds
        dim.fillColor = NSColor.black.withAlphaComponent(Self.dimming).cgColor
        dim.fillRule = .evenOdd
        dim.opacity = 0
        root.addSublayer(dim)
        root.addSublayer(field)
        root.addSublayer(ghostLayer)
        root.addSublayer(scanLayer)
        for b in [viewerBrackets] {
            b.fillColor = nil
            b.strokeColor = NSColor.white.withAlphaComponent(0.75).cgColor
            b.lineWidth = 1
            root.addSublayer(b)
        }
        overlay.contentView = view
        window.addChildWindow(overlay, ordered: .above)

        let scale = window.backingScaleFactor
        field.contentsScale = scale
        field.opacity = 0
        viewerBrackets.contentsScale = scale

        // "Press esc to cancel", small, at the bottom.
        hint.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        hint.cornerRadius = 11
        hint.opacity = 0
        hintText.string = L10n.tr("Press esc to cancel")
        hintText.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        hintText.fontSize = 11
        hintText.foregroundColor = NSColor.white.withAlphaComponent(0.75).cgColor
        hintText.alignmentMode = .center
        hintText.contentsScale = scale
        hint.addSublayer(hintText)

        root.addSublayer(hint)
        MagicState.shared.stage = stage.word
        // The editor is locked while it works: esc or Stop cancels; space still plays the preview; a
        // blocked click or key nudges the "Press esc to cancel" hint.
        monitor = NSEvent.addLocalMonitorForEvents(matching: MagicLock.events) { [weak self] e in
            MainActor.assumeIsolated {
                switch MagicLock.judge(e, in: self?.host, allowSpace: true) {
                case .pass: return e
                case .stop:
                    MagicShow.stopAll()
                    return nil
                case .blocked:
                    self?.nudge()
                    return nil
                }
            }
        }
        startLoop()
        look()
    }

    /// Ends the show: everything carries on as it was and fades out where it is, then `done` (where the
    /// swarm starts).
    func end(then done: (() -> Void)? = nil) {
        guard leaveDone == nil, fadeFrom == nil else { return }
        fadeFrom = now
        leaveDone = done
        // Stopped, or nothing to play: the editor is free at once. Handing over to the swarm, it stays
        // locked until the swarm takes over.
        if done == nil { removeMonitor() }
    }

    /// Hands over to the swarm, which starts now, while this fades out around it: the dimming, scans and
    /// dots go; each outline stays until its clip lands. The swarm locks the editor from here.
    func handOver() {
        guard leaveDone == nil, fadeFrom == nil else { return }
        fadeFrom = now
        handedOver = true
        removeMonitor()
        if Self.current === self {
            Self.current = nil
            Self.leaving = self
        }
    }

    private var handedOver = false

    /// How long until the outlines drawn so far are fully drawn.
    var secondsUntilDrawn: Double { max(0, (ghosts.map(\.born).max() ?? now) + Self.ghostDraw - now) }
    private static let ghostDraw = 0.7
    private static let ghostLeave = 0.3

    /// When a blocked click or key last nudged the hint.
    private var nudged = -10.0
    private func nudge() { nudged = now }

    /// When the fade-out began.
    private var fadeFrom: Double?
    private static let fadeTime = 0.6

    /// Takes the show down at once.
    func cancel() {
        link?.invalidate()
        link = nil
        removeMonitor()
        host?.removeChildWindow(overlay)
        overlay.orderOut(nil)
        if Self.current === self {
            Self.current = nil
            MagicState.shared.stage = nil
        } else if Self.leaving === self {
            Self.leaving = nil
            // Handed over but nothing played: the editor is free again.
            if Self.current == nil, !MagicShow.isRunning { MagicState.shared.stage = nil }
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: What's happening (stages only move forward)

    private func advance(to s: Stage) {
        lastEvent = CACurrentMediaTime()
        guard fadeFrom == nil, s > stage else { return }
        stage = s
    }

    /// Looking: the items in the Media panel.
    func look() {
        lastEvent = CACurrentMediaTime()
        guard model != nil, stage == .looking else { return }
        targets = mediaRects(nil)
    }

    /// Analyzing: the clips on the timeline (of these library items, or all of them when nil), those
    /// items in the Media panel, and the viewer.
    func analyze(assets: Set<UUID>?) {
        advance(to: .analyzing)
        guard let model, stage == .analyzing else { return }
        var rects: [CGRect] = []
        if let canvas = TimelineCanvas.current {
            let visible = toOverlay(canvas.convert(canvas.bounds, to: nil))
            for c in model.project.clips {
                // Every title and sound, and the clips of the items being studied.
                if let a = c.assetID, let assets, (c.kind == .video || c.kind == .image), !assets.contains(a) { continue }
                if let r = canvas.magicWindowRect(of: c, in: model.project).map(toOverlay), visible.intersects(r) {
                    rects.append(r.intersection(visible))
                }
            }
        }
        rects += mediaRects(assets)
        rects.append(viewerRect)
        targets = rects.filter { $0.width > 6 && $0.height > 6 }
    }

    /// The items in the Media panel (these ones, or all) that are on screen.
    private func mediaRects(_ assets: Set<UUID>?) -> [CGRect] {
        guard let model else { return [] }
        return model.project.assets.filter { assets?.contains($0.id) ?? true }.compactMap { mediaRect($0.id) }
    }

    /// A Media item's picture, if most of it is scrolled into view (only the part on screen); nil when
    /// it's mostly out of sight, so nothing is scanned where there's nothing to see.
    private func mediaRect(_ asset: UUID) -> CGRect? {
        guard let r = MagicAnchors.rect(asset.uuidString).map(toOverlay) else { return nil }
        guard let list = (MagicAnchors.rect("libraryList") ?? MagicAnchors.rect("library")).map(toOverlay) else { return r }
        // Any part on screen is scanned, cut off at the list's edge like the picture is.
        return Self.mostlyIn(r, list, share: 0)
    }

    /// The part of `r` inside `area`, when at least 60% of it is.
    private static func mostlyIn(_ r: CGRect, _ area: CGRect, share: CGFloat = 0.6) -> CGRect? {
        let v = r.intersection(area)
        guard !v.isNull, r.width * r.height > 0, v.width * v.height >= share * r.width * r.height,
              v.width > 6, v.height > 6 else { return nil }
        return v
    }

    /// One library item is being looked at: it's scanned next (once thinking, straight away: the stage
    /// doesn't go back).
    func focus(asset: UUID) {
        if stage < .analyzing { analyze(assets: nil) }
        lastEvent = CACurrentMediaTime()
        guard fadeFrom == nil else { return }
        // Its clip on the timeline if that's in view, otherwise its Media item if that's in view;
        // nothing when neither is (the panel doesn't scroll on its own while the editor is locked).
        var rect: CGRect?
        if let model, let canvas = TimelineCanvas.current, let c = model.project.clips.first(where: { $0.assetID == asset }),
           let r = canvas.magicWindowRect(of: c, in: model.project).map(toOverlay) {
            rect = Self.mostlyIn(r, toOverlay(canvas.convert(canvas.bounds, to: nil)))
        }
        guard let rect = rect ?? mediaRect(asset) else { return }
        if stage == .thinking {
            addScan(rect)
        } else {
            focusQueue.append(rect)
        }
    }

    func think() { advance(to: .thinking) }

    /// The coming edit, sketched as dashed ghosts on the timeline as it takes shape (Thinking).
    func plan(_ project: Project) {
        advance(to: .thinking)
        guard fadeFrom == nil, let canvas = TimelineCanvas.current else { return }
        // Every clip, a video's own sound included (so the rows match the finished cut); that sound is
        // drawn at the same moment as its video, not after it.
        let linkedSound = { (c: Clip) in c.kind == .audio && c.linkID != nil }
        let clips = project.clips.filter { !linkedSound($0) } + project.clips.filter(linkedSound)
        for c in clips {
            let key = "\(c.trackID)|\(Int(c.start * 100))|\(Int(c.duration * 100))"
            guard !ghostKeys.contains(key), let r = canvas.magicWindowRect(of: c, in: project).map(toOverlay),
                  r.width > 3 else { continue }
            ghostKeys.append(key)
            // One after another, a little apart; a video's sound with its video.
            let born = linkedSound(c) ? c.linkID.flatMap { linkBorn[$0] } : nil
            let g = Ghost(c, in: project, born: born ?? max(now, (ghosts.map(\.born).max() ?? 0) + 0.12))
            if !linkedSound(c), let link = c.linkID { linkBorn[link] = g.born }
            g.shape.fillColor = nil
            g.shape.strokeColor = NSColor.white.withAlphaComponent(0.65).cgColor
            g.shape.lineWidth = 1.5
            g.shape.lineDashPattern = [7, 6]
            g.shape.strokeEnd = 0
            g.fill.cornerRadius = 6
            g.fill.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            g.fill.opacity = 0
            ghostLayer.addSublayer(g.fill)
            ghostLayer.addSublayer(g.shape)
            ghosts.append(g)
        }
    }

    // MARK: The loop

    private var now: Double { CACurrentMediaTime() - t0 }

    private func startLoop() {
        let l = overlay.contentView!.displayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private var buttonRect: CGRect? { MagicAnchors.rect("magicButton").map(toOverlay) }

    private var viewerRect: CGRect {
        MagicAnchors.rect("viewer").map(toOverlay)
            ?? CGRect(x: 300, y: 80, width: max(200, (host?.frame.width ?? 1200) - 640), height: 360)
    }

    @objc private func step() {
        guard let host else { return cancel() }
        if overlay.frame != host.frame {
            overlay.setFrame(host.frame, display: false)
            root.frame = CGRect(origin: .zero, size: host.frame.size)
        }
        let wall = CACurrentMediaTime()
        let dt = min(1.0 / 30, max(1.0 / 240, wall - last))
        last = wall
        let t = now
        // Analyzing, then a while with nothing new from the AI: it's thinking.
        if fadeFrom == nil, stage == .analyzing, wall - lastEvent > 2.5, focusQueue.isEmpty { think() }
        let fade = fadeFrom.map { max(0, 1 - (t - $0) / Self.fadeTime) } ?? 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = root.bounds.size
        // The app dims, all but the Magic button (Stop).
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: size))
        if let b = buttonRect {
            path.addRoundedRect(in: b.insetBy(dx: -3, dy: -3), cornerWidth: b.height / 2 + 3, cornerHeight: b.height / 2 + 3)
        }
        dim.path = path
        dim.frame = root.bounds
        let appear = min(1, t / 0.35)
        dim.opacity = Float(appear * fade)
        hint.bounds = CGRect(x: 0, y: 0, width: 140, height: 22)
        hint.position = CGPoint(x: size.width / 2, y: size.height - 26)
        hintText.frame = CGRect(x: 0, y: 4, width: 140, height: 15)
        // A blocked click or key: the hint swells a touch and brightens, then settles.
        let bump = max(0, 1 - (t - nudged) / 0.45)
        let swell = sin(min(1, (t - nudged) / 0.45) * .pi) * bump
        hint.transform = CATransform3DMakeScale(1 + 0.08 * swell, 1 + 0.08 * swell, 1)
        hintText.foregroundColor = NSColor.white.withAlphaComponent(0.75 + 0.25 * bump).cgColor
        hint.opacity = Float(max(min(1, max(0, t - 0.6) / 0.4), bump) * fade)

        let view = viewerRect
        viewerBrackets.path = Self.brackets(view, length: 6)
        viewerBrackets.opacity = Float(appear * fade)

        updateScans(t, fade: fade)
        updateField(t, view: view, dt: dt, fade: fade)
        updateGhosts(t, fade: fade)
        CATransaction.commit()

        if handedOver {
            // Gone once it has faded and every outline has gone with its clip.
            if let f = fadeFrom, now - f >= Self.fadeTime, ghosts.allSatisfy({ ($0.landed ?? .infinity) + Self.ghostLeave <= t }) {
                cancel()
            }
        } else if let f = fadeFrom, now - f >= Self.fadeTime {
            let done = leaveDone
            leaveDone = nil
            cancel()
            done?()
        }
    }

    /// Small corner brackets just outside a rect.
    private static func brackets(_ r: CGRect, length: CGFloat) -> CGPath {
        let o: CGFloat = 1.5
        let x0 = r.minX - o, y0 = r.minY - o, x1 = r.maxX + o, y1 = r.maxY + o
        let l = min(length, r.width / 3, r.height / 3)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0, y: y0 + l)); p.addLine(to: CGPoint(x: x0, y: y0)); p.addLine(to: CGPoint(x: x0 + l, y: y0))
        p.move(to: CGPoint(x: x1 - l, y: y0)); p.addLine(to: CGPoint(x: x1, y: y0)); p.addLine(to: CGPoint(x: x1, y: y0 + l))
        p.move(to: CGPoint(x: x1, y: y1 - l)); p.addLine(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x1 - l, y: y1))
        p.move(to: CGPoint(x: x0 + l, y: y1)); p.addLine(to: CGPoint(x: x0, y: y1)); p.addLine(to: CGPoint(x: x0, y: y1 - l))
        return p
    }

    // MARK: Pieces

    /// A few items at a time get scanned, round and round, wanted ones first. New ones stop once it's
    /// thinking (bar the clips it goes back to look at).
    private func updateScans(_ t: Double, fade: Double) {
        let busy = scans.filter { t < $0.start + $0.sweep }.count
        let room = min(6, max(1, targets.count / 2 + 1))
        if fadeFrom == nil, stage < .thinking, busy < room, t - lastScan > 0.18, t > 0.25 {
            if !focusQueue.isEmpty {
                addScan(focusQueue.removeFirst())
            } else if !targets.isEmpty {
                let active = scans.map(\.rect)
                let fresh = targets.filter { r in !active.contains(r) && !recent.contains(r) }
                let pool = fresh.isEmpty ? targets.filter { !active.contains($0) } : fresh
                if let r = pool.randomElement() {
                    addScan(r)
                    recent.append(r)
                    if recent.count > max(1, targets.count * 2 / 3) { recent.removeFirst() }
                }
            }
        }
        for s in scans {
            let u = (t - s.start) / s.sweep
            let r = s.rect
            let width = r.width * CGFloat(min(1, max(0, u)))
            s.box.frame = CGRect(x: r.minX, y: r.minY, width: width, height: r.height)
            s.bar.frame = CGRect(x: r.minX + width - 0.75, y: r.minY, width: 1.5, height: r.height)
            // The fill and line fade once it's across; the brackets a moment later.
            let after = max(0, t - s.start - s.sweep)
            let sweepAlpha = u < 1 ? 1 : max(0, 1 - after / 0.3)
            s.box.opacity = Float(sweepAlpha * fade)
            s.bar.opacity = Float(sweepAlpha * fade)
            let bracketIn = min(1, (t - s.start) / 0.15)
            let bracketOut = max(0, min(1, 1 - (after - 0.25) / 0.3))
            s.brackets.opacity = Float(bracketIn * bracketOut * fade)
        }
        scans.removeAll { s in
            guard t > s.end else { return false }
            s.box.removeFromSuperlayer()
            s.bar.removeFromSuperlayer()
            s.brackets.removeFromSuperlayer()
            return true
        }
    }

    private func addScan(_ r: CGRect) {
        let t = now
        let s = Scan(r, start: t, sweep: Double.random(in: 1.0...1.5) * min(1.6, max(0.8, Double(r.width) / 220)))
        s.box.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        s.bar.backgroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
        s.brackets.path = Self.brackets(r, length: r == viewerRect ? 6 : 3)
        s.brackets.fillColor = nil
        s.brackets.strokeColor = NSColor.white.withAlphaComponent(0.75).cgColor
        s.brackets.lineWidth = 1
        for l in [s.box, s.bar, s.brackets] as [CALayer] { l.opacity = 0; scanLayer.addSublayer(l) }
        scans.append(s)
        lastScan = t
    }

    private func updateField(_ t: Double, view: CGRect, dt: Double, fade: Double) {
        let want = stage == .thinking ? 1.0 : 0.0
        fieldAlpha += (want - fieldAlpha) * min(1, dt * (want > fieldAlpha ? 1.2 : 3))
        field.frame = view
        field.opacity = Float(fieldAlpha * fade)
        guard fieldAlpha > 0.01 else { return }
        field.time = t
        field.tint = color
        field.setNeedsDisplay()
    }

    /// Ghosts draw themselves, one after another, where their clips will be on the timeline as it's laid
    /// out now. After the handover each one goes as its real clip lands on it (all of them if the show
    /// ends or stops).
    private func updateGhosts(_ t: Double, fade: Double) {
        let canvas = TimelineCanvas.current
        let clips = handedOver ? (model?.project.clips ?? []) : []
        let showing = MagicShow.isRunning
        for g in ghosts {
            if handedOver, g.landed == nil {
                let there = clips.contains { c in
                    c.trackID == g.clip.trackID && abs(c.start - g.clip.start) < 0.02 && abs(c.duration - g.clip.duration) < 0.02
                }
                if there || !showing { g.landed = t }
            }
            if let canvas, let r = canvas.magicWindowRect(of: g.clip, in: g.project).map(toOverlay)?.insetBy(dx: 1, dy: 3) {
                if r.size != g.size {
                    g.size = r.size
                    g.shape.path = CGPath(roundedRect: CGRect(origin: .zero, size: r.size), cornerWidth: min(6, r.width / 2),
                                          cornerHeight: min(6, r.height / 2), transform: nil)
                }
                g.shape.frame = r
                g.fill.frame = r
            }
            g.progress = min(1, max(0, (t - g.born) / Self.ghostDraw))
            g.shape.strokeEnd = g.progress
            g.shape.lineDashPhase = CGFloat(-t * 24)
            let alpha = handedOver ? max(0, 1 - (t - (g.landed ?? t)) / Self.ghostLeave) : fade
            g.shape.opacity = Float(alpha)
            g.fill.opacity = Float(max(0, (g.progress - 0.6) / 0.4) * alpha)
        }
    }

    private func toOverlay(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: (host?.frame.height ?? 0) - r.maxY, width: r.width, height: r.height)
    }
}

/// While Magic works out an edit and plays it, the editor is locked: clicks, drags, scrolling, pinches
/// and keys in its window do nothing, so nothing changes under it. What still works: esc and the Magic
/// button (Stop), which cancel; space to play the preview (while it's working the edit out); quit, hide
/// and minimise; the window's title strip (moving it, the window buttons) bar Export; other windows and
/// the menus.
@MainActor
enum MagicLock {
    static let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
                                                 .magnify, .swipe, .rotate, .smartMagnify, .keyDown]
    enum Verdict { case pass, stop, blocked }

    static func judge(_ e: NSEvent, in window: NSWindow?, allowSpace: Bool) -> Verdict {
        guard let window, e.window === window else { return .pass }
        let button = MagicAnchors.rect("magicButton")
        switch e.type {
        case .keyDown:
            if e.keyCode == 53 { return .stop }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == .command, let c = e.charactersIgnoringModifiers?.lowercased(), ["q", "h", "m"].contains(c) { return .pass }
            if allowSpace, e.keyCode == 49, mods.isEmpty { return .pass }
            return .blocked
        case .leftMouseDown:
            if let button, button.contains(e.locationInWindow) { return .stop }
            // The title strip, left of the Magic button (Export is to its right).
            let fromTop = window.frame.height - e.locationInWindow.y
            if fromTop < 50, e.locationInWindow.x < (button?.minX ?? window.frame.width - 200) { return .pass }
            return .blocked
        default:
            return .blocked
        }
    }
}

/// The shimmering dots over the viewer while thinking: a drifting noise.
private final class DotField: CALayer {
    var time = 0.0
    var glows: [CGPoint] = []
    var tint: NSColor = .white

    override init() { super.init(); needsDisplayOnBoundsChange = true; masksToBounds = true }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private static func noise(_ a: Double, _ b: Double) -> Double {
        sin(a * 1.7 + sin(b * 1.3)) * 0.5 + sin(b * 2.1 - a * 0.6) * 0.3 + sin((a + b) * 0.9) * 0.2
    }

    override func draw(in ctx: CGContext) {
        let w = bounds.width, h = bounds.height
        guard w > 10, h > 10 else { return }
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: h)
            ctx.scaleBy(x: 1, y: -1)
        }
        // Darken the picture a touch so the dots read.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.fill(bounds)
        // A fine grid of small dots.
        let spacing = max(6, min(w, h) / 55)
        let reach = Double(max(w, h)) * 0.13
        let warm = tint.blended(withFraction: 0.55, of: .white) ?? tint
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        warm.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        var y = spacing / 2
        while y < h {
            var x = spacing / 2
            while x < w {
                let u = Double(x / w), v = Double(y / h)
                let n = min(1, pow(Self.noise(u * 4 + time * 0.6, v * 3.2 - time * 0.44) * 0.5 + 0.5, 2.6) * 1.2) * 0.65
                var glow = 0.0
                for p in glows {
                    let d = hypot(Double(x - p.x), Double(y - p.y))
                    glow = max(glow, 1 - d / reach)
                }
                glow = pow(max(0, glow), 2) * 0.7
                let level = min(1, n + glow * (1 - n * 0.5))
                let radius = 0.35 + CGFloat(level) * spacing * 0.16
                ctx.setFillColor(red: r + (1 - r) * CGFloat(level) * 0.5, green: g + (1 - g) * CGFloat(level) * 0.4,
                                 blue: b + (1 - b) * CGFloat(level) * 0.3, alpha: 0.05 + 0.6 * CGFloat(level))
                ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                x += spacing
            }
            y += spacing
        }
    }
}

private final class FlippedHost: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
