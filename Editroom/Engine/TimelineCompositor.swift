import AVFoundation
import CoreImage
import Metal

/// Where a video layer's picture comes from in its file, for showing it from the scrub frames.
struct ScrubSource {
    let asset: UUID
    let clock: SourceClock
    /// Played backwards: the file's length, which the time is counted back from.
    var reversedLength: Double? = nil

    func time(at t: Double) -> Double {
        let s = clock.source(at: t - 1e-4)
        return reversedLength.map { $0 - s } ?? s
    }
}

/// One visual element on the timeline, already resolved for a specific render size.
struct RenderLayer {
    enum Source {
        case track(CMPersistentTrackID, CGImagePropertyOrientation)
        case image(CIImage)
        case color(CIColor)
        /// Played backwards: at timeline time t the frame is the one just before file time
        /// `length - clock.source(at: t)`, kept no bigger than `limit` pixels.
        case reversed(ReverseFrames, CGImagePropertyOrientation, limit: Int, clock: SourceClock, length: Double)
        /// Played forwards, read straight from the file (HDR and Log): at timeline time t the frame
        /// is the one showing at file time `clock.source(at: t)`.
        case decoded(ReverseFrames, CGImagePropertyOrientation, limit: Int, clock: SourceClock)
    }

    /// When the layer is drawn: the clip, plus any extra a transition shows before or after it.
    let start: Double
    let end: Double
    /// The clip itself, which its own fades are measured from.
    let fadeStart: Double
    let fadeEnd: Double
    let reveal: TransitionEdge?
    let conceal: TransitionEdge?
    let fadeIn: Double
    let fadeOut: Double
    let inCurve: FadeCurve
    let outCurve: FadeCurve
    let source: Source
    /// Baked colour cube for this clip's grade, if it has one.
    let cube: Data?
    /// How the source file's picture is encoded; HDR and Log are converted to Rec.709 first.
    let color: SourceColor
    let transform: ClipTransform?
    /// A video layer's place in its file, for scrubbing from made-ahead frames (nil: not from them).
    let scrub: ScrubSource?

    init(clip: Clip, source: Source, cube: Data? = nil, color: SourceColor = .standard, plan: TransitionPlan = TransitionPlan(),
         scrub: ScrubSource? = nil) {
        self.scrub = scrub
        self.cube = cube
        self.color = color
        transform = clip.transform.flatMap { $0.isIdentity ? nil : $0 }
        start = clip.start - plan.leadIn
        end = clip.end + plan.tailOut
        fadeStart = clip.start
        fadeEnd = clip.end
        reveal = plan.reveal
        conceal = plan.conceal
        fadeIn = clip.fadeIn
        fadeOut = clip.fadeOut
        inCurve = clip.inCurve
        outCurve = clip.outCurve
        self.source = source
    }

    func opacity(at t: Double) -> Double {
        var o = 1.0
        // The clip's own fades; in the extra a transition shows, they hold their value at that end.
        let ft = min(max(t, fadeStart), fadeEnd)
        if fadeIn > 0 { o = min(o, inCurve.apply((ft - fadeStart) / fadeIn)) }
        if fadeOut > 0 { o = min(o, outCurve.apply((fadeEnd - ft) / fadeOut)) }
        if let r = reveal, r.kind != .wipe { o *= r.progress(t) }
        if let c = conceal { o *= 1 - c.progress(t) }
        return max(0, min(1, o))
    }

    /// For a wipe in progress, how much of the picture (from the left) is showing.
    func wipe(at t: Double) -> Double? {
        guard let r = reveal, r.kind == .wipe, t < r.end else { return nil }
        let p = r.progress(t)
        return p * p * (3 - 2 * p)
    }
}

/// A single instruction spans the whole timeline; the compositor resolves what is visible per frame.
final class TimelineInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    /// Bottom-most first.
    let layers: [RenderLayer]

    /// The sequence is laid out at this size, and the output is the window at `offset` within it
    /// (the same as the output, unless exporting to a different shape).
    let canvas: CGSize
    let offset: CGPoint
    /// Captions, drawn over everything in the output's own frame.
    let captions: [CaptionLayer]
    /// Video drawn bigger than its own pixels is enlarged with the upscaler (on export), not just stretched.
    let upscale: Bool
    /// An HDR project: put together in HDR (HLG, Rec.2020), SDR at standard white within it.
    let hdr: Bool

    init(timeRange: CMTimeRange, layers: [RenderLayer], trackIDs: [CMPersistentTrackID], canvas: CGSize, offset: CGPoint = .zero,
         captions: [CaptionLayer] = [], upscale: Bool = false, hdr: Bool = false) {
        self.upscale = upscale
        self.hdr = hdr
        self.timeRange = timeRange
        self.canvas = canvas
        self.offset = offset
        self.layers = layers
        self.captions = captions
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
    }
}

class TimelineCompositor: NSObject, AVVideoCompositing {
    /// HDR projects: colour-managed, in linear Rec.2020 at half float, so HDR and SDR (at standard white, as
    /// BT.2408 places it) go together and come out as HLG. SDR projects use `context`, untouched.
    static let hdrContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()
    static let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    static let rec709 = CGColorSpace(name: CGColorSpace.itur_709)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    private let queue = DispatchQueue(label: "editroom.compositor", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0

    // Take frames in the decoder's own YUV formats (8- and 10-bit), so a 4K frame isn't converted to
    // RGB on the way in; Core Image converts on the GPU as part of compositing.
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelFormatType_32BGRA,
            ],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock()
        let gen = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = gen != self.generation
            self.lock.unlock()
            if stale {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? TimelineInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Editroom", code: 1))
                return
            }
            let image = Self.compose(instruction, request: request)
            let size = request.renderContext.size
            Self.render(image, to: output, size: size, hdr: instruction.hdr)
            request.finish(withComposedVideoFrame: output)
        }
    }

    /// Draws a composed frame into `output` and tags it: Rec.709, or in an HDR project HLG in Rec.2020. Saying so
    /// stops the encoder or display from "converting" a frame again because it inherited a source's tags.
    static func render(_ image: CIImage, to output: CVPixelBuffer, size: CGSize, hdr: Bool) {
        let bounds = CGRect(origin: .zero, size: size)
        if hdr {
            hdrContext.render(image, to: output, bounds: bounds, colorSpace: hlg)
        } else {
            context.render(image, to: output, bounds: bounds, colorSpace: nil)
        }
        tag(output, hdr: hdr)
    }

    static func tag(_ buffer: CVPixelBuffer, hdr: Bool) {
        CVBufferRemoveAllAttachments(buffer)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              hdr ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private static func compose(_ instruction: TimelineInstruction, request: AVAsynchronousVideoCompositionRequest) -> CIImage {
        let t = request.compositionTime.seconds + 1e-4
        // HDR: the frame's values as they are; what they mean (HLG or Rec.709) is said per layer below.
        let raw: [CIImageOption: Any]? = instruction.hdr ? [.colorSpace: NSNull()] : nil
        return compose(instruction, at: t, output: request.renderContext.size) { _, layer in
            let buffer: CVPixelBuffer?
            switch layer.source {
            case .track(let id, _): buffer = request.sourceFrame(byTrackID: id)
            case .reversed(let frames, _, let limit, let clock, let length): buffer = frames.frame(before: length - clock.source(at: t - 1e-4), limit: limit)
            case .decoded(let frames, _, let limit, let clock): buffer = frames.frame(at: clock.source(at: t - 1e-4), limit: limit)
            default: buffer = nil
            }
            return buffer.map { CIImage(cvPixelBuffer: $0, options: raw) }
        }
    }

    /// The frame at timeline time `t`: every layer showing then, bottom first. `picture` gives a video
    /// layer's own frame, as it comes from the file (the player's decoded frame, or a scrub frame).
    static func compose(_ instruction: TimelineInstruction, at t: Double, output: CGSize,
                        picture: (Int, RenderLayer) -> CIImage?) -> CIImage {
        let size = instruction.canvas
        let frame = CGRect(origin: .zero, size: size)
        var out = CIImage(color: .black).cropped(to: frame)

        for (index, layer) in instruction.layers.enumerated() where t >= layer.start && t < layer.end {
            let opacity = layer.opacity(at: t)
            if opacity <= 0.001 { continue }
            var image: CIImage
            switch layer.source {
            case .track(_, let orientation), .reversed(_, let orientation, _, _, _), .decoded(_, let orientation, _, _):
                guard var src = picture(index, layer) else { continue }
                if orientation != .up { src = src.oriented(orientation) }
                let e = src.extent
                guard e.width > 0, e.height > 0 else { continue }
                let s = min(size.width / e.width, size.height / e.height)
                if instruction.upscale, s > 1.01,
                   let up = Upscaler.shared.upscale(src.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)),
                                                    to: CGSize(width: e.width * s, height: e.height * s), slot: index, context: context) {
                    // Enlarged with detail rebuilt, then centred as the plain fit would be.
                    let u = up.extent
                    image = up.transformed(by: CGAffineTransform(translationX: (size.width - u.width) / 2 - u.minX,
                                                                 y: (size.height - u.height) / 2 - u.minY))
                } else {
                    let tx = (size.width - e.width * s) / 2 - e.minX * s
                    let ty = (size.height - e.height * s) / 2 - e.minY * s
                    image = src.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty))
                }
                // After scaling, so a 4K source is converted at the output's size.
                image = layer.color.toRec709(image)
                // HDR: HDR clips are HLG (PQ arrives as HLG); SDR and Log (Rec.709 by now) go in at standard white.
                if instruction.hdr { image = image.matchedToWorkingSpace(from: layer.color.isHDR ? hlg : rec709) ?? image }
            case .image(let img):
                image = img
            case .color(let color):
                // HDR: a solid's colour is SDR (sRGB), at standard white at most.
                let c = instruction.hdr ? CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha, colorSpace: sRGB) ?? color : color
                image = CIImage(color: c).cropped(to: frame)
            }
            if let w = layer.wipe(at: t) {
                image = image.cropped(to: CGRect(x: 0, y: 0, width: size.width * w, height: size.height))
            }
            if let tf = layer.transform?.at(t - layer.fadeStart) {
                // Scale about the frame's centre, then offset (Core Image's y runs up).
                let cx = size.width / 2, cy = size.height / 2
                let m = CGAffineTransform(translationX: -cx, y: -cy)
                    .concatenating(CGAffineTransform(scaleX: tf.scale, y: tf.scale))
                    .concatenating(CGAffineTransform(translationX: cx + tf.x * size.width, y: cy - tf.y * size.height))
                image = image.transformed(by: m)
            }
            if let cube = layer.cube {
                // HDR: graded on the HLG signal, which runs 0...1 like the cube (highlights above standard white
                // included), then back.
                if instruction.hdr { image = image.matchedFromWorkingSpace(to: hlg) ?? image }
                image = image.applyingFilter("CIColorCube", parameters: [
                    "inputCubeDimension": GradeCube.dimension,
                    "inputCubeData": cube,
                ])
                if instruction.hdr { image = image.matchedToWorkingSpace(from: hlg) ?? image }
            }
            if opacity < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
                ])
            }
            out = image.composited(over: out)
        }
        if instruction.offset != .zero || output != size {
            out = out.transformed(by: CGAffineTransform(translationX: -instruction.offset.x, y: -instruction.offset.y))
        }
        out = out.cropped(to: CGRect(origin: .zero, size: output))
        for caption in instruction.captions where t >= caption.start && t < caption.end {
            if let image = caption.image(output: output) { out = image.composited(over: out) }
        }
        return out.cropped(to: CGRect(origin: .zero, size: output))
    }
}

/// HDR projects' compositor: takes HDR frames as they are (10-bit HLG) and makes half-float HLG frames.
final class HDRTimelineCompositor: TimelineCompositor {
    var supportsHDRSourceFrames: Bool { true }
    var supportsWideColorSourceFrames: Bool { true }

    // 10-bit formats only for what may be HDR (no 8-bit RGB, which would clip it), plus 8-bit YUV for the blank
    // base track. ProRes HDR arrives in 4:2:2.
    override var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        ]
    }

    override var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        ]
    }
}
