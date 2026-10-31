import SwiftUI

/// Edits the extracted values of a classified document, one row per schema field with its description as guidance.
struct FieldValuesSheet: View {
    let store: ClassifierStore
    let target: ValueEditorTarget

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var original: [String: String] = [:]

    private var folder: DocumentFolder? { store.folders.first { $0.id == target.folderID } }
    private var doc: Document { target.document }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Edit Values").font(.headline)
                Text("Correct the values extracted from “\(doc.name)” (\(folder?.name ?? "")). Leave a field empty if the document doesn't contain it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 12)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(folder?.fields ?? []) { field in
                        FieldValueRow(field: field, value: binding(for: field),
                                      isInvalid: invalidKeys.contains(field.key))
                        if field.id != folder?.fields.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 22)
            }
            Divider()

            HStack {
                Spacer()
                Button("Discard", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!invalidKeys.isEmpty || cleaned(values) == original)
            }
            .padding(22)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 320, idealHeight: 560)
        .onAppear(perform: load)
    }

    /// Number fields accept only number characters; anything else typed or pasted is dropped.
    private func binding(for field: SchemaField) -> Binding<String> {
        Binding { values[field.key] ?? "" } set: { newValue in
            values[field.key] = field.type.isNumeric
                ? newValue.filter(FieldType.numberInputCharacters.contains)
                : newValue
        }
    }

    /// Number fields whose text isn't a valid number; Apply stays disabled until they're fixed or cleared.
    private var invalidKeys: Set<String> {
        let cleaned = cleaned(values)
        return Set((folder?.fields ?? []).filter { field in
            field.type.isNumeric && cleaned[field.key].map { field.type.numberFromInput($0) == nil } == true
        }.map(\.key))
    }

    private func load() {
        original = doc.values
        values = doc.values
    }

    /// Trims values and drops empty ones, so a cleared field means "not in the document".
    private func cleaned(_ values: [String: String]) -> [String: String] {
        values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
    }

    /// Saves the values, with numbers in stored form ("1500" → "1,500.00").
    private func apply() {
        var result = cleaned(values)
        for field in folder?.fields ?? [] where field.type.isNumeric {
            if let value = result[field.key] { result[field.key] = field.type.numberFromInput(value) }
        }
        Task { [store, id = doc.id] in await store.updateValues(result, of: id) }
        dismiss()
    }
}

private struct FieldValueRow: View {
    let field: SchemaField
    @Binding var value: String
    var isInvalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.label).font(.callout.weight(.semibold))
                Text(field.type.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
            }
            if !field.description.isEmpty {
                Text(field.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch field.type {
            case .date, .timestamp:
                DateValueEditor(value: $value, includesTime: field.type == .timestamp)
            case .string, .integer, .decimal:
                TextField(field.label, text: $value, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(field.type.isNumeric ? .trailing : .leading)
                if isInvalid {
                    Label(field.type == .integer ? "Enter a whole number, like 12 or 1,500."
                                                 : "Enter a number, like 1,248.50.",
                          systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 12)
    }

    /// Shows the format the table sorts best by.
    private var prompt: String {
        switch field.type {
        case .decimal: "e.g. 1,248.50"
        case .integer: "e.g. 12"
        case .string, .date, .timestamp: "Empty"
        }
    }
}

/// A date picker over a text value stored as "28 Jun 2024" (or "28 Jun 2024, 9:30 am" with time), so the table
/// keeps sorting by date. The value can be empty, and text that isn't a recognizable date is shown so it isn't lost.
private struct DateValueEditor: View {
    @Binding var value: String
    let includesTime: Bool

    @State private var showsCalendar = false

    private var formatter: DateFormatter { includesTime ? .documentStamp : .documentDay }

    private var date: Date? {
        includesTime ? DateFormatter.documentTimestamp(from: value) : DateFormatter.documentDate(from: value)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let date {
                let selection = Binding { date } set: { value = formatter.string(from: $0) }
                DatePicker("Value", selection: selection, displayedComponents: components)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                #if os(macOS)
                // The macOS compact picker is a text field; the calendar comes from this popover.
                Button("Show Calendar", systemImage: "calendar") { showsCalendar = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Choose from a calendar")
                    .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                        DatePicker("Value", selection: selection, displayedComponents: components)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding()
                    }
                #endif
                Button("Clear", systemImage: "xmark.circle.fill") { value = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove the value")
            } else {
                Button(includesTime ? "Set Date & Time" : "Set Date") { value = formatter.string(from: .now) }
                if value.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("No date").foregroundStyle(.secondary)
                } else {
                    Label("“\(value)” isn't a recognizable date. Set one to replace it.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var components: DatePickerComponents { includesTime ? [.date, .hourAndMinute] : [.date] }
}

#Preview {
    let store = ClassifierStore.preview(selecting: "invoices")
    FieldValuesSheet(store: store, target: ValueEditorTarget(folderID: "invoices", document: store.rows[0]))
        .frame(width: 560, height: 560)
}

#Preview("Unrecognized and empty dates") {
    let store = ClassifierStore.preview()
    let invoices = SampleData.folders().first { $0.folder.id == "invoices" }!
    let quotes = SampleData.folders().first { $0.folder.id == "quotes" }!
    // The AI wrote a due date the app can't read, and the quote has no expiry date.
    var invoice = invoices.docs[0]
    invoice.values["dueDate"] = "end of month"
    var quote = quotes.docs[0]
    quote.values["validUntil"] = nil
    return HStack(spacing: 0) {
        FieldValuesSheet(store: store, target: ValueEditorTarget(folderID: "invoices", document: invoice))
        Divider()
        FieldValuesSheet(store: store, target: ValueEditorTarget(folderID: "quotes", document: quote))
    }
    .frame(width: 1120, height: 560)
}
