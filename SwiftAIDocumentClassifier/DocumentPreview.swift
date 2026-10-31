import SwiftUI

/// Quick Look-style stage plus the inspector of extracted fields.
struct DocumentPreview: View {
    let folder: DocumentFolder
    let doc: Document?
    let showsInspector: Bool
    /// Opens the value editor for a classified document; nil in the inbox, which has no extracted fields.
    var onEditValues: ((Document) -> Void)?

    @State private var zoom = PreviewZoom()
    @State private var pdfPage = 0

    var body: some View {
        if let doc {
            HStack(spacing: 0) {
                PageView(doc: doc, zoom: zoom, pdfPage: $pdfPage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.6))
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        PreviewZoomControls(zoom: zoom, pageLabel: pageLabel(for: doc))
                            .padding(10)
                    }
                if showsInspector {
                    Divider()
                    InspectorView(folder: folder, doc: doc, onEditValues: onEditValues.map { edit in { edit(doc) } })
                        .frame(width: 282)
                }
            }
            .focusedSceneValue(\.previewZoom, zoom)
            .onChange(of: doc.id) {
                zoom.zoomToFit()
                pdfPage = 0
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "doc",
                                   description: Text("Select a document to preview it here."))
        }
    }

    private func pageLabel(for doc: Document) -> String? {
        guard PageView.isPaged(doc), let pages = doc.pages, pages > 1 else { return nil }
        return "Page \(pdfPage + 1) of \(pages)"
    }
}

// MARK: - Page

private struct PageView: View {
    let doc: Document
    let zoom: PreviewZoom
    @Binding var pdfPage: Int

    private static let sheet = CGSize(width: 300, height: 286)
    private static let receipt = CGSize(width: 220, height: 286)
    /// PDFs generated for multi-page sample documents, keyed by document.
    private static var sampleRenditions: [Document.ID: URL] = [:]

    /// Multi-page documents scroll through their pages in `PDFStage`; others zoom in `ZoomableStage`.
    static func isPaged(_ doc: Document) -> Bool {
        switch doc.content {
        case .pdf: true
        case .printed: (doc.pages ?? 1) > 1
        case .image, .file: false
        }
    }

    var body: some View {
        switch doc.content {
        case .pdf(let url):
            pdfStage(url)
        case .printed(let page) where Self.isPaged(doc):
            if let url = sampleRendition(page) {
                pdfStage(url)
            }
        case .image(let url):
            ImageStage(url: url, zoom: zoom)
        case .file:
            ZoomableStage(zoom: zoom, contentSize: Self.sheet) { scale in
                paper {
                    VStack(spacing: 10) {
                        Image(systemName: "doc")
                            .font(.system(size: 44, weight: .ultraLight))
                            .foregroundStyle(Color.paperMuted)
                        Text(doc.name).font(.system(size: 10, weight: .bold))
                        Text("Preview unavailable").foregroundStyle(Color.paperMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .scaledPage(size: Self.sheet, scale: scale)
            }
        case .printed(let page):
            let size = page.style == .receipt ? Self.receipt : Self.sheet
            ZoomableStage(zoom: zoom, contentSize: size) { scale in
                printed(page).scaledPage(size: size, scale: scale)
            }
        }
    }

    private func pdfStage(_ url: URL) -> some View {
        PDFStage(url: url, zoom: zoom, currentPage: $pdfPage)
            .id(url)
    }

    /// Page 1 is the printed page; the rest are continuation sheets.
    private func sampleRendition(_ page: PrintedPage) -> URL? {
        if let url = Self.sampleRenditions[doc.id] { return url }
        let total = doc.pages ?? 1
        let size = page.style == .receipt ? Self.receipt : Self.sheet
        let data = DocumentRendition.pdf(pageSize: size, pageCount: total) { index in
            if index == 0 {
                printed(page)
            } else {
                continuation(page, number: index + 1, of: total)
            }
        }
        let url = URL.temporaryDirectory.appending(path: "sample-\(doc.id).pdf")
        guard let data, (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        Self.sampleRenditions[doc.id] = url
        return url
    }

    private func continuation(_ page: PrintedPage, number: Int, of total: Int) -> some View {
        paper {
            HStack(alignment: .firstTextBaseline) {
                Text(page.from).bold()
                Spacer()
                Text("Page \(number) of \(total)").foregroundStyle(Color.paperMuted)
            }
            rule
            ForEach(0..<11, id: \.self) { line in
                fillerLine([1, 0.92, 0.97, 0.85, 0.6][line % 5])
            }
            Spacer(minLength: 0)
        }
        .fontDesign(page.style == .receipt ? .monospaced : nil)
    }

    private func fillerLine(_ fraction: CGFloat) -> some View {
        Capsule()
            .fill(Color(red: 0.93, green: 0.94, blue: 0.96))
            .frame(maxWidth: .infinity, maxHeight: 5)
            .scaleEffect(x: fraction, anchor: .leading)
            .padding(.vertical, 2.5)
    }

    @ViewBuilder
    private func printed(_ page: PrintedPage) -> some View {
        switch page.style {
        case .invoice, .quote:
            paper {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text(page.from).brand()
                        Text(page.style == .invoice ? "Tax Invoice" : "Quotation").kicker()
                    }
                    Spacer()
                    Text(page.date).foregroundStyle(Color.paperMuted)
                }
                rule
                ForEach(page.lines, id: \.self) { line in
                    lineRow(line, "—")
                }
                Spacer(minLength: 0)
                totalRow(page.style == .invoice ? "Amount Due" : "Total", page.amount)
            }
        case .letter, .contract:
            paper {
                Text(page.from).brand()
                Text(page.date).kicker().padding(.top, 2)
                rule
                if let to = page.to { Text(to).padding(.bottom, 6) }
                if let subject = page.subject { Text(subject).bold().padding(.bottom, 6) }
                if let paragraph = page.paragraph { Text(paragraph).foregroundStyle(Color(white: 0.33)) }
                ForEach([0.85, 1, 0.7, 0.5], id: \.self, content: fillerLine)
                Spacer(minLength: 0)
            }
        case .receipt:
            paper {
                VStack {
                    Text(page.from).font(.system(size: 11, weight: .bold))
                    Text(page.date).foregroundStyle(Color.paperMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
                rule
                ForEach(page.lines, id: \.self) { line in
                    lineRow(line, "·")
                }
                Spacer(minLength: 0)
                totalRow("TOTAL", page.amount)
            }
            .fontDesign(.monospaced)
        }
    }

    /// A sheet of paper; `ZoomableStage` sizes it (300×286, receipts 220×286) and adds the shadow.
    private func paper(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .font(.system(size: 8.5))
            .lineSpacing(2)
            .foregroundStyle(Color(white: 0.16))
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white, in: .rect(cornerRadius: 2))
            .environment(\.colorScheme, .light)
    }

    private var rule: some View {
        Rectangle().fill(Color.paperRule).frame(height: 1).padding(.vertical, 10)
    }

    private func lineRow(_ text: String, _ trailing: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(text)
                Spacer()
                Text(trailing).foregroundStyle(Color.paperMuted)
            }
            .padding(.vertical, 3)
            Rectangle().fill(Color.paperRule.opacity(0.6)).frame(height: 0.5)
        }
    }

    private func totalRow(_ label: String, _ amount: String?) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.paperRule).frame(height: 1)
            HStack {
                Text(label)
                Spacer()
                Text(amount ?? "—")
            }
            .font(.system(size: 11, weight: .bold))
            .padding(.top, 10)
        }
    }
}

/// Decodes an image document off the main actor when it's shown, so loaded rows never hold decoded images.
private struct ImageStage: View {
    let url: URL
    let zoom: PreviewZoom

    @State private var image: (url: URL, image: CGImage, size: CGSize)?

    var body: some View {
        Group {
            if let image, image.url == url {
                ZoomableStage(zoom: zoom, contentSize: image.size) { _ in
                    Image(decorative: image.image, scale: 1)
                        .resizable()
                        .background(.white)
                }
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            if let loaded = await DocumentReader.loadImage(at: url) {
                image = (url, loaded.image, loaded.size)
            }
        }
    }
}

private extension Color {
    static let paperMuted = Color(red: 0.60, green: 0.60, blue: 0.63)
    static let paperRule = Color(red: 0.90, green: 0.90, blue: 0.92)
}

private extension Text {
    func brand() -> some View {
        font(.system(size: 12, weight: .bold)).tracking(-0.1)
    }

    func kicker() -> some View {
        textCase(.uppercase)
            .font(.system(size: 8, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Color.paperMuted)
    }
}

// MARK: - Inspector

private struct InspectorView: View {
    let folder: DocumentFolder
    let doc: Document
    let onEditValues: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                Divider()
                if folder.isInbox {
                    section("File") {
                        row("File type", doc.kind)
                        row("Pages", doc.pages.map(String.init))
                        row("MD5", doc.md5, monospaced: true)
                        row("Added", doc.formattedAdded)
                        row("Size", doc.formattedSize)
                    }
                } else {
                    section("Extracted Fields", systemImage: "tag",
                            onEdit: folder.fields.isEmpty ? nil : onEditValues) {
                        ForEach(folder.fields) { field in
                            row(field.label, doc[field.key], accent: field.type.isNumeric)
                        }
                    }
                    Divider()
                    section("General") {
                        row("Kind", doc.kind)
                        row("Size", doc.formattedSize)
                    }
                }
            }
        }
        .background(.background.secondary)
    }

    private var header: some View {
        Text(doc.name)
            .font(.system(size: 13, weight: .semibold))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func section(_ title: String, systemImage: String? = nil, onEdit: (() -> Void)? = nil,
                         @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Group {
                    if let systemImage {
                        Label(title, systemImage: systemImage)
                    } else {
                        Text(title)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                Spacer()
                if let onEdit {
                    Button("Edit", action: onEdit)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                        .font(.system(size: 11, weight: .medium))
                        .help("Edit the extracted values")
                }
            }
            .padding(.bottom, 1)
            rows()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func row(_ key: String, _ value: String?, accent: Bool = false, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value ?? "—")
                .fontWeight(.medium)
                .font(monospaced ? .system(size: 10.5, design: .monospaced) : nil)
                .foregroundStyle(accent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}
