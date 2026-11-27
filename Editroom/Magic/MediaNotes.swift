import Foundation

/// What an AI saw in a library item ("0–3s girl in a high chair eating noodles; 3–8s close-up,
/// laughing"), written by Claude, ChatGPT or OpenCode with note_media after looking at it, and handed back with
/// list_media so later Magic runs needn't look again. Kept on this Mac per file (never in the project);
/// a changed file is a new file, so its old note is never used.
enum MediaNotes {
    struct Note: Codable {
        var text: String
        var by: String?
        var date: Date
    }

    static let maxLength = 800

    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom/Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The file's name, size and date make the name, so editing the footage leaves the note behind.
    private static func file(for path: String) -> URL {
        folder.appendingPathComponent(ReverseAudio.cacheName(for: URL(fileURLWithPath: path)) + ".json")
    }

    static func note(for path: String) -> Note? {
        guard let data = try? Data(contentsOf: file(for: path)) else { return nil }
        return try? JSONDecoder().decode(Note.self, from: data)
    }

    static func save(_ text: String, for path: String, by: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let note = Note(text: String(t.prefix(maxLength)), by: by, date: Date())
        if let data = try? JSONEncoder().encode(note) { try? data.write(to: file(for: path), options: .atomic) }
    }
}
