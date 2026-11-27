import AppKit
import Foundation
import AVFoundation

/// Headless engine check: `Editroom --selftest <mediaDir> <outDir>`.
/// Imports every file in mediaDir, builds a small multi-track edit, and exports MP4 + WAV.
@MainActor
enum SelfTest {
    nonisolated static func runIfRequested() {
        let args = CommandLine.arguments
        // `--bench <dir>`: how fast the preview pipeline makes frames from the 4K clips in a folder.
        if let i = args.firstIndex(of: "--bench"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                await bench(dir)
                exit(0)
            }
            return
        }
        // `--bench-files <file>...`: how fast the preview pipeline makes frames for each file (HDR included), alone and
        // with a second copy over it as a picture-in-picture, at the file's own size and rate.
        if let i = args.firstIndex(of: "--bench-files") {
            let files = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                await benchFiles(files)
                exit(0)
            }
            return
        }
        // `--reverse-bench <file>...`: how long reversing each whole file takes.
        if let i = args.firstIndex(of: "--reverse-bench") {
            let files = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                let media = MediaStore()
                for f in files {
                    guard let a = await media.importFile(f) else { log("RBENCH can't open \(f.lastPathComponent)"); continue }
                    // Sound: made once per file (the cached copy is removed first, to time it fresh).
                    if a.hasAudio || a.kind == .audio {
                        try? FileManager.default.removeItem(at: ReverseAudio.cacheURL(for: a.url))
                        let t0 = Date()
                        await media.prepareReversedAudio(a.id)?.value
                        log(String(format: "RBENCH %@ %.1fs long: sound reversed in %.2fs (ready=%@)", f.lastPathComponent, a.duration,
                                   Date().timeIntervalSince(t0), media.runtimes[a.id]?.reversedAudio != nil ? "yes" : "no"))
                    }
                    // Picture: frames played backwards in order, as fast as they come.
                    if let frames = media.runtimes[a.id]?.reverseFrames {
                        for limit in [1920, 3840] {
                            let fps = max(24, a.fps)
                            let n = Int(min(a.duration, 6) * fps)
                            let t0 = Date()
                            var got = 0
                            for i in 0..<n where frames.frame(before: a.duration - Double(i) / fps, limit: limit) != nil { got += 1 }
                            let dt = Date().timeIntervalSince(t0)
                            log(String(format: "RBENCH %@ backwards at %d px: %d/%d frames, %.0f fps (needs %.0f)", f.lastPathComponent, limit, got, n, Double(n) / dt, a.fps))
                        }
                    }
                }
                exit(0)
            }
            return
        }
        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 2 else { return }
        let mediaDir = URL(fileURLWithPath: args[i + 1])
        let outDir = URL(fileURLWithPath: args[i + 2])
        Task { @MainActor in
            await run(mediaDir: mediaDir, outDir: outDir)
            exit(0)
        }
    }

    @MainActor
    static func bench(_ dir: URL) async {
        await BaseVideo.load()
        let media = MediaStore()
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var assets: [MediaAsset] = []
        for f in files { if let a = await media.importFile(f) { assets.append(a) } }
        guard let a60 = assets.first(where: { $0.fps > 50 }), let a30 = assets.first(where: { $0.fps < 50 }) else { log("BENCH needs a 4K60 and a 4K30 clip"); return }

        func project(heavy: Bool) -> Project {
            var p = Project()
            p.width = 3840; p.height = 2160; p.fps = 60
            p.assets = assets
            let v1 = p.videoTracks[0].id, v2 = p.videoTracks[1].id
            var base = Clip(trackID: v1, kind: .video, assetID: a60.id, start: 0, duration: 10)
            if heavy {
                var g = ColorGrade()
                g.look = "Teal and orange"
                g.exposure = 0.3
                g.midtones = WheelPoint(x: 0.4, y: -0.2)
                base.grade = g
                var pip = Clip(trackID: v2, kind: .video, assetID: a30.id, start: 0, duration: 10)
                pip.transform = ClipTransform(scale: 0.45, x: 0.22, y: -0.2)
                pip.fadeIn = 1
                let v3 = p.addTrack(.video)
                var text = Clip(trackID: v3, kind: .text, start: 0, duration: 10)
                text.text.string = "Benchmark"
                p.clips = [base, pip, text]
            } else {
                p.clips = [base]
            }
            return p
        }

        for (name, heavy) in [("single 4K60 clip", false), ("4K60 graded + 4K30 picture-in-picture + text", true)] {
            let p = project(heavy: heavy)
            let size = CompositionBuilder.previewSize(for: p)
            guard let built = CompositionBuilder.build(project: p, media: media, renderSize: size, includeAudio: false),
                  let reader = try? AVAssetReader(asset: built.composition) else { continue }
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: built.composition.tracks(withMediaType: .video),
                                                             videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = built.videoComposition
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))
            let t0 = CACurrentMediaTime()
            reader.startReading()
            var frames = 0
            while output.copyNextSampleBuffer() != nil { frames += 1 }
            let secs = CACurrentMediaTime() - t0
            log(String(format: "BENCH %@: %d frames at %dx%d in %.2fs = %.0f fps (playback needs 60)", name, frames, Int(size.width), Int(size.height), secs, Double(frames) / secs))
        }
    }

    static func benchFiles(_ files: [URL]) async {
        await BaseVideo.load()
        let media = MediaStore()
        for f in files {
            guard let a = await media.importFile(f) else { log("BENCH can't open \(f.lastPathComponent)"); continue }
            let kind = media.runtimes[a.id]?.sourceColor ?? .standard
            for layers in [1, 2] {
                var p = Project()
                p.width = a.width; p.height = a.height; p.fps = a.fps > 1 ? a.fps : 30
                p.assets = [a]
                let length = min(8, a.duration)
                var clips = [Clip(trackID: p.videoTracks[0].id, kind: .video, assetID: a.id, start: 0, duration: length)]
                if layers == 2 {
                    var pip = Clip(trackID: p.videoTracks[1].id, kind: .video, assetID: a.id, start: 0, duration: length)
                    pip.sourceStart = min(1, a.duration / 4)
                    pip.transform = ClipTransform(scale: 0.45, x: 0.22, y: -0.2)
                    clips.append(pip)
                }
                p.clips = clips
                let size = CompositionBuilder.previewSize(for: p)
                guard let built = CompositionBuilder.build(project: p, media: media, renderSize: size, includeAudio: false),
                      let reader = try? AVAssetReader(asset: built.composition) else { log("BENCH \(a.name): no composition"); continue }
                let output = AVAssetReaderVideoCompositionOutput(videoTracks: built.composition.tracks(withMediaType: .video),
                                                                 videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                output.videoComposition = built.videoComposition
                output.alwaysCopiesSampleData = false
                reader.add(output)
                reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600))
                let t0 = CACurrentMediaTime()
                reader.startReading()
                var frames = 0
                while output.copyNextSampleBuffer() != nil { frames += 1 }
                let secs = CACurrentMediaTime() - t0
                log(String(format: "BENCH %@ (%@, %dx%d %.0ffps) %@: %d frames at %dx%d in %.2fs = %.0f fps (needs %.0f)",
                           a.name, "\(kind)", a.width, a.height, p.fps, layers == 1 ? "alone" : "with a picture-in-picture copy",
                           frames, Int(size.width), Int(size.height), secs, Double(frames) / secs, p.fps))
            }
        }
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    /// A one-second 640×360 test clip whose picture is `value(x)` across (the same down): 10-bit HEVC in HLG (the
    /// values are the HLG signal), or SDR in Rec.709.
    private static func makeTestClip(_ url: URL, hlg: Bool, value: (Int) -> Double) async -> Bool {
        try? FileManager.default.removeItem(at: url)
        let W = 640, H = 360
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let color: [String: Any] = hlg
            ? [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
            : [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: (hlg ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String,
                                              AVVideoQualityKey: 0.95],
            AVVideoColorPropertiesKey: color])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        // Half floats by hand: Swift's Float16 isn't there on Intel Macs. (Values here are 0-1.)
        func half(_ v: Float) -> UInt16 {
            guard v > 0 else { return 0 }
            let bits = v.bitPattern, exp = Int((bits >> 23) & 0xFF) - 112, man = bits & 0x7F_FFFF
            guard exp > 0 else { return 0 }
            return UInt16(min(0x7BFF, (UInt32(exp) << 10 | man >> 13) + ((man >> 12) & 1)))
        }
        let columns = (0..<W).map { half(Float(value($0))) }
        for f in 0..<30 {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let b = pb else { return false }
            CVPixelBufferLockBaseAddress(b, [])
            let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt16.self), row = CVPixelBufferGetBytesPerRow(b) / 2
            for y in 0..<H { for x in 0..<W { let p = base + y * row + x * 4; p[0] = columns[x]; p[1] = columns[x]; p[2] = columns[x]; p[3] = 0x3C00 } }
            CVPixelBufferUnlockBaseAddress(b, [])
            CVBufferSetAttachment(b, kCVImageBufferColorPrimariesKey, hlg ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(b, kCVImageBufferTransferFunctionKey, hlg ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, hlg ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    /// A file's video transfer function (HLG, Rec.709...), as its tags say.
    private static func transferFunction(_ url: URL) async -> String? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let fd = try? await track.load(.formatDescriptions).first else { return nil }
        return CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
    }

    /// The luma (0...1) at points (x, y from the top) of the frame at `time`, read as the file has it (no conversion).
    private static func lumaSamples(_ url: URL, at time: Double, points: [(Int, Int)]) async -> [Double?] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return points.map { _ in nil } }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 600), duration: CMTime(seconds: 0.2, preferredTimescale: 600))
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(), let b = CMSampleBufferGetImageBuffer(sample) else { return points.map { _ in nil } }
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt16.self), row = CVPixelBufferGetBytesPerRowOfPlane(b, 0) / 2
        return points.map { x, y in (Double(base[y * row + x] >> 6) - 64) / 876 }
    }

    private static func export(_ project: Project, _ media: MediaStore, _ settings: ExportSettings, to url: URL) async -> Bool {
        let exporter = Exporter()
        exporter.start(project: project, media: media, settings: settings, url: url)
        while exporter.state == .running { try? await Task.sleep(nanoseconds: 50_000_000) }
        if case .done = exporter.state {
            log("EXPORT OK \(url.lastPathComponent)")
            return true
        }
        log("EXPORT FAIL \(url.lastPathComponent): \(exporter.state)")
        return false
    }

    static func run(mediaDir: URL, outDir: URL) async {
        await BaseVideo.load()
        log("base track: \(BaseVideo.track != nil)")
        let media = MediaStore()
        var project = Project()
        let files = ((try? FileManager.default.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            if let a = await media.importFile(f) {
                project.assets.append(a)
                log("IMPORT OK \(f.lastPathComponent) kind=\(a.kind) dur=\(a.duration) \(a.width)x\(a.height) fps=\(a.fps) audio=\(a.hasAudio) converted=\(a.playablePath != nil)")
            } else {
                log("IMPORT FAIL \(f.lastPathComponent)")
            }
        }
        guard let video = project.assets.first(where: { $0.kind == .video && $0.hasAudio }) else {
            log("SELFTEST FAIL no video asset")
            return
        }
        project.width = 1280
        project.height = 720
        project.fps = 30
        let v1 = project.videoTracks[0].id, v2 = project.videoTracks[1].id
        let a1 = project.audioTracks[0].id, a2 = project.audioTracks[1].id

        // 0-2s normal speed, 2-3s at 400% (source 2s..6s), then a solid fading in.
        let l1 = UUID(), l2 = UUID()
        var c1 = Clip(trackID: v1, kind: .video, assetID: video.id, start: 0, duration: 2)
        c1.linkID = l1
        c1.fadeIn = 0.5
        var c1a = Clip(trackID: a1, kind: .audio, assetID: video.id, start: 0, duration: 2)
        c1a.linkID = l1
        c1a.fadeIn = 0.5
        var c2 = Clip(trackID: v1, kind: .video, assetID: video.id, start: 2, duration: 1, sourceStart: 2, speed: 4)
        c2.linkID = l2
        var c2a = Clip(trackID: a1, kind: .audio, assetID: video.id, start: 2, duration: 1, sourceStart: 2, speed: 4)
        c2a.linkID = l2
        var solid = Clip(trackID: v1, kind: .solid, start: 3.5, duration: 1)
        solid.color = RGBA(r: 0.9, g: 0.2, b: 0.2, a: 1)
        solid.fadeIn = 0.5
        // Half size, in the top-right quarter of the frame.
        solid.transform = ClipTransform(scale: 0.5, x: 0.25, y: -0.25)
        var text = Clip(trackID: v2, kind: .text, start: 0.5, duration: 2)
        text.text.string = "Editroom"
        text.fadeIn = 0.5
        text.fadeOut = 0.5
        text.fadeOutCurve = .smooth
        // Grade the sped-up section: mono look plus a strong warm push in the highlights.
        var grade = ColorGrade()
        grade.look = "Mono"
        grade.highlights = WheelPoint(x: 1, y: 0)
        c2.grade = grade
        // Dissolve from the normal-speed section into the graded, sped-up one.
        c2.transitionIn = Transition(kind: .dissolve, duration: 0.5)
        c1.fadeInCurve = .easeIn
        c1a.fadeInCurve = .easeIn
        project.clips = [c1, c1a, c2, c2a, solid, text]

        if let small = project.assets.first(where: { $0.kind == .video && $0.id != video.id }) {
            // Picture-in-track test: a second source on V2 over the sped-up section.
            project.clips.append(Clip(trackID: v2, kind: .video, assetID: small.id, start: 2.5, duration: min(1, small.duration)))
        }
        if let tone = project.assets.first(where: { $0.kind == .audio }) {
            var t = Clip(trackID: a2, kind: .audio, assetID: tone.id, start: 1, duration: min(3, tone.duration))
            t.gainDB = -6
            t.fadeOut = 1
            project.clips.append(t)
        }
        project.sanitize()
        log("project duration \(project.duration)")
        if let data = try? JSONEncoder().encode(SavedDocument(project: project)) {
            try? data.write(to: outDir.appendingPathComponent("selftest.room"))
        }

        var ok = true
        var s = ExportSettings()
        ok = await export(project, media, s, to: outDir.appendingPathComponent("edit_h264.mp4")) && ok
        s.codec = .hevc
        s.quality = .web
        s.height = 2160
        ok = await export(project, media, s, to: outDir.appendingPathComponent("edit_hevc_4k_web.mp4")) && ok
        s = ExportSettings()
        s.includeAudio = false
        s.height = 360
        ok = await export(project, media, s, to: outDir.appendingPathComponent("edit_noaudio.mp4")) && ok
        s = ExportSettings()
        s.format = .wav
        ok = await export(project, media, s, to: outDir.appendingPathComponent("edit.wav")) && ok

        // Gain check: a lone tone at +6 dB and at 0 dB.
        if let tone = project.assets.first(where: { $0.kind == .audio }) {
            for (name, db) in [("tone_0db.wav", 0.0), ("tone_plus6.wav", 6.0), ("tone_minus12.wav", -12.0)] {
                var p = Project()
                p.assets = project.assets
                var c = Clip(trackID: p.audioTracks[0].id, kind: .audio, assetID: tone.id, start: 0, duration: min(2, tone.duration))
                c.gainDB = db
                p.clips = [c]
                ok = await export(p, media, s, to: outDir.appendingPathComponent(name)) && ok
            }
        }
        // Speed change on several clips: they stay butted together, and untouched clips are pushed, never overlapped.
        do {
            var p = Project()
            p.assets = project.assets
            let t = p.videoTracks[0].id
            let a = Clip(trackID: t, kind: .video, assetID: video.id, start: 0, duration: 2)
            let b = Clip(trackID: t, kind: .video, assetID: video.id, start: 2, duration: 2, sourceStart: 2)
            let c = Clip(trackID: t, kind: .solid, start: 4, duration: 1)
            p.clips = [a, b, c]
            var fast = p
            fast.setSpeed(ids: [a.id, b.id], speed: 2)
            var slow = p
            slow.setSpeed(ids: [a.id, b.id], speed: 0.5)
            let f = fast.clips.map { [$0.start, $0.end] }, sl = slow.clips.map { [$0.start, $0.end] }
            let pass = f == [[0, 1], [1, 2], [4, 5]] && sl == [[0, 4], [4, 8], [8, 9]]
            log("SPEED GROUP \(pass ? "OK" : "FAIL") fast=\(f) slow=\(sl)")
            ok = ok && pass
        }
        // Speed ramps: 100% → 400% → 100% over 4s of footage. Timing round-trips, the footage stays the
        // same, a split keeps both halves on the same curve, reversing mirrors it, and it exports.
        do {
            var p = Project()
            p.assets = project.assets
            let t = p.videoTracks[0].id, at = p.audioTracks[0].id
            let link = UUID()
            var v = Clip(trackID: t, kind: .video, assetID: video.id, start: 0, duration: 4, sourceStart: 0.5)
            v.linkID = link
            var a = v
            a.id = UUID()
            a.trackID = at
            a.kind = .audio
            let after = Clip(trackID: t, kind: .solid, start: 4, duration: 1)
            p.clips = [v, a, after]
            p.setRamp(ids: [v.id, a.id], speed: 4, points: (0, 0.25, 0.75, 1), start: 1, end: 1)
            let rv = p.clip(v.id)!, ra = p.clip(a.id)!
            let footage = abs(rv.sourceLength - 4) < 0.02
            // Pure 400% would be 1s, pure 100% 4s: a ramp at both ends lands in between.
            let shorter = rv.duration > 1.2 && rv.duration < 3
            let together = abs(ra.duration - rv.duration) < 1e-6 && p.clip(after.id)!.start >= rv.end - 1e-6
            var trips = true
            for x in stride(from: 0.0, through: 4, by: 0.37) {
                let s = rv.sourceStart + x
                let back = rv.sourceTime(at: rv.start + rv.timelineSpan(from: rv.sourceStart, to: s))
                if abs(back - s) > 1e-4 { trips = false }
            }
            let ends = abs(rv.speed(atSource: rv.sourceStart) - 1) < 1e-6 && abs(rv.speed(atSource: rv.sourceStart + 2) - 4) < 1e-6
            var q = p
            let mid = rv.start + rv.duration * 0.3
            _ = q.split(ids: [rv.id], at: mid)
            let halves = q.clips.filter { $0.trackID == t && $0.kind == .video }.sorted { $0.start < $1.start }
            let split = halves.count == 2 && abs(halves[0].sourceLength + halves[1].sourceLength - rv.sourceLength) < 1e-3
                && abs(halves[1].sourceStart - rv.sourceTime(at: mid)) < 1e-4
                && abs(halves[1].speed(atSource: halves[1].sourceStart) - rv.speed(atSource: halves[1].sourceStart)) < 1e-9
            let length = video.duration
            let m = rv.ramp!.mirrored(length: length)
            let mirrored = abs(m.speed(at: length - (rv.sourceStart + 0.3), mid: 4) - rv.speed(atSource: rv.sourceStart + 0.3)) < 1e-9
            var back = p
            back.setRamp(ids: [v.id, a.id], speed: 4, points: (0, 0, 1, 1), start: 1, end: 1)
            // A slow-motion moment in the middle: 100% to 30% of the way, easing to 25% by 40%, held to
            // 60%, back to 100% by 70%, then 100% to the end.
            var moment = p
            moment.setRamp(ids: [v.id, a.id], speed: 0.25, points: (0.3, 0.4, 0.6, 0.7), start: 1, end: 1)
            let mc = moment.clip(v.id)!
            let L = mc.sourceLength, s0 = mc.sourceStart
            let middle = abs(mc.speed(atSource: s0 + 0.1 * L) - 1) < 1e-6 && abs(mc.speed(atSource: s0 + 0.5 * L) - 0.25) < 1e-6
                && abs(mc.speed(atSource: s0 + 0.9 * L) - 1) < 1e-6 && abs(L - rv.sourceLength) < 0.02
                && abs(mc.duration - L * (0.6 + 0.2 / 0.25 + 0.2 * 2.2)) < 0.6
            let flat = back.clip(v.id)!.ramp == nil && abs(back.clip(v.id)!.duration - 1) < 0.04
            p.sanitize()
            let exported = await export(p, media, ExportSettings(), to: outDir.appendingPathComponent("ramp.mp4"))
            let file = AVURLAsset(url: outDir.appendingPathComponent("ramp.mp4"))
            let seconds = (try? await file.load(.duration).seconds) ?? 0
            let lasts = abs(seconds - p.duration) < 0.1
            let pass = footage && shorter && together && trips && ends && split && mirrored && flat && middle && exported && lasts
            if !pass {
                log("RAMP DEBUG v=\(rv.start)+\(rv.duration) a=\(ra.start)+\(ra.duration) after=\(p.clip(after.id)!.start) halves=\(halves.map { [$0.start, $0.duration, $0.sourceStart, $0.sourceLength] }) mid=\(mid) src(mid)=\(rv.sourceTime(at: mid))")
            }
            log("RAMP \(pass ? "OK" : "FAIL") footage=\(footage) length=\(String(format: "%.2f", rv.duration)) together=\(together) trips=\(trips) ends=\(ends) split=\(split) mirrored=\(mirrored) flat=\(flat) middle=\(middle) (\(String(format: "%.2f", mc.duration))s) export=\(exported) lasts=\(lasts) (\(String(format: "%.2f", seconds)) of \(String(format: "%.2f", p.duration)))")
            ok = ok && pass
        }
        // Zoom/scroll limits: whatever is asked for, the state must stay inside the bars and be stable.
        do {
            let m = EditorModel()
            m.load(project, url: nil)
            m.view.viewWidth = 1500
            m.view.viewHeight = 360
            m.clampView()
            var pass = true
            func check(_ label: String) {
                let v = m.view
                let extent = CGFloat(m.extent)
                let span = v.viewWidth / v.pps
                let before = (v.pps, v.scrollX, v.scrollY, v.rowHeight)
                m.clampView()
                let stable = before == (v.pps, v.scrollX, v.scrollY, v.rowHeight)
                let good = stable && span <= extent + 0.001 && v.scrollX >= 0 && v.scrollX / v.pps + span <= extent + 0.001
                    && v.scrollY >= m.minScrollY - 0.001 && v.scrollY <= m.maxScrollY + 0.001 && m.minScrollY <= m.maxScrollY + 0.001 && m.rowWindow > 0 && m.rowWindow <= 1
                    && TimelineViewState.rowRange.contains(v.rowHeight)
                if !good { log("VIEW FAIL \(label) pps=\(v.pps) x=\(v.scrollX) y=\(v.scrollY) row=\(v.rowHeight)") }
                pass = pass && good
            }
            check("initial")
            // Bar grips: the dragged edge tracks the mouse, the other mirrors it, and an edge at the end stays put.
            func grip(_ part: Int, _ a: CGFloat, _ b: CGFloat, _ move: CGFloat, _ wantA: CGFloat, _ wantB: CGFloat, _ label: String) {
                let e = gripDrag(part: part, start: a, end: b, move: move, bar: 400, minLength: 20, maxLength: 400)
                let good = abs(e.start - wantA) < 0.01 && abs(e.end - wantB) < 0.01
                if !good { log("GRIP FAIL \(label): \(e.start) \(e.end)") }
                pass = pass && good
            }
            grip(2, 100, 200, 30, 70, 230, "end grip, both free")
            grip(0, 100, 200, -30, 70, 230, "start grip, both free")
            grip(2, 0, 200, 30, 0, 230, "end grip, start at end of bar")
            grip(0, 150, 400, -30, 120, 400, "start grip, end at end of bar")
            grip(0, 0, 200, -30, 0, 200, "start grip already at end, pulled out")
            grip(2, 150, 400, 30, 150, 400, "end grip already at end, pulled out")
            grip(0, 0, 200, 30, 30, 170, "start grip at end, pushed in")
            grip(2, 100, 200, 500, 0, 400, "end grip past the bar")
            grip(2, 100, 200, -500, 140, 160, "end grip squeezed to minimum")
            // Playhead at the start edge: only the dragged end moves.
            let held = gripDrag(part: 2, start: 0, end: 200, move: -60, bar: 400, minLength: 20, maxLength: 400, mirror: 0)
            // Playhead a quarter of the way in: the far edge moves a third as much, so the playhead holds its place.
            let quarter = gripDrag(part: 2, start: 100, end: 200, move: -30, bar: 400, minLength: 20, maxLength: 400, mirror: 1.0 / 3)
            let anchored = held.start == 0 && abs(held.end - 140) < 0.01 && abs(quarter.start - 110) < 0.01 && abs(quarter.end - 170) < 0.01
                && abs((125 - quarter.start) / (quarter.end - quarter.start) - 0.25) < 0.001
            if !anchored { log("GRIP FAIL playhead anchor") }
            pass = pass && anchored
            m.setView(pps: 0.0001); check("zoom out past limit")
            let fullyOut = m.view.pps
            m.setView(pps: 0.0001); pass = pass && m.view.pps == fullyOut
            m.setView(pps: 1e9, scrollX: 1e9); check("zoom in past limit")
            m.setView(scrollX: -500, scrollY: -500); check("scroll before start")
            m.setView(scrollY: 1e9, rowHeight: 9999); check("tallest rows, scrolled to end")
            m.setView(rowHeight: 1); check("shortest rows")
            // At the smallest rows everything fits, the thumb fills the bar and the tracks sit centred.
            pass = pass && m.rowWindow == 1 && abs(m.view.scrollY - m.centeredScrollY) < 0.001
            // With more video than audio tracks, the centre is still the video/audio gap.
            m.addTrack(.video)
            m.addTrack(.video)
            m.addTrack(.video)
            // A centred thumb always means centred tracks, at any row height.
            for row in [30.0, 62.0, 110.0] {
                m.setView(rowHeight: row)
                m.setView(scrollY: (m.minScrollY + m.maxScrollY) / 2)
                let gapOnScreen = m.rowsAbove - m.view.scrollY
                let centred = abs(m.view.scrollY - m.centeredScrollY) < 0.001 && abs(gapOnScreen - m.rowsVisible / 2) < 0.001
                if !centred { log("VIEW FAIL centre at row \(row)") }
                pass = pass && centred
                check("centred at row \(row)")
            }
            m.seek(to: 2)
            for f in [0.5, 3.0, 0.2, 7.0, 0.01, 40.0] {
                let px = CGFloat(m.playhead) * m.view.pps - m.view.scrollX
                m.zoom(by: f)
                let after = CGFloat(m.playhead) * m.view.pps - m.view.scrollX
                // The playhead holds its place unless a scroll limit is in the way.
                let pinned = abs(px - after) < 0.5 || m.view.scrollX == 0 || abs(m.view.scrollX - m.maxScrollX) < 0.5 || px < 0 || px > m.view.viewWidth
                if !pinned { log("VIEW FAIL playhead moved \(px) -> \(after)") }
                pass = pass && pinned
                check("zoom x\(f)")
            }
            log("VIEW LIMITS \(pass ? "OK" : "FAIL")")
            ok = ok && pass
        }
        // Missing media: a project folder moved as a whole finds its files by relative path, and
        // relinking one file finds the others beside it.
        // It needs two particular files in the media folder; without them it's skipped, not crashed.
        let relinkFiles = ["a_main.mp4", "b_tone.wav"]
        if !relinkFiles.allSatisfy({ FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent($0).path) }) {
            log("RELINK SKIP needs \(relinkFiles.joined(separator: " and ")) in the media folder")
        } else {
            let fm = FileManager.default
            let work = outDir.appendingPathComponent("relink")
            try? fm.removeItem(at: work)
            let first = work.appendingPathComponent("first"), footage = first.appendingPathComponent("footage")
            try? fm.createDirectory(at: footage, withIntermediateDirectories: true)
            var p = Project()
            for name in ["a_main.mp4", "b_tone.wav"] {
                let copy = footage.appendingPathComponent(name)
                try? fm.copyItem(at: mediaDir.appendingPathComponent(name), to: copy)
                if let a = await media.importFile(copy) { p.assets.append(a) }
            }
            if p.assets.count != relinkFiles.count {
                log("RELINK FAIL imported \(p.assets.count) of \(relinkFiles.count) files")
                ok = false
            } else {
            p.stampRelativePaths(projectDir: first)
            let second = work.appendingPathComponent("second")
            try? fm.moveItem(at: first, to: second)
            var moved = p
            let found = moved.resolveMovedMedia(projectDir: second)
            let relative = p.assets.count == 2 && found == 2 && moved.assets.allSatisfy { fm.fileExists(atPath: $0.path) }
                && p.assets[0].relativePath == "footage/a_main.mp4"

            // Now scatter the files somewhere the relative paths don't reach, and relink just one.
            let elsewhere = work.appendingPathComponent("elsewhere")
            try? fm.moveItem(at: second.appendingPathComponent("footage"), to: elsewhere)
            let m = EditorModel()
            m.load(p, url: nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let missingBefore = m.missingAssets.count
            let linked = await m.relink(p.assets[0].id, to: elsewhere.appendingPathComponent("a_main.mp4"))
            let wrongKind = await m.relink(p.assets[0].id, to: elsewhere.appendingPathComponent("b_tone.wav"))
            let swept = linked && !wrongKind && missingBefore == 2 && m.missingAssets.isEmpty
                && m.project.assets.map(\.id) == p.assets.map(\.id)
                && m.project.assets.allSatisfy { !m.media.isOffline($0) }
            log("RELINK \(relative && swept ? "OK" : "FAIL") relative=\(relative) swept=\(swept) missingBefore=\(missingBefore)")
            ok = ok && relative && swept
            }
        }
        // Reload: a file saved over with a shorter one is noticed, opened again, and its clip cut to fit
        // (one undo step); its identity stays.
        do {
            let fm = FileManager.default
            let vids = ((try? fm.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "mp4" }
            var probed: [(URL, Double)] = []
            for v in vids { if let a = await media.importFile(v) { probed.append((v, a.duration)) } }
            probed.sort { $0.1 > $1.1 }
            if probed.count < 2 || probed[0].1 - probed.last!.1 < 0.5 {
                log("RELOAD SKIP needs two videos of different lengths in the media folder")
            } else {
                let work = outDir.appendingPathComponent("reload")
                try? fm.removeItem(at: work)
                try? fm.createDirectory(at: work, withIntermediateDirectories: true)
                let file = work.appendingPathComponent("r.mp4")
                try? fm.copyItem(at: probed[0].0, to: file)
                let m = EditorModel()
                var p = Project()
                if let a = await m.media.importFile(file) {
                    p.assets = [a]
                    p.clips = [Clip(trackID: p.videoTracks[0].id, kind: .video, assetID: a.id, start: 0, duration: a.duration)]
                }
                m.load(p, url: nil)
                try? await Task.sleep(nanoseconds: 300_000_000)
                let unchanged = m.media.changedOnDisk(m.project.assets).isEmpty
                try? await Task.sleep(nanoseconds: 1_100_000_000)   // a later modification date
                try? fm.removeItem(at: file)
                try? fm.copyItem(at: probed.last!.0, to: file)
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                let noticed = !m.media.changedOnDisk(m.project.assets).isEmpty
                await m.reloadMedia(Set(m.project.assets.map(\.id)))
                let short = probed.last!.1
                let asset = m.project.assets.first
                let fitted = asset.map { abs($0.duration - short) < 0.05 } == true
                    && m.project.clips.first.map { abs($0.end - short) < 0.05 } == true
                    && asset?.id == p.assets.first?.id
                    && m.media.changedOnDisk(m.project.assets).isEmpty
                    && asset.map { !m.media.isOffline($0) } == true
                m.undo()
                let undone = m.project.clips.first.map { abs($0.end - probed[0].1) < 0.05 } == true
                log("RELOAD \(unchanged && noticed && fitted && undone ? "OK" : "FAIL") unchanged=\(unchanged) noticed=\(noticed) fitted=\(fitted) undone=\(undone)")
                ok = ok && unchanged && noticed && fitted && undone
            }
        }
        // Sticky edges: three butted clips; shortening the first pulls the other two back, and a
        // linked partner follows its clip.
        do {
            var p = Project()
            let v = p.videoTracks[0].id, a = p.audioTracks[0].id
            let link = UUID()
            let c1 = Clip(trackID: v, kind: .solid, start: 0, duration: 4)
            let c2 = Clip(trackID: v, kind: .solid, start: 4, duration: 2, linkID: link)
            let c3 = Clip(trackID: v, kind: .solid, start: 6, duration: 1)
            let c2a = Clip(trackID: a, kind: .solid, start: 4, duration: 2, linkID: link)
            let far = Clip(trackID: v, kind: .solid, start: 9, duration: 1)
            p.clips = [c1, c2, c3, c2a, far]
            var short = c1
            short.trimTail(to: 3)
            let carried = p.carried(by: [c1.id: short])
            let pulled = carried[c2.id]?.start == 3 && carried[c3.id]?.start == 5 && carried[c2a.id]?.start == 3 && carried[far.id] == nil
            // Growing it by 3 pushes the chain into the far clip, which joins in.
            var long = c1
            long.trimTail(to: 7)
            let pushed = p.carried(by: [c1.id: long])
            let grew = pushed[c3.id]?.start == 9 && pushed[far.id]?.start == 10 && p.fits(pushed.merging([c1.id: long]) { a, _ in a })
            // Doubling the speed of a 4s video clip halves it, and the touching clip follows it back.
            var q = Project()
            let qv = q.videoTracks[0].id
            let fastClip = Clip(trackID: qv, kind: .video, start: 0, duration: 4)
            let next = Clip(trackID: qv, kind: .solid, start: 4, duration: 2)
            q.clips = [fastClip, next]
            var plain = q
            plain.setSpeed(ids: [fastClip.id], speed: 2)
            q.setSpeed(ids: [fastClip.id], speed: 2, sticky: true)
            let sped = q.clip(fastClip.id)?.duration == 2 && q.clip(next.id)?.start == 2 && plain.clip(next.id)?.start == 4
            log("STICKY \(pulled && grew && sped ? "OK" : "FAIL") pulled=\(pulled) grew=\(grew) speed=\(sped)")
            ok = ok && pulled && grew && sped
        }
        // Tracks: old files without solo/lock still open; solo silences the others; locked clips are left out.
        do {
            let old = #"{"id":"6F1D8C64-1B2E-4C38-9A6E-0B9C1F6A1B2C","kind":"audio","hidden":false,"muted":false,"gainDB":0}"#
            let decoded = (try? JSONDecoder().decode(Track.self, from: Data(old.utf8))).map { !$0.solo && !$0.locked } ?? false
            var p = Project()
            p.audioTracks[1].solo = true
            let solo = !p.isAudible(p.audioTracks[0]) && p.isAudible(p.audioTracks[1])
            p.videoTracks[0].locked = true
            let a = Clip(trackID: p.videoTracks[0].id, kind: .solid, start: 0, duration: 1)
            let b = Clip(trackID: p.videoTracks[1].id, kind: .solid, start: 0, duration: 1)
            p.clips = [a, b]
            let lock = p.unlocked([a.id, b.id]) == [b.id]
            log("TRACKS \(decoded && solo && lock ? "OK" : "FAIL") decode=\(decoded) solo=\(solo) lock=\(lock)")
            ok = ok && decoded && solo && lock
        }
        // Magic history: kept in the project file, newest first and each once, and undo leaves it alone.
        do {
            let m = EditorModel()
            m.addMagicPrompt("make a quick cut", tab: .local)
            m.mutate { $0.width = 1280 }
            m.addMagicPrompt("slow-mo moment", tab: .chatgpt)
            m.addMagicPrompt(" make a quick cut ", tab: .claude)
            m.undo()
            let order = m.magicHistory.map(\.text) == ["make a quick cut", "slow-mo moment"] && m.magicHistory[0].tab == "claude"
            let saved = (try? JSONEncoder().encode(m.project)).flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
            let file = saved?.magicHistory?.map(\.text) == m.magicHistory.map(\.text)
            let old = (try? JSONEncoder().encode(Project())).flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
            let opensOld = old != nil && old?.magicHistory == nil && EditorModel().magicHistory.isEmpty
            for i in 0..<25 { m.addMagicPrompt("prompt \(i)", tab: .local) }
            let capped = m.magicHistory.count == MagicHistory.limit && m.magicHistory[0].text == "prompt 24"
            let good = order && file && opensOld && capped
            log("HISTORY \(good ? "OK" : "FAIL") order=\(order) file=\(file) opensOld=\(opensOld) capped=\(capped)")
            ok = ok && good
        }
        // An AI's edit, played as its result: an AI adds clips one after another, each at full length then
        // trimmed (so played in order every step waits for the last). As a result the new clips all fly in
        // at once, and the show still ends exactly where the AI's edits do.
        do {
            var p = Project()
            let v1 = p.videoTracks[0].id, a2 = p.audioTracks[1].id
            let old = Clip(trackID: v1, kind: .solid, start: 0, duration: 3)
            let music = Clip(trackID: a2, kind: .audio, start: 0, duration: 20)
            p.clips = [old, music]
            var edits: [MagicEdit] = [.remove([old.id])]
            var t = 0.0
            for _ in 0..<6 {
                let c = Clip(trackID: v1, kind: .solid, start: t, duration: 5)
                edits.append(.place([c], asset: nil))
                edits.append(.trimTail([c.id], from: t + 5, to: t + 1))
                edits.append(.fadeIn(c.id, to: 0.2))
                t += 1
            }
            edits.append(.gain(music.id, from: 0, to: -6))
            var final = p
            for e in edits { e.apply(&final, 1) }
            let stepPlan = MCPDraft.plan(base: p, edits: edits)
            let resultPlan = MCPDraft.resultPlan(base: p, edits: edits)
            var played = resultPlan.base
            for task in resultPlan.tasks { task.edit.apply(&played, 1) }
            let same = Dictionary(played.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                == Dictionary(final.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // The longest line of edits each waiting for the one before: short means many cursors at once.
            func depth(_ plan: MagicPlan) -> Int {
                var d: [Int] = []
                for t in plan.tasks { d.append(1 + (t.after.map { d[$0] }.max() ?? 0)) }
                return d.max() ?? 0
            }
            let wider = depth(resultPlan) <= 4 && depth(resultPlan) < depth(stepPlan)
            let good = same && wider
            log("AI RESULT SHOW \(good ? "OK" : "FAIL") same=\(same) depth=\(depth(resultPlan)) (was \(depth(stepPlan))) tasks=\(resultPlan.tasks.count)")
            ok = ok && good
        }
        // Media search in everyday words: "ride" finds a rollercoaster, "party" a celebration, "city" a cityscape;
        // a word nothing means finds nothing.
        do {
            func tags(_ names: String...) -> SceneTags { SceneTags(tags: names.map { SceneTags.Tag(name: $0, confidence: 0.9, times: [1]) }) }
            let ride = tags("rollercoaster").shows("ride") && tags("amusement park").shows("rides") && tags("carousel").shows("ride")
            let party = tags("celebration").shows("party") && tags("cityscape").shows("city") && tags("surfing").shows("waves")
            let still = tags("dog").shows("puppy") && !tags("dog").shows("ride") && !tags("rollercoaster").shows("laughing")
            let vehicle = tags("car").shows("vehicle") && tags("boat").shows("vehicles") && tags("airplane").shows("vehicle") && tags("bus").shows("vehicle")
            // Apple Intelligence's words, in other forms: "laughing" finds laughter, "smiling" a smile.
            let feelings = tags("laughter").shows("laughing") && tags("smile").shows("smiling") && tags("smiles").shows("happy")
                && tags("helicopter").shows("vehicle") && !tags("parking").shows("park")
            var withWords = tags("people")
            withWords.add([(1.5, ["car", "laughing"]), (3, ["car"])])
            let added = withWords.tags.first { $0.name == "car" }?.times == [1.5, 3] && withWords.shows("vehicle") && withWords.shows("laughter")
            let good = ride && party && still && vehicle && feelings && added && SceneTags.aliases.count > 100
            log("SEARCH WORDS \(good ? "OK" : "FAIL") ride=\(ride) vehicle=\(vehicle) feelings=\(feelings) described=\(added) everyday=\(party) unchanged=\(still) labels=\(SceneTags.aliases.count)")
            ok = ok && good
        }
        // @ markers: by name or @marker:, unnamed ones by colour, read as their times (a span, a title's place),
        // and a file of the same name wins over a marker.
        do {
            var p = Project()
            p.clips = [Clip(trackID: p.videoTracks[0].id, kind: .video, start: 0, duration: 30)]
            p.markers = [Marker(time: 12.4, name: "Jump"), Marker(time: 20, name: "", tint: .green), Marker(time: 25, name: "Big drop")]
            let marks = MagicMention.markerLabels(p)
            let labels = marks.map(\.name) == ["Jump", "Green marker", "Big drop"]
            func isMarker(_ text: String) -> Bool {
                MagicMention.find(in: text, media: p.assets, markers: marks).contains { if case .marker = $0.mention { return true } else { return false } }
            }
            let found = isMarker("title at @Jump") && isMarker("at @marker:Green marker") && isMarker("from @big drop on") && !isMarker("email me@Jump")
            let timed = MagicMention.markersAsTimes("slow-mo from @Jump to @marker:Green marker", project: p)
            let span = MagicTimes.span(in: timed, fps: p.fps)
            let spanOK = timed == "slow-mo from 0:12.4 to 0:20" && span.map { abs($0.start - 12.4) < 0.01 && abs($0.end - 20) < 0.01 } ?? false
            let titleReq = MagicMention.markersAsTimes("add a title at @Big drop", project: p)
            var titleAt = -1.0
            if let plan = LocalTitle.plan(request: titleReq, playhead: 0, project: p).plan {
                var q = plan.base
                for t in plan.tasks { t.edit.apply(&q, 1) }
                titleAt = q.clips.first { $0.kind == .text }?.start ?? -1
            }
            let titleOK = abs(titleAt - 25) < 0.05
            var withFile = p
            withFile.assets = [MediaAsset(path: "/tmp/Jump.mov", name: "Jump.mov", kind: .video, duration: 5, width: 1920, height: 1080, fps: 30, hasAudio: false)]
            let fileWins = MagicMention.find(in: "use @Jump", media: withFile.assets, markers: marks).first.map { if case .media = $0.mention { return true } else { return false } } ?? false
            let good = labels && found && spanOK && titleOK && fileWins
            log("MARKER MENTIONS \(good ? "OK" : "FAIL") labels=\(labels) found=\(found) span=\(spanOK) (\(timed)) title=\(titleOK) at \(titleAt) fileWins=\(fileWins)")
            ok = ok && good
        }
        // Local titles on an edit: at the end (default words), and their own words at the start.
        do {
            var p = Project()
            p.clips = [Clip(trackID: p.videoTracks[0].id, kind: .video, start: 0, duration: 10)]
            func titled(_ request: String) -> Clip? {
                guard LocalTitle.asks(request, project: p), let plan = LocalTitle.plan(request: request, playhead: 0, project: p).plan else { return nil }
                var q = plan.base
                for t in plan.tasks { t.edit.apply(&q, 1) }
                return q.clips.first { $0.kind == .text }
            }
            let end = titled("add vlog title screen at the end")
            let endOK = end.map { abs($0.end - 10) < 0.05 && $0.text.string == "Title" && $0.trackID == p.videoTracks[1].id } ?? false
            let start = titled("put a title saying \"Day one\" at the start")
            let startOK = start.map { $0.start == 0 && $0.text.string == "Day one" } ?? false
            let newCut = !LocalTitle.asks("make a new montage with a title", project: p)
            // Quotes read as pairs: an apostrophe inside stays in the title.
            let quotes = LocalBrain.titleAsked("add a title at the end that says \"Mom doesn't know what ai is\"") == "Mom doesn't know what ai is"
                && LocalBrain.titleAsked("title “It’s day one” at the start") == "It’s day one"
                && LocalBrain.titleAsked("add a title saying 'Mom doesn't know' at the end") == "Mom doesn't know"
                && LocalBrain.titleAsked("add a title at the end") == ""
            let good = endOK && startOK && newCut && quotes
            log("LOCAL TITLE \(good ? "OK" : "FAIL") end=\(endOK) start=\(startOK) newCut=\(newCut) quotes=\(quotes)")
            ok = ok && good
        }
        // Local captions: "add captions" captions everyone talking (not a title); quoted words are still a title.
        do {
            var p = Project()
            let file = MediaAsset(path: "/tmp/Talk.mov", name: "Talk.mov", kind: .video, duration: 5, width: 1920, height: 1080, fps: 30, hasAudio: true)
            p.assets = [file]
            let link = UUID()
            var v = Clip(trackID: p.videoTracks[0].id, kind: .video, assetID: file.id, start: 0, duration: 5)
            v.linkID = link
            var a = Clip(trackID: p.audioTracks[0].id, kind: .audio, assetID: file.id, start: 0, duration: 5)
            a.linkID = link
            p.clips = [v, a]
            let pointers = MagicPointers(playhead: 0, selected: [], range: nil)
            let reads = LocalCaptions.asks("add captions", project: p) && LocalCaptions.asks("can you put subtitles on this", project: p)
                && !LocalCaptions.asks("add a caption saying 'Day one'", project: p) && !LocalCaptions.asks("make a new montage with captions", project: p)
                && LocalCaptions.asks("add captions to Robbie's clip", project: p)
            let notTitle = LocalBrain.titleAsked("add captions") == nil && LocalBrain.titleAsked("add a caption saying 'Day one'") == "Day one"
            func applied(_ request: String, to base: Project) -> Project? {
                guard let plan = LocalCaptions.plan(request: request, pointers: pointers, project: base, transcript: { _ in nil }).plan else { return nil }
                var q = plan.base
                for t in plan.tasks { t.edit.apply(&q, 1) }
                return q
            }
            let added = applied("add captions", to: p)
            let addOK = added.map { $0.captions != nil && $0.captionedClips.map(\.id) == [a.id] } ?? false
            let removed = added.flatMap { applied("remove the captions", to: $0) }
            let removeOK = removed.map { $0.captions == nil } ?? false
            let good = reads && notTitle && addOK && removeOK
            log("LOCAL CAPTIONS \(good ? "OK" : "FAIL") reads=\(reads) notTitle=\(notTitle) add=\(addOK) remove=\(removeOK)")
            ok = ok && good
        }
        // Magic's captions join the cut's undo step: one Undo takes both back.
        do {
            var p = Project()
            p.assets = project.assets
            let m = EditorModel()
            m.load(p, url: nil)
            let before = m.project
            let a = Clip(trackID: m.project.audioTracks[0].id, kind: .audio, assetID: video.id, start: 0, duration: 2)
            m.mutate { $0.clips.append(a) }
            m.amendLastStep { $0.addCaptions([a.id]) }
            let both = m.project.clips.count == 1 && m.project.captions != nil
            m.undo()
            let back = m.project.clips.isEmpty && m.project.captions == nil && m.project == before
            m.redo()
            let again = m.project.clips.count == 1 && m.project.captions != nil
            let good = both && back && again
            log("CAPTION UNDO \(good ? "OK" : "FAIL") both=\(both) oneUndo=\(back) redo=\(again)")
            ok = ok && good
        }
        // Local adds clips where asked: the end, the beginning, after the selected clip, before the second clip,
        // or at a time inside a clip (cut in two there); what comes after moves along.
        do {
            var p = Project()
            let mk = { (n: String) in MediaAsset(path: "/tmp/\(n).mov", name: "\(n).mov", kind: .video, duration: 8, width: 1920, height: 1080, fps: 30, hasAudio: true) }
            let a = mk("A"), b = mk("B"), c = mk("C"), d = mk("D")
            p.assets = [a, b, c, d]
            let la = UUID(), ld = UUID()
            var va = Clip(trackID: p.videoTracks[0].id, kind: .video, assetID: a.id, start: 0, duration: 3); va.linkID = la
            var aa = Clip(trackID: p.audioTracks[0].id, kind: .audio, assetID: a.id, start: 0, duration: 3); aa.linkID = la
            var vd = Clip(trackID: p.videoTracks[0].id, kind: .video, assetID: d.id, start: 3, duration: 3); vd.linkID = ld
            var ad = Clip(trackID: p.audioTracks[0].id, kind: .audio, assetID: d.id, start: 3, duration: 3); ad.linkID = ld
            p.clips = [va, aa, vd, ad]
            let reads = LocalAdd.asks("add one more clip to end of video", project: p) && LocalAdd.asks("put two more shots at the start", project: p)
                && LocalAdd.asks("add one more clip after @selected", project: p)
                && !LocalAdd.asks("add a title at the end", project: p) && !LocalAdd.asks("add captions", project: p)
                && !LocalAdd.asks("make a new video with 5 clips", project: p)
            let counts = LocalAdd.count("add one more clip") == 1 && LocalAdd.count("add two more shots") == 2
                && LocalAdd.count("add 3 clips at the end") == 3 && LocalAdd.count("add another clip") == 1
            /// The picture's files in order with their starts, after the request.
            func order(_ request: String, selected: [UUID] = []) -> String {
                let ptr = MagicPointers(playhead: 0, selected: selected, range: nil)
                guard let plan = LocalAdd.plan(request: request, typed: request, pointers: ptr, project: p).plan else { return "-" }
                var q = plan.base
                for t in plan.tasks { t.edit.apply(&q, 1) }
                // Every sound still under its picture.
                let synced = q.clips.filter { $0.kind == .video }.allSatisfy { v in
                    q.clips.contains { $0.kind == .audio && $0.linkID == v.linkID && abs($0.start - v.start) < 1e-6 && abs($0.end - v.end) < 1e-6 }
                }
                let vs = q.clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }
                return vs.map { "\(q.asset($0.assetID)?.name.prefix(1) ?? "?")\(String(format: "%g", $0.start))" }.joined(separator: " ") + (synced ? "" : " unsynced")
            }
            let results = [order("add one more clip to end of video"), order("add one more clip to beginning of video"),
                           order("add one more clip after @selected", selected: [va.id, aa.id]), order("add a clip before the second clip"),
                           order("add a clip at 0:01.5")]
            let expected = ["A0 D3 B6", "B0 A3 D6", "A0 B3 D6", "A0 B3 D6", "A0 B1.5 A4.5 D6"]
            let placed = results == expected
            let good = reads && counts && placed
            log("LOCAL ADD \(good ? "OK" : "FAIL") reads=\(reads) counts=\(counts) placed=\(placed) \(results)")
            ok = ok && good
        }
        // Several asks in one request: the clip added, then the title at the new end, then captions, as one plan.
        do {
            var p = Project()
            let mk = { (n: String) in MediaAsset(path: "/tmp/\(n).mov", name: "\(n).mov", kind: .video, duration: 8, width: 1920, height: 1080, fps: 30, hasAudio: true) }
            let a = mk("A"), b = mk("Heli")
            p.assets = [a, b]
            let l = UUID()
            var v = Clip(trackID: p.videoTracks[0].id, kind: .video, assetID: a.id, start: 0, duration: 3); v.linkID = l
            var au = Clip(trackID: p.audioTracks[0].id, kind: .audio, assetID: a.id, start: 0, duration: 3); au.linkID = l
            p.clips = [v, au]
            let request = "add @Heli clip to end and add captions and a title at the end"
            let parts = LocalCombined.parts(request, project: p)
            let m = EditorModel()
            m.load(p, url: nil)
            let outcome = await LocalCombined.plan(parts, request: request, typed: request,
                                                   pointers: MagicPointers(playhead: 0, selected: [], range: nil), model: m) {}
            var q = p
            for t in outcome.plan?.tasks ?? [] { t.edit.apply(&q, 1) }
            let heli = q.clips.first { $0.kind == .video && $0.assetID == b.id }
            let title = q.clips.first { $0.kind == .text }
            let added = heli.map { abs($0.start - 3) < 0.01 } ?? false
            let titled = title.map { t in abs(t.end - (heli?.end ?? -1)) < 0.05 && t.text.string == "Title" } ?? false
            let captioned = q.captions != nil && q.captionedClips.count == 2
            let good = parts.count == 3 && added && titled && captioned
            log("LOCAL COMBINED \(good ? "OK" : "FAIL") parts=\(parts.count) added=\(added) title=\(titled) captions=\(captioned)")
            ok = ok && good
        }
        // A project's files aren't drawn as missing while they load; a file that's really gone is, once looked for.
        do {
            var p = Project()
            let gone = MediaAsset(path: "/tmp/editroom-no-such-file.mov", name: "Gone.mov", kind: .video, duration: 5, width: 1920, height: 1080, fps: 30, hasAudio: true)
            p.assets = [gone]
            p.clips = [Clip(trackID: p.videoTracks[0].id, kind: .video, assetID: gone.id, start: 0, duration: 2)]
            let m = EditorModel()
            m.load(p, url: nil)
            let whileOpening = !m.media.looksOffline(gone)
            for _ in 0..<40 where m.media.opening.contains(gone.id) { try? await Task.sleep(nanoseconds: 50_000_000) }
            let thenMissing = m.media.looksOffline(gone)
            let good = whileOpening && thenMissing
            log("OPENING \(good ? "OK" : "FAIL") notRedWhileOpening=\(whileOpening) redWhenMissing=\(thenMissing)")
            ok = ok && good
        }
        // Ripple Trim (Q/W): the clip under the playhead loses its head or tail, the gap closes on every track,
        // and with a clip selected only its tracks move.
        do {
            func setup() -> (EditorModel, UUID, UUID, UUID) {
                var p = Project()
                let v1 = p.videoTracks[0].id, a1 = p.audioTracks[0].id
                let a2 = Track(kind: .audio)
                p.audioTracks.append(a2)
                let link = UUID()
                var x = Clip(trackID: v1, kind: .video, assetID: nil, start: 0, duration: 4); x.linkID = link
                var xa = Clip(trackID: a1, kind: .audio, assetID: nil, start: 0, duration: 4); xa.linkID = link
                let y = Clip(trackID: v1, kind: .video, assetID: nil, start: 4, duration: 4)
                let music = Clip(trackID: a2.id, kind: .audio, assetID: nil, start: 0, duration: 8)
                p.clips = [x, xa, y, music]
                let m = EditorModel()
                m.load(p, url: nil)
                return (m, x.id, y.id, music.id)
            }
            func spans(_ m: EditorModel) -> String {
                m.project.clips.sorted { ($0.trackID.uuidString, $0.start) < ($1.trackID.uuidString, $1.start) }
                    .map { String(format: "%.1f-%.1f", $0.start, $0.end) }.sorted().joined(separator: " ")
            }
            func qShapeOK(_ m: EditorModel) -> Bool { spans(m) == "0.0-3.0 0.0-3.0 0.0-7.0 3.0-7.0" }
            // Q at 1s, nothing selected: X and its audio lose 0–1, Y and the music slide back with them.
            var (m, _, yID, musicID) = setup()
            m.seek(to: 1); m.rippleTrim(head: true)
            let q = m.project.clip(yID)?.start == 3 && qShapeOK(m) && abs(m.playhead) < 1e-6
            let qShape = spans(m)
            // W at 6s: Y loses 6–8; the music's tail goes too.
            (m, _, yID, musicID) = setup()
            m.seek(to: 6); m.rippleTrim(head: false)
            let w = m.project.clip(yID)?.end == 6 && m.project.duration == 6
            // W at 1s with X selected: X and its audio lose 1–4, Y slides to 1; the music isn't touched.
            var xID: UUID
            (m, xID, yID, musicID) = setup()
            m.selection = [xID]
            m.seek(to: 1); m.rippleTrim(head: false)
            let sel = m.project.clip(yID)?.start == 1 && m.project.clip(musicID)?.end == 8 && m.project.clips.count == 4
            m.undo()
            let undone = m.project.clip(yID)?.start == 4
            let good = q && w && sel && undone
            log("RIPPLE TRIM \(good ? "OK" : "FAIL") q=\(q) [\(qShape)] w=\(w) selected=\(sel) undo=\(undone)")
            ok = ok && good
        }
        // Zoom for agents: set_transform's zoom (in at 1s over 1.5s, framing the right side), reported by get_project,
        // an out that ends with the clip, and off keeping the scale.
        do {
            var p = Project()
            let clip = Clip(trackID: p.videoTracks[0].id, kind: .solid, start: 0, duration: 6)
            p.clips = [clip]
            let m = EditorModel()
            m.load(p, url: nil)
            func call(_ args: [String: Any]) async -> String? {
                do { _ = try await MCPTools.call("set_transform", args, model: m, client: nil, draft: nil); return nil }
                catch { return (error as? MCPToolError)?.message ?? "\(error)" }
            }
            let id = clip.id.uuidString
            let e1 = await call(["clip_id": id, "zoom": "in", "zoom_start": 1.0, "zoom_seconds": 1.5, "focus_x": 0.75])
            let z = m.project.clip(clip.id)?.transform
            let inOK = e1 == nil && z?.scale == 2 && z?.zoom?.mode == .zoomIn && z?.zoom?.p1 == 1 && z?.zoom?.p2 == 2.5
                && abs((z?.x ?? 0) + 0.5) < 1e-9 && z?.at(0) == nil && z?.at(3)?.scale == 2
            let out = try? await MCPTools.call("get_project", [:], model: m, client: nil, draft: nil)
            let shown = (out?.first?["text"] as? String)?.contains("\"zoom\"") == true
            let e2 = await call(["clip_id": id, "zoom": "out", "zoom_seconds": 2.0, "zoom_smooth": false])
            let o = m.project.clip(clip.id)?.transform?.zoom
            let outOK = e2 == nil && o?.mode == .zoomOut && o?.p3 == 4 && o?.p4 == 6 && o?.smooth == false
            let e3 = await call(["clip_id": id, "zoom": "off"])
            let offOK = e3 == nil && m.project.clip(clip.id)?.transform?.zoom == nil && m.project.clip(clip.id)?.transform?.scale == 2
            let bad = await call(["clip_id": id, "zoom": "sideways"]) != nil
            let good = inOK && shown && outOK && offOK && bad
            log("ZOOM TOOL \(good ? "OK" : "FAIL") in=\(inOK) shown=\(shown) out=\(outOK) off=\(offOK) refusesBad=\(bad) \(e1 ?? "")")
            ok = ok && good
        }
        // Local's zooms: "@selected add zoom animation" zooms the selected shot (and adds no clip); "zoom in and out"
        // at the playhead; "2x" sets how far; "remove the zoom" takes it off and keeps the scale.
        do {
            var p = Project()
            let a = Clip(trackID: p.videoTracks[0].id, kind: .solid, start: 0, duration: 4)
            let b = Clip(trackID: p.videoTracks[0].id, kind: .solid, start: 4, duration: 4)
            p.clips = [a, b]
            func run(_ text: String, _ ptr: MagicPointers, _ on: Project) -> Project {
                var q = on
                for task in LocalZoom.plan(request: text, pointers: ptr, project: on).plan?.tasks ?? [] { task.edit.apply(&q, 1) }
                return q
            }
            let asked = LocalZoom.asks("@selected add zoom animation") && !LocalZoom.asks("add a clip at the end")
            let selected = run("@selected add zoom animation", MagicPointers(playhead: 6, selected: [a.id], range: nil), p)
            let selOK = selected.clips.count == 2 && selected.clip(a.id)?.transform?.zoom?.mode == .zoomIn
                && selected.clip(a.id)?.transform?.scale == 2 && selected.clip(b.id)?.transform == nil
            let inOut = run("zoom in and out 1.5x", MagicPointers(playhead: 6, selected: [], range: nil), p)
            let inOutOK = inOut.clip(b.id)?.transform?.zoom?.mode == .inOut && inOut.clip(b.id)?.transform?.scale == 1.5
                && inOut.clip(a.id)?.transform == nil
            let off = run("remove the zoom", MagicPointers(playhead: 1, selected: [a.id], range: nil), selected)
            let offOK = off.clip(a.id)?.transform?.zoom == nil && off.clip(a.id)?.transform?.scale == 2
            let good = asked && selOK && inOutOK && offOK
            log("LOCAL ZOOM \(good ? "OK" : "FAIL") asks=\(asked) selected=\(selOK) inOutAtPlayhead=\(inOutOK) off=\(offOK)")
            ok = ok && good
        }
        // Shown after importing by hand: files picked and scrolled to; a folder's tile picked and scrolled to; an agent's
        // import leaves the panel alone.
        do {
            let fm = FileManager.default
            let dir = outDir.appendingPathComponent("reveal-test/Clips")
            try? fm.removeItem(at: dir.deletingLastPathComponent())
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.copyItem(at: mediaDir.appendingPathComponent("c_clip.mp4"), to: dir.appendingPathComponent("one.mp4"))
            var p = Project()
            p.settingsLocked = true   // no "match the sequence?" question
            let m = EditorModel()
            m.load(p, url: nil)
            try? await Task.sleep(nanoseconds: 200_000_000)
            let files = [mediaDir.appendingPathComponent("a_clip.mp4"), mediaDir.appendingPathComponent("d_clip.mp4")]
            let got: [MediaAsset] = await withCheckedContinuation { c in m.importFiles(files, offerMatch: true) { c.resume(returning: $0) } }
            let filesOK = got.count == 2 && m.mediaSelection == Set(got.map(\.id)) && m.mediaReveal?.target == .asset(got[0].id)
            let folderPath = dir.standardizedFileURL.path
            _ = await withCheckedContinuation { c in m.importFiles([dir], offerMatch: true) { c.resume(returning: $0) } } as [MediaAsset]
            let folderOK = m.folderSelection == [folderPath] && m.mediaReveal?.target == .folder(folderPath) && m.mediaFolder == nil
            let before = (m.mediaSelection, m.folderSelection, m.mediaReveal)
            _ = await withCheckedContinuation { c in m.importFiles([mediaDir.appendingPathComponent("e_clip.mp4")], offerMatch: false) { c.resume(returning: $0) } } as [MediaAsset]
            let agentOK = m.mediaSelection == before.0 && m.folderSelection == before.1 && m.mediaReveal == before.2
            // Reveal in Media: a timeline clip's file is picked and scrolled to; the timeline keeps its selection.
            var revealOK = false
            if let first = got.first {
                let clip = Clip(trackID: m.project.videoTracks[0].id, kind: .video, assetID: first.id, start: 0, duration: 1)
                m.mutate { $0.clips.append(clip) }
                m.selection = [clip.id]
                m.mediaSelection = []
                m.revealInMedia()
                revealOK = m.mediaSelection == [first.id] && m.mediaReveal?.target == .asset(first.id) && m.selection == [clip.id]
            }
            // ⌘A on the timeline: Media lets go of its picks, so Delete is for the clips.
            m.mediaSelection = Set(got.map(\.id))
            m.selectAll()
            let selectAllOK = m.mediaSelection.isEmpty && !m.selection.isEmpty
            let good = filesOK && folderOK && agentOK && revealOK && selectAllOK
            log("IMPORT SHOWN \(good ? "OK" : "FAIL") files=\(filesOK) folder=\(folderOK) agentLeavesIt=\(agentOK) revealInMedia=\(revealOK) selectAll=\(selectAllOK)")
            ok = ok && good
            try? fm.removeItem(at: dir.deletingLastPathComponent())
        }
        // Upscaler (export): the same way up and the same colours as a plain resize, a sharper edge, and how long 1080p to
        // 4K takes on this Mac.
        do {
            let up = Upscaler.shared
            if !up.available {
                log("UPSCALE SKIP MetalFX's upscaler isn't available on this Mac")
            } else {
                let ctx = TimelineCompositor.context
                func rect(_ c: CIColor, _ r: CGRect) -> CIImage { CIImage(color: c).cropped(to: r) }
                // 320 × 180: dark left, light right (an edge to measure), a red band along the top, blue along the bottom.
                var img = rect(CIColor(red: 0.2, green: 0.2, blue: 0.2), CGRect(x: 0, y: 0, width: 320, height: 180))
                img = rect(CIColor(red: 0.8, green: 0.8, blue: 0.8), CGRect(x: 160, y: 0, width: 160, height: 180)).composited(over: img)
                img = rect(CIColor(red: 0.9, green: 0.1, blue: 0.1), CGRect(x: 0, y: 150, width: 320, height: 30)).composited(over: img)
                img = rect(CIColor(red: 0.1, green: 0.1, blue: 0.9), CGRect(x: 0, y: 0, width: 320, height: 30)).composited(over: img)
                let target = CGSize(width: 1280, height: 720)
                func pixels(_ i: CIImage) -> [UInt8] {
                    var b = [UInt8](repeating: 0, count: 1280 * 720 * 4)
                    ctx.render(i, toBitmap: &b, rowBytes: 1280 * 4, bounds: CGRect(origin: .zero, size: target), format: .RGBA8, colorSpace: nil)
                    return b
                }
                let upscaled = up.upscale(img, to: target, slot: 99, context: ctx)
                let plain = img.transformed(by: CGAffineTransform(scaleX: 4, y: 4))
                var good = false
                var detail = "no picture"
                if let upscaled {
                    let a = pixels(upscaled), b = pixels(plain)
                    func px(_ p: [UInt8], _ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * 1280 + x) * 4; return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2])) }
                    func near(_ u: (Int, Int, Int), _ v: (Int, Int, Int)) -> Bool { abs(u.0 - v.0) < 14 && abs(u.1 - v.1) < 14 && abs(u.2 - v.2) < 14 }
                    // Same way up and same colours: the bands and both sides match the plain resize.
                    let same = [(640, 40), (640, 680), (300, 360), (980, 360)].allSatisfy { near(px(a, $0.0, $0.1), px(b, $0.0, $0.1)) }
                    // The edge: how many pixels across row 360 are partway between dark and light.
                    func soft(_ p: [UInt8]) -> Int { (560..<720).filter { let v = px(p, $0, 360).0; return v > 70 && v < 185 }.count }
                    let sharper = soft(a) <= soft(b)
                    // Timing: 1080p to 4K.
                    let hd = rect(CIColor(red: 0.5, green: 0.4, blue: 0.3), CGRect(x: 0, y: 0, width: 1920, height: 1080))
                    _ = up.upscale(hd, to: CGSize(width: 3840, height: 2160), slot: 98, context: ctx)
                    let t0 = Date()
                    for _ in 0..<20 { _ = up.upscale(hd, to: CGSize(width: 3840, height: 2160), slot: 98, context: ctx) }
                    let ms = Date().timeIntervalSince(t0) / 20 * 1000
                    good = same && sharper
                    detail = String(format: "sameWayUpAndColours=%@ edge=%d px (plain %d) 1080p→4K=%.1f ms a frame", same ? "true" : "false", soft(a), soft(b), ms)
                }
                up.purge()
                log("UPSCALE \(good ? "OK" : "FAIL") \(detail)")
                ok = ok && good
            }
        }
        // Files promised by another app (Photos): held for an unsaved project, moved beside it on the first save (and the
        // clip follows), and held copies no project uses cleared away. Uses a throwaway holding folder, never the real one.
        do {
            let fm = FileManager.default
            let held = outDir.appendingPathComponent("held-test/From Photos", isDirectory: true)
            let projectDir = outDir.appendingPathComponent("held-test/Project", isDirectory: true)
            try? fm.removeItem(at: held.deletingLastPathComponent())
            try? fm.createDirectory(at: held, withIntermediateDirectories: true)
            try? fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
            EditorModel.heldMediaFolderForTests = held.standardizedFileURL
            defer { EditorModel.heldMediaFolderForTests = nil }
            let clip = held.appendingPathComponent("IMG_0001.mov")
            let stray = held.appendingPathComponent("IMG_0002.mov")
            try? fm.copyItem(at: mediaDir.appendingPathComponent("c_clip.mp4"), to: clip)
            try? fm.copyItem(at: mediaDir.appendingPathComponent("d_clip.mp4"), to: stray)
            var p = Project()
            p.settingsLocked = true
            let m = EditorModel()
            m.load(p, url: nil)
            try? await Task.sleep(nanoseconds: 200_000_000)
            let got: [MediaAsset] = await withCheckedContinuation { c in m.importFiles([clip], offerMatch: false) { c.resume(returning: $0) } }
            let heldOK = m.promisedMediaFolder.standardizedFileURL.path == held.standardizedFileURL.path && got.count == 1
            // Cleared: the stray copy (unused) goes, the one in the project stays.
            m.clearUnusedHeldMedia()
            let clearOK = !fm.fileExists(atPath: stray.path) && fm.fileExists(atPath: clip.path)
            // Saved: the held copy moves beside the project and the clip points there.
            let saveURL = projectDir.appendingPathComponent("Trip.room")
            m.saveForTest(to: saveURL)
            let moved = projectDir.appendingPathComponent("From Photos/IMG_0001.mov").standardizedFileURL.path
            let movedOK = got.first.flatMap { m.project.asset($0.id) }?.path == moved && fm.fileExists(atPath: moved) && !fm.fileExists(atPath: clip.path)
                && m.promisedMediaFolder.standardizedFileURL.path == projectDir.appendingPathComponent("From Photos").standardizedFileURL.path
            let good = heldOK && clearOK && movedOK
            log("PROMISED FILES \(good ? "OK" : "FAIL") heldWhileUnsaved=\(heldOK) unusedCleared=\(clearOK) movedOnSave=\(movedOK)")
            ok = ok && good
            try? fm.removeItem(at: held.deletingLastPathComponent())
        }
        // Replaced in another format: clip.mp4 deleted, clip.mov saved beside it. The same item takes the new file, and its
        // clip on the timeline stays; with two candidates (clip.mov and clip.mkv), nothing is guessed.
        do {
            let fm = FileManager.default
            let dir = outDir.appendingPathComponent("replace-test", isDirectory: true)
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let mp4 = dir.appendingPathComponent("amusement-park.mp4")
            try? fm.copyItem(at: mediaDir.appendingPathComponent("c_clip.mp4"), to: mp4)
            var p = Project()
            p.settingsLocked = true
            let m = EditorModel()
            m.load(p, url: nil)
            try? await Task.sleep(nanoseconds: 200_000_000)
            let got: [MediaAsset] = await withCheckedContinuation { c in m.importFiles([mp4], offerMatch: false) { c.resume(returning: $0) } }
            var good = false
            if let a = got.first {
                m.mutate { $0.clips.append(Clip(trackID: $0.videoTracks[0].id, kind: .video, assetID: a.id, start: 0, duration: 2)) }
                try? fm.removeItem(at: mp4)
                let mov = dir.appendingPathComponent("amusement-park.mov")
                try? fm.copyItem(at: mediaDir.appendingPathComponent("d_clip.mp4"), to: mov)
                await m.syncFolders()
                let now = m.project.asset(a.id)
                let movPath = mov.standardizedFileURL.path
                let swapped = now?.path == movPath && m.project.assets.count == 1 && m.project.clips.count == 1
                    && abs((now?.duration ?? 0) - 3) < 0.1
                // Two candidates: left missing, not guessed.
                try? fm.removeItem(at: mov)
                try? fm.copyItem(at: mediaDir.appendingPathComponent("c_clip.mp4"), to: dir.appendingPathComponent("amusement-park.m4v"))
                try? fm.copyItem(at: mediaDir.appendingPathComponent("e_clip.mp4"), to: dir.appendingPathComponent("amusement-park.mkv"))
                await m.adoptReplacements()
                let notGuessed = m.project.asset(a.id)?.path == movPath
                good = swapped && notGuessed
                log("REPLACED FILE \(good ? "OK" : "FAIL") sameItemNewFile=\(swapped) twoCandidatesLeftAlone=\(notGuessed)")
            } else {
                log("REPLACED FILE FAIL no import")
            }
            ok = ok && good
            try? fm.removeItem(at: dir)
        }
        // Reload from Disk after the file is replaced by a rotated version (same name): the item becomes portrait and the
        // picture is drawn turned (black at the sides of a wide frame), not the old landscape picture.
        do {
            let fm = FileManager.default
            let dir = outDir.appendingPathComponent("rotate-test", isDirectory: true)
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("clip.mov")
            let plain = outDir.deletingLastPathComponent().appendingPathComponent("rot/plain.mov")
            let tagged = outDir.deletingLastPathComponent().appendingPathComponent("rot/tagged.mov")
            if fm.fileExists(atPath: plain.path), fm.fileExists(atPath: tagged.path) {
                try? fm.copyItem(at: plain, to: file)
                var p = Project()
                p.settingsLocked = true
                p.width = 1280; p.height = 720
                let m = EditorModel()
                m.load(p, url: nil)
                try? await Task.sleep(nanoseconds: 200_000_000)
                let got: [MediaAsset] = await withCheckedContinuation { c in m.importFiles([file], offerMatch: false) { c.resume(returning: $0) } }
                if let a = got.first {
                    m.mutate { $0.clips.append(Clip(trackID: $0.videoTracks[0].id, kind: .video, assetID: a.id, start: 0, duration: 2)) }
                    try? fm.removeItem(at: file)
                    try? fm.copyItem(at: tagged, to: file)
                    await m.reloadMedia([a.id])
                    let now = m.project.asset(a.id)
                    let sizeOK = now?.width == 720 && now?.height == 1280
                    var drawnOK = false
                    if let img = await m.snapshot(at: 0.5)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                       let data = img.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
                        // The left edge of a wide frame holding a portrait picture is black.
                        let bpr = img.bytesPerRow, y = img.height / 2
                        let edge = Int(bytes[y * bpr + 4]) + Int(bytes[y * bpr + 5]) + Int(bytes[y * bpr + 6])
                        drawnOK = edge < 30
                    }
                    let good = sizeOK && drawnOK
                    log("RELOAD ROTATED \(good ? "OK" : "FAIL") portraitSize=\(sizeOK) (\(now?.width ?? 0)x\(now?.height ?? 0)) drawnTurned=\(drawnOK)")
                    ok = ok && good
                }
            } else {
                log("RELOAD ROTATED SKIP needs rot/plain.mov and rot/tagged.mov next to the out folder")
            }
            try? fm.removeItem(at: dir)
        }
        // Folders: a folder brought in whole is mirrored in Media and followed on disk: files added later come in,
        // a file renamed or the folder moved is followed (same items, nothing to locate), a file taken out stays out
        // (Undo brings it back), one put in the Trash isn't followed there, and Delete Folder takes it all out.
        do {
            let fm = FileManager.default
            let base = outDir.appendingPathComponent("folders-test")
            try? fm.removeItem(at: base)
            let root = base.appendingPathComponent("Shoot")
            let drone = root.appendingPathComponent("B-roll/Drone")
            try? fm.createDirectory(at: drone, withIntermediateDirectories: true)
            func put(_ name: String, _ to: String) { try? fm.copyItem(at: mediaDir.appendingPathComponent(name), to: root.appendingPathComponent(to)) }
            put("a_clip.mp4", "interview.mp4"); put("c_clip.mp4", "B-roll/street.mp4"); put("d_clip.mp4", "B-roll/Drone/air.mp4")
            try? "notes".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            let m = EditorModel()
            m.load(Project(), url: nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            func settle() async { for _ in 0..<100 where m.importCount > 0 { try? await Task.sleep(nanoseconds: 100_000_000) } }
            let rootPath = root.standardizedFileURL.path
            let imported: [MediaAsset] = await withCheckedContinuation { c in m.importFiles([root], offerMatch: false) { c.resume(returning: $0) } }
            var tree = MediaTree(m.project)
            let importOK = imported.count == 3 && m.project.folders?.count == 1 && tree.folders(in: nil) == [rootPath]
                && tree.folders(in: rootPath) == [rootPath + "/B-roll"] && tree.assets(in: rootPath, of: m.project.assets).count == 1
                && tree.count(under: rootPath) == 3 && tree.label(rootPath + "/B-roll/Drone") == "Shoot / B-roll / Drone"
                && tree.assets(in: nil, of: m.project.assets).isEmpty
            // A file added on disk comes in.
            put("e_clip.mp4", "B-roll/new.mp4")
            await m.syncFolders(); await settle()
            let added = m.project.assets.first { $0.path.hasSuffix("/B-roll/new.mp4") }
            let addOK = m.project.assets.count == 4 && added != nil
            guard let added, let street = m.project.assets.first(where: { $0.path.hasSuffix("street.mp4") }) else {
                log("FOLDERS FAIL import=\(importOK) added=false")
                ok = false
                return
            }
            // Renamed in Finder: the same item, with the new name.
            try? fm.moveItem(at: root.appendingPathComponent("B-roll/street.mp4"), to: root.appendingPathComponent("B-roll/street-2.mp4"))
            await m.syncFolders(); await settle()
            let renamed = m.project.asset(street.id)
            let renameOK = renamed?.path.hasSuffix("/B-roll/street-2.mp4") == true && renamed?.name == "street-2" && m.project.assets.count == 4
            // Taken out of the project: stays out when the folder is looked at again; Undo brings it back.
            m.removeAssets([added.id])
            await m.syncFolders(); await settle()
            let hiddenOK = m.project.assets.count == 3 && m.project.folders?.count == 1
            m.undo()
            let undoOK = m.project.assets.count == 4 && m.project.folders?.count == 1
            // The whole folder renamed: everything follows it.
            let moved = base.appendingPathComponent("Shoot Moved")
            try? fm.moveItem(at: root, to: moved)
            await m.syncFolders(); await settle()
            let movedPath = moved.standardizedFileURL.path
            tree = MediaTree(m.project)
            let folderOK = m.project.folders?.first?.path == movedPath && m.project.assets.count == 4
                && m.project.assets.allSatisfy { $0.path.hasPrefix(movedPath + "/") && fm.fileExists(atPath: $0.path) }
                && tree.count(under: movedPath) == 4 && m.missingAssets.isEmpty
            // Picked with an item and deleted together (Delete key): the folder's items and the item go.
            let picks = m.project.assets.count
            let interview = m.project.assets.first { $0.path.hasSuffix("/interview.mp4") }
            m.folderSelection = [movedPath + "/B-roll/Drone"]
            m.mediaSelection = interview.map { [$0.id] } ?? []
            m.deleteSelected()
            let pickedOK = m.project.assets.count == picks - 2 && m.folderSelection.isEmpty && m.mediaSelection.isEmpty
                && m.project.isHidden(movedPath + "/B-roll/Drone/air.mp4")
            m.undo()
            // Deleted on disk: put in the Trash and not on the timeline, it leaves Media (and its Drone folder with it),
            // and Undo doesn't bring it back; deleted while on the timeline, it stays, shown missing.
            let airURL = moved.appendingPathComponent("B-roll/Drone/air.mp4").standardizedFileURL
            let air = m.project.assets.first { $0.path.hasSuffix("air.mp4") }
            let street2 = m.project.assets.first { $0.path.hasSuffix("street-2.mp4") }
            if let street2 { m.mutate { $0.clips.append(Clip(trackID: $0.videoTracks[0].id, kind: .video, assetID: street2.id, start: 0, duration: 1)) } }
            var trashed: NSURL?
            try? fm.trashItem(at: airURL, resultingItemURL: &trashed)
            try? fm.removeItem(at: moved.appendingPathComponent("B-roll/street-2.mp4"))
            await m.syncFolders(); await settle()
            let goneOK = air != nil && m.project.asset(air!.id) == nil && !MediaTree(m.project).exists(movedPath + "/B-roll/Drone")
            m.undo()
            let staysGone = air != nil && m.project.asset(air!.id) == nil
            m.redo()
            let usedStays = street2 != nil && m.project.asset(street2!.id) != nil
            let trashOK = goneOK && staysGone && usedStays
            if let t = trashed as URL? { try? fm.removeItem(at: t) }
            // Delete Folder: all of it goes; the files stay. (Timeline cleared first, so it doesn't stop to ask.)
            m.mutate { $0.clips.removeAll() }
            m.removeFolder(movedPath)
            let deleteOK = m.project.assets.isEmpty && m.project.folders == nil && fm.fileExists(atPath: movedPath + "/interview.mp4")
            if !trashOK { log("FOLDERS detail goneFromMedia=\(goneOK) undoKeepsItGone=\(staysGone) usedOneStays=\(usedStays)") }
            let good = importOK && addOK && renameOK && hiddenOK && undoOK && folderOK && trashOK && pickedOK && deleteOK
            log("FOLDERS \(good ? "OK" : "FAIL") import=\(importOK) added=\(addOK) rename=\(renameOK) hidden=\(hiddenOK) undo=\(undoOK) moved=\(folderOK) trash=\(trashOK) picked=\(pickedOK) delete=\(deleteOK)")
            ok = ok && good
            try? fm.removeItem(at: base)
        }
        // Zoom on Scale: in, in and out, out; kept on its picture through trims and splits (an in-and-out cut
        // in the middle leaves an in and an out); never past the picture's edge; drawn zoomed where it's framed.
        do {
            var z = ZoomMove.starter(.inOut, length: 8)
            let io = z.amount(at: 0) == 0 && z.amount(at: 0.5) > 0 && z.amount(at: 0.5) < 1 && z.amount(at: 4) == 1 && z.amount(at: 7.99) < 0.01
            z.smooth = false
            let linear = abs(z.amount(at: 1) - 0.5) < 1e-9 && z.p2 == 2
            let zin = ZoomMove.starter(.zoomIn, length: 8), zout = ZoomMove.starter(.zoomOut, length: 8)
            let modes = zin.amount(at: 7.9) == 1 && zout.amount(at: 0) == 1 && zout.amount(at: 7.99) < 0.01
            var p = Project()
            var c = Clip(trackID: p.videoTracks[0].id, kind: .solid, start: 0, duration: 8)
            c.transform = ClipTransform(scale: 2, x: 0.9, y: 0, zoom: .starter(.inOut, length: 8))
            p.clips = [c]
            let edge = c.transform!.at(4)!.x == 0.5
            let right = p.split(ids: [c.id], at: 4)
            let l = p.clip(c.id)!.transform!.zoom!, r = p.clip(right.first!)!.transform!.zoom!
            let split = l.amount(at: 3.9) == 1 && r.amount(at: 0) == 1 && r.amount(at: 3.99) < 0.01
            // The toggle: on zooms to 200% from 100%; off keeps the scale.
            let m = EditorModel()
            var q = Project()
            let clip = Clip(trackID: q.videoTracks[0].id, kind: .solid, start: 0, duration: 6)
            q.clips = [clip]
            m.load(q, url: nil)
            m.toggleZoom(clip.id)
            let on = m.project.clip(clip.id)?.transform?.scale == 2 && m.project.clip(clip.id)?.transform?.zoom != nil && m.playhead > 0
            m.toggleZoom(clip.id)
            let off = m.project.clip(clip.id)?.transform?.zoom == nil && m.project.clip(clip.id)?.transform?.scale == 2
            // Red on the left, blue on the right, zoomed 2× onto the right half: blue at the left edge.
            let size = CGSize(width: 64, height: 36)
            let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 36))
            let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 36))
            var pic = Clip(trackID: p.videoTracks[0].id, kind: .image, start: 0, duration: 4)
            pic.transform = ClipTransform(scale: 2, x: -0.5, y: 0, zoom: .starter(.zoomIn, length: 4))
            let ins = TimelineInstruction(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600)),
                                          layers: [RenderLayer(clip: pic, source: .image(blue.composited(over: red)))], trackIDs: [], canvas: size)
            let ctx = CIContext(options: [.workingColorSpace: NSNull()])
            func pixel(_ t: Double) -> [UInt8] {
                var px = [UInt8](repeating: 0, count: 4)
                ctx.render(TimelineCompositor.compose(ins, at: t, output: size) { _, _ in nil }, toBitmap: &px, rowBytes: 4,
                           bounds: CGRect(x: 2, y: 18, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
                return px
            }
            let first = pixel(0), last = pixel(3)
            let drawn = first[0] > 200 && first[2] < 50 && last[2] > 200 && last[0] < 50
            let good = io && linear && modes && edge && split && on && off && drawn
            log("ZOOM \(good ? "OK" : "FAIL") inOut=\(io) linear=\(linear) modes=\(modes) edge=\(edge) split=\(split) toggle=\(on && off) drawn=\(drawn) \(first) \(last)")
            ok = ok && good
        }
        // Typed timecodes.
        do {
            let cases: [(String, Double?)] = [("1000", 10), ("1:02:03", 62.1), ("00:00:02:15", 2.5), ("12", 0.4), ("abc", nil)]
            let good = cases.allSatisfy { c in
                let v = Timecode.parse(c.0, fps: 30)
                return c.1 == nil ? v == nil : v.map { abs($0 - c.1!) < 1e-9 } ?? false
            }
            log("TIMECODE \(good ? "OK" : "FAIL")")
            ok = ok && good
        }
        // Transition timing: the dissolve borrows the sped-up clip's unused head and ends at the cut;
        // a dip sits across the cut; with no spare media at all, a dissolve uses what there is.
        do {
            var p = Project()
            let v = p.videoTracks[0].id
            let a = Clip(trackID: v, kind: .video, start: 0, duration: 2)
            var b = Clip(trackID: v, kind: .video, start: 2, duration: 1, sourceStart: 2, speed: 4)
            b.transitionIn = Transition(kind: .dissolve, duration: 0.5)
            p.clips = [a, b]
            let span = p.transitionSpan(from: a, into: b)
            let headOK = span.map { abs($0.start - 1.5) < 1e-9 && $0.end == 2 && $0.fromHead } ?? false
            let plan = p.transitionPlan(b)
            let planOK = abs(plan.leadIn - 0.5) < 1e-9 && plan.reveal?.start == 1.5
            p.clips[1].transitionIn = Transition(kind: .dipToBlack, duration: 1)
            let dip = p.transitionSpan(from: a, into: p.clips[1])
            let dipOK = dip.map { $0.start == 1.5 && $0.end == 2.5 } ?? false
            let concealOK = p.transitionPlan(a).conceal?.end == 2
            let good = headOK && planOK && dipOK && concealOK
            log("TRANSITIONS \(good ? "OK" : "FAIL") head=\(headOK) plan=\(planOK) dip=\(dipOK) conceal=\(concealOK)")
            ok = ok && good
        }
        // Ducking: A2 (the tone) turned down while A1 has sound; checked by comparing files.
        do {
            var ducked = project
            ducked.audioTracks[1].duckUnder = ducked.audioTracks[0].id
            ducked.audioTracks[1].duckDB = -18
            var settings = ExportSettings()
            settings.format = .wav
            _ = await export(ducked, media, settings, to: outDir.appendingPathComponent("ducked.wav"))
            let spans = AudioLevels.activity(on: project.audioTracks[0].id, project: project, media: media)
            log("DUCK spans=\(spans.map { String(format: "%.2f-%.2f", $0.start, $0.end) })")
        }
        // Loudness: a WAV exported at -14 LUFS, measured again from the file.
        do {
            var settings = ExportSettings()
            settings.format = .wav
            settings.loudness = -14
            let url = outDir.appendingPathComponent("loud_14.wav")
            _ = await export(project, media, settings, to: url)
            let check = AVURLAsset(url: url)
            let comp = AVMutableComposition()
            if let src = try? await check.loadTracks(withMediaType: .audio).first, let range = try? await src.load(.timeRange),
               let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? t.insertTimeRange(range, of: src, at: .zero)
            }
            let measured = LoudnessMeter.measure(BuiltTimeline(composition: comp, videoComposition: AVMutableVideoComposition(),
                                                               audioMix: nil, duration: 0, signature: 0, hasAudio: true))
            let good = measured.map { abs($0.lufs + 14) < 0.6 || $0.peakDB > -1.3 } ?? false
            log("LOUDNESS \(good ? "OK" : "FAIL") lufs=\(measured.map { String(format: "%.2f", $0.lufs) } ?? "-") peak=\(measured.map { String(format: "%.2f", $0.peakDB) } ?? "-")")
            ok = ok && good
        }
        // Text and solids land in the first open spot: a free track at the playhead, else the next gap.
        do {
            var p = Project()
            let v1 = p.videoTracks[0].id, v2 = p.videoTracks[1].id
            p.clips = [Clip(trackID: v1, kind: .solid, start: 0, duration: 10)]
            let up = p.firstFreeVideoSpot(from: 2, duration: 5)
            p.clips.append(Clip(trackID: v2, kind: .solid, start: 1, duration: 3))
            let right = p.firstFreeVideoSpot(from: 2, duration: 5)
            let good = up.map { $0.track == v2 && $0.start == 2 } == true && right.map { $0.track == v2 && $0.start == 4 } == true
            log("PLACEMENT \(good ? "OK" : "FAIL")")
            ok = ok && good
        }
        // Audio scrubbing: the edit's mix is rendered into memory, with sound where the edit has it and
        // silence after the end.
        do {
            let scrubber = AudioScrubber()
            scrubber.prepare(project: project, media: media)
            var waited = 0
            while !scrubber.ready, waited < 100 { try? await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
            let mid = scrubber.peak(at: 1.5), late = scrubber.peak(at: project.duration + 1)
            let good = scrubber.ready && mid > 0.01 && late == 0
            log("AUDIO SCRUB \(good ? "OK" : "FAIL") ready=\(scrubber.ready) after=\(waited * 50)ms peak=\(mid) end=\(late)")
            ok = ok && good
        }
        // Meters: lit while playing, and empty the moment playback stops (no lingering levels or red).
        do {
            let meters = MeterState()
            var loud = project
            loud.audioTracks[1].gainDB = 30
            for _ in 0..<5 { meters.update(project: loud, media: media, time: 2.0, playing: true) }
            let lit = meters.master.level > -20 && meters.master.clipped
            meters.update(project: loud, media: media, time: 2.0, playing: false)
            let empty = meters.master.level == MeterState.floor && !meters.master.clipped && meters.tracks.values.allSatisfy { $0.level == MeterState.floor && $0.peak == MeterState.floor }
            log("METERS \(lit && empty ? "OK" : "FAIL") lit=\(lit) emptyOnStop=\(empty)")
            ok = ok && lit && empty
        }
        // Gaps and pasting: a gap closes with linked audio following; all gaps close; paste makes fresh,
        // still-linked copies at the playhead.
        do {
            var p = Project()
            let v = p.videoTracks[0].id, a = p.audioTracks[0].id
            let link = UUID()
            let c1 = Clip(trackID: v, kind: .solid, start: 0, duration: 2)
            let c2 = Clip(trackID: v, kind: .video, start: 3, duration: 2, linkID: link)
            let c2a = Clip(trackID: a, kind: .audio, start: 3, duration: 2, linkID: link)
            let c3 = Clip(trackID: v, kind: .solid, start: 6, duration: 1)
            p.clips = [c1, c2, c3, c2a]
            let g = p.gap(on: v, at: 2.5)
            var q = p
            q.pullLeft(on: v, from: 3, by: 1)
            let closed = g.map { $0.start == 2 && $0.end == 3 } == true && q.clip(c2.id)?.start == 2 && q.clip(c2a.id)?.start == 2 && q.clip(c3.id)?.start == 5
            var r = p
            r.closeAllGaps(on: v)
            let all = r.clip(c2.id)?.start == 2 && r.clip(c3.id)?.start == 4
            let m = EditorModel()
            m.load(p, url: nil)
            m.selection = [c2.id]
            m.copySelection()
            m.seek(to: 10)
            m.paste()
            let pasted = m.project.clips.filter { $0.start == 10 }
            let pasteOK = pasted.count == 2 && Set(pasted.map(\.linkID)).count == 1 && pasted[0].linkID != link && !pasted.contains { $0.id == c2.id }
            log("GAPS+PASTE \(closed && all && pasteOK ? "OK" : "FAIL") gap=\(closed) all=\(all) paste=\(pasteOK)")
            ok = ok && closed && all && pasteOK
        }
        // @folder: a folder in Media, with the folders inside it; two folders of the same name are told apart by
        // their path; Magic and the AI apps are told exactly which files it holds.
        do {
            func asset(_ path: String) -> MediaAsset {
                MediaAsset(path: path, name: URL(fileURLWithPath: path).lastPathComponent, kind: .video, duration: 5,
                           width: 1920, height: 1080, fps: 30, hasAudio: false)
            }
            var p = Project()
            let a = asset("/tmp/er-shoot/Drone/a.mov"), b = asset("/tmp/er-shoot/Drone/Day 2/b.mov")
            let c = asset("/tmp/er-shoot/c.mov"), d = asset("/tmp/er-other/Drone/d.mov")
            p.assets = [a, b, c, d]
            p.folders = [MediaFolder(path: "/tmp/er-shoot"), MediaFolder(path: "/tmp/er-other")]
            let folders = MagicMention.folderLabels(p)
            let names = Set(folders.map(\.name))
            let namesOK = names == ["er-shoot", "er-shoot / Drone", "Day 2", "er-other", "er-other / Drone"]
            let found = MagicMention.find(in: "cut a promo from @folder:er-shoot / Drone please", media: p.assets, folders: folders)
            let drone = folders.first { $0.path == "/tmp/er-shoot/Drone" }
            let findOK = found.map(\.mention) == [.folder("/tmp/er-shoot/Drone", only: false)] && Set(drone?.files ?? []) == [a.id, b.id]
                && MagicMention.find(in: "use @folder:day 2", media: p.assets, folders: folders).map(\.mention) == [.folder("/tmp/er-shoot/Drone/Day 2", only: false)]
            let plain = MagicMention.plain("use @folder:Day 2 now", media: p.assets, folders: folders)
            let plainOK = plain == "use the files in the folder er-shoot / Drone / Day 2 (b.mov) now"
            let told = MagicAgent.pointing(MagicPointers(playhead: 0, selected: [], range: nil), request: "use @folder:er-shoot / Drone", project: p) ?? ""
            let toldOK = told.contains(a.id.uuidString) && told.contains(b.id.uuidString) && !told.contains(c.id.uuidString) && !told.contains(d.id.uuidString)
            // Only what's directly in it, when asked: the AI is told where each file is, and Local keeps to the top.
            let shoot = folders.first { $0.path == "/tmp/er-shoot" }
            let laidOut = told.contains("Directly in \"er-shoot / Drone\": a.mov") && told.contains("In \"er-shoot / Drone / Day 2\": b.mov")
            let asks = ["@folder:footage use only the clips directly in this folder and make a 10s clip",
                        "@folder:footage just this folder, not the subfolders", "use @folder:footage but not the sub-folders",
                        "@folder:footage top level only", "@folder:footage, not the folders inside it"]
            let everything = ["@folder:footage use all the clips in this folder and make 10s clip", "make a promo from @folder:footage"]
            let onlyOK = asks.allSatisfy(MagicMention.onlyDirect) && !everything.contains(where: MagicMention.onlyDirect)
                && shoot?.files(for: "use @folder:er-shoot only, no subfolders") == [c.id] && Set(shoot?.files(for: "use @folder:er-shoot") ?? []) == [a.id, b.id, c.id]
            // Local: "use all the media directly in @folder:…" keeps to that folder's files (not those and everything else).
            var local = LocalRecipe()
            LocalBrain.applyMedia(&local, named: [c], action: "unchanged", request: "use all the media directly in this folder and cut to 12s video",
                                  pointed: [c.id], hasEdit: true, folder: true)
            var asFiles = LocalRecipe()
            LocalBrain.applyMedia(&asFiles, named: [c], action: "unchanged", request: "use all the media and add @c.mov too", pointed: [c.id], hasEdit: true)
            // A clip elsewhere that shows something in the request isn't added to the folder's files.
            var shown = LocalRecipe()
            LocalBrain.applyMedia(&shown, named: [c, d], action: "only", request: "use all the footage in just this folder", pointed: [c.id], folder: true)
            let localOK = local.keepOnly == [c.id] && asFiles.keepOnly.isEmpty && shown.keepOnly == [c.id]
            // Asked for just the folder: the AI is told only its own files, and to leave the sub-folders out.
            let justTold = MagicAgent.pointing(MagicPointers(playhead: 0, selected: [], range: nil),
                                               request: "use all the media in just this folder @folder:er-shoot and make 10s video", project: p) ?? ""
            let justOK = justTold.contains("ONLY the 1 library file") && justTold.contains(c.id.uuidString)
                && !justTold.contains(a.id.uuidString) && !justTold.contains(b.id.uuidString) && justTold.contains("2 files in its sub-folders")
            // "@folder:…:only": the folder's own files, without any words about it; offered only where there are folders inside.
            let onlyFound = MagicMention.find(in: "cut from @folder:er-shoot:only now", media: p.assets, folders: folders)
            let onlyTold = MagicAgent.pointing(MagicPointers(playhead: 0, selected: [], range: nil), request: "make a cut from @folder:er-shoot:only", project: p) ?? ""
            let suffixOK = onlyFound.map(\.mention) == [.folder("/tmp/er-shoot", only: true)] && onlyFound.first?.range.length == 21
                && onlyTold.contains("ONLY the 1 library file") && !onlyTold.contains(a.id.uuidString)
                && MagicMention.plain("use @folder:er-shoot:only", media: p.assets, folders: folders) == "use the files directly in the folder er-shoot (c.mov)"
                && shoot?.hasSubfolders == true && folders.first { $0.name == "Day 2" }?.hasSubfolders == false
                && MagicMention.find(in: "@folder:Day 2:only", media: p.assets, folders: folders).first?.mention == .folder("/tmp/er-shoot/Drone/Day 2", only: false)
            let folderOK = namesOK && findOK && plainOK && toldOK && laidOut && onlyOK && localOK && justOK && suffixOK
            log("MENTION FOLDER \(folderOK ? "OK" : "FAIL") names=\(namesOK) \(names.sorted()) find=\(findOK) plain=\(plainOK) told=\(toldOK) laidOut=\(laidOut) only=\(onlyOK) local=\(localOK) just=\(justOK) suffix=\(suffixOK)")
            ok = ok && folderOK
        }
        // Pasting into another project (another tab): the media comes too, once, linked to the same file; media it
        // already has (the same file) is used, not added again; clips keep their tracks by place (V3 stays V3, made there if need be).
        do {
            var src = Project()
            let v3 = src.addTrack(.video)
            let asset = MediaAsset(path: "/tmp/editroom-selftest/shared.mov", name: "shared.mov", kind: .video, duration: 10,
                                   width: 1920, height: 1080, fps: 30, hasAudio: true)
            src.assets = [asset]
            let link = UUID()
            src.clips = [Clip(trackID: v3, kind: .video, assetID: asset.id, start: 2, duration: 3, linkID: link),
                         Clip(trackID: src.audioTracks[0].id, kind: .audio, assetID: asset.id, start: 2, duration: 3, linkID: link)]
            let a = EditorModel(), b = EditorModel()
            a.load(src, url: nil)
            b.load(Project(), url: nil)
            a.selection = [src.clips[0].id]
            a.copySelection()
            b.paste()
            b.seek(to: 20)
            b.paste()
            let added = b.project.assets.count == 1 && b.project.assets[0].path == asset.path
            let onV3 = b.project.videoTracks.count == 3 && b.project.clips.filter { $0.kind == .video }.allSatisfy { $0.trackID == b.project.videoTracks[2].id }
            let linked = b.project.clips.count == 4 && b.project.clips.allSatisfy { $0.assetID == b.project.assets[0].id }
            // Already in Media there (its own id): that one's used.
            var other = Project()
            let mine = MediaAsset(path: asset.path, name: "shared.mov", kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: true)
            other.assets = [mine]
            let c = EditorModel()
            c.load(other, url: nil)
            c.paste()
            let reused = c.project.assets.count == 1 && c.project.clips.count == 2 && c.project.clips.allSatisfy { $0.assetID == mine.id }
            // Within the same project it pastes as before.
            a.seek(to: 10)
            a.paste()
            let same = a.project.assets.count == 1 && a.project.clips.count == 4 && a.project.videoTracks.count == 3
            let pasteOK = added && onV3 && linked && reused && same
            log("PASTE ACROSS \(pasteOK ? "OK" : "FAIL") added=\(added) tracks=\(onV3) linked=\(linked) reused=\(reused) same=\(same)")
            ok = ok && pasteOK
        }
        // Brightness of each range: a project from before has none (and still opens), lifting the shadows brightens
        // the darks more than the brights, pulling the highlights down darkens the brights more, and it's kept.
        do {
            let old = try? JSONDecoder().decode(ColorGrade.self, from: Data(#"{"exposure":0.5,"lookIntensity":1}"#.utf8))
            let opens = old?.exposure == 0.5 && old?.shadowsLevel == 0 && old?.highlightsLevel == 0
            func grey(_ g: ColorGrade, _ v: Int) -> Float {
                guard let data = GradeBaker.cube(for: g) else { return Float(v) / Float(GradeBaker.dimension - 1) }
                let n = GradeBaker.dimension
                return data.withUnsafeBytes { $0.bindMemory(to: Float.self)[((v * n + v) * n + v) * 4] }
            }
            let n = GradeBaker.dimension, dark = n / 8, light = n * 7 / 8
            var lows = ColorGrade(); lows.shadowsLevel = 60
            var highs = ColorGrade(); highs.highlightsLevel = -60
            let base = ColorGrade()
            let lifted = grey(lows, dark) - grey(base, dark) > grey(lows, light) - grey(base, light) + 0.01
            let pulled = grey(base, light) - grey(highs, light) > grey(base, dark) - grey(highs, dark) + 0.01
            let kept = (try? JSONDecoder().decode(ColorGrade.self, from: JSONEncoder().encode(lows)))?.shadowsLevel == 60
            // Switched off (Grade's eye): kept and saved, but nothing drawn, in the viewer or an export.
            var switched = lows; switched.off = true
            let offOK = old?.off == false && GradeBaker.cube(for: switched) == nil && !switched.isNeutral
                && (try? JSONDecoder().decode(ColorGrade.self, from: JSONEncoder().encode(switched)))?.off == true
                && { var back = switched; back.off = false; return GradeBaker.cube(for: back) != nil }()
            log("GRADE LEVELS \(opens && lifted && pulled && kept && offOK ? "OK" : "FAIL") opens=\(opens) lifted=\(lifted) pulled=\(pulled) kept=\(kept) off=\(offOK)")
            ok = ok && opens && lifted && pulled && kept && offOK
        }
        // HDR (HLG) project: an HLG clip keeps its highlights (normal white 0.75, a highlight 0.95), an SDR solid and an
        // SDR clip's white land at standard white (0.75, not boosted), and the export is 10-bit HEVC tagged HLG. The same
        // project as SDR still exports Rec.709.
        do {
            let hlgURL = outDir.appendingPathComponent("hdr_patches.mov"), sdrURL = outDir.appendingPathComponent("sdr_white.mov")
            let madeHLG = await makeTestClip(hlgURL, hlg: true) { x in x < 320 ? 0.75 : 0.95 }
            let madeSDR = await makeTestClip(sdrURL, hlg: false) { _ in 1.0 }
            if madeHLG, madeSDR, let h = await media.importFile(hlgURL), let w = await media.importFile(sdrURL) {
                var p = Project()
                p.width = 640; p.height = 360; p.fps = 30; p.hdr = true; p.settingsLocked = true
                p.assets = [h, w]
                let v1 = p.videoTracks[0].id, v2 = p.videoTracks[1].id
                var solid = Clip(trackID: v2, kind: .solid, start: 0, duration: 1)
                solid.color = RGBA(r: 1, g: 1, b: 1, a: 1)
                solid.transform = ClipTransform(scale: 0.25, x: 0, y: 0.3)
                p.clips = [Clip(trackID: v1, kind: .video, assetID: h.id, start: 0, duration: 1),
                           Clip(trackID: v1, kind: .video, assetID: w.id, start: 1, duration: 1), solid]
                var s = ExportSettings(); s.codec = .h264; s.includeAudio = false
                let hdrOut = outDir.appendingPathComponent("hdr_export.mp4")
                let exported = await export(p, media, s, to: hdrOut)
                let tags = await transferFunction(hdrOut)
                let a = await lumaSamples(hdrOut, at: 0.5, points: [(160, 90), (480, 90), (320, 288)])
                let b = await lumaSamples(hdrOut, at: 1.5, points: [(320, 180)])
                let near = { (v: Double?, want: Double) in v.map { abs($0 - want) < 0.04 } ?? false }
                let kept = near(a[0], 0.75) && near(a[1], 0.95)
                let titleWhite = near(a[2], 0.75), sdrWhite = near(b[0], 0.75)
                var sdr = p; sdr.hdr = nil
                let sdrOut = outDir.appendingPathComponent("hdr_as_sdr.mp4")
                let sdrOK = await export(sdr, media, s, to: sdrOut)
                let sdrTags = await transferFunction(sdrOut)
                let good = exported && tags == (AVVideoTransferFunction_ITU_R_2100_HLG as String) && kept && titleWhite && sdrWhite
                    && sdrOK && sdrTags == (AVVideoTransferFunction_ITU_R_709_2 as String)
                log("HDR \(good ? "OK" : "FAIL") tags=\(tags ?? "-") highlights=\(kept) (\(a.map { $0.map { String(format: "%.3f", $0) } ?? "-" })) sdrWhite=\(sdrWhite) (\(b.map { $0.map { String(format: "%.3f", $0) } ?? "-" })) solidWhite=\(titleWhite) asSDR=\(sdrTags ?? "-")")
                ok = ok && good
            } else {
                log("HDR FAIL couldn't make or open the test clips")
                ok = false
            }
        }
        // Speech language: one this Mac can't hear is said (by name), not guessed at in English; one it can is used;
        // Automatic is the Mac's. The setting is put back as it was.
        if Transcripts.available {
            let defaults = UserDefaults.standard
            let before = defaults.string(forKey: Transcripts.languageKey)
            defaults.set("vi_VN", forKey: Transcripts.languageKey)
            let vi = await Transcripts.resolve()
            defaults.set("es_ES", forKey: Transcripts.languageKey)
            let es = await Transcripts.resolve()
            defaults.set("", forKey: Transcripts.languageKey)
            let auto = await Transcripts.resolve()
            if let before { defaults.set(before, forKey: Transcripts.languageKey) } else { defaults.removeObject(forKey: Transcripts.languageKey) }
            let unsupported = vi.locale == nil && vi.name.lowercased().contains("vietnam")
            let spanish = es.locale?.language.languageCode?.identifier == "es"
            let automatic = auto.locale != nil
            log("SPEECH LANGUAGE \(unsupported && spanish && automatic ? "OK" : "FAIL") unsupported=\(unsupported) (\(vi.name)) spanish=\(spanish) (\(es.locale?.identifier ?? "-")) automatic=\(automatic) (\(auto.locale?.identifier ?? "-"))")
            ok = ok && unsupported && spanish && automatic
        }
        // Overwriting into the middle of a clip with its sound: both halves keep their sound linked. Over the
        // picture only, the right half of the picture stands alone.
        do {
            var p = Project()
            let v = p.videoTracks[0].id, a = p.audioTracks[0].id
            let link = UUID(), newLink = UUID()
            let long = Clip(trackID: v, kind: .video, start: 0, duration: 10, linkID: link)
            let longA = Clip(trackID: a, kind: .audio, start: 0, duration: 10, linkID: link)
            let mid = Clip(trackID: v, kind: .video, start: 3, duration: 2, linkID: newLink)
            let midA = Clip(trackID: a, kind: .audio, start: 3, duration: 2, linkID: newLink)
            p.clips = [long, longA, mid, midA]
            p.resolveOverlaps(keeping: [mid.id, midA.id])
            let rights = p.clips.filter { $0.start == 5 }
            let leftsLinked = p.clip(long.id)?.linkID == link && p.clip(longA.id)?.linkID == link
            let rightsLinked = rights.count == 2 && Set(rights.map(\.kind)) == [.video, .audio]
                && rights[0].linkID != nil && rights[0].linkID == rights[1].linkID && rights[0].linkID != link
            var q = Project()
            let qv = q.videoTracks[0].id, qa = q.audioTracks[0].id
            let title = Clip(trackID: qv, kind: .text, start: 3, duration: 2)
            q.clips = [Clip(trackID: qv, kind: .video, start: 0, duration: 10, linkID: link),
                       Clip(trackID: qa, kind: .audio, start: 0, duration: 10, linkID: link), title]
            q.resolveOverlaps(keeping: [title.id])
            let alone = q.clips.first { $0.start == 5 && $0.kind == .video }?.linkID == nil
            log("OVERWRITE LINKS \(leftsLinked && rightsLinked && alone ? "OK" : "FAIL") left=\(leftsLinked) right=\(rightsLinked) pictureOnly=\(alone)")
            ok = ok && leftsLinked && rightsLinked && alone
        }
        // Freeze frame: the clip splits at the playhead, a 2s hold goes in and the rest moves along;
        // exported frames across the hold are identical.
        if let video = project.assets.first(where: { $0.kind == .video && $0.duration >= 6 }) {
            var p = Project()
            p.width = 640; p.height = 360; p.fps = 30
            p.assets = project.assets
            let v = p.videoTracks[0].id
            p.clips = [Clip(trackID: v, kind: .video, assetID: video.id, start: 0, duration: 4)]
            let m = EditorModel()
            m.load(p, url: nil)
            m.seek(to: 1)
            m.selection = [p.clips[0].id]
            m.freezeFrame()
            let parts = m.project.clips.sorted { $0.start < $1.start }.map { ($0.start, $0.end, $0.isFreeze) }
            let shape = parts.count == 3 && parts[1] == (1, 3, true) && parts[2].0 == 3 && abs(parts[2].1 - 6) < 1e-9
            let url = outDir.appendingPathComponent("freeze.mp4")
            var settings = ExportSettings()
            settings.includeAudio = false
            _ = await export(m.project, media, settings, to: url)
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            func bytes(_ t: Double) async -> [UInt8] {
                guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
                      let data = cg.dataProvider?.data as Data? else { return [] }
                return Array(data)
            }
            func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
                guard !a.isEmpty, a.count == b.count else { return 999 }
                var sum = 0
                for i in stride(from: 0, to: a.count, by: 7) { sum += abs(Int(a[i]) - Int(b[i])) }
                return Double(sum) / Double(a.count / 7)
            }
            let f1 = await bytes(1.3), f2 = await bytes(2.7), moving = await bytes(4.5)
            let held = diff(f1, f2) < 2 && diff(f1, moving) > 2
            log("FREEZE \(shape && held ? "OK" : "FAIL") shape=\(shape) held=\(held) d=\(diff(f1, f2)) vs \(diff(f1, moving))")
            ok = ok && shape && held
        }
        // Reverse: a reversed clip's first frame is the last of its stretch of the file and its last
        // frame the first, its length is unchanged, and its sound comes along.
        if let video = project.assets.first(where: { $0.kind == .video && $0.duration >= 6 && $0.hasAudio }),
           let v1 = project.videoTracks.first, let a1 = project.audioTracks.first {
            var p = project
            p.clips = []
            let link = UUID()
            var v = Clip(trackID: v1.id, kind: .video, assetID: video.id, start: 0, duration: 3, sourceStart: 1)
            var a = Clip(trackID: a1.id, kind: .audio, assetID: video.id, start: 0, duration: 3, sourceStart: 1)
            v.linkID = link; a.linkID = link
            for c in [v, a] {
                var r = c
                r.sourceStart = video.duration - (c.sourceStart + c.duration)
                r.reversed = true
                p.clips.append(r)
            }
            let out = outDir.appendingPathComponent("reversed.mp4")
            var settings = ExportSettings()
            settings.height = 360
            _ = await export(p, media, settings, to: out)
            let rev = AVURLAsset(url: out), src = AVURLAsset(url: video.url)
            let length = (try? await rev.load(.duration).seconds) ?? 0
            func frame(_ a: AVAsset, _ t: Double) async -> [UInt8] {
                let g = AVAssetImageGenerator(asset: a)
                g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
                g.maximumSize = CGSize(width: 160, height: 90)
                guard let cg = try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
                      let d = cg.dataProvider?.data as Data? else { return [] }
                return Array(d)
            }
            func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
                guard !a.isEmpty, a.count == b.count else { return 999 }
                var s = 0; for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }; return Double(s) / Double(a.count)
            }
            let startMatch = diff(await frame(rev, 0.02), await frame(src, 3.97))
            let endMatch = diff(await frame(rev, 2.95), await frame(src, 1.02))
            let wrongWay = diff(await frame(rev, 0.02), await frame(src, 1.02))
            let audio = ((try? await rev.loadTracks(withMediaType: .audio))?.count ?? 0) == 1
            let good = abs(length - 3) < 0.1 && startMatch < 8 && endMatch < 8 && wrongWay > startMatch && audio
            log("REVERSE \(good ? "OK" : "FAIL") length=\(length) start=\(startMatch) end=\(endMatch) forwards=\(wrongWay) audio=\(audio)")
            ok = ok && good
        }
        // In/out: exporting just the range gives a file the range's length, and markers survive saving.
        do {
            var p = project
            p.inPoint = 1
            p.outPoint = 2.5
            p.markers = [Marker(time: 1.2, name: "Beat drop", tint: .green)]
            var settings = ExportSettings()
            settings.includeAudio = true
            settings.height = 360
            settings.rangeOnly = true
            let url = outDir.appendingPathComponent("range.mp4")
            _ = await export(p, media, settings, to: url)
            let length = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.timeRange).duration.seconds) ?? 0
            let back = (try? JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)))
            let kept = back?.markers?.first?.name == "Beat drop" && back?.inPoint == 1 && back?.outPoint == 2.5
            var old = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
            old?["markers"] = nil
            let opensOld = old.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { try? JSONDecoder().decode(Project.self, from: $0) } != nil
            let snaps = p.snapTargets(excluding: []).contains(1.2)
            let good = abs(length - 1.5) < 0.06 && kept && opensOld && snaps
            log("RANGE \(good ? "OK" : "FAIL") length=\(length) kept=\(kept) opensOld=\(opensOld) snaps=\(snaps)")
            ok = ok && good
        }
        // Sticky trims: a left edge counts as attached at time zero or against a clip, not in the open.
        do {
            var p = Project()
            p.videoTracks = [Track(kind: .video)]
            let v = p.videoTracks[0].id
            let a = Clip(trackID: v, kind: .solid, start: 0, duration: 2)
            let b = Clip(trackID: v, kind: .solid, start: 2, duration: 2)
            let free = Clip(trackID: v, kind: .solid, start: 6, duration: 2)
            p.clips = [a, b, free]
            let good = TimelineCanvas.attachedOnLeft([a], in: p) && TimelineCanvas.attachedOnLeft([b], in: p) && !TimelineCanvas.attachedOnLeft([free], in: p)
            log("STICKY EDGE \(good ? "OK" : "FAIL")")
            ok = ok && good
        }
        // Film print: the app's Look gives the same colours as the mock it was approved from.
        do {
            let cases: [((Double, Double, Double), (Double, Double, Double))] = [
                ((0.80, 0.55, 0.42), (0.8603, 0.6593, 0.5182)),
                ((0.70, 0.10, 0.12), (0.6969, 0.1364, 0.1386)),
                ((0.20, 0.50, 0.25), (0.3269, 0.5724, 0.3360)),
                ((0.50, 0.50, 0.50), (0.6021, 0.5987, 0.5938)),
                ((0.10, 0.12, 0.20), (0.1167, 0.1203, 0.1584)),
                ((0.95, 0.93, 0.90), (0.9350, 0.9800, 0.9546)),
            ]
            let worst = cases.map { input, want in
                let got = LookMath.filmPrint(input)
                return max(abs(got.0 - want.0), abs(got.1 - want.1), abs(got.2 - want.2))
            }.max() ?? 1
            let good = worst < 0.002 && BuiltInLook.named("Film print") != nil
            log("FILM PRINT \(good ? "OK" : "FAIL") worst=\(String(format: "%.4f", worst))")
            ok = ok && good
        }
        // Copy and paste grade: the whole grade goes onto every selected visual clip (not sound), and
        // one undo puts them all back.
        do {
            var p = Project()
            let v = p.videoTracks[0].id, au = p.audioTracks[0].id
            var graded = Clip(trackID: v, kind: .solid, start: 0, duration: 2)
            var g = ColorGrade()
            g.look = "Warm film"
            g.lookIntensity = 0.6
            g.exposure = 0.4
            g.saturation = -12
            graded.grade = g
            var other = Clip(trackID: v, kind: .solid, start: 2, duration: 2)
            var og = ColorGrade()
            og.exposure = -1
            other.grade = og
            let plain = Clip(trackID: v, kind: .text, start: 4, duration: 2)
            let sound = Clip(trackID: au, kind: .audio, start: 0, duration: 2)
            p.clips = [graded, other, plain, sound]
            let m = EditorModel()
            m.load(p, url: nil)
            m.selection = [graded.id]
            let canCopy = m.canCopyGrade
            m.copyGrade()
            m.selection = [other.id, plain.id, sound.id]
            let canPaste = m.canPasteGrade
            m.pasteGrade()
            let pasted = m.project.clip(other.id)?.grade == g && m.project.clip(plain.id)?.grade == g && m.project.clip(sound.id)?.grade == nil
            m.undo()
            let undone = m.project.clip(other.id)?.grade == og && m.project.clip(plain.id)?.grade == nil
            let good = canCopy && canPaste && pasted && undone
            log("GRADE PASTE \(good ? "OK" : "FAIL") copy=\(canCopy) paste=\(canPaste) pasted=\(pasted) undo=\(undone)")
            ok = ok && good
        }
        // Export shapes: a vertical 9:16 export is 1080 × 1920, and moving the crop changes what's kept.
        do {
            var settings = ExportSettings()
            settings.includeAudio = false
            settings.height = 1080
            settings.shape = .vertical
            settings.reframe = CGPoint(x: 0.1, y: 0.5)
            let left = outDir.appendingPathComponent("vertical_left.mp4"), right = outDir.appendingPathComponent("vertical_right.mp4")
            _ = await export(project, media, settings, to: left)
            settings.reframe = CGPoint(x: 0.9, y: 0.5)
            _ = await export(project, media, settings, to: right)
            func probe(_ url: URL) async -> (CGSize, [UInt8]) {
                let a = AVURLAsset(url: url)
                let size = (try? await a.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
                let g = AVAssetImageGenerator(asset: a)
                g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
                g.maximumSize = CGSize(width: 90, height: 160)
                let cg = try? await g.image(at: CMTime(seconds: 1.0, preferredTimescale: 600)).image
                return (size, cg.flatMap { $0.dataProvider?.data as Data? }.map { Array($0) } ?? [])
            }
            let (ls, lb) = await probe(left), (rs, rb) = await probe(right)
            var d = 0.0
            if !lb.isEmpty, lb.count == rb.count { d = Double(zip(lb, rb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(lb.count) }
            let good = ls == CGSize(width: 1080, height: 1920) && rs == ls && d > 10
            log("SHAPES \(good ? "OK" : "FAIL") size=\(ls) leftVsRight=\(d)")
            ok = ok && good
        }
        // Auto planner: finds the beat of a 128 BPM track, cuts the test clips on its beats, never
        // reuses a moment, ends on a bar; the choreographed edits build exactly that cut, graded,
        // with a title.
        do {
            let rate = 22050.0, bpm = 128.0, seconds = 40.0
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let song = outDir.appendingPathComponent("beat128.caf")
            try? FileManager.default.removeItem(at: song)
            if let file = try? AVAudioFile(forWriting: song, settings: format.settings),
               let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)) {
                buf.frameLength = buf.frameCapacity
                let x = buf.floatChannelData![0]
                let period = 60 / bpm
                for i in 0..<Int(buf.frameLength) {
                    let t = Double(i) / rate
                    let beat = Int(t / period), into = t - Double(beat) * period
                    // A kick on every beat (harder on the first of each bar) and a quiet hat between.
                    let kick = exp(-into * 30) * sin(2 * .pi * 55 * into) * (beat % 4 == 0 ? 0.9 : 0.6)
                    let hatAt = into - period / 2
                    let hat = hatAt > 0 ? exp(-hatAt * 80) * Double.random(in: -0.15...0.15) : 0
                    x[i] = Float(kick + hat)
                }
                try? file.write(from: buf)
            }
            let music = await MediaAnalyzer.music(song)
            var clips: [(MediaAsset, ClipAnalysis)] = []
            for a in project.assets where a.kind == .video {
                if let c = await MediaAnalyzer.clip(a.url, kind: .video) { clips.append((a, c)) }
            }
            var songAsset = MediaAsset(path: song.path, name: "beat128", kind: .audio, duration: seconds, width: 0, height: 0, fps: 0, hasAudio: true)
            songAsset.duration = seconds
            var plan = project
            plan.clips = []
            plan.assets.append(songAsset)
            let decision = music.flatMap { m in AutoPlanner.decide(project: plan, clips: clips, music: (songAsset, m)) }
            var good = false
            var detail = "no plan"
            if let m = music, let d = decision, let dm = d.music {
                let tempoOK = abs(m.bpm - bpm) < 1.5
                let gaps = zip(m.beats.dropFirst(), m.beats).map { $0 - $1 }
                let steady = gaps.allSatisfy { abs($0 - 60 / bpm) < 0.03 }
                    // On the kicks, not between them.
                    && m.beats.allSatisfy { b in
                        let off = b.truncatingRemainder(dividingBy: 60 / bpm)
                        return min(off, 60 / bpm - off) < 0.04
                    }
                // Every cut is on a beat of the song.
                var at = 0.0
                var onBeat = true
                for s in d.shots {
                    at += s.duration
                    let songTime = dm.source + at
                    onBeat = onBeat && m.beats.contains { abs($0 - songTime) < 0.002 }
                }
                let firstBeat = m.beats.firstIndex { abs($0 - dm.source) < 0.002 } ?? -1
                let lastBeat = m.beats.firstIndex { abs($0 - (dm.source + at)) < 0.002 } ?? -1
                // Bars start on the accented kick.
                let barTime = m.beats[m.barPhase].truncatingRemainder(dividingBy: 4 * 60 / bpm)
                let downbeatOK = min(barTime, 4 * 60 / bpm - barTime) < 0.04
                let onBar = downbeatOK && firstBeat >= 0 && m.isBarStart(firstBeat) && (lastBeat - firstBeat) % 4 == 0
                let inside = d.shots.allSatisfy { $0.source >= 0 && $0.source + $0.duration <= $0.asset.duration + 0.001 }
                var clash = false
                for (i, a) in d.shots.enumerated() {
                    for b in d.shots[(i + 1)...] where a.asset.id == b.asset.id {
                        if a.source < b.source + b.duration && b.source < a.source + a.duration { clash = true }
                    }
                }
                // The choreographed edits, all done, make that cut.
                var built = false
                if let choreo = Choreographer.plan(project: plan, decision: d) {
                    var p = choreo.base
                    for t in choreo.tasks { t.edit.apply(&p, 1) }
                    let v1 = p.videoTracks[0].id
                    let shots = p.clips.filter { $0.trackID == v1 }.sorted { $0.start < $1.start }
                    let gapless = zip(shots.dropFirst(), shots).allSatisfy { abs($0.start - $1.end) < 1e-6 }
                    built = shots.count == d.shots.count && gapless && shots.allSatisfy { ($0.grade?.look ?? "") == d.look }
                        // No title unless one was asked for.
                        && (d.title.isEmpty ? !p.clips.contains { $0.kind == .text } : p.clips.contains { $0.kind == .text && $0.text.string == d.title })
                        && LocalBrain.titleAsked("make a fast cut") == nil && LocalBrain.titleAsked("add a title") == ""
                        && LocalBrain.titleAsked("put a title saying \"Summer '26\" on it")?.hasPrefix("Summer") == true
                        && LocalBrain.titleAsked("make it without a title") == nil
                        && LocalTitle.atEnd("make a 18s video using all the media. add title at end \"Novemeber 23\"")
                        && LocalTitle.atEnd("put an end card on it") && !LocalTitle.atEnd("add a title saying \"Weekend\"")
                        && p.clips.contains { $0.assetID == songAsset.id }
                }
                good = tempoOK && steady && onBeat && onBar && inside && !clash && built && d.shots.count >= 2
                detail = String(format: "bpm=%.1f beats=%d steady=%@ shots=%d onBeat=%@ onBar=%@ inside=%@ clash=%@ built=%@",
                                m.bpm, m.beats.count, "\(steady)", d.shots.count, "\(onBeat)", "\(onBar)", "\(inside)", "\(clash)", "\(built)")
            }
            log("AUTO PLAN \(good ? "OK" : "FAIL") \(detail)")
            ok = ok && good
        }
        // MCP tools: an agent adds two clips, trims, splits, grades, adds a dissolve and deletes with
        // ripple; each call is one undo step; bad input is a clear error, not a crash.
        do {
            let m = EditorModel()
            var p = Project()
            p.assets = project.assets.filter { $0.kind == .video }
            m.load(p, url: nil)
            func call(_ name: String, _ args: [String: Any]) async -> (Any?, String?) {
                do {
                    let out = try await MCPTools.call(name, args, model: m, client: nil)
                    let text = out.first?["text"] as? String ?? ""
                    return (try? JSONSerialization.jsonObject(with: Data(text.utf8)), nil)
                } catch {
                    return (nil, (error as? MCPToolError)?.message ?? "\(error)")
                }
            }
            var good = false
            var detail = ""
            if let asset = p.assets.first(where: { $0.hasAudio && $0.duration >= 4 }) {
                let (a, _) = await call("add_clip", ["asset_id": asset.id.uuidString, "duration": 3.0])
                let (b, _) = await call("add_clip", ["asset_id": asset.id.uuidString, "source_start": 1.0, "duration": 2.0])
                let first = ((a as? [String: Any])?["added"] as? [[String: Any]])?.first?["id"] as? String ?? ""
                let second = ((b as? [String: Any])?["added"] as? [[String: Any]])?.first?["id"] as? String ?? ""
                _ = await call("trim_clip", ["clip_id": first, "end": 2.5])
                _ = await call("set_transition", ["clip_id": second, "kind": "dissolve", "duration": 0.4])
                _ = await call("set_grade", ["clip_ids": [second], "look": "Mono", "exposure": 0.3])
                let (split, _) = await call("split_clip", ["clip_id": second, "at": 4.0])
                let right = ((split as? [String: Any])?["right"] as? [[String: Any]])?.first?["id"] as? String ?? ""
                _ = await call("delete_clips", ["clip_ids": [right], "ripple": true])
                let (_, bad) = await call("move_clip", ["clip_id": "nope", "start": 1.0])
                let q = m.project
                let v1 = q.clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }
                let shapeOK = v1.count == 2 && abs(v1[0].end - 2.5) < 1e-6 && abs(v1[1].start - 3) < 1e-6 && abs(v1[1].end - 4) < 1e-6
                let gradeOK = v1.last?.grade?.look == "Mono" && abs((v1.last?.grade?.exposure ?? 0) - 0.3) < 1e-9
                let audioOK = q.clips.filter { $0.kind == .audio }.count == 2
                // Seven changes, seven undos back to empty.
                for _ in 0..<7 { m.undo() }
                let undoOK = m.project.clips.isEmpty
                good = shapeOK && gradeOK && audioOK && undoOK && bad != nil
                detail = "v1=\(v1.map { "\($0.start)-\($0.end)" }) grade=\(gradeOK) audio=\(audioOK) undo=\(undoOK) error=\(bad ?? "none")"
            }
            log("MCP TOOLS \(good ? "OK" : "FAIL") \(detail)")
            ok = ok && good
        }
        // The newer MCP tools: markers and in/out, reframing, title style, solids, freeze, reverse, detach,
        // duplicate, track switches, search and export; each change one undo step; export refused in Magic.
        do {
            let m = EditorModel()
            var p = Project()
            p.assets = project.assets.filter { $0.kind == .video }
            m.load(p, url: nil)
            m.setExportTarget(name: "selftest", directory: outDir.path)
            func call(_ name: String, _ args: [String: Any], draft: MCPDraft? = nil) async -> (Any?, String?) {
                do {
                    let out = try await MCPTools.call(name, args, model: m, client: nil, draft: draft)
                    let text = out.first?["text"] as? String ?? ""
                    return (try? JSONSerialization.jsonObject(with: Data(text.utf8)), nil)
                } catch {
                    return (nil, (error as? MCPToolError)?.message ?? "\(error)")
                }
            }
            func id(_ r: Any?) -> String {
                if let d = r as? [String: Any] {
                    if let added = d["added"] as? [[String: Any]] { return added.first?["id"] as? String ?? "" }
                    if let added = d["added"] as? [String: Any] { return added["id"] as? String ?? "" }
                    return d["id"] as? String ?? ""
                }
                return (r as? [[String: Any]])?.first?["id"] as? String ?? ""
            }
            var checks: [String: Bool] = [:]
            if let asset = p.assets.first(where: { $0.hasAudio && $0.duration >= 4 }) {
                let a = id(await call("add_clip", ["asset_id": asset.id.uuidString, "duration": 3.0]).0)
                let aID = UUID(uuidString: a)
                // Markers and in/out.
                let mk = id(await call("set_marker", ["time": 1.0, "name": "Beat", "color": "red"]).0)
                _ = await call("set_marker", ["marker_id": mk, "name": "Drop"])
                _ = await call("set_marker", ["time": 2.0])
                checks["markers"] = m.project.markerList.map(\.name) == ["Drop", "Marker 2"] && m.project.markerList.first?.tint == .red
                _ = await call("delete_markers", ["marker_ids": [mk]])
                checks["delete"] = m.project.markerList.count == 1
                _ = await call("set_in_out", ["in": 0.5, "out": 2.5])
                checks["in_out"] = m.project.playRange.map { abs($0.start - 0.5) < 0.02 && abs($0.end - 2.5) < 0.02 } ?? false
                // Reframing, a styled title, a solid.
                _ = await call("set_transform", ["clip_id": a, "scale": 1.5, "x": 0.1])
                checks["transform"] = m.project.clip(aID ?? UUID())?.transform.map { $0.scale == 1.5 && $0.x == 0.1 } ?? false
                let t = id(await call("add_title", ["text": "Hi", "start": 0.0, "duration": 1.0]).0)
                let (_, badFont) = await call("set_title_style", ["clip_id": t, "font": "No Such Font Anywhere"])
                _ = await call("set_title_style", ["clip_id": t, "text": "Hello", "size": 80.0, "color": "#FF0000", "x": 0.3, "bold": false])
                let title = UUID(uuidString: t).flatMap { m.project.clip($0) }
                checks["title"] = title.map { $0.text.string == "Hello" && $0.text.size == 80 && $0.text.color.r == 1 && $0.text.color.g == 0 && $0.text.x == 0.3 && !$0.text.bold } ?? false
                checks["bad_font"] = badFont != nil
                if checks["title"] != true, let tt = title { log("MCP MORE title: \(tt.text.string) size \(tt.text.size) colour \(MCPTools.hex(tt.text.color)) x \(tt.text.x) bold \(tt.text.bold)") }
                let s = id(await call("add_solid", ["color": "#112233", "start": 5.0, "duration": 1.0]).0)
                _ = await call("set_solid_color", ["clip_id": s, "color": "#445566"])
                checks["solid"] = UUID(uuidString: s).flatMap { m.project.clip($0) }.map { $0.kind == .solid && MCPTools.hex($0.color) == "#445566" } ?? false
                // Captions from the clip's speech, styled; then the track taken away.
                let (_, capErr) = await call("set_captions", ["clip_ids": [a], "size": 80.0, "highlight": false])
                checks["captions"] = capErr == nil && m.project.captions?.style.size == 80 && m.project.captions?.style.highlight == false
                    && m.project.captionedClips.count == 1
                if checks["captions"] != true { log("MCP MORE captions: \(capErr ?? "-")") }
                _ = await call("set_captions", ["remove": true])
                checks["captions_off"] = m.project.captions == nil && m.project.captionedClips.isEmpty
                // Freeze, reverse, detach, duplicate.
                let videoBefore = m.project.clips.filter { $0.kind == .video }.map(\.end).max() ?? 0
                _ = await call("freeze_frame", ["clip_id": a, "at": 1.0, "seconds": 1.0])
                let videoAfter = m.project.clips.filter { $0.kind == .video }.map(\.end).max() ?? 0
                checks["freeze"] = m.project.clips.contains { $0.isFreeze } && abs(videoAfter - videoBefore - 1) < 0.05
                _ = await call("reverse_clip", ["clip_id": a])
                checks["reverse"] = m.project.clip(aID ?? UUID())?.playsBackwards == true
                _ = await call("detach_audio", ["clip_id": a])
                checks["detach"] = m.project.clip(aID ?? UUID())?.linkID == nil
                _ = await call("duplicate_clip", ["clip_id": a, "start": 12.0])
                checks["duplicate"] = m.project.clips.contains { $0.kind == .video && abs($0.start - 12) < 0.02 }
                // Track switches.
                _ = await call("set_track", ["track": "A1", "muted": true, "gain_db": -3.0])
                checks["track"] = m.project.audioTracks.first.map { $0.muted && $0.gainDB == -3 } ?? false
                // Search: nothing shows a made-up word; asking for nothing is an error.
                let (found, _) = await call("search_media", ["shows": "zzqqxx"])
                let (_, empty) = await call("search_media", [:])
                checks["search"] = ((found as? [String: Any])?["found"] as? [Any])?.isEmpty == true && empty != nil
                // Export: a small file, waited for, in the folder set for it; refused during Magic.
                let draft = MCPDraft.open(m.project)
                let (_, refused) = await call("export", ["name": "mcp-export"], draft: draft)
                draft.close()
                let (made, exportError) = await call("export", ["name": "mcp-export", "height": 360, "wait": true])
                let file = (made as? [String: Any])?["file"] as? String ?? ""
                checks["export"] = exportError == nil && (made as? [String: Any])?["status"] as? String == "done" && FileManager.default.fileExists(atPath: file)
                    && file.hasPrefix(outDir.path)
                checks["export_refused_in_magic"] = refused != nil
                try? FileManager.default.removeItem(atPath: file)
                // Every change undoes: back to an empty timeline with no markers or range.
                for _ in 0..<40 where m.canUndo { m.undo() }
                checks["undo"] = m.project.clips.isEmpty && m.project.markers == nil && m.project.playRange == nil
            }
            let good = !checks.isEmpty && checks.values.allSatisfy { $0 }
            log("MCP MORE \(good ? "OK" : "FAIL") " + checks.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            ok = ok && good
        }
        // Magic with an AI: its calls edit a hidden draft and leave the timeline alone; its edits,
        // played back in any order their dependencies allow, make exactly the draft.
        do {
            let m = EditorModel()
            var p = Project()
            p.assets = project.assets.filter { $0.kind == .video }
            m.load(p, url: nil)
            let before = m.project
            let draft = MCPDraft.open(m.project)
            defer { draft.close() }
            func call(_ name: String, _ args: [String: Any]) async -> (Any?, String?) {
                do {
                    let out = try await MCPTools.call(name, args, model: m, client: nil, draft: draft)
                    let text = out.first?["text"] as? String ?? ""
                    return (try? JSONSerialization.jsonObject(with: Data(text.utf8)), nil)
                } catch {
                    return (nil, (error as? MCPToolError)?.message ?? "\(error)")
                }
            }
            var good = false
            var detail = "no video with sound"
            if let asset = p.assets.first(where: { $0.hasAudio && $0.duration >= 4 }) {
                func added(_ r: Any?) -> String { ((r as? [String: Any])?["added"] as? [[String: Any]])?.first?["id"] as? String ?? "" }
                let a = added(await call("add_clip", ["asset_id": asset.id.uuidString, "duration": 3.0]).0)
                let b = added(await call("add_clip", ["asset_id": asset.id.uuidString, "source_start": 1.0, "duration": 2.0]).0)
                let c = added(await call("add_clip", ["asset_id": asset.id.uuidString, "source_start": 0.5, "duration": 1.5]).0)
                _ = await call("trim_clip", ["clip_id": a, "start": 0.5])
                _ = await call("set_grade", ["clip_ids": [b], "look": "Mono", "exposure": 0.2])
                _ = await call("add_title", ["text": "Hello", "start": 0.0, "duration": 1.5])
                _ = await call("set_transition", ["clip_id": b, "kind": "dissolve"])
                _ = await call("move_clip", ["clip_id": c, "start": 8.0])
                _ = await call("history", ["action": "undo"])   // takes back the move
                _ = await call("set_audio", ["clip_id": c, "gain_db": -12.0, "fade_out": 0.5])
                let (sped, speedError) = await call("set_speed", ["clip_id": b, "speed": 4.0])
                // Then a slow-motion moment in that sped-up clip (file 1–3): 25% from 1.5 to 2.2s, 400% around it.
                let (_, rampError) = await call("set_speed_ramp", ["clip_id": b, "speed": 0.25, "from": 1.5, "to": 2.2, "ease": 0.2, "around": 4.0])
                _ = await call("set_sequence", ["width": 1080, "height": 1920])
                _ = await call("delete_clips", ["clip_ids": [a], "ripple": true])
                // Two ripple deletes in a row: played as plain deletes side by side, then "Close gaps".
                _ = await call("delete_clips", ["clip_ids": [c], "ripple": true])
                let (_, refused) = await call("save_project", [:])
                let (_, frameError) = await call("get_frame", ["time": 1.0])
                let untouched = m.project == before
                let target = draft.project
                let plan = MCPDraft.plan(base: before, edits: draft.edits)
                // Played in order, and in shuffled orders that respect the dependencies.
                var orders: [[Int]] = [Array(plan.tasks.indices)]
                var rng = SeededRandom(seed: 7)
                for _ in 0..<20 {
                    var done = Set<Int>(), order: [Int] = []
                    while order.count < plan.tasks.count {
                        let ready = plan.tasks.indices.filter { !done.contains($0) && plan.tasks[$0].after.allSatisfy(done.contains) }
                        let pick = ready[Int(rng.next() * Double(ready.count)) % ready.count]
                        order.append(pick)
                        done.insert(pick)
                    }
                    orders.append(order)
                }
                // The order clips are listed in doesn't matter, only the clips.
                func same(_ x: Project, _ y: Project) -> Bool {
                    var x = x, y = y
                    x.clips.sort { $0.id.uuidString < $1.id.uuidString }
                    y.clips.sort { $0.id.uuidString < $1.id.uuidString }
                    return x == y
                }
                let failing = orders.indices.filter { k in
                    var q = before
                    for i in orders[k] { plan.tasks[i].edit.apply(&q, 1) }
                    if !same(q, target), k < 3 || CommandLine.arguments.contains("--verbose") {
                        let diff = q.clips.filter { c in target.clip(c.id) != c }.map { c in "\(c.kind.rawValue)@\(c.start)-\(c.end) vs \(target.clip(c.id).map { "\($0.start)-\($0.end)" } ?? "gone")" }
                        log("  order \(k) \(orders[k]) differs: \(diff) counts \(q.clips.count)/\(target.clips.count) after=\(plan.tasks.map(\.after)) labels=\(plan.tasks.map { $0.edit.label(1) })")
                    }
                    return !same(q, target)
                }
                let replayOK = failing.isEmpty
                let parallel = plan.tasks.filter { $0.after.isEmpty }.count
                let shapeOK = target.width == 1080 && target.clips.contains { $0.kind == .text && $0.text.string == "Hello" }
                    && target.clip(UUID(uuidString: c)!)?.start ?? 0 < 8 && target.clip(UUID(uuidString: a)!) == nil
                let ramped = target.clip(UUID(uuidString: b)!)
                let rampOK = rampError == nil && ramped?.isRamped == true && ramped?.speed == 0.25
                    && abs((ramped?.ramp?.inTo ?? 0) - 1.5) < 1e-3 && abs((ramped?.ramp?.outFrom ?? 0) - 2.2) < 1e-3
                    && abs((ramped.map { $0.speed(atSource: $0.sourceStart) } ?? 0) - 4) < 1e-6
                let speedOK = speedError == nil && sped != nil && rampOK
                good = untouched && replayOK && shapeOK && speedOK && refused != nil && frameError == nil && parallel > 1
                detail = "speed=\(speedOK) ramp=\(rampOK)\(rampError.map { " " + $0 } ?? "") untouched=\(untouched) replay=\(replayOK) failing=\(failing.count)/\(orders.count) shape=\(shapeOK) edits=\(plan.tasks.count) startFree=\(parallel) refused=\(refused != nil)"
            }
            log("MAGIC DRAFT \(good ? "OK" : "FAIL") \(detail)")
            ok = ok && good
        }
        // Connect buttons, against a throwaway home folder: Codex's settings keep every other line,
        // and the Claude extension holds a valid manifest and its launcher.
        do {
            let fm = FileManager.default
            let fake = outDir.appendingPathComponent("connect-home", isDirectory: true)
            try? fm.removeItem(at: fake)
            try? fm.createDirectory(at: fake.appendingPathComponent(".codex"), withIntermediateDirectories: true)
            let original = """
            model = "x"

            [mcp_servers.other]
            command = "other"

            [mcp_servers.editroom]
            command = "old"

            [mcp_servers.editroom.env]
            A = "1"

            [features]
            js_repl = false
            """
            let config = fake.appendingPathComponent(".codex/config.toml")
            try? original.write(to: config, atomically: true, encoding: .utf8)
            let c = AgentConnect.shared
            let realHome = c.home
            c.home = fake
            c.openInClaude = false
            defer { c.home = realHome; c.openInClaude = true }
            var good = true
            var detail = ""
            do {
                try c.connectCodex()
                let on = try String(contentsOf: config, encoding: .utf8)
                let sections = on.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
                let codexOK = c.codexConnected && on.contains("command = \"other\"") && on.contains("js_repl = false")
                    && !on.contains("\"old\"") && !on.contains("A = \"1\"")
                    && sections == ["[mcp_servers.other]", "[features]", "[mcp_servers.editroom]"]
                try c.disconnectCodex()
                let off = try String(contentsOf: config, encoding: .utf8)
                let offOK = !c.codexConnected && off.contains("[mcp_servers.other]") && off.contains("[features]")
                let backupOK = fm.fileExists(atPath: fake.appendingPathComponent(".codex/config.toml.before-editroom").path)

                let mcpb = try c.makeClaudeExtension()
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                let out = fake.appendingPathComponent("unzipped")
                unzip.arguments = ["-qo", mcpb.path, "-d", out.path]
                try unzip.run(); unzip.waitUntilExit()
                let manifest = (try? Data(contentsOf: out.appendingPathComponent("manifest.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let server = manifest["server"] as? [String: Any]
                let launcher = out.appendingPathComponent("server/editroom-mcp")
                let script = (try? String(contentsOf: launcher, encoding: .utf8)) ?? ""
                let claudeOK = manifest["name"] as? String == "editroom" && manifest["manifest_version"] as? String == "0.3"
                    && server?["type"] as? String == "binary" && (manifest["tools"] as? [Any])?.count == MCPTools.definitions.count
                    && script.contains("--mcp") && fm.isExecutableFile(atPath: launcher.path)
                    && fm.fileExists(atPath: out.appendingPathComponent("icon.png").path)
                // The launcher really reaches the server (which answers on this thread, so wait elsewhere).
                MCPServer.shared.start()
                try? await Task.sleep(nanoseconds: 300_000_000)
                let path = launcher.path
                let reply: String = await Task.detached {
                    let probe = Process()
                    probe.executableURL = URL(fileURLWithPath: "/bin/sh")
                    probe.arguments = [path]
                    let input = Pipe(), output = Pipe()
                    probe.standardInput = input
                    probe.standardOutput = output
                    do { try probe.run() } catch { return "" }
                    input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-ai"}}}"#.utf8 + [10]))
                    try? input.fileHandleForWriting.close()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    probe.waitUntilExit()
                    return String(data: data, encoding: .utf8) ?? ""
                }.value
                let launchOK = reply.contains("\"editroom\"")
                good = codexOK && offOK && backupOK && claudeOK && launchOK
                detail = "codex=\(codexOK) off=\(offOK) backup=\(backupOK) claude=\(claudeOK) launcher=\(launchOK)"
            } catch {
                good = false
                detail = error.localizedDescription
            }
            log("AGENT CONNECT \(good ? "OK" : "FAIL") \(detail)")
            ok = ok && good
        }
        // Downloading music for an agent: audio is kept (with its source noted), anything else refused.
        do {
            let folder = outDir.appendingPathComponent("download-test", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            let song = project.assets.first { $0.kind == .audio }?.url ?? project.assets.first { $0.kind == .video && $0.hasAudio }?.url
            let page = outDir.appendingPathComponent("page.html")
            try? "<html>not audio</html>".write(to: page, atomically: true, encoding: .utf8)
            var good = false
            var detail = "no audio to test with"
            if let song {
                let kept = try? await MediaDownload.fetch(song, name: "Test: Track/One", sourcePage: "https://example.com/track",
                                                          licence: "CC0, no attribution", into: folder, allowFiles: true)
                var refusedPage = false
                do { _ = try await MediaDownload.fetch(page, name: nil, sourcePage: nil, licence: nil, into: folder, allowFiles: true) }
                catch { refusedPage = true }
                var refusedHTTP = false
                do { _ = try await MediaDownload.fetch(URL(string: "http://example.com/a.mp3")!, name: nil, sourcePage: nil, licence: nil, into: folder) }
                catch { refusedHTTP = true }
                let notes = (try? String(contentsOf: folder.appendingPathComponent("Sources.txt"), encoding: .utf8)) ?? ""
                let keptOK = kept.map { FileManager.default.fileExists(atPath: $0.path) && $0.lastPathComponent.hasPrefix("Test  Track One") } ?? false
                let notesOK = notes.contains("CC0, no attribution") && notes.contains("https://example.com/track")
                let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("page") }
                good = keptOK && notesOK && refusedPage && refusedHTTP && leftovers.isEmpty
                detail = "kept=\(keptOK) notes=\(notesOK) refusedPage=\(refusedPage) refusedHTTP=\(refusedHTTP) leftovers=\(leftovers.count)"
            }
            log("DOWNLOAD \(good ? "OK" : "FAIL") \(detail)")
            ok = ok && good
        }
        // Deleting from the Media panel: picked items go (with Delete), and one Undo brings them back.
        do {
            let m = EditorModel()
            var p = Project()
            p.assets = project.assets
            m.load(p, url: nil)
            let ids = p.assets.prefix(2).map(\.id)
            m.mediaSelection = Set(ids)
            m.deleteSelected()
            let gone = ids.allSatisfy { id in m.project.asset(id) == nil } && m.mediaSelection.isEmpty
            m.undo()
            let back = ids.allSatisfy { id in m.project.asset(id) != nil } && m.project.assets.count == p.assets.count
            m.redo()
            let again = ids.allSatisfy { id in m.project.asset(id) == nil } && m.project.assets.count == p.assets.count - 2
            let good = ids.count == 2 && gone && back && again
            log("MEDIA DELETE \(good ? "OK" : "FAIL") gone=\(gone) undo=\(back) redo=\(again)")
            ok = ok && good
        }
        // Local Magic on an edit: repeats out, long shots trimmed, cuts on the beat, ends on a bar, no gaps,
        // the song trimmed to fit, and a doubled title out.
        do {
            func video(_ name: String) -> MediaAsset {
                MediaAsset(path: "/tmp/\(name).mov", name: name, kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: false)
            }
            let a = video("A"), b = video("B")
            let songAsset = MediaAsset(path: "/tmp/song.m4a", name: "Song", kind: .audio, duration: 60, width: 0, height: 0, fps: 0, hasAudio: true)
            var p = Project()
            p.assets = [a, b, songAsset]
            while p.videoTracks.count < 2 { p.videoTracks.append(Track(kind: .video)) }
            let v1 = p.videoTracks[0].id, v2 = p.videoTracks[1].id, a1 = p.audioTracks[0].id
            func shot(_ asset: MediaAsset, _ start: Double, _ length: Double, src: Double) -> Clip {
                var c = Clip(trackID: v1, kind: .video, assetID: asset.id, start: start, duration: length)
                c.sourceStart = src
                return c
            }
            p.clips = [shot(a, 0, 5, src: 0), shot(b, 5, 5, src: 0), shot(a, 10, 5, src: 0.5), shot(b, 15, 2, src: 6)]
            p.clips.append(Clip(trackID: a1, kind: .audio, assetID: songAsset.id, start: 0, duration: 30))
            var t1 = Clip(trackID: v2, kind: .text, start: 0, duration: 2); t1.text.string = "Hi"
            p.addTrack(.video)
            var t2 = Clip(trackID: p.videoTracks[2].id, kind: .text, start: 0, duration: 2); t2.text.string = "Hi"
            p.clips += [t1, t2]
            // Sharp in the middle of each file, soft at the ends.
            func analysis() -> ClipAnalysis {
                ClipAnalysis(duration: 10, created: nil, samples: stride(from: 0.0, through: 10, by: 0.25).map { t in
                    ClipAnalysis.Sample(time: t, luma: 0.45, sharpness: 400 - 30 * abs(t - 5) * abs(t - 5), motion: 0.01, color: 0.3, faces: 0)
                })
            }
            let music = MusicAnalysis(duration: 60, bpm: 120, beats: stride(from: 0.0, to: 60, by: 0.5).map { $0 }, barPhase: 0,
                                      energy: Array(repeating: 0.5, count: 120))
            var good = false
            var detail = "no plan"
            if let outcome = LocalImprover.plan(project: p, analyses: [a.id: analysis(), b.id: analysis()], music: music) {
                var q = p
                for task in outcome.plan.tasks { task.edit.apply(&q, 1) }
                let kept = q.clips.filter { $0.trackID == v1 }.sorted { $0.start < $1.start }
                let gapless = zip(kept, kept.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-6 } && abs((kept.first?.start ?? 1)) < 1e-6
                let onBeats = kept.allSatisfy { abs(($0.end * 2).rounded() - $0.end * 2) < 1e-6 }
                let end = kept.last?.end ?? 0
                let onBar = abs((end / 2).rounded() - end / 2) < 1e-6
                let repeatsOut = kept.filter { $0.assetID == a.id }.count == 1
                let trimmed = kept.allSatisfy { $0.duration <= 4.5 + 1e-6 }
                let song = q.clips.first { $0.assetID == songAsset.id }
                let songFits = song.map { abs($0.end - end) < 1e-6 && $0.fadeOut > 0 } ?? false
                let titleOnce = q.clips.filter { $0.kind == .text }.count == 1
                good = gapless && onBeats && onBar && repeatsOut && trimmed && songFits && titleOnce
                detail = "\(outcome.summary) | gapless=\(gapless) beats=\(onBeats) bar=\(onBar) repeats=\(repeatsOut) trimmed=\(trimmed) song=\(songFits) title=\(titleOnce) cuts=\(kept.map { $0.end })"
            }
            // And following a recipe: 4 seconds, fast, Mono, no music, vertical.
            var recipe = LocalRecipe()
            recipe.seconds = 4
            recipe.pace = .fast
            recipe.look = "Mono"
            recipe.music = .off
            recipe.frame = .vertical
            if let outcome = LocalImprover.plan(project: p, analyses: [a.id: analysis(), b.id: analysis()], music: nil, recipe: recipe) {
                var q = p
                for task in outcome.plan.tasks { task.edit.apply(&q, 1) }
                let kept = q.clips.filter { $0.trackID == v1 }
                let length = (kept.map(\.end).max() ?? 0) - (kept.map(\.start).min() ?? 0)
                let recipeOK = length <= 4.05 && length >= 2 && kept.allSatisfy { $0.grade?.look == "Mono" }
                    && q.width == 1080 && q.height == 1920 && !q.clips.contains { $0.assetID == songAsset.id }
                good = good && recipeOK
                detail += " | recipe=\(recipeOK) length=\(length) \(outcome.summary)"
            } else {
                good = false
                detail += " | recipe: no plan"
            }
            // Longer than the edit is now (after repeats come out): shots grow into their files, with no
            // gaps or overlaps, cuts on the beat, ending near the length asked for.
            var longer = LocalRecipe()
            longer.seconds = 25
            if let outcome = LocalImprover.plan(project: p, analyses: [a.id: analysis(), b.id: analysis()], music: music, recipe: longer) {
                var q = p
                for task in outcome.plan.tasks { task.edit.apply(&q, 1) }
                let kept = q.clips.filter { $0.trackID == v1 }.sorted { $0.start < $1.start }
                let end = kept.last?.end ?? 0
                let gapless = zip(kept, kept.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-6 }
                let inFiles = kept.allSatisfy { $0.sourceStart >= -1e-6 && $0.sourceStart + $0.duration * $0.speed <= 10 + 1e-6 }
                let longOK = kept.count == 3 && gapless && inFiles && abs(end - 25) <= 2 && outcome.notes.isEmpty
                good = good && longOK
                detail += " | longer=\(longOK) end=\(end) \(outcome.summary)"
            } else {
                good = false
                detail += " | longer: no plan"
            }
            // Named media: "i only want img_1607 video. nothing else on timeline" keeps just that file's shots
            // (both copies: nothing else unasked), closes the gaps, and clears titles and music.
            let lib = [MediaAsset(path: "/tmp/IMG_1607.MOV", name: "IMG_1607", kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: false),
                       MediaAsset(path: "/tmp/IMG_1818.MOV", name: "IMG_1818", kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: false)]
            let ask = "i only want img_1607 video. nothing else on timeline"
            let found = LocalBrain.named(in: ask, media: lib)
            var onlyA = LocalRecipe()
            LocalBrain.applyMedia(&onlyA, named: [a], action: "unchanged", request: ask)
            let readOK = found.map(\.name) == ["IMG_1607"] && LocalBrain.named(in: "take out 1818", media: lib).map(\.name) == ["IMG_1818"]
                && onlyA.keepOnly == [a.id] && onlyA.clearRest
            if let outcome = LocalImprover.plan(project: p, analyses: [a.id: analysis(), b.id: analysis()], music: music, recipe: onlyA) {
                var q = p
                for task in outcome.plan.tasks { task.edit.apply(&q, 1) }
                let kept = q.clips.filter { $0.trackID == v1 }.sorted { $0.start < $1.start }
                let onlyOK = readOK && kept.count == 2 && kept.allSatisfy { $0.assetID == a.id } && abs(kept[0].start) < 1e-6
                    && abs(kept[0].end - kept[1].start) < 1e-6 && abs(kept[1].duration - 5) < 1e-6
                    && !q.clips.contains { $0.kind == .text } && !q.clips.contains { $0.assetID == songAsset.id }
                good = good && onlyOK
                detail += " | only=\(onlyOK) read=\(readOK) \(outcome.summary)"
            } else {
                good = false
                detail += " | only: no plan (read=\(readOK))"
            }
            // Sound effects: a whoosh from the library leads into every cut, on a track of its own.
            var withFX = p
            let whoosh = MediaAsset(path: "/tmp/Whoosh 1.wav", name: "Whoosh 1", kind: .audio, duration: 1, width: 0, height: 0, fps: 0, hasAudio: true)
            withFX.assets.append(whoosh)
            var fx = LocalRecipe()
            fx.soundEffects = true
            fx.onlyAsked = true
            if let outcome = LocalImprover.plan(project: withFX, analyses: [a.id: analysis(), b.id: analysis()], music: music, recipe: fx) {
                var q = withFX
                for task in outcome.plan.tasks { task.edit.apply(&q, 1) }
                let placed = q.clips.filter { $0.assetID == whoosh.id }.sorted { $0.start < $1.start }
                let cutsNow = q.clips.filter { $0.trackID == v1 }.map(\.end).sorted().dropLast()
                let leadIn = placed.count == cutsNow.count && zip(placed, cutsNow).allSatisfy { $0.start < $1 && $0.end > $1 - 1e-6 }
                let ownTrack = Set(placed.map(\.trackID)).count == 1 && !q.clips.contains { c in placed.first.map { c.trackID == $0.trackID && c.assetID != whoosh.id } ?? false }
                let fxOK = !placed.isEmpty && leadIn && ownTrack
                good = good && fxOK
                detail += " | sfx=\(fxOK) placed=\(placed.count) \(outcome.summary)"
            } else {
                good = false
                detail += " | sfx: no plan"
            }
            // The request check: settings the request doesn't mention are dropped (the on-device model over-fills).
            var noisy = LocalRecipe()
            noisy.seconds = 20; noisy.pace = .calm; noisy.look = "none"; noisy.music = .off; noisy.frame = .square
            noisy.cannotDo = "find new music, sound effects"
            let checked = LocalBrain.checked(noisy, against: "add sound effects and make it 20 seconds")
            let checkOK = checked.seconds == 20 && checked.pace == .unchanged && checked.look == nil && checked.music == .unchanged
                && checked.frame == .unchanged && checked.cannotDo == "sound effects"
            // A question with numbers in it isn't a length; real lengths in other wordings still are.
            var asked = LocalRecipe(); asked.seconds = 100
            let lengths = LocalBrain.checked(asked, against: "what's 5+5?").seconds == nil
                && LocalBrain.checked(asked, against: "make it 30s").seconds == 100
                && LocalBrain.checked(asked, against: "1:30 long cut").seconds == 100
                && LocalBrain.checked(asked, against: "length of 45").seconds == 100
            good = good && checkOK && lengths
            detail += " | check=\(checkOK) lengths=\(lengths)"
            // @ mentions: found by name (with or without the extension, any case), not inside an address;
            // in plain words for Apple's model; Local's direct edits on what they point at.
            do {
                let file = MediaAsset(path: "/tmp/IMG_1607.MOV", name: "IMG_1607.MOV", kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: false)
                let lib = [file, MediaAsset(path: "/tmp/Beach day.mov", name: "Beach day.mov", kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: false)]
                let text = "Tighten @Selected, open on @img_1607 then @in-out and @Beach day.mov. me@x.com @nothing @playheads"
                let found = MagicMention.find(in: text, media: lib).map(\.mention)
                let findOK = found == [.selected, .media(file.id), .range, .media(lib[1].id)]
                    && MagicMention.find(in: "open on @media:img_1607 now", media: lib).map(\.mention) == [.media(file.id)]
                    && MagicMention.find(in: "open on @media:img_1607 now", media: lib).first?.range == NSRange(location: 8, length: 15)
                let plainOK = MagicMention.plain("cut @selected at @playhead with @IMG_1607", media: lib)
                    == "cut the selected clips at the playhead with IMG_1607.MOV"
                let first = p.clips.filter { $0.trackID == v1 }.min { $0.start < $1.start }!
                let ptr = MagicPointers(playhead: 7, selected: [first.id], range: (2, 4))
                func run(_ ask: String, _ r: LocalRecipe = LocalRecipe()) -> Project? {
                    guard let o = LocalPointed.plan(request: ask, recipe: r, pointers: ptr, project: p), let plan = o.plan else { return nil }
                    var q = plan.base
                    for task in plan.tasks { task.edit.apply(&q, 1) }
                    return q
                }
                let shots = { (q: Project) in q.clips.filter { $0.trackID == v1 }.sorted { $0.start < $1.start } }
                let removed = run("@selected is no good").map(shots) ?? []
                let removeOK = removed.count == 3 && !removed.contains { $0.id == first.id } && abs(removed[0].start) < 1e-6
                let ended = run("end it at @playhead").map(\.duration) ?? 0
                let endOK = abs(ended - 7) < 1e-6
                let cut = run("remove @in-out").map(shots) ?? []
                let rangeOK = cut.count == 5 && abs((cut.last?.end ?? 0) - 15) < 1e-6
                var mono = LocalRecipe(); mono.look = "Mono"
                let looked = run("make @selected black and white", mono)
                let lookOK = looked?.clips.first { $0.id == first.id }?.grade?.look == "Mono"
                    && looked?.clips.filter { $0.id != first.id && $0.grade?.look == "Mono" }.isEmpty == true
                let wholeOK = LocalPointed.plan(request: "make it shorter", recipe: LocalRecipe(), pointers: ptr, project: p) == nil
                let brief = MagicAgent.brief(request: "@selected is weak", project: p, pointers: ptr)
                let briefOK = brief.contains("@selected means exactly the selected clips") && brief.contains("Playhead: 7.00s")
                // Moving shots by name, and naming files on an edit never takes the others out.
                func order(_ ask: String) -> [UUID] {
                    guard let o = LocalPointed.plan(request: ask, recipe: LocalRecipe(), pointers: ptr, project: p), let plan = o.plan else { return [] }
                    var q = plan.base
                    for task in plan.tasks { task.edit.apply(&q, 1) }
                    return shots(q).compactMap(\.assetID)
                }
                let moveOK = order("put @B in front of @A") == [b.id, a.id, a.id, b.id]
                    && order("swap @A and @B") == [b.id, a.id, a.id, b.id]
                    && order("move @A to the end") == [b.id, a.id, b.id, a.id]
                var named = LocalRecipe()
                LocalBrain.applyMedia(&named, named: [a, b], action: "only", request: "put @B in front of @A", pointed: [a.id, b.id], hasEdit: true)
                let keepOK = named.keepOnly.isEmpty && named.takeOut.isEmpty
                // @clip: one clip in particular: named by file (·2 for the second use) or a title's words.
                let labels = MagicMention.clipLabels(p).map(\.name)
                let secondA = p.clips.filter { $0.assetID == a.id }.sorted { $0.start < $1.start }[1]
                let clipFind = MagicMention.find(in: "fix @clip:A·2 and @clip:Hi", media: p.assets, clips: MagicMention.clipLabels(p)).map(\.mention)
                let afterRemove = run("@clip:A·2 is no good").map(shots) ?? []
                let clipOK = labels.prefix(3) == ["Hi", "Hi·2", "A"] && labels.contains("A·2") && labels.contains("B·2")
                    && clipFind.first == .clip(secondA.id) && clipFind.count == 2
                    && afterRemove.count == 3 && !afterRemove.contains { $0.id == secondA.id } && afterRemove.contains { $0.id == first.id }
                    && order("put @clip:B·2 in front of @clip:A") == [b.id, a.id, b.id, a.id]
                // Typed times: the viewer's timecode (frames at the project's rate), m:ss, h:mm:ss; a span is a range.
                func near(_ x: Double?, _ y: Double) -> Bool { x.map { abs($0 - y) < 1e-6 } ?? false }
                let tc = MagicTimes.span(in: "between 00:00:05:15 and 00:00:06:00 find a better clip", fps: 30)
                let timeOK = near(tc?.start, 5.5) && near(tc?.end, 6)
                    && near(MagicTimes.span(in: "from 5s to 6.5 seconds", fps: 30)?.end, 6.5)
                    && near(MagicTimes.span(in: "cut 0:05 to 0:06", fps: 30)?.start, 5)
                    && MagicTimes.span(in: "make it 0:30 long", fps: 30) == nil
                    && MagicTimes.span(in: "make it 30s, fast", fps: 30) == nil
                    && near(MagicTimes.times(in: "at 1:02:30", fps: 30).first?.seconds, 3750)
                    && MagicTimes.times(in: "make it 0:30", fps: 30).map(\.seconds) == [30]
                let typedCut = run("remove between 0:02 and 0:04").map(shots) ?? []
                let typedOK = typedCut.count == 5 && abs((typedCut.last?.end ?? 0) - 15) < 1e-6
                    && MagicAgent.brief(request: "between 0:05 and 0:06 find a better clip", project: p, pointers: ptr).contains("is 5.00s to 6.00s on the timeline")
                // Speech: sentences, pauses and phrases from a transcript; Local cuts the pauses out of the
                // talking shots, the shot's own sound with it, and leaves the rest in sync.
                let said = Transcript(words: [.init(start: 1, end: 1.4, text: "Welcome"), .init(start: 1.4, end: 2, text: "back."),
                                              .init(start: 5, end: 5.5, text: "It's"), .init(start: 5.5, end: 6, text: "raining.")], language: "en_US")
                let speechOK = said.speech().count == 2 && said.sentences().map(\.text) == ["Welcome back.", "It's raining."]
                    && said.says("it's RAINING") && !said.says("raining it's")
                    && said.snippet("rai", typing: true).map { $0.match == "raining." && $0.before == "Welcome back. It's" } == true
                    && said.says("it's rai", typing: true) && !said.says("it's rai") && !said.says("welc raining", typing: true)
                var sp = Project()
                let talk = MediaAsset(path: "/tmp/talk.mov", name: "talk", kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: true)
                sp.assets = [talk]
                let sv1 = sp.videoTracks[0].id, sa1 = sp.audioTracks[0].id, link = UUID()
                var tv = Clip(trackID: sv1, kind: .video, assetID: talk.id, start: 0, duration: 10); tv.linkID = link
                var ta = Clip(trackID: sa1, kind: .audio, assetID: talk.id, start: 0, duration: 10); ta.linkID = link
                var broll = Clip(trackID: sv1, kind: .video, assetID: a.id, start: 10, duration: 3); broll.linkID = UUID()
                sp.clips = [tv, ta, broll]
                let cutPlan = LocalSpeech.plan(project: sp, only: nil) { $0 == talk.id ? said : Transcript(words: [], language: "") }
                var sq = cutPlan.plan?.base ?? sp
                for task in cutPlan.plan?.tasks ?? [] { task.edit.apply(&sq, 1) }
                let vids = sq.clips.filter { $0.trackID == sv1 }.sorted { $0.start < $1.start }
                let auds = sq.clips.filter { $0.trackID == sa1 }.sorted { $0.start < $1.start }
                // Kept: 0.88-2.2 and 4.88-6.2 of the talk (1.32s each), then the 3s b-roll untouched.
                let cutOK = vids.count == 3 && abs(vids[0].start) < 1e-6 && abs(vids[0].duration - 1.32) < 1e-6
                    && abs(vids[1].sourceStart - 4.88) < 1e-6 && abs(vids[2].start - 2.64) < 1e-6 && vids[2].assetID == a.id
                    && auds.count == 2 && zip(auds, vids).allSatisfy { abs($0.start - $1.start) < 1e-6 && abs($0.duration - $1.duration) < 1e-6 }
                    && LocalSpeech.asks("cut out all the dead space") && !LocalSpeech.asks("make it fast")
                // Scene tags: a word matches a tag (plural or not), and as it's typed.
                let tags = SceneTags(tags: [.init(name: "swimming pool", confidence: 0.8, times: [1]), .init(name: "chair", confidence: 0.6, times: [2])])
                let tagOK = tags.shows("pool") && tags.shows("chairs") && tags.shows("po", typing: true) && !tags.shows("po") && !tags.shows("beach")
                    && SceneTags(tags: [.init(name: "portal", confidence: 0.7, times: [])]).shows("door")
                    && SceneTags(tags: [.init(name: "adult", confidence: 0.7, times: [])]).shows("wom", typing: true)
                // Local's ramps: a slow-mo moment at the playhead in the talk shot; then ramps into the cut.
                let at5 = MagicPointers(playhead: 5, selected: [], range: nil)
                var rq = sp
                let moment = LocalRamp.plan(request: "speed ramp here", pointers: at5, project: sp)
                for task in moment.plan?.tasks ?? [] { task.edit.apply(&rq, 1) }
                let rt = rq.clip(tv.id)
                var cq = sp
                let cutsPlan = LocalRamp.plan(request: "ramp into the cuts", pointers: at5, project: sp)
                for task in cutsPlan.plan?.tasks ?? [] { task.edit.apply(&cq, 1) }
                let before = cq.clip(tv.id), after = cq.clip(broll.id)
                let rampOK = LocalRamp.asks("add a speed ramp") && LocalRamp.asks("slow-mo moment please") && !LocalRamp.asks("make it slow motion")
                    && rt?.isRamped == true && abs((rt?.speed ?? 0) - 0.3) < 1e-9 && rq.clip(ta.id)?.isRamped == true
                    && abs((rt.map { $0.speed(atSource: $0.sourceStart + 5) } ?? 0) - 0.3) < 1e-6
                    && abs((before.map { $0.speed(atSource: $0.sourceStart + $0.sourceLength - 1e-3) } ?? 0) - 4) < 0.05
                    && abs((after.map { $0.speed(atSource: $0.sourceStart) } ?? 0) - 4) < 1e-6
                    && abs((after.map { $0.speed(atSource: $0.sourceStart + $0.sourceLength * 0.5) } ?? 0) - 1) < 1e-6
                // Every clip in a short montage: 20 clips in 10s at 120 bpm (a beat is 0.5s) needs half-beat cuts.
                let many = (0..<20).map { i in
                    (MediaAsset(path: "/tmp/m\(i).mov", name: "m\(i)", kind: .video, duration: 6, width: 1920, height: 1080, fps: 30, hasAudio: false),
                     ClipAnalysis(duration: 6, created: Date(timeIntervalSince1970: Double(i) * 100),
                                  samples: (0..<12).map { k in .init(time: Double(k) * 0.5, luma: 0.4 + Double(i % 3) * 0.1, sharpness: 50 + Double(k), motion: 0.01 * Double(k % 4), color: 0.3, faces: 0) }))
                }
                let song = MediaAsset(path: "/tmp/song.m4a", name: "song", kind: .audio, duration: 60, width: 0, height: 0, fps: 0, hasAudio: true)
                let beat = MusicAnalysis(duration: 60, bpm: 120, beats: (0..<120).map { Double($0) * 0.5 }, barPhase: 0, energy: Array(repeating: 0.5, count: 120))
                var everyRecipe = LocalRecipe()
                everyRecipe.seconds = 10
                everyRecipe.pace = .fast
                everyRecipe.every = true
                everyRecipe.wholeLibrary = true
                let montage = AutoPlanner.decide(project: Project(), clips: many, music: (song, beat), recipe: everyRecipe)
                let montageLength = montage.map { $0.shots.reduce(0) { $0 + $1.duration } } ?? 0
                let everyOK = LocalBrain.wantsEvery("fit all the videos within 10s") && LocalBrain.wantsEvery("use every clip")
                    && LocalBrain.wantsEvery("all of my clips") && !LocalBrain.wantsEvery("make it 10 seconds")
                    && Set(montage?.shots.map(\.asset.id) ?? []).count == 20 && montageLength <= 10.2 && montageLength > 8
                let countOK = everyOK && LocalBrain.shotCount("create 7 second montage with at least 10 clips") == 10
                    && LocalBrain.shotCount("twelve quick cuts") == 12 && LocalBrain.shotCount("make it 7 seconds") == nil
                // What they asked for shows late in a file whose best-looking part is early: the shot
                // goes where it shows.
                let dogClip = MediaAsset(path: "/tmp/dog.mov", name: "dog", kind: .video, duration: 12, width: 1920, height: 1080, fps: 30, hasAudio: false)
                let dogLook = ClipAnalysis(duration: 12, created: nil,
                                           samples: (0..<24).map { k in .init(time: Double(k) * 0.5, luma: 0.5, sharpness: 80 - Double(k) * 2, motion: 0.01, color: 0.3, faces: 0) })
                var dogRecipe = LocalRecipe()
                dogRecipe.seconds = 2
                let plainDog = AutoPlanner.decide(project: Project(), clips: [(dogClip, dogLook)], music: nil, recipe: dogRecipe)
                dogRecipe.moments = [dogClip.id: [9]]
                let wantDog = AutoPlanner.decide(project: Project(), clips: [(dogClip, dogLook)], music: nil, recipe: dogRecipe)
                let momentOK = !(plainDog?.shots.contains { $0.source <= 10 && $0.source + $0.duration >= 8 } ?? true)
                    && (wantDog?.shots.contains { $0.source <= 10 && $0.source + $0.duration >= 8 } ?? false)
                // "show little girl eating": the clip of a child eating, not every clip with a person in it.
                let party = MediaAsset(path: "/tmp/party.mov", name: "party", kind: .video, duration: 6, width: 1920, height: 1080, fps: 30, hasAudio: false)
                let tag = { (n: String) in SceneTags.Tag(name: n, confidence: 0.9, times: [1]) }
                let seen: [UUID: SceneTags] = [dogClip.id: SceneTags(tags: [tag("child"), tag("eating"), tag("food")]),
                                               party.id: SceneTags(tags: [tag("people"), tag("cake")])]
                let asked = Transcript.tokens("show little girl eating").filter { $0.count >= 3 && !LocalBrain.notThings.contains($0) }
                let picked = LocalBrain.showing(asked, in: [party, dogClip], shows: { seen[$0] }).map(\.name)
                // "little girl": a clip Vision is sure shows a child beats one where it's only a guess.
                let beach = MediaAsset(path: "/tmp/beach.mov", name: "beach", kind: .video, duration: 6, width: 1920, height: 1080, fps: 30, hasAudio: false)
                var seen2 = seen
                seen2[beach.id] = SceneTags(tags: [tag("people"), SceneTags.Tag(name: "child", confidence: 0.41, times: [1])])
                let girl = Transcript.tokens("add the little girl").filter { $0.count >= 3 && !LocalBrain.notThings.contains($0) }
                let girlPick = LocalBrain.showing(girl, in: [beach, party, dogClip], shows: { seen2[$0] }).map(\.name)
                let pickOK = girlPick == ["dog"] && picked == ["dog"] && LocalBrain.askedPhrase("show little girl eating", matched: ["girl", "eating"]) == "little girl eating"
                log("SHOWING \(pickOK ? "OK" : "FAIL") \(picked) girl=\(girlPick)")
                let spans = { (d: EditDecision?) in (d?.shots ?? []).map { String(format: "%.2f+%.2f", $0.source, $0.duration) }.joined(separator: ",") }
                log("MOMENTS \(momentOK ? "OK" : "FAIL") plain=\(spans(plainDog)) wanted=\(spans(wantDog))")
                let mOK = pickOK && momentOK && rampOK && countOK && tagOK && speechOK && cutOK && timeOK && typedOK && clipOK && moveOK && keepOK && findOK && plainOK && removeOK && endOK && rangeOK && lookOK && wholeOK && briefOK
                log("MENTIONS \(mOK ? "OK" : "FAIL") every=\(everyOK) (\(Set(montage?.shots.map(\.asset.id) ?? []).count) clips, \(String(format: "%.1f", montageLength))s) ramp=\(rampOK) \(moment.said) / \(cutsPlan.said) count=\(countOK) tags=\(tagOK) speech=\(speechOK) cut=\(cutOK) \(cutPlan.said) time=\(timeOK) typed=\(typedOK) clip=\(clipOK) \(labels) move=\(moveOK) keep=\(keepOK) find=\(findOK) plain=\(plainOK) remove=\(removeOK) end=\(endOK) range=\(rangeOK) look=\(lookOK) whole=\(wholeOK) brief=\(briefOK)")
                good = good && mOK
            }
            log("LOCAL IMPROVE \(good ? "OK" : "FAIL") \(detail)")
            ok = ok && good
        }
        // Shortcuts: key presses find their action; changing one takes it from whatever had it; resetting
        // brings the defaults back. The person's own shortcuts are put back afterwards.
        do {
            let saved = UserDefaults.standard.data(forKey: "shortcuts")
            defer {
                if let saved { UserDefaults.standard.set(saved, forKey: "shortcuts") } else { UserDefaults.standard.removeObject(forKey: "shortcuts") }
            }
            UserDefaults.standard.removeObject(forKey: "shortcuts")
            let keys = ShortcutStore()
            func press(_ chars: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> KeyCombo? {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                 characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code).flatMap(KeyCombo.init(event:))
            }
            let space = press(" ", code: 49).flatMap(keys.action(for:))
            let scrub = press("S", code: 1, .shift).flatMap(keys.action(for:))
            let save = press("s", code: 1, .command).flatMap(keys.action(for:))
            let ripple = press("\u{7f}", code: 51, .shift).flatMap(keys.action(for:))
            let findOK = space == .playPause && scrub == .audioScrubbing && save == .save && ripple == .rippleDelete
            // P for Snapping; then S (Snapping's old key) for Loop, which has to take it from nobody.
            keys.set(.snapping, to: KeyCombo("p"))
            let taken = keys.set(.loop, to: KeyCombo("s"))
            let moved = keys.action(for: KeyCombo("p")) == .snapping && keys.action(for: KeyCombo("s")) == .loop && taken == nil
            // ⇧S for Loop takes it from Audio Scrubbing.
            let stolen = keys.set(.loop, to: KeyCombo("s", shift: true))
            let stealOK = stolen == .audioScrubbing && keys.combos(.audioScrubbing).isEmpty
            let reloaded = ShortcutStore()
            let persisted = reloaded.combos(.snapping) == [KeyCombo("p")]
            reloaded.resetAll()
            let resetOK = ShortcutStore().combos(.snapping) == ShortcutAction.snapping.defaults
            // Menus never get plain Delete (it would delete clips from Settings or a sheet).
            let menuOK = reloaded.menu(.delete) == nil && reloaded.menu(.save) != nil
            let good = findOK && moved && stealOK && persisted && resetOK && menuOK
            log("SHORTCUTS \(good ? "OK" : "FAIL") find=\(findOK) move=\(moved) steal=\(stealOK) saved=\(persisted) reset=\(resetOK) menu=\(menuOK)")
            ok = ok && good
        }
        // Captions: words land where they're said on the timeline, follow the clip, take fixes, and draw.
        do {
            var p = Project()
            p.width = 1280; p.height = 720; p.fps = 30
            p.assets = [video]
            let v1 = p.videoTracks[0].id, a1 = p.audioTracks[0].id
            let link = UUID()
            var cv = Clip(trackID: v1, kind: .video, assetID: video.id, start: 5, duration: 3, sourceStart: 1)
            cv.linkID = link
            var ca = Clip(trackID: a1, kind: .audio, assetID: video.id, start: 5, duration: 3, sourceStart: 1)
            ca.linkID = link
            p.clips = [cv, ca]
            let said: [(String, Double, Double)] = [("hello", 0.2, 0.5), ("so", 1.1, 1.3), ("here's", 1.35, 1.6), ("the", 1.62, 1.7),
                                                    ("thing.", 1.72, 2.0), ("we", 2.8, 2.95), ("made", 3.0, 3.3), ("it", 3.35, 3.5), ("again", 4.5, 4.8)]
            let script = Transcript(words: said.map { Transcript.Word(start: $0.1, end: $0.2, text: $0.0) }, language: "en")
            let heard: (MediaAsset) -> Transcript? = { _ in script }
            // Captioning the video means its sound.
            let targets = p.captionTargets([cv.id])
            let picksSound = targets == [ca.id]
            p.addCaptions(targets)
            var blocks = CaptionLayout.blocks(p, transcript: heard)
            let texts = blocks.map(\.text)
            let phrases = texts == ["so here's the thing.", "we made it"]
            let placed = blocks.count == 2 && abs(blocks[0].start - 5.1) < 0.001 && abs(blocks[1].start - 6.8) < 0.001
                && blocks.allSatisfy { $0.end <= 8 + 1e-9 }
            // Moved 2s later and played at 200%: each word where it's now said.
            for i in p.clips.indices { p.clips[i].start += 2; p.clips[i].speed = 2; p.clips[i].duration = 1.5 }
            let moved = CaptionLayout.blocks(p, transcript: heard)
            let follows = moved.count == 2 && abs(moved[0].start - (7 + 0.05)) < 0.001 && abs(moved[1].start - (7 + 0.9)) < 0.001
            for i in p.clips.indices { p.clips[i].start -= 2; p.clips[i].speed = 1; p.clips[i].duration = 3 }
            // A fix (same words count, one for one), and a caption left out.
            blocks = CaptionLayout.blocks(p, transcript: heard)
            p.setCaptionText(blocks[1], to: "we made it!")
            p.setCaptionText(blocks[0], to: "")
            let fixed = CaptionLayout.blocks(p, transcript: heard).map(\.text) == ["we made it!"]
            // Drawn: white text at the captions' height, the word being said in yellow.
            var drawn = false
            if let track = p.captions {
                let layers = CaptionRenderer.layers(CaptionLayout.blocks(p, transcript: heard), style: track.style)
                let instruction = TimelineInstruction(timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1)),
                                                      layers: [], trackIDs: [], canvas: p.size, captions: layers)
                let frame = TimelineCompositor.compose(instruction, at: 7.05, output: p.size) { _, _ in nil }
                if let cg = TimelineCompositor.context.createCGImage(frame, from: CGRect(origin: .zero, size: p.size)) {
                    let bytes = NSBitmapImageRep(cgImage: cg)
                    var white = 0, yellow = 0, elsewhere = 0
                    for y in stride(from: 0, to: 720, by: 3) {
                        for x in stride(from: 0, to: 1280, by: 3) {
                            guard let c = bytes.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                            let near = abs(CGFloat(y) - 0.78 * 720) < 60
                            if c.redComponent > 0.9, c.greenComponent > 0.9, c.blueComponent > 0.9 { near ? (white += 1) : (elsewhere += 1) }
                            if near, c.redComponent > 0.9, c.greenComponent > 0.7, c.blueComponent < 0.45 { yellow += 1 }
                        }
                    }
                    drawn = white > 40 && yellow > 10 && elsewhere == 0
                    log("CAPTIONS draw white=\(white) yellow=\(yellow) elsewhere=\(elsewhere)")
                }
            }
            p.removeCaptions([ca.id])
            let removed = p.captions == nil && !p.clips.contains { $0.captioned == true } && p.captionFixes == nil
            // Deleting every captioned clip takes the caption track with it.
            var emptied = p
            emptied.addCaptions([ca.id])
            emptied.clips.removeAll()
            emptied.sanitize()
            let trackGoes = emptied.captions == nil
            // Captioned again: every word is back, the earlier edits gone.
            p.addCaptions([ca.id])
            let afresh = CaptionLayout.blocks(p, transcript: heard).map(\.text) == ["so here's the thing.", "we made it"]
            // Typing: fewer words (the first takes them all), then the same words again.
            blocks = CaptionLayout.blocks(p, transcript: heard)
            p.setCaptionText(blocks[1], to: "we did")
            let fewer = CaptionLayout.blocks(p, transcript: heard).last?.text == "we did"
            // More words than were said: the caption keeps its time, the words share it.
            p.setCaptionText(blocks[1], to: "and then we finally made it work")
            let longer = CaptionLayout.blocks(p, transcript: heard).filter { $0.start >= blocks[1].start - 1e-9 }
            let kept = longer.map(\.text).joined(separator: " ") == "and then we finally made it work"
                && abs((longer.first?.start ?? 0) - blocks[1].start) < 1e-6 && abs((longer.last?.end ?? 0) - blocks[1].end) < 1e-6
                && longer.flatMap(\.words).count == 7
            p.setCaptionText(blocks[1], to: "we made it")
            let back = CaptionLayout.blocks(p, transcript: heard).last?.text == "we made it" && kept
            let good = picksSound && phrases && placed && follows && fixed && drawn && removed && trackGoes && afresh && fewer && back
            log("CAPTIONS \(good ? "OK" : "FAIL") sound=\(picksSound) phrases=\(phrases) \(texts) placed=\(placed) follows=\(follows) \(moved.map { String(format: "%.3f", $0.start) }) fixed=\(fixed) drawn=\(drawn) removed=\(removed) trackGoes=\(trackGoes) afresh=\(afresh) typing=\(fewer)/\(back)")
            ok = ok && good
        }
        log(ok ? "SELFTEST OK" : "SELFTEST FAIL")
    }
}
