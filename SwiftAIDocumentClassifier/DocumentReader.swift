import CoreGraphics
import ImageIO
import PDFKit
import Vision

/// What the model reads for one document: its text and, for images, the image itself.
struct DocumentText {
    var fileName: String
    var body: String
    /// Images are attached to the prompt as well as OCR'd; the on-device model accepts image input.
    var image: CGImage?
}

/// Gets a document's text on device: the PDF text layer when there is one, Vision OCR otherwise.
enum DocumentReader {
    enum ReadError: LocalizedError {
        case noContent

        var errorDescription: String? { "No readable content was found in this document." }
    }

    /// PDFs with less text than this per page are treated as scans and OCR'd.
    private static let minimumTextPerPage = 40
    /// Scanned PDFs are OCR'd up to this many pages; the model's context can't hold more anyway.
    private static let maximumOCRPages = 4

    static func read(_ doc: Document) async throws -> DocumentText {
        var body = ""
        var image: CGImage?
        switch doc.content {
        case .printed(let page):
            body = page.transcript
        case .pdf(let url):
            guard let pdf = PDFDocument(url: url) else { throw ReadError.noContent }
            body = pdf.string ?? ""
            if body.trimmingCharacters(in: .whitespacesAndNewlines).count < minimumTextPerPage * pdf.pageCount {
                body = try await recognizeText(inPagesOf: pdf)
            }
        case .image(let url):
            image = await loadImage(at: url)?.image
            if let image { body = try await recognizeText(in: image) }
        case .file:
            break
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || image != nil else { throw ReadError.noContent }
        return DocumentText(fileName: doc.name, body: body, image: image)
    }

    /// Decodes an image file with its EXIF orientation applied. `size` is in points, from the image's DPI.
    @concurrent
    static func loadImage(at url: URL) async -> (image: CGImage, size: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        return (image, CGSize(width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi))
    }

    // MARK: OCR

    static func recognizeText(in image: CGImage) async throws -> String {
        let observations = try await RecognizeDocumentsRequest().perform(on: image)
        return observations.map(\.document.text.transcript).joined(separator: "\n")
    }

    private static func recognizeText(inPagesOf pdf: PDFDocument) async throws -> String {
        var pages: [String] = []
        for index in 0..<min(pdf.pageCount, maximumOCRPages) {
            guard let page = pdf.page(at: index), let image = render(page) else { continue }
            pages.append(try await recognizeText(in: image))
        }
        return pages.joined(separator: "\n\n")
    }

    /// Rasterizes a page with its long side at ~2000 px, enough for reliable OCR.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 2000 / max(bounds.width, bounds.height, 1)
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}

extension PrintedPage {
    /// The text printed on a sample page, in reading order (matches what `DocumentPreview` draws).
    var transcript: String {
        let total: (String) -> [String] = { label in amount.map { ["\(label) \($0)"] } ?? [] }
        let lines: [String] = switch style {
        case .invoice: [from, "Tax Invoice", date] + self.lines + total("Amount Due")
        case .quote: [from, "Quotation", date] + self.lines + total("Total")
        case .receipt: [from, date] + self.lines + total("TOTAL")
        case .letter, .contract: [from, date] + [to, subject, paragraph].compactMap { $0 }
        }
        return lines.joined(separator: "\n")
    }
}
