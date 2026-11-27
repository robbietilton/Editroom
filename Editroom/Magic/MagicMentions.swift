import Foundation

/// What someone is pointing at when they ask Magic for something: where the playhead is, the clips
/// they have selected and the in/out range. Read when they press Make it, before Magic locks the
/// window and clears the selection.
struct MagicPointers {
    var playhead: Double
    /// Selected clips, in timeline order.
    var selected: [UUID]
    var range: (start: Double, end: Double)?

    @MainActor static func now(_ model: EditorModel) -> MagicPointers {
        let p = model.project
        let selected = p.clips.filter { model.selection.contains($0.id) }
            .sorted { ($0.start, p.trackOrder($0.trackID)) < ($1.start, p.trackOrder($1.trackID)) }.map(\.id)
        return MagicPointers(playhead: model.playhead, selected: selected, range: p.playRange)
    }
}

/// `@playhead`, `@selected`, `@in-out`, `@` + a library file's name, `@clip:` + one clip on the
/// timeline, `@marker:` + a marker (or a marker's name alone) and `@folder:` + a folder in Media, typed in the Magic box to say exactly
/// what a request is about.
enum MagicMention: Hashable {
    case playhead, selected, range
    case media(UUID)
    /// One clip on the timeline (a title, a solid, or one use of a file).
    case clip(UUID)
    /// A marker on the timeline, by its name (`@marker:Jump`, or just `@Jump`).
    case marker(UUID)
    /// A folder in the Media panel, by its path: every file in it and in the folders inside it (`@folder:Drone`),
    /// or with `only`, just the files directly in it (`@folder:Drone:only`).
    case folder(String, only: Bool)

    static let words: [(word: String, mention: MagicMention)] = [("playhead", .playhead), ("selected", .selected), ("in-out", .range)]

    /// A clip on the timeline as `@clip:` names it: a file's name, a title's words (cut short), or
    /// "Solid"; a name used more than once gets ·2, ·3… in time order. A video's own sound isn't listed
    /// apart from it.
    struct ClipLabel {
        let id: UUID
        let name: String
        let kind: ClipKind
        let track: String
        let start: Double
    }

    /// A marker as `@marker:` names it: its own name, or its colour ("Yellow marker") when it has none;
    /// a name used more than once gets ·2, ·3… in time order.
    struct MarkerLabel {
        let id: UUID
        let name: String
        let time: Double
        let tint: Marker.Tint
    }

    /// A folder in Media as `@folder:` names it: its own name, or its path in Media ("B-roll / Drone") when
    /// another folder has the same name. `files` are what's in it and in the folders inside it.
    struct FolderLabel {
        let path: String
        let name: String
        let label: String
        let files: [UUID]
        /// Just the files directly in it, not in the folders inside it.
        var direct: [UUID] = []

        /// Folders inside it hold some of its files: `@folder:…:only` is offered for just its own.
        var hasSubfolders: Bool { !direct.isEmpty && direct.count < files.count }

        /// What a request means by it: everything in it, or only what's directly in it (`:only`, or the request says so).
        func files(for request: String, only: Bool = false) -> [UUID] {
            (only || MagicMention.onlyDirect(request)) && !direct.isEmpty ? direct : files
        }
    }

    /// The request asks for only what's directly in a folder, not the folders inside it ("only the clips in this
    /// folder, not the sub-folders", "top level only").
    static func onlyDirect(_ request: String) -> Bool {
        let t = request.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "sub folder", with: "subfolder")
        let phrases = ["directly in", "top level", "only this folder", "only the folder", "only in this folder", "only in the folder",
                       "just this folder", "just the folder", "just in this folder", "only what's in", "only whats in",
                       "not the subfolder", "no subfolder", "without subfolder", "without the subfolder", "exclude subfolder",
                       "excluding subfolder", "excluding the subfolder", "skip the subfolder", "skip subfolder", "ignore the subfolder",
                       "ignore subfolder", "not subfolder", "not in subfolder", "not in the subfolder",
                       "not the folders inside", "not in the folders inside", "not the folders in", "not from the folders inside",
                       "without the folders inside", "ignore the folders inside", "skip the folders inside", "leave out the folders inside",
                       "not the nested", "no nested", "not nested"]
        return phrases.contains { t.contains($0) }
    }

    static func folderLabels(_ p: Project) -> [FolderLabel] {
        let tree = MediaTree(p)
        var paths: [String] = []
        func walk(_ folder: String?) {
            for f in tree.folders(in: folder) { paths.append(f); walk(f) }
        }
        walk(nil)
        let found = paths.map { f in (f, tree.name(f), tree.label(f), tree.assets(under: f, of: p.assets).map(\.id)) }.filter { !$0.3.isEmpty }
        var count: [String: Int] = [:]
        for f in found { count[f.1.lowercased(), default: 0] += 1 }
        return found.map { f in
            FolderLabel(path: f.0, name: count[f.1.lowercased()]! > 1 ? f.2 : f.1, label: f.2, files: f.3,
                        direct: tree.assets(in: f.0, of: p.assets).map(\.id))
        }
    }

    static func markerLabels(_ p: Project) -> [MarkerLabel] {
        var seen: [String: Int] = [:]
        return p.markerList.map { m in
            let own = m.name.trimmingCharacters(in: .whitespaces)
            let b = own.isEmpty ? m.tint.rawValue.capitalized + " marker" : own
            let n = (seen[b.lowercased()] ?? 0) + 1
            seen[b.lowercased()] = n
            return MarkerLabel(id: m.id, name: n == 1 ? b : "\(b)·\(n)", time: m.time, tint: m.tint)
        }
    }

    /// A time as a clock ("0:12.4", "1:02:03.5") that `MagicTimes` reads back as the same place.
    static func clock(_ t: Double) -> String {
        let t = max(0, (t * 100).rounded() / 100)
        let h = Int(t) / 3600, m = Int(t) % 3600 / 60
        var sec = String(format: "%05.2f", t.truncatingRemainder(dividingBy: 60))
        while sec.hasSuffix("0") { sec.removeLast() }
        if sec.hasSuffix(".") { sec.removeLast() }
        return h > 0 ? String(format: "%d:%02d:", h, m) + sec : "\(m):" + sec
    }

    /// The request with each marker it names written as the marker's time, so everything that reads
    /// typed times ("from 0:12 to 0:18", "a title at 0:12") reads markers too.
    static func markersAsTimes(_ text: String, project p: Project) -> String {
        let marks = markerLabels(p)
        guard !marks.isEmpty else { return text }
        var s = text as NSString
        for (r, m) in find(in: text, media: p.assets, clips: clipLabels(p), markers: marks).reversed() {
            guard case .marker(let id) = m, let l = marks.first(where: { $0.id == id }) else { continue }
            s = s.replacingCharacters(in: r, with: clock(l.time)) as NSString
        }
        return s as String
    }

    static func clipLabels(_ p: Project) -> [ClipLabel] {
        let videoLinks = Set(p.clips.filter { $0.kind != .audio }.compactMap(\.linkID))
        let clips = p.clips.filter { !($0.kind == .audio && $0.linkID.map(videoLinks.contains) == true) }
            .sorted { ($0.start, p.trackOrder($0.trackID)) < ($1.start, p.trackOrder($1.trackID)) }
        func base(_ c: Clip) -> String {
            let n = p.name(of: c).trimmingCharacters(in: .whitespaces)
            guard c.kind == .text, n.count > 24 else { return n }
            return String(n.prefix(22)).trimmingCharacters(in: .whitespaces) + "…"
        }
        func track(_ c: Clip) -> String {
            if let i = p.videoTracks.firstIndex(where: { $0.id == c.trackID }) { return "V\(i + 1)" }
            return "A\((p.audioTracks.firstIndex { $0.id == c.trackID } ?? 0) + 1)"
        }
        var seen: [String: Int] = [:]
        return clips.map { c in
            let b = base(c)
            let n = (seen[b.lowercased()] ?? 0) + 1
            seen[b.lowercased()] = n
            return ClipLabel(id: c.id, name: n == 1 ? b : "\(b)·\(n)", kind: c.kind, track: track(c), start: c.start)
        }
    }

    /// Every mention in the text, in order, with where it is (UTF-16, for the text view). A file's name
    /// counts with or without its extension; the longest name that fits wins.
    static func find(in text: String, media: [MediaAsset], clips: [ClipLabel] = [],
                     markers: [MarkerLabel] = [], folders: [FolderLabel] = []) -> [(range: NSRange, mention: MagicMention)] {
        let s = text as NSString
        guard s.range(of: "@").location != NSNotFound else { return [] }
        var names: [(String, MagicMention)] = words.map { ($0.word, $0.mention) }
        for a in media {
            names.append((a.name, .media(a.id)))
            let bare = (a.name as NSString).deletingPathExtension
            if !bare.isEmpty, bare != a.name { names.append((bare, .media(a.id))) }
        }
        // Markers by name too ("@Jump"); a file of the same name wins.
        let markerNames = markers.map { ($0.name, MagicMention.marker($0.id)) }
        names = names.enumerated().sorted { ($0.element.0.count, -$0.offset) > ($1.element.0.count, -$1.offset) }.map(\.element)
        let withMarkers = (names + markerNames).enumerated()
            .sorted { ($0.element.0.count, -$0.offset) > ($1.element.0.count, -$1.offset) }.map(\.element)
        let clipNames = clips.map { ($0.name, MagicMention.clip($0.id)) }.sorted { $0.0.count > $1.0.count }
        func isWordChar(_ c: unichar) -> Bool {
            guard let u = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(u) || c == 0x5F // _
        }
        func starts(_ word: String, at i: Int) -> Bool {
            let n = (word as NSString).length
            return i + n <= s.length && s.substring(with: NSRange(location: i, length: n)).caseInsensitiveCompare(word) == .orderedSame
        }
        var out: [(NSRange, MagicMention)] = []
        var i = 0
        while i < s.length {
            let at = s.range(of: "@", range: NSRange(location: i, length: s.length - i))
            guard at.location != NSNotFound else { break }
            i = at.location + 1
            // Not the middle of an address ("me@example.com").
            if at.location > 0, isWordChar(s.character(at: at.location - 1)) { continue }
            // "@media:club" is "@club", written the way the list browses to it; "@clip:" names one clip.
            var from = i
            var pool = withMarkers
            if starts("marker:", at: i) {
                from += 7
                pool = markerNames.sorted { $0.0.count > $1.0.count }
            } else if starts("media:", at: i) {
                from += 6
                pool = names.filter { if case .media = $0.1 { return true } else { return false } }
            } else if starts("clip:", at: i) {
                from += 5
                pool = clipNames
            } else if starts("folder:", at: i) {
                from += 7
                pool = (folders.map { ($0.name, MagicMention.folder($0.path, only: false)) }
                        + folders.filter(\.hasSubfolders).map { ($0.name + ":only", MagicMention.folder($0.path, only: true)) })
                    .sorted { $0.0.count > $1.0.count }
            }
            for (name, mention) in pool {
                let len = (name as NSString).length
                guard starts(name, at: from) else { continue }
                // The whole name: "@intro" isn't "@introduction".
                if from + len < s.length, isWordChar(s.character(at: from + len)) { continue }
                out.append((NSRange(location: at.location, length: from + len - at.location), mention))
                i = from + len
                break
            }
        }
        return out
    }

    /// The request in plain words, for a reader that doesn't know about mentions (Apple's model):
    /// "@selected" reads "the selected clips", "@beach.mov" reads "beach.mov".
    static func plain(_ text: String, media: [MediaAsset], clips: [ClipLabel] = [], markers: [MarkerLabel] = [],
                      folders: [FolderLabel] = []) -> String {
        var s = text as NSString
        for (r, m) in find(in: text, media: media, clips: clips, markers: markers, folders: folders).reversed() {
            let words: String = switch m {
            case .playhead: "the playhead"
            case .selected: "the selected clips"
            case .range: "the marked range"
            case .media(let id): media.first { $0.id == id }?.name ?? s.substring(with: r)
            case .clip(let id): "the clip " + (clips.first { $0.id == id }?.name ?? "")
            case .marker(let id): markers.first { $0.id == id }.map { clock($0.time) } ?? s.substring(with: r)
            case .folder(let path, let only):
                folders.first { $0.path == path }.map { f in
                    let names = f.files(for: text, only: only).compactMap { id in media.first { $0.id == id }?.name }
                    return "the files \(only ? "directly " : "")in the folder \(f.label) (" + names.prefix(20).joined(separator: ", ") + (names.count > 20 ? ", and \(names.count - 20) more" : "") + ")"
                } ?? s.substring(with: r)
            }
            s = s.replacingCharacters(in: r, with: words) as NSString
        }
        return s as String
    }
}

extension Project {
    /// Where a track sits for sorting: video tracks top to bottom, then audio.
    func trackOrder(_ id: UUID) -> Int {
        if let i = videoTracks.firstIndex(where: { $0.id == id }) { return videoTracks.count - i }
        return videoTracks.count + 1 + (audioTracks.firstIndex { $0.id == id } ?? 0)
    }
}

/// Times typed in a request: "0:05", "00:05", "1:02:30" and the viewer's own "00:00:05:00" (the last
/// two digits frames, at the project's rate). A span ("between 0:05 and 0:06", "from 5s to 6s") is a
/// range on the timeline; a lone time is just said to the AI, since "make it 0:30" is a length, not a place.
enum MagicTimes {
    struct Typed {
        let range: NSRange
        let text: String
        let seconds: Double
        /// "5s" or "5 seconds": only a time when it's part of a span.
        let unitOnly: Bool
    }

    static func times(in text: String, fps: Double) -> [Typed] {
        let s = text as NSString
        let patterns: [(String, ([Double]) -> Double, Bool)] = [
            // hh:mm:ss:ff, as the viewer shows it.
            (#"(?<![\d:.])(\d{1,2}):(\d{2}):(\d{2})[;:](\d{2})(?![\d:])"#, { $0[0] * 3600 + $0[1] * 60 + $0[2] + $0[3] / max(1, fps) }, false),
            // h:mm:ss
            (#"(?<![\d:.])(\d{1,2}):(\d{2}):(\d{2}(?:\.\d+)?)(?![\d:])"#, { $0[0] * 3600 + $0[1] * 60 + $0[2] }, false),
            // m:ss
            (#"(?<![\d:.])(\d{1,3}):(\d{2}(?:\.\d+)?)(?![\d:])"#, { $0[0] * 60 + $0[1] }, false),
            // 5s, 5 sec, 5 seconds
            (#"(?<![\d:.])(\d+(?:\.\d+)?)\s*(?:s|secs?|seconds?)\b"#, { $0[0] }, true),
        ]
        var out: [Typed] = []
        for (pattern, value, unitOnly) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: s.length)) {
                // The first, longest pattern that matched there wins.
                guard !out.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) else { continue }
                let parts = (1..<m.numberOfRanges).compactMap { i -> Double? in
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? nil : Double(s.substring(with: r))
                }
                out.append(Typed(range: m.range, text: s.substring(with: m.range), seconds: value(parts), unitOnly: unitOnly))
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// Where the prompt has times Magic will read as places in the edit, for showing them in bold: clock
    /// times ("0:05", "00:00:05:12") always; "5s" or "5 seconds" only as part of a span ("between 5s and 8s").
    static func recognised(in text: String) -> [NSRange] {
        let s = text as NSString
        let found = times(in: text, fps: 30)
        var out = found.filter { !$0.unitOnly }.map(\.range)
        for (a, b) in zip(found, found.dropFirst()) where a.unitOnly || b.unitOnly {
            let gapStart = NSMaxRange(a.range)
            guard b.range.location >= gapStart else { continue }
            let gap = s.substring(with: NSRange(location: gapStart, length: b.range.location - gapStart)).lowercased()
                .trimmingCharacters(in: .whitespaces)
            let before = s.substring(with: NSRange(location: max(0, a.range.location - 12), length: min(12, a.range.location))).lowercased()
            guard ["and", "to", "-", "–", "—", "through", "until", "till"].contains(gap),
                  before.hasSuffix("between ") || before.hasSuffix("from ") else { continue }
            out += [a.range, b.range]
        }
        return out
    }

    /// A span they typed: "between A and B", "from A to B" (or A to B / A–B with two clock times).
    static func span(in text: String, fps: Double) -> (start: Double, end: Double, text: String)? {
        let s = text as NSString
        let found = times(in: text, fps: fps)
        for (a, b) in zip(found, found.dropFirst()) {
            let gapStart = NSMaxRange(a.range)
            guard b.range.location >= gapStart else { continue }
            let gap = s.substring(with: NSRange(location: gapStart, length: b.range.location - gapStart)).lowercased()
                .trimmingCharacters(in: .whitespaces)
            guard ["and", "to", "-", "–", "—", "through", "until", "till"].contains(gap) else { continue }
            let before = s.substring(with: NSRange(location: max(0, a.range.location - 12), length: min(12, a.range.location))).lowercased()
            let introduced = before.hasSuffix("between ") || before.hasSuffix("from ")
            // Without "between" or "from", only two clock times ("0:05 to 0:06") make a span.
            guard introduced || (!a.unitOnly && !b.unitOnly), b.seconds > a.seconds else { continue }
            let from = introduced ? (before.hasSuffix("between ") ? 8 : 5) : 0
            let whole = NSRange(location: a.range.location - from, length: NSMaxRange(b.range) - (a.range.location - from))
            return (a.seconds, b.seconds, s.substring(with: whole))
        }
        return nil
    }
}
