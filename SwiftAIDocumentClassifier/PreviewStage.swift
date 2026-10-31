import PDFKit
import SwiftUI

// MARK: - Zoom model

/// Zoom state shared by the preview stage, its floating controls and the View menu commands.
@Observable
final class PreviewZoom {
    enum Mode: Equatable {
        case fit
        case scale(CGFloat)
    }

    static let range: ClosedRange<CGFloat> = 0.1...8
    static let steps: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8]

    var mode = Mode.fit
    /// The scale actually on screen, reported back by the stage. Resolves `.fit` to a number.
    var scale: CGFloat = 1

    var canZoomIn: Bool { scale < Self.range.upperBound * 0.99 }
    var canZoomOut: Bool { scale > Self.range.lowerBound * 1.01 }

    func zoomIn() { setScale(Self.steps.first { $0 > scale * 1.01 } ?? Self.range.upperBound) }
    func zoomOut() { setScale(Self.steps.last { $0 < scale * 0.99 } ?? Self.range.lowerBound) }
    func zoomToFit() { mode = .fit }
    func setScale(_ newScale: CGFloat) { mode = .scale(Self.clamped(newScale)) }

    static func clamped(_ scale: CGFloat) -> CGFloat {
        min(max(scale, range.lowerBound), range.upperBound)
    }
}

extension FocusedValues {
    @Entry var previewZoom: PreviewZoom?
}

/// View menu items matching Preview's zoom shortcuts.
struct PreviewZoomCommands: Commands {
    @FocusedValue(\.previewZoom) private var zoom

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Actual Size") { zoom?.setScale(1) }
                .keyboardShortcut("0")
            Button("Zoom to Fit") { zoom?.zoomToFit() }
                .keyboardShortcut("9")
            Button("Zoom In") { zoom?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(zoom?.canZoomIn != true)
            Button("Zoom Out") { zoom?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(zoom?.canZoomOut != true)
            Divider()
        }
    }
}

// MARK: - Controls

/// Floating zoom control (and page indicator for PDFs) over the preview stage.
struct PreviewZoomControls: View {
    let zoom: PreviewZoom
    var pageLabel: String?

    var body: some View {
        HStack(spacing: 4) {
            if let pageLabel {
                Text(pageLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                Divider().frame(height: 14)
            }
            Button("Zoom Out", systemImage: "minus.magnifyingglass", action: zoom.zoomOut)
                .disabled(!zoom.canZoomOut)
            Menu {
                Button("Zoom to Fit", action: zoom.zoomToFit)
                Button("Actual Size") { zoom.setScale(1) }
                Divider()
                ForEach(PreviewZoom.steps, id: \.self) { step in
                    Button(Double(step).formatted(.percent)) { zoom.setScale(step) }
                }
            } label: {
                Text(Double(zoom.scale), format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(minWidth: 40)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Zoom")
            Button("Zoom In", systemImage: "plus.magnifyingglass", action: zoom.zoomIn)
                .disabled(!zoom.canZoomIn)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect()
    }
}

// MARK: - Zoomable stage

/// Scrolls and zooms content of a known natural size. `content` receives the scale and must
/// fill `contentSize × scale` — vector pages use `scaledPage`, images just stretch.
struct ZoomableStage<Content: View>: View {
    let zoom: PreviewZoom
    let contentSize: CGSize
    @ViewBuilder let content: (CGFloat) -> Content

    private let margin: CGFloat = 22
    @State private var viewport = CGSize.zero
    @GestureState private var pinch: CGFloat = 1

    private var fitScale: CGFloat {
        guard contentSize.width > 0, contentSize.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        let fit = min((viewport.width - 2 * margin) / contentSize.width,
                      (viewport.height - 2 * margin) / contentSize.height)
        return PreviewZoom.clamped(fit)
    }

    private var baseScale: CGFloat {
        switch zoom.mode {
        case .fit: fitScale
        case .scale(let scale): scale
        }
    }

    var body: some View {
        let scale = PreviewZoom.clamped(baseScale * pinch)
        ScrollView([.horizontal, .vertical]) {
            content(scale)
                .frame(width: contentSize.width * scale, height: contentSize.height * scale, alignment: .topLeading)
                .paperShadow()
                .padding(margin)
                // Centers the page while it is smaller than the viewport.
                .frame(minWidth: viewport.width, minHeight: viewport.height)
        }
        .defaultScrollAnchor(.top)
        // Excludes safe-area insets such as the floating zoom controls, so "fit" stays clear of them.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .simultaneousGesture(
            MagnifyGesture()
                .updating($pinch) { value, pinch, _ in pinch = value.magnification }
                .onEnded { value in zoom.setScale(baseScale * value.magnification) }
        )
        .onChange(of: scale, initial: true) { zoom.scale = scale }
    }
}

extension View {
    /// Scales vector content laid out at `size` so it fills `size × scale`, for `ZoomableStage`.
    func scaledPage(size: CGSize, scale: CGFloat) -> some View {
        frame(width: size.width, height: size.height)
            .scaleEffect(scale, anchor: .topLeading)
    }

    func paperShadow() -> some View {
        shadow(color: .black.opacity(0.18), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.16), radius: 12, y: 8)
    }
}

// MARK: - PDF

/// Continuous, Preview-style PDF scrolling. Zoom follows `zoom`; pinching in the view updates it.
struct PDFStage {
    let url: URL
    let zoom: PreviewZoom
    /// Zero-based index of the page PDFKit considers current.
    @Binding var currentPage: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(zoom: zoom, currentPage: $currentPage)
    }

    private func makePDFView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.minScaleFactor = PreviewZoom.range.lowerBound
        view.maxScaleFactor = PreviewZoom.range.upperBound
        view.autoScales = true
        #if os(macOS)
        view.backgroundColor = .underPageBackgroundColor
        #endif
        context.coordinator.observe(view)
        return view
    }

    private func updatePDFView(_ view: PDFView, context: Context) {
        context.coordinator.zoom = zoom
        context.coordinator.apply(zoom.mode, to: view)
    }

    final class Coordinator: NSObject {
        var zoom: PreviewZoom
        private let currentPage: Binding<Int>
        private var isApplying = false

        init(zoom: PreviewZoom, currentPage: Binding<Int>) {
            self.zoom = zoom
            self.currentPage = currentPage
        }

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: view)
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        }

        func apply(_ mode: PreviewZoom.Mode, to view: PDFView) {
            isApplying = true
            defer { isApplying = false }
            switch mode {
            case .fit:
                if !view.autoScales { view.autoScales = true }
            case .scale(let scale):
                if view.autoScales { view.autoScales = false }
                if abs(view.scaleFactor - scale) > 0.001 { view.scaleFactor = scale }
            }
        }

        // Notifications can arrive while SwiftUI is updating the view, so state changes are deferred.
        @objc private func scaleChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }
            let scale = view.scaleFactor
            let userZoomed = !isApplying && !view.autoScales
            Task {
                zoom.scale = scale
                if userZoomed { zoom.mode = .scale(scale) }
            }
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView,
                  let page = view.currentPage, let index = view.document?.index(for: page) else { return }
            Task { currentPage.wrappedValue = index }
        }
    }
}

#if os(macOS)
extension PDFStage: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { makePDFView(context: context) }
    func updateNSView(_ view: PDFView, context: Context) { updatePDFView(view, context: context) }
}
#else
extension PDFStage: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { makePDFView(context: context) }
    func updateUIView(_ view: PDFView, context: Context) { updatePDFView(view, context: context) }
}
#endif

// MARK: - Preview

#Preview("PDF") {
    @Previewable @State var zoom = PreviewZoom()
    @Previewable @State var page = 0
    PDFStage(url: samplePDF(pages: 3), zoom: zoom, currentPage: $page)
        .background(.quaternary.opacity(0.6))
        .overlay(alignment: .bottom) {
            PreviewZoomControls(zoom: zoom, pageLabel: "Page \(page + 1) of 3").padding(10)
        }
        .frame(width: 760, height: 330)
}

/// A generated A4 PDF with numbered pages, since the sample data has no real PDFs.
private func samplePDF(pages: Int) -> URL {
    let url = URL.temporaryDirectory.appending(path: "preview-sample.pdf")
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return url }
    for number in 1...pages {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.85, alpha: 1))
        for row in 0..<14 {
            context.fill(CGRect(x: 60, y: 640 - row * 36, width: row % 3 == 2 ? 300 : 475, height: 10))
        }
        let title = NSAttributedString(string: "Page \(number)", attributes: [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 36, nil),
        ])
        context.textPosition = CGPoint(x: 60, y: 740)
        CTLineDraw(CTLineCreateWithAttributedString(title), context)
        context.endPDFPage()
    }
    context.closePDF()
    return url
}
