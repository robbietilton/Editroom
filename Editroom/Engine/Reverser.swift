import AVFoundation
import CoreImage
import VideoToolbox

/// Reversed clips play straight from their original file, so reversing is instant at any length.
///
/// A reversed clip is a normal clip on a mirror image of its file: source time `s` is original time
/// `length - s`. Trims, splits and speed work as on any clip. Picture is decoded backwards while it
/// plays (`ReverseFrames`); sound is reversed once per file into a small cached WAV (`ReverseAudio`).
enum Reverser {
    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom/Reversed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Picture

/// Hands out a file's frames for any time, read half a second at a time and kept in a small cache,
/// so playing decodes each stretch once. The next stretch in the playing direction is decoded ahead,
/// while the current one plays. Used for clips playing backwards, and for HDR and Log clips, whose
/// frames must reach the compositor exactly as the file has them (AVFoundation's own conversion of
/// them is inaccurate).
final class ReverseFrames: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let naturalSize: CGSize
    /// HDR and Log are kept at 10 bits: their flat curves band badly in 8.
    private let pixelFormat: OSType

    private final class Chunk: @unchecked Sendable {
        let group = DispatchGroup()
        var frames: [(pts: Double, buffer: CVPixelBuffer)] = []
        var lastUsed = 0
    }

    private struct Key: Hashable {
        let index: Int
        let limit: Int
    }

    private let lock = NSLock()
    private var chunks: [Key: Chunk] = [:]
    private var clock = 0
    private var lastTouched = Date.distantPast
    private let fps: Double

    /// Every instance alive, so one that starts decoding can tell idle ones to let their frames go:
    /// decoded 4K frames are large, and a clip that has finished playing shouldn't keep them.
    private static let registry = NSHashTable<ReverseFrames>.weakObjects()
    private static let registryLock = NSLock()
    private let decodeQueue = DispatchQueue(label: "editroom.reverse", qos: .userInitiated, attributes: .concurrent)

    /// Extra reader settings: SDR Rec.709 for HDR, so AVFoundation converts it as it's read.
    private let readSettings: [String: Any]

    init(asset: AVAsset, track: AVAssetTrack, naturalSize: CGSize, tenBit: Bool = false, readSettings: [String: Any] = [:]) {
        self.readSettings = readSettings
        self.asset = asset
        self.track = track
        self.naturalSize = naturalSize
        pixelFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let rate = Double(track.nominalFrameRate)
        fps = rate > 1 ? rate : 30
        Self.registryLock.lock()
        Self.registry.add(self)
        Self.registryLock.unlock()
    }

    /// Lets go of every decoded frame if nothing has asked for one for a couple of seconds.
    private func releaseIfIdle(_ now: Date) {
        lock.lock(); defer { lock.unlock() }
        if now.timeIntervalSince(lastTouched) > 2 { chunks.removeAll() }
    }

    /// The frame showing at file time `t`, for playing forwards: the last one starting at or before it.
    func frame(at t: Double, limit: Int) -> CVPixelBuffer? {
        let len = chunkLength(limit: limit)
        let k = max(0, Int(floor((t + 1e-6) / len)))
        let chunk = self.chunk(k, limit: limit, length: len)
        _ = chunk.group.wait(timeout: .now() + 3)
        // Playing forwards needs the stretch after this one next.
        _ = self.chunk(k + 1, limit: limit, length: len)
        lock.lock()
        let found = chunk.frames.last(where: { $0.pts <= t + 1e-6 })?.buffer
        lock.unlock()
        if let found { return found }
        guard k > 0 else {
            lock.lock(); defer { lock.unlock() }
            return chunk.frames.first?.buffer
        }
        let previous = self.chunk(k - 1, limit: limit, length: len)
        _ = previous.group.wait(timeout: .now() + 3)
        lock.lock(); defer { lock.unlock() }
        return previous.frames.last?.buffer ?? chunk.frames.first?.buffer
    }

    /// Frames are kept no bigger than `limit` on their long side. Big frames are cached in shorter
    /// stretches to keep memory down.
    private func chunkLength(limit: Int) -> Double {
        // A stretch is a set number of frames (fewer when they're big), so a 60 or 120 fps file
        // doesn't hold several times the memory of a 24 fps one.
        limit > 2000 ? min(0.25, max(0.1, 8 / fps)) : min(0.5, max(0.15, 16 / fps))
    }

    /// The frame showing just before original time `t` (frames are held until the next one, so
    /// playing backwards from `t` starts with the frame that ends there).
    func frame(before t: Double, limit: Int) -> CVPixelBuffer? {
        let len = chunkLength(limit: limit)
        let k = max(0, Int(floor((t - 1e-6) / len)))
        let chunk = self.chunk(k, limit: limit, length: len)
        _ = chunk.group.wait(timeout: .now() + 3)
        // Playing backwards needs the stretch before this one next.
        if k > 0 { _ = self.chunk(k - 1, limit: limit, length: len) }
        lock.lock()
        let found = chunk.frames.last(where: { $0.pts < t - 1e-6 })?.buffer
        lock.unlock()
        if let found { return found }
        guard k > 0 else {
            lock.lock(); defer { lock.unlock() }
            return chunk.frames.first?.buffer
        }
        let previous = self.chunk(k - 1, limit: limit, length: len)
        _ = previous.group.wait(timeout: .now() + 3)
        lock.lock(); defer { lock.unlock() }
        return previous.frames.last?.buffer ?? chunk.frames.first?.buffer
    }

    private func chunk(_ k: Int, limit: Int, length: Double) -> Chunk {
        let key = Key(index: k, limit: limit)
        lock.lock()
        clock += 1
        lastTouched = Date()
        if let c = chunks[key] {
            c.lastUsed = clock
            lock.unlock()
            return c
        }
        let c = Chunk()
        c.lastUsed = clock
        c.group.enter()
        chunks[key] = c
        // Keep the three most recently used stretches: the one showing and those either side.
        if chunks.count > 3 {
            let old = chunks.filter { $0.key != key }.sorted { $0.value.lastUsed < $1.value.lastUsed }
            for (k, _) in old.prefix(chunks.count - 3) { chunks[k] = nil }
        }
        lock.unlock()
        Self.registryLock.lock()
        let others = Self.registry.allObjects.filter { $0 !== self }
        Self.registryLock.unlock()
        let now = Date()
        for other in others { other.releaseIfIdle(now) }
        decodeQueue.async { [self] in
            let frames = decode(from: Double(k) * length, to: Double(k + 1) * length, limit: limit)
            lock.lock()
            c.frames = frames
            lock.unlock()
            c.group.leave()
        }
        return c
    }

    private func decode(from start: Double, to end: Double, limit: Int) -> [(pts: Double, buffer: CVPixelBuffer)] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        settings.merge(readSettings) { $1 }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                       end: CMTime(seconds: end, preferredTimescale: 60000))
        guard reader.startReading() else { return [] }

        let longSide = max(naturalSize.width, naturalSize.height)
        let scale = longSide > CGFloat(limit) * 1.02 ? CGFloat(limit) / longSide : 1
        var session: VTPixelTransferSession?
        if scale < 1 { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) }
        let w = Int((naturalSize.width * scale / 2).rounded()) * 2
        let h = Int((naturalSize.height * scale / 2).rounded()) * 2

        var frames: [(pts: Double, buffer: CVPixelBuffer)] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts >= start - 1e-4, pts < end - 1e-4, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if let session {
                var small: CVPixelBuffer?
                CVPixelBufferCreate(nil, w, h, pixelFormat,
                                    [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                                     kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &small)
                if let small, VTPixelTransferSessionTransferImage(session, from: buffer, to: small) == noErr {
                    // Keep the colour tags, so the frame is read with the right matrix and curve.
                    CVBufferPropagateAttachments(buffer, small)
                    frames.append((pts, small))
                }
            } else {
                frames.append((pts, buffer))
            }
        }
        if let session { VTPixelTransferSessionInvalidate(session) }
        reader.cancelReading()
        return frames
    }
}

// MARK: - Sound

enum ReverseAudio {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Where a file's reversed sound is kept: named from the file's path, size and date, so it's
    /// made once and reused, even after relaunching.
    static func cacheURL(for source: URL) -> URL {
        Reverser.folder.appendingPathComponent(cacheName(for: source) + ".wav")
    }

    /// A file's name plus a hash of its path, size and date: changes whenever the file does.
    static func cacheName(for source: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        // The file's number on its disk too: one replaced by another of the same name, size and date (a rotated copy)
        // is a new file, so its frames and sound are made again rather than the old ones shown.
        let stamp = "\(source.path)|\(attrs?[.size] ?? 0)|\(attrs?[.modificationDate] ?? Date.distantPast)|\(attrs?[.systemFileNumber] ?? 0)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in stamp.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return source.deletingPathExtension().lastPathComponent + "-" + String(hash, radix: 36)
    }

    /// Writes the whole sound of a file backwards as 16-bit stereo WAV. The decoded sound goes to
    /// a scratch file first and is written out backwards from there, so memory stays small even
    /// for long recordings.
    static func render(asset: AVAsset, track: AVAssetTrack, to out: URL) throws {
        // Kept at the file's own rate, so nothing is resampled.
        var rate = 48000
        if let fmt = track.formatDescriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt as! CMAudioFormatDescription)?.pointee,
           asbd.mSampleRate >= 8000 { rate = Int(asbd.mSampleRate) }
        guard let reader = try? AVAssetReader(asset: asset) else { throw Failure(message: L10n.tr("Couldn't read the sound.")) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw Failure(message: L10n.tr("Couldn't read the sound.")) }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".raw")
        FileManager.default.createFile(atPath: scratch.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sink = try FileHandle(forWritingTo: scratch)
        var chunk = Data()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let base = chunk.count
            chunk.count += length
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress! + base)
            }
            if chunk.count > 4 << 20 { sink.write(chunk); chunk.removeAll(keepingCapacity: true) }
        }
        sink.write(chunk)
        try sink.close()
        guard reader.status == .completed else { throw Failure(message: L10n.tr("Couldn't read the sound.")) }

        let decoded = try Data(contentsOf: scratch, options: .alwaysMapped)
        let frames = decoded.count / 4
        let partial = out.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let file = try FileHandle(forWritingTo: partial)
        file.write(wavHeader(frames: frames, rate: rate))
        // Backwards, a block at a time: each frame is 4 bytes (left and right).
        let block = 1 << 18
        var end = frames
        var buffer = [UInt32](repeating: 0, count: block)
        decoded.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt32.self)
            while end > 0 {
                let start = max(0, end - block)
                let n = end - start
                for i in 0..<n { buffer[i] = src[end - 1 - i] }
                buffer.withUnsafeBytes { file.write(Data(bytes: $0.baseAddress!, count: n * 4)) }
                end = start
            }
        }
        try file.close()
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: partial, to: out)
    }

    private static func wavHeader(frames: Int, rate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = frames * 4
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        return d
    }
}
