import Foundation
import GRDB

/// The catalogue, stored in SQLite at `DocumentLibrary.root/library.sqlite`: document types and their fields,
/// documents, extracted values (with typed sort keys) and an FTS5 trigram search index. Every read and write goes
/// through GRDB's async API, which runs it on the database's own queue, never on the main actor.
///
/// The Unclassified inbox isn't a `document_type` row: its documents have `type_id IS NULL`. Callers use folder IDs
/// throughout, and `"inbox"` is translated only here.
nonisolated final class LibraryDatabase: Sendable {
    let library: DocumentLibrary
    private let writer: any DatabaseWriter

    static let fileName = "library.sqlite"

    private init(library: DocumentLibrary, writer: any DatabaseWriter) {
        self.library = library
        self.writer = writer
    }

    /// Opens the library's database, creating it and seeding the sample data on first launch. `created` is true
    /// when this call created it, which is when files from runs before persistence are recovered. Blocking.
    @concurrent
    static func open(_ library: DocumentLibrary) async throws -> (database: LibraryDatabase, created: Bool) {
        try FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
        let path = library.root.appending(path: fileName).path(percentEncoded: false)
        let pool = try DatabasePool(path: path)   // WAL mode
        let created = try await pool.read { db in try migrator.appliedMigrations(db).isEmpty }
        try migrator.migrate(pool)
        return (LibraryDatabase(library: library, writer: pool), created)
    }

    /// A seeded in-memory database for SwiftUI previews.
    static func inMemory(library: DocumentLibrary) throws -> LibraryDatabase {
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        return LibraryDatabase(library: library, writer: queue)
    }

    // MARK: Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try createTables(db)
            try seedSamples(db)
        }
        return migrator
    }

    /// `schema_field` is keyed by type and key because keys repeat across types (several sample types have a
    /// "vendor" or "amount" field), so `field_value` can't reference it; values of removed fields are deleted by
    /// `saveType`. `document.seq` gives each document a stable integer rowid for its `search` row.
    private static func createTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE document_type (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                position INTEGER NOT NULL
            );
            CREATE TABLE schema_field (
                type_id TEXT NOT NULL REFERENCES document_type(id) ON DELETE CASCADE,
                key TEXT NOT NULL,
                label TEXT NOT NULL,
                data_type TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                width REAL,
                position INTEGER NOT NULL,
                PRIMARY KEY (type_id, key)
            );
            CREATE TABLE document (
                seq INTEGER PRIMARY KEY,
                id TEXT NOT NULL UNIQUE,
                type_id TEXT REFERENCES document_type(id) ON DELETE SET NULL,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                added_at REAL NOT NULL,
                size_bytes INTEGER NOT NULL,
                pages INTEGER,
                md5 TEXT,
                content_kind TEXT NOT NULL,
                file_path TEXT,
                rendition_path TEXT,
                sample_page TEXT,
                is_sample INTEGER NOT NULL DEFAULT 0,
                suggested_type_id TEXT,
                confidence TEXT
            );
            CREATE INDEX document_type_added ON document(type_id, added_at);
            CREATE TABLE field_value (
                doc_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                field_key TEXT NOT NULL,
                display TEXT NOT NULL,
                sort_num REAL,
                sort_text TEXT COLLATE NOCASE,
                PRIMARY KEY (doc_id, field_key)
            ) WITHOUT ROWID;
            CREATE INDEX field_value_num ON field_value(field_key, sort_num);
            CREATE INDEX field_value_text ON field_value(field_key, sort_text);
            CREATE TABLE document_text (
                doc_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                source TEXT NOT NULL,
                text TEXT NOT NULL,
                PRIMARY KEY (doc_id, source)
            );
            CREATE VIRTUAL TABLE search USING fts5(
                body, content='', contentless_delete=1, tokenize='trigram remove_diacritics 1'
            );
            CREATE TRIGGER document_search_delete AFTER DELETE ON document BEGIN
                DELETE FROM search WHERE rowid = old.seq;
            END;
            """)
    }

    /// Writes `SampleData` into the new database. Runs only in the first migration, so it never reseeds.
    private static func seedSamples(_ db: Database) throws {
        for seed in SampleData.folders() {
            if !seed.folder.isInbox { try saveType(db, seed.folder) }
            for doc in seed.docs {
                try insert(db, doc, into: seed.folder.id, filePath: nil, renditionPath: nil, isSample: true)
            }
        }
    }

    // MARK: Reads

    /// Document types in sidebar order, with their fields.
    func types() async throws -> [DocumentFolder] {
        try await writer.read { db in try Self.types(db) }
    }

    /// Number of documents per folder, including the inbox.
    func documentCounts() async throws -> [DocumentFolder.ID: Int] {
        try await writer.read { db in try Self.documentCounts(db) }
    }

    /// A folder's documents with their values, newest first.
    func documents(in folderID: DocumentFolder.ID) async throws -> [Document] {
        try await writer.read { [library] db in try Self.documents(db, in: folderID, library: library) }
    }

    func document(_ id: Document.ID) async throws -> Document? {
        try await writer.read { [library] db in
            guard let record = try DocumentRecord.fetchOne(db, sql: "SELECT * FROM document WHERE id = ?",
                                                           arguments: [id.uuidString]) else { return nil }
            let values = try FieldValueRecord.fetchAll(db, sql: "SELECT * FROM field_value WHERE doc_id = ?",
                                                       arguments: [record.id])
            return Self.document(record, values: Dictionary(uniqueKeysWithValues: values.map { ($0.fieldKey, $0.display) }),
                                 library: library)
        }
    }

    /// The folder a document is in, or nil if there is no such document.
    func folderID(containing id: Document.ID) async throws -> DocumentFolder.ID? {
        try await writer.read { db in
            try Row.fetchOne(db, sql: "SELECT type_id FROM document WHERE id = ?", arguments: [id.uuidString])
                .map { Self.folderID(forTypeID: $0["type_id"]) }
        }
    }

    /// IDs of a folder's documents that match `search`, in `sort` order (newest first without one). Searches of
    /// three or more characters use the trigram index, so they match anywhere inside words; shorter ones fall back
    /// to `LIKE` on the name and values.
    func documentIDs(in folderID: DocumentFolder.ID, matching search: String, sortedBy sort: DocumentSort?) async throws -> [Document.ID] {
        try await writer.read { db in
            var sql = "SELECT d.id FROM document d"
            var arguments: StatementArguments = []
            var order = "d.added_at DESC, d.seq DESC"
            if let sort {
                let direction = sort.ascending ? "ASC" : "DESC"
                let column: String
                if let meta = Self.metaColumns[sort.key] {
                    column = meta
                } else {
                    sql += " LEFT JOIN field_value v ON v.doc_id = d.id AND v.field_key = ?"
                    arguments += [sort.key]
                    column = sort.type == .string ? "v.sort_text" : "v.sort_num"
                }
                order = "\(column) IS NULL, \(column) \(direction), d.name COLLATE NOCASE, d.seq"
            }
            sql += " WHERE d.type_id IS ?"
            arguments += [Self.typeID(forFolderID: folderID)]
            if search.count >= 3 {
                // A quoted FTS5 phrase: the whole query, matched as a substring by the trigram tokenizer.
                sql += " AND d.seq IN (SELECT rowid FROM search WHERE search MATCH ?)"
                arguments += ["\"" + search.replacing("\"", with: "\"\"") + "\""]
            } else if !search.isEmpty {
                let pattern = "%" + search.replacing(#/[\\%_]/#) { "\\" + $0.output } + "%"
                sql += """
                     AND (d.name LIKE ? ESCAPE '\\'
                          OR EXISTS (SELECT 1 FROM field_value s WHERE s.doc_id = d.id AND s.display LIKE ? ESCAPE '\\'))
                    """
                arguments += [pattern, pattern]
            }
            sql += " ORDER BY " + order
            return try String.fetchAll(db, sql: sql, arguments: arguments).compactMap(UUID.init(uuidString:))
        }
    }

    /// Documents of a type that have a value for any of `keys`.
    func documentIDs(in typeID: DocumentFolder.ID, withValuesFor keys: Set<String>) async throws -> [Document.ID] {
        guard !keys.isEmpty else { return [] }
        return try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT v.doc_id FROM field_value v JOIN document d ON d.id = v.doc_id
                WHERE d.type_id = ? AND v.field_key IN (\(databaseQuestionMarks(count: keys.count)))
                """, arguments: StatementArguments([typeID] + Array(keys)))
            .compactMap(UUID.init(uuidString:))
        }
    }

    func documentCount(in typeID: DocumentFolder.ID, withValuesFor keys: Set<String>) async throws -> Int {
        guard !keys.isEmpty else { return 0 }
        return try await writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT v.doc_id) FROM field_value v JOIN document d ON d.id = v.doc_id
                WHERE d.type_id = ? AND v.field_key IN (\(databaseQuestionMarks(count: keys.count)))
                """, arguments: StatementArguments([typeID] + Array(keys))) ?? 0
        }
    }

    /// Library-relative paths of every original and rendition a document uses.
    func storedPaths() async throws -> Set<String> {
        try await writer.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT file_path FROM document WHERE file_path IS NOT NULL
                UNION SELECT rendition_path FROM document WHERE rendition_path IS NOT NULL
                """))
        }
    }

    // MARK: Writes

    /// Adds a document. `filePath` and `renditionPath` are relative to the library root.
    func insert(_ document: Document, into folderID: DocumentFolder.ID, filePath: String?, renditionPath: String?) async throws {
        try await writer.write { db in
            try Self.insert(db, document, into: folderID, filePath: filePath, renditionPath: renditionPath, isSample: false)
        }
    }

    /// Moves a document to another folder, replacing its values.
    func move(_ id: Document.ID, to folderID: DocumentFolder.ID, values: [String: String]) async throws {
        try await writer.write { db in
            let typeID = Self.typeID(forFolderID: folderID)
            try db.execute(sql: "UPDATE document SET type_id = ? WHERE id = ?", arguments: [typeID, id.uuidString])
            try Self.writeValues(db, values, of: id.uuidString, typeID: typeID)
        }
    }

    /// Replaces a document's values. With `expectedFolderID`, does nothing (and returns false) if the document has
    /// been moved elsewhere meanwhile.
    @discardableResult
    func replaceValues(_ values: [String: String], of id: Document.ID,
                       ifIn expectedFolderID: DocumentFolder.ID? = nil) async throws -> Bool {
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT type_id FROM document WHERE id = ?",
                                             arguments: [id.uuidString]) else { return false }
            let typeID: String? = row["type_id"]
            if let expectedFolderID, Self.typeID(forFolderID: expectedFolderID) != typeID { return false }
            try Self.writeValues(db, values, of: id.uuidString, typeID: typeID)
            return true
        }
    }

    /// Deletes a document with its values, text and search row (by cascade and trigger). Returns the library paths
    /// of its original and rendition that no other document uses, for the caller to delete; identical files are
    /// stored once, so another import of the same file may still need them.
    func deleteDocument(_ id: Document.ID) async throws -> [String] {
        try await writer.write { db in
            guard let record = try DocumentRecord.fetchOne(db, sql: "SELECT * FROM document WHERE id = ?",
                                                           arguments: [id.uuidString]) else { return [] }
            try db.execute(sql: "DELETE FROM document WHERE id = ?", arguments: [record.id])
            return try [record.filePath, record.renditionPath].compactMap { $0 }.filter { path in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document WHERE file_path = ? OR rendition_path = ?",
                                 arguments: [path, path]) == 0
            }
        }
    }

    /// Creates or updates a type and its fields; values of `removedKeys` are deleted from the type's documents.
    func saveType(_ folder: DocumentFolder, removing removedKeys: Set<String> = []) async throws {
        try await writer.write { db in try Self.saveType(db, folder, removing: removedKeys) }
    }

    /// Converts the values of `fields` (key → new data type) in the given documents of a type, in one transaction.
    /// Documents that have left the type meanwhile are skipped. Values that can't be converted are removed.
    func convertValues(of fields: [String: FieldType], in documentIDs: [Document.ID],
                       typeID: DocumentFolder.ID) async throws -> (converted: Int, discarded: Int) {
        guard !fields.isEmpty, !documentIDs.isEmpty else { return (0, 0) }
        return try await writer.write { db in
            let keys = Array(fields.keys)
            let ids = documentIDs.map(\.uuidString)
            let values = try FieldValueRecord.fetchAll(db, sql: """
                SELECT v.* FROM field_value v JOIN document d ON d.id = v.doc_id
                WHERE d.type_id = ? AND v.field_key IN (\(databaseQuestionMarks(count: keys.count)))
                AND v.doc_id IN (\(databaseQuestionMarks(count: ids.count)))
                """, arguments: StatementArguments([typeID] + keys + ids))
            var converted = 0, discarded = 0
            for var value in values {
                guard let type = fields[value.fieldKey] else { continue }
                if let display = type.convertedValue(value.display) {
                    value.display = display
                    (value.sortNum, value.sortText) = type.sortKeys(for: display)
                    try value.update(db)
                    converted += 1
                } else {
                    try value.delete(db)
                    discarded += 1
                }
            }
            for id in Set(values.map(\.docId)) { try Self.rewriteSearchRow(db, documentID: id) }
            return (converted, discarded)
        }
    }

    // MARK: Previews

    /// Types, counts and one folder's rows, read synchronously so previews render immediately. Previews only:
    /// the app never reads the database on the main actor.
    func previewSnapshot(of folderID: DocumentFolder.ID) throws
        -> (types: [DocumentFolder], counts: [DocumentFolder.ID: Int], rows: [Document]) {
        try writer.read { [library] db in
            (try Self.types(db), try Self.documentCounts(db), try Self.documents(db, in: folderID, library: library))
        }
    }
}

// MARK: - Queries and writes in a transaction

nonisolated private extension LibraryDatabase {
    static func typeID(forFolderID folderID: DocumentFolder.ID) -> String? {
        folderID == DocumentFolder.inbox.id ? nil : folderID
    }

    static func folderID(forTypeID typeID: String?) -> DocumentFolder.ID {
        typeID ?? DocumentFolder.inbox.id
    }

    /// Inbox columns (`MetaKey`) sort by `document` columns.
    static let metaColumns = [
        MetaKey.name: "d.name COLLATE NOCASE",
        MetaKey.kind: "d.kind COLLATE NOCASE",
        MetaKey.added: "d.added_at",
        MetaKey.size: "d.size_bytes",
        MetaKey.pages: "d.pages",
        MetaKey.md5: "d.md5",
    ]

    static func types(_ db: Database) throws -> [DocumentFolder] {
        let fields = Dictionary(grouping: try SchemaFieldRecord.fetchAll(db, sql: "SELECT * FROM schema_field ORDER BY position"),
                                by: \.typeId)
        return try DocumentTypeRecord.fetchAll(db, sql: "SELECT * FROM document_type ORDER BY position").map { type in
            DocumentFolder(id: type.id, name: type.name, description: type.description,
                           fields: (fields[type.id] ?? []).map(\.schemaField))
        }
    }

    static func documentCounts(_ db: Database) throws -> [DocumentFolder.ID: Int] {
        var counts: [DocumentFolder.ID: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT type_id, COUNT(*) AS n FROM document GROUP BY type_id") {
            counts[folderID(forTypeID: row["type_id"])] = row["n"]
        }
        return counts
    }

    static func documents(_ db: Database, in folderID: DocumentFolder.ID, library: DocumentLibrary) throws -> [Document] {
        let typeID = typeID(forFolderID: folderID)
        var values: [String: [String: String]] = [:]
        let rows = try Row.fetchCursor(db, sql: """
            SELECT v.doc_id, v.field_key, v.display FROM field_value v JOIN document d ON d.id = v.doc_id
            WHERE d.type_id IS ?
            """, arguments: [typeID])
        while let row = try rows.next() {
            values[row[0], default: [:]][row[1]] = row[2]
        }
        return try DocumentRecord.fetchAll(db, sql: "SELECT * FROM document WHERE type_id IS ? ORDER BY added_at DESC, seq DESC",
                                           arguments: [typeID])
            .compactMap { document($0, values: values[$0.id] ?? [:], library: library) }
    }

    static func document(_ record: DocumentRecord, values: [String: String], library: DocumentLibrary) -> Document? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        let content: DocumentContent = switch ContentKind(rawValue: record.contentKind) {
        case .pdf: (record.renditionPath ?? record.filePath).map { .pdf(library.url(forStoredPath: $0)) } ?? .file
        case .image: record.filePath.map { .image(library.url(forStoredPath: $0)) } ?? .file
        case .sample: record.samplePage.map { .printed($0) } ?? .file
        case .file, nil: .file
        }
        return Document(id: id, name: record.name, kind: record.kind, added: Date(timeIntervalSince1970: record.addedAt),
                        sizeBytes: record.sizeBytes, pages: record.pages, md5: record.md5, values: values, content: content)
    }

    static func insert(_ db: Database, _ document: Document, into folderID: DocumentFolder.ID,
                       filePath: String?, renditionPath: String?, isSample: Bool) throws {
        let typeID = typeID(forFolderID: folderID)
        var samplePage: PrintedPage?
        let kind: ContentKind
        switch document.content {
        case .pdf: kind = .pdf
        case .image: kind = .image
        case .file: kind = .file
        case .printed(let page):
            kind = .sample
            samplePage = page
        }
        try DocumentRecord(
            id: document.id.uuidString, typeId: typeID, name: document.name, kind: document.kind,
            addedAt: document.added.timeIntervalSince1970, sizeBytes: document.sizeBytes, pages: document.pages,
            md5: document.md5, contentKind: kind.rawValue, filePath: filePath, renditionPath: renditionPath,
            samplePage: samplePage, isSample: isSample
        ).insert(db)
        try writeValues(db, document.values, of: document.id.uuidString, typeID: typeID)
    }

    /// Replaces a document's values, with sort keys for each field's data type, and rewrites its search row.
    static func writeValues(_ db: Database, _ values: [String: String], of documentID: String, typeID: String?) throws {
        try db.execute(sql: "DELETE FROM field_value WHERE doc_id = ?", arguments: [documentID])
        if !values.isEmpty {
            var types: [String: FieldType] = [:]
            for field in try SchemaFieldRecord.fetchAll(db, sql: "SELECT * FROM schema_field WHERE type_id IS ?",
                                                        arguments: [typeID]) {
                types[field.key] = FieldType(rawValue: field.dataType)
            }
            for (key, display) in values {
                let (number, text) = (types[key] ?? .string).sortKeys(for: display)
                try FieldValueRecord(docId: documentID, fieldKey: key, display: display, sortNum: number, sortText: text)
                    .insert(db)
            }
        }
        try rewriteSearchRow(db, documentID: documentID)
    }

    /// The search row holds the name and every value; it's rewritten in the same transaction as any change to them.
    static func rewriteSearchRow(_ db: Database, documentID: String) throws {
        guard let row = try Row.fetchOne(db.cachedStatement(sql: "SELECT seq, name FROM document WHERE id = ?"),
                                         arguments: [documentID]) else { return }
        let seq: Int64 = row["seq"]
        let values = try String.fetchAll(db.cachedStatement(sql: "SELECT display FROM field_value WHERE doc_id = ?"),
                                         arguments: [documentID])
        try db.cachedStatement(sql: "DELETE FROM search WHERE rowid = ?").execute(arguments: [seq])
        try db.cachedStatement(sql: "INSERT INTO search(rowid, body) VALUES (?, ?)")
            .execute(arguments: [seq, ([row["name"] as String] + values).joined(separator: "\n")])
    }

    static func saveType(_ db: Database, _ folder: DocumentFolder, removing removedKeys: Set<String> = []) throws {
        let position = try Int.fetchOne(db, sql: "SELECT position FROM document_type WHERE id = ?", arguments: [folder.id])
            ?? Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position) + 1, 0) FROM document_type") ?? 0
        // `save` updates in place (no delete), so the type's documents keep pointing at it.
        try DocumentTypeRecord(id: folder.id, name: folder.name, description: folder.description, position: position).save(db)
        try db.execute(sql: "DELETE FROM schema_field WHERE type_id = ?", arguments: [folder.id])
        for (index, field) in folder.fields.enumerated() {
            try SchemaFieldRecord(field, typeID: folder.id, position: index).insert(db)
        }

        guard !removedKeys.isEmpty else { return }
        let keys = Array(removedKeys)
        let filter = """
            FROM field_value WHERE field_key IN (\(databaseQuestionMarks(count: keys.count)))
            AND doc_id IN (SELECT id FROM document WHERE type_id = ?)
            """
        let arguments = StatementArguments(keys + [folder.id])
        let affected = try String.fetchAll(db, sql: "SELECT DISTINCT doc_id " + filter, arguments: arguments)
        try db.execute(sql: "DELETE " + filter, arguments: arguments)
        for id in affected { try rewriteSearchRow(db, documentID: id) }
    }
}

/// How a table is sorted: one column (a `MetaKey` or a field key) and a direction.
nonisolated struct DocumentSort: Hashable, Sendable {
    var key: String
    var type: FieldType
    var ascending: Bool
}

// MARK: - Records

nonisolated private enum ContentKind: String {
    case pdf, image, file, sample
}

nonisolated private struct DocumentTypeRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "document_type"

    var id: String
    var name: String
    var description: String
    var position: Int
}

nonisolated private struct SchemaFieldRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "schema_field"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var typeId: String
    var key: String
    var label: String
    var dataType: String
    var description: String
    var width: Double?
    var position: Int

    init(_ field: SchemaField, typeID: String, position: Int) {
        typeId = typeID
        key = field.key
        label = field.label
        dataType = field.type.rawValue
        description = field.description
        width = field.width.map(Double.init)
        self.position = position
    }

    var schemaField: SchemaField {
        SchemaField(key: key, label: label, type: FieldType(rawValue: dataType) ?? .string,
                    width: width.map { CGFloat($0) }, description: description)
    }
}

nonisolated private struct DocumentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "document"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    /// Assigned by SQLite on insert.
    var seq: Int64?
    var id: String
    var typeId: String?
    var name: String
    var kind: String
    /// Seconds since 1970.
    var addedAt: Double
    var sizeBytes: Int64
    var pages: Int?
    var md5: String?
    var contentKind: String
    var filePath: String?
    var renditionPath: String?
    /// Stored as JSON text.
    var samplePage: PrintedPage?
    var isSample: Bool
    var suggestedTypeId: String?
    var confidence: String?

    init(id: String, typeId: String?, name: String, kind: String, addedAt: Double, sizeBytes: Int64, pages: Int?,
         md5: String?, contentKind: String, filePath: String?, renditionPath: String?, samplePage: PrintedPage?,
         isSample: Bool) {
        self.id = id
        self.typeId = typeId
        self.name = name
        self.kind = kind
        self.addedAt = addedAt
        self.sizeBytes = sizeBytes
        self.pages = pages
        self.md5 = md5
        self.contentKind = contentKind
        self.filePath = filePath
        self.renditionPath = renditionPath
        self.samplePage = samplePage
        self.isSample = isSample
    }

    /// Decodes columns directly: about three times faster than `Decodable` when a folder loads thousands of rows.
    init(row: Row) throws {
        seq = row["seq"]
        id = row["id"]
        typeId = row["type_id"]
        name = row["name"]
        kind = row["kind"]
        addedAt = row["added_at"]
        sizeBytes = row["size_bytes"]
        pages = row["pages"]
        md5 = row["md5"]
        contentKind = row["content_kind"]
        filePath = row["file_path"]
        renditionPath = row["rendition_path"]
        samplePage = (row["sample_page"] as String?).flatMap { try? JSONDecoder().decode(PrintedPage.self, from: Data($0.utf8)) }
        isSample = row["is_sample"]
        suggestedTypeId = row["suggested_type_id"]
        confidence = row["confidence"]
    }
}

nonisolated private struct FieldValueRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "field_value"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var docId: String
    var fieldKey: String
    var display: String
    var sortNum: Double?
    var sortText: String?
}
