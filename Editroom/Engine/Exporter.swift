import Combine
import AVFoundation
import AppKit
import VideoToolbox

struct ExportSettings: Equatable {
    enum Format: String, CaseIterable { case mp4 = "Video", wav = "Audio" }
    enum Quality: String, CaseIterable { case high = "High", web = "Web" }
    enum Codec: String, CaseIterable { case h264 = "H.264", hevc = "HEVC" }

    var format = Format.mp4
    /// Output height; nil keeps the sequence size.
    var height: Int?
    var codec = Codec.h264
    var quality = Quality.high
    var includeAudio = true
    /// Target integrated loudness in LUFS; nil leaves levels as they are.
    var loudness: Double?
    /// The output's shape. Anything but the sequence's own crops the picture to fit.
    var shape = Shape.original
    /// Which part of the picture to keep when cropping, as the crop's centre (0...1 across and down).
    var reframe = CGPoint(x: 0.5, y: 0.5)
    /// Export just the in/out range, when the timeline has one.
    var rangeOnly = false

    /// What gets exported: the whole timeline, or just its in/out range moved to start at zero.
    func output(_ project: Project) -> Project {
        guard rangeOnly, let r = project.playRange else { return project }
        return project.cropped(to: r)
    }

    enum Shape: String, CaseIterable {
        case original, vertical, square, portrait

        var label: String {
            switch self {
            case .original: return "Sequence shape"
            case .vertical: return "Vertical 9:16"
            case .square: return "Square 1:1"
            case .portrait: return "Portrait 4:5"
            }
        }

        /// Height over width, or nil for the sequence's own shape.
        var tallness: Double? {
            switch self {
            case .original: return nil
            case .vertical: return 16.0 / 9.0
            case .square: return 1
            case .portrait: return 5.0 / 4.0
            }
        }
    }

    func renderSize(for project: Project) -> CGSize {
        func even(_ v: Double) -> CGFloat { max(2, CGFloat((v / 2).rounded() * 2)) }
        if let tall = shape.tallness {
            // The resolution names the short side; crops are never taller-than-wide in the other direction.
            let short = Double(height ?? min(project.width, project.height))
            return CGSize(width: even(short), height: even(short * tall))
        }
        let h = Double(height ?? project.height)
        let w = h * Double(project.width) / Double(max(1, project.height))
        return CGSize(width: even(w), height: even(h))
    }

    /// Whether the output crops the sequence's picture.
    func crops(_ project: Project) -> Bool {
        let s = renderSize(for: project)
        return abs(Double(s.width / s.height) - Double(project.aspect)) > 0.01
    }

    func videoBitrate(size: CGSize, fps: Double) -> Int {
        var bpp = quality == .high ? 0.2 : 0.085
        if codec == .hevc { bpp *= 0.62 }
        return Int(Double(size.width * size.height) * min(fps, 60) * bpp)
    }

    var fileExtension: String { format == .mp4 ? "mp4" : "wav" }
}

@MainActor
final class Exporter: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case done(URL)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var progress = 0.0
    private var job: ExportJob?

    func reset() {
        if state != .running { state = .idle }
    }

    func cancel() {
        job?.cancelled = true
        measuringCancelled = true
    }

    private var measuringCancelled = false

    func start(project whole: Project, media: MediaStore, settings: ExportSettings, url: URL) {
        guard state != .running else { return }
        let project = settings.output(whole)
        progress = 0
        if media.needsReversedAudio(project) {
            // Reversed clips' sound is still being made: wait for it first.
            state = .running
            measuringCancelled = false
            Task {
                await media.prepareReversedAudio(for: project)
                guard !measuringCancelled else { state = .idle; return }
                state = .idle
                start(project: project, media: media, settings: settings, url: url)
            }
            return
        }
        let wantsAudio = settings.format == .wav || settings.includeAudio
        if let target = settings.loudness, wantsAudio,
           let mix = CompositionBuilder.build(project: project, media: media, renderSize: CGSize(width: 16, height: 16),
                                              includeVideo: false, includeAudio: true), mix.hasAudio {
            // Measure the mix first, then export with every track turned by the same amount, kept
            // 1 dB under full scale so the result can't clip.
            state = .running
            measuringCancelled = false
            Task.detached(priority: .userInitiated) {
                let result = LoudnessMeter.measure(mix)
                await MainActor.run {
                    guard !self.measuringCancelled else {
                        self.state = .idle
                        return
                    }
                    var adjusted = project
                    if let result {
                        let gain = min(target - result.lufs, -1 - result.peakDB)
                        for i in adjusted.audioTracks.indices { adjusted.audioTracks[i].gainDB += gain }
                    }
                    self.begin(project: adjusted, media: media, settings: settings, url: url)
                }
            }
            return
        }
        begin(project: project, media: media, settings: settings, url: url)
    }

    private func begin(project: Project, media: MediaStore, settings: ExportSettings, url: URL) {
        progress = 0
        let wav = settings.format == .wav
        let size = settings.renderSize(for: project)
        guard let built = CompositionBuilder.build(project: project, media: media, renderSize: size,
                                                   includeVideo: !wav, includeAudio: wav || settings.includeAudio,
                                                   reframe: settings.crops(project) ? settings.reframe : nil,
                                                   // Video drawn bigger than its pixels (a 1080p sequence at 4K) is upscaled, not stretched.
                                                   upscale: true) else {
            state = .failed("The timeline is empty.")
            return
        }
        if wav && !built.hasAudio {
            state = .failed("There's no audio on the timeline.")
            return
        }
        do {
            let job = try ExportJob(built: built, settings: settings, size: size, fps: project.fps, url: url)
            self.job = job
            state = .running
            job.run(progress: { [weak self] p in
                Task { @MainActor in
                    guard let self, self.state == .running else { return }
                    self.progress = max(self.progress, p)
                }
            }, completion: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.job = nil
                    // The upscaler's frames (a few hundred MB at 4K) aren't kept between exports.
                    Upscaler.shared.purge()
                    if let error {
                        self.state = (error as? ExportJob.Cancelled) != nil ? .idle : .failed(error.localizedDescription)
                    } else {
                        self.progress = 1
                        self.state = .done(url)
                    }
                }
            })
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Exports run one after another in the background while editing carries on. Each one renders the
/// timeline as it was when it was added.
@MainActor
final class ExportQueue: ObservableObject {
    enum Status: Equatable { case waiting, running, done, failed(String), cancelled }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let project: Project
        let settings: ExportSettings
        var status = Status.waiting
        var name: String { url.lastPathComponent }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var progress = 0.0
    private var startedAt = Date()
    private let exporter = Exporter()
    private weak var media: MediaStore?
    private var bag: [Any] = []
    private var clearTimer: Timer?

    init() {
        bag.append(exporter.$progress.sink { [weak self] p in self?.progress = p })
        bag.append(exporter.$state.sink { [weak self] state in
            // Published before the value changes; read it on the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exporterChanged(state) } }
        })
    }

    var current: Item? { items.first { $0.status == .running } }
    var waiting: Int { items.filter { $0.status == .waiting }.count }
    var isBusy: Bool { items.contains { $0.status == .running || $0.status == .waiting } }

    /// Seconds left on the current export, once there's enough progress to guess.
    var timeLeft: Double? {
        guard current != nil, progress > 0.03 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        return elapsed / progress * (1 - progress)
    }

    func add(project: Project, media: MediaStore, settings: ExportSettings, url: URL) {
        self.media = media
        clearTimer?.invalidate()
        items.append(Item(url: url, project: project, settings: settings))
        startNext()
    }

    func cancel(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].status == .running {
            exporter.cancel()
        } else if items[i].status == .waiting {
            items[i].status = .cancelled
        }
    }

    func clearFinished() {
        items.removeAll { $0.status != .running && $0.status != .waiting }
    }

    private func startNext() {
        guard current == nil, let media, let i = items.firstIndex(where: { $0.status == .waiting }) else {
            if !isBusy, !items.isEmpty { scheduleClear() }
            return
        }
        items[i].status = .running
        progress = 0
        startedAt = Date()
        let item = items[i]
        exporter.reset()
        exporter.start(project: item.project, media: media, settings: item.settings, url: item.url)
    }

    private func exporterChanged(_ state: Exporter.State) {
        guard let i = items.firstIndex(where: { $0.status == .running }) else { return }
        switch exporter.state {
        case .running: return
        case .done: items[i].status = .done
        case .failed(let message): items[i].status = .failed(message)
        case .idle: items[i].status = .cancelled
        }
        startNext()
    }

    /// Finished exports stay in the toolbar a little while, then tidy themselves away.
    private func scheduleClear() {
        clearTimer?.invalidate()
        clearTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isBusy, !self.holdOpen else { return }
                self.clearFinished()
            }
        }
    }

    /// Set while the list is open, so finished items don't vanish from under the mouse.
    var holdOpen = false {
        didSet { if !holdOpen, !isBusy { scheduleClear() } }
    }
}

/// Reads the composition through the custom compositor and audio mix, and encodes it.
final class ExportJob {
    struct Cancelled: Error {}

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
    private let duration: Double
    private let url: URL
    /// An HDR project's export: frames are HLG in Rec.2020.
    private var hdr = false
    var cancelled = false

    init(built: BuiltTimeline, settings: ExportSettings, size: CGSize, fps: Double, url: URL) throws {
        self.url = url
        duration = built.duration
        try? FileManager.default.removeItem(at: url)
        let wav = settings.format == .wav
        reader = try AVAssetReader(asset: built.composition)
        writer = try AVAssetWriter(outputURL: url, fileType: wav ? .wav : .mp4)
        writer.shouldOptimizeForNetworkUse = true

        if !wav {
            // An HDR project: 10-bit HEVC in HLG, Rec.2020 (H.264 can't carry HDR), as an iPhone records it.
            hdr = built.videoComposition.colorTransferFunction == AVVideoTransferFunction_ITU_R_2100_HLG
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: built.composition.tracks(withMediaType: .video),
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                    hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA])
            output.videoComposition = built.videoComposition
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw NSError(domain: "Editroom", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't set up video rendering."]) }
            reader.add(output)

            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: settings.videoBitrate(size: size, fps: fps),
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int((fps * 2).rounded()),
            ]
            if hdr {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            } else if settings.codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: settings.codec == .h264 && !hdr ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: compression,
                AVVideoColorPropertiesKey: hdr ? [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
                ] : [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw NSError(domain: "Editroom", code: 3, userInfo: [NSLocalizedDescriptionKey: "This resolution isn't supported by the encoder."]) }
            writer.add(input)
            pairs.append((output, input))
        }

        if built.hasAudio {
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: wav ? 24 : 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderAudioMixOutput(audioTracks: built.composition.tracks(withMediaType: .audio), audioSettings: pcm)
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                var stereo = AudioChannelLayout()
                stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
                let layout = Data(bytes: &stereo, count: MemoryLayout<AudioChannelLayout>.size)
                var settingsOut: [String: Any] = wav ? pcm : [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: settings.quality == .high ? 256_000 : 160_000,
                ]
                settingsOut[AVChannelLayoutKey] = layout
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settingsOut)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    pairs.append((output, input))
                }
            }
        }
        guard !pairs.isEmpty else { throw NSError(domain: "Editroom", code: 4, userInfo: [NSLocalizedDescriptionKey: "Nothing to export."]) }
    }

    func run(progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        guard writer.startWriting() else { return completion(writer.error ?? Cancelled()) }
        guard reader.startReading() else {
            writer.cancelWriting()
            return completion(reader.error ?? Cancelled())
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let total = max(duration, 0.001)
        for (index, pair) in pairs.enumerated() {
            let (output, input) = pair
            let queue = DispatchQueue(label: "editroom.export.\(index)")
            var lastReported = -1.0
            group.enter()
            input.requestMediaDataWhenReady(on: queue) { [weak self] in
                while input.isReadyForMoreMediaData {
                    guard let self, !self.cancelled, let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if index == 0 {
                        let p = CMSampleBufferGetPresentationTimeStamp(sample).seconds / total
                        if p - lastReported >= 0.005 {
                            lastReported = p
                            progress(min(1, p))
                        }
                    }
                    // Frames are Rec.709 once composited (HLG in an HDR project), whatever the sources were. Without
                    // this the encoder sees a source's tags (or ICC profile) and converts the colours a second time.
                    if let frame = CMSampleBufferGetImageBuffer(sample) {
                        TimelineCompositor.tag(frame, hdr: self.hdr)
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) { [self] in
            if cancelled {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                completion(Cancelled())
            } else if reader.status == .failed {
                writer.cancelWriting()
                completion(reader.error ?? Cancelled())
            } else if writer.status == .failed {
                completion(writer.error ?? Cancelled())
            } else {
                writer.finishWriting { [self] in
                    completion(writer.status == .completed ? nil : (writer.error ?? Cancelled()))
                }
            }
        }
    }
}
