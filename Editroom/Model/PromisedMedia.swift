import AppKit

/// Files another app promises rather than hands over: Photos (whose library apps can't read), Mail attachments, some
/// browsers. Dropped on Editroom, they're written as copies into the project's "From Photos" folder, beside the
/// project file, so they travel with it. An unsaved project has no folder yet: they're held in Editroom's own folder
/// until the first save moves them beside it, and held copies no project uses are cleared away.
extension EditorModel {
    /// Self-tests point this at a throwaway folder, never the real one.
    nonisolated(unsafe) static var heldMediaFolderForTests: URL?

    /// Where copies wait while the project isn't saved.
    static var heldMediaFolder: URL {
        if let t = heldMediaFolderForTests { return t }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Editroom/From Photos", isDirectory: true)
    }

    /// Where promised files go now: beside the project once it's saved.
    var promisedMediaFolder: URL {
        fileURL.map { $0.deletingLastPathComponent().appendingPathComponent("From Photos", isDirectory: true) } ?? Self.heldMediaFolder
    }

    /// Asks the other app to write its files (Photos fetches originals from iCloud first if it must). A placeholder shows
    /// for each in Media straight away; each file is imported as soon as it's written, taking its placeholder's place.
    func importPromised(_ receivers: [NSFilePromiseReceiver]) {
        guard !receivers.isEmpty else { return }
        let fm = FileManager.default
        let final = promisedMediaFolder
        // Written into a folder of their own first, so a name already in use is never overwritten.
        let incoming = Self.heldMediaFolder.appendingPathComponent(".incoming/" + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: final, withIntermediateDirectories: true)
        try? fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        let expected = receivers.reduce(0) { $0 + max(1, $1.fileTypes.count) }
        let placeholders = (0..<expected).map { _ in UUID() }
        let drop = UUID()
        for p in placeholders { incomingDrop[p] = drop }
        incomingFiles += placeholders
        // Shown where they'll land: the top of Media, scrolled to.
        mediaFolder = nil
        if let first = placeholders.first { mediaReveal = MediaReveal(target: .incoming(first)) }
        beginWaitingForFiles()
        var remaining = expected
        var failed = 0
        var arrived: [UUID] = []
        // One file has been written, or couldn't be: it's brought in, and its placeholder goes once it's in Media.
        let settle: @MainActor (URL?) -> Void = { [weak self] url in
            guard let self else { return }
            remaining -= 1
            // Cancelled while it was on its way: thrown away, and nothing is imported.
            if let n = self.incomingCancels[drop], n > 0 {
                self.incomingCancels[drop] = n - 1
                if let url { try? fm.removeItem(at: url) }
                if remaining == 0 { self.finishDrop(drop, incoming: incoming, failed: failed) }
                return
            }
            let placeholder = placeholders.first { self.incomingFiles.contains($0) }
            let done = { [weak self] in
                guard let self else { return }
                if let placeholder {
                    self.incomingFiles.removeAll { $0 == placeholder }
                    self.incomingSelection.remove(placeholder)
                }
                if remaining == 0 { self.finishDrop(drop, incoming: incoming, failed: failed) }
            }
            guard let url else {
                failed += 1
                done()
                return
            }
            let to = Self.unused(final.appendingPathComponent(url.lastPathComponent))
            guard (try? fm.moveItem(at: url, to: to)) != nil else {
                failed += 1
                done()
                return
            }
            self.importFiles([to]) { [weak self] got in
                guard let self else { return }
                // Everything this drop has brought in so far stays picked.
                arrived += got.map(\.id)
                self.mediaSelection = Set(arrived)
                self.folderSelection = []
                done()
            }
        }
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for r in receivers {
            r.receivePromisedFiles(atDestination: incoming, options: [:], operationQueue: queue) { url, error in
                DispatchQueue.main.async { MainActor.assumeIsolated { settle(error == nil ? url : nil) } }
            }
        }
        // A promise the other app never keeps: its placeholder doesn't stay forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, remaining > 0 else { return }
                self.incomingFiles.removeAll { placeholders.contains($0) }
                remaining = 0
                self.finishDrop(drop, incoming: incoming, failed: 0)
            }
        }
    }

    /// A drop's last file has come in (or been thrown away).
    private func finishDrop(_ drop: UUID, incoming: URL, failed: Int) {
        endWaitingForFiles()
        try? FileManager.default.removeItem(at: incoming)
        incomingCancels[drop] = nil
        for (p, d) in incomingDrop where d == drop { incomingDrop[p] = nil; incomingSelection.remove(p) }
        if failed > 0 {
            importError = failed == 1 ? L10n.tr("One file couldn't be brought in.") : L10n.fmt("%lld files couldn't be brought in.", failed)
        }
    }

    /// Cancels picked imports: their placeholders go now, and as many of each drop's files are thrown away when they
    /// arrive (the other app can't be stopped writing them).
    func cancelIncoming(_ ids: Set<UUID>) {
        for id in ids where incomingFiles.contains(id) {
            if let drop = incomingDrop[id] { incomingCancels[drop, default: 0] += 1 }
        }
        incomingFiles.removeAll { ids.contains($0) }
        incomingSelection.subtract(ids)
    }

    /// The project is being saved to `projectDir`: copies held for it move into its "From Photos" folder.
    func adoptHeldMedia(projectDir: URL) {
        let held = Self.heldMediaFolder.standardizedFileURL.path + "/"
        let dest = projectDir.appendingPathComponent("From Photos", isDirectory: true)
        let fm = FileManager.default
        var moved = Set<UUID>()
        for i in project.assets.indices where project.assets[i].path.hasPrefix(held) {
            let from = URL(fileURLWithPath: project.assets[i].path)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let to = Self.unused(dest.appendingPathComponent(from.lastPathComponent))
            guard (try? fm.moveItem(at: from, to: to)) != nil else { continue }
            repointAsset(at: i, to: to.standardizedFileURL.path)
            moved.insert(project.assets[i].id)
        }
        if !moved.isEmpty { Task { await reopenMovedMedia(moved) } }
    }

    /// Held copies the project open now doesn't use (one started and never saved, then left): deleted.
    func clearUnusedHeldMedia() {
        let fm = FileManager.default
        let folder = Self.heldMediaFolder
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let used = Set(project.assets.flatMap { [$0.path, $0.playablePath].compactMap { $0 } })
        for name in names where name != ".incoming" {
            let path = folder.appendingPathComponent(name).standardizedFileURL.path
            if !used.contains(path) { try? fm.removeItem(atPath: path) }
        }
        // Copies left half-written by a drop that never finished.
        try? fm.removeItem(at: folder.appendingPathComponent(".incoming"))
    }

    /// `url`, or "name 2.ext", "name 3.ext"… if that's taken.
    static func unused(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
