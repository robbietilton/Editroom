import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What Local Magic should do, worked out from what the person typed. Local's own planner follows it:
/// nothing here edits anything by itself.
struct LocalRecipe: Equatable {
    enum Pace: String { case unchanged, calm, fast }
    enum Music: String { case unchanged, off, add }
    enum Frame: String { case unchanged, vertical, horizontal, square }

    /// How long the video should be, if they said.
    var seconds: Double?
    var pace: Pace = .unchanged
    /// A built-in look for every shot; "none" takes looks off; nil leaves colour alone.
    var look: String?
    var music: Music = .unchanged
    var frame: Frame = .unchanged
    /// Anything they asked for that these settings can't do.
    var cannotDo = ""
    /// Media they named: only use these, or take these out (library ids), with their names for the note.
    var keepOnly: Set<UUID> = []
    var takeOut: Set<UUID> = []
    var mediaNames: [String] = []
    /// "Nothing else on the timeline": with keepOnly, titles, overlays and music go too.
    var clearRest = false
    /// Where the things they asked for show in each file ("the dog", "the pool"), from Media's labels:
    /// its shots are taken from around these times when it can.
    var moments: [UUID: [Double]] = [:]
    /// The files that show what they asked for, best match first.
    var shown: [UUID] = []
    /// What they asked to see, in their words ("little girl eating"), for the note.
    var asked = ""
    /// Asks for nothing Local can do (no setting, no media): it shouldn't edit anything.
    var isEmpty: Bool {
        seconds == nil && pace == .unchanged && look == nil && music == .unchanged && frame == .unchanged
            && keepOnly.isEmpty && takeOut.isEmpty && speed == nil && !soundEffects && !levelAudio && title == nil && !wholeLibrary && shots == nil
    }

    /// They want the whole Media library, not just what's in the edit ("use most of the clips", "make a
    /// new intro"): a new cut from everything, in place of the edit.
    var wholeLibrary = false
    /// How many shots they asked for, at least ("at least 10 clips", "12 shots").
    var shots: Int?
    /// Every clip in the library, each at least once ("fit all the videos", "use every clip").
    var every = false
    /// Asks only for the audio levels to match (and maybe a look): nothing about the picture's cut.
    var onlyLevels: Bool {
        levelAudio && seconds == nil && pace == .unchanged && music == .unchanged && frame == .unchanged
            && keepOnly.isEmpty && takeOut.isEmpty && speed == nil && !soundEffects
    }

    /// About which media to use: then Local does just that (and closes gaps), nothing else unasked.
    var isFocused: Bool { !keepOnly.isEmpty || !takeOut.isEmpty || onlyAsked }
    /// A specific request ("10x speed", "black and white"): do just that, not the general clean-up too.
    var onlyAsked = false
    /// Clip speed for every shot: 10 for "1000%" or "10x", 0.5 for "half speed" or "slow motion".
    var speed: Double?
    /// Put the short sound files from their Media (sound effects) on the cuts.
    var soundEffects = false
    /// They asked whether it should ("do you think…", "should I…", "if so"): only where it sees a strong
    /// moment, or not at all, with a note saying why.
    var askedJudgement = false
    /// A title they asked for: nil if they didn't, "" for one made from when it was filmed, or their
    /// words when they quote them ("add a title saying \"Summer\"").
    var title: String?
    /// The title goes over the end instead of the start ("add a title at the end").
    var titleAtEnd = false
    /// Bring every audio clip to the same level ("equalize the audio", "same volume"): the clip gain for
    /// each, worked out from the waveforms when the request is read.
    var levelAudio = false
    var levelGains: [UUID: Double] = [:]
    /// Audio clips with no sound to measure, by name: left as they are.
    var levelSilent: [String] = []

    static let plain = LocalRecipe()

    /// "20s, fast, Mono, no music, vertical", for the log and the note.
    var summary: String {
        var parts: [String] = []
        if let seconds { parts.append("\(Int(seconds))s") }
        if pace != .unchanged { parts.append(pace.rawValue) }
        if let look { parts.append(look == "none" ? "no look" : look) }
        if music == .off { parts.append("no music") } else if music == .add { parts.append("music added") }
        if frame != .unchanged { parts.append(frame.rawValue) }
        if let speed { parts.append(String(format: "speed ×%g", speed)) }
        if let shots { parts.append("\(shots)+ shots") }
        if soundEffects { parts.append("sound effects") }
        if levelAudio { parts.append("audio levelled") }
        if !keepOnly.isEmpty { parts.append("only " + mediaNames.joined(separator: ", ")) }
        if !takeOut.isEmpty { parts.append(mediaNames.joined(separator: ", ") + " out") }
        return parts.joined(separator: ", ")
    }
}

/// Apple's on-device model (Apple Intelligence), used only to turn a request into a `LocalRecipe`. Free,
/// private and offline; on Macs without it, Local works without prompts.
enum LocalBrain {
    static let looks = ["Warm film", "Golden hour", "Film print", "Teal and orange", "Pastel", "Bleach bypass", "Mono", "Cool night", "Faded"]

    /// Why prompts can't be used on this Mac, or nil if they can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled): return L10n.tr("Turn on Apple Intelligence in System Settings to describe what you want.")
            case .unavailable(.modelNotReady): return L10n.tr("Apple Intelligence is still getting ready on this Mac.")
            case .unavailable: return L10n.tr("Describing what you want needs a Mac with Apple Intelligence.")
            }
        }
        #endif
        return L10n.tr("Describing what you want needs macOS 26 or later with Apple Intelligence.")
    }

    static var available: Bool { unavailableReason == nil }

    struct Failure: Error { let message: String }

    /// Media the request names, kept only or taken out. The words decide when they're clear ("only",
    /// "just", "nothing else" / "remove", "without"…); otherwise the model's reading.
    /// A general request to make it better ("improve it", "tighten it up"), which Local's own
    /// improvement is for.
    static func isGeneral(_ request: String) -> Bool {
        let t = request.lowercased()
        return ["improve", "better", "tighten", "tidy", "clean", "polish", "fix", "best", "nicer", "good", "shorter", "trim",
                "cut it down", "make it work", "edit it", "magic",
                // The general improve cuts to the beat of the music.
                "beat", "rhythm", "recut", "re-cut", "re-edit"].contains { t.contains($0) }
    }

    /// Clip speed a request asks for: "1000%" or "10x" or "10 times" (with speed / faster / slower nearby),
    /// "double speed", "half speed", "slow motion".
    /// A question about whether to do it, rather than an order.
    static func asksJudgement(_ request: String) -> Bool {
        let t = request.lowercased()
        return t.contains("?") || ["do you think", "should i", "should we", "would it", "if so", "if you think", "worth",
                                   "any good", "makes sense", "if it fits", "where it fits", "if needed", "only if"].contains { t.contains($0) }
    }

    /// How many shots or clips they asked for: "at least 10 clips", "12 shots", "ten cuts".
    static func shotCount(_ request: String) -> Int? {
        var t = request.lowercased()
        let words = ["two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
                     "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30]
        for (w, n) in words { t = t.replacingOccurrences(of: "\\b\(w)\\b", with: String(n), options: .regularExpression) }
        guard let r = t.range(of: #"(\d+)\s*(\+\s*)?(different |unique |separate |short |quick |fast )?(clips|shots|cuts|scenes|videos)"#,
                              options: .regularExpression),
              let n = Int(t[r].prefix { $0.isNumber }), (2...200).contains(n) else { return nil }
        return n
    }

    /// Every clip, each in it at least once: "all the videos", "every clip", "each shot".
    static func wantsEvery(_ request: String) -> Bool {
        let t = request.lowercased()
        let things = "(clips|videos|shots|footage|media|files)"
        return t.range(of: #"\b(all|every one of|each of)\s+(of\s+)?(the\s+|my\s+|our\s+)?"# + things, options: .regularExpression) != nil
            || t.range(of: #"\b(every|each)\s+(single\s+)?(clip|video|shot|file)\b"#, options: .regularExpression) != nil
    }

    /// Asks for footage beyond what's in the edit: most or all of the clips, more or other shots, a new video.
    static func wantsLibrary(_ request: String) -> Bool {
        let t = request.lowercased()
        return ["most of the clips", "most clips", "all the clips", "all clips", "all of the clips", "all my clips", "every clip",
                "more clips", "more shots", "other clips", "other shots", "the rest of the clips", "whole library", "all my media",
                "media folder", "all the media", "all of my", "from scratch", "start over", "make a new", "create a new",
                "new video", "new cut", "new edit", "create ", "montage"].contains { t.contains($0) }
    }

    /// The title they asked for, if they did: their quoted words, or "" for one with placeholder words to type over.
    /// No title unless they ask (a title over every cut gets in the way more often than it helps).
    static func titleAsked(_ request: String) -> String? {
        let t = request.lowercased()
        let quoted = quotedWords(request) != nil
        let asks = (quoted && t.contains("caption")) || ["title", "heading", "text on", "words on", "add text", "put text", "some text", "call it", "name it",
                    "text saying", "text that says"].contains { t.contains($0) }
        let refuses = ["no title", "without a title", "without title", "no text", "without text", "remove the title", "take out the title"]
            .contains { t.contains($0) }
        guard asks, !refuses else { return nil }
        return quotedWords(request) ?? ""
    }

    /// Words they put in quotes: "…" or “…” up to the matching close, so an apostrophe inside ("doesn't")
    /// stays in; '…' or ‘…’ only as a pair around words (an apostrophe in a word doesn't close it).
    static func quotedWords(_ request: String) -> String? {
        let patterns = [#""([^"]{1,120})""#, #"“([^”]{1,120})”"#,
                        #"(?:^|\s)'(.{1,120}?)'(?=$|\s|[.,!?;:])"#, #"(?:^|\s)‘(.{1,120}?)’(?=$|\s|[.,!?;:])"#]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
                  let r = Range(m.range(at: 1), in: request) else { continue }
            let words = request[r].trimmingCharacters(in: .whitespaces)
            if !words.isEmpty { return words }
        }
        return nil
    }

    /// Asks for sound effects ("sfx", "sound effects", "whooshes"…).
    static func wantsSoundEffects(_ request: String) -> Bool {
        let t = request.lowercased()
        return ["sfx", "sound effect", "sound fx", "soundfx", "fx sound", "whoosh", "swoosh", "foley", "sound design"].contains { t.contains($0) }
    }

    /// Asks for the audio clips at one level ("equalize all audio", "same volume", "normalize the sound").
    static func wantsLevels(_ request: String) -> Bool {
        let t = request.lowercased()
        let about = ["audio", "sound", "volume", "loud", "level", "clip", "voice", "music", "db"].contains { t.contains($0) }
        let even = ["equaliz", "equalis", "normaliz", "normalis", "even out", "same level", "same volume", "same loudness",
                    "same output", "consistent", "match", "balance", "level out", "level the", "levels the same", "too quiet and"]
            .contains { t.contains($0) }
        return about && even
    }

    /// Short sound-only files in the library: the sound effects (they can be used more than once).
    static func soundEffects(in p: Project) -> [MediaAsset] {
        p.assets.filter { $0.kind == .audio && $0.duration > 0.05 && $0.duration < 10 }
    }

    static func speed(in request: String) -> Double? {
        let t = request.lowercased()
        let about = ["speed", "faster", "slower", "fast", "slow", "sped", "timelapse", "time lapse", "playback"].contains { t.contains($0) }
        if t.contains("slow motion") || t.contains("slow-mo") || t.contains("slowmo") { return 0.5 }
        if t.contains("double speed") || t.contains("twice as fast") { return 2 }
        if t.contains("half speed") || t.contains("half as fast") { return 0.5 }
        if t.contains("normal speed") || t.contains("real time") || t.contains("realtime") { return 1 }
        guard about else { return nil }
        if let m = t.range(of: #"(\d+(\.\d+)?)\s*%"#, options: .regularExpression),
           let n = Double(t[m].filter { $0.isNumber || $0 == "." }) { return (n / 100).clamped(to: 0.05...100) }
        if let m = t.range(of: #"(\d+(\.\d+)?)\s*(x|times)\b"#, options: .regularExpression),
           let n = Double(t[m].prefix { $0.isNumber || $0 == "." }) { return n.clamped(to: 0.05...100) }
        return nil
    }

    /// Words in a request that aren't things a clip shows.
    static let notThings: Set<String> = ["make", "the", "and", "use", "using", "only", "just", "clip", "clips", "shot", "shots",
        "video", "videos", "cut", "edit", "fast", "slow", "with", "out", "take", "remove", "keep", "all", "some", "more", "less",
        "seconds", "second", "minute", "music", "song", "look", "vertical", "square", "from", "into", "this", "that", "these",
        "show", "shows", "showing", "see", "want", "give", "put", "add", "where", "who", "any", "little", "big"]

    static func applyMedia(_ r: inout LocalRecipe, named: [MediaAsset], action: String, request: String, pointed: Set<UUID> = [],
                           hasEdit: Bool = false) {
        guard !named.isEmpty else { return }
        let text = request.lowercased()
        let only = ["only", "just ", "nothing else", "nothing but", "except", "solely", "keep ", "use the ", "using the "].contains { text.contains($0) }
        let remove = ["remove", "take out", "without", "delete", "drop", "get rid", "cut out", "no more", "lose "].contains { text.contains($0) }
        // Naming files on an edit that's already made ("put @a in front of @b") never takes the others
        // out: only "only" or "remove" in so many words does (Apple's model guesses this wrong). For a
        // new cut, files named with @ are the ones to use.
        let explicit = named.allSatisfy { pointed.contains($0.id) }
        // A name that's an everyday word ("intro", "run") may just be a word in the request ("a vlog
        // intro"): it picks media out only when the request says to, in so many words.
        let everyday = named.allSatisfy { a in (a.name as NSString).deletingPathExtension.allSatisfy { $0.isLetter || $0 == " " } }
        if everyday, !explicit, !only, !remove { return }
        let amongOthers = ["also", " too", "include", "as well", "most", "all ", "every", "the rest", "other"].contains { text.contains($0) }
        // Asked for by what they show ("show the girl eating", "add the dog"): never taken out unless
        // the words say so (Apple's model sometimes reads "add" as "remove").
        let picked = !explicit && action == "remove" && !remove ? "only" : action
        let fallback = hasEdit ? "unchanged" : !explicit ? picked : !amongOthers && action != "remove" ? "only" : "unchanged"
        let mode = only && !remove ? "only" : remove && !only ? "remove" : fallback
        let ids = Set(named.map(\.id))
        if mode == "only" { r.keepOnly = ids } else if mode == "remove" { r.takeOut = ids } else { return }
        r.mediaNames = named.map(\.name)
        r.clearRest = mode == "only" && ["nothing else", "everything else", "anything else", "on the timeline", "on timeline"].contains { text.contains($0) }
        // Their names aren't something it couldn't do.
        let lower = named.map { $0.name.lowercased() }
        if lower.contains(where: { r.cannotDo.lowercased().contains($0) }) { r.cannotDo = "" }
    }

    /// The small model tends to fill in settings nobody asked for. A setting only stands if the request
    /// talks about that kind of thing; a "can't do" only if it's about something they said that the
    /// settings don't cover.
    static func checked(_ r: LocalRecipe, against request: String) -> LocalRecipe {
        let text = request.lowercased()
        func says(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        let lengthWords = ["second", "sec", "minute", "min", "long", "short", "length", "s "]
        let paceWords = ["pace", "pacing", "calm", "slow", "relax", "chill", "gentle", "fast", "quick", "punch", "snappy", "energ", "rhythm", "tempo"]
        let lookWords = ["look", "grade", "colour", "color", "film", "warm", "cool", "mono", "black and white", "b&w", "bw", "vintage", "fade",
                         "pastel", "teal", "orange", "golden", "night", "bleach", "filter", "tone", "cinematic", "moody", "natural", "lut"]
        let musicWords = ["music", "song", "soundtrack", "track", "tune", "audio", "beat"]
        let frameWords = ["vertical", "portrait", "tiktok", "tik tok", "reel", "shorts", "story", "stories", "phone", "horizontal", "landscape",
                          "widescreen", "youtube", "square", "instagram", "9:16", "16:9", "1:1"]
        var out = r
        // A length needs a number with a time unit ("30s", "2 minutes", "1:30") or a number and "long" / "length"
        // ("what's 5+5" has a number and an "s " but isn't a length).
        let timed = text.range(of: #"\d+(\.\d+)?\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes)\b|\d+:\d\d"#, options: .regularExpression) != nil
        let worded = says(["long", "length", "duration"]) && text.contains(where: \.isNumber)
        if out.seconds != nil, !(timed || worded) { out.seconds = nil }
        if out.pace != .unchanged, !says(paceWords) { out.pace = .unchanged }
        if out.look != nil, !says(lookWords) { out.look = nil }
        if out.music != .unchanged, !says(musicWords) { out.music = .unchanged }
        if out.music == .off, !says(["no ", "without", "remove", "off", "mute", "silent", "drop", "take out"]) { out.music = .unchanged }
        if out.frame != .unchanged, !says(frameWords) { out.frame = .unchanged }
        // "Can't do": only parts that share a real word with the request, and aren't about what was done.
        let handled = (out.music != .unchanged ? musicWords : []) + (out.look != nil ? lookWords : [])
            + (out.frame != .unchanged ? frameWords : []) + (out.pace != .unchanged ? paceWords : []) + (out.seconds != nil ? lengthWords : [])
        let requestWords = Set(text.split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
        let parts = r.cannotDo.split(separator: ",").flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let kept = parts.filter { part in
            let p = part.lowercased()
            let shares = p.split { !$0.isLetter }.contains { w in requestWords.contains { $0.hasPrefix(String(w.prefix(5))) && w.count >= 4 } }
            let aboutHandled = handled.contains { p.contains($0) }
            return shares && !aboutHandled
        }
        out.cannotDo = kept.joined(separator: ", ")
        return out
    }

    /// Library items a request names: "IMG_1607", "img_1607", "IMG_1607.mov" or just "1607".
    static func named(in request: String, media: [MediaAsset]) -> [MediaAsset] {
        let text = request.lowercased()
        let words = Set(text.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }.map(String.init))
        return media.filter { a in
            let name = a.name.lowercased()
            let bare = (name as NSString).deletingPathExtension
            // The whole name as its own word(s), not inside another ("intro" isn't in "introduce").
            if bare.count >= 3, text.range(of: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: bare) + "(?![\\p{L}\\p{N}])",
                                           options: .regularExpression) != nil { return true }
            // A number in the name on its own, like "1607" for IMG_1607 (three digits or more).
            let numbers = bare.split { !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
            return numbers.contains { words.contains($0) }
        }
    }

    /// The files that show what's asked for: those matching the most of its words ("girl eating" is
    /// the clip with a child eating, not every clip with a person in it).
    static func showing(_ words: [String], in media: [MediaAsset], shows: (UUID) -> SceneTags?) -> [MediaAsset] {
        // Ties go to the file with the more particular label: "girl" is a "child" in one clip and an
        // "adult" or "people" in every clip with a person in it.
        let general: Set<String> = ["people", "person", "adult"]
        let scored = media.map { a -> (MediaAsset, Double) in
            guard let t = shows(a.id) else { return (a, 0) }
            let score = words.reduce(0.0) { sum, w in
                let tags = t.matching(w)
                guard t.shows(w) else { return sum }
                // A particular label counts for more the surer Vision is of it.
                let particular = tags.filter { !general.contains($0.name) }.map(\.confidence).max() ?? (tags.isEmpty ? 1 : 0)
                return sum + 1 + 0.5 * particular
            }
            return (a, score)
        }
        guard let best = scored.map(\.1).max(), best > 0 else { return [] }
        return scored.filter { $0.1 == best }.map(\.0)
    }

    /// Their words from the first thing found to the last ("show little girl eating" with "girl" and
    /// "eating" found: "little girl eating"), with a describing word just before it kept.
    static func askedPhrase(_ request: String, matched: [String]) -> String {
        let words = request.lowercased().split { !$0.isLetter && $0 != "-" && $0 != "'" }.map(String.init)
        let hits = words.indices.filter { matched.contains(words[$0]) }
        guard var first = hits.first, let last = hits.last else { return "" }
        let describing: Set<String> = ["little", "small", "big", "young", "old", "baby", "red", "blue", "white", "black", "happy", "funny", "cute"]
        if first > 0, describing.contains(words[first - 1]) { first -= 1 }
        return words[first...last].joined(separator: " ")
    }

    /// The times in each file where one of these words shows, by its labels.
    static func moments(of words: [String], in media: [MediaAsset], shows: (UUID) -> SceneTags?) -> [UUID: [Double]] {
        var out: [UUID: [Double]] = [:]
        for a in media where a.kind == .video {
            guard let tags = shows(a.id) else { continue }
            let times = Set(words.flatMap { tags.matching($0) }.flatMap(\.times)).sorted()
            if !times.isEmpty { out[a.id] = times }
        }
        return out
    }

    /// Reads a request into a recipe. `media` is the library, so named items can be picked out.
    static func recipe(for request: String, media: [MediaAsset] = [], pointed: Set<UUID> = [], hasEdit: Bool = false,
                       shows: (UUID) -> SceneTags? = { _ in nil }) async throws -> LocalRecipe {
        // Files named, with @ or by name, or by what they show ("the pool clips").
        let words = Transcript.tokens(request).filter { $0.count >= 3 && !Self.notThings.contains($0) }
        let named = media.filter { a in pointed.contains(a.id) || Self.named(in: request, media: [a]).count == 1 }
            + showing(words, in: media, shows: shows).filter { a in !pointed.contains(a.id) && Self.named(in: request, media: [a]).count != 1 }
        #if canImport(FoundationModels)
        if #available(macOS 26, *), available {
            let session = LanguageModelSession(instructions: """
            You turn a person's request for editing their video into settings. Set a field ONLY if their \
            words ask for it; every other field stays "unchanged" (seconds stays 0). Most requests change one \
            or two fields. The editor can only: set a length, make the pacing calm or fast, put one colour \
            look on every shot or take looks off, turn music off or add music from their library, and make \
            the frame vertical, horizontal or square. If they ask for something else (sound effects, a title \
            or text, a particular story, effects), write just that in cannotDo, in their words; otherwise \
            leave cannotDo empty. Never mention anything they didn't ask for. Their media files are: \
            \(media.map(\.name).joined(separator: ", ")). If they name files to use only those, mediaAction is \
            "only"; to take them out, "remove". Naming files isn't something to put in cannotDo.
            """)
            do {
                let out = try await session.respond(to: request, generating: RecipeOut.self).content
                var r = LocalRecipe()
                r.seconds = out.seconds > 0 ? Double(out.seconds) : nil
                r.pace = LocalRecipe.Pace(rawValue: out.pace) ?? .unchanged
                r.look = out.look == "unchanged" ? nil : out.look
                r.music = LocalRecipe.Music(rawValue: out.music) ?? .unchanged
                r.frame = LocalRecipe.Frame(rawValue: out.frame) ?? .unchanged
                r.cannotDo = out.cannotDo.trimmingCharacters(in: .whitespacesAndNewlines)
                r = checked(r, against: request)
                applyMedia(&r, named: named, action: out.mediaAction, request: request, pointed: pointed, hasEdit: hasEdit)
                let showing = showing(words, in: media, shows: shows)
                r.shown = showing.map(\.id)
                if let best = showing.first, let tags = shows(best.id) {
                    r.asked = askedPhrase(request, matched: words.filter { tags.shows($0) })
                }
                r.moments = moments(of: words, in: showing, shows: shows)
                return r
            } catch {
                throw Failure(message: L10n.fmt("Apple Intelligence couldn't read that: %@", error.localizedDescription))
            }
        }
        #endif
        throw Failure(message: unavailableReason ?? L10n.tr("Apple Intelligence isn't available."))
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable(description: "Settings for editing a video, from the person's request")
struct RecipeOut {
    @Guide(description: "How long the video should be, in seconds; 0 if they didn't say", .range(0...900))
    var seconds: Int
    @Guide(description: "Pacing: calm (longer, slower shots), fast (short, punchy shots), or unchanged", .anyOf(["unchanged", "calm", "fast"]))
    var pace: String
    @Guide(description: "One colour look for every shot, none to take looks off, or unchanged",
           .anyOf(["unchanged", "none", "Warm film", "Golden hour", "Film print", "Teal and orange", "Pastel", "Bleach bypass", "Mono", "Cool night", "Faded"]))
    var look: String
    @Guide(description: "Music: off to remove it, add to put a song from their library under it, or unchanged", .anyOf(["unchanged", "off", "add"]))
    var music: String
    @Guide(description: "Frame shape: vertical (for phones, Reels, TikTok, Shorts), horizontal, square, or unchanged",
           .anyOf(["unchanged", "vertical", "horizontal", "square"]))
    var frame: String
    @Guide(description: "What they asked for that these settings can't do, in a few plain words; empty if nothing")
    var cannotDo: String
    @Guide(description: "If they name media files: only (use just those), remove (take those out), or unchanged", .anyOf(["unchanged", "only", "remove"]))
    var mediaAction: String
}
#endif
