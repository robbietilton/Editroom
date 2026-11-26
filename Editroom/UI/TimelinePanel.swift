import SwiftUI

struct TimelinePanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar(model: model)
            Hairline()
            HStack(spacing: 0) {
                TrackHeaders(model: model, view: model.view)
                    .frame(width: TimelineLayout.headerWidth)
                Hairline(vertical: true)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        TimelineCanvasView(model: model)
                            .clipped()
                        RowScaleBar(model: model, view: model.view)
                            .frame(width: RangeBarStyle.thickness)
                    }
                    HStack(spacing: 0) {
                        ZoomScrollBar(model: model, view: model.view)
                        Theme.panel.frame(width: RangeBarStyle.thickness)
                    }
                    .frame(height: RangeBarStyle.thickness)
                }
            }
        }
        .background(Theme.bg)
    }
}

// MARK: - Toolbar

struct TimelineToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        // Left: tools and the edits they go with. Right: editing modes and zoom.
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ToolKey(symbol: "cursorarrow", on: model.tool == .move, help: "Select (V or A)") { model.tool = .move }
                ToolKey(symbol: "scissors", on: model.tool == .cut, help: "Cut (C)") { model.tool = .cut }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.bg))
            TextAction(title: "Split", help: "Split at Playhead (⌘K)") { model.splitAtPlayhead() }
            TextAction(title: "Delete", help: "Delete (⌫)") { model.deleteSelected() }
                .disabled(model.selection.isEmpty && model.mediaSelection.isEmpty && model.folderSelection.isEmpty)
            if model.project.inPoint != nil || model.project.outPoint != nil {
                RangeReadout(model: model).padding(.leading, 4)
            }
            Spacer()
            ToggleChip(title: "Strip", on: model.thumbnails, help: "Filmstrip: pictures in clips. Off shows clips as flat colour by type") { model.thumbnails.toggle() }
            ToggleChip(title: "Snap", on: model.snapping, help: "Snapping (S)") { model.snapping.toggle() }
            ToggleChip(title: "Sticky", on: model.sticky, help: "Sticky Edges (R): clips touching a clip that changes length move with it") { model.sticky.toggle() }
            ToggleChip(title: "Skim", on: model.skimming, help: "Skimming (K): hover the timeline to preview frames") { model.skimming.toggle() }
            ToggleChip(title: "Audio", on: model.audioScrub, help: "Audio Scrubbing (⇧S): hear sound while dragging the playhead or skimming") { model.audioScrub.toggle() }
            IconButton(symbol: "arrow.left.and.right", help: "Zoom to Fit (⇧Z)") { model.zoomToFit() }
                .padding(.leading, 4)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Theme.panel).panelTopLight()
    }
}

/// The in/out range: click In or Out to go there, ✕ to clear it.
struct RangeReadout: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var themes = ThemeStore.shared
    @State private var hoveringClear = false

    var body: some View {
        let p = model.project
        let range = p.playRange
        HStack(spacing: 6) {
            point("In", p.inPoint ?? 0)
            point("Out", p.outPoint ?? p.duration)
            if let r = range {
                Text("· " + Self.length(r.end - r.start))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
            Button { model.clearRange() } label: {
                Text("✕").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hoveringClear ? Theme.text : Theme.textFaint)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringClear = $0 }
            .help("Clear In and Out (⇧X)")
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.bg))
    }

    private func point(_ label: String, _ t: Double) -> some View {
        Button { model.seek(to: t) } label: {
            HStack(spacing: 5) {
                Text(L10n.tr(label)).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textFaint)
                Text(Timecode.string(t, fps: model.project.fps))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label == "In" ? L10n.tr("Go to In (I sets it)") : L10n.tr("Go to Out (O sets it)"))
    }

    static func length(_ s: Double) -> String {
        if s < 60 { return s < 10 ? L10n.fmt("%.1f seconds", s) : L10n.fmt("%llds", Int(s.rounded())) }
        return Timecode.short(s)
    }
}

/// One key of the tool selector.
struct ToolKey: View {
    let symbol: String
    let on: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Glyph(symbol: symbol, size: 12)
                .foregroundStyle(on || hovering ? Theme.text : Theme.textDim)
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.raised : .clear))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.ink.opacity(on ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(L10n.tr(help))
    }
}

/// A labelled on/off toggle.
struct ToggleChip: View {
    let title: String
    let on: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // On is the same grey as the Split and Delete commands, off matches a disabled Delete: its
            // own 0.4 with macOS halving a disabled button again, so 0.2. Neither has a key behind it,
            // only a faint one on hover.
            Text(L10n.tr(title)).font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(on ? (hovering ? Theme.text : Theme.textDim) : Theme.textDim.opacity(hovering ? 0.6 : 0.2))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(L10n.tr(help))
    }
}

/// A plain text command button.
struct TextAction: View {
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(L10n.tr(title))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.textDim)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(L10n.tr(help))
    }
}

// MARK: - Zoom / scroll bars

enum RangeBarStyle {
    static let thickness: CGFloat = 15
    static let handle: CGFloat = 11
}

/// A scrollbar thumb with a grip at each end: drag the middle to scroll, drag a grip to zoom.
private struct RangeThumb: View {
    let vertical: Bool
    let hot: Int?     // 0 = start grip, 1 = body, 2 = end grip
    let active: Bool

    var body: some View {
        let lit = hot != nil || active
        ZStack {
            Capsule().fill(Theme.ink.opacity(lit ? 0.3 : 0.2))
            if vertical {
                VStack { grip(0); Spacer(minLength: 0); grip(2) }
            } else {
                HStack { grip(0); Spacer(minLength: 0); grip(2) }
            }
        }
    }

    private func grip(_ part: Int) -> some View {
        Circle()
            .fill(Theme.bg)
            // The grips work as a pair, so they light up as a pair.
            .overlay(Circle().strokeBorder(hot == 0 || hot == 2 ? Theme.ink : Theme.ink.opacity(0.6), lineWidth: 2))
            .frame(width: RangeBarStyle.handle, height: RangeBarStyle.handle)
    }
}

/// What a bar drag started from. Captured once on mouse-down; every later position is computed
/// from this, never from the previous frame, so a drag can't drift, flip handles or snap.
private final class BarDrag {
    var part = 1
    var pps: CGFloat = 0
    var scrollX: CGFloat = 0
    var scrollY: CGFloat = 0
    var rowHeight: CGFloat = 0
    var length: CGFloat = 0
    var content: CGFloat = 0
    var start: CGFloat = 0
    var mirror: CGFloat = 1
    /// What sat in the middle of the timeline when a row-zoom drag began.
    var anchor: (fixed: CGFloat, rows: CGFloat) = (0, 0)
}

/// Where a thumb's two edges end up when one grip is dragged. The dragged edge follows the mouse
/// exactly; the other edge mirrors it. An edge already at the end of the bar stays there, so the
/// other edge alone carries the change, and a grip at the end can't be pulled further out.
/// `move` is the mouse travel along the bar since the drag began; lengths are in bar points.
/// `mirror` is how far the other edge travels for each point the dragged one does: 1 keeps the
/// middle of the thumb fixed, 0 keeps the other edge fixed.
func gripDrag(part: Int, start a0: CGFloat, end b0: CGFloat, move: CGFloat, bar: CGFloat,
              minLength: CGFloat, maxLength: CGFloat, mirror: CGFloat = 1) -> (start: CGFloat, end: CGFloat) {
    // Positive `grow` pulls the dragged grip outward.
    var grow = part == 2 ? move : -move
    grow = min(grow, part == 2 ? bar - b0 : a0)
    func edges(_ g: CGFloat) -> (start: CGFloat, end: CGFloat) {
        part == 2 ? (max(0, a0 - g * mirror), b0 + g) : (a0 - g, min(bar, b0 + g * mirror))
    }
    func fits(_ g: CGFloat) -> Bool {
        let e = edges(g)
        return e.end - e.start >= minLength - 0.0001 && e.end - e.start <= maxLength + 0.0001
    }
    if !fits(grow) {
        // Length only ever increases with `grow`, so close in on the limit from the starting size.
        var ok: CGFloat = 0, bad = grow
        for _ in 0..<40 {
            let mid = (ok + bad) / 2
            if fits(mid) { ok = mid } else { bad = mid }
        }
        grow = ok
    }
    return edges(grow)
}

private func barPart(at p: CGFloat, thumb: CGFloat, length: CGFloat) -> Int? {
    guard p >= thumb - 2, p <= thumb + length + 2 else { return nil }
    let grip = min(RangeBarStyle.handle + 3, length / 3)
    if p < thumb + grip { return 0 }
    if p > thumb + length - grip { return 2 }
    return 1
}

/// Horizontal bar under the timeline. The bar is the whole scrollable timeline and the thumb is what's
/// on screen. Drag the thumb to scroll; drag either grip to zoom both sides, centred on the playhead.
struct ZoomScrollBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var view: TimelineViewState
    @State private var drag: BarDrag?
    @State private var hot: Int?

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let extent = CGFloat(model.extent)
            let minLen = RangeBarStyle.handle * 2 + 6
            let len = max(minLen, min(1, view.viewWidth / view.pps / extent) * w)
            let x = min(max(0, view.scrollX / view.pps / extent * w), w - len)
            ZStack(alignment: .topLeading) {
                Theme.panel
                RangeThumb(vertical: false, hot: hot, active: drag != nil)
                    .frame(width: len, height: RangeBarStyle.handle)
                    .offset(x: x, y: (geo.size.height - RangeBarStyle.handle) / 2)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard drag == nil else { return }
                if case .active(let p) = phase { hot = barPart(at: p.x, thumb: x, length: len) } else { hot = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let d: BarDrag
                        if let existing = drag {
                            d = existing
                        } else {
                            d = BarDrag()
                            if let part = barPart(at: v.startLocation.x, thumb: x, length: len) {
                                d.part = part
                            } else {
                                // Click on the empty bar: centre the thumb there, then keep dragging it.
                                let start = (v.startLocation.x - len / 2) / w * extent
                                model.setView(scrollX: start * view.pps)
                                d.part = 1
                            }
                            d.pps = view.pps
                            d.scrollX = view.scrollX
                            // Zoom around the playhead: the far edge moves just enough to hold the playhead
                            // where it is on screen. With the playhead at the far edge that edge doesn't move
                            // at all; with it in the middle both edges move equally. If the playhead is off
                            // screen, or nearer the grip being dragged, fall back to the middle of the view.
                            let t = (CGFloat(model.playhead) * view.pps - view.scrollX) / max(1, view.viewWidth)
                            if d.part == 2, t >= 0, t <= 0.5 { d.mirror = t / (1 - t) }
                            else if d.part == 0, t >= 0.5, t <= 1 { d.mirror = (1 - t) / t }
                            else { d.mirror = 1 }
                            drag = d
                            hot = d.part
                        }
                        let dx = v.translation.width
                        if d.part == 1 {
                            model.setView(scrollX: d.scrollX + dx / w * extent * d.pps)
                        } else {
                            // The grip stays under the mouse and the other end mirrors it.
                            let a0 = d.scrollX / d.pps / extent * w
                            let e = gripDrag(part: d.part, start: a0, end: a0 + view.viewWidth / d.pps / extent * w, move: dx, bar: w,
                                             minLength: view.viewWidth / TimelineViewState.maxPPS / extent * w, maxLength: w,
                                             mirror: d.mirror)
                            let pps = view.viewWidth / ((e.end - e.start) / w * extent)
                            model.setView(pps: pps, scrollX: e.start / w * extent * pps)
                        }
                    }
                    .onEnded { _ in
                        drag = nil
                        hot = nil
                    }
            )
        }
        .overlay(Hairline(), alignment: .top)
    }
}

/// Vertical bar beside the timeline. The thumb's length is the row zoom (full bar at the smallest
/// rows) and its position is the scroll. Drag it to scroll; drag either grip to scale rows from both
/// ends, keeping whatever is in the middle of the timeline in the middle.
struct RowScaleBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var view: TimelineViewState
    @State private var drag: BarDrag?
    @State private var hot: Int?

    var body: some View {
        GeometryReader { geo in
            let top = TimelineLayout.ruler
            let h = max(1, geo.size.height - top)
            let minLen = RangeBarStyle.handle * 2 + 6
            let world = model.rowsWorld
            let len = max(minLen, model.rowWindow * h)
            let y = min(max(0, (view.scrollY - model.minScrollY) / world * h), h - len)
            ZStack(alignment: .topLeading) {
                Theme.panel
                RangeThumb(vertical: true, hot: hot, active: drag != nil)
                    .frame(width: RangeBarStyle.handle, height: len)
                    .offset(x: (geo.size.width - RangeBarStyle.handle) / 2, y: top + y)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard drag == nil else { return }
                if case .active(let p) = phase { hot = barPart(at: p.y - top, thumb: y, length: len) } else { hot = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let d: BarDrag
                        if let existing = drag {
                            d = existing
                        } else {
                            d = BarDrag()
                            if let part = barPart(at: v.startLocation.y - top, thumb: y, length: len) {
                                d.part = part
                            } else {
                                model.setView(scrollY: model.minScrollY + (v.startLocation.y - top - len / 2) / h * world)
                                d.part = 1
                            }
                            d.scrollY = view.scrollY
                            d.rowHeight = view.rowHeight
                            d.length = model.rowWindow * h
                            d.content = world
                            d.start = (view.scrollY - model.minScrollY) / world * h
                            d.anchor = model.rowAnchor(at: view.scrollY + model.rowsVisible / 2)
                            drag = d
                            hot = d.part
                        }
                        let dy = v.translation.height
                        if d.part == 1 {
                            model.setView(scrollY: d.scrollY + dy / h * d.content)
                        } else {
                            // A shorter thumb means taller rows. The grip stays under the mouse and the other end mirrors it.
                            let rows = TimelineViewState.rowRange
                            let e = gripDrag(part: d.part, start: d.start, end: d.start + d.length, move: dy, bar: h,
                                             minLength: model.rowWindow(rowHeight: rows.upperBound) * h,
                                             maxLength: model.rowWindow(rowHeight: rows.lowerBound) * h)
                            // Rows are whole points tall, so take the height whose thumb is closest to the one asked for.
                            var best = view.rowHeight, miss = CGFloat.infinity
                            for r in stride(from: rows.lowerBound, through: rows.upperBound, by: 1) {
                                let off = abs(model.rowWindow(rowHeight: r) * h - (e.end - e.start))
                                if off < miss { miss = off; best = r }
                            }
                            // Whatever was in the middle of the timeline stays there, so rows grow and shrink
                            // around it instead of the view hopping as the thumb is re-fitted each step.
                            let centre = d.anchor.fixed + d.anchor.rows * best
                            model.setView(scrollY: centre - model.rowsVisible / 2, rowHeight: best)
                        }
                    }
                    .onEnded { _ in
                        drag = nil
                        hot = nil
                    }
            )
        }
        .overlay(Hairline(vertical: true), alignment: .leading)
    }
}

// MARK: - Track headers

struct TrackHeaders: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var view: TimelineViewState

    var body: some View {
        let layout = TimelineLayout(project: model.project, rowHeight: view.rowHeight)
        let ruler = TimelineLayout.ruler
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(layout.rows, id: \.track.id) { row in
                    TrackHeader(model: model, track: row.track,
                                label: (row.track.kind == .video ? "V" : "A") + "\(row.index + 1)",
                                canDelete: model.project.tracks(row.track.kind).count > 1)
                        .frame(width: TimelineLayout.headerWidth, height: row.height)
                        .offset(y: ruler + row.y - view.scrollY)
                }
                if let cy = layout.captionY, let track = model.project.captions {
                    CaptionHeader(model: model, track: track)
                        .frame(width: TimelineLayout.headerWidth, height: TimelineLayout.captionRow)
                        .offset(y: ruler + cy - view.scrollY)
                }
                AddTrackButton(label: "Video") { model.addTrack(.video) }
                    .frame(width: TimelineLayout.headerWidth, height: TimelineLayout.zone)
                    .offset(y: ruler + layout.videoZoneY - view.scrollY)
                AddTrackButton(label: "Audio") { model.addTrack(.audio) }
                    .frame(width: TimelineLayout.headerWidth, height: TimelineLayout.zone)
                    .offset(y: ruler + layout.audioZoneY - view.scrollY)

                // Corner above the headers, level with the ruler.
                Theme.panel
                    .frame(width: TimelineLayout.headerWidth, height: ruler)
                    .overlay(Hairline(), alignment: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .background(Theme.bg)
    }
}

/// The caption track's header: C1, its eye, and a click shows the caption style in the inspector.
struct CaptionHeader: View {
    @ObservedObject var model: EditorModel
    let track: CaptionTrack

    var body: some View {
        let focused = model.captionsFocused || !model.captionSelection.isEmpty
        HStack(spacing: 3) {
            Text("C1")
                .font(Theme.mono(11.5, .semibold))
                .foregroundStyle(track.hidden ? Theme.textFaint : Theme.text)
                .frame(width: 24, alignment: .leading)
            MiniKey(symbol: track.hidden ? "eye.slash" : "eye", on: track.hidden, help: track.hidden ? "Show Captions" : "Hide Captions") {
                model.setCaptionsHidden(!track.hidden)
            }
            Text("Captions")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(focused ? Theme.text : Theme.textDim)
                .padding(.leading, 4)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .overlay(Hairline(), alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { model.focusCaptions() }
        .help("Captions: click for their style")
        .contextMenu {
            Button(track.hidden ? L10n.tr("Show Captions") : L10n.tr("Hide Captions")) { model.setCaptionsHidden(!track.hidden) }
            Divider()
            Button("Delete Caption Track") { model.removeCaptionTrack() }
        }
    }
}

struct AddTrackButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text(L10n.tr(label)).font(.system(size: 10, weight: .medium))
                Spacer()
            }
            .foregroundStyle(hovering ? Theme.text : Theme.textFaint)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hovering ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(label == "Video" ? L10n.tr("Add Video Track") : L10n.tr("Add Audio Track"))
    }
}

struct TrackHeader: View {
    @ObservedObject var model: EditorModel
    let track: Track
    let label: String
    let canDelete: Bool

    private func update(_ body: @escaping (inout Track) -> Void) {
        model.mutate { $0.updateTrack(track.id, body) }
    }

    var body: some View {
        let off = track.locked || (track.kind == .video ? track.hidden : !model.project.isAudible(track))
        HStack(spacing: 3) {
            HStack(spacing: 1) {
                Text(label)
                    .font(Theme.mono(11.5, .semibold))
                    .foregroundStyle(off ? Theme.textFaint : Theme.text)
                if track.duckUnder != nil {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(Theme.accent)
                        .help("Ducks under another track")
                }
            }
            .frame(width: 24, alignment: .leading)
            if track.kind == .audio {
                LetterToggle(letter: "M", on: track.muted, color: Theme.text, help: "Mute") { update { $0.muted.toggle() } }
                LetterToggle(letter: "S", on: track.solo, color: Theme.text, help: "Solo") { update { $0.solo.toggle() } }
            } else {
                MiniKey(symbol: track.hidden ? "eye.slash" : "eye", on: track.hidden, help: track.hidden ? L10n.tr("Show") : L10n.tr("Hide")) {
                    update { $0.hidden.toggle() }
                }
            }
            MiniKey(symbol: "lock", on: track.locked, help: track.locked ? L10n.tr("Unlock") : L10n.tr("Lock")) {
                update { $0.locked.toggle() }
            }
            Spacer(minLength: 0)
            if track.kind == .audio {
                GainPill(db: track.gainDB) { value in
                    model.live(autoCommit: false) { $0.updateTrack(track.id) { $0.gainDB = value } }
                } onEnd: {
                    model.commitLive()
                }
                LevelMeter(meters: model.meters, track: track.id)
                    .frame(width: 6)
                    .padding(.vertical, 8)
                    .padding(.leading, 3)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .overlay(Hairline(), alignment: .bottom)
        .contextMenu {
            if track.kind == .audio {
                let others = model.project.audioTracks.enumerated().filter { $0.element.id != track.id }
                Menu("Duck Under") {
                    Toggle("None", isOn: Binding(get: { track.duckUnder == nil }, set: { _ in model.duck(track.id, under: nil) }))
                    Divider()
                    ForEach(others, id: \.element.id) { item in
                        Toggle("A\(item.offset + 1)", isOn: Binding(get: { track.duckUnder == item.element.id },
                                                                   set: { _ in model.duck(track.id, under: item.element.id) }))
                    }
                    Divider()
                    ForEach([-6.0, -12, -18, -24], id: \.self) { db in
                        Toggle(L10n.fmt("Down %lld dB", Int(-db)), isOn: Binding(get: { abs(track.duckDB - db) < 0.01 },
                                                                    set: { _ in model.duck(track.id, under: track.duckUnder, amount: db) }))
                    }
                }
                Divider()
            }
            Button("Add Video Track") { model.addTrack(.video) }
            Button("Add Audio Track") { model.addTrack(.audio) }
            if canDelete {
                Divider()
                Button("Delete Track") { model.removeTrack(track.id) }
            }
        }
    }
}

/// A small square key with an icon, for hide and lock: white when on.
struct MiniKey: View {
    let symbol: String
    let on: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Glyph(symbol: symbol, size: 9.5, weight: .semibold)
                .foregroundStyle(on ? Theme.onText.opacity(0.85) : (hovering ? Theme.text : Theme.textDim))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? Theme.text : (hovering ? Theme.hover : Theme.field)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(L10n.tr(help))
    }
}

/// A one-letter toggle, for mute and solo.
struct LetterToggle: View {
    let letter: String
    let on: Bool
    let color: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(letter)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(on ? Color.black.opacity(0.85) : (hovering ? Theme.text : Theme.textDim))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? color : (hovering ? Theme.hover : Theme.field)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(L10n.tr(help))
    }
}

/// A vertical segmented level meter. Lit segments are light grey, yellow from -12 dB and red from
/// -3 dB; one segment briefly holds the recent peak; the top segment is red while the signal is at
/// full scale. Everything empties the moment playback stops. Pass no track for the output.
struct LevelMeter: View {
    enum Side { case both, left, right }
    @ObservedObject var meters: MeterState
    var track: UUID?
    /// For the output: one side, or both together.
    var side = Side.both

    private static let segment: CGFloat = 2
    private static let gap: CGFloat = 1

    private static func color(_ db: Double) -> Color {
        db > -3 ? Theme.alert : db > -12 ? Color(nsColor: Theme.NS.snap) : Theme.meterLow
    }

    var body: some View {
        let r = track.map { meters.tracks[$0] ?? MeterReading() }
            ?? (side == .left ? meters.masterLeft : side == .right ? meters.masterRight : meters.master)
        GeometryReader { g in
            let count = max(4, Int((g.size.height + Self.gap) / (Self.segment + Self.gap)))
            // The top segment is the clip light; the rest span the floor to 0 dB.
            let span = count - 1
            let lit = Int((Double(span) * ((r.level - MeterState.floor) / -MeterState.floor)).clamped(to: 0...Double(span)))
            let peak = Int((Double(span) * ((r.peak - MeterState.floor) / -MeterState.floor)).clamped(to: 0...Double(span))) - 1
            VStack(spacing: Self.gap) {
                Rectangle()
                    .fill(r.clipped ? Theme.alert : Theme.well)
                    .frame(height: Self.segment)
                ForEach((0..<span).reversed(), id: \.self) { i in
                    Rectangle()
                        .fill(i < lit || (i == peak && r.peak > MeterState.floor + 0.5) ? Self.color(MeterState.floor * (1 - Double(i + 1) / Double(span))) : Theme.well)
                        .frame(height: Self.segment)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .help(r.clipped ? L10n.tr("Clipping") : L10n.tr("Level"))
    }
}

/// Track level: drag sideways to change, or click to type a value (Return/click away confirms, Esc cancels).
struct GainPill: View {
    let db: Double
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    @State private var hovering = false
    @State private var startDB: Double?
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused, editing { commit() }
                    }
            } else {
                Text(formatDB(db).replacingOccurrences(of: " dB", with: ""))
            }
        }
        .font(Theme.mono(10))
        .foregroundStyle(editing || abs(db) > 0.05 ? Theme.text : Theme.textDim)
        .frame(width: 46, height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering || startDB != nil || editing ? Theme.hover : Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.text.opacity(editing ? 0.85 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { v in
                    guard !editing else { return }
                    if startDB == nil { startDB = db }
                    let raw = (startDB ?? 0) + Double(v.translation.width) * 0.15
                    onChange(min(12, max(-60, (raw * 10).rounded() / 10)))
                }
                .onEnded { _ in
                    guard startDB != nil else { return }
                    startDB = nil
                    onEnd()
                }
        )
        .simultaneousGesture(TapGesture().onEnded {
            guard !editing else { return }
            text = db <= -59.5 ? "-60" : String(format: "%.1f", db)
            editing = true
            focused = true
        })
        .help("Track level — drag, or click to type")
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")
            .filter { "0123456789.-".contains($0) }
        if let v = Double(cleaned) {
            onChange(min(12, max(-60, (v * 10).rounded() / 10)))
            onEnd()
        }
        editing = false
    }
}
