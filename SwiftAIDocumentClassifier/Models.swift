import SwiftUI

// MARK: - Schema

nonisolated enum FieldType: String, CaseIterable, Identifiable {
    case string, date, timestamp, integer, decimal

    var id: Self { self }

    var label: String {
        switch self {
        case .string: "Text"
        case .date: "Date"
        case .timestamp: "Timestamp"
        case .integer: "Integer"
        case .decimal: "Decimal (2dp)"
        }
    }

    var isNumeric: Bool { self == .integer || self == .decimal }

    /// Default column width for a newly defined field of this type.
    var defaultWidth: CGFloat {
        switch self {
        case .timestamp: 180
        case .date: 130
        case .integer, .decimal: 120
        case .string: 170
        }
    }
}

nonisolated extension FieldType {
    /// Converts a stored value to this type's stored format, or nil if it can't be read as this type.
    /// Used when a field's data type changes; values that return nil are discarded.
    func convertedValue(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch self {
        case .string:
            return text
        case .date:
            return DateFormatter.documentTimestamp(from: text).map(DateFormatter.documentDay.string(from:))
        case .timestamp:
            return DateFormatter.documentTimestamp(from: text).map(DateFormatter.documentStamp.string(from:))
        case .integer, .decimal:
            guard let number = Self.singleNumber(in: text) else { return nil }
            let style = FloatingPointFormatStyle<Double>.number.locale(Locale(identifier: "en_US"))
            return self == .integer
                ? number.rounded().formatted(style.precision(.fractionLength(0)))
                : number.formatted(style.precision(.fractionLength(2)))
        }
    }

    /// The sort keys stored with a value in `field_value`, computed by every write: dates and timestamps as epoch
    /// seconds, numbers as their value, text (case-insensitively) as itself. Values that don't parse as their type
    /// get no keys and sort with the empty ones.
    func sortKeys(for display: String) -> (number: Double?, text: String?) {
        switch self {
        case .string: (nil, display)
        case .date: (DateFormatter.documentDate(from: display)?.timeIntervalSince1970, nil)
        case .timestamp: (DateFormatter.documentTimestamp(from: display)?.timeIntervalSince1970, nil)
        case .integer, .decimal: (Double(display.replacing(",", with: "")), nil)
        }
    }

    /// Characters a number field accepts while typing.
    static let numberInputCharacters = Set("0123456789.,-")

    /// Validates what a user typed into a number field and returns it in stored form ("1500" → "1,500.00"), or nil
    /// if it isn't a plain number: digits with optional thousands commas, decimals and a leading minus. Integer
    /// fields reject fractions instead of rounding them.
    func numberFromInput(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard isNumeric, text.wholeMatch(of: #/-?[\d,]+(\.\d+)?/#) != nil else { return nil }
        if self == .integer, let dot = text.firstIndex(of: "."),
           text[text.index(after: dot)...].contains(where: { $0 != "0" }) { return nil }
        return convertedValue(text)
    }

    /// The value of a text that contains exactly one number, allowing currency symbols, thousands separators and
    /// words around it ("$1,248.50", "2,650 / mo"). Texts with several numbers, like dates, return nil.
    private static func singleNumber(in text: String) -> Double? {
        let ungrouped = text.replacing(#/(\d),(?=\d{3})/#) { String($0.output.1) }
        let matches = ungrouped.matches(of: #/\d+(\.\d+)?/#)
        guard matches.count == 1, let match = matches.first, var number = Double(match.output.0) else { return nil }
        // A minus sign counts only when nothing but currency symbols and spaces precede it ("-$5", "$-5").
        let prefix = ungrouped[..<match.range.lowerBound].filter { !$0.isWhitespace }
        if prefix.contains("-"), !prefix.contains(where: { $0.isLetter || $0.isNumber }) { number.negate() }
        return number
    }
}

/// One extracted field of a document type, shown as a table column.
nonisolated struct SchemaField: Identifiable, Hashable {
    var key: String
    var label: String
    var type: FieldType = .string
    var width: CGFloat? = nil
    var description: String = ""

    var id: String { key }
    var columnWidth: CGFloat { width ?? type.defaultWidth }

    static func newField() -> SchemaField {
        SchemaField(key: "c_" + UUID().uuidString.prefix(8).lowercased(), label: "")
    }
}

// MARK: - Documents

/// What the preview pane renders for a document.
nonisolated enum DocumentContent {
    case printed(PrintedPage)
    /// A PDF stored in the library.
    case pdf(URL)
    /// An image stored in the library, decoded only when it's shown or read.
    case image(URL)
    case file
}

/// A stand-in rendering of a scanned page (invoice, letter, receipt…).
/// Stored as JSON in the database (`document.sample_page`).
nonisolated struct PrintedPage: Codable {
    enum Style: String, Codable { case invoice, quote, letter, contract, receipt }

    var style: Style
    var from: String
    var date: String
    var to: String? = nil
    var amount: String? = nil
    var subject: String? = nil
    var paragraph: String? = nil
    var lines: [String] = []
}

nonisolated struct Document: Identifiable {
    /// Stable across launches: stored in the database as text.
    var id = UUID()
    var name: String
    var kind: String
    var added: Date
    var sizeBytes: Int64
    var pages: Int?
    var md5: String?
    /// Extracted values keyed by `SchemaField.key`.
    var values: [String: String] = [:]
    var content: DocumentContent

    var isImage: Bool { kind.localizedCaseInsensitiveContains("image") }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
    var formattedAdded: String { DateFormatter.documentStamp.string(from: added) }

    /// Display value for a column. Keys prefixed with `_` (plus `pages`/`md5`) are file metadata.
    subscript(key: String) -> String? {
        switch key {
        case MetaKey.name: name
        case MetaKey.kind: kind
        case MetaKey.added: formattedAdded
        case MetaKey.size: formattedSize
        case MetaKey.pages: pages.map(String.init)
        case MetaKey.md5: md5
        default: values[key]
        }
    }
}

/// What a table row carries when dragged onto a sidebar folder: just the document's ID.
/// Sent as tagged text, so drags within the app need no custom type declared in Info.plist.
nonisolated struct DocumentDragItem: Transferable, Sendable {
    let documentID: UUID

    private static let prefix = "swiftaidocumentclassifier-document:"

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { (item: DocumentDragItem) in
            prefix + item.documentID.uuidString
        } importing: { (text: String) in
            guard text.hasPrefix(prefix), let id = UUID(uuidString: String(text.dropFirst(prefix.count))) else {
                throw CocoaError(.coderInvalidValue)
            }
            return DocumentDragItem(documentID: id)
        }
    }
}

nonisolated enum MetaKey {
    static let name = "_name"
    static let kind = "_kind"
    static let added = "_added"
    static let size = "_size"
    static let pages = "pages"
    static let md5 = "md5"
}

// MARK: - Folders

/// The inbox or a document type. Documents aren't held here: they live in the database, and `ClassifierStore`
/// loads only the selected folder's rows.
nonisolated struct DocumentFolder: Identifiable {
    var id: String
    var name: String
    /// What documents of this type are; the classifier matches documents against it.
    var description = ""
    /// The Unclassified inbox: shows file facts instead of extracted fields and can't be edited.
    var isInbox = false
    var fields: [SchemaField]

    /// The Unclassified inbox is not a database type: its documents have no type (`type_id IS NULL`), and its
    /// columns are file metadata.
    static let inbox = DocumentFolder(id: "inbox", name: "Unclassified", isInbox: true, fields: SampleData.inboxFields)
}

nonisolated extension DateFormatter {
    /// Reads the date spellings found in documents and model answers ("28 Jun 2024", "June 28, 2024",
    /// "2024-06-28", "28/06/2024"). Day-first for numeric dates, as in the sample (Australian) documents.
    static func documentDate(from text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return documentDateParsers.lazy.compactMap { $0.date(from: text) }.first
    }

    /// Reads a timestamp as stored by `documentStamp`, falling back to a plain date.
    static func documentTimestamp(from text: String) -> Date? {
        documentStamp.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? documentDate(from: text)
    }

    private static let documentDateParsers: [DateFormatter] =
        ["d MMM yyyy", "d MMMM yyyy", "MMM d, yyyy", "MMMM d, yyyy", "yyyy-MM-dd", "d/M/yyyy", "d.M.yyyy"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f
        }

    /// Formats and parses dates as stored in the table, e.g. "28 Jun 2024".
    static let documentDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// When a file was added, e.g. "14 Jun 2024, 9:31 am".
    static let documentStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy, h:mm a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()
}
