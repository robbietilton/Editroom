import AVFoundation
import CoreAudio
import os

/// Playback sound as continuous streams, one per audio track ("lanes"), all on one clock. Each track's
/// sound is read from the edit's composition (AVAssetReader, with the edit's audio mix) and queued on
/// its own audio renderer a little ahead of what's being heard, so changes while playing never stop or
/// swap anything: the next sound queued simply comes from the new edit, carrying on sample for sample.
/// When nothing near the playhead changed, it's the same sound and the join can't be heard. Muting or
/// soloing a track sets its renderer's volume, heard at once.
///
/// Times: the renderers run on the synchronizer's continuous clock ("render time"). Each queued buffer
/// is stamped with render time = timeline time + an offset, which grows by the loop's length each time a
/// loop goes round, so looping is gapless too.
final class AudioStream: @unchecked Sendable {
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "editroom.audio-stream", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    /// How far ahead of what's heard the sound is queued: enough to ride out a busy moment, little
    /// enough that a change is heard soon after it's made. On top of the output's own delay (`latency`).
    private static let ahead = CMTime(seconds: 0.2, preferredTimescale: 48000)
    /// A new reader starts at least this far before where its sound is wanted, and what it reads first is
    /// dropped: a freshly started decoder and resampler take up to about 0.1s to settle, which would click.
    private static let lead = CMTime(seconds: 0.25, preferredTimescale: 48000)

    /// One audio track's sound: its own renderer, and what's queued on it.
    private final class Lane {
        var renderer = AVSampleBufferAudioRenderer()
        /// Its sound in the composition.
        var track: CMPersistentTrackID
        /// The rate its sound is read at: its own (most of its clips'), so the reader doesn't resample.
        /// AVFoundation's resampling can come out a few samples early or late from one reader to the
        /// next, which would be heard where one takes over from another; the renderer resamples instead,
        /// once, as the single stream it is.
        var rate: Double
        var feed: Feed?
        /// Where the queued sound ends, in render and timeline time.
        var queuedEnd: (render: CMTime, media: CMTime)?
        /// Read but not yet queued: sound further ahead than `ahead` (after a silence), held back so an
        /// edit made meanwhile still reaches it.
        var held: (buffer: CMSampleBuffer, render: CMTime, media: CMTime, length: CMTime)?

        init(track: CMPersistentTrackID, rate: Double) {
            self.track = track
            self.rate = rate
        }
    }

    /// How much earlier than it's heard the output needs its sound: next to nothing for the speakers, around
    /// 0.15-0.3s for Bluetooth headphones, which take the sound that long to send. Everything is queued this much
    /// further ahead, or it reaches them late and is dropped: choppy, or silent.
    private var latency = CMTime.zero
    private let latencyLock = OSAllocatedUnfairLock(initialState: 0.0)
    /// The output's delay in seconds, for starting the picture with the sound.
    var outputLatency: Double { latencyLock.withLock { $0 } }

    /// The current output's delay, as macOS reports it.
    private static func measureLatency() -> Double {
        func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ fallback: T) -> T {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value = fallback
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : fallback
        }
        let device: AudioObjectID = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                        kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
        guard device != 0 else { return 0 }
        let rate: Float64 = get(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0)
        guard rate > 0 else { return 0 }
        let frames: UInt32 = get(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, 0)
            + get(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, 0)
            + get(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, 0)
        let stream: AudioStreamID = get(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, AudioStreamID(0))
        let streamFrames: UInt32 = stream == 0 ? 0 : get(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, 0)
        return min(1, Double(frames + streamFrames) / rate)
    }

    /// Reads the output's delay again (on `queue`).
    private func updateLatency() {
        let seconds = Self.measureLatency()
        latency = CMTime(seconds: seconds, preferredTimescale: 48000)
        latencyLock.withLock { $0 = seconds }
    }

    private struct Feed {
        let reader: AVAssetReader
        let output: AVAssetReaderAudioMixOutput
        /// render time − timeline time for this stretch.
        let offset: CMTime
        /// Sound before this timeline time is the reader settling, not queued.
        let from: CMTime
        /// Where this stretch ends (the loop's end, or the edit's).
        let until: CMTime
        let rate: Double
    }

    // Only touched on `queue`.
    private var composition: AVComposition?
    private var mix: AVAudioMix?
    private var duration = CMTime.zero
    private var loop: (start: CMTime, end: CMTime)?
    /// By timeline track.
    private var lanes: [UUID: Lane] = [:]
    /// Which tracks are heard (muted and unsoloed ones aren't); a track not listed is.
    private var audible: [UUID: Bool] = [:]
    /// Where each stretch of render time starts, for telling which timeline time is being heard.
    private var stretches: [(render: CMTime, offset: CMTime)] = []
    private var playing = false
    /// The tracks of the last load: a lane of any other track is only waiting to be taken out once stopped.
    private var wanted = Set<UUID>()

    private static func settings(rate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    init() {
        let seconds = Self.measureLatency()
        latency = CMTime(seconds: seconds, preferredTimescale: 48000)
        latencyLock.withLock { $0 = seconds }
        // Another output picked (headphones on, off): its delay is read again.
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
            self?.updateLatency()
        }
        // The output changed under a renderer (another device, or the same one set up again): it throws away what
        // it had queued. Its sound is queued again from just ahead of what's heard, rather than left silent.
        NotificationCenter.default.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: nil, queue: nil) { [weak self] note in
            guard let renderer = note.object as? AVSampleBufferAudioRenderer else { return }
            self?.queue.async {
                guard let self, self.playing, let lane = self.lanes.values.first(where: { $0.renderer === renderer }) else { return }
                self.updateLatency()
                self.join(lane)
            }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
    }

    /// The clock the sound plays to; the video players follow it too, so picture and sound never drift.
    var clock: CMClock? { synchronizer.timebase.sourceClock }

    // MARK: Called from the main thread

    /// The edit's sound changed (nil: it has none). `tracks` gives each timeline track's sound in the
    /// composition and the rate to read it at. Playing, the next sound queued is the new edit's.
    func load(_ composition: AVComposition?, mix: AVAudioMix?, duration: Double,
              tracks: [UUID: (track: CMPersistentTrackID, rate: Double)]) {
        let mix = mix?.copy() as? AVAudioMix
        queue.async {
            self.composition = composition
            self.mix = mix
            self.duration = CompositionBuilder.time(duration)
            let tracks = composition == nil ? tracks.mapValues { _ in (track: kCMPersistentTrackID_Invalid, rate: 48000.0) } : tracks
            self.wanted = Set(tracks.keys)
            // A track gone: its renderer goes, but only once stopped. Adding or taking out a renderer while the
            // synchronizer plays interrupts every track's sound for a moment, so meanwhile it's just silent.
            for (id, lane) in self.lanes where tracks[id] == nil {
                self.silence(lane)
                guard !self.playing else { continue }
                self.synchronizer.removeRenderer(lane.renderer, at: .invalid)
                self.lanes[id] = nil
            }
            for (id, t) in tracks {
                if let lane = self.lanes[id] {
                    lane.track = t.track
                    lane.rate = t.rate
                    // A track with no sound now (its clips moved to another): nothing queued, nothing read.
                    if t.track == kCMPersistentTrackID_Invalid { self.silence(lane); continue }
                    if self.playing { self.continueWithNewSound(lane) }
                } else {
                    let lane = Lane(track: t.track, rate: t.rate)
                    lane.renderer.volume = self.audible[id] == false ? 0 : 1
                    self.synchronizer.addRenderer(lane.renderer)
                    self.lanes[id] = lane
                    if self.playing { self.join(lane) }
                }
            }
        }
    }

    /// A lane with nothing to play: its reading stops and what it had queued goes.
    private func silence(_ lane: Lane) {
        lane.feed?.reader.cancelReading()
        lane.feed = nil
        lane.held = nil
        lane.queuedEnd = nil
        lane.renderer.flush()
    }

    /// Which tracks are heard. Takes effect at once.
    func setAudible(_ audible: [UUID: Bool]) {
        queue.async {
            self.audible = audible
            for (id, lane) in self.lanes {
                let volume: Float = audible[id] == false ? 0 : 1
                if lane.renderer.volume != volume { lane.renderer.volume = volume }
            }
        }
    }

    /// What's looped (nil: nothing). Playing, it takes effect from what's queued next.
    func setLoop(_ span: (start: Double, end: Double)?) {
        queue.async {
            let new = span.map { (start: CompositionBuilder.time($0.start), end: CompositionBuilder.time($0.end)) }
            guard new?.start != self.loop?.start || new?.end != self.loop?.end else { return }
            self.loop = new
            if self.playing { self.lanes.values.forEach(self.continueWithNewSound) }
        }
    }

    /// Starts the sound at timeline time `t`, heard from host time `host` (the picture starts then too).
    func start(at t: Double, host: CMTime) {
        queue.async {
            self.updateLatency()
            for lane in self.lanes.values {
                lane.feed?.reader.cancelReading()
                lane.renderer.flush()
            }
            let start = CompositionBuilder.time(t)
            // Render time is timeline time at the start.
            self.synchronizer.setRate(1, time: start, atHostTime: host)
            self.playing = true
            self.stretches = [(start, .zero)]
            for lane in self.lanes.values {
                lane.held = nil
                lane.queuedEnd = (start, start)
                lane.feed = self.makeFeed(lane, from: start, offset: .zero)
            }
            self.pump()
        }
    }

    func stop() {
        queue.async {
            self.playing = false
            self.synchronizer.rate = 0
            // Renderers of tracks that went while playing go now.
            for (id, lane) in self.lanes where !self.wanted.contains(id) {
                self.synchronizer.removeRenderer(lane.renderer, at: .invalid)
                self.lanes[id] = nil
            }
            for lane in self.lanes.values {
                lane.feed?.reader.cancelReading()
                lane.feed = nil
                lane.held = nil
                lane.renderer.flush()
                lane.queuedEnd = nil
            }
            self.stretches = []
        }
    }

    /// The timeline time being heard at host time `host` (nil while stopped), for checking against the picture.
    func timelineTime(atHost host: CMTime) -> Double? {
        queue.sync {
            guard playing else { return nil }
            let render = CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: synchronizer.timebase)
            guard let stretch = stretch(at: render) else { return nil }
            return (render - stretch.offset).seconds
        }
    }

    // MARK: On the queue

    private func stretch(at render: CMTime) -> (render: CMTime, offset: CMTime)? {
        stretches.last(where: { $0.render <= render }) ?? stretches.first
    }

    /// The sound queued on a lane from here on is read from the current edit (and loop): what's already
    /// queued plays out, and the new sound follows it exactly.
    private func continueWithNewSound(_ lane: Lane) {
        lane.feed?.reader.cancelReading()
        lane.feed = nil
        lane.held = nil
        // A lane that has run out (its sound ended) starts again just ahead of what's being heard.
        guard let end = lane.queuedEnd, end.render > synchronizer.currentTime() + latency + CMTime(seconds: 0.03, preferredTimescale: 48000) else {
            join(lane)
            return
        }
        lane.feed = makeFeed(lane, from: end.media, offset: end.render - end.media)
        pump()
    }

    /// A lane joins in while playing: its sound starts a moment ahead of what's being heard.
    private func join(_ lane: Lane) {
        let at = synchronizer.currentTime() + latency + CMTime(seconds: 0.1, preferredTimescale: 48000)
        guard let stretch = stretch(at: at) else { return }
        let media = at - stretch.offset
        lane.feed?.reader.cancelReading()
        lane.held = nil
        lane.queuedEnd = (at, media)
        lane.feed = makeFeed(lane, from: media, offset: stretch.offset)
        pump()
    }

    /// A reader of a lane's sound from timeline time `start`, to the loop's end or the edit's.
    private func makeFeed(_ lane: Lane, from start: CMTime, offset: CMTime) -> Feed? {
        guard let composition, let track = composition.track(withTrackID: lane.track) else { return nil }
        var start = start
        var offset = offset
        if let loop, start >= loop.end - CMTime(seconds: 1 / lane.rate, preferredTimescale: 96000) {
            // At the loop's end: on round to its start.
            offset = offset + (loop.end - loop.start)
            start = loop.start
        }
        let end = loop.map { min($0.end, duration) } ?? duration
        guard end > start, let reader = try? AVAssetReader(asset: composition) else { return nil }
        // Read on a little past a loop's end and cut there here: a reader's last moments before the end
        // of what it's asked for come out slightly differently, which would differ from a join's.
        let readEnd = min(duration, end + Self.lead)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: Self.settings(rate: lane.rate))
        let own = AVMutableAudioMix()
        own.inputParameters = mix?.inputParameters.filter { $0.trackID == lane.track } ?? []
        output.audioMix = own
        output.audioTimePitchAlgorithm = .spectral
        // Queued buffers stay with the renderer while the reader reads on, so each gets its own copy.
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        // On a tenth of a second from the timeline's start (a whole number of samples at every usual
        // rate), as every reader of this edit starts, so any that does resample does so alike.
        let readStart = CMTime(value: CMTimeValue(max(0, ((start - Self.lead).seconds * 10).rounded(.down))), timescale: 10)
        reader.timeRange = CMTimeRange(start: readStart, end: readEnd)
        guard reader.startReading() else { return nil }
        if stretches.last?.offset != offset { stretches.append((start + offset, offset)) }
        if stretches.count > 8 { stretches.removeFirst(stretches.count - 8) }
        return Feed(reader: reader, output: output, offset: offset, from: start, until: end, rate: lane.rate)
    }

    /// Keeps every lane topped up to `ahead` of what's being heard.
    private func pump() {
        guard playing else { return }
        let limit = synchronizer.currentTime() + latency + Self.ahead
        for lane in lanes.values {
            // A renderer that has failed (the output turned it down): a fresh one in its place, picking up just
            // ahead of what's heard, rather than silence until Editroom is opened again.
            if lane.renderer.status == .failed {
                let volume = lane.renderer.volume
                synchronizer.removeRenderer(lane.renderer, at: .invalid)
                lane.renderer = AVSampleBufferAudioRenderer()
                lane.renderer.volume = volume
                synchronizer.addRenderer(lane.renderer)
                join(lane)
                continue
            }
            while lane.renderer.isReadyForMoreMediaData {
                if let h = lane.held {
                    guard h.render < limit else { break }
                    lane.renderer.enqueue(h.buffer)
                    lane.queuedEnd = (h.render + h.length, h.media + h.length)
                    lane.held = nil
                    continue
                }
                guard let feed = lane.feed, let end = lane.queuedEnd, end.render < limit else { break }
                guard let read = feed.output.copyNextSampleBuffer().flatMap({ Self.cut($0, at: feed.until, rate: feed.rate) }) else {
                    // This stretch is done: round the loop, or that's the end of this track's sound.
                    lane.feed = loop.flatMap { makeFeed(lane, from: $0.end, offset: feed.offset) }
                    continue
                }
                // The reader's settling-in sound, before where it was wanted, is dropped.
                guard let buffer = Self.trimmed(read, from: feed.from, rate: feed.rate) else { continue }
                let media = CMSampleBufferGetPresentationTimeStamp(buffer)
                let length = CMSampleBufferGetDuration(buffer)
                guard media.isNumeric, length.isNumeric, let stamped = Self.retimed(buffer, by: feed.offset) else { continue }
                lane.held = (stamped, media + feed.offset, media, length)
            }
        }
    }

    /// The part of a buffer before timeline time `until` (nil if none of it is).
    private static func cut(_ buffer: CMSampleBuffer, at until: CMTime, rate: Double) -> CMSampleBuffer? {
        let start = CMSampleBufferGetPresentationTimeStamp(buffer)
        let count = CMSampleBufferGetNumSamples(buffer)
        let keep = Int(((until - start).seconds * rate).rounded())
        guard keep > 0 else { return nil }
        guard keep < count else { return buffer }
        var out: CMSampleBuffer?
        CMSampleBufferCopySampleBufferForRange(allocator: nil, sampleBuffer: buffer, sampleRange: CFRange(location: 0, length: keep), sampleBufferOut: &out)
        return out
    }

    /// The part of a buffer from timeline time `from` on (nil if it all comes before).
    private static func trimmed(_ buffer: CMSampleBuffer, from: CMTime, rate: Double) -> CMSampleBuffer? {
        let start = CMSampleBufferGetPresentationTimeStamp(buffer)
        let count = CMSampleBufferGetNumSamples(buffer)
        guard start < from else { return buffer }
        let skip = Int(((from - start).seconds * rate).rounded())
        guard skip < count else { return nil }
        var out: CMSampleBuffer?
        CMSampleBufferCopySampleBufferForRange(allocator: nil, sampleBuffer: buffer, sampleRange: CFRange(location: skip, length: count - skip),
                                               sampleBufferOut: &out)
        return out
    }

    private static func retimed(_ buffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, count))
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + offset
            timing[i].decodeTimeStamp = .invalid
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}
