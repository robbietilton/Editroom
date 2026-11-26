import SwiftUI
import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
}

/// The app's looks, picked in Settings > General. Dark is the original; Auto is Light or Dark, as
/// macOS is.
enum AppTheme: String, CaseIterable, Identifiable {
    case auto, dark, grey, amber, light
    var id: Self { self }
    var name: String { L10n.tr(rawValue.prefix(1).uppercased() + rawValue.dropFirst()) }
    var isLight: Bool { resolved == .light }

    /// The theme it draws with: Auto becomes Light or Dark.
    var resolved: AppTheme {
        guard self == .auto else { return self }
        return Self.macOSIsDark ? .dark : .light
    }

    var palette: Palette {
        switch resolved {
        case .grey: .grey
        case .amber: .amber
        case .light: .light
        default: .dark
        }
    }

    /// macOS is set to dark (or is dark right now, on its own Auto).
    static var macOSIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    static let key = "appearance"
    static var saved: AppTheme { UserDefaults.standard.string(forKey: key).flatMap(AppTheme.init(rawValue:)) ?? .dark }
}

/// Every colour a theme sets. Chrome tints (hovers, strokes, quiet fills) are `ink` at low opacity:
/// white on the dark themes, black on Light. Clips stay dark in every theme, so what's drawn on them
/// (names, waveforms, fades, the white selection edge) reads the same everywhere.
struct Palette {
    var bg: UInt32, panel: UInt32, lane: UInt32, laneAlt: UInt32, raised: UInt32, field: UInt32
    var ink: UInt32, strokeAlpha: Double, hoverAlpha: Double
    var text: UInt32, textDim: UInt32, textFaint: UInt32
    /// Type on a `text`-coloured fill (the white pill buttons).
    var onText: UInt32
    var accent: UInt32
    var video: UInt32, audio: UInt32, textClip: UInt32, clipStroke: UInt32, offline: UInt32
    /// The empty timeline's hint.
    var hint: UInt32
    /// Unlit meter segments; a switch that's off; quiet large buttons.
    var well: UInt32, control: UInt32, button: UInt32, buttonHover: UInt32
    /// Behind the transport's play button; dashed outlines of empty places.
    var transport: UInt32, outline: UInt32
    /// Quiet meter segments, and quiet chip type.
    var meterLow: UInt32, chip: UInt32
    /// The export sheet.
    var sheet: UInt32, sheetField: UInt32, sheetFieldHover: UInt32, sheetFieldStroke: UInt32, sheetLabel: UInt32

    /// Exactly the colours Editroom has always had.
    static let dark = Palette(
        bg: 0x0A0A0A, panel: 0x111111, lane: 0x0D0D0D, laneAlt: 0x0A0A0A, raised: 0x1A1A1A, field: 0x181818,
        ink: 0xFFFFFF, strokeAlpha: 0.085, hoverAlpha: 0.07,
        text: 0xF2F2F0, textDim: 0x9A9A96, textFaint: 0x5C5C59, onText: 0x0A0A0A, accent: 0xFF4A1C,
        video: 0x1E1E1E, audio: 0x151515, textClip: 0x1B1B1B, clipStroke: 0x2C2C2C, offline: 0x5A1F1F,
        hint: 0x3E3E3C, well: 0x262626, control: 0x3A3A3A, button: 0x242424, buttonHover: 0x2E2E2E,
        transport: 0x161616, outline: 0x2C2C2C, meterLow: 0xD9D9D6, chip: 0xC9C9C5,
        sheet: 0x141414, sheetField: 0x1E1E1E, sheetFieldHover: 0x262626, sheetFieldStroke: 0x2E2E2E, sheetLabel: 0xA8A8A4)

    /// A step lighter than Dark: charcoal rather than black.
    static let grey = Palette(
        bg: 0x1C1C1C, panel: 0x232323, lane: 0x1F1F1F, laneAlt: 0x1C1C1C, raised: 0x2D2D2D, field: 0x2A2A2A,
        ink: 0xFFFFFF, strokeAlpha: 0.09, hoverAlpha: 0.07,
        text: 0xF2F2F0, textDim: 0xA6A6A2, textFaint: 0x6F6F6C, onText: 0x1C1C1C, accent: 0xFF4A1C,
        video: 0x333333, audio: 0x2A2A2A, textClip: 0x303030, clipStroke: 0x444444, offline: 0x6A2A2A,
        hint: 0x585856, well: 0x383838, control: 0x4C4C4C, button: 0x363636, buttonHover: 0x404040,
        transport: 0x2A2A2A, outline: 0x444444, meterLow: 0xD9D9D6, chip: 0xCFCFCB,
        sheet: 0x262626, sheetField: 0x303030, sheetFieldHover: 0x383838, sheetFieldStroke: 0x424242, sheetLabel: 0xAEAEAA)

    /// Warm near-black, cream type and an amber accent, like an old amber screen.
    static let amber = Palette(
        bg: 0x100B06, panel: 0x18120A, lane: 0x130E08, laneAlt: 0x100B06, raised: 0x261C10, field: 0x22190E,
        ink: 0xFFE8CC, strokeAlpha: 0.09, hoverAlpha: 0.075,
        text: 0xF7E7CF, textDim: 0xB39B7C, textFaint: 0x76634C, onText: 0x140E07, accent: 0xFFA43A,
        video: 0x2E2316, audio: 0x21180D, textClip: 0x2A1F13, clipStroke: 0x45341F, offline: 0x5E2414,
        hint: 0x5A4830, well: 0x352816, control: 0x523F27, button: 0x33261A, buttonHover: 0x403021,
        transport: 0x21190F, outline: 0x3E3022, meterLow: 0xE6D6BD, chip: 0xD8C6AA,
        sheet: 0x1A140C, sheetField: 0x261D13, sheetFieldHover: 0x30251A, sheetFieldStroke: 0x3A2D1F, sheetLabel: 0xB8A182)

    /// Light chrome with dark clips (media reads best on dark), and the viewer stays black.
    static let light = Palette(
        bg: 0xE3E3E0, panel: 0xF4F4F2, lane: 0xEAEAE7, laneAlt: 0xE3E3E0, raised: 0xFFFFFF, field: 0xFFFFFF,
        ink: 0x000000, strokeAlpha: 0.11, hoverAlpha: 0.055,
        text: 0x1C1C1B, textDim: 0x5F5F5B, textFaint: 0x98988F, onText: 0xFFFFFF, accent: 0xF0451A,
        video: 0x6A6A67, audio: 0x73736F, textClip: 0x6A6A67, clipStroke: 0x5A5A57, offline: 0x9A3A30,
        hint: 0x9E9E99, well: 0xD5D5D1, control: 0xC6C6C1, button: 0xE4E4E1, buttonHover: 0xDADAD6,
        transport: 0xE6E6E3, outline: 0xC4C4BF, meterLow: 0x8C8C87, chip: 0x3A3A38,
        sheet: 0xF4F4F2, sheetField: 0xFFFFFF, sheetFieldHover: 0xF8F8F6, sheetFieldStroke: 0xD3D3CE, sheetLabel: 0x5F5F5B)
}

/// The palette in use, shared by SwiftUI and the AppKit timeline. Changing it (Settings > General)
/// redraws the windows.
enum Theme {
    /// The theme being drawn (never Auto: that's resolved to Light or Dark).
    nonisolated(unsafe) static var current: AppTheme = AppTheme.saved.resolved
    static var p: Palette { current.palette }

    enum NS {
        static var bg: NSColor { NSColor(hex: p.bg) }
        static var panel: NSColor { NSColor(hex: p.panel) }
        static var lane: NSColor { NSColor(hex: p.lane) }
        static var laneAlt: NSColor { NSColor(hex: p.laneAlt) }
        static var raised: NSColor { NSColor(hex: p.raised) }
        /// A selected clip's edge: white on the dark themes, near-black on Light (white doesn't show
        /// against its pale lanes).
        static var selection: NSColor { current.isLight ? NSColor(hex: 0x1C1C1B) : .white }
        /// White on the dark themes, black on Light: the base of every chrome tint.
        static var ink: NSColor { NSColor(hex: p.ink) }
        static func ink(_ alpha: CGFloat) -> NSColor { NSColor(hex: p.ink, alpha: alpha) }
        static var stroke: NSColor { ink(p.strokeAlpha) }
        static var text: NSColor { NSColor(hex: p.text) }
        static var textDim: NSColor { NSColor(hex: p.textDim) }
        static var textFaint: NSColor { NSColor(hex: p.textFaint) }
        static var hint: NSColor { NSColor(hex: p.hint) }
        static var accent: NSColor { NSColor(hex: p.accent) }
        /// Too loud: the same red-orange in every theme.
        static let alert = NSColor(hex: 0xFF4A1C)
        /// Meter yellow.
        static let snap = NSColor(hex: 0xF2C14E)

        // Clips are neutral; their pictures and waveforms carry the colour.
        static var video: NSColor { NSColor(hex: p.video) }
        static var audio: NSColor { NSColor(hex: p.audio) }
        static var image: NSColor { NSColor(hex: p.video) }
        static var textClip: NSColor { NSColor(hex: p.textClip) }
        static var solid: NSColor { NSColor(hex: p.textClip) }
        static var clipStroke: NSColor { NSColor(hex: p.clipStroke) }
        static var offline: NSColor { NSColor(hex: p.offline) }

        static func clip(_ kind: ClipKind) -> NSColor {
            switch kind {
            case .video: return video
            case .audio: return audio
            case .image: return image
            case .text: return textClip
            case .solid: return solid
            }
        }

        // With thumbnails off, clips are flat colour by media type, as in Premiere: pictures blue,
        // audio green, text plum, solids ochre.
        static func clipType(_ kind: ClipKind) -> NSColor {
            switch kind {
            case .video, .image: return NSColor(hex: 0x3A5A80)
            case .audio: return NSColor(hex: 0x2F6A47)
            case .text: return NSColor(hex: 0x664675)
            case .solid: return NSColor(hex: 0x7A6428)
            }
        }
    }

    private static func c(_ hex: UInt32) -> Color { Color(hex: hex) }
    static var bg: Color { c(p.bg) }
    static var panel: Color { c(p.panel) }
    static var raised: Color { c(p.raised) }
    static var field: Color { c(p.field) }
    /// White on the dark themes, black on Light: hovers, strokes and quiet fills use it at low opacity.
    static var ink: Color { c(p.ink) }
    static var hover: Color { ink.opacity(p.hoverAlpha) }
    static var stroke: Color { ink.opacity(p.strokeAlpha) }
    static var text: Color { c(p.text) }
    static var textDim: Color { c(p.textDim) }
    static var textFaint: Color { c(p.textFaint) }
    static var onText: Color { c(p.onText) }
    static var well: Color { c(p.well) }
    static var control: Color { c(p.control) }
    static var button: Color { c(p.button) }
    static var buttonHover: Color { c(p.buttonHover) }
    static var transport: Color { c(p.transport) }
    static var outline: Color { c(p.outline) }
    static var meterLow: Color { c(p.meterLow) }
    static var chip: Color { c(p.chip) }
    /// Small spaced-out section labels.
    static func label(_ size: CGFloat = 10) -> Font { .system(size: size, weight: .semibold) }
    static var accent: Color { c(p.accent) }
    static var alert: Color { Color(nsColor: NS.alert) }
    static var scheme: ColorScheme { current.isLight ? .light : .dark }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The chosen theme. Changing it re-reads every colour: the main window and Settings rebuild their views,
/// the windows take the new background, and macOS draws menus and popovers light or dark to match.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    /// What they picked (maybe Auto).
    @Published var theme: AppTheme = AppTheme.saved {
        didSet {
            guard theme != oldValue else { return }
            UserDefaults.standard.set(theme.rawValue, forKey: AppTheme.key)
            resolve()
        }
    }
    /// What's drawn: Auto as Light or Dark. Views rebuild when this changes.
    @Published private(set) var resolved: AppTheme = AppTheme.saved.resolved
    /// Times as timecode or as plain minutes and seconds. Views rebuild when it changes.
    @Published var timeStyle: TimeStyle = TimeStyle.current {
        didSet {
            guard timeStyle != oldValue else { return }
            UserDefaults.standard.set(timeStyle.rawValue, forKey: TimeStyle.key)
            TimelineCanvas.current?.needsDisplay = true
        }
    }
    /// What rebuilds the views when it changes: the theme. (Times just redraw: the views that show one
    /// watch `timeStyle`, so the timeline and playhead don't jump.)
    var look: String { resolved.rawValue }
    private var observer: NSObjectProtocol?

    private init() {
        // macOS switching between light and dark (by hand, or on its own schedule) moves Auto with it.
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ThemeStore.shared.resolve() }
        }
    }

    private func resolve() {
        let now = theme.resolved
        Theme.current = now
        if now != resolved { resolved = now }
        apply()
    }

    /// The windows' own colours, and light or dark for what macOS draws.
    func apply() {
        NSApp.appearance = NSAppearance(named: resolved.isLight ? .aqua : .darkAqua)
        for window in NSApp.windows where window.canBecomeMain || window.title == "Settings" {
            window.backgroundColor = Theme.NS.panel
        }
        TimelineCanvas.current?.needsDisplay = true
    }
}

// MARK: - Shared controls

/// Square icon button with a hover state and optional "on" state.
struct IconButton: View {
    let symbol: String
    var active = false
    var size: CGFloat = 28
    var help = ""
    /// Shifts the glyph up (negative) or down to centre symbols whose weight sits off-centre.
    var nudge: CGFloat = 0
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Glyph(symbol: symbol, size: size * 0.46)
                .foregroundStyle(active || hovering ? Theme.text : Theme.textDim)
                .offset(y: nudge)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Theme.ink.opacity(0.1) : (hovering ? Theme.hover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(L10n.tr(help))
    }
}

/// The app's own line icons, drawn on a 16-point grid with one 1.3-point stroke so they read as one
/// family. Each stands in for the system symbol of the same meaning.
struct LineIcon: Shape {
    let name: String

    static let names: Set<String> = ["cursorarrow", "scissors", "square.and.arrow.down", "eye", "eye.slash",
                                     "lock", "repeat", "arrow.left.and.right", "arrow.up.left.and.arrow.down.right",
                                     "arrow.down.right.and.arrow.up.left", "trash"]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func line(_ pts: [(CGFloat, CGFloat)]) {
            p.move(to: pt(pts[0].0, pts[0].1))
            for q in pts.dropFirst() { p.addLine(to: pt(q.0, q.1)) }
        }
        switch name {
        case "cursorarrow":
            line([(3, 2), (13, 8.2), (8.6, 9.1), (11.1, 13.5), (9.5, 14.4), (7, 10), (3.6, 12)])
            p.closeSubpath()
        case "scissors":
            p.addEllipse(in: CGRect(x: 1.7, y: 9.7, width: 4.6, height: 4.6))
            p.addEllipse(in: CGRect(x: 9.7, y: 9.7, width: 4.6, height: 4.6))
            line([(5.6, 10.4), (13, 2)])
            line([(10.4, 10.4), (3, 2)])
        case "textformat":
            line([(3, 13.5), (7, 2.5), (9, 2.5), (13, 13.5)])
            line([(4.6, 9.5), (11.4, 9.5)])
        case "square.and.arrow.down":
            line([(8, 1.5), (8, 10)])
            line([(5, 7), (8, 10), (11, 7)])
            p.move(to: pt(3, 9.5)); p.addLine(to: pt(3, 12.5))
            p.addQuadCurve(to: pt(4.5, 14), control: pt(3, 14))
            p.addLine(to: pt(11.5, 14))
            p.addQuadCurve(to: pt(13, 12.5), control: pt(13, 14))
            p.addLine(to: pt(13, 9.5))
        case "eye", "eye.slash":
            p.move(to: pt(1.5, 8))
            p.addQuadCurve(to: pt(14.5, 8), control: pt(8, 1))
            p.addQuadCurve(to: pt(1.5, 8), control: pt(8, 15))
            p.addEllipse(in: CGRect(x: 6, y: 6, width: 4, height: 4))
            if name == "eye.slash" { line([(2.5, 13.5), (13.5, 2.5)]) }
        case "lock":
            p.addRoundedRect(in: CGRect(x: 3, y: 7, width: 10, height: 7.5), cornerSize: CGSize(width: 1.5, height: 1.5))
            p.move(to: pt(5.2, 7)); p.addLine(to: pt(5.2, 5))
            p.addArc(center: pt(8, 5), radius: 2.8, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: pt(10.8, 7))
        case "repeat":
            p.move(to: pt(2, 7)); p.addLine(to: pt(2, 6))
            p.addQuadCurve(to: pt(4.5, 3.5), control: pt(2, 3.5))
            p.addLine(to: pt(13, 3.5))
            line([(11, 1.5), (13, 3.5), (11, 5.5)])
            p.move(to: pt(14, 9)); p.addLine(to: pt(14, 10))
            p.addQuadCurve(to: pt(11.5, 12.5), control: pt(14, 12.5))
            p.addLine(to: pt(3, 12.5))
            line([(5, 14.5), (3, 12.5), (5, 10.5)])
        case "arrow.left.and.right":
            line([(1.5, 8), (14.5, 8)])
            line([(4.5, 5), (1.5, 8), (4.5, 11)])
            line([(11.5, 5), (14.5, 8), (11.5, 11)])
        case "arrow.up.left.and.arrow.down.right":
            line([(2, 6), (2, 2), (6, 2)]); line([(2, 2), (6.5, 6.5)])
            line([(14, 10), (14, 14), (10, 14)]); line([(14, 14), (9.5, 9.5)])
        case "arrow.down.right.and.arrow.up.left":
            line([(6.5, 2.5), (6.5, 6.5), (2.5, 6.5)]); line([(2, 2), (6.5, 6.5)])
            line([(9.5, 13.5), (9.5, 9.5), (13.5, 9.5)]); line([(14, 14), (9.5, 9.5)])
        case "trash":
            line([(2.5, 4.5), (13.5, 4.5)])
            line([(6, 4.5), (6, 3), (10, 3), (10, 4.5)])
            line([(4, 4.5), (4.7, 13.5), (11.3, 13.5), (12, 4.5)])
        default:
            break
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16).translatedBy(x: rect.minX, y: rect.minY))
    }
}

/// An icon by system-symbol name, drawn from the app's own line set where it has one.
struct Glyph: View {
    let symbol: String
    /// The size a system symbol would be drawn at; line icons are sized to match.
    let size: CGFloat
    var weight: Font.Weight = .medium

    var body: some View {
        if LineIcon.names.contains(symbol) {
            LineIcon(name: symbol)
                .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                .frame(width: size * 1.2, height: size * 1.2)
        } else if symbol == "solid" {
            SolidIcon(lineWidth: 1.3).frame(width: size * 1.15, height: size * 0.86)
        } else if symbol == "textformat" {
            TextFrameIcon().frame(width: size * 1.15, height: size * 0.86)
        } else {
            Image(systemName: symbol).font(.system(size: size, weight: weight))
        }
    }
}

/// The icon for a text clip: a T inside the same frame as the solid icon, so the two read as a pair.
struct TextFrameIcon: View {
    var lineWidth: CGFloat = 1.3

    var body: some View {
        Canvas { ctx, size in
            let outer = CGRect(x: lineWidth / 2, y: lineWidth / 2, width: size.width - lineWidth, height: size.height - lineWidth)
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            ctx.stroke(Path(roundedRect: outer, cornerRadius: 2.2), with: .foreground, style: style)
            // On the frame's 17 × 13 grid: crossbar from 5 to 12 at 4, stem down to 9.5.
            let sx = size.width / 17, sy = size.height / 13
            var t = Path()
            t.move(to: CGPoint(x: 5 * sx, y: 4 * sy)); t.addLine(to: CGPoint(x: 12 * sx, y: 4 * sy))
            t.move(to: CGPoint(x: 8.5 * sx, y: 4 * sy)); t.addLine(to: CGPoint(x: 8.5 * sx, y: 9.5 * sy))
            ctx.stroke(t, with: .foreground, style: style)
        }
    }
}

/// The icon for a solid clip: a 16:9 frame filled with colour.
struct SolidIcon: View {
    var lineWidth: CGFloat = 1.3

    var body: some View {
        Canvas { ctx, size in
            let outer = CGRect(x: lineWidth / 2, y: lineWidth / 2, width: size.width - lineWidth, height: size.height - lineWidth)
            ctx.stroke(Path(roundedRect: outer, cornerRadius: 2.2), with: .foreground, lineWidth: lineWidth)
            let inner = outer.insetBy(dx: lineWidth + 1.1, dy: lineWidth + 1.1)
            ctx.fill(Path(roundedRect: inner, cornerRadius: 1), with: .foreground)
        }
    }
}

extension View {
    /// A faint 1pt highlight along a panel's top edge, like light catching the lip of a housing.
    func panelTopLight() -> some View {
        overlay(alignment: .top) { Rectangle().fill(Theme.ink.opacity(0.045)).frame(height: 1).allowsHitTesting(false) }
    }
}

struct Hairline: View {
    var vertical = false
    /// Solid: one colour whatever is under it (see-through, it looked lighter over the grey panels than
    /// over the near-black viewer): #1F1F1F on the dark theme, to match its other borders; on the others,
    /// the line's colour as it looks on a panel.
    var solid = false
    static var solidColor: Color {
        if Theme.p.panel == 0x111111 { return Color(hex: 0x1F1F1F) }
        return Color(nsColor: Theme.NS.panel.blended(withFraction: Theme.p.strokeAlpha * 0.72, of: Theme.NS.ink) ?? Theme.NS.panel)
    }
    var body: some View {
        Rectangle()
            .fill(solid ? Self.solidColor : Theme.stroke)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Draggable splitter between panes. Hovering shows only the resize cursor (like Mac split views); a
/// line shows while it's dragged. While Magic works (the editor is locked), it doesn't react at all.
struct Splitter: View {
    let vertical: Bool
    let onDrag: (CGFloat) -> Void
    @ObservedObject private var magic = MagicState.shared
    @State private var hovering = false
    @State private var dragging = false

    private var locked: Bool { magic.stage != nil }

    var body: some View {
        Rectangle()
            .fill(dragging ? Theme.ink.opacity(0.45) : Theme.stroke)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .overlay(
                Color.clear
                    .frame(width: vertical ? 9 : nil, height: vertical ? nil : 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != hovering else { return }
                        if inside, locked { return }
                        hovering = inside
                        if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                guard !locked else { return }
                                dragging = true
                                onDrag(vertical ? v.location.x : v.location.y)
                            }
                            .onEnded { _ in dragging = false }
                    )
                    .allowsHitTesting(!locked)
            )
            // Magic starting while the pointer is on it: the resize cursor goes.
            .onChange(of: locked) { _, now in
                guard now, hovering else { return }
                hovering = false
                dragging = false
                NSCursor.pop()
            }
            .zIndex(10)
    }
}
