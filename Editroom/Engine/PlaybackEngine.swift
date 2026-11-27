import AVFoundation
import CoreImage
import QuartzCore

/// Owns the picture's AVPlayer, which swaps freshly built compositions in as the timeline changes,
/// and the sound's AudioStream, which plays the edit's sound as one continuous stream alongside it.
@MainActor
final class PlaybackEngine {
    /// The player being watched (silent: the sound is `audio`'s). While looping it swaps with `spare` at each loop.
    private(set) var player = AVPlayer()
    let audio = AudioStream()
    /// What the sound was last made from, so it's only read again when something audible changed.
    private var audioKey: AudioKey?
    private struct AudioKey: Equatable {
        var signature: Int?
        var tracks: [Track]
        var clips: [Clip]
        var duration: Double
    }
    private(set) var duration: Double = 0
    private(set) var fps: Double = 30
    /// An HDR project: frames are half-float HLG (8-bit would clip and band its highlights).
    private(set) var hdr = false
    private var frameFormat: OSType { hdr ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA }
    private var videoOutput: AVPlayerItemVideoOutput?
    private var signature: Int?
    private var isSeeking = false
    private var targetTime: Double = 0
    private var endObserver: NSObjectProtocol?

    var onEnded: (() -> Void)?
    var isEmpty: Bool { player.currentItem == nil }

    init() {
        for p in [player, spare] { configure(p) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                // Looping with the spare ready: it takes over, with no seek.
                if self.loopsItself {
                    if self.swapAt == nil { self.startSpare(in: 0) }
                    self.swapToSpare()
                    return
                }
                self.audio.stop()
                self.onEnded?()
            }
        }
    }

    /// A picture player: silent, and on the sound's clock, so the two stay together.
    private func configure(_ p: AVPlayer) {
        p.automaticallyWaitsToMinimizeStalling = false
        p.actionAtItemEnd = .pause
        p.isMuted = true
        if let clock = audio.clock { p.sourceClock = clock }
    }

    var isPlaying: Bool { player.rate != 0 }
    /// A seek is still on its way (testing).
    var seekInFlight: Bool { isSeeking }

    var currentTime: Double {
        if isSeeking { return targetTime }
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : targetTime
    }

    /// Rebuilds the player item. Changes that don't alter the edit structure only swap the video composition and mix.
    func rebuild(project: Project, media: MediaStore, at time: Double) {
        fps = project.fps
        hdr = project.isHDR
        // The sound: read again only when something audible changed. Playing, the change is heard from
        // just ahead of the playhead, with no break in the sound. Muting and soloing aren't such a change:
        // each track's sound is silenced by its own lane, at once (unless a track ducks under another,
        // whose sound then matters).
        let sound = project.duration > 0
            ? CompositionBuilder.build(project: project, media: media, renderSize: CGSize(width: 16, height: 16),
                                       includeVideo: false, includeAudio: true, keepAllTracks: true)
            : nil
        let ducking = project.audioTracks.contains { $0.duckUnder != nil }
        let key = AudioKey(signature: sound?.signature,
                           tracks: ducking ? project.audioTracks : project.audioTracks.map { var t = $0; t.muted = false; t.solo = false; return t },
                           clips: project.clips.filter { $0.kind == .audio }, duration: project.duration)
        if key != audioKey {
            audioKey = key
            // Each track's sound is read at the rate most of it is in (by length), so it isn't resampled on the way.
            var lanes: [UUID: (track: CMPersistentTrackID, rate: Double)] = [:]
            for (id, compTrack) in sound?.audioTracks ?? [:] {
                var lengths: [Double: Double] = [:]
                for c in key.clips where c.trackID == id {
                    guard let asset = c.assetID, let rate = media.runtimes[asset]?.audioRate, rate > 0 else { continue }
                    lengths[rate, default: 0] += c.duration
                }
                let rate = lengths.max { $0.value < $1.value }.map(\.key).flatMap { (8000...192_000).contains($0) ? $0 : nil } ?? 48000
                lanes[id] = (compTrack, rate)
            }
            // Every audio track has its renderer from the start, sound or not, so sound moved onto an empty
            // track while playing never adds one (which would interrupt the others for a moment).
            for t in project.audioTracks where lanes[t.id] == nil { lanes[t.id] = (kCMPersistentTrackID_Invalid, 48000) }
            audio.load(sound.flatMap { $0.hasAudio ? $0.composition : nil }, mix: sound?.audioMix, duration: project.duration, tracks: lanes)
        }
        audio.setAudible(Dictionary(uniqueKeysWithValues: project.audioTracks.map { ($0.id, project.isAudible($0)) }))
        // The picture, silent.
        guard let built = CompositionBuilder.build(project: project, media: media,
                                                   renderSize: CompositionBuilder.previewSize(for: project), includeAudio: false, keepAllTracks: true) else {
            abandonHandoff()
            audio.stop()
            player.replaceCurrentItem(with: nil)
            videoOutput = nil
            dropSpare()
            signature = nil
            duration = 0
            isSeeking = false
            // Nothing to show: the last picture goes too, so a viewer that appears now (Magic starting, full
            // screen) is black rather than showing what was there before.
            lastFrame = nil
            lastPlayerFrame = nil
            scrubReady = nil
            return
        }
        duration = built.duration
        instruction = built.videoComposition.instructions.first as? TimelineInstruction
        renderSize = built.videoComposition.renderSize

        if handingOff {
            // The edit waiting to take over changed again: a tweak goes to it, anything else starts over.
            if built.signature == spareSignature, let s = spare.currentItem {
                s.videoComposition = built.videoComposition
                return
            }
            abandonHandoff()
        }

        if built.signature == signature, let item = player.currentItem {
            item.videoComposition = built.videoComposition
            if spareSignature == signature, let s = spare.currentItem {
                s.videoComposition = built.videoComposition
            }
            if !isPlaying { refresh(at: time) }
            return
        }

        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: frameFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        item.add(output)
        if let span = loopSpan { item.forwardPlaybackEndTime = CompositionBuilder.time(span.end) }
        // Playing: the new edit takes over in step with the playhead, with no pause.
        if isPlaying, handOff(item, output: output, signature: built.signature) { return }
        install(item, output: output, signature: built.signature, at: time)
    }

    /// The new edit becomes the player's at once, at `time` (a seek, so a moment's pause while playing).
    private func install(_ item: AVPlayerItem, output: AVPlayerItemVideoOutput, signature: Int, at time: Double) {
        let wasPlaying = isPlaying
        retire()
        dropSpare()
        player.replaceCurrentItem(with: item)
        videoOutput = output
        self.signature = signature
        isSeeking = false
        movePicture(to: time)
        if wasPlaying {
            player.playImmediately(atRate: 1)
            // The sound plays on regardless; the picture finds its place in it once the seek lands.
            afterSeek = .pictureToSound
        }
        if loopSpan != nil { primeSpare() }
    }

    /// Picture and sound start together, a moment from now (time for the sound to be read and queued).
    func play() {
        guard player.currentItem != nil else { return }
        if isSeeking {
            // Wherever the seek lands, the sound joins it there.
            player.playImmediately(atRate: 1)
            afterSeek = .startSound
            return
        }
        let t = currentTime
        // Far enough ahead for the output's own delay (Bluetooth headphones), so the first sound isn't late.
        let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.06 + audio.outputLatency, preferredTimescale: 1_000_000_000))
        audio.setLoop(loopSpan)
        audio.start(at: t, host: host)
        player.setRate(1, time: CompositionBuilder.time(t), atHostTime: host)
    }

    func pause() {
        player.pause()
        retire()
        audio.stop()
        afterSeek = .none
        settleHandoff()
        cancelSwap()
    }

    /// What's done once a seek made while playing lands: the sound starts again where the picture lands
    /// (a jump), or the picture is put in step with the sound, which plays on (an edit put in place).
    private enum AfterSeek { case none, startSound, pictureToSound }
    private var afterSeek = AfterSeek.none

    /// The picture is put in step with the sound as it plays: the sound leads, since a picture moving
    /// a frame can't be seen and a jump in the sound can be heard.
    private func syncPicture() {
        let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.03, preferredTimescale: 1_000_000_000))
        guard isPlaying, let t = audio.timelineTime(atHost: host) else { syncSound(); return }
        player.setRate(1, time: CompositionBuilder.time(t), atHostTime: host)
    }

    /// The sound starts again in step with the picture as it plays: at the moment, a little from now,
    /// that the picture's own clock says it'll be at.
    private func syncSound() {
        guard isPlaying, let timebase = player.currentItem?.timebase else { return }
        // Far enough ahead for the output's own delay (Bluetooth headphones), so the first sound isn't late.
        let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.06 + audio.outputLatency, preferredTimescale: 1_000_000_000))
        let t = CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: timebase).seconds
        guard t.isFinite else { return }
        audio.setLoop(loopSpan)
        audio.start(at: t, host: host)
    }

    /// Each half second while playing: if the sound has come apart from the picture (more than about a
    /// frame), it's put back in step.
    private var lastSyncCheck = 0.0
    private func checkSoundSync() {
        let now = CACurrentMediaTime()
        guard isPlaying, !isSeeking, swapAt == nil, now - lastSyncCheck > 0.5 else { return }
        lastSyncCheck = now
        let host = CMClockGetTime(CMClockGetHostTimeClock())
        guard let heard = audio.timelineTime(atHost: host), let timebase = player.currentItem?.timebase else { return }
        let seen = CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: timebase).seconds
        if seen.isFinite, abs(heard - seen) > 0.04 { syncPicture() }
    }

    /// Coalescing seek: only one seek is in flight, the latest request always wins. `fast` (scrubbing,
    /// skimming) lets the decoder land on the nearest frame it can show at once, within a little of
    /// the time, rather than decoding up from the last keyframe to the exact frame, which in long-GOP
    /// footage (a 4K screen recording, a phone clip) takes long enough to fall seconds behind a quick
    /// drag. The exact frame follows as soon as the scrub rests (`seek(to:)` again, not fast).
    func seek(to time: Double, fast: Bool = false) {
        settleHandoff()
        if isPlaying {
            audio.stop()
            afterSeek = .startSound
        }
        movePicture(to: time, fast: fast)
    }

    /// The picture's seek alone; the sound is left as it is.
    private func movePicture(to time: Double, fast: Bool = false) {
        targetTime = clamp(time)
        exactWanted = !fast
        cancelSwap()
        guard player.currentItem != nil else { return }
        if !isSeeking { performSeek() }
    }

    /// Whether the latest request wants the exact frame, and whether the seek in flight is exact.
    private var exactWanted = true
    private var seekingExact = true

    private var refreshPending = false

    private func refresh(at time: Double) {
        targetTime = clamp(time)
        if isSeeking { refreshPending = true } else { performSeek() }
    }

    private func clamp(_ t: Double) -> Double {
        max(0, min(t, duration - 0.5 / fps))
    }

    private func performSeek() {
        guard let item = player.currentItem else { isSeeking = false; return }
        isSeeking = true
        let t = targetTime
        let exact = exactWanted
        seekingExact = exact
        let slack = exact ? CMTime.zero : CMTime(seconds: 0.75, preferredTimescale: 600)
        player.seek(to: CompositionBuilder.time(t), toleranceBefore: slack, toleranceAfter: slack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if abs(self.targetTime - t) > 1e-6 || self.refreshPending || (self.exactWanted && !exact) {
                    self.refreshPending = false
                    self.performSeek()
                } else {
                    self.isSeeking = false
                    switch self.afterSeek {
                    case .startSound: self.syncSound()
                    case .pictureToSound: self.syncPicture()
                    case .none: break
                    }
                    self.afterSeek = .none
                }
            }
        }
    }

    // MARK: Seamless looping

    /// Looping: a second player waits at the loop's start, already decoded, and starts at the very
    /// moment the first reaches the end (its own clock, not a seek), so the loop has no pause. Then
    /// they swap, and the one that finished goes back to wait at the start for the next time round.
    private var spare = AVPlayer()
    private var spareOutput: AVPlayerItemVideoOutput?
    /// The edit the spare's item was made from (a different one is made again).
    private var spareSignature: Int?
    /// The spare is at the loop's start, decoded, ready to start.
    private var spareReady = false
    private var priming = 0
    /// When the spare is set to start (host time, seconds).
    private var swapAt: Double?

    /// What's being looped while playing (nil: not looping). The player stops itself at its end.
    var loopSpan: (start: Double, end: Double)? {
        didSet {
            guard loopSpan?.start != oldValue?.start || loopSpan?.end != oldValue?.end else { return }
            player.currentItem?.forwardPlaybackEndTime = loopSpan.map { CompositionBuilder.time($0.end) } ?? .invalid
            audio.setLoop(loopSpan)
            if handingOff {
                spare.currentItem?.forwardPlaybackEndTime = loopSpan.map { CompositionBuilder.time($0.end) } ?? .invalid
                return
            }
            if loopSpan == nil { dropSpare() } else { primeSpare() }
        }
    }

    /// Set when the spare takes over: the loop just started again (see `takeWrap`).
    private var wrapped = false

    /// True once after each loop: the playhead goes exactly to the start for that frame, the frame
    /// the viewer is showing, rather than wherever playback has got to by the time it's drawn.
    func takeWrap() -> Bool {
        defer { wrapped = false }
        return wrapped
    }

    /// The loop is taken care of here (the spare is ready, or already starting).
    var loopsItself: Bool { loopSpan != nil && (spareReady || swapAt != nil) }

    /// Each frame while playing: starts the spare just as the loop's end comes, and swaps once it has.
    func serviceLoop() {
        checkSoundSync()
        guard let span = loopSpan, player.currentItem != nil else { return }
        if let at = swapAt {
            if CACurrentMediaTime() >= at { swapToSpare() }
            return
        }
        guard spareReady, isPlaying else { return }
        let left = span.end - player.currentTime().seconds
        if left < 0.25 { startSpare(in: max(0, left)) }
    }

    /// Starts the waiting spare `seconds` from now, on the host clock.
    private func startSpare(in seconds: Double) {
        guard spareReady, swapAt == nil else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let at = CMTimeAdd(now, CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
        spare.setRate(1, time: .invalid, atHostTime: at)
        swapAt = at.seconds
        spareReady = false
    }

    /// The spare is playing: it becomes the player, and the old one goes to wait at the start.
    private func swapToSpare() {
        guard swapAt != nil else { return }
        swapAt = nil
        let handover = handingOff
        handingOff = false
        if !handover { wrapped = true }
        let old = player, oldOutput = videoOutput, oldSignature = signature
        isSeeking = false
        if handover { signature = spareSignature }
        player = spare
        videoOutput = spareOutput
        if handover {
            // The old edit plays on until the new one's first picture is out, which can take a few frames
            // after it starts: shown meanwhile, rather than the picture standing still. It's no use to loop with.
            retire()
            retiring = (old, oldOutput, CACurrentMediaTime() + 0.4)
            spare = AVPlayer()
            configure(spare)
            spareOutput = nil
            spareSignature = nil
            if loopSpan != nil { primeSpare() }
        } else {
            spare = old
            spareOutput = oldOutput
            spareSignature = oldSignature
            old.pause()
            primeSpare()
        }
    }

    /// The edit just handed over from, still playing until the new one shows its first picture (or `until`).
    private var retiring: (player: AVPlayer, output: AVPlayerItemVideoOutput?, until: Double)?

    private func retire() {
        guard let r = retiring else { return }
        retiring = nil
        r.player.pause()
        r.player.replaceCurrentItem(with: nil)
    }

    // MARK: Seamless edits while playing

    /// The spare holds a new edit, getting ready to take over from the player (see `handOff`).
    private var handingOff = false
    /// How long the last hand-over's seek and decode took, to judge how far ahead the next one starts.
    private var handoffPrep = 0.03

    /// An edit that changes the timeline's structure (a clip moved, added, trimmed) needs a new player
    /// item. While playing, it's readied on the spare a little ahead of the playhead, then started at
    /// the moment the playhead gets there and swapped in, as a loop is: playback never stops. False
    /// when there isn't room ahead to do that (the end is too close); the edit is installed at once.
    private func handOff(_ item: AVPlayerItem, output: AVPlayerItemVideoOutput, signature sig: Int) -> Bool {
        if swapAt != nil { cancelSwap() }
        let now = player.currentTime().seconds
        guard now.isFinite else { return false }
        let end = min(duration, loopSpan?.end ?? .infinity)
        guard now + 0.6 < end - 0.1 else { return false }
        priming += 1
        let generation = priming
        spareReady = false
        spare.pause()
        spare.replaceCurrentItem(with: item)
        // Sent to about where it'll take over before it draws anything: left alone, it first makes the
        // frame at the start, which costs a decode the playing picture needs (and, from frames decoded
        // ahead, pushes out the ones playing).
        spare.seek(to: CompositionBuilder.time(now + max(0.035, handoffPrep * 1.5 + 0.02) + 0.03), toleranceBefore: .zero, toleranceAfter: .zero)
        spareOutput = output
        spareSignature = sig
        handingOff = true
        let next = spare
        Task { @MainActor [weak self] in
            for _ in 0..<750 where item.status != .readyToPlay || next.status != .readyToPlay {
                if item.status == .failed { break }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let self, generation == self.priming else { return }
            // Just long enough ahead for the seek and decode to finish before the playhead gets
            // there: what they took last time, with room to spare. Footage that's slower to ready gets more.
            var lead = max(0.035, self.handoffPrep * 1.5 + 0.02)
            for _ in 0..<3 {
                guard item.status == .readyToPlay, self.isPlaying else { break }
                let asked = CACurrentMediaTime()
                let target = self.player.currentTime().seconds + lead
                guard target < end - 0.1 else { break }
                let landed = await next.seek(to: CompositionBuilder.time(target), toleranceBefore: .zero, toleranceAfter: .zero)
                guard generation == self.priming else { return }
                guard landed else { break }
                let ready = await next.preroll(atRate: 1)
                guard generation == self.priming else { return }
                guard ready, self.isPlaying else { break }
                self.handoffPrep = min(0.5, CACurrentMediaTime() - asked)
                // The moment the playing one reaches `target`, read off its own clock (exact, where
                // the time it reports is only near enough).
                let host = CMClockGetHostTimeClock()
                let at = self.player.currentItem?.timebase.map { CMSyncConvertTime(CompositionBuilder.time(target), from: $0, to: host) }
                    ?? CMTimeAdd(CMClockGetTime(host), CMTime(seconds: target - self.player.currentTime().seconds, preferredTimescale: 1_000_000_000))
                if at.isNumeric, at.seconds - CMClockGetTime(host).seconds > 0.01 {
                    next.setRate(1, time: CompositionBuilder.time(target), atHostTime: at)
                    self.swapAt = at.seconds
                    return
                }
                lead *= 2
            }
            // Couldn't get ahead of the playhead (or playback stopped): put the edit in place now.
            self.settleHandoff()
        }
        return true
    }

    /// A hand-over still waiting is finished at once: the new edit goes in at the playhead.
    private func settleHandoff() {
        guard handingOff, let item = spare.currentItem, let output = spareOutput, let sig = spareSignature else { return }
        let t = player.currentTime().seconds
        handingOff = false
        priming += 1
        swapAt = nil
        spare.pause()
        spare.replaceCurrentItem(with: nil)
        spareOutput = nil
        spareSignature = nil
        install(item, output: output, signature: sig, at: t.isFinite ? t : targetTime)
    }

    /// The edit waiting to take over is out of date: it's dropped, and the player carries on as it was.
    private func abandonHandoff() {
        guard handingOff else { return }
        handingOff = false
        swapAt = nil
        dropSpare()
    }

    /// Stopped or moved before the spare took over: it goes back to waiting.
    private func cancelSwap() {
        guard swapAt != nil else { return }
        swapAt = nil
        spare.pause()
        primeSpare()
    }

    private func dropSpare() {
        priming += 1
        spareReady = false
        if swapAt != nil { spare.pause(); swapAt = nil }
        spare.replaceCurrentItem(with: nil)
        spareOutput = nil
        spareSignature = nil
    }

    /// Puts the spare at the loop's start, decoded and ready to go.
    private func primeSpare() {
        guard let span = loopSpan, let main = player.currentItem else { return }
        priming += 1
        let generation = priming
        spareReady = false
        let item: AVPlayerItem
        if spareSignature == signature, let current = spare.currentItem {
            item = current
        } else {
            item = AVPlayerItem(asset: main.asset)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: frameFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            item.add(output)
            spare.replaceCurrentItem(with: item)
            spareOutput = output
            spareSignature = signature
        }
        item.videoComposition = main.videoComposition
        item.forwardPlaybackEndTime = CompositionBuilder.time(span.end)
        let player = spare
        Task { @MainActor [weak self] in
            for _ in 0..<150 where item.status != .readyToPlay || player.status != .readyToPlay {
                if item.status == .failed { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard let self, generation == self.priming, item.status == .readyToPlay, player.status == .readyToPlay else { return }
            let landed = await player.seek(to: CompositionBuilder.time(span.start), toleranceBefore: .zero, toleranceAfter: .zero)
            guard landed, generation == self.priming, player.rate == 0 else { return }
            let ready = await player.preroll(atRate: 1)
            guard ready, generation == self.priming else { return }
            self.spareReady = true
        }
    }

    /// Pulls the newest decoded frame, if one arrived since the last call.
    func pullFrame() -> CVPixelBuffer? {
        if let at = swapAt, CACurrentMediaTime() >= at { swapToSpare() }
        if let ready = scrubReady {
            scrubReady = nil
            lastFrame = ready.buffer
            shownTime = ready.time
            return ready.buffer
        }
        if restorePlayerFrame {
            restorePlayerFrame = false
            if let back = lastPlayerFrame {
                lastFrame = back
                return back
            }
        }
        guard let output = videoOutput else { return nil }
        if let frame = take(from: output) {
            retire()
            return frame
        }
        // The new edit's first picture isn't out yet: the old one's, as it plays on.
        if let r = retiring {
            if CACurrentMediaTime() > r.until || !isPlaying { retire(); return nil }
            if let o = r.output, let frame = take(from: o) { return frame }
        }
        return nil
    }

    /// The newest frame from `output` for now, if there's one not yet shown.
    private func take(from output: AVPlayerItemVideoOutput) -> CVPixelBuffer? {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t) else { return nil }
        var shown = CMTime.zero
        let frame = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown)
        // Playing, a frame from somewhere else (a player just handed an edit drew one elsewhere before it
        // got to the playhead) is never shown: the last frame stays up instead.
        if isPlaying, frame != nil, shown.isNumeric, t.isNumeric, abs(shown.seconds - t.seconds) > 3 / max(fps, 1) { return nil }
        if frame != nil {
            lastFrame = frame
            lastPlayerFrame = frame
            if shown.isNumeric { shownTime = shown.seconds }
        }
        return frame
    }

    // MARK: Scrubbing from made-ahead frames

    /// The timeline as the player has it, for compositing scrub frames the same way.
    private var instruction: TimelineInstruction?
    private var renderSize = CGSize(width: 1920, height: 1080)
    private let scrubQueue = DispatchQueue(label: "editroom.scrub", qos: .userInteractive)
    private var scrubBusy = false
    /// The latest scrub frame asked for, waiting for the one being drawn.
    private var scrubNext: (time: Double, pictures: [Int: CIImage], still: CIImage?)?
    /// A drawn scrub frame for the viewer's next refresh.
    private var scrubReady: (buffer: CVPixelBuffer, time: Double)?
    /// Bumped when scrubbing ends, so a frame still being drawn doesn't land over the exact one.
    private var scrubGeneration = 0
    private var scrubPool: CVPixelBufferPool?
    private var scrubPoolSize = CGSize.zero
    private var scrubPoolHDR = false

    /// Shows the frame at `t` composited from made-ahead frames, if every video layer showing then has
    /// them. False when it can't (the player's seek has to do).
    func showScrubFrame(at t: Double, cache: ScrubCache) -> Bool {
        guard let instruction, !isPlaying else { return false }
        let at = clamp(t) + 1e-4
        var pictures: [Int: CIImage] = [:]
        for (i, layer) in instruction.layers.enumerated() where at >= layer.start && at < layer.end {
            switch layer.source {
            case .track, .reversed, .decoded:
                guard let s = layer.scrub, let img = cache.image(s.asset, at: s.time(at: at)) else { return false }
                pictures[i] = img
            default: continue
            }
        }
        scrubNext = (at, pictures, nil)
        drawScrubFrame()
        return true
    }

    /// The exact frame takes over: nothing drawn from scrub frames lands after this.
    /// One frame of a file filling the viewer (fitted, as the viewer fits the timeline): the new edge
    /// of a clip while it's trimmed. Drawn like a scrub frame, on the GPU straight into the viewer.
    func showStill(_ image: CIImage, orientation: CGImagePropertyOrientation, time: Double) {
        let src = orientation == .up ? image : image.oriented(orientation)
        let e = src.extent
        guard e.width > 0, e.height > 0 else { return }
        let size = renderSize
        let s = min(size.width / e.width, size.height / e.height)
        let fitted = src.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                                           tx: (size.width - e.width * s) / 2 - e.minX * s,
                                                           ty: (size.height - e.height * s) / 2 - e.minY * s))
        scrubNext = (time, [:], fitted.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))))
        stillShowing = true
        drawScrubFrame()
    }

    /// A still went up (a trim's edge): when it ends, the player's last frame comes back, since
    /// nothing may have changed to make it draw a new one.
    private var stillShowing = false
    private var lastPlayerFrame: CVPixelBuffer?
    private var restorePlayerFrame = false

    func endStill() {
        guard stillShowing else { return }
        stillShowing = false
        endScrubFrames()
        restorePlayerFrame = true
    }

    func endScrubFrames() {
        scrubGeneration += 1
        scrubNext = nil
        scrubReady = nil
    }

    private func drawScrubFrame() {
        guard !scrubBusy, let job = scrubNext, let instruction else { return }
        scrubNext = nil
        scrubBusy = true
        let size = renderSize
        let hdr = instruction.hdr
        if scrubPool == nil || scrubPoolSize != size || scrubPoolHDR != hdr {
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ] as CFDictionary, &pool)
            scrubPool = pool
            scrubPoolSize = size
            scrubPoolHDR = hdr
        }
        let pool = scrubPool
        let generation = scrubGeneration
        scrubQueue.async { [weak self] in
            var buffer: CVPixelBuffer?
            if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
            if let buffer {
                let image = job.still ?? TimelineCompositor.compose(instruction, at: job.time, output: size) { i, _ in job.pictures[i] }
                // Drawn and tagged as the player's frames are, so the viewer shows them in the same colours.
                TimelineCompositor.render(image, to: buffer, size: size, hdr: hdr)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scrubBusy = false
                    if let buffer, generation == self.scrubGeneration { self.scrubReady = (buffer, job.time) }
                    self.drawScrubFrame()
                }
            }
        }
    }

    /// The time of the frame last handed to the viewer (testing).
    private(set) var shownTime: Double = 0

    /// The most recent frame handed out, so a viewer that appears later can show it straight away.
    private(set) var lastFrame: CVPixelBuffer?

    /// Its tab went behind another: the players, their decoded frames and the sound's renderers are let go.
    /// The next rebuild makes them again.
    func unload() {
        abandonHandoff()
        cancelSwap()
        audio.stop()
        audio.load(nil, mix: nil, duration: 0, tracks: [:])
        audioKey = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        dropSpare()
        retire()
        signature = nil
        isSeeking = false
        lastFrame = nil
        lastPlayerFrame = nil
        scrubReady = nil
        scrubNext = nil
        scrubPool = nil
        scrubPoolSize = .zero
    }
}
