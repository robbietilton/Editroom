import SwiftUI
import AppKit
import AVFoundation

/// Colours for the export sheet: a cool, slightly blue dark, a step apart from the editor chrome.
enum SheetStyle {
    static var background: Color { Color(hex: Theme.p.sheet) }
    static var field: Color { Color(hex: Theme.p.sheetField) }
    static var fieldHover: Color { Color(hex: Theme.p.sheetFieldHover) }
    static var fieldStroke: Color { Color(hex: Theme.p.sheetFieldStroke) }
    static var label: Color { Color(hex: Theme.p.sheetLabel) }
    static var text: Color { Theme.text }
    static var divider: Color { Theme.ink.opacity(0.08) }
    static let radius: CGFloat = 8
}

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @State private var failure: String?
    @State private var settings = ExportSettings()
    @State private var name = ""
    @State private var folder = URL(fileURLWithPath: NSHomeDirectory())
    @StateObject private var player = PreviewPlayer()
    @FocusState private var nameFocused: Bool

    private var heights: [(String, Int?)] {
        let p = model.project
        let vertical = p.height > p.width
        let base: [(String, Int)] = [("4K", 2160), ("1440p", 1440), ("1080p", 1080), ("720p", 720)]
        // For vertical frames the label names the short side.
        func size(_ h: Int?) -> CGSize {
            var s = settings
            s.height = h
            return s.renderSize(for: p)
        }
        let scaled: [(String, Int?)] = base.map { item in
            // A crop to another shape names its short side; so does a vertical sequence.
            let h = settings.shape == .original && vertical ? Int((Double(item.1) * Double(p.height) / Double(p.width)).rounded()) : item.1
            let s = size(h)
            return ("\(item.0) (\(Int(s.width)) × \(Int(s.height)))", h)
        }
        let source = size(nil)
        return [("Source (\(Int(source.width)) × \(Int(source.height)))", nil)] + scaled
    }

    private var isVideo: Bool { settings.format == .mp4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SheetStyle.text)
                .padding(.bottom, 16)

            HStack(alignment: .center, spacing: 20) {
                form.frame(width: 284)
                Rectangle().fill(SheetStyle.divider).frame(width: 1)
                summaryColumn.frame(width: Self.previewWidth)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 20)

            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .background(SheetStyle.background)
        .preferredColorScheme(Theme.scheme)
        .onAppear(perform: setUp)
        .onExitCommand(perform: escape)
        .onDisappear { player.stop() }
    }

    static let loudnessTargets: [(String, Double?)] = [
        ("As mixed", nil), ("−14 LUFS · web, YouTube", -14), ("−16 LUFS · podcasts", -16), ("−23 LUFS · broadcast", -23),
    ]

    static func loudnessLabel(_ v: Double?) -> String {
        guard let v else { return "As mixed" }
        return "\(Int(v)) LUFS".replacingOccurrences(of: "-", with: "−")
    }

    static let previewWidth: CGFloat = 388
    static let fieldHeight: CGFloat = 28

    // MARK: Left column

    private var form: some View {
        let h = Self.fieldHeight
        return VStack(spacing: 8) {
            row("Filename") {
                HStack(spacing: 0) {
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .fixedSize()
                        .focused($nameFocused)
                    Text("." + settings.fileExtension)
                        .padding(.leading, -4)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(SheetStyle.text)
                .padding(.horizontal, 11)
                .frame(height: h)
                .sheetField(focused: nameFocused)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { nameFocused = true }
            }
            row("Location") {
                FolderButton(folder: folder, height: h, action: chooseFolder)
            }
            if let r = model.project.playRange {
                row("Range") {
                    SheetMenu(label: settings.rangeOnly ? "In to out · " + RangeReadout.length(r.end - r.start) : "Whole timeline", height: h) {
                        Button("In to out · " + RangeReadout.length(r.end - r.start)) { settings.rangeOnly = true; player.load(model, project: settings.output(model.project)) }
                        Button("Whole timeline") { settings.rangeOnly = false; player.load(model, project: model.project) }
                    }
                }
            }
            row("Format") {
                SheetMenu(label: isVideo ? "MP4 Video" : "WAV Audio", symbol: isVideo ? "film" : "waveform", height: h) {
                    Button("MP4 Video") { settings.format = .mp4 }
                    Button("WAV Audio") { settings.format = .wav }
                }
            }
            if isVideo {
                row("Resolution") {
                    SheetMenu(label: heights.first { $0.1 == settings.height }?.0 ?? heights[0].0, height: h) {
                        ForEach(heights, id: \.0) { item in
                            Button(item.0) { settings.height = item.1 }
                        }
                    }
                }
                row("Shape") {
                    SheetMenu(label: settings.shape.label, height: h) {
                        ForEach(ExportSettings.Shape.allCases, id: \.self) { shape in
                            Button(shape.label) {
                                settings.shape = shape
                                settings.reframe = CGPoint(x: 0.5, y: 0.5)
                            }
                        }
                    }
                }
                row("Codec") {
                    // An HDR project is always 10-bit HEVC in HLG (H.264 can't carry HDR).
                    if model.project.isHDR {
                        SheetMenu(label: "HEVC · HDR (HLG)", height: h) {
                            Button("HEVC · HDR (HLG, 10-bit)") {}
                            Text("H.264 can't carry HDR. For an SDR file, set the sequence to SDR.")
                        }
                    } else {
                        SheetMenu(label: settings.codec.rawValue, height: h) {
                            ForEach(ExportSettings.Codec.allCases, id: \.self) { codec in
                                Button(codec.rawValue) { settings.codec = codec }
                            }
                        }
                    }
                }
                row("Quality") {
                    SheetMenu(label: settings.quality == .high ? "High" : "Web", height: h) {
                        Button("High") { settings.quality = .high }
                        Button("Web") { settings.quality = .web }
                    }
                }
            }
            // Whether there's sound, and how loud: one menu ("No audio" only for video; a WAV is its sound).
            row("Audio") {
                SheetMenu(label: isVideo && !settings.includeAudio ? "No audio" : Self.loudnessLabel(settings.loudness), height: h) {
                    if isVideo {
                        Button("No audio") { settings.includeAudio = false }
                        Divider()
                    }
                    ForEach(Self.loudnessTargets, id: \.0) { item in
                        Button(item.0) {
                            settings.includeAudio = true
                            settings.loudness = item.1
                        }
                    }
                }
            }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(SheetStyle.label)
                .frame(width: 84, alignment: .leading)
            content()
        }
    }

    // MARK: Right column

    private var summaryColumn: some View {
        let p = model.project
        let size = settings.renderSize(for: p)
        let w = Self.previewWidth
        return VStack(alignment: .leading, spacing: 12) {
            PreviewPlayerBox(player: player, showsVideo: isVideo, projectAspect: p.aspect,
                             crop: isVideo && settings.crops(p) ? settings.renderSize(for: p) : nil,
                             reframe: $settings.reframe)
                .frame(width: w, height: (w * 9 / 16).rounded())
                // Exported bigger than the sequence: said so, since it's upscaled (sharpened as it's enlarged), not stretched.
                .overlay(alignment: .topLeading) {
                    if isVideo, Upscaler.shared.available, max(size.width, size.height) > CGFloat(max(p.width, p.height)) + 1 {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9.5, weight: .semibold))
                            Text("Upscaled from \(min(p.width, p.height))p").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Color(hex: 0xF2F2F0))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.55)))
                        .padding(8)
                        .allowsHitTesting(false)
                    }
                }

            // Spread edge to edge under the preview: first item flush left, last flush right.
            HStack(spacing: 0) {
                if isVideo {
                    stat("display", "\(Int(size.width)) × \(Int(size.height))")
                    Spacer(minLength: 8)
                    statDivider
                    Spacer(minLength: 8)
                    stat(nil, InspectorView.fpsLabel(p.fps))
                } else {
                    stat("waveform", "48 kHz · 24-bit")
                }
                Spacer(minLength: 8)
                statDivider
                Spacer(minLength: 8)
                stat("doc", estimatedSize)
            }
            .padding(.horizontal, 4)
        }
    }

    private var statDivider: some View {
        Rectangle().fill(Theme.ink.opacity(0.14)).frame(width: 1, height: 13)
    }

    private func stat(_ symbol: String?, _ text: String) -> some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11.5)).foregroundStyle(SheetStyle.label)
            }
            Text(text).font(.system(size: 11.5)).foregroundStyle(SheetStyle.label).lineLimit(1)
        }
    }

    private var estimatedSize: String {
        let p = model.project
        let bits: Double
        if isVideo {
            let size = settings.renderSize(for: p)
            bits = Double(settings.videoBitrate(size: size, fps: p.fps)) + (settings.includeAudio ? 256_000 : 0)
        } else {
            bits = 48000 * 24 * 2
        }
        let megabytes = bits * settings.output(p).duration / 8 / 1_000_000
        return megabytes >= 1000 ? String(format: "~%.1f GB", megabytes / 1000) : String(format: "~%.0f MB", max(1, megabytes))
    }

    // MARK: Actions

    private func setUp() {
        name = model.project.exportName ?? model.title
        if let dir = model.project.exportDir, FileManager.default.fileExists(atPath: dir) {
            folder = URL(fileURLWithPath: dir)
        } else {
            // Next to the project file, or the Desktop for a project that hasn't been saved.
            folder = model.fileURL?.deletingLastPathComponent()
                ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? folder
        }
        model.pause()
        settings.rangeOnly = model.project.playRange != nil
        player.load(model, project: settings.output(model.project))
        if CommandLine.arguments.contains("--export-vertical") { settings.shape = .vertical; settings.reframe = CGPoint(x: 0.3, y: 0.5) }
        if CommandLine.arguments.contains("--play-export-preview") { player.toggle() }
        // Don't open with the filename selected; it reads as an error state.
        DispatchQueue.main.async { nameFocused = false }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func escape() {
        model.showExport = false
    }

    private func start() {
        model.pause()
        player.pause()
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        if clean.isEmpty { clean = model.title }
        name = clean
        let url = folder.appendingPathComponent(clean + "." + settings.fileExtension)
        if FileManager.default.fileExists(atPath: url.path) {
            let alert = EditroomAlert()
            alert.messageText = "Replace “\(url.lastPathComponent)”?"
            alert.informativeText = "A file with this name already exists in \(folder.lastPathComponent)."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.commitLive()
        let p = model.project
        if settings.format == .wav && !p.clips.contains(where: { $0.kind == .audio }) {
            failure = "There's no audio on the timeline."
            return
        }
        model.setExportTarget(name: clean, directory: folder.path)
        // It runs in the background; the toolbar shows how it's going.
        model.exports.add(project: model.project, media: model.media, settings: settings, url: url)
        model.showExport = false
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let failure {
                Text(failure)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(hex: 0xFF7A6B))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            PillButton(title: "Cancel", prominent: false, large: true, shortcut: .cancelAction) { model.showExport = false }
            PillButton(title: "Export", prominent: true, large: true, shortcut: .defaultAction) { start() }
                .disabled(model.project.duration <= 0)
        }
    }
}

private struct FolderButton: View {
    let folder: URL
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SheetStyle.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(hovering ? SheetStyle.text : SheetStyle.label)
            }
            .padding(.horizontal, 11)
            .frame(height: height)
            .sheetField(hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Choose where exports are saved")
    }
}

// MARK: - Preview player

/// A small independent player for the export sheet, so the timeline can be watched before exporting.
@MainActor
final class PreviewPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    /// Where playback is, 0...1 of the timeline.
    @Published private(set) var progress = 0.0
    private(set) var duration = 0.0
    private var startTime = CMTime.zero
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    func load(_ model: EditorModel, project p: Project) {
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        if isPlaying { player.pause(); isPlaying = false }
        let scale = min(1, 960 / CGFloat(max(p.width, p.height)))
        let size = CGSize(width: max(2, (CGFloat(p.width) * scale / 2).rounded() * 2),
                          height: max(2, (CGFloat(p.height) * scale / 2).rounded() * 2))
        guard let built = CompositionBuilder.build(project: p, media: model.media, renderSize: size) else { return }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        player.actionAtItemEnd = .pause
        player.replaceCurrentItem(with: item)
        // Open on the frame under the playhead; playing from the very end starts over.
        // (For an in/out export, the playhead is measured from the range's start.)
        let from = p.duration == model.project.duration ? model.playhead : 0
        let t = min(max(0, from), max(0, built.duration - 1 / p.fps))
        startTime = CompositionBuilder.time(t)
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        duration = built.duration
        progress = built.duration > 0 ? t / built.duration : 0
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.duration > 0, time.seconds.isFinite else { return }
                self.progress = min(1, max(0, time.seconds / self.duration))
            }
        }
        isReady = true
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    func toggle() {
        guard isReady else { return }
        if isPlaying {
            pause()
        } else {
            player.playImmediately(atRate: 1)
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Jumps to a point (0...1 of the timeline), carrying on playing if it was.
    func seek(fraction: Double) {
        guard isReady, duration > 0 else { return }
        let f = min(1, max(0, fraction))
        progress = f
        player.seek(to: CompositionBuilder.time(f * duration), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
        isReady = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct PreviewPlayerBox: View {
    @ObservedObject var player: PreviewPlayer
    let showsVideo: Bool
    let projectAspect: CGFloat
    /// The output size when it crops the picture; nil shows the whole frame.
    let crop: CGSize?
    @Binding var reframe: CGPoint
    @State private var hovering = false
    @State private var dragStart: CGPoint?

    var body: some View {
        ZStack {
            Color.black
            if showsVideo {
                PlayerLayerView(player: player.player)
                if let crop {
                    GeometryReader { g in reframeOverlay(crop, in: g.size) }
                }
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.textFaint)
            }
            // Scrub bar along the bottom while playing or under the mouse: drag it to move through.
            if player.isPlaying || hovering {
                VStack(spacing: 0) {
                    Spacer()
                    ScrubBar(progress: player.progress) { player.seek(fraction: $0) }
                        .frame(height: 22)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
                }
            }
            if !player.isPlaying || hovering {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .scaleEffect(hovering ? 1.08 : 1)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.ink.opacity(hovering ? 0.28 : 0.14)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture { player.toggle() }
        .help("Play preview")
    }
}

extension PreviewPlayerBox {
    /// Where the picture sits in the box, and the window of it the export keeps.
    private func geometry(_ crop: CGSize, in box: CGSize) -> (picture: CGRect, window: CGRect) {
        let pw = min(box.width, box.height * projectAspect)
        let picture = CGRect(x: (box.width - pw) / 2, y: (box.height - pw / projectAspect) / 2, width: pw, height: pw / projectAspect)
        let oa = crop.width / crop.height
        let size = oa < projectAspect ? CGSize(width: picture.height * oa, height: picture.height)
                                      : CGSize(width: picture.width, height: picture.width / oa)
        let cx = min(max(picture.minX + size.width / 2, picture.minX + reframe.x * picture.width), picture.maxX - size.width / 2)
        let cy = min(max(picture.minY + size.height / 2, picture.minY + reframe.y * picture.height), picture.maxY - size.height / 2)
        return (picture, CGRect(x: cx - size.width / 2, y: cy - size.height / 2, width: size.width, height: size.height))
    }

    /// Dims what the export leaves out; drag the bright window to choose what to keep.
    @ViewBuilder fileprivate func reframeOverlay(_ crop: CGSize, in box: CGSize) -> some View {
        let geo = geometry(crop, in: box)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: box))
                p.addRect(geo.window)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            Rectangle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: geo.window.width, height: geo.window.height)
                .offset(x: geo.window.minX, y: geo.window.minY)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            if dragStart == nil { dragStart = reframe }
                            guard let s = dragStart else { return }
                            let half = CGSize(width: geo.window.width / 2 / geo.picture.width, height: geo.window.height / 2 / geo.picture.height)
                            reframe = CGPoint(x: min(max(half.width, s.x + v.translation.width / geo.picture.width), 1 - half.width),
                                              y: min(max(half.height, s.y + v.translation.height / geo.picture.height), 1 - half.height))
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
        }
    }
}

/// A thin progress track with a playhead, for the export preview. Click or drag to scrub.
private struct ScrubBar: View {
    let progress: Double
    let onSeek: (Double) -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let x = g.size.width * CGFloat(progress)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(height: hovering || dragging ? 4 : 3)
                Capsule().fill(Color.white).frame(width: max(0, x), height: hovering || dragging ? 4 : 3)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 2, height: hovering || dragging ? 12 : 9)
                    .offset(x: x - 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        onSeek(Double(v.location.x / max(1, g.size.width)))
                    }
                    .onEnded { _ in dragging = false }
            )
        }
    }
}

struct PillButton: View {
    let title: String
    let prominent: Bool
    var large = false
    var shortcut: KeyboardShortcut?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(prominent ? Theme.onText : Theme.text)
                .padding(.horizontal, large ? 18 : 15)
                .frame(height: 28)
                .background(
                    // The main action is a white pill; others are quiet grey.
                    Capsule().fill(prominent
                        ? AnyShapeStyle(Theme.text)
                        : AnyShapeStyle(large ? (hovering ? Theme.buttonHover : Theme.button) : Theme.ink.opacity(hovering ? 0.14 : 0.08)))
                )
                .overlay(Capsule().strokeBorder(Theme.ink.opacity(prominent ? 0 : 0.05)))
                .brightness(prominent && hovering ? -0.06 : 0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// The rounded, softly outlined field used throughout the export sheet: the same fill, hover and outline as the
    /// inspector's fields and menus.
    func sheetField(hovering: Bool = false, focused: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: SheetStyle.radius, style: .continuous).fill(hovering ? Theme.hover : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: SheetStyle.radius, style: .continuous)
                .strokeBorder(focused ? Theme.text.opacity(0.85) : Theme.ink.opacity(0.05), lineWidth: 1))
    }
}

/// Dropdown styled for the export sheet.
private struct SheetMenu<Content: View>: View {
    let label: String
    var symbol: String?
    var height: CGFloat = 30
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                }
                Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(SheetStyle.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(SheetStyle.text.opacity(0.85))
            }
            .padding(.horizontal, 11)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .sheetField(hovering: hovering)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Orange on/off switch with a white knob.
private struct AccentSwitch: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Theme.accent : Theme.control)
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                .padding(2)
        }
        .frame(width: 34, height: 20)
        .brightness(hovering ? 0.06 : 0)
        .animation(.easeOut(duration: 0.14), value: isOn)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture { isOn.toggle() }
    }
}
