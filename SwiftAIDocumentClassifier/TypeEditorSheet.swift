import SwiftUI

/// Creates a document type, edits one, or reviews a type suggested by AI classification.
struct TypeEditorSheet: View {
    let store: ClassifierStore
    let mode: TypeEditorMode

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var typeDescription = ""
    @State private var fields: [SchemaField] = []
    /// Documents affected by the pending schema change, counted in the database.
    @State private var affected = AffectedDocuments()

    private var editingID: DocumentFolder.ID? {
        if case .edit(let id) = mode { id } else { nil }
    }

    private var suggestion: TypeSuggestion? {
        if case .suggest(let suggestion) = mode { suggestion } else { nil }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameTaken: Bool { store.isNameTaken(trimmedName, excluding: editingID) }
    private var canSubmit: Bool { !trimmedName.isEmpty && !nameTaken }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], 22)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameSection
                    descriptionSection
                    SchemaEditor(fields: $fields)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 4)
            }

            HStack {
                if let suggestion {
                    classifyAsExistingMenu(suggestion)
                }
                if let warning = removalWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(submitTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(22)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 360, idealHeight: 620)
        .onAppear(perform: load)
        .task(id: schemaChange) {
            guard let id = editingID, let change = schemaChange else { return }
            affected = AffectedDocuments(
                removed: await store.documentCount(in: id, withValuesFor: change.removed),
                retyped: await store.documentCount(in: id, withValuesFor: change.retyped))
        }
    }

    /// Keys of the fields that applying would remove or retype (edit mode only).
    private var schemaChange: SchemaChange? {
        guard let id = editingID else { return nil }
        let kept = fields.filter { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        return SchemaChange(removed: store.removedFieldKeys(in: id, keeping: kept),
                            retyped: Set(store.retypedFields(in: id, to: kept).map(\.key)))
    }

    /// Tells the user what applying will do to existing values: removed fields lose them, and fields with a new
    /// data type have them converted (or removed when they can't be).
    private var removalWarning: String? {
        guard let change = schemaChange else { return nil }
        let removed = change.removed, retyped = change.retyped
        func documentsText(_ count: Int) -> String { count == 1 ? "1 document" : "\(count.formatted()) documents" }

        var sentences: [String] = []
        let removedCount = removed.isEmpty ? 0 : affected.removed
        if removedCount > 0 {
            let fieldsText = removed.count == 1 ? "1 field deletes its values" : "\(removed.count) fields deletes their values"
            sentences.append("Removing \(fieldsText) from \(documentsText(removedCount)).")
        }
        let retypedCount = retyped.isEmpty ? 0 : affected.retyped
        if retypedCount > 0 {
            let fieldsText = retyped.count == 1 ? "1 field converts its values" : "\(retyped.count) fields converts their values"
            sentences.append("Changing the data type of \(fieldsText) in \(documentsText(retypedCount)); values that can't be converted are removed.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private var submitTitle: String {
        switch mode {
        case .create: "Create"
        case .edit: "Apply"
        case .suggest: "Create & Classify"
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch mode {
            case .create:
                Text("New Document Type").font(.headline)
                Text("Name the type and define the fields to extract from each document. The new type starts empty.")
                    .subtitle()
            case .edit:
                Text("Edit Document Type").font(.headline)
                Text("Rename the type or change which fields are extracted from its documents.")
                    .subtitle()
            case .suggest(let suggestion):
                Label("Suggested Document Type", systemImage: "apple.intelligence").font(.headline)
                Text("\(suggestion.reason) Apple Intelligence suggests this new type. Adjust it and create it to classify the document, or classify the document as an existing type instead.")
                    .subtitle()
            }
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Type name").sectionLabel()
            TextField("Type name", text: $name, prompt: Text("e.g. Invoices"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(submit)
            if nameTaken {
                Text("A document type named “\(trimmedName)” already exists.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Description — what documents of this type are; AI classification matches documents against it")
                .sectionLabel()
            DescriptionEditor(
                text: $typeDescription,
                placeholder: "Describe this kind of document and how to recognize it, e.g. “Bills requesting payment, with an amount due and a due date.”",
                height: 56)
        }
    }

    /// Rejects the suggestion: files the document under an existing type, filling as many of its fields as possible.
    private func classifyAsExistingMenu(_ suggestion: TypeSuggestion) -> some View {
        let types = store.typeFolders.sorted { first, _ in first.id == suggestion.closestTypeID }
        return Menu("Classify as Existing Type") {
            ForEach(types) { type in
                Button(type.id == suggestion.closestTypeID ? "\(type.name) (closest match)" : type.name) {
                    Task { await store.forceClassify(suggestion, into: type.id) }
                    dismiss()
                }
            }
        }
        .fixedSize()
        .disabled(types.isEmpty)
    }

    private func load() {
        switch mode {
        case .create:
            fields = [.newField()]
        case .edit(let id):
            guard let folder = store.folders.first(where: { $0.id == id }) else { return }
            name = folder.name
            typeDescription = folder.description
            fields = folder.fields
        case .suggest(let suggestion):
            name = suggestion.name
            typeDescription = suggestion.description
            fields = suggestion.fields
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let kept = fields.compactMap { field -> SchemaField? in
            var field = field
            field.label = field.label.trimmingCharacters(in: .whitespaces)
            field.description = field.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return field.label.isEmpty ? nil : field
        }
        let description = typeDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .create:
            Task { await store.createType(name: trimmedName, description: description, fields: kept) }
        case .edit(let id):
            Task { await store.updateType(id: id, name: trimmedName, description: description, fields: kept) }
        case .suggest(let suggestion):
            Task { await store.acceptSuggestion(suggestion, name: trimmedName, description: description, fields: kept) }
        }
        dismiss()
    }
}

private struct SchemaChange: Hashable {
    var removed: Set<String>
    var retyped: Set<String>
}

private struct AffectedDocuments {
    var removed = 0
    var retyped = 0
}

private struct SchemaEditor: View {
    @Binding var fields: [SchemaField]

    private let stackWidth: CGFloat = 196

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Schema fields").sectionLabel()
                Spacer()
                Text(fields.count == 1 ? "1 field" : "\(fields.count) fields")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if fields.isEmpty {
                Text("No fields yet — add the fields you want to extract from this document type.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 8) {
                    Text("Field name & data type").frame(width: stackWidth, alignment: .leading)
                    Text("Description — tells AI extraction how to find the value")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            }

            ForEach($fields) { $field in
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 6) {
                        TextField("Field name", text: $field.label, prompt: Text("e.g. Vendor"))
                            .textFieldStyle(.roundedBorder)
                        Picker("Data type", selection: $field.type) {
                            ForEach(FieldType.allCases) { Text($0.label).tag($0) }
                        }
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .labelsHidden()
                    .frame(width: stackWidth)

                    DescriptionEditor(text: $field.description)

                    Button("Remove field", systemImage: "minus.circle.fill") {
                        fields.removeAll { $0.id == field.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Remove field")
                    .padding(.top, 4)
                }
            }

            Button("Add Field", systemImage: "plus.circle") {
                fields.append(.newField())
            }
        }
    }
}

/// Multi-line description with a placeholder, which `TextEditor` lacks.
private struct DescriptionEditor: View {
    @Binding var text: String
    var placeholder = "Describe what this field is and how to find it in the document. The more detail, the better the AI can extract it."
    var height: CGFloat = 92

    var body: some View {
        TextEditor(text: $text)
            .font(.callout)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: height)
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

private extension Text {
    func sectionLabel() -> some View {
        font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    func subtitle() -> some View {
        font(.callout).foregroundStyle(.secondary)
    }
}

#Preview("Suggested type") {
    let store = ClassifierStore.preview()
    let suggestion = TypeSuggestion(
        documentID: UUID(),
        text: DocumentText(fileName: "payslip_2024-06-15.pdf", body: ""),
        reason: "“payslip_2024-06-15.pdf” doesn't match any existing document type.",
        name: "Payslips",
        description: "Documents showing an employee's earnings, deductions, and net pay for a specific pay period.",
        fields: [
            SchemaField(key: "c_1", label: "Pay Date", type: .date, description: "The date the pay was paid or the end of the pay period."),
            SchemaField(key: "c_2", label: "Gross Pay", type: .decimal, description: "The total amount earned before deductions."),
            SchemaField(key: "c_3", label: "Net Pay", type: .decimal, description: "The final amount paid to the employee."),
        ],
        closestTypeID: "letters", closestValues: [:])
    TypeEditorSheet(store: store, mode: .suggest(suggestion))
        .frame(width: 760, height: 620)
}
