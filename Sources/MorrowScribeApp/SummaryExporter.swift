import AppKit
import CoreText
import Foundation
import UniformTypeIdentifiers

enum SummaryExportFormat {
    case markdown
    case pdf

    var contentType: UTType {
        switch self {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .pdf: .pdf
        }
    }

    var filenameExtension: String {
        switch self {
        case .markdown: "md"
        case .pdf: "pdf"
        }
    }
}

enum SummaryExporter {
    @MainActor
    static func copy(markdown: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }

    @MainActor
    static func export(
        markdown: String,
        suggestedBaseName: String,
        format: SummaryExportFormat
    ) throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(safeBaseName(suggestedBaseName))-summary.\(format.filenameExtension)"
        panel.title = "Export Summary"

        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        switch format {
        case .markdown:
            try markdown.write(to: destination, atomically: true, encoding: .utf8)
        case .pdf:
            try writePDF(markdown: markdown, to: destination)
        }
        return true
    }

    private static func safeBaseName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "meeting" : trimmed
        let invalid = CharacterSet(charactersIn: "/:\\")
        let components = source.components(separatedBy: invalid)
        let joined = components.joined(separator: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writePDF(markdown: String, to destination: URL) throws {
        let attributed = PlannerMarkdownRenderer.render(markdown)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)

        // US Letter at 72 points/inch. The renderer is intentionally independent of the
        // current window size so exports remain stable and printable.
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let margin: CGFloat = 54
        let bodyRect = CGRect(
            x: margin,
            y: margin,
            width: mediaBox.width - margin * 2,
            height: mediaBox.height - margin * 2
        )
        var range = CFRange(location: 0, length: 0)

        repeat {
            context.beginPDFPage(nil)
            context.textMatrix = .identity

            let path = CGMutablePath()
            path.addRect(bodyRect)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, context)

            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()

            guard visible.length > 0 else { break }
            range.location += visible.length
        } while range.location < attributed.length

        context.closePDF()
    }
}
