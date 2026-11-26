import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var media: MediaStore
    @State private var dropTargeted = false
    @State private var search = ""
    /// Thumbnails (the default) or a list, from Settings > General.
    @AppStorage(MediaLayout.key) private var layout = MediaLayout.thumbnails
    /// How wide the panel is, so a list's pictures can grow a little when it's widened.
    @State private var panelWidth: CGFloat = 252
    /// How tall the panel is, so a click anywhere below the items (not just between them) clears what's picked.
    @State private var panelHeight: CGFloat = 400

    /// 64 points wide at the usual width, up to 104 as the panel is widened.
    private var thumbWidth: CGFloat { min(104, max(64, 64 + (panelWidth - 252) * 0.21)) }

    /// What's said in clips, for searching it (and to update as clips are heard).
    @ObservedObject private var transcripts = Transcripts.shared
    @ObservedObject private var scenes = SceneTagStore.shared

    /// Words typed in "quotes": what's said.
    private var phrases: [String] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard let re = try? NSRegularExpression(pattern: #"["“”]([^"“”]*)["“”]?"#) else { return [] }
        let ns = q as NSString
        return re.matches(in: q, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Where a clip says the first quoted phrase, to show under it.
    private func snippet(_ a: MediaAsset) -> (before: String, match: String, after: String)? {
        guard let phrase = phrases.first else { return nil }
        return media.transcript(a.id)?.snippet(phrase, typing: true)
    }

    /// The search: words in "quotes" are what's said in a clip; anything else is in its name.
    private func shown(_ assets: [MediaAsset]) -> [MediaAsset] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return assets }
        var phrases: [String] = []
        var rest = q
        if let re = try? NSRegularExpression(pattern: #"["“”]([^"“”]*)["“”]?"#) {
            let ns = q as NSString
            for m in re.matches(in: q, range: NSRange(location: 0, length: ns.length)) {
                let phrase = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty { phrases.append(phrase) }
            }
            rest = re.stringByReplacingMatches(in: q, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
        }
        return assets.filter { a in
            // Plain words: in its name, or what it shows ("pool"), each word as it's typed.
            if !rest.isEmpty, !a.name.localizedCaseInsensitiveContains(rest) {
                let tags = media.sceneTags(a.id)
                let words = rest.lowercased().split(separator: " ").map(String.init)
                guard words.allSatisfy({ w in a.name.lowercased().contains(w) || tags?.shows(w, typing: w == words.last) == true }) else { return false }
            }
            guard !phrases.isEmpty else { return true }
            guard let t = media.transcript(a.id) else { return false }
            return phrases.allSatisfy { t.says($0, typing: true) }
        }
    }

    var body: some View {
        // Folders: the one open (if it's still there), what's in it, and while searching, everything inside it.
        let tree = MediaTree(model.project)
        let folder = model.mediaFolder.flatMap { tree.exists($0) ? $0 : nil }
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        let shown = shown(searching ? (folder.map { tree.assets(under: $0, of: model.project.assets) } ?? model.project.assets)
                                    : tree.assets(in: folder, of: model.project.assets))
        let folders = searching ? [] : tree.folders(in: folder)
        let missingRoot = folder.flatMap { tree.root(of: $0) }.flatMap { MediaFolder.isFolder($0.path) ? nil : $0 }
        /// Where an item found by searching is, when that's not the folder open.
        func place(_ a: MediaAsset) -> String? {
            guard searching, let at = tree.folder(of: a), at != folder else { return nil }
            return tree.label(at)
        }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                // In a folder: back, and the way down to it, in place of the title.
                if let folder {
                    MediaTitle(model: model, tree: tree, folder: folder)
                } else {
                    Text("MEDIA")
                        .font(Theme.label())
                        .kerning(1.6)
                        .foregroundStyle(Theme.textDim)
                }
                if model.importCount > 0 {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                }
                Spacer()
                AddButton(model: model, symbol: "textformat", payload: .text, help: "Text: click to add at the playhead, or drag to the timeline")
                AddButton(model: model, symbol: "solid", payload: .solid, help: "Solid: click to add at the playhead, or drag to the timeline")
                IconButton(symbol: "square.and.arrow.down", size: 26, help: "Import Media (⌘I)") { model.showImportPanel() }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(height: 44)
            .contentShape(Rectangle())
            // Right-click: the header buttons' actions in words, and how the list looks.
            .contextMenu { panelMenu }

            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.project.assets.isEmpty && folders.isEmpty && model.incomingFiles.isEmpty {
                        SearchField(text: $search)
                        Text("Imported media\nappears here")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textFaint)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                    } else {
                        if let missingRoot {
                            MissingFolder(model: model, folder: missingRoot)
                        }
                        SearchField(text: $search, prompt: folder == nil ? "Search" : "Search folder")
                        let order = folders.map(MediaPick.folder) + shown.map { MediaPick.asset($0.id) }
                            + (folder == nil && !searching ? model.incomingFiles.map(MediaPick.incoming) : [])
                        let pickedCount = model.mediaSelection.count + model.folderSelection.count + model.incomingSelection.count
                        if layout == .thumbnails {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8, alignment: .top)], spacing: 10) {
                                ForEach(folders, id: \.self) { f in
                                    FolderTile(model: model, tree: tree, folder: f, picked: model.folderSelection.contains(f), pickedCount: pickedCount, clearSearch: { search = "" })
                                        .id(MediaPick.folder(f))
                                        .simultaneousGesture(TapGesture().onEnded { model.clickMedia(.folder(f), in: order) })
                                }
                                ForEach(shown) { asset in
                                    AssetTile(model: model, media: media, asset: asset, snippet: snippet(asset), place: place(asset), offline: media.looksOffline(asset), selected: false,
                                              picked: model.mediaSelection.contains(asset.id), pickedCount: pickedCount,
                                              matchesSequence: model.sequenceMatches(asset))
                                        .id(MediaPick.asset(asset.id))
                                        .simultaneousGesture(TapGesture().onEnded { model.clickMedia(.asset(asset.id), in: order) })
                                }
                                // Files another app is still writing (Photos): where they'll land.
                                if folder == nil && !searching {
                                    ForEach(model.incomingFiles, id: \.self) { id in
                                        IncomingTile(picked: model.incomingSelection.contains(id))
                                            .id(MediaPick.incoming(id))
                                            .simultaneousGesture(TapGesture().onEnded { model.clickMedia(.incoming(id), in: order) })
                                            .modifier(IncomingActions(model: model, id: id))
                                    }
                                }
                            }
                        } else {
                            VStack(spacing: 3) {
                                ForEach(folders, id: \.self) { f in
                                    FolderRow(model: model, tree: tree, folder: f, thumbWidth: thumbWidth, picked: model.folderSelection.contains(f), pickedCount: pickedCount, clearSearch: { search = "" })
                                        .id(MediaPick.folder(f))
                                        .simultaneousGesture(TapGesture().onEnded { model.clickMedia(.folder(f), in: order) })
                                }
                                ForEach(shown) { asset in
                                    AssetRow(model: model, media: media, asset: asset, snippet: snippet(asset), place: place(asset), thumbWidth: thumbWidth, offline: media.looksOffline(asset), selected: false,
                                             picked: model.mediaSelection.contains(asset.id), pickedCount: pickedCount,
                                             matchesSequence: model.sequenceMatches(asset))
                                        // A click picks it (⇧ for a range, ⌘ to add or take away); a double-click adds it.
                                        .id(MediaPick.asset(asset.id))
                                        .simultaneousGesture(TapGesture().onEnded { model.clickMedia(.asset(asset.id), in: order) })
                                }
                                if folder == nil && !searching {
                                    ForEach(model.incomingFiles, id: \.self) { id in
                                        IncomingRow(thumbWidth: thumbWidth, picked: model.incomingSelection.contains(id))
                                            .id(MediaPick.incoming(id))
                                            .simultaneousGesture(TapGesture().onEnded { model.clickMedia(.incoming(id), in: order) })
                                            .modifier(IncomingActions(model: model, id: id))
                                    }
                                }
                            }
                        }
                        if shown.isEmpty && folders.isEmpty && (model.incomingFiles.isEmpty || searching) {
                            Text(search.contains("\"") || search.contains("“") ? L10n.fmt("Nothing says %@", search) : L10n.fmt("No media matches “%@”", search))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textFaint)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                // A click on empty space (between items or below them) lets go of what's picked; items take their own clicks.
                .frame(maxWidth: .infinity, minHeight: max(0, panelHeight - 44), alignment: .top)
                .background(EmptySpaceClicks {
                    // Only Media's picks: the timeline's selection is left as it is.
                    model.mediaSelection = []
                    model.folderSelection = []
                    model.incomingSelection = []
                })
            }
            // The part of the list on screen, for Magic's scans.
            .background(MagicAnchor(key: "libraryList"))
            // The same menu on the space around the items (each item keeps its own).
            .contextMenu { panelMenu }
            // Just imported: scrolled into view (after the folder it's in has opened and drawn).
            .onChange(of: model.mediaReveal) { _, reveal in
                guard let reveal else { return }
                search = ""
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(reveal.target, anchor: .center) }
                }
            }
            }
        }
        .background(Theme.panel)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { panelWidth = g.size.width; panelHeight = g.size.height }
                .onChange(of: g.size.width) { _, w in panelWidth = w }
                .onChange(of: g.size.height) { _, h in panelHeight = h }
        })
        // Files dragged over the panel, or anywhere else in the window that imports: they'll land here.
        .overlay {
            if dropTargeted || model.importDropHover {
                ZStack(alignment: .bottom) {
                    // What happens, on a dark fade up from the bottom, so it reads over any pictures and the media stays in view.
                    LinearGradient(stops: [.init(color: .black.opacity(0.92), location: 0), .init(color: .black.opacity(0.7), location: 0.45),
                                           .init(color: .black.opacity(0), location: 1)], startPoint: .bottom, endPoint: .top)
                        .frame(height: 150)
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line").font(.system(size: 11, weight: .semibold))
                        Text("Add to Media").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: 0xF2F2F0))
                    .padding(.bottom, 22)
                    Rectangle().strokeBorder(Theme.accent.opacity(0.9), lineWidth: 2)
                }
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { model.importFiles($0) }
            return true
        }
    }
}

extension LibraryView {
    /// The Media panel's own menu: add a text or solid at the playhead, import, and List or Thumbnails.
    @ViewBuilder var panelMenu: some View {
        Button("Add Text") { model.addAtPlayhead(.text) }
        Button("Add Solid") { model.addAtPlayhead(.solid) }
        Button("Import Media…") { model.showImportPanel() }
            .keyboardShortcut("i", modifiers: .command)
        Divider()
        Picker("View as", selection: $layout) {
            ForEach(MediaLayout.allCases) { Text($0.name).tag($0) }
        }
        .pickerStyle(.inline)
    }
}

private struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            // A quote searches what's said: the icon says so as soon as it's typed.
            let saying = text.contains("\"") || text.contains("“")
            Image(systemName: saying ? "text.bubble" : "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(saying ? Theme.text : Theme.textFaint)
                .help(saying ? L10n.tr("Searching what's said in your clips") : "")
            TextField(L10n.tr(prompt), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.text.opacity(focused ? 0.85 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

/// A library item's picture. Moving the mouse across a video's thumbnail scrubs through it.
private struct MediaThumb: View {
    @ObservedObject var media: MediaStore
    /// Where to show the hovered frame full size; nil keeps scrubbing to the thumbnail.
    var preview: SourcePreviewState?
    let asset: MediaAsset
    let offline: Bool
    var compact = false
    @State private var scrub: CGFloat?
    @State private var frame: CGImage?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.5)
                if let frame, scrub != nil {
                    Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: g.size.width, height: g.size.height).clipped()
                } else if let poster = media.posters[asset.id] {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: g.size.width, height: g.size.height).clipped()
                } else {
                    Image(systemName: asset.kind == .audio ? "waveform" : asset.kind == .image ? "photo" : "film")
                        .font(.system(size: compact ? 13 : 20, weight: .regular))
                        .foregroundStyle(asset.kind == .audio ? Theme.textDim : Theme.textFaint)
                        .frame(width: g.size.width, height: g.size.height)
                }
                if offline {
                    Color.black.opacity(0.6)
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        .frame(width: g.size.width, height: g.size.height)
                }
                if let scrub {
                    Rectangle().fill(Color.white).frame(width: 1.5, height: g.size.height).offset(x: scrub - 0.75)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard asset.kind == .video, !offline, asset.duration > 0 else { return }
                switch phase {
                case .active(let p):
                    let x = min(max(0, p.x), g.size.width)
                    scrub = x
                    let fraction = Double(x / max(1, g.size.width))
                    // A frame made ahead, at once; until the strip is made, one decoded from the file.
                    let quick = media.instantFrame(asset: asset, at: fraction)
                    if let quick {
                        frame = quick
                    } else {
                        // Quantise so nearby positions share cached frames.
                        let steps = 60.0
                        let t = min(asset.duration - 0.05, (fraction * steps).rounded() / steps * asset.duration)
                        media.scrubFrame(asset: asset.id, time: max(0, t)) { img in
                            if scrub != nil { frame = img }
                        }
                    }
                    // The main viewer shows it too, full size and in playback's colours.
                    let exact = min(asset.duration - 0.02, fraction * asset.duration)
                    preview?.hover(asset, at: max(0, exact), media: media)
                case .ended:
                    scrub = nil
                    frame = nil
                    preview?.clear()
                }
            }
        }
    }
}

func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

private struct AddButton: View {
    let model: EditorModel
    let symbol: String
    let payload: DragPayload
    let help: String
    @State private var hovering = false

    var body: some View {
        Glyph(symbol: symbol, size: 12)
            .foregroundStyle(hovering ? Theme.text : Theme.textDim)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onTapGesture { model.addAtPlayhead(payload) }
            .background(MagicAnchor(key: payload == .text ? "addText" : "addSolid"))
            .onDrag {
                model.dragPayload = payload
                return NSItemProvider(object: ("editroom:" + (payload == .text ? "text" : "solid")) as NSString)
            }
            .help(L10n.tr(help))
    }
}

/// Shared behaviour for a library item: double-click adds it, drag it out, right-click for more.
private struct AssetActions: ViewModifier {
    let model: EditorModel
    let asset: MediaAsset
    let offline: Bool
    let picked: Bool
    let pickedCount: Int
    let matchesSequence: Bool

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) { model.addAtPlayhead(.asset(asset.id)) }
            .onDrag {
                model.dragPayload = .asset(asset.id)
                // Dragging one of several picked items takes them all, in the Media panel's order.
                let ids = picked && pickedCount > 1
                    ? model.project.assets.map(\.id).filter { model.mediaSelection.contains($0) }
                    : [asset.id]
                return NSItemProvider(object: ("editroom:" + ids.map(\.uuidString).joined(separator: ",")) as NSString)
            }
            .contextMenu {
                if offline {
                    Button("Locate…") { model.locate(asset.id) }
                    Divider()
                }
                Button("Add to Timeline") { model.addAtPlayhead(.asset(asset.id)) }
                if asset.kind == .video {
                    Button("Match Sequence to Clip") { model.matchSequence(to: asset) }
                        .disabled(matchesSequence)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.path)]) }
                if !offline {
                    // Normally automatic (when Editroom comes back to the front); this is for being sure.
                    let ids = picked && pickedCount > 1 ? model.mediaSelection : [asset.id]
                    Button(ids.count > 1 ? L10n.fmt("Reload %lld Items from Disk", ids.count) : L10n.tr("Reload from Disk")) {
                        Task { await model.reloadMedia(ids) }
                    }
                }
                Divider()
                // The picked items when this is one of them; otherwise just this one.
                if picked, pickedCount > 1 {
                    Button(L10n.fmt("Delete %lld Items", pickedCount)) { model.deleteSelected() }
                } else {
                    Button("Delete") { model.removeAssets([asset.id]) }
                }
            }
    }
}

private struct AssetRow: View {
    let model: EditorModel
    let media: MediaStore
    let asset: MediaAsset
    /// Where it says what's being searched for.
    var snippet: (before: String, match: String, after: String)?
    /// The folder it's in, for search results from other folders.
    var place: String?
    var thumbWidth: CGFloat = 64
    let offline: Bool
    /// Used by a clip selected on the timeline.
    let selected: Bool
    /// Picked in the Media panel.
    let picked: Bool
    let pickedCount: Int
    /// The sequence already has this video's size and rate. Passed in (rather than read from the
    /// model in the menu) so the row, and its menu, update when the sequence changes.
    let matchesSequence: Bool
    @State private var hovering = false

    /// Under the name: just how long it is (the frame size is on hover).
    private var detail: String {
        switch asset.kind {
        case .video: Timecode.short(asset.duration)
        case .audio: Timecode.short(asset.duration) + "  ·  " + L10n.tr("Audio")
        case .image: L10n.tr("Photo")
        }
    }

    /// On hover: everything about the file.
    private var details: String {
        var parts = [asset.name]
        if asset.kind != .image { parts.append(Timecode.short(asset.duration)) }
        if asset.width > 0 { parts.append("\(asset.width)×\(asset.height)") }
        if asset.kind == .video, asset.fps > 0 { parts.append(InspectorView.fpsLabel(asset.fps)) }
        if asset.kind == .audio { parts.append(L10n.tr("Audio")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 9) {
            MediaThumb(media: media, preview: model.sourcePreview, asset: asset, offline: offline, compact: true)
                .frame(width: thumbWidth, height: (thumbWidth * 9 / 16).rounded())
                .background(MagicAnchor(key: asset.id.uuidString))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovering || selected || picked ? Theme.text : Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                if let place { PlaceLine(place: place) }
                if let snippet { SaidLine(snippet: snippet) }
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(picked ? Theme.ink.opacity(0.12) : hovering ? Theme.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(picked ? Theme.ink.opacity(0.18) : Theme.control.opacity(selected ? 1 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(details)
        .modifier(AssetActions(model: model, asset: asset, offline: offline, picked: picked, pickedCount: pickedCount,
                               matchesSequence: matchesSequence))
    }
}

/// How the Media panel shows its items.
enum MediaLayout: String, CaseIterable, Identifiable {
    case thumbnails, list
    static let key = "mediaLayout"
    var id: String { rawValue }
    var name: String { self == .list ? L10n.tr("List") : L10n.tr("Thumbnails") }
}

/// A Media item as a larger picture, its name underneath: the Thumbnails layout.
private struct AssetTile: View {
    let model: EditorModel
    let media: MediaStore
    let asset: MediaAsset
    var snippet: (before: String, match: String, after: String)?
    var place: String?
    let offline: Bool
    let selected: Bool
    let picked: Bool
    let pickedCount: Int
    let matchesSequence: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            MediaThumb(media: media, preview: model.sourcePreview, asset: asset, offline: offline)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(MagicAnchor(key: asset.id.uuidString))
                .overlay(alignment: .bottomTrailing) {
                    if asset.kind != .image {
                        Text(Timecode.short(asset.duration))
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Color(hex: 0xF2F2F0))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.black.opacity(0.55)))
                            .padding(5)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(picked ? Theme.ink.opacity(0.85) : Theme.control.opacity(selected ? 1 : 0), lineWidth: picked ? 1.5 : 1))
            Text(asset.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering || selected || picked ? Theme.text : Theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 2)
            if let place { PlaceLine(place: place).padding(.horizontal, 2).padding(.top, -3) }
            if let snippet { SaidLine(snippet: snippet).padding(.horizontal, 2) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(picked ? Theme.ink.opacity(0.12) : hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .modifier(AssetActions(model: model, asset: asset, offline: offline, picked: picked, pickedCount: pickedCount,
                               matchesSequence: matchesSequence))
    }
}

/// What a clip says around the words being searched for, those words in bold.
private struct SaidLine: View {
    let snippet: (before: String, match: String, after: String)

    var body: some View {
        (Text("“" + (snippet.before.isEmpty ? "" : snippet.before + " "))
            + Text(snippet.match).bold().foregroundColor(Theme.text)
            + Text((snippet.after.isEmpty ? "" : " " + snippet.after) + "”"))
            .font(.system(size: 10))
            .foregroundStyle(Theme.textDim)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Folders

/// The folder a search result is in.
private struct PlaceLine: View {
    let place: String
    var body: some View {
        Text(place)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textFaint)
            .lineLimit(1)
            .truncationMode(.head)
    }
}

/// What a folder's right-click menu and double-click do, for its tile and its row.
private struct FolderActions: ViewModifier {
    let model: EditorModel
    let tree: MediaTree
    let folder: String
    let picked: Bool
    let pickedCount: Int
    let clearSearch: () -> Void

    func body(content: Content) -> some View {
        let root = tree.roots.first { $0.path == folder }
        let missing = !MediaFolder.isFolder(folder)
        content
            .onTapGesture(count: 2) { open() }
            .contextMenu {
                if missing, let root {
                    Button("Locate…") { model.locateFolder(root.id) }
                    Divider()
                }
                Button("Open") { open() }
                if !missing {
                    Button("Reload Folder from Disk") { Task { await model.reloadFolder(folder) } }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
                }
                Divider()
                // The picked folders and items when this is one of them; otherwise just this folder.
                if picked, pickedCount > 1 {
                    Button(L10n.fmt("Delete %lld Items", pickedCount)) { model.deleteSelected() }
                } else {
                    Button("Delete Folder") { model.removeFolder(folder) }
                }
            }
            .help(missing ? L10n.fmt("%@ can't be found. Right-click to locate it.", tree.name(folder))
                          : L10n.fmt("%@ · %lld items. Double-click to open. Changes in Finder are reflected here.",
                                     tree.name(folder), tree.count(under: folder)))
    }

    private func open() {
        clearSearch()
        model.mediaSelection = []
        model.folderSelection = []
        model.incomingSelection = []
        model.mediaFolder = folder
    }
}

/// A folder's picture: a folder, with how many items are in it (or a warning when it's missing).
private struct FolderPicture: View {
    let missing: Bool
    let count: Int
    var compact = false

    var body: some View {
        ZStack {
            // Quiet: a faint fill and no outline, so it sits back among the clips' (mostly dark) pictures.
            RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous).fill(Theme.ink.opacity(0.02))
            Image(systemName: "folder")
                .font(.system(size: compact ? 14 : 21, weight: .light))
                .foregroundStyle(Theme.textDim.opacity(0.8))
            if missing {
                Color.black.opacity(0.45)
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
        }
    }
}

/// A folder in the Thumbnails layout.
private struct FolderTile: View {
    let model: EditorModel
    let tree: MediaTree
    let folder: String
    let picked: Bool
    let pickedCount: Int
    let clearSearch: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            FolderPicture(missing: !MediaFolder.isFolder(folder), count: tree.count(under: folder))
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(picked ? 0.85 : 0), lineWidth: 1.5))
            // Its name, and how many items are in it at the right.
            HStack(spacing: 6) {
                Text(tree.name(folder))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hovering || picked ? Theme.text : Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if MediaFolder.isFolder(folder) {
                    Text("\(tree.count(under: folder))")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(picked ? Theme.ink.opacity(0.12) : hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .modifier(FolderActions(model: model, tree: tree, folder: folder, picked: picked, pickedCount: pickedCount, clearSearch: clearSearch))
    }
}

/// A folder in the List layout.
private struct FolderRow: View {
    let model: EditorModel
    let tree: MediaTree
    let folder: String
    var thumbWidth: CGFloat = 64
    let picked: Bool
    let pickedCount: Int
    let clearSearch: () -> Void
    @State private var hovering = false

    var body: some View {
        let missing = !MediaFolder.isFolder(folder)
        let n = tree.count(under: folder)
        HStack(spacing: 9) {
            FolderPicture(missing: missing, count: n, compact: true)
                .frame(width: thumbWidth, height: (thumbWidth * 9 / 16).rounded())
            VStack(alignment: .leading, spacing: 2) {
                Text(tree.name(folder))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovering || picked ? Theme.text : Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(missing ? L10n.tr("Missing") : L10n.fmt("%lld items", n))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(picked ? Theme.ink.opacity(0.12) : hovering ? Theme.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.ink.opacity(picked ? 0.18 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .modifier(FolderActions(model: model, tree: tree, folder: folder, picked: picked, pickedCount: pickedCount, clearSearch: clearSearch))
    }
}

/// The Media panel's title inside a folder: back (up one folder), and the open folder's name.
private struct MediaTitle: View {
    let model: EditorModel
    let tree: MediaTree
    let folder: String
    @State private var hoveringBack = false

    var body: some View {
        let trail = tree.trail(folder)
        let up = trail.count > 1 ? trail[trail.count - 2] : nil
        HStack(spacing: 5) {
            Button {
                model.mediaSelection = []
                model.folderSelection = []
                model.incomingSelection = []
                model.mediaFolder = up
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hoveringBack ? Theme.text : Theme.textDim)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hoveringBack ? Theme.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, -6)
            .onHover { hoveringBack = $0 }
            .animation(.easeOut(duration: 0.12), value: hoveringBack)
            .help(up.map { L10n.fmt("Back to %@", tree.name($0)) } ?? L10n.tr("Back to Media"))
            Text(tree.name(folder).uppercased())
                .font(Theme.label())
                .kerning(1.6)
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(tree.label(folder))
        }
    }
}

/// Inside a linked folder that can't be found: where to find it.
private struct MissingFolder: View {
    let model: EditorModel
    let folder: MediaFolder

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(.yellow)
            Text("“\(folder.name)” can't be found")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Locate…") { model.locateFolder(folder.id) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.onText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.text))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raised))
    }
}

/// Behind the Media panel's items: a click or right-click on empty space lets go of what's picked there (a right-click,
/// as in Finder, then goes on to open the panel's menu). Items in front take their own clicks.
private struct EmptySpaceClicks: NSViewRepresentable {
    let clear: () -> Void

    func makeNSView(context: Context) -> Catcher {
        let v = Catcher()
        v.clear = clear
        return v
    }

    func updateNSView(_ v: Catcher, context: Context) { v.clear = clear }

    final class Catcher: NSView {
        var clear: () -> Void = {}
        override func mouseDown(with event: NSEvent) { clear() }
        override func rightMouseDown(with event: NSEvent) {
            clear()
            super.rightMouseDown(with: event)
        }
    }
}

// MARK: - Files on their way

/// A file another app is still writing for a drop (Photos fetching a video): a dim tile with a spinner, where it'll land.
private struct IncomingTile: View {
    var picked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.02))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(picked ? 0.85 : 0.06), lineWidth: picked ? 1.5 : 1)
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            Text("Importing…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(picked ? Theme.ink.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .help("Being written by the app it came from (Photos may be fetching it from iCloud). Delete cancels it.")
    }
}

/// The same, in the List layout.
private struct IncomingRow: View {
    var thumbWidth: CGFloat = 64
    var picked = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.ink.opacity(0.02))
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.ink.opacity(0.06))
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            .frame(width: thumbWidth, height: (thumbWidth * 9 / 16).rounded())
            Text("Importing…")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textFaint)
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(picked ? Theme.ink.opacity(0.12) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.ink.opacity(picked ? 0.18 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .help("Being written by the app it came from (Photos may be fetching it from iCloud). Delete cancels it.")
    }
}

/// A placeholder's right-click: cancel it (or every picked one, when it's one of them).
private struct IncomingActions: ViewModifier {
    let model: EditorModel
    let id: UUID

    func body(content: Content) -> some View {
        content.contextMenu {
            let ids = model.incomingSelection.contains(id) ? model.incomingSelection : [id]
        Button(ids.count > 1 ? L10n.fmt("Cancel %lld Imports", ids.count) : L10n.tr("Cancel Import")) { model.cancelIncoming(ids) }
        }
    }
}
