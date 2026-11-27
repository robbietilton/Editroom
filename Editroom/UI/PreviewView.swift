import SwiftUI
import AppKit
import AVFoundation

/// Displays decoded frames straight from the player's video output. The last frame stays up while
/// a new composition is swapped in, so edits never flash black.
final class PreviewSurface: NSView {
    private let model: EditorModel
    private var link: CADisplayLink?
    private var current: CVPixelBuffer?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        // A viewer that has just appeared (full screen, say) starts on the frame already showing.
        if current == nil, let last = model.engine.lastFrame {
            current = last
            show(last)
        }
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// Whether a frame has the viewer's shape. A frame made for the sequence's old shape (it went from vertical to
    /// wide, say) would be stretched to fill: it isn't shown, so the viewer is black for that moment instead.
    private func fits(_ buffer: CVPixelBuffer) -> Bool {
        let w = CGFloat(CVPixelBufferGetWidth(buffer)), h = CGFloat(CVPixelBufferGetHeight(buffer))
        guard w > 0, h > 0, bounds.width > 0, bounds.height > 0 else { return true }
        return abs((w / h) / (bounds.width / bounds.height) - 1) < 0.02
    }

    private func show(_ buffer: CVPixelBuffer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let surface = buffer.flatMap { fits($0) ? CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() : nil }
        if let buffer, let surface { prepareHDR(buffer, surface) }
        layer?.contents = surface
        CATransaction.commit()
    }

    private static let hlgSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!.copyPropertyList()

    /// An HDR project's frame (HLG): shown with the screen's extra brightness above white (EDR), as Photos and
    /// QuickTime show HDR, on any Mac that has some. SDR frames are shown as they always were.
    private func prepareHDR(_ buffer: CVPixelBuffer, _ surface: IOSurface) {
        let hlg = (CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String)
            == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
        if layer?.wantsExtendedDynamicRangeContent != hlg { layer?.wantsExtendedDynamicRangeContent = hlg }
        guard hlg, let space = Self.hlgSpace else { return }
        // What the frame's values mean, on the surface the layer shows.
        IOSurfaceSetValue(surface, kIOSurfaceColorSpace, space)
    }

    // Resized to a new shape: the frame showing is hidden if it no longer fits (the new one follows).
    override func layout() {
        super.layout()
        if let current, !fits(current) { show(nil) }
    }

    @objc private func step(_ sender: CADisplayLink) {
        if let buffer = model.engine.pullFrame() {
            current = buffer
            show(buffer)
        } else if model.engine.isEmpty, current != nil {
            current = nil
            layer?.contents = nil
        }
        model.tick()
    }
}

struct PreviewSurfaceView: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> PreviewSurface { PreviewSurface(model: model) }
    func updateNSView(_ nsView: PreviewSurface, context: Context) {}
}

struct PreviewView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clock: Clock
    @ObservedObject var source: SourcePreviewState
    @State private var moveStart: (x: Double, y: Double)?
    /// Viewer magnification; nil fits the frame to the space available.
    @State private var zoom: Double?

    init(model: EditorModel) {
        self.model = model
        self.clock = model.clock
        self.source = model.sourcePreview
    }

    /// The one visual clip in the selection, which dragging in the viewer moves.
    private var target: Clip? {
        let visual = model.selection.compactMap { model.project.clip($0) }.filter { $0.kind != .audio }
        return visual.count == 1 ? visual[0] : nil
    }

    private func setTransform(_ id: UUID, _ body: @escaping (inout ClipTransform) -> Void) {
        model.live(autoCommit: false) { p in
            guard let i = p.index(of: id) else { return }
            var t = p.clips[i].transform ?? ClipTransform()
            body(&t)
            p.clips[i].transform = t.isIdentity ? nil : t
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let aspect = model.project.aspect
                let fit = min(geo.size.width, geo.size.height * aspect)
                // 100% is one frame pixel per screen pixel.
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let w = zoom.map { CGFloat(Double(model.project.width) * $0) / scale } ?? fit
                let h = w / aspect
                let viewer = picture(w: w, h: h).background(MagicAnchor(key: "viewer"))
                if w <= geo.size.width + 0.5 && h <= geo.size.height + 0.5 {
                    viewer.position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        viewer.frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // The bar takes the whole space under the picture, so its controls sit in the middle of it.
            TransportBar(model: model, clock: model.clock, meters: model.meters, zoom: $zoom)
        }
        .background(model.viewerOnly ? Color.black : Theme.bg)
    }

    @ViewBuilder private func picture(w: CGFloat, h: CGFloat) -> some View {
                let clip = target
                ZStack(alignment: .topLeading) {
                    PreviewSurfaceView(model: model)
                        .frame(width: w, height: h)
                        // Square, as the export is, with its faint edge drawn just outside the picture, not over it.
                        .overlay(Rectangle().inset(by: -0.5).stroke(Theme.ink.opacity(0.05), lineWidth: 1))
                    // Nothing on the timeline yet: say how to start, and take a click as "import". Not while
                    // a Media item is hovered: its frame is drawn underneath, by the player, once skimming rests.
                    if model.project.clips.isEmpty, source.current == nil {
                        EmptyViewerPrompt(hasMedia: !model.project.assets.isEmpty) { model.showImportPanel() }
                            .frame(width: w, height: h)
                    }
                    // A library item being hover-scrubbed shows here, labelled so it isn't mistaken for the edit.
                    if let s = source.current {
                        SourceFrame(current: s).frame(width: w, height: h)
                    }
                }
                .frame(width: w, height: h, alignment: .topLeading)
                .coordinateSpace(name: "viewer")
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("viewer"))
                        .onChanged { v in
                            guard let c = target else { return }
                            if c.kind == .text {
                                if moveStart == nil { moveStart = (c.text.x, c.text.y) }
                                guard let s = moveStart else { return }
                                let nx = min(1, max(0, s.x + Double(v.translation.width / w)))
                                let ny = min(1, max(0, s.y + Double(v.translation.height / h)))
                                model.live(autoCommit: false) { p in
                                    if let i = p.index(of: c.id) {
                                        p.clips[i].text.x = nx
                                        p.clips[i].text.y = ny
                                    }
                                }
                            } else if c.isTransformable {
                                let tf = c.transform ?? ClipTransform()
                                // A zooming clip: framed on the picture all the way in.
                                if moveStart == nil, tf.zoom != nil { model.showZoomed(c.id) }
                                if moveStart == nil { moveStart = tf.zoomedOffset }
                                guard let s = moveStart else { return }
                                var nx = s.x + Double(v.translation.width / w)
                                var ny = s.y + Double(v.translation.height / h)
                                // Snap back to centre within a few points.
                                if abs(nx) * Double(w) < 5 { nx = 0 }
                                if abs(ny) * Double(h) < 5 { ny = 0 }
                                // Zoomed in, the picture can't be pulled past the frame's edge.
                                if tf.fills {
                                    let m = (tf.scale - 1) / 2
                                    nx = min(max(nx, -m), m); ny = min(max(ny, -m), m)
                                }
                                let width = Double(model.project.width), height = Double(model.project.height)
                                setTransform(c.id) {
                                    $0.x = (nx * width).rounded() / width
                                    $0.y = (ny * height).rounded() / height
                                }
                            }
                        }
                        .onEnded { _ in
                            moveStart = nil
                            model.commitLive()
                        }
                )
    }
}

struct TransportBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clock: Clock
    /// Redraws the times when Show time as changes.
    @ObservedObject private var themes = ThemeStore.shared
    let meters: MeterState
    @Binding var zoom: Double?

    private static let zooms: [(String, Double?)] = [("Fit", nil), ("25%", 0.25), ("50%", 0.5), ("100%", 1), ("200%", 2)]

    var body: some View {
        let fps = model.project.fps
        ZStack {
            HStack(alignment: .center, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TimecodeField(time: Double(clock.frame) / fps, fps: fps) { model.seek(to: $0) }
                    Text("/ " + Timecode.string(model.project.duration, fps: fps))
                        .font(Theme.mono(11.5, .regular))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                IconButton(symbol: "repeat", active: model.loop, size: 28, help: "Loop Playback (L)") { model.loop.toggle() }
                // Output level, left and right.
                HStack(spacing: 2) {
                    LevelMeter(meters: meters, side: .left).frame(width: 4)
                    LevelMeter(meters: meters, side: .right).frame(width: 4)
                }
                .frame(height: 24)
                .padding(.horizontal, 4)
                .help("Output level, left and right")
                Menu {
                    ForEach(Self.zooms, id: \.0) { item in
                        Button(item.0) { zoom = item.1 }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Self.zooms.first { $0.1 == zoom }?.0 ?? "Fit")
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
                    }
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Viewer zoom")
                IconButton(symbol: model.viewerOnly ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           size: 28, help: model.viewerOnly ? "Exit Full Screen (F or Esc)" : "Full Screen Viewer (F)") {
                    model.toggleViewerFullScreen()
                }
            }
            HStack(alignment: .center, spacing: 4) {
                IconButton(symbol: "backward.end.fill", size: 32, help: "Previous Edit (↑ or ⇧←)") { model.jumpToEdit(forward: false) }
                IconButton(symbol: "backward.frame.fill", size: 32, help: "Back One Frame (←)") { model.step(frames: -1) }
                PlayButton(playing: model.isPlaying) { model.togglePlay() }
                    .padding(.horizontal, 10)
                IconButton(symbol: "forward.frame.fill", size: 32, help: "Forward One Frame (→)") { model.step(frames: 1) }
                IconButton(symbol: "forward.end.fill", size: 32, help: "Next Edit (↓ or ⇧→)") { model.jumpToEdit(forward: true) }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
    }
}

/// A library item's frame filling the viewer, with its name and source time in the corner.
private struct SourceFrame: View {
    let current: SourcePreviewState.Current
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        let a = current.asset
        let fps = a.fps > 1 ? a.fps : 30
        ZStack(alignment: .topLeading) {
            // Until its first frame is decoded, the viewer's own picture stays showing underneath
            // rather than going black.
            if let img = current.image {
                Color.black
                Image(decorative: img, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                // Trimming a clip's edge: just the time (the clip is the one being dragged).
                if current.note == nil { Text(a.name).font(.system(size: 11.5, weight: .semibold)) }
                Text(Timecode.string(current.time, fps: fps)).font(Theme.mono(11.5, .regular))
                    .foregroundStyle(Color(hex: current.note == nil ? 0x9A9A96 : 0xF2F2F0))
            }
            // On the picture, so light type in every theme.
            .foregroundStyle(Color(hex: 0xF2F2F0))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.65)))
            .padding(10)
        }
        // The whole viewer, label in its top-left corner, also when the picture is drawn underneath by the
        // player (scrub frames) rather than here.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// What the viewer shows on an empty timeline: a dashed drop area with a film frame and an arrow.
private struct EmptyViewerPrompt: View {
    let hasMedia: Bool
    let onImport: () -> Void
    @State private var hovering = false

    /// The viewer is black in every theme, so on Light this uses Dark's colours, not Light's dark ones.
    private var p: Palette { Theme.current.isLight ? AppTheme.dark.palette : Theme.p }

    var body: some View {
        let text = Color(hex: p.text), faint = Color(hex: p.textFaint)
        GeometryReader { g in
            VStack(spacing: 16) {
                Canvas { ctx, size in
                    let s = size.width / 74
                    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * s, y: y * s, width: w * s, height: h * s) }
                    var frame = Path(roundedRect: r(1, 9, 58, 40), cornerRadius: 5 * s)
                    for y: CGFloat in [17, 41] { frame.move(to: CGPoint(x: 1 * s, y: y * s)); frame.addLine(to: CGPoint(x: 59 * s, y: y * s)) }
                    for x: CGFloat in [9, 19, 29, 39, 49] {
                        frame.move(to: CGPoint(x: x * s, y: 9 * s)); frame.addLine(to: CGPoint(x: x * s, y: 17 * s))
                        frame.move(to: CGPoint(x: x * s, y: 41 * s)); frame.addLine(to: CGPoint(x: x * s, y: 49 * s))
                    }
                    let style = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
                    ctx.stroke(frame, with: .color(faint), style: style)
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: 66 * s, y: 4 * s)); arrow.addLine(to: CGPoint(x: 66 * s, y: 24 * s))
                    arrow.move(to: CGPoint(x: 59 * s, y: 17 * s)); arrow.addLine(to: CGPoint(x: 66 * s, y: 24 * s)); arrow.addLine(to: CGPoint(x: 73 * s, y: 17 * s))
                    ctx.stroke(arrow, with: .color(text), style: style)
                }
                .frame(width: 96, height: 70)
                // Centred when they wrap (a vertical frame is narrow), and kept off the dashed edge.
                Text(hasMedia ? "Drag media from the library to the timeline" : "Drop video, audio or images anywhere")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(hasMedia ? "or double-click it to add it at the playhead"
                              : "or press ⌘I to import  ·  MP4, MOV, MKV, WebM, WAV, MP3, JPG, PNG")
                    .font(.system(size: 11.5))
                    .foregroundStyle(faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .frame(width: g.size.width * 0.62, height: g.size.height * 0.58)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(hovering ? Color(hex: p.ink).opacity(0.3) : Color(hex: p.outline))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onTapGesture { if !hasMedia { onImport() } }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// The current time. Click it to type a time to jump to: Return or clicking away goes there, Esc cancels.
private struct TimecodeField: View {
    let time: Double
    let fps: Double
    let onJump: (Double) -> Void
    @ObservedObject private var themes = ThemeStore.shared
    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused, editing { commit() }
                    }
            } else {
                Text(Timecode.string(time, fps: fps))
            }
        }
        .font(Theme.mono(20, .medium))
        .kerning(0.4)
        .foregroundStyle(Theme.text)
        .fixedSize()
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(editing || hovering ? Theme.field : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.text.opacity(editing ? 0.85 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture {
            guard !editing else { return }
            text = Timecode.string(time, fps: fps)
            editing = true
            focused = true
        }
        .padding(.leading, -7)
        .help("Click to type a time")
    }

    private func commit() {
        if let t = Timecode.parse(text, fps: fps) { onJump(t) }
        editing = false
    }
}

private struct PlayButton: View {
    let playing: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.onText)
                .offset(x: playing ? 0 : 1.5)
                .frame(width: 46, height: 46)
                .background(Circle().fill(hovering ? Theme.ink : Theme.text))
                // A dark ring sets it off from the bar.
                .padding(5)
                .background(Circle().fill(Theme.transport).overlay(Circle().strokeBorder(Theme.ink.opacity(0.05))))
                .scaleEffect(hovering ? 1.05 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Play / Pause (Space)")
    }
}
