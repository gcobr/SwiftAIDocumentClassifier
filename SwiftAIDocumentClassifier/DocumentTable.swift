import SwiftUI

struct DocumentTable: View {
    let folder: DocumentFolder
    let docs: [Document]
    @Binding var selection: Document.ID?
    @Binding var sortOrder: [DocumentComparator]

    private static let nameField = SchemaField(key: MetaKey.name, label: "Name", width: 260)

    var body: some View {
        Table(of: Document.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: DocumentComparator(field: Self.nameField)) { doc in
                Label {
                    Text(doc.name).truncationMode(.middle)
                } icon: {
                    Image(systemName: doc.isImage ? "photo" : "doc.text")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: Self.nameField.columnWidth)

            TableColumnForEach(folder.fields) { field in
                TableColumn(field.label, sortUsing: DocumentComparator(field: field)) { doc in
                    cell(field, doc)
                }
                .width(min: 50, ideal: field.columnWidth)
                .alignment(field.type.isNumeric ? .numeric : .leading)
            }
        } rows: {
            // Rows can be dragged onto a sidebar folder to file the document there.
            ForEach(docs) { doc in
                TableRow(doc).draggable(DocumentDragItem(documentID: doc.id))
            }
        }
        #if os(macOS)
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        #endif
    }

    @ViewBuilder
    private func cell(_ field: SchemaField, _ doc: Document) -> some View {
        let text = Text(doc[field.key] ?? "—").foregroundStyle(.secondary)
        if field.key == MetaKey.md5 {
            text.font(.system(.caption, design: .monospaced))
        } else if field.type.isNumeric {
            text.monospacedDigit()
        } else {
            text
        }
    }
}

/// The table's sort descriptor for one column. Rows are sorted in the database (`sort`), by typed sort keys;
/// `compare` only satisfies `SortComparator`.
struct DocumentComparator: SortComparator, Hashable {
    let key: String
    let type: FieldType
    var order: SortOrder = .forward

    init(field: SchemaField) {
        key = field.key
        type = field.type
    }

    var sort: DocumentSort { DocumentSort(key: key, type: type, ascending: order == .forward) }

    func compare(_ lhs: Document, _ rhs: Document) -> ComparisonResult {
        let result = (lhs[key] ?? "").localizedStandardCompare(rhs[key] ?? "")
        guard order == .reverse else { return result }
        return switch result {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}
