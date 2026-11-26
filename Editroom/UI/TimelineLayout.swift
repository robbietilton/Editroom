import AppKit

/// Vertical arrangement of the timeline, shared by the canvas and the track headers.
struct TimelineLayout {
    static let ruler: CGFloat = 26
    static let zone: CGFloat = 26
    static let gap: CGFloat = 1
    static let divider: CGFloat = 9
    static let headerWidth: CGFloat = 176

    struct Row {
        let track: Track
        let index: Int
        let y: CGFloat
        let height: CGFloat
    }

    private(set) var rows: [Row] = []
    /// The caption track's row, at the top, when the sequence has one.
    private(set) var captionY: CGFloat?
    private(set) var videoZoneY: CGFloat = 0
    private(set) var dividerY: CGFloat = 0
    private(set) var audioZoneY: CGFloat = 0
    private(set) var contentHeight: CGFloat = 0

    /// Height everything except the track rows takes up.
    static let fixedHeight = zone * 2 + divider
    static let captionRow: CGFloat = 30

    /// Height the caption track takes above the video tracks (none without one).
    static func captionSpace(_ project: Project) -> CGFloat { project.captions == nil ? 0 : captionRow + gap }

    init(project: Project, rowHeight: CGFloat) {
        var y: CGFloat = 0
        if project.captions != nil {
            captionY = y
            y += Self.captionRow + Self.gap
        }
        videoZoneY = y
        y += Self.zone
        for (i, t) in project.videoTracks.enumerated().reversed() {
            rows.append(Row(track: t, index: i, y: y, height: rowHeight))
            y += rowHeight + Self.gap
        }
        dividerY = y
        y += Self.divider
        for (i, t) in project.audioTracks.enumerated() {
            rows.append(Row(track: t, index: i, y: y, height: rowHeight))
            y += rowHeight + Self.gap
        }
        audioZoneY = y
        y += Self.zone
        contentHeight = y
    }

    /// Vertical band (content coordinates) for a track id, including the "new track" placeholders.
    func band(for trackID: UUID) -> (y: CGFloat, height: CGFloat)? {
        if trackID == TrackToken.newVideo { return (videoZoneY + 2, Self.zone - 4) }
        if trackID == TrackToken.newAudio { return (audioZoneY + 2, Self.zone - 4) }
        guard let row = rows.first(where: { $0.track.id == trackID }) else { return nil }
        return (row.y, row.height)
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, checked: Bool = false, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: L10n.tr(title), action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

enum Cursors {
    static let cut: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            guard let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return false }
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = .zero
            shadow.set()
            let s = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
}
