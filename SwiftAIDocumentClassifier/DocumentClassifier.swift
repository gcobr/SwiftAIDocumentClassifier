import Foundation
import FoundationModels

/// Classification, field extraction and new-type proposals with the on-device Apple Foundation Model.
/// Every request uses guided generation, so answers always match the schema; nothing leaves the device.
struct DocumentClassifier {
    let model = SystemLanguageModel.default

    /// A document is filed under its best-matching type only if at least this share of the type's fields
    /// could be extracted; otherwise the app suggests a new type.
    static let minimumFieldCoverage = 0.5

    /// Greedy sampling for repeatable answers; the token cap stops a runaway answer from filling the context.
    private static let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 600)
    /// Tokens kept free for the model's answer.
    private static let responseReserve = 700

    enum Confidence: String, CaseIterable {
        case high, medium, low
    }

    struct Match {
        /// Nil when no existing type fits.
        var typeID: DocumentFolder.ID?
        var confidence: Confidence
        /// What the model thinks the document is, e.g. "plumbing invoice".
        var documentKind: String
    }

    // MARK: Classify

    /// Picks the existing type whose description and fields best match the document.
    func classify(_ document: DocumentText, among types: [DocumentFolder]) async throws -> Match {
        guard !types.isEmpty else { return Match(typeID: nil, confidence: .low, documentKind: "") }
        let noMatch = "No matching type"
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Classification", properties: [
            // Generated first, so the model states what the document is before choosing a type.
            .init(name: "documentKind",
                  description: "What this document is, in a few words, e.g. 'plumbing invoice' or 'school newsletter'.",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "documentType",
                  description: "The document type this document belongs to, or '\(noMatch)'.",
                  schema: DynamicGenerationSchema(name: "DocumentType", anyOf: types.map(\.name) + [noMatch])),
            .init(name: "confidence",
                  description: "How certain the choice of document type is.",
                  schema: DynamicGenerationSchema(name: "Confidence", anyOf: Confidence.allCases.map(\.rawValue))),
        ]), dependencies: [])

        let instructions = """
            You sort documents into document types. Each type has a description and the fields extracted from \
            its documents. Choose the type whose description matches what the document is and whose fields the \
            document contains. If no type matches, choose "\(noMatch)". Use only the document's content.
            """
        let header = "Document types:\n" + types.map(Self.summary).joined(separator: "\n")
            + "\n\nDocument “\(document.fileName)”:\n"
        let content = try await respond(instructions: instructions, header: header, document: document, schema: schema)

        let chosen = try content.value(String.self, forProperty: "documentType")
        return Match(
            typeID: types.first { $0.name == chosen }?.id,
            confidence: Confidence(rawValue: try content.value(String.self, forProperty: "confidence")) ?? .low,
            documentKind: try content.value(String.self, forProperty: "documentKind")
        )
    }

    // MARK: Extract

    /// Fills the type's fields from the document. Fields the document doesn't contain are left out of the result.
    func extractValues(from document: DocumentText, for type: DocumentFolder) async throws -> [String: String] {
        guard !type.fields.isEmpty else { return [:] }
        let names = Self.propertyNames(for: type.fields)
        // Every field is required but nullable text, converted afterwards. Measured on the on-device model:
        // numeric schemas make it produce a number (e.g. 1.00) even when the document has none, and optional
        // properties make it skip or reorder fields.
        let properties = zip(type.fields, names).map { field, name in
            DynamicGenerationSchema.Property(
                name: name, description: Self.guide(for: field),
                schema: DynamicGenerationSchema(name: "Value_" + name,
                                                anyOf: [DynamicGenerationSchema(type: String.self), .null]),
                isOptional: false)
        }
        let schema = try GenerationSchema(
            root: DynamicGenerationSchema(name: "Fields", description: type.description, properties: properties),
            dependencies: [])

        let instructions = """
            You extract fields from a document of type "\(type.name)". Follow each field's description; take \
            values from the document's content, never from its file name. If the document doesn't contain the \
            information for a field, answer null. Never invent values: examples in descriptions are \
            illustrations, not answers.
            """
        let header = "Document “\(document.fileName)”:\n"
        let content = try await respond(instructions: instructions, header: header, document: document, schema: schema)

        guard case .structure(let generated, _) = content.kind else { return [:] }
        var values: [String: String] = [:]
        for (field, name) in zip(type.fields, names) {
            if let value = generated[name].flatMap({ Self.displayValue($0, for: field.type) }) {
                values[field.key] = value
            }
        }
        return values
    }

    // MARK: Propose

    /// Suggests a new document type, with fields, for a document that no existing type fits.
    func proposeType(for document: DocumentText, existing types: [DocumentFolder]) async throws -> ProposedType {
        let instructions = """
            You design document types for a document filing app. A document type has a plural name, a description \
            of what its documents are, and fields to extract from each document. Propose fields that this document \
            actually contains and that would be useful to sort or search by. Integer and decimal fields hold only \
            a number. Only if the document gives an amount per period, such as per month or per fortnight, add a \
            separate text field named "Period" for how often it applies. Don't add a Period field for one-off totals.
            """
        let existing = types.isEmpty ? "" : "Existing types (don't reuse these names): "
            + types.map(\.name).joined(separator: ", ") + "\n\n"
        let header = existing + "Propose a document type for documents like this one, “\(document.fileName)”:\n"
        let body = try await fittedBody(document.body, instructions: instructions, header: header,
                                        tokensForSchema: model.tokenCount(for: ProposedType.generationSchema))
        let session = LanguageModelSession(model: model, instructions: instructions)
        var proposal = try await session.respond(generating: ProposedType.self, options: Self.options) {
            header
            body
            if let image = document.image { Attachment(image) }
        }.content
        Self.addPeriodFieldIfNeeded(to: &proposal, documentText: document.body)
        return proposal
    }

    /// Amounts per period are modeled as a number plus a separate Period text field. The on-device model only
    /// sometimes proposes that field (measured), so it's added when the document states an amount per period,
    /// the proposal has a decimal field, and no field already covers the period.
    private static func addPeriodFieldIfNeeded(to proposal: inout ProposedType, documentText: String) {
        let perPeriod = #"\b(per|a|each|every)\s+(day|week|fortnight|month|quarter|year|annum)\b|/\s?(day|wk|week|mo|month|qtr|quarter|yr|year)\b|\b(weekly|fortnightly|monthly|quarterly|annually|yearly)\b|\bp\.a\."#
        guard documentText.range(of: perPeriod, options: [.regularExpression, .caseInsensitive]) != nil,
              proposal.fields.contains(where: { $0.type == .decimal }),
              !proposal.fields.contains(where: { field in
                  ["period", "frequency", "interval"].contains { field.name.localizedCaseInsensitiveContains($0) }
              }) else { return }
        proposal.fields.append(ProposedField(
            name: "Period", type: .text,
            description: "How often the amount applies, such as week, fortnight, month or year. Leave empty for a one-off total."))
    }

    // MARK: Prompting

    private func respond(instructions: String, header: String, document: DocumentText,
                         schema: GenerationSchema) async throws -> GeneratedContent {
        let body = try await fittedBody(document.body, instructions: instructions, header: header,
                                        tokensForSchema: model.tokenCount(for: schema))
        let session = LanguageModelSession(model: model, instructions: instructions)
        return try await session.respond(schema: schema, options: Self.options) {
            header
            body
            if let image = document.image { Attachment(image) }
        }.content
    }

    /// Trims the document text so instructions, schema, prompt, image and answer fit the model's context window.
    private func fittedBody(_ body: String, instructions: String, header: String,
                            tokensForSchema: Int) async throws -> String {
        let fixed = try await model.tokenCount(for: Instructions(instructions))
            + model.tokenCount(for: header) + tokensForSchema
        let budget = model.contextSize - fixed - Self.responseReserve - 200   // 200 covers an image attachment
        guard budget > 0 else { return "" }
        var text = body
        for _ in 0..<4 {
            let tokens = try await model.tokenCount(for: text)
            guard tokens > budget else { return text }
            text = String(text.prefix(Int(Double(text.count) * Double(budget) / Double(tokens) * 0.9)))
        }
        return text
    }

    /// One line per type: name, description, and each field with the first sentence of its description.
    private static func summary(of type: DocumentFolder) -> String {
        let fields = type.fields.map { field in
            let hint = firstSentence(of: field.description)
            return hint.isEmpty ? field.label : "\(field.label) (\(hint))"
        }
        var line = "- \(type.name)"
        if !type.description.isEmpty { line += ": \(type.description)" }
        if !fields.isEmpty { line += " Fields: " + fields.joined(separator: "; ") + "." }
        return line
    }

    private static func firstSentence(of text: String, maxLength: Int = 100) -> String {
        let sentence = text.split(separator: ". ", maxSplits: 1).first.map(String.init) ?? ""
        return sentence.count > maxLength ? String(sentence.prefix(maxLength)) + "…" : sentence
    }

    // MARK: Field schemas

    private static func guide(for field: SchemaField) -> String {
        // No hint for numbers: on the on-device model, "write it as a number" makes amounts come back
        // missing or malformed. Numbers are normalized from the copied text instead.
        let format = switch field.type {
        case .date: "Format the date like 28 Jun 2024."
        case .timestamp: "Format like 28 Jun 2024, 9:30 am."
        case .decimal, .integer, .string: ""
        }
        return [field.label + ".", field.description, format].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// camelCase property names derived from field labels ("BSB / Account" → "bsbAccount"), unique within a type.
    static func propertyNames(for fields: [SchemaField]) -> [String] {
        var used = Set<String>()
        return fields.map { field in
            let words = field.label.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            var name = words.enumerated().map { $0 == 0 ? $1.lowercased() : $1.capitalized }.joined()
            if name.isEmpty || name.first?.isNumber == true { name = "field" + name }
            var unique = name, suffix = 2
            while !used.insert(unique).inserted { unique = name + String(suffix); suffix += 1 }
            return unique
        }
    }

    /// Converts a generated value to the string shown in the table, normalizing dates and numbers.
    static func displayValue(_ content: GeneratedContent, for type: FieldType) -> String? {
        let text: String
        switch content.kind {
        case .string(let string): text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let number): text = String(number)
        default: return nil
        }
        let placeholders: Set<String> = ["", "n/a", "na", "none", "null", "nil", "unknown", "not found",
                                         "not available", "not specified", "not provided", "-", "—"]
        guard !placeholders.contains(text.lowercased()) else { return nil }
        switch type {
        case .date: return normalizedDate(text)
        // Number fields store only the number; an answer without one is discarded rather than stored as text.
        case .integer, .decimal: return normalizedNumber(text, as: type)
        case .string, .timestamp: return text
        }
    }

    /// The first number in the text ("$2,650 / mo" → 2650), formatted with grouping; nil if there is none.
    private static func normalizedNumber(_ text: String, as type: FieldType) -> String? {
        guard let range = text.range(of: #"-?\d[\d,]*(\.\d+)?"#, options: .regularExpression),
              let number = Double(text[range].replacing(",", with: "")) else { return nil }
        let style = FloatingPointFormatStyle<Double>.number.locale(Locale(identifier: "en_US"))
        return type == .integer
            ? number.formatted(style.precision(.fractionLength(0)))
            : number.formatted(style.precision(.fractionLength(2)))
    }

    /// Rewrites common date spellings as "28 Jun 2024" (the format the table sorts by); leaves others as written.
    private static func normalizedDate(_ text: String) -> String {
        DateFormatter.documentDate(from: text).map(DateFormatter.documentDay.string(from:)) ?? text
    }
}

// MARK: - Proposal types

@Generable
struct ProposedType {
    @Guide(description: "A short plural name for this kind of document, e.g. 'Payslips' or 'Medical Referrals'.")
    var name: String

    @Guide(description: "One or two sentences describing what documents of this type are and how to recognize them.")
    var description: String

    @Guide(description: "Two to six fields worth extracting from every document of this type.", .count(2...6))
    var fields: [ProposedField]
}

@Generable
struct ProposedField {
    @Guide(description: "A short field name in title case, e.g. 'Pay Date'.")
    var name: String

    var type: ProposedFieldType

    @Guide(description: "How to find this value in the document, written as an instruction for extracting it.")
    var description: String
}

@Generable
enum ProposedFieldType {
    case text, date, integer, decimal

    var fieldType: FieldType {
        switch self {
        case .text: .string
        case .date: .date
        case .integer: .integer
        case .decimal: .decimal
        }
    }
}
