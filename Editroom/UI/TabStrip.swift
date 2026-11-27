import SwiftUI
import AppKit

/// The open projects, as tabs across the title bar, each as wide as its name (up to a limit), with + for a
/// new one. Only the tab in front has a pill; the others are just their names until hovered. With more than
/// fit, they shrink evenly and their names are cut short. One project shows just its name.
struct TabStrip: View {
    @ObservedObject var workspace: Workspace

    /// Narrower than this, tabs are put in the "more tabs" menu instead.
    static let minTab: CGFloat = 84
    private static let spacing: CGFloat = 2
    private static let plusWidth: CGFloat = 26
    private static let moreWidth: CGFloat = 124

    var body: some View {
        GeometryReader { g in
            let tabs = workspace.tabs
            let (shown, hidden) = split(tabs, width: g.size.width)
            HStack(spacing: 4) {
                if !hidden.isEmpty {
                    MoreTabsButton(hidden: hidden) { workspace.select($0) }
                }
                TabRow(minTab: Self.minTab, spacing: Self.spacing) {
                    ForEach(shown, id: \.slot) { model in
                        TabItem(model: model, active: model === workspace.active, single: tabs.count == 1,
                                select: { workspace.select(model) },
                                close: { workspace.close(model) },
                                closeOthers: tabs.count > 1 ? { workspace.closeOthers(than: model) } : nil)
                    }
                    NewTabButton { workspace.newTab() }
                }
            }
        }
        .frame(height: 28)
    }

    /// The tabs that fit, keeping the one in front, and the rest for the menu.
    private func split(_ tabs: [EditorModel], width: CGFloat) -> ([EditorModel], [EditorModel]) {
        let per = Self.minTab + Self.spacing
        guard CGFloat(tabs.count) * per + Self.plusWidth <= width else {
            let fit = max(1, Int((width - Self.plusWidth - Self.moreWidth - 4) / per))
            let front = tabs.firstIndex { $0 === workspace.active } ?? 0
            // The last ones show, unless the one in front is further left: then the run ending at it.
            var from = max(0, tabs.count - fit)
            if front < from { from = max(0, front - fit + 1) }
            let shown = Array(tabs[from..<min(tabs.count, from + fit)])
            return (shown, tabs.filter { t in !shown.contains { $0 === t } })
        }
        return (tabs, [])
    }
}

/// "6 more tabs ⌄": the tabs that don't fit, to pick from.
private struct MoreTabsButton: View {
    let hidden: [EditorModel]
    let pick: (EditorModel) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            let menu = NSMenu()
            for model in hidden {
                let item = NSMenuItem(title: model.title + (model.showsUnsaved ? " •" : ""), action: #selector(MenuAction.run), keyEquivalent: "")
                let action = MenuAction { pick(model) }
                item.target = action
                item.representedObject = action
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: {
            HStack(spacing: 5) {
                Text("\(hidden.count) more tab\(hidden.count == 1 ? "" : "s")")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(hovering ? Theme.text : Theme.textDim)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background(Capsule().fill(Theme.ink.opacity(hovering ? 0.08 : 0.04)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovering = $0 }
    }
}

/// A menu item's action, as a closure.
private final class MenuAction: NSObject {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func run() { body() }
}

/// Lays tabs out from the left, each as wide as it would like up to a limit, with the last view (+) after them.
/// Short of room, the widest give way first, down to an equal share each.
private struct TabRow: Layout {
    var maxTab: CGFloat = 190
    var minTab: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = widths(subviews, available: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? w.reduce(0, +) + spacing * CGFloat(max(0, w.count - 1)), height: proposal.height ?? 28)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (view, w) in zip(subviews, widths(subviews, available: bounds.width)) {
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }

    private func widths(_ subviews: Subviews, available: CGFloat) -> [CGFloat] {
        guard let plus = subviews.last?.sizeThatFits(.unspecified).width else { return [] }
        let ideals = subviews.dropLast().map { min(maxTab, $0.sizeThatFits(.unspecified).width) }
        var room = available - plus - spacing * CGFloat(subviews.count - 1)
        var out = ideals
        // The narrowest keep their size; the rest share what's left.
        var left = ideals.indices.sorted { ideals[$0] < ideals[$1] }
        while let i = left.first {
            let share = room / CGFloat(left.count)
            if ideals[i] <= share {
                room -= ideals[i]
                left.removeFirst()
            } else {
                for j in left { out[j] = max(minTab, share) }
                break
            }
        }
        return out + [plus]
    }
}

private struct TabItem: View {
    @ObservedObject var model: EditorModel
    let active: Bool
    let single: Bool
    let select: () -> Void
    let close: () -> Void
    let closeOthers: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        // The only tab shows × on hover (closing its project), unless it's already empty.
        let closable = !single || !model.isBlank
        let showsClose = closable && (single ? hovering : active || hovering)
        HStack(spacing: 6) {
            Text(model.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active && !single ? Theme.text : Theme.textDim)
                .lineLimit(1)
                .truncationMode(.tail)
            if model.showsUnsaved {
                Circle().fill(active ? Theme.textDim : Theme.textFaint).frame(width: 5, height: 5)
            }
            if closable {
                // Room for × kept on every tab, so a tab doesn't change width as it's hovered.
                TabCloseButton(action: close)
                    .opacity(showsClose ? 1 : 0)
                    .allowsHitTesting(showsClose)
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, closable ? 6 : 13)
        .frame(maxHeight: .infinity)
        .background(Capsule().fill(fill))
        .contentShape(Capsule())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(model.openPath ?? model.title)
        .contextMenu {
            Button("Close Tab", action: close)
            if let closeOthers { Button("Close Other Tabs", action: closeOthers) }
        }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }

    private var fill: Color {
        if single { return .clear }
        if active { return Theme.ink.opacity(0.13) }
        return hovering ? Theme.ink.opacity(0.06) : .clear
    }
}

private struct TabCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hovering ? Theme.text : Theme.textDim)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.ink.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close Tab (\(ShortcutStore.shared.combos(.closeTab).first?.display ?? "⌘W"))")
    }
}

private struct NewTabButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.textDim)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.ink.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New Tab (\(ShortcutStore.shared.combos(.newTab).first?.display ?? "⌘T"))")
    }
}
