# SwiftAIDocumentClassifier

A SwiftUI app for sorting scanned and digital documents (PDFs, images and, on macOS, Word-processing files) into **document types** such as Invoices, Letters or Receipts. Each type defines a schema of fields to extract. New files land in an **Unclassified** inbox, where on-device Apple Intelligence classifies them and extracts their fields.

The UI started from the Claude Design prototype *Document Classifier* ([claude.ai/design project](https://claude.ai/design/p/f2629100-6621-4c0f-b1d2-7372f6d413c8?file=docclassifier%2FDocument+Classifier.html)) and has since evolved beyond it; this README describes the app as implemented.

## Features

- **Sidebar:** the Unclassified inbox plus a "Document Types" section with document counts; **New Type** button.
- **Document table:** columns come from the selected type's schema; click a header to sort (numbers and dates sort by value, empty values last). Per-folder row selection is remembered. Search filters by name and extracted values as you type, matching anywhere inside words (`water` finds "Brightwater"); sorting and searching run in SQLite, so they stay fast with thousands of documents.
- **Preview:** every multi-page document scrolls continuously through its pages like Preview (PDFKit), with a "Page N of M" indicator: PDFs directly; Word/OpenDocument/RTF files and multi-page TIFFs through a PDF rendition made on import; multi-page sample documents through a generated PDF (page 1 plus continuation sheets). Single-page images and sample pages (invoice, quote, letter, contract, receipt) scroll in 2D when zoomed. **Zoom** works for every type: floating − / percentage menu / + control, pinch, and View-menu commands (⌘+, ⌘−, ⌘0 Actual Size, ⌘9 Zoom to Fit); it resets to fit when the selection changes. Beside it, an **inspector**: file facts for the inbox, extracted fields for typed folders. **Edit** in the Extracted Fields header opens a sheet with one row per field (name, data type, the field's description as guidance, and an editable value); the list scrolls for long schemas. Integer and Decimal fields accept only digits, a decimal point, thousands separators and a leading minus sign; anything else is dropped as you type, an invalid number such as `1.2.3` disables Apply with an error, and Integer fields reject fractions. Date and Timestamp fields use a date picker (on macOS, with a calendar button that opens a calendar), plus a button to clear the value; an empty date shows **Set Date**, and a value the app can't read as a date is shown with a warning until you pick one. **Apply** saves the changes and **Discard** closes without saving. Clearing a field removes its value. Toggle with the ⓘ toolbar button. Resizable split on macOS.
- **AI Classify** (Unclassified only, next to Add Documents): classifies the selected document with the on-device Apple Foundation Model; nothing leaves the Mac (details in [Apple Intelligence](#apple-intelligence)). It reads the document (PDF text layer, or Vision OCR for images and scans; images are also attached to the prompt), picks the type whose description and fields fit, and extracts that type's fields. If no type fits, or fewer than half of the best type's fields are in the document, it opens the type sheet with a **suggested new type** (name, description, typed fields). **Create & Classify** files the document under it, and **Classify as Existing Type** files it under a type you pick and fills what it can. A banner reports the result, with **Show** to open the folder.
- **AI Reclassify** (every document type, same place): runs the same process on a classified document. If the result is the type it's already in, the document and its values stay as they are; if it's a different type, the document moves there with freshly extracted values; if no type fits, the suggestion sheet opens (Cancel leaves it where it is).
- **Drag to classify:** drag a row from the table onto a folder in the sidebar to file the document there. The app accepts your choice without classifying the document or suggesting another type: it discards the values from the previous type and the on-device model fills the new type's fields (the banner reports how many it found). Dropping on Unclassified just clears the values. If another classification is running, the move happens immediately and the fields are filled when the model is free.
- **Create / edit document type:** a sheet with the type name (duplicate check), a type description (what the classifier matches documents against) and schema fields: name, data type (Text, Date, Timestamp, Integer, Decimal (2dp)) and a description that tells the AI how to extract the value. Integer and Decimal fields hold only a number (stored as `1,500.00`, without currency symbols or units). An amount that applies to a period is modeled as two fields: the number in a Decimal field and the period (month, year, and so on) in a separate Text field, as the sample Contracts type does with Value and Period. Removing a field deletes its values from every document of that type when you apply, and changing a field's data type converts its values (text to dates or numbers, dates to timestamps, and so on); a value that can't be converted is removed from that document. The sheet warns how many documents are affected before you apply. Conversion blocks the window with a progress card (documents done of total) and ends with a banner summarizing how many values were converted and removed. Renaming a field keeps its values.
- **Add Documents:** the system file importer for PDFs and images, plus on macOS Word (.docx, .doc), OpenDocument text and RTF; computes real MD5 and page count; files are copied into the library (named by SHA-256, so duplicates are stored once) and added to Unclassified. Word-processing files are paginated onto A4 with TextKit and multi-page TIFFs get one page per frame; the resulting PDF is stored in the library's `Renditions/` folder.
- **Library size:** shown at the top of the sidebar. It is the disk space used by everything under the library folder (original files, PDF renditions and the SQLite database with its `-wal`/`-shm` files), updated after each write.

Everything is saved in the library folder, `Application Support/DocumentLibrary/` in the app container: imported files in `Files/`, PDF renditions in `Renditions/`, and the catalogue (types, fields, documents, extracted values and the search index) in `library.sqlite` ([GRDB](https://github.com/groue/GRDB.swift)). On first launch the sample documents from `SampleData.swift` are written into the new database, once. Files imported by versions of the app that didn't save the catalogue are recovered at the same time: each appears once in Unclassified as "Recovered <hash>.<ext>".

## Apple Intelligence

Classification and extraction run entirely on device. The app uses only Apple's on-device foundation model; it never calls Private Cloud Compute or any server, so documents don't leave the Mac and AI works offline.

### Frameworks and APIs

| Framework | What the app uses | For |
| --- | --- | --- |
| **Foundation Models** | `SystemLanguageModel.default`, the on-device Apple Foundation Model ("AFM 3 Core Advanced" on the development Mac) | All three AI steps below |
| | `SystemLanguageModel.availability` | Disabling AI Classify, with the reason, when the device isn't eligible, Apple Intelligence is off, or the model is still downloading |
| | `contextSize`, `tokenCount(for:)` | Fitting each request in the context window (8,192 tokens on the development Mac; read at runtime, never hard-coded) |
| | `LanguageModelSession(model:instructions:)`, `Instructions`, the `Prompt` builder | One fresh single-turn session per step, so steps don't share or fill each other's context |
| | `Attachment` (multimodal prompting) | Sending an image document itself alongside its OCR text (~130 tokens per image) |
| | Guided generation: `DynamicGenerationSchema` → `GenerationSchema`, `respond(schema:)`, `GeneratedContent` | Schemas built at runtime from the user's document types and fields, so the answer always parses |
| | Guided generation: `@Generable`, `@Guide` (incl. `.count(2...6)`) | The fixed shape of a proposed new type (`ProposedType`, `ProposedField`, `ProposedFieldType`) |
| | `GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 600)` | Repeatable answers, and a cap so a runaway answer can't overflow the context |
| **Vision** | `RecognizeDocumentsRequest` → `DocumentObservation.document.text.transcript` | On-device OCR of images and scanned PDF pages |
| **PDFKit** | `PDFDocument.string`, `PDFPage.draw(with:to:)` | Reading a PDF's text layer; rasterizing scanned pages (~2000 px) for OCR |

Not used: Private Cloud Compute (`PrivateCloudComputeLanguageModel`), reasoning levels (not supported by the on-device model), tool calling (including Vision's `OCRTool`, because the app runs OCR itself and puts the text in the prompt), and the content-tagging model.

### How each kind of document reaches the model

`DocumentReader` turns a document into a `DocumentText`: the file name, a text body and, for image documents only, the image.

| Document | What the model receives |
| --- | --- |
| **PDF with a text layer** (digital PDFs) | The text layer from PDFKit. No image. |
| **Scanned PDF** (less than 40 characters of text per page) | Each of the first 4 pages rendered at ~2000 px and OCR'd with Vision; the page texts joined. No image. |
| **Image** (JPEG, PNG, HEIC, single-page TIFF) | Vision OCR text **plus the image itself** as an `Attachment`, so the model sees layout, logos and stamps as well as the words. |
| **Multi-page TIFF** | Converted to a PDF rendition on import (one page per frame), which has no text layer, so it's handled like a scanned PDF. |
| **Word (.docx, .doc), OpenDocument text, RTF** (macOS) | Converted to a PDF rendition on import (TextKit lays the text out on A4 pages), so the model receives that rendition's text layer. That is the document's own text, so no OCR is needed. |
| **Sample documents** (seed data) | The text printed on the sample page, in reading order (`PrintedPage.transcript`). Continuation pages of multi-page samples are filler and add nothing. |
| **Files without a preview** | Nothing readable. Classification stops with "No readable content was found in this document." |

Whatever the source, the text is trimmed if needed so instructions, schema, prompt, an image allowance (200 tokens) and room for the answer (700 tokens) all fit the context window.

### The three steps

1. **Classify.** The prompt lists every document type on one line each (its name, its description, and each field's label with the first sentence of that field's description), followed by the file name and the document. The runtime schema asks, in this order, for `documentKind` (what the document is, in a few words; it is generated first so the model commits to that before choosing), `documentType` (one of the type names or "No matching type", enforced by the schema) and `confidence` (high / medium / low; returned but not shown in the UI yet).
2. **Extract.** For the chosen type, a schema with one property per field (camelCase names derived from the labels). Each property's description is the field's label and description, plus a format hint for dates ("like 28 Jun 2024"). Every property is a required but nullable string; the app converts values itself (dates to `28 Jun 2024`, numbers to just the number, `1,248.50`) and drops placeholders such as "N/A" and number answers that contain no number. The share of fields actually found decides whether the document has enough information for that type: at least half (`DocumentClassifier.minimumFieldCoverage`).
3. **Propose** (only when no type fits, or too few fields were found). The model generates a `ProposedType`: a plural name, a description, and two to six fields, each with a name, a data type (text, date, integer or decimal) and an extraction instruction. It avoids the existing type names. Number fields hold only the number, so when the document gives an amount per period ("per month", "/mo", "annually" and so on) the proposal includes a separate Period text field; the instructions ask for it, and because the model only sometimes complies, the app adds it when it's missing. It opens pre-filled in the type sheet; accepting it runs step 2 for the new type.

These choices were measured on the on-device model with the sample documents: numeric schemas made it invent numbers (a contract "value" of 1.00), optional properties made it skip or reorder fields, and a "write it as a number" hint made it drop amounts. That is why fields are nullable strings converted in code. One known weakness remains: example wording in a field description can leak into answers (the sample contracts get "ongoing" as their term).

## Requirements

- Xcode 27.2 or later (the project uses the new `project.xcproj` format with a folder-synchronized source group, so new `.swift` files in `SwiftAIDocumentClassifier/` are picked up automatically).
- Deployment target 27.2. One multiplatform target: macOS, iOS/iPadOS, visionOS. The layout is designed for macOS.
- AI Classify needs a device that supports Apple Intelligence, with Apple Intelligence turned on and its model downloaded; otherwise the button is disabled and its tooltip says why.

## Build & run

Open `SwiftAIDocumentClassifier.xcodeproj` and run the `SwiftAIDocumentClassifier` scheme on **My Mac**, or from the command line:

```sh
xcodebuild -project SwiftAIDocumentClassifier.xcodeproj -scheme SwiftAIDocumentClassifier \
  -destination 'platform=macOS' build
xcodebuild -project SwiftAIDocumentClassifier.xcodeproj -scheme SwiftAIDocumentClassifier \
  -destination 'generic/platform=iOS Simulator' build
```

Both should build with zero errors and zero warnings.

## Source layout

| File | Contents |
| --- | --- |
| [MyApp.swift](SwiftAIDocumentClassifier/MyApp.swift) | App entry point, default window size 1200×780, zoom commands |
| [Models.swift](SwiftAIDocumentClassifier/Models.swift) | `FieldType`, `SchemaField`, `Document`, `DocumentContent`, `PrintedPage`, `DocumentFolder`, `MetaKey`, date formatters |
| [SampleData.swift](SwiftAIDocumentClassifier/SampleData.swift) | Seed folders, schemas (with AI field descriptions) and documents |
| [ClassifierStore.swift](SwiftAIDocumentClassifier/ClassifierStore.swift) | `@Observable` app state (types, counts, the selected folder's rows), loading and recovery, type create/update, file import, AI classification flow (classify, accept suggestion, force classify, filing); `PlatformImage` helpers |
| [DocumentLibrary.swift](SwiftAIDocumentClassifier/DocumentLibrary.swift) | On-disk library folder (`Files/`, `Renditions/`), content-addressed storage, `LibrarySizeMonitor` |
| [LibraryDatabase.swift](SwiftAIDocumentClassifier/LibraryDatabase.swift) | SQLite catalogue (GRDB): schema and migration (with sample seeding), queries for rows, sorting and FTS5 search, and every write |
| [ContentView.swift](SwiftAIDocumentClassifier/ContentView.swift) | `NavigationSplitView`, `FolderDetailView` (toolbar, search, split), `EmptyFolderView` |
| [SidebarView.swift](SwiftAIDocumentClassifier/SidebarView.swift) | Folder list and New Type button |
| [DocumentTable.swift](SwiftAIDocumentClassifier/DocumentTable.swift) | Dynamic-column `Table` and `DocumentComparator` |
| [DocumentPreview.swift](SwiftAIDocumentClassifier/DocumentPreview.swift) | Page rendering and inspector |
| [DocumentRendition.swift](SwiftAIDocumentClassifier/DocumentRendition.swift) | PDF renditions for paged content: text documents (TextKit, macOS), multi-page TIFF, SwiftUI pages |
| [PreviewStage.swift](SwiftAIDocumentClassifier/PreviewStage.swift) | `PreviewZoom` model + View-menu commands, floating zoom controls, `ZoomableStage`, `PDFStage` (PDFView bridge); `#Preview("PDF")` with a generated PDF |
| [FieldValuesSheet.swift](SwiftAIDocumentClassifier/FieldValuesSheet.swift) | Sheet for editing a classified document's extracted values |
| [TypeEditorSheet.swift](SwiftAIDocumentClassifier/TypeEditorSheet.swift) | Create/edit/suggested type sheet and schema editor; `#Preview("Suggested type")` |
| [DocumentReader.swift](SwiftAIDocumentClassifier/DocumentReader.swift) | Document text for the model: PDF text layer, Vision `RecognizeDocumentsRequest` OCR, sample-page transcripts |
| [DocumentClassifier.swift](SwiftAIDocumentClassifier/DocumentClassifier.swift) | Foundation Models classification, field extraction (dynamic schemas) and new-type proposals (`@Generable`) |

## Roadmap

Not built yet, in priority order:

1. **Store extracted text:** `DocumentReader` already produces it for classification. Persist it per document in `document_text` (the table exists, empty) and add it to the search index instead of re-reading (and re-OCRing) each time.
2. **AI follow-ups:** classify all Unclassified documents in one go (suggestions queued one at a time); re-run extraction for a classified document; validate edited numbers; show the classifier's confidence; an evaluation set (the Evaluations framework) to guard prompt quality across model updates.
3. **Moving documents:** a "Move to" command (menu and context menu) as a keyboard-friendly alternative to dragging, and dragging several selected rows at once.
4. **Re-extraction when a schema changes:** fields added to a type stay empty for documents already in it until they are reclassified into it or edited by hand. Offer to extract just the new fields.
5. **Removing sample documents:** a "Remove Sample Documents" command (they are marked `is_sample`).
6. Smaller gaps: back/forward toolbar arrows and the list-view button (both no-ops in the prototype), a deliberate compact (iPhone) layout, and a page-thumbnail sidebar for long documents.
