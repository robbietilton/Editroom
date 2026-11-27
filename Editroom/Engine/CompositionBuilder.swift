import AVFoundation
import AppKit
import CoreImage

struct BuiltTimeline {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let duration: Double
    let signature: Int
    let hasAudio: Bool
    /// Each timeline audio track's composition track (only tracks with sound on them).
    var audioTracks: [UUID: CMPersistentTrackID] = [:]
}

/// A tiny black movie stretched under everything so the composition always has video to drive rendering.
enum BaseVideo {
    static var track: AVAssetTrack?
    static var range = CMTimeRange.zero
    private static var asset: AVURLAsset?

    static func load() async {
        guard track == nil, let url = Bundle.main.url(forResource: "Base", withExtension: "mp4") else { return }
        let a = AVURLAsset(url: url)
        guard let t = try? await a.loadTracks(withMediaType: .video).first,
              let r = try? await t.load(.timeRange) else { return }
        asset = a
        range = r
        track = t
    }
}

enum CompositionBuilder {
    static let timescale: CMTimeScale = 60000

    static func time(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    static func frameDuration(fps: Double) -> CMTime {
        let rounded = fps.rounded()
        if abs(fps - rounded) < 0.001 { return CMTime(value: 1, timescale: CMTimeScale(rounded)) }
        // NTSC style rates: 23.976, 29.97, 59.94
        return CMTime(value: 1001, timescale: CMTimeScale((fps * 1.001).rounded()) * 1000)
    }

    static func previewSize(for project: Project) -> CGSize {
        let w = Double(project.width), h = Double(project.height)
        let s = min(1, 1920 / max(w, h))
        return CGSize(width: max(2, (w * s / 2).rounded() * 2), height: max(2, (h * s / 2).rounded() * 2))
    }

    @MainActor
    /// With `reframe`, the sequence is scaled to cover `renderSize` and cropped around that point
    /// (0...1 across and down), for outputs of a different shape.
    /// With `keepAllTracks` (the player), hidden tracks stay in the composition, left out of the picture,
    /// so hiding one changes only the layers and the player takes that as it plays, with no new item
    /// and no pause. Muted and unsoloed tracks keep their sound at their own level: the player silences
    /// each track's sound itself (AudioStream), at once.
    static func build(project: Project, media: MediaStore, renderSize: CGSize,
                      includeVideo: Bool = true, includeAudio: Bool = true, reframe: CGPoint? = nil,
                      keepAllTracks: Bool = false, upscale: Bool = false) -> BuiltTimeline? {
        // The sequence is laid out on `canvas`, then `offset` picks the output's window from it.
        var canvas = renderSize
        var offset = CGPoint.zero
        if let center = reframe, renderSize.height > 0 {
            let pa = project.aspect, oa = renderSize.width / renderSize.height
            if abs(pa - oa) > 0.001 {
                canvas = pa > oa ? CGSize(width: (renderSize.height * pa).rounded(), height: renderSize.height)
                                 : CGSize(width: renderSize.width, height: (renderSize.width / pa).rounded())
                let ox = min(max(0, center.x * canvas.width - renderSize.width / 2), canvas.width - renderSize.width)
                let top = min(max(0, center.y * canvas.height - renderSize.height / 2), canvas.height - renderSize.height)
                // Core Image counts up from the bottom.
                offset = CGPoint(x: ox, y: canvas.height - renderSize.height - top)
            }
        }
        let total = project.duration
        guard total > 0 else { return nil }
        let comp = AVMutableComposition()
        var hasher = Hasher()
        hasher.combine(Int(renderSize.width)); hasher.combine(Int(renderSize.height))
        hasher.combine(project.fps); hasher.combine(time(total).value)
        // HDR (HLG): HDR clips come through composition tracks as they are, SDR clips are read from their files
        // (AVFoundation would brighten them into HDR), and everything is put together in HDR.
        let hdr = project.isHDR
        hasher.combine(hdr)
        hasher.combine(includeVideo); hasher.combine(includeAudio)

        if let base = BaseVideo.track, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? t.insertTimeRange(BaseVideo.range, of: base, at: .zero)
            t.scaleTimeRange(CMTimeRange(start: .zero, duration: BaseVideo.range.duration), toDuration: time(total))
            hasher.combine(1)
        }

        // Video
        var layers: [RenderLayer] = []
        var requiredTracks: [CMPersistentTrackID] = []
        let frame = CGRect(origin: .zero, size: canvas)

        if includeVideo {
            for track in project.videoTracks where keepAllTracks || !track.hidden {
                hasher.combine(track.id)
                let layersBefore = layers.count, tracksBefore = requiredTracks.count
                defer {
                    // A hidden track keeps its place in the composition but adds nothing to the picture.
                    if track.hidden {
                        layers.removeSubrange(layersBefore...)
                        requiredTracks.removeSubrange(tracksBefore...)
                    }
                }
                let clips = project.clips.filter { $0.trackID == track.id }.sorted { $0.start < $1.start }
                // Clips alternate between two composition tracks, so neighbours can overlap in a transition.
                var compTracks: [AVMutableCompositionTrack?] = [nil, nil]
                var cursors: [CMTime] = [.zero, .zero]
                for (index, clip) in clips.enumerated() {
                    let plan = project.transitionPlan(clip)
                    switch clip.kind {
                    case .video where clip.playsBackwards:
                        // Read backwards from the file as it plays; no composition track needed.
                        guard let id = clip.assetID, let rt = media.runtimes[id],
                              let frames = hdr && rt.sourceColor.isHDR ? rt.hdrFrames : rt.reverseFrames,
                              let length = project.asset(id)?.duration else { continue }
                        var shown = clip
                        shown.start -= plan.leadIn
                        shown.sourceStart = clip.sourceTime(at: shown.start)
                        hash(shown, media: media, into: &hasher)
                        let limit = Int(max(canvas.width, canvas.height).rounded())
                        layers.append(RenderLayer(clip: clip, source: .reversed(frames, rt.orientation, limit: limit, clock: SourceClock(shown), length: length),
                                                  cube: GradeBaker.cube(for: clip.grade), color: rt.sourceColor, plan: plan,
                                                  scrub: rt.sourceColor.isStandard ? ScrubSource(asset: id, clock: SourceClock(shown), reversedLength: length) : nil))
                    case .video where clip.assetID.flatMap { media.runtimes[$0] }.map { hdr ? !$0.sourceColor.isHDR : !$0.sourceColor.isStandard } == true:
                        // Read from the file as it plays, so the compositor gets the file's own pixels; no composition
                        // track needed. An SDR project: HDR and Log. An HDR project: SDR and Log.
                        guard let id = clip.assetID, let rt = media.runtimes[id], let frames = rt.reverseFrames else { continue }
                        var shown = clip
                        shown.start -= plan.leadIn
                        if !clip.isFreeze { shown.sourceStart = clip.sourceTime(at: shown.start) }
                        hash(shown, media: media, into: &hasher)
                        let limit = Int(max(canvas.width, canvas.height).rounded())
                        layers.append(RenderLayer(clip: clip, source: .decoded(frames, rt.orientation, limit: limit, clock: SourceClock(shown)),
                                                  cube: GradeBaker.cube(for: clip.grade), color: rt.sourceColor, plan: plan,
                                                  scrub: rt.sourceColor.isStandard ? ScrubSource(asset: id, clock: SourceClock(shown)) : nil))
                    case .video:
                        guard let id = clip.assetID, let rt = media.runtimes[id], let src = rt.videoTrack else { continue }
                        let lane = index % 2
                        if compTracks[lane] == nil {
                            compTracks[lane] = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                            if let ct = compTracks[lane] { requiredTracks.append(ct.trackID) }
                        }
                        // The stretch of media actually shown, including any a transition borrows.
                        var shown = clip
                        shown.start -= plan.leadIn
                        if !clip.isFreeze { shown.sourceStart = clip.sourceTime(at: shown.start) }
                        shown.duration += plan.leadIn + plan.tailOut
                        guard let ct = compTracks[lane], insert(shown, source: src, range: rt.videoRange, into: ct, cursor: &cursors[lane]) else { continue }
                        hash(shown, media: media, into: &hasher)
                        layers.append(RenderLayer(clip: clip, source: .track(ct.trackID, rt.orientation), cube: GradeBaker.cube(for: clip.grade), color: rt.sourceColor, plan: plan,
                                                  scrub: rt.sourceColor.isStandard ? ScrubSource(asset: id, clock: SourceClock(shown)) : nil))
                    case .image:
                        guard let cg = media.still(clip.assetID) else { continue }
                        let img = CIImage(cgImage: cg)
                        let e = img.extent
                        let s = min(frame.width / e.width, frame.height / e.height)
                        let fitted = img.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                                                           tx: (frame.width - e.width * s) / 2,
                                                                           ty: (frame.height - e.height * s) / 2))
                        layers.append(RenderLayer(clip: clip, source: .image(fitted), cube: GradeBaker.cube(for: clip.grade), plan: plan))
                    case .solid:
                        let c = clip.color
                        layers.append(RenderLayer(clip: clip, source: .color(CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)), cube: GradeBaker.cube(for: clip.grade), plan: plan))
                    case .text:
                        guard let img = TextRenderer.image(clip.text, renderSize: canvas) else { continue }
                        layers.append(RenderLayer(clip: clip, source: .image(img), cube: GradeBaker.cube(for: clip.grade), plan: plan))
                    case .audio:
                        continue
                    }
                }
            }
        }

        // Audio
        var mixParams: [AVMutableAudioMixInputParameters] = []
        var audioTracks: [UUID: CMPersistentTrackID] = [:]
        if includeAudio {
            for track in project.audioTracks where keepAllTracks || project.isAudible(track) {
                hasher.combine(track.id)
                let audible = keepAllTracks || project.isAudible(track)
                let clips = project.clips.filter { $0.trackID == track.id && $0.kind == .audio }.sorted { $0.start < $1.start }
                var compTrack: AVMutableCompositionTrack?
                var params: AVMutableAudioMixInputParameters?
                var cursor = CMTime.zero
                let trackGain = audible ? dbToLinear(track.gainDB) : 0
                // Ducking under another track: the level follows that track's sound.
                let duckSpans: [(start: Double, end: Double)]? = !audible ? nil : track.duckUnder.flatMap { voice in
                    guard let v = project.audioTracks.first(where: { $0.id == voice }), project.isAudible(v) else { return nil }
                    return AudioLevels.activity(on: voice, project: project, media: media)
                }
                let duckLow = dbToLinear(track.duckDB)
                for clip in clips {
                    guard clip.speedRange.hi <= 32, clip.speedRange.lo >= 1.0 / 32,
                          let id = clip.assetID, let rt = media.runtimes[id], var src = rt.audioTrack else { continue }
                    var clip = clip
                    var sourceRange = rt.audioRange
                    if clip.playsBackwards {
                        // The reversed sound runs from the end of the file's sound; line it up with the
                        // file's length, which a reversed clip's source time is measured from.
                        guard let r = media.reversedAudio(id), let length = project.asset(id)?.duration else { hasher.combine(-1); continue }
                        clip.sourceStart += r.range.duration.seconds - length
                        clip.ramp = clip.ramp?.shifted(by: r.range.duration.seconds - length)
                        src = r.track
                        sourceRange = r.range
                        hasher.combine(-2)
                    }
                    if compTrack == nil {
                        compTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        if let ct = compTrack {
                            let p = AVMutableAudioMixInputParameters(track: ct)
                            p.audioTimePitchAlgorithm = .spectral
                            params = p
                            mixParams.append(p)
                            audioTracks[track.id] = ct.trackID
                        }
                    }
                    guard let ct = compTrack, let p = params, insert(clip, source: src, range: sourceRange, into: ct, cursor: &cursor) else { continue }
                    hash(clip, media: media, into: &hasher)

                    let gain = Float(trackGain * dbToLinear(clip.gainDB))
                    if let spans = duckSpans, !spans.isEmpty {
                        // Fades and ducking together, as short linear pieces every 50ms.
                        let step = 0.05
                        var t0 = clip.start
                        func level(_ t: Double) -> Float {
                            gain * Float(clip.fadeGain(at: t) * AudioLevels.duckGain(at: t, spans: spans, low: duckLow))
                        }
                        while t0 < clip.end - 1e-6 {
                            let t1 = min(clip.end, t0 + step)
                            p.setVolumeRamp(fromStartVolume: level(t0), toEndVolume: level(t1), timeRange: CMTimeRange(start: time(t0), end: time(t1)))
                            t0 = t1
                        }
                        continue
                    }
                    let start = time(clip.start), end = time(clip.end)
                    let fi = min(time(clip.fadeIn), end - start)
                    let fo = min(time(clip.fadeOut), end - start - fi)
                    if fi > .zero {
                        ramp(p, from: start, duration: fi, gain: gain, curve: clip.inCurve, rising: true)
                    } else {
                        p.setVolume(gain, at: start)
                    }
                    if fo > .zero {
                        ramp(p, from: end - fo, duration: fo, gain: gain, curve: clip.outCurve, rising: false)
                    }
                }
            }
        }

        let vc = AVMutableVideoComposition()
        vc.frameDuration = frameDuration(fps: project.fps)
        vc.renderSize = renderSize
        if hdr {
            // HLG in Rec.2020: HDR clips' composition tracks arrive as they are (PQ made HLG).
            vc.customVideoCompositorClass = HDRTimelineCompositor.self
            vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
            vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
        } else {
            // The timeline is Rec.709. Only SDR clips go through composition tracks (AVFoundation leaves
            // them as they are); HDR and Log clips are read straight from their files and converted by
            // the compositor (SourceColor), because AVFoundation's conversion of them is inaccurate.
            vc.customVideoCompositorClass = TimelineCompositor.self
            vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        let range = CMTimeRange(start: .zero, duration: CMTimeMaximum(comp.duration, time(total)))
        // Captions: read from what's said in the captioned clips, unless the caption track is hidden.
        var captions: [CaptionLayer] = []
        if includeVideo, let track = project.captions, !track.hidden {
            captions = CaptionRenderer.layers(CaptionLayout.blocks(project) { media.transcript($0.id) }, style: track.style)
        }
        // The upscaler works in Rec.709; an HDR export is resized as before.
        vc.instructions = [TimelineInstruction(timeRange: range, layers: layers, trackIDs: requiredTracks, canvas: canvas, offset: offset,
                                               captions: captions, upscale: upscale && !hdr, hdr: hdr)]

        var mix: AVMutableAudioMix?
        if !mixParams.isEmpty {
            mix = AVMutableAudioMix()
            mix?.inputParameters = mixParams
        }

        return BuiltTimeline(composition: comp.copy() as! AVComposition, videoComposition: vc, audioMix: mix,
                             duration: total, signature: hasher.finalize(), hasAudio: !mixParams.isEmpty, audioTracks: audioTracks)
    }

    /// Volume ramps are linear, so curved fades are approximated with short linear pieces.
    private static func ramp(_ p: AVMutableAudioMixInputParameters, from start: CMTime, duration: CMTime,
                             gain: Float, curve: FadeCurve, rising: Bool) {
        let pieces = curve == .linear ? 1 : 16
        var t0 = start
        for i in 0..<pieces {
            let x0 = Double(i) / Double(pieces), x1 = Double(i + 1) / Double(pieces)
            let t1 = i == pieces - 1 ? start + duration : start + CMTimeMultiplyByFloat64(duration, multiplier: x1)
            guard t1 > t0 else { continue }
            let v0 = gain * Float(curve.apply(rising ? x0 : 1 - x0))
            let v1 = gain * Float(curve.apply(rising ? x1 : 1 - x1))
            p.setVolumeRamp(fromStartVolume: v0, toEndVolume: v1, timeRange: CMTimeRange(start: t0, end: t1))
            t0 = t1
        }
    }

    @MainActor private static func hash(_ clip: Clip, media: MediaStore, into hasher: inout Hasher) {
        hasher.combine(clip.assetID)
        // The file the item has open: reloaded from disk (a rotated copy saved over it), it's a new one, so the
        // player builds afresh instead of keeping what it made from the old file.
        if let id = clip.assetID, let rt = media.runtimes[id] { hasher.combine(ObjectIdentifier(rt)) }
        hasher.combine(clip.start)
        hasher.combine(clip.duration)
        hasher.combine(clip.sourceStart)
        hasher.combine(clip.speed)
        hasher.combine(clip.reversed)
        hasher.combine(clip.ramp)
    }

    /// Places one clip's media on a composition track, applying speed by scaling the inserted range.
    private static func insert(_ clip: Clip, source: AVAssetTrack, range: CMTimeRange,
                               into track: AVMutableCompositionTrack, cursor: inout CMTime) -> Bool {
        let start = time(clip.start)
        let end = time(clip.end)
        guard start >= cursor, end > start else { return false }
        if clip.isFreeze {
            // One source frame stretched over the whole clip.
            let frame = CMTime(value: 1, timescale: 60)
            var at = time(clip.sourceStart)
            if at < range.start { at = range.start }
            if at + frame > range.end { at = range.end - frame }
            guard at >= range.start else { return false }
            do { try track.insertTimeRange(CMTimeRange(start: at, duration: frame), of: source, at: start) } catch { return false }
            track.scaleTimeRange(CMTimeRange(start: start, duration: frame), toDuration: end - start)
            cursor = end
            return true
        }
        if clip.isRamped { return insertRamped(clip, source: source, range: range, into: track, cursor: &cursor) }
        let unity = abs(clip.speed - 1) < 1e-9
        var srcStart = time(clip.sourceStart)
        var tgtDur = end - start
        var srcDur = unity ? tgtDur : time(clip.duration * clip.speed)
        if srcStart < range.start { srcStart = range.start }
        let available = range.end - srcStart
        guard available > .zero else { return false }
        if srcDur > available {
            srcDur = available
            tgtDur = unity ? available : CMTimeMinimum(tgtDur, CMTimeMultiplyByFloat64(available, multiplier: 1 / clip.speed))
        }
        guard srcDur > .zero, tgtDur > .zero else { return false }
        do {
            try track.insertTimeRange(CMTimeRange(start: srcStart, duration: srcDur), of: source, at: start)
        } catch {
            return false
        }
        if srcDur != tgtDur {
            track.scaleTimeRange(CMTimeRange(start: start, duration: srcDur), toDuration: tgtDur)
        }
        cursor = start + tgtDur
        return true
    }

    /// A ramped clip: its footage in short pieces, each played at its own speed, so the speed
    /// changes smoothly (about every frame through a ramp; one piece where it holds steady).
    private static func insertRamped(_ clip: Clip, source: AVAssetTrack, range: CMTimeRange,
                                     into track: AVMutableCompositionTrack, cursor: inout CMTime) -> Bool {
        guard let ramp = clip.ramp else { return false }
        let start = time(clip.start)
        guard start >= cursor, clip.duration > 0 else { return false }
        let lo = range.start.seconds, hi = range.end.seconds
        let s0 = max(lo, clip.sourceStart)
        let s1 = min(hi, clip.sourceTime(at: clip.end))
        guard s1 > s0 else { return false }
        // Where the footage is cut into pieces: the ramp's marks, and steps through each ramp.
        var cuts = [s0, s1]
        for (a, b) in [(ramp.inFrom, ramp.inTo), (ramp.outFrom, ramp.outTo)] where b > a {
            let steps = max(4, min(90, Int((clip.timelineSpan(from: a, to: b) * 30).rounded(.up))))
            for i in 0...steps { cuts.append(a + (b - a) * Double(i) / Double(steps)) }
        }
        cuts = Array(Set(cuts.filter { $0 >= s0 && $0 <= s1 })).sorted()
        var at = start
        for (a, b) in zip(cuts, cuts.dropFirst()) where b - a > 1e-6 {
            let srcRange = CMTimeRange(start: time(a), end: time(b))
            let end = time(clip.start + clip.timelineSpan(from: clip.sourceStart, to: b))
            guard srcRange.duration > .zero, end > at else { continue }
            do { try track.insertTimeRange(srcRange, of: source, at: at) } catch { return false }
            if srcRange.duration != end - at { track.scaleTimeRange(CMTimeRange(start: at, duration: srcRange.duration), toDuration: end - at) }
            at = end
        }
        cursor = at
        return at > start
    }
}

// MARK: - Text

enum TextRenderer {
    private struct Key: Hashable {
        let style: TextStyle
        let w: Int
        let h: Int
    }

    @MainActor private static var cache: [Key: CIImage] = [:]

    static func font(_ style: TextStyle, size: CGFloat) -> NSFont {
        if !style.fontName.isEmpty {
            let manager = NSFontManager.shared
            if let f = manager.font(withFamily: style.fontName, traits: style.bold ? .boldFontMask : [], weight: 5, size: size) { return f }
            if let f = NSFont(name: style.fontName, size: size) { return f }
        }
        return NSFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
    }

    @MainActor
    static func image(_ style: TextStyle, renderSize: CGSize) -> CIImage? {
        guard !style.string.isEmpty else { return nil }
        let key = Key(style: style, w: Int(renderSize.width), h: Int(renderSize.height))
        if let hit = cache[key] { return hit }

        let pt = CGFloat(style.size) * renderSize.height / 1080
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let c = style.color
        let attr = NSAttributedString(string: style.string, attributes: [
            .font: font(style, size: pt),
            .foregroundColor: NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a),
            .paragraphStyle: para,
        ])
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = attr.boundingRect(with: CGSize(width: renderSize.width * 0.94, height: .greatestFiniteMagnitude), options: opts)
        let pad = ceil(pt * 0.25)
        let tw = ceil(bounds.width), th = ceil(bounds.height)
        let w = Int(tw + pad * 2), h = Int(th + pad * 2)
        guard w > 0, h > 0, w < 16384, h < 16384,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attr.draw(with: CGRect(x: pad, y: pad, width: tw, height: th), options: opts)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }

        let cx = style.x * renderSize.width
        let cy = (1 - style.y) * renderSize.height
        let image = CIImage(cgImage: cg).transformed(by: CGAffineTransform(
            translationX: (cx - CGFloat(w) / 2).rounded(), y: (cy - CGFloat(h) / 2).rounded()))
        if cache.count > 64 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
