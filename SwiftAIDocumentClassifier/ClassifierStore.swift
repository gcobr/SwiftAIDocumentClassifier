import CryptoKit
import FoundationModels
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class ClassifierStore {
    /// The inbox followed by the document types, with their fields. Documents live in the database; only the
    /// selected folder's are loaded, in `rows`.
    var folders: [DocumentFolder] = [.inbox]
    /// Number of documents per folder, for the sidebar badges.
    private(set) var counts: [DocumentFolder.ID: Int] = [:]
    var selectedFolderID: DocumentFolder.ID? = DocumentFolder.inbox.id {
        didSet {
            if selectedFolderID != oldValue { Task { await reloadRows() } }
        }
    }
    /// Selected document per folder, so switching folders keeps each folder's selection.
    var selectedDocByFolder: [DocumentFolder.ID: Document.ID] = [:]
    /// The selected folder's documents, newest first. They belong to `rowsFolderID`, which lags behind
    /// `selectedFolderID` while another folder loads.
    private(set) var rows: [Document] = []
    private(set) var rowsFolderID: DocumentFolder.ID?
    /// Changes every time `rows` is reloaded, so views re-run their sorted or filtered queries.
    private(set) var rowsRevision = 0
    var editor: TypeEditorMode?
    var valueEditor: ValueEditorTarget?
    /// Set while values are being converted after a field's data type changed; the window is blocked meanwhile.
    var schemaUpdate: SchemaUpdateProgress?
    var classificationProgress: ClassificationProgress?
    var classificationNotice: ClassificationNotice?

    @ObservationIgnored private let library: DocumentLibrary
    @ObservationIgnored private var database: LibraryDatabase?
    @ObservationIgnored private var rowIndex: [Document.ID: Int] = [:]
    /// Reloads can overlap; only the latest one is applied.
    @ObservationIgnored private var rowsGeneration = 0
    @ObservationIgnored let classifier = DocumentClassifier()
    let librarySize: LibrarySizeMonitor

    init(library: DocumentLibrary = .default) {
        self.library = library
        librarySize = LibrarySizeMonitor(library: library)
    }

    var selectedFolder: DocumentFolder? {
        folders.first { $0.id == selectedFolderID }
    }

    /// A loaded row of the selected folder.
    func row(_ id: Document.ID) -> Document? {
        rowIndex[id].map { rows[$0] }
    }

    // MARK: Loading

    /// Opens the database and loads the types and the selected folder. Every window calls this once; they share
    /// one database.
    func load() async {
        guard database == nil else { return }
        // On macOS, previews also launch the app's window; keep them out of the user's library.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            database = try? LibraryDatabase.inMemory(library: library)
            folders = [.inbox] + ((try? await database?.types()) ?? [])
            await reloadRows()
            return
        }
        do {
            let (database, created) = try await Self.openDatabase(library)
            self.database = database
            librarySize.setNeedsUpdate()
            if created { await recoverLeftoverFiles() }
            folders = [.inbox] + (try await database.types())
            await reloadRows()
        } catch {
            notify("Couldn't open the document library: \(error.localizedDescription)", isError: true)
        }
    }

    @ObservationIgnored private static var opening: Task<(database: LibraryDatabase, created: Bool), any Error>?

    /// Opens the database once per process; only the first caller learns whether it was just created.
    private static func openDatabase(_ library: DocumentLibrary) async throws -> (database: LibraryDatabase, created: Bool) {
        if let opening { return (try await opening.value.database, false) }
        let task = Task { try await LibraryDatabase.open(library) }
        opening = task
        return try await task.value
    }

    /// A store on an in-memory copy of the sample data, loaded synchronously so previews render immediately.
    static func preview(selecting folderID: DocumentFolder.ID = DocumentFolder.inbox.id) -> ClassifierStore {
        let store = ClassifierStore()
        guard let database = try? LibraryDatabase.inMemory(library: store.library),
              let snapshot = try? database.previewSnapshot(of: folderID) else { return store }
        store.database = database
        store.folders = [.inbox] + snapshot.types
        store.counts = snapshot.counts
        store.selectedFolderID = folderID
        store.setRows(snapshot.rows, of: folderID)
        return store
    }

    /// Reloads the selected folder's rows and the sidebar counts.
    func reloadRows() async {
        guard let database, let folderID = selectedFolderID else { return }
        rowsGeneration += 1
        let generation = rowsGeneration
        do {
            let docs = try await database.documents(in: folderID)
            let counts = try await database.documentCounts()
            guard generation == rowsGeneration else { return }
            self.counts = counts
            setRows(docs, of: folderID)
        } catch {
            notify("Couldn't load \(selectedFolder?.name ?? "the folder"): \(error.localizedDescription)", isError: true)
        }
    }

    private func setRows(_ docs: [Document], of folderID: DocumentFolder.ID) {
        rows = docs
        rowIndex = Dictionary(uniqueKeysWithValues: docs.enumerated().map { ($1.id, $0) })
        rowsFolderID = folderID
        rowsRevision += 1
    }

    /// The selected folder's document IDs matching `search`, in `sort` order; nil if the query failed.
    func documentIDs(matching search: String, sortedBy sort: DocumentSort?) async -> [Document.ID]? {
        guard let database, let folderID = rowsFolderID else { return nil }
        return try? await database.documentIDs(in: folderID, matching: search, sortedBy: sort)
    }

    /// Number of the type's documents with a value for any of `keys` (for the type sheet's warning).
    func documentCount(in typeID: DocumentFolder.ID, withValuesFor keys: Set<String>) async -> Int {
        (try? await database?.documentCount(in: typeID, withValuesFor: keys)) ?? 0
    }

    // MARK: Document types

    var typeFolders: [DocumentFolder] { folders.filter { !$0.isInbox } }

    @discardableResult
    func createType(name: String, description: String, fields: [SchemaField], select: Bool = true) async -> DocumentFolder.ID? {
        guard let database else { return nil }
        let folder = DocumentFolder(id: "t_" + UUID().uuidString.prefix(8).lowercased(), name: name,
                                    description: description, fields: fields)
        do {
            try await database.saveType(folder)
        } catch {
            notify("Couldn't create \(name): \(error.localizedDescription)", isError: true)
            return nil
        }
        librarySize.setNeedsUpdate()
        folders.append(folder)
        if select { selectedFolderID = folder.id }
        return folder.id
    }

    /// Saves a type's edits. Values of fields that were removed from the schema are deleted from all of the
    /// type's documents; renamed fields keep their key, so their values stay. Values of fields whose data type
    /// changed are converted (see `convertValues`).
    func updateType(id: DocumentFolder.ID, name: String, description: String, fields: [SchemaField]) async {
        guard let database, var folder = folders.first(where: { $0.id == id }) else { return }
        let removedKeys = removedFieldKeys(in: id, keeping: fields)
        let retyped = retypedFields(in: id, to: fields)
        folder.name = name
        folder.description = description
        folder.fields = fields
        do {
            try await database.saveType(folder, removing: removedKeys)
        } catch {
            notify("Couldn't save \(name): \(error.localizedDescription)", isError: true)
            return
        }
        librarySize.setNeedsUpdate()
        if let i = folders.firstIndex(where: { $0.id == id }) { folders[i] = folder }
        if !retyped.isEmpty { await convertValues(of: retyped, in: id) }
        await reloadRows()
    }

    /// Keys of the type's current fields that `fields` no longer contains.
    func removedFieldKeys(in typeID: DocumentFolder.ID, keeping fields: [SchemaField]) -> Set<String> {
        guard let type = folders.first(where: { $0.id == typeID }) else { return [] }
        return Set(type.fields.map(\.key)).subtracting(fields.map(\.key))
    }

    /// Fields in `fields` that exist in the type with a different data type.
    func retypedFields(in typeID: DocumentFolder.ID, to fields: [SchemaField]) -> [SchemaField] {
        guard let type = folders.first(where: { $0.id == typeID }) else { return [] }
        let current = Dictionary(uniqueKeysWithValues: type.fields.map { ($0.key, $0.type) })
        return fields.filter { field in current[field.key].map { $0 != field.type } ?? false }
    }

    /// Converts the retyped fields' values in every document of the type, discarding values that can't be
    /// converted. Works in write transactions of `conversionBatchSize` documents, updating the blocking progress
    /// overlay (`schemaUpdate`) between them; a type can hold thousands of documents.
    private func convertValues(of fields: [SchemaField], in typeID: DocumentFolder.ID) async {
        guard let database, let type = folders.first(where: { $0.id == typeID }) else { return }
        let types = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.type) })
        guard let affected = try? await database.documentIDs(in: typeID, withValuesFor: Set(types.keys)),
              !affected.isEmpty else { return }

        schemaUpdate = SchemaUpdateProgress(typeName: type.name, fieldNames: fields.map(\.label),
                                            completed: 0, total: affected.count)
        defer { schemaUpdate = nil }

        var converted = 0, discarded = 0
        for start in stride(from: 0, to: affected.count, by: Self.conversionBatchSize) {
            let end = min(start + Self.conversionBatchSize, affected.count)
            do {
                let result = try await database.convertValues(of: types, in: Array(affected[start..<end]), typeID: typeID)
                converted += result.converted
                discarded += result.discarded
            } catch {
                notify("Couldn't convert the values of \(type.name): \(error.localizedDescription)", isError: true)
                return
            }
            schemaUpdate?.completed = end
        }
        librarySize.setNeedsUpdate()

        let names = ListFormatter.localizedString(byJoining: fields.map(\.label))
        var message = "Converted \(converted.formatted()) \(names) value\(converted == 1 ? "" : "s") in \(type.name)."
        if discarded > 0 {
            message += " \(discarded.formatted()) couldn't be converted and \(discarded == 1 ? "was" : "were") removed."
        }
        classificationNotice = ClassificationNotice(message: message, systemImage: "arrow.triangle.2.circlepath",
                                                    isError: discarded > 0)
    }

    private static let conversionBatchSize = 1_000

    /// Replaces a document's extracted values (keyed by `SchemaField.key`), e.g. after the user corrects them.
    func updateValues(_ values: [String: String], of documentID: Document.ID) async {
        guard let database else { return }
        do {
            try await database.replaceValues(values, of: documentID)
        } catch {
            notify("Couldn't save the values: \(error.localizedDescription)", isError: true)
            return
        }
        librarySize.setNeedsUpdate()
        await reloadRows()
    }

    /// Deletes a document from the library: its database rows and, unless another document uses them, its stored
    /// file and rendition. The folder selects the next document.
    func removeDocument(_ documentID: Document.ID) async {
        guard let database, classificationProgress?.documentID != documentID else { return }
        let name = row(documentID)?.name ?? "the document"
        let next = rowAfter(documentID)
        do {
            let unusedFiles = try await database.deleteDocument(documentID)
            await Self.deleteFiles(Set(unusedFiles), of: library)
        } catch {
            notify("Couldn't remove “\(name)”: \(error.localizedDescription)", isError: true)
            return
        }
        librarySize.setNeedsUpdate()
        if let folderID = rowsFolderID { selectedDocByFolder[folderID] = next }
        await reloadRows()
        notify("Removed “\(name)” from the library.", systemImage: "trash")
    }

    /// The row that takes a document's place in the loaded folder's default order when it leaves.
    private func rowAfter(_ documentID: Document.ID) -> Document.ID? {
        guard let position = rowIndex[documentID] else { return nil }
        let remaining = rows.filter { $0.id != documentID }
        return remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)].id
    }

    func isNameTaken(_ name: String, excluding id: DocumentFolder.ID?) -> Bool {
        folders.contains { $0.id != id && $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    // MARK: Import

    #if os(macOS)
    static let importTypes: [UTType] = [.pdf, .image] + DocumentRendition.textDocumentTypes.map(\.type)
    #else
    static let importTypes: [UTType] = [.pdf, .image]
    #endif

    /// Copies picked files into the library, adds them to the Unclassified inbox and selects the first one.
    func importFiles(_ urls: [URL]) async {
        var firstID: Document.ID?
        for url in urls {
            if let id = await importFile(at: url) { firstID = firstID ?? id }
        }
        guard let firstID else { return }
        selectedDocByFolder[DocumentFolder.inbox.id] = firstID
        if selectedFolderID == DocumentFolder.inbox.id {
            await reloadRows()
        } else {
            selectedFolderID = DocumentFolder.inbox.id   // reloads
        }
    }

    /// Stores one file and adds it to the inbox; returns its document ID.
    @discardableResult
    private func importFile(at url: URL, named name: String? = nil) async -> Document.ID? {
        guard let database, let stored = makeDocument(from: url, named: name) else { return nil }
        do {
            try await database.insert(stored.document, into: DocumentFolder.inbox.id,
                                      filePath: stored.filePath, renditionPath: stored.renditionPath)
        } catch {
            notify("Couldn't add “\(stored.document.name)”: \(error.localizedDescription)", isError: true)
            return nil
        }
        librarySize.setNeedsUpdate()
        return stored.document.id
    }

    /// Copies the file into the library (plus a PDF rendition for paged non-PDFs) and describes it. Paths are
    /// relative to the library root.
    private func makeDocument(from url: URL, named name: String? = nil)
        -> (document: Document, filePath: String, renditionPath: String?)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }

        let type = UTType(filenameExtension: url.pathExtension)
        let isPDF = type?.conforms(to: .pdf) ?? false
        let isImage = type?.conforms(to: .image) ?? false
        #if os(macOS)
        let textFormat = DocumentRendition.textDocumentFormat(for: type)
        let isText = textFormat != nil
        #else
        let isText = false
        #endif
        guard isPDF || isImage || isText else { return nil }
        guard let storedPath = try? library.store(data, pathExtension: url.pathExtension) else { return nil }

        // Anything with pages is shown as a PDF: the original if it is one, otherwise a stored rendition.
        var rendition: Data?
        #if os(macOS)
        if let textFormat { rendition = DocumentRendition.pdf(fromTextDocument: data, format: textFormat) }
        #endif
        if isImage { rendition = DocumentRendition.pdf(fromMultiPageImage: data, type: type) }

        var pages: Int? = 1
        var content = DocumentContent.file
        var renditionPath: String?
        if isPDF {
            pages = PDFDocument(data: data)?.pageCount
            content = .pdf(library.url(forStoredPath: storedPath))
        } else if let rendition, let path = try? library.store(rendition, pathExtension: "pdf", in: .renditions) {
            pages = PDFDocument(data: rendition)?.pageCount
            content = .pdf(library.url(forStoredPath: path))
            renditionPath = path
        } else if isImage, PlatformImage(data: data) != nil {
            content = .image(library.url(forStoredPath: storedPath))
        }

        let document = Document(
            name: name ?? url.lastPathComponent,
            kind: type?.localizedDescription ?? "Document",
            added: .now,
            sizeBytes: Int64(data.count),
            pages: pages,
            md5: Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            content: content
        )
        return (document, storedPath, renditionPath)
    }

    /// Files in `Files/` left by runs before the catalogue was saved. Runs once, right after the database is
    /// created: each file is imported into Unclassified as "Recovered <hash prefix>.<ext>" (which also recreates
    /// Word and TIFF renditions), then renditions that no document uses are deleted.
    private func recoverLeftoverFiles() async {
        guard let database, let stored = try? await database.storedPaths() else { return }
        let leftovers = await Self.storedFiles(in: .files, of: library).subtracting(stored)
        for path in leftovers.sorted() {
            let url = library.url(forStoredPath: path)
            let hash = url.deletingPathExtension().lastPathComponent
            let name = "Recovered \(hash.prefix(8))" + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")
            await importFile(at: url, named: name)
        }
        guard let used = try? await database.storedPaths() else { return }
        await Self.deleteFiles(Self.storedFiles(in: .renditions, of: library).subtracting(used), of: library)
        librarySize.setNeedsUpdate()
    }

    /// Library-relative paths of the files in one library folder.
    @concurrent
    private static func storedFiles(in folder: DocumentLibrary.Folder, of library: DocumentLibrary) async -> Set<String> {
        let directory = library.root.appending(path: folder.rawValue, directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return Set(names.filter { !$0.hasPrefix(".") }.map { "\(folder.rawValue)/\($0)" })
    }

    @concurrent
    private static func deleteFiles(_ paths: Set<String>, of library: DocumentLibrary) async {
        for path in paths { try? FileManager.default.removeItem(at: library.url(forStoredPath: path)) }
    }
}

// MARK: - AI classification

extension ClassifierStore {
    /// Why the AI Classify/Reclassify button is disabled, or nil when the on-device model is ready.
    var aiUnavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings to classify documents."
        case .unavailable(.modelNotReady): "The Apple Intelligence model is still downloading. Try again later."
        case .unavailable: "Apple Intelligence isn't available right now."
        }
    }

    /// Reads a document, matches it to a type and fills that type's fields; works for Unclassified documents
    /// (AI Classify) and classified ones (AI Reclassify). The document moves only if the outcome differs from its
    /// current folder. If no type fits, or too few of the best type's fields are in the document, opens the type
    /// sheet with a suggested new type.
    func classify(_ documentID: Document.ID) async {
        guard classificationProgress == nil, let doc = await document(documentID), classificationProgress == nil else { return }
        classificationProgress = ClassificationProgress(documentID: documentID, documentName: doc.name,
                                                        step: "Reading document…")
        defer { classificationProgress = nil }
        do {
            let text = try await DocumentReader.read(doc)
            classificationProgress?.step = "Classifying…"
            let types = typeFolders
            let match = try await classifier.classify(text, among: types)

            var reason = "“\(doc.name)” doesn't match any existing document type."
            var closest: (id: DocumentFolder.ID, values: [String: String])?
            if let type = types.first(where: { $0.id == match.typeID }) {
                classificationProgress?.step = "Extracting \(type.name) fields…"
                let values = try await classifier.extractValues(from: text, for: type)
                let coverage = type.fields.isEmpty ? 1 : Double(values.count) / Double(type.fields.count)
                if coverage >= DocumentClassifier.minimumFieldCoverage {
                    await fileAndReport(documentID, named: doc.name, into: type.id, values: values)
                    return
                }
                reason = "“\(doc.name)” looks like \(type.name), but only \(values.count) of its \(type.fields.count) fields are in the document."
                closest = (type.id, values)
            }

            classificationProgress?.step = "Suggesting a document type…"
            let proposal = try await classifier.proposeType(for: text, existing: types)
            editor = .suggest(TypeSuggestion(
                documentID: documentID, text: text, reason: reason,
                name: proposal.name, description: proposal.description,
                fields: proposal.fields.map { field in
                    var schemaField = SchemaField.newField()
                    schemaField.label = field.name
                    schemaField.type = field.type.fieldType
                    schemaField.description = field.description
                    return schemaField
                },
                closestTypeID: closest?.id, closestValues: closest?.values ?? [:]))
        } catch {
            notify("Couldn't classify “\(doc.name)”: \(error.localizedDescription)", isError: true)
        }
    }

    /// Files a document under the folder the user dropped it on, without classifying it: its previous values are
    /// discarded and the on-device model fills the new type's fields. Dropping on Unclassified just clears them.
    func assign(_ documentID: Document.ID, to typeID: DocumentFolder.ID) async {
        guard let sourceID = await folderID(containing: documentID), sourceID != typeID,
              let doc = await document(documentID), let target = folders.first(where: { $0.id == typeID }),
              await move(documentID, from: sourceID, into: typeID, values: [:]) else { return }
        guard !target.isInbox, !target.fields.isEmpty else {
            notify("Moved “\(doc.name)” to \(target.name).", showing: typeID, systemImage: "folder")
            return
        }
        if let reason = aiUnavailableReason {
            notify("Moved “\(doc.name)” to \(target.name), but its fields are empty. \(reason)",
                   showing: typeID, isError: true)
            return
        }

        // One model request at a time: wait for a classification already running.
        while classificationProgress != nil { try? await Task.sleep(for: .milliseconds(200)) }
        guard let type = folders.first(where: { $0.id == typeID }) else { return }
        classificationProgress = ClassificationProgress(documentID: documentID, documentName: doc.name,
                                                        step: "Filling \(type.name) fields…")
        defer { classificationProgress = nil }
        guard await folderID(containing: documentID) == typeID else { return }   // moved again meanwhile
        do {
            let text = try await DocumentReader.read(doc)
            let values = try await classifier.extractValues(from: text, for: type)
            // Saved only if the document is still there.
            guard let database, try await database.replaceValues(values, of: documentID, ifIn: typeID) else { return }
            librarySize.setNeedsUpdate()
            await reloadRows()
            notify("Moved “\(doc.name)” to \(type.name). Apple Intelligence filled \(values.count) of its \(type.fields.count) fields.",
                   showing: typeID)
        } catch {
            notify("Moved “\(doc.name)” to \(type.name), but couldn't fill its fields: \(error.localizedDescription)",
                   showing: typeID, isError: true)
        }
    }

    /// Creates the (possibly edited) suggested type and files the document under it.
    func acceptSuggestion(_ suggestion: TypeSuggestion, name: String, description: String, fields: [SchemaField]) async {
        guard let typeID = await createType(name: name, description: description, fields: fields, select: false) else { return }
        await extractAndFile(suggestion, into: typeID, createdType: true)
    }

    /// Files the document under an existing type the user picked instead of the suggestion, filling what it can.
    /// Picking the type the document is already in leaves it untouched.
    func forceClassify(_ suggestion: TypeSuggestion, into typeID: DocumentFolder.ID) async {
        let currentID = await folderID(containing: suggestion.documentID)
        if typeID == suggestion.closestTypeID || typeID == currentID {
            await fileAndReport(suggestion.documentID, named: suggestion.text.fileName, into: typeID,
                                values: suggestion.closestValues)
        } else {
            await extractAndFile(suggestion, into: typeID, createdType: false)
        }
    }

    private func extractAndFile(_ suggestion: TypeSuggestion, into typeID: DocumentFolder.ID, createdType: Bool) async {
        guard classificationProgress == nil, let type = folders.first(where: { $0.id == typeID }) else { return }
        classificationProgress = ClassificationProgress(documentID: suggestion.documentID,
                                                        documentName: suggestion.text.fileName,
                                                        step: "Extracting \(type.name) fields…")
        defer { classificationProgress = nil }
        do {
            let values = try await classifier.extractValues(from: suggestion.text, for: type)
            await fileAndReport(suggestion.documentID, named: suggestion.text.fileName, into: typeID, values: values,
                          createdType: createdType)
        } catch {
            notify("Couldn't extract \(type.name) fields: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: Filing

    /// A document by ID: from the loaded rows when it's there, otherwise from the database.
    private func document(_ id: Document.ID) async -> Document? {
        if let row = row(id) { return row }
        return try? await database?.document(id)
    }

    private func folderID(containing documentID: Document.ID) async -> DocumentFolder.ID? {
        try? await database?.folderID(containing: documentID)
    }

    /// Files the document under `typeID` (unless it's already there) and reports the outcome in the banner.
    private func fileAndReport(_ documentID: Document.ID, named name: String, into typeID: DocumentFolder.ID,
                               values: [String: String], createdType: Bool = false) async {
        guard let sourceID = await folderID(containing: documentID),
              let source = folders.first(where: { $0.id == sourceID }),
              let target = folders.first(where: { $0.id == typeID }) else { return }
        guard sourceID != typeID else {
            // Same outcome as before: keep the document and its values as they are.
            notify("“\(name)” is still classified as \(target.name).")
            return
        }
        guard await move(documentID, from: sourceID, into: typeID, values: values) else { return }
        let message = switch (source.isInbox, createdType) {
        case (true, false): "Classified “\(name)” as \(target.name)."
        case (true, true): "Created \(target.name) and classified “\(name)” as \(target.name)."
        case (false, false): "Reclassified “\(name)” from \(source.name) to \(target.name)."
        case (false, true): "Created \(target.name) and reclassified “\(name)” from \(source.name)."
        }
        notify(message, showing: typeID)
    }

    /// Moves a document between folders with new extracted values; returns false if saving failed. The source
    /// folder selects the next document.
    private func move(_ documentID: Document.ID, from sourceID: DocumentFolder.ID, into typeID: DocumentFolder.ID,
                      values: [String: String]) async -> Bool {
        guard let database else { return false }
        // The row after the moved one, in the source's default order (when it's the loaded folder).
        let next = rowsFolderID == sourceID ? rowAfter(documentID) : nil
        do {
            try await database.move(documentID, to: typeID, values: values)
        } catch {
            notify("Couldn't move the document: \(error.localizedDescription)", isError: true)
            return false
        }
        librarySize.setNeedsUpdate()
        selectedDocByFolder[typeID] = documentID
        selectedDocByFolder[sourceID] = next
        await reloadRows()
        return true
    }

    private func notify(_ message: String, showing folderID: DocumentFolder.ID? = nil,
                        systemImage: String = "apple.intelligence", isError: Bool = false) {
        classificationNotice = ClassificationNotice(message: message, folderID: folderID,
                                                    systemImage: systemImage, isError: isError)
    }
}

/// The classified document whose values are being edited.
struct ValueEditorTarget: Identifiable {
    let folderID: DocumentFolder.ID
    /// The document as it was when editing began.
    let document: Document

    var id: Document.ID { document.id }
}

struct ClassificationProgress: Equatable {
    let documentID: Document.ID
    let documentName: String
    var step: String
}

/// A short-lived banner reporting where a document was filed, why classification failed, or how a schema
/// change went.
struct ClassificationNotice: Identifiable {
    let id = UUID()
    var message: String
    var folderID: DocumentFolder.ID?
    var systemImage = "apple.intelligence"
    var isError = false
}

struct SchemaUpdateProgress: Equatable {
    let typeName: String
    let fieldNames: [String]
    var completed: Int
    let total: Int
}

/// A new document type proposed by the classifier, shown pre-filled in the type sheet.
struct TypeSuggestion: Identifiable {
    let id = UUID()
    let documentID: Document.ID
    /// Kept so accepting or forcing the classification doesn't read (or OCR) the document again.
    let text: DocumentText
    let reason: String
    var name: String
    var description: String
    var fields: [SchemaField]
    /// The best-matching existing type, offered first when classifying as an existing type.
    var closestTypeID: DocumentFolder.ID?
    var closestValues: [String: String]
}

enum TypeEditorMode: Identifiable {
    case create
    case edit(DocumentFolder.ID)
    case suggest(TypeSuggestion)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let id): "edit-" + id
        case .suggest(let suggestion): "suggest-" + suggestion.id.uuidString
        }
    }
}

#if canImport(AppKit)
typealias PlatformImage = NSImage
extension NSImage {
    convenience init(cgImage: CGImage) { self.init(cgImage: cgImage, size: .zero) }
    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}
extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#else
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#endif
