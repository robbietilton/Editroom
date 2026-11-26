import SwiftUI

/// Toolbar pill for exports running in the background: progress and time left, or the result.
/// Click it for the list, to cancel one or show a finished file.
struct ExportProgressPill: View {
    @ObservedObject var queue: ExportQueue
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        if !queue.items.isEmpty {
            Button { open.toggle() } label: { label }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .popover(isPresented: $open, arrowEdge: .bottom) { ExportList(queue: queue) }
                .onChange(of: open) { _, isOpen in queue.holdOpen = isOpen }
                .padding(.trailing, 6)
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            if let current = queue.current {
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.12))
                    Capsule().fill(Theme.accent).frame(width: max(4, 72 * queue.progress))
                }
                .frame(width: 72, height: 4)
                Text(status(current))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.text)
            } else if queue.items.contains(where: { if case .failed = $0.status { return true }; return false }) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFF7A6B))
                Text("Export failed").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text)
            } else if queue.items.contains(where: { $0.status == .done }) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x3DDC97))
                Text("Exported").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text)
            }
            if queue.waiting > 0 {
                Text("+\(queue.waiting)").font(Theme.mono(10)).foregroundStyle(Theme.textDim)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(Capsule().fill(hovering ? Theme.hover : Theme.field))
        .contentShape(Capsule())
        .help("Exports")
    }

    private func status(_ item: ExportQueue.Item) -> String {
        let pct = "\(Int(queue.progress * 100))%"
        guard let left = queue.timeLeft else { return pct }
        return L10n.fmt("%@  ·  %@ left", pct, Timecode.short(left))
    }
}

private struct ExportList: View {
    @ObservedObject var queue: ExportQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(queue.items) { item in
                HStack(spacing: 10) {
                    icon(item.status)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                        Text(detail(item)).font(.system(size: 10)).foregroundStyle(Theme.textFaint).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    switch item.status {
                    case .running, .waiting:
                        IconButton(symbol: "xmark", size: 22, help: "Cancel") { queue.cancel(item.id) }
                    case .done:
                        IconButton(symbol: "magnifyingglass", size: 22, help: "Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        }
                    default:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                Hairline()
            }
            if queue.items.contains(where: { $0.status != .running && $0.status != .waiting }) {
                Button("Clear Finished") { queue.clearFinished() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                    .padding(12)
            }
        }
        .frame(width: 300)
        .background(Theme.panel)
    }

    @ViewBuilder private func icon(_ status: ExportQueue.Status) -> some View {
        switch status {
        case .running: ProgressView(value: queue.progress).progressViewStyle(.circular).controlSize(.small).tint(Theme.accent)
        case .waiting: Image(systemName: "clock").foregroundStyle(Theme.textDim)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x3DDC97))
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFF7A6B))
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(Theme.textFaint)
        }
    }

    private func detail(_ item: ExportQueue.Item) -> String {
        let s = item.settings
        let kind = s.format == .wav ? "WAV" : "\(s.codec.rawValue) · \(Int(s.renderSize(for: item.project).height))p"
        switch item.status {
        case .running: return kind + " · \(Int(queue.progress * 100))%"
        case .waiting: return L10n.fmt("%@ · waiting", kind)
        case .done: return L10n.fmt("%@ · done", kind)
        case .failed(let m): return m
        case .cancelled: return L10n.fmt("%@ · cancelled", kind)
        }
    }
}
