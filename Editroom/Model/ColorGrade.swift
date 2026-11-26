import Foundation

/// Per-clip colour correction: an optional look, five basic adjustments, and three tint wheels.
struct ColorGrade: Codable, Hashable {
    /// A built-in look's name, or the path of a .cube file. Nil for none.
    var look: String?
    var lookIntensity = 1.0
    /// Stops, -2...2.
    var exposure = 0.0
    /// -50...50.
    var contrast = 0.0
    /// -100...100.
    var saturation = 0.0
    /// -50...50, negative is cooler.
    var temperature = 0.0
    /// -50...50, positive is toward magenta.
    var tint = 0.0
    /// Wheel positions inside the unit circle: x right, y down. Red sits at 0°, green at 120°, blue at 240°.
    var shadows = WheelPoint()
    var midtones = WheelPoint()
    var highlights = WheelPoint()

    /// No look and every adjustment at zero. The look's strength doesn't count without a look (it isn't
    /// shown then, and a look taken away can leave it behind).
    var isNeutral: Bool {
        var g = self
        if g.look == nil { g.lookIntensity = ColorGrade().lookIntensity }
        return g == ColorGrade()
    }

    var lookLabel: String {
        guard let look else { return "None" }
        if BuiltInLook.named(look) != nil { return look }
        return URL(fileURLWithPath: look).deletingPathExtension().lastPathComponent
    }

    var localizedLookLabel: String {
        guard let look else { return L10n.tr("None") }
        if BuiltInLook.named(look) != nil { return BuiltInLook.displayName(look) }
        return URL(fileURLWithPath: look).deletingPathExtension().lastPathComponent
    }
}

struct WheelPoint: Codable, Hashable {
    var x = 0.0
    var y = 0.0

    /// RGB offset this wheel position adds, before weighting by tonal range.
    var offset: (Double, Double, Double) {
        let m = min(1, (x * x + y * y).squareRoot()) * 0.22
        guard m > 0 else { return (0, 0, 0) }
        let a = atan2(y, x)
        let third = 2 * Double.pi / 3
        return (cos(a) * m, cos(a - third) * m, cos(a + third) * m)
    }
}

/// The primitive operations every look and every user grade is made of.
struct GradeRecipe {
    var exposure = 0.0
    var contrast = 0.0
    var saturation = 0.0
    var temperature = 0.0
    var tint = 0.0
    var shadows = (0.0, 0.0, 0.0)
    var midtones = (0.0, 0.0, 0.0)
    var highlights = (0.0, 0.0, 0.0)
    var lift = (0.0, 0.0, 0.0)
    var fade = 0.0
    /// A look with its own maths (see LookMath), used instead of the steps above.
    var custom: (((Double, Double, Double)) -> (Double, Double, Double))?

    func apply(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        if let custom { return custom(rgb) }
        var (r, g, b) = rgb
        let gain = pow(2, exposure)
        r *= gain; g *= gain; b *= gain
        let t = temperature / 50 * 0.12, ti = tint / 50 * 0.1
        r += t; b -= t; g -= ti
        // Tonal weights from luma: shadows fall off toward white, highlights toward black.
        let l = min(1, max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b))
        let sh = 1 - l, mid = 4 * l * (1 - l)
        r += shadows.0 * sh + midtones.0 * mid + highlights.0 * l + lift.0
        g += shadows.1 * sh + midtones.1 * mid + highlights.1 * l + lift.1
        b += shadows.2 * sh + midtones.2 * mid + highlights.2 * l + lift.2
        let k = 1 + contrast / 50 * 0.6
        r = (r - 0.5) * k + 0.5; g = (g - 0.5) * k + 0.5; b = (b - 0.5) * k + 0.5
        if fade != 0 {
            r = r * (1 - fade) + fade; g = g * (1 - fade) + fade; b = b * (1 - fade) + fade
        }
        let l2 = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let s = 1 + saturation / 100
        return (l2 + (r - l2) * s, l2 + (g - l2) * s, l2 + (b - l2) * s)
    }
}

enum BuiltInLook {
    /// The Looks offered in the menu, in order.
    static let all: [(name: String, recipe: GradeRecipe)] = [
        ("Warm film", GradeRecipe(contrast: 8, saturation: -8, temperature: 18, lift: (0.02, 0, -0.02), fade: 0.03)),
        ("Golden hour", GradeRecipe(custom: LookMath.goldenHour)),
        ("Film print", GradeRecipe(custom: LookMath.filmPrint)),
        ("Teal and orange", GradeRecipe(contrast: 12, saturation: 10, shadows: (-0.05, 0.01, 0.05), highlights: (0.06, 0.01, -0.05))),
        ("Pastel", GradeRecipe(custom: LookMath.pastel)),
        ("Bleach bypass", GradeRecipe(custom: LookMath.bleachBypass)),
        ("Mono", GradeRecipe(contrast: 14, saturation: -100)),
        ("Cool night", GradeRecipe(exposure: -0.25, contrast: 6, saturation: -15, temperature: -22)),
    ]

    /// No longer offered, but still read, so projects that used them look the same.
    private static let retired: [(name: String, recipe: GradeRecipe)] = [
        ("Faded", GradeRecipe(contrast: -18, saturation: -20, fade: 0.07)),
    ]

    static func named(_ name: String) -> GradeRecipe? {
        (all + retired).first { $0.name == name }?.recipe
    }

    static func displayName(_ name: String) -> String {
        L10n.tr(name)
    }
}

/// Looks that need more than GradeRecipe's steps: a soft S-curve, tints weighted toward the
/// shadows or highlights. Values are Rec.709-encoded 0...1, as in every grade.
enum LookMath {
    typealias RGB = (Double, Double, Double)

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func luma(_ c: RGB) -> Double { 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 }
    private static func each(_ c: RGB, _ f: (Double) -> Double) -> RGB { (f(c.0), f(c.1), f(c.2)) }
    /// Positive adds an S-curve; negative flattens.
    private static func contrast(_ c: RGB, _ k: Double) -> RGB {
        each(c) { x in let x = clamp(x), s = x * x * (3 - 2 * x); return clamp(x + k * (s - x) * 2) }
    }
    private static func fade(_ c: RGB, _ f: Double) -> RGB { each(c) { f + (1 - f) * $0 } }
    private static func saturate(_ c: RGB, _ s: Double) -> RGB { let l = luma(c); return each(c) { clamp(l + s * ($0 - l)) } }
    private static func add(_ c: RGB, _ t: RGB, _ w: Double = 1) -> RGB {
        (clamp(c.0 + t.0 * w), clamp(c.1 + t.1 * w), clamp(c.2 + t.2 * w))
    }
    /// Tints that land mostly in the shadows and mostly in the highlights.
    private static func split(_ c: RGB, shadows: RGB, highlights: RGB) -> RGB {
        let l = clamp(luma(c))
        return add(add(c, shadows, (1 - l) * (1 - l)), highlights, l * l)
    }

    private static func toHSV(_ c: RGB) -> (h: Double, s: Double, v: Double) {
        let mx = max(c.0, c.1, c.2), mn = min(c.0, c.1, c.2), d = mx - mn
        var h = 0.0
        if d > 1e-6 {
            if mx == c.0 { h = 60 * ((c.1 - c.2) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.1 { h = 60 * ((c.2 - c.0) / d + 2) }
            else { h = 60 * ((c.0 - c.1) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    private static func fromHSV(_ h: Double, _ s: Double, _ v: Double) -> RGB {
        let c = v * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        switch h {
        case ..<60: return (c + m, x + m, m)
        case ..<120: return (x + m, c + m, m)
        case ..<180: return (m, c + m, x + m)
        case ..<240: return (m, x + m, c + m)
        case ..<300: return (x + m, m, c + m)
        default: return (c + m, m, x + m)
        }
    }

    /// Shifts the hue and scales the saturation (and brightness) of colours near `center`, fading
    /// out over `width` degrees and leaving greys and near-whites alone.
    private static func hueBand(_ c: RGB, center: Double, width: Double, shift: Double, sat: Double, value: Double = 1) -> RGB {
        var (h, s, v) = toHSV(c)
        var d = abs(h - center)
        if d > 180 { d = 360 - d }
        guard d < width else { return c }
        let w = (0.5 + 0.5 * cos(d / width * .pi)) * min(1, s * 2.5)
        h = (h + shift * w + 360).truncatingRemainder(dividingBy: 360)
        s = clamp(s * (1 + (sat - 1) * w))
        v = clamp(v * (1 + (value - 1) * w))
        return fromHSV(h, s, v)
    }

    /// The warm film-print look, inspired by Kodak 2383 print film: golden skin, dense rich reds,
    /// teal-leaning shadows, filmic contrast, and a touch of fade for soft blacks. Our own maths,
    /// with its settings tuned until it behaves like that print film on test footage.
    static func filmPrint(_ c: RGB) -> RGB {
        let p = filmPrintSettings
        var c = add(each(c, clamp), (p[0], p[1], p[2]))
        c = each(c) { pow(clamp($0), p[3]) }
        c = hueBand(c, center: 28, width: 22, shift: p[4], sat: p[5])
        c = hueBand(c, center: 110, width: 60, shift: p[6], sat: p[7])
        c = hueBand(c, center: 210, width: 45, shift: p[8], sat: p[9])
        c = split(c, shadows: (p[10], p[11], p[12]), highlights: (p[13], p[14], p[15]))
        c = contrast(c, p[16])
        c = saturate(c, p[17])
        c = hueBand(c, center: 356, width: 20, shift: 0, sat: p[18], value: p[19])
        return fade(c, 0.035)
    }

    /// Warmth (r, g, b), gamma, skin hue/saturation, green hue/saturation, blue hue/saturation,
    /// shadow tint (r, g, b), highlight tint (r, g, b), contrast, saturation, red saturation and brightness.
    private static let filmPrintSettings: [Double] = [
        0.1260, 0.0872, 0.1130, 0.9273, 4.3723, 1.1754, -6.7912, 0.8993, -3.0058, 1.0943,
        -0.2338, -0.1982, -0.2908, -0.1016, -0.0275, -0.0710, 0.1846, 0.8248, 1.0324, 1.0304,
    ]

    /// Amber highlights, slightly cool shadows: late-afternoon light.
    static func goldenHour(_ c: RGB) -> RGB {
        var c = split(c, shadows: (-0.012, 0, 0.03), highlights: (0.085, 0.04, -0.06))
        c = contrast(c, 0.08)
        return saturate(c, 1.08)
    }

    /// High contrast and very little colour.
    static func bleachBypass(_ c: RGB) -> RGB {
        var c = saturate(each(c, clamp), 0.42)
        c = contrast(c, 0.42)
        return add(c, (-0.01, 0, 0.008))
    }

    /// Lifted shadows, soft bright colours.
    static func pastel(_ c: RGB) -> RGB {
        var c = each(c) { pow(clamp($0), 0.8) }
        c = contrast(c, -0.36)
        c = fade(c, 0.14)
        c = split(c, shadows: (0.03, 0, 0.05), highlights: (0.01, 0, 0.012))
        return saturate(c, 0.8)
    }
}

/// A 3D lookup table read from a .cube file.
final class CubeLUT {
    let size: Int
    /// size³ RGB triples, red varying fastest.
    private let values: [Float]

    init?(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var size = 0
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts[0] == "LUT_3D_SIZE", parts.count > 1 {
                size = Int(parts[1]) ?? 0
                values.reserveCapacity(size * size * size * 3)
            } else if parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                values.append(r); values.append(g); values.append(b)
            }
        }
        guard size >= 2, size <= 256, values.count == size * size * size * 3 else { return nil }
        self.size = size
        self.values = values
    }

    /// Trilinear lookup.
    func sample(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let n = Double(size - 1)
        func split(_ v: Double) -> (Int, Int, Double) {
            let p = min(1, max(0, v)) * n
            let i = min(size - 2, Int(p))
            return (i, i + 1, p - Double(i))
        }
        let (r0, r1, fr) = split(rgb.0), (g0, g1, fg) = split(rgb.1), (b0, b1, fb) = split(rgb.2)
        func at(_ r: Int, _ g: Int, _ b: Int, _ c: Int) -> Double {
            Double(values[((b * size + g) * size + r) * 3 + c])
        }
        var out = [0.0, 0.0, 0.0]
        for c in 0..<3 {
            let c00 = at(r0, g0, b0, c) * (1 - fr) + at(r1, g0, b0, c) * fr
            let c10 = at(r0, g1, b0, c) * (1 - fr) + at(r1, g1, b0, c) * fr
            let c01 = at(r0, g0, b1, c) * (1 - fr) + at(r1, g0, b1, c) * fr
            let c11 = at(r0, g1, b1, c) * (1 - fr) + at(r1, g1, b1, c) * fr
            out[c] = (c00 * (1 - fg) + c10 * fg) * (1 - fb) + (c01 * (1 - fg) + c11 * fg) * fb
        }
        return (out[0], out[1], out[2])
    }
}

/// Turns a whole grade (look, then adjustments and wheels on top) into one colour cube, so the
/// viewer and the export run exactly the same single lookup per pixel.
enum GradeCube {
    /// Points per axis in a baked cube.
    static let dimension = 32
}

@MainActor
enum GradeBaker {
    static let dimension = GradeCube.dimension
    private static var cache: [ColorGrade: Data] = [:]
    private static var cubes: [String: CubeLUT] = [:]

    static func cubeFile(_ path: String) -> CubeLUT? {
        if let hit = cubes[path] { return hit }
        guard let lut = CubeLUT(url: URL(fileURLWithPath: path)) else { return nil }
        cubes[path] = lut
        return lut
    }

    /// RGBA float data for CIColorCube, or nil when the grade changes nothing.
    static func cube(for grade: ColorGrade?) -> Data? {
        guard let grade, !grade.isNeutral else { return nil }
        if let hit = cache[grade] { return hit }

        var lookRecipe: GradeRecipe?
        var lookFile: CubeLUT?
        if let look = grade.look {
            lookRecipe = BuiltInLook.named(look)
            if lookRecipe == nil { lookFile = cubeFile(look) }
        }
        let user = GradeRecipe(exposure: grade.exposure, contrast: grade.contrast, saturation: grade.saturation,
                               temperature: grade.temperature, tint: grade.tint,
                               shadows: grade.shadows.offset, midtones: grade.midtones.offset, highlights: grade.highlights.offset)
        let mix = min(1, max(0, grade.lookIntensity))
        let n = dimension
        var data = [Float](repeating: 1, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    var c = (Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
                    if mix > 0, lookRecipe != nil || lookFile != nil {
                        let looked = lookRecipe?.apply(c) ?? lookFile!.sample(c)
                        c = (c.0 + (looked.0 - c.0) * mix, c.1 + (looked.1 - c.1) * mix, c.2 + (looked.2 - c.2) * mix)
                    }
                    c = user.apply(c)
                    data[i] = Float(min(1, max(0, c.0)))
                    data[i + 1] = Float(min(1, max(0, c.1)))
                    data[i + 2] = Float(min(1, max(0, c.2)))
                    i += 4
                }
            }
        }
        let out = data.withUnsafeBufferPointer { Data(buffer: $0) }
        if cache.count > 200 { cache.removeAll() }
        cache[grade] = out
        return out
    }
}
