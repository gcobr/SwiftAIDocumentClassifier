import SwiftUI

struct SidebarView: View {
    @Bindable var store: ClassifierStore

    var body: some View {
        List(selection: $store.selectedFolderID) {
            ForEach(store.folders.filter(\.isInbox)) { folder in
                row(folder, systemImage: "tray")
            }
            Section("Document Types") {
                ForEach(store.folders.filter { !$0.isInbox }) { folder in
                    row(folder, systemImage: "folder.fill")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            LibrarySizeView(monitor: store.librarySize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("New Type", systemImage: "plus") { store.editor = .create }
                    .buttonStyle(.borderless)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 232)
    }

    private func row(_ folder: DocumentFolder, systemImage: String) -> some View {
        FolderRow(folder: folder, count: store.counts[folder.id] ?? 0, systemImage: systemImage,
                  acceptsDrops: store.schemaUpdate == nil) { items in
            for item in items {
                Task { await store.assign(item.documentID, to: folder.id) }
            }
        }
        .tag(folder.id)
    }
}

/// A sidebar folder that accepts documents dragged from the table; the user's choice of type is applied as is.
private struct FolderRow: View {
    let folder: DocumentFolder
    let count: Int
    let systemImage: String
    let acceptsDrops: Bool
    let onDrop: ([DocumentDragItem]) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        Label(folder.name, systemImage: systemImage)
            // The drop target spans the whole row, not just the label text, so the row reacts wherever the
            // pointer is over it.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.3))
                        .padding(.horizontal, -8)
                        .padding(.vertical, -4)
                }
            }
            .dropDestination(for: DocumentDragItem.self, isEnabled: acceptsDrops) { items, _ in
                isDropTargeted = false
                onDrop(items)
            }
            // Filing moves the document, so the pointer shows a move rather than a copy ("+").
            .dropConfiguration { _ in DropConfiguration(operation: .move) }
            .onDropSessionUpdated { session in
                isDropTargeted = session.phase == .entering || session.phase == .active
            }
            .badge(count)
    }
}

/// Disk space used by the library; updates as content is added.
private struct LibrarySizeView: View {
    let monitor: LibrarySizeMonitor

    var body: some View {
        HStack {
            Label("Library", systemImage: "internaldrive")
            Spacer()
            if let usage = monitor.usage {
                Text(usage.formattedSize)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: usage)
                    .help(usage.fileCount == 1 ? "1 file in the library" : "\(usage.fileCount) files in the library")
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
