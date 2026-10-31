import SwiftUI

struct ContentView: View {
    @State private var store: ClassifierStore
    @State private var isImporting = false

    init(store: ClassifierStore = ClassifierStore()) {
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            if let folder = store.selectedFolder {
                FolderDetailView(store: store, folder: folder, onAddDocuments: { isImporting = true })
                    .id(folder.id)
            } else {
                ContentUnavailableView("No Folder Selected", systemImage: "sidebar.left")
            }
        }
        .overlay(alignment: .top) {
            Group {
                if let progress = store.classificationProgress {
                    ClassificationProgressBanner(progress: progress)
                } else if let notice = store.classificationNotice {
                    ClassificationBanner(store: store, notice: notice)
                }
            }
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        .animation(.default, value: store.classificationNotice?.id)
        .animation(.default, value: store.classificationProgress == nil)
        // Converting values after a data-type change blocks the window, toolbar included.
        .disabled(store.schemaUpdate != nil)
        .overlay {
            if let progress = store.schemaUpdate {
                SchemaUpdateOverlay(progress: progress)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: ClassifierStore.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await store.importFiles(urls) } }
        }
        .task { await store.load() }
        .sheet(item: $store.editor) { mode in
            TypeEditorSheet(store: store, mode: mode)
        }
        .sheet(item: $store.valueEditor) { target in
            FieldValuesSheet(store: store, target: target)
        }
    }
}

/// Toolbar, table, and preview for one folder.
struct FolderDetailView: View {
    @Bindable var store: ClassifierStore
    let folder: DocumentFolder
    let onAddDocuments: () -> Void

    @State private var searchText = ""
    @State private var sortOrder: [DocumentComparator] = []
    @State private var showsInspector = true
    /// Row order for the current search and sort, from the database; nil shows `store.rows` as loaded.
    @State private var orderedIDs: [Document.ID]?
    @State private var lastSearch = ""
    @State private var removalCandidate: Document?

    private var query: RowQuery {
        RowQuery(search: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                 sort: sortOrder.first?.sort, revision: store.rowsRevision)
    }

    private var isLoaded: Bool { store.rowsFolderID == folder.id }

    private var visibleDocs: [Document] {
        guard isLoaded else { return [] }
        guard let orderedIDs else { return store.rows }
        return orderedIDs.compactMap { store.row($0) }
    }

    /// The stored selection while that document still exists, otherwise the first row.
    private var selection: Binding<Document.ID?> {
        Binding {
            if let id = store.selectedDocByFolder[folder.id], store.row(id) != nil { return id }
            guard isLoaded else { return nil }
            return orderedIDs.map { ids in ids.first { store.row($0) != nil } } ?? store.rows.first?.id
        } set: {
            store.selectedDocByFolder[folder.id] = $0
        }
    }

    private var documentCount: Int { store.counts[folder.id] ?? 0 }

    var body: some View {
        content
            .navigationTitle(folder.name)
            #if os(macOS)
            .navigationSubtitle(documentCount == 1 ? "1 document" : "\(documentCount.formatted()) documents")
            #endif
            .searchable(text: $searchText, prompt: "Search \(folder.name)")
            .task(id: query) { await runQuery(query) }
            .confirmationDialog("Remove “\(removalCandidate?.name ?? "")” from the library?",
                                isPresented: Binding { removalCandidate != nil } set: { if !$0 { removalCandidate = nil } },
                                presenting: removalCandidate) { doc in
                Button("Remove", role: .destructive) { Task { await store.removeDocument(doc.id) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The file and its extracted values are deleted. This can't be undone.")
            }
            .toolbar {
                if !folder.isInbox {
                    ToolbarItem(placement: .navigation) {
                        Button("Edit Type", systemImage: "pencil") { store.editor = .edit(folder.id) }
                            .help("Edit type & schema")
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    // Same size while running: the symbol pulses and the steps show in the banner,
                    // so the toolbar never relayouts.
                    let isRunning = store.classificationProgress != nil
                    Button {
                        if let id = selection.wrappedValue { Task { await store.classify(id) } }
                    } label: {
                        Label(folder.isInbox ? "AI Classify" : "AI Reclassify", systemImage: "apple.intelligence")
                            .symbolEffect(.pulse, options: .repeating, isActive: isRunning)
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(isRunning || selection.wrappedValue == nil || store.aiUnavailableReason != nil)
                    .help(store.aiUnavailableReason ?? (folder.isInbox
                        ? "Classify the selected document with Apple Intelligence"
                        : "Classify the selected document again; it moves only if the result is a different type"))
                    Button("Remove", systemImage: "trash") {
                        removalCandidate = selection.wrappedValue.flatMap { store.row($0) }
                    }
                    .disabled(selection.wrappedValue == nil
                              || store.classificationProgress?.documentID == selection.wrappedValue)
                    .help("Remove the selected document and its file from the library")
                    Button("Add Documents", systemImage: "tray.and.arrow.down", action: onAddDocuments)
                        .labelStyle(.titleAndIcon)
                    Button("Inspector", systemImage: "info.circle") { showsInspector.toggle() }
                        .help(showsInspector ? "Hide Inspector" : "Show Inspector")
                }
            }
    }

    /// Searching and sorting run in the database, so the main thread only maps IDs to loaded rows. Typing is
    /// debounced; the task restarts (cancelling this one) on every change.
    private func runQuery(_ query: RowQuery) async {
        guard !query.search.isEmpty || query.sort != nil else {
            orderedIDs = nil
            lastSearch = ""
            return
        }
        if query.search != lastSearch {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
        }
        let ids = await store.documentIDs(matching: query.search, sortedBy: query.sort)
        guard !Task.isCancelled else { return }
        orderedIDs = ids
        lastSearch = query.search
    }

    private var editValues: ((Document) -> Void)? {
        guard !folder.isInbox else { return nil }
        return { [store, folder] doc in store.valueEditor = ValueEditorTarget(folderID: folder.id, document: doc) }
    }

    @ViewBuilder
    private var content: some View {
        if !isLoaded {
            Color.clear
        } else if store.rows.isEmpty {
            EmptyFolderView(folder: folder)
        } else {
            let docs = visibleDocs
            let selected = docs.first { $0.id == selection.wrappedValue }
            #if os(macOS)
            VSplitView {
                DocumentTable(folder: folder, docs: docs, selection: selection, sortOrder: $sortOrder)
                    .frame(minHeight: 120)
                DocumentPreview(folder: folder, doc: selected, showsInspector: showsInspector,
                                onEditValues: editValues)
                    .frame(minHeight: 220, idealHeight: 330)
            }
            #else
            VStack(spacing: 0) {
                DocumentTable(folder: folder, docs: docs, selection: selection, sortOrder: $sortOrder)
                Divider()
                DocumentPreview(folder: folder, doc: selected, showsInspector: showsInspector,
                                onEditValues: editValues)
                    .frame(height: 330)
            }
            #endif
        }
    }
}

/// Blocks the window while a field's values are converted to its new data type, with document-level progress.
private struct SchemaUpdateOverlay: View {
    let progress: SchemaUpdateProgress

    /// Short conversions finish before this delay, so the overlay doesn't flash.
    @State private var isVisible = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(alignment: .leading, spacing: 10) {
                Text("Updating \(progress.typeName)").font(.headline)
                Text("Converting \(ListFormatter.localizedString(byJoining: progress.fieldNames)) values to the new data type. Values that can't be converted are removed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                Text("\(progress.completed.formatted()) of \(progress.total.formatted()) documents")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(width: 380)
            .glassEffect(in: .rect(cornerRadius: 16))
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .opacity(isVisible ? 1 : 0)
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation { isVisible = true }
        }
    }
}

/// Shows the current classification step while the model works.
private struct ClassificationProgressBanner: View {
    let progress: ClassificationProgress

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(progress.documentName)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(progress.step)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect()
        .animation(.default, value: progress.step)
    }
}

/// Reports where AI classification filed a document (with a button to go there), or why it failed.
private struct ClassificationBanner: View {
    let store: ClassifierStore
    let notice: ClassificationNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : notice.systemImage)
                .foregroundStyle(notice.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
            Text(notice.message)
                .lineLimit(2)
            if let folderID = notice.folderID {
                Button("Show") {
                    store.selectedFolderID = folderID
                    store.classificationNotice = nil
                }
            }
            Button("Dismiss", systemImage: "xmark") { store.classificationNotice = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect()
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(notice.isError ? 10 : 5))
            if store.classificationNotice?.id == notice.id { store.classificationNotice = nil }
        }
    }
}

struct EmptyFolderView: View {
    let folder: DocumentFolder

    var body: some View {
        ContentUnavailableView {
            Label("No Documents", systemImage: "tray")
        } description: {
            Text("Documents classified as \(Text(folder.name).bold()) will appear here.")
            Text(fieldSummary)
                .font(.caption)
        }
    }

    private var fieldSummary: String {
        switch folder.fields.count {
        case 0: "No extraction fields defined yet."
        case 1: "1 field will be extracted from each document."
        case let n: "\(n) fields will be extracted from each document."
        }
    }
}

/// What the table shows: a search and a sort, re-run whenever the loaded rows change.
private struct RowQuery: Hashable {
    var search: String
    var sort: DocumentSort?
    var revision: Int
}

#Preview {
    ContentView(store: .preview())
        .frame(width: 1200, height: 780)
}
