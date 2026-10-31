import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Converts multi-page content to PDF so every paged document scrolls and zooms in the same `PDFStage`.
enum DocumentRendition {
    /// A4, with 72 pt margins, for documents that don't carry their own page size.
    static let paperSize = CGSize(width: 595.28, height: 841.89)
    static let margin: CGFloat = 72

    // MARK: Word-processing documents

    #if os(macOS)
    /// Formats TextKit can read; only macOS can open Word and OpenDocument files.
    static let textDocumentTypes: [(type: UTType, format: NSAttributedString.DocumentType)] = [
        (UTType("org.openxmlformats.wordprocessingml.document"), .officeOpenXML),
        (UTType("com.microsoft.word.doc"), .docFormat),
        (UTType("org.oasis-open.opendocument.text"), .openDocument),
        (.rtf, .rtf),
    ].compactMap { type, format in type.map { ($0, format) } }

    static func textDocumentFormat(for type: UTType?) -> NSAttributedString.DocumentType? {
        guard let type else { return nil }
        return textDocumentTypes.first { type.conforms(to: $0.type) }?.format
    }

    /// Lays the document out on A4 pages with TextKit and draws each page into a PDF.
    static func pdf(fromTextDocument data: Data, format: NSAttributedString.DocumentType) -> Data? {
        guard let text = try? NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil),
              text.length > 0 else { return nil }

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let textRect = CGRect(origin: .zero, size: paperSize).insetBy(dx: margin, dy: margin)

        // One container per page until all glyphs are placed (stop if a page takes nothing, e.g. an oversized image).
        var pages: [NSRange] = []
        var laidOut = 0
        while laidOut < layout.numberOfGlyphs {
            let container = NSTextContainer(size: textRect.size)
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            guard range.length > 0 else { break }
            pages.append(range)
            laidOut = NSMaxRange(range)
        }

        return renderPDF(pageSize: paperSize, pageCount: pages.count) { index, context in
            // TextKit draws in flipped (top-left origin) coordinates.
            context.translateBy(x: 0, y: paperSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawBackground(forGlyphRange: pages[index], at: textRect.origin)
            layout.drawGlyphs(forGlyphRange: pages[index], at: textRect.origin)
            NSGraphicsContext.current = nil
        }
    }
    #endif

    // MARK: Multi-page images

    /// One PDF page per frame of a multi-page TIFF (typical scanner output); nil for single-page images.
    static func pdf(fromMultiPageImage data: Data, type: UTType?) -> Data? {
        guard type?.conforms(to: .tiff) == true,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 1 else { return nil }
        let document = PDFDocument()
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
                  let page = PDFPage(image: PlatformImage(cgImage: image)) else { continue }
            document.insert(page, at: document.pageCount)
        }
        return document.pageCount > 1 ? document.dataRepresentation() : nil
    }

    // MARK: SwiftUI pages

    /// Renders SwiftUI views as vector PDF pages (used for the sample documents).
    static func pdf(pageSize: CGSize, pageCount: Int, @ViewBuilder page: (Int) -> some View) -> Data? {
        let renderers = (0..<pageCount).map { index in
            ImageRenderer(content: page(index).frame(width: pageSize.width, height: pageSize.height))
        }
        return renderPDF(pageSize: pageSize, pageCount: pageCount) { index, context in
            renderers[index].render { _, draw in draw(context) }
        }
    }

    // MARK: PDF context

    private static func renderPDF(pageSize: CGSize, pageCount: Int, drawPage: (Int, CGContext) -> Void) -> Data? {
        guard pageCount > 0 else { return nil }
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            context.saveGState()
            drawPage(index, context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
