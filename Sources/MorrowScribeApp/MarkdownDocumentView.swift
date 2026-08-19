import AppKit
import Markdown
import SwiftUI

/// Native text-system host used for both raw Markdown and preview rendering.
/// Keeping the scroll view and text layout manager alive avoids SwiftUI re-laying out a
/// large selectable `Text` every time a live transcript appends content.
struct MarkdownDocumentView: NSViewRepresentable {
    let markdown: String
    let preview: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MarkdownScrollView {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        let scrollView = MarkdownScrollView(frame: .zero)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.update(scrollView: scrollView, markdown: markdown, preview: preview)
        return scrollView
    }

    func updateNSView(_ scrollView: MarkdownScrollView, context: Context) {
        context.coordinator.update(scrollView: scrollView, markdown: markdown, preview: preview)
    }

    @MainActor
    final class Coordinator {
        private var previousMarkdown = ""
        private var previousPreview: Bool?
        private var hasRendered = false

        func update(scrollView: MarkdownScrollView, markdown: String, preview: Bool) {
            guard let textView = scrollView.documentView as? NSTextView else { return }

            let modeChanged = previousPreview != preview
            let contentChanged = previousMarkdown != markdown
            if !modeChanged, !contentChanged {
                return
            }

            let viewportHeight = scrollView.contentView.bounds.height
            let oldDocumentHeight = textView.frame.height
            let oldOffset = scrollView.contentView.bounds.origin.y
            let oldScrollableHeight = max(1, oldDocumentHeight - viewportHeight)
            let oldFraction = min(1, max(0, oldOffset / oldScrollableHeight))
            let wasPinnedToBottom = hasRendered && oldDocumentHeight > viewportHeight && oldOffset >= oldScrollableHeight - 12

            if !preview,
               previousPreview == false,
               markdown.hasPrefix(previousMarkdown),
               !previousMarkdown.isEmpty {
                let suffix = String(markdown.dropFirst(previousMarkdown.count))
                textView.textStorage?.append(PlannerMarkdownRenderer.rawAttributedString(suffix))
            } else {
                let attributed = preview
                    ? PlannerMarkdownRenderer.render(markdown)
                    : PlannerMarkdownRenderer.rawAttributedString(markdown)
                textView.textStorage?.setAttributedString(attributed)
            }

            previousMarkdown = markdown
            previousPreview = preview
            hasRendered = true
            scrollView.invalidateDocumentSize()
            scrollView.sizeDocumentView()

            let newDocumentHeight = textView.frame.height
            let newScrollableHeight = max(0, newDocumentHeight - viewportHeight)
            let targetY: CGFloat
            if wasPinnedToBottom {
                targetY = newScrollableHeight
            } else if modeChanged {
                targetY = oldFraction * newScrollableHeight
            } else {
                targetY = min(oldOffset, newScrollableHeight)
            }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

final class MarkdownScrollView: NSScrollView {
    private var documentSizeInvalidated = true
    private var lastSizedViewport = NSSize(width: -1, height: -1)

    override func layout() {
        super.layout()
        sizeDocumentView()
    }

    func invalidateDocumentSize() {
        documentSizeInvalidated = true
    }

    func sizeDocumentView() {
        guard let textView = documentView as? NSTextView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }

        let viewport = contentView.bounds.size
        let viewportChanged = abs(viewport.width - lastSizedViewport.width) > 0.5 ||
            abs(viewport.height - lastSizedViewport.height) > 0.5
        guard documentSizeInvalidated || viewportChanged else { return }

        let width = max(1, viewport.width)
        let minimumHeight = max(1, viewport.height)
        let horizontalInsets = textView.textContainerInset.width * 2
        let containerWidth = max(1, width - horizontalInsets)

        textView.minSize = NSSize(width: 0, height: minimumHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textContainer.widthTracksTextView = false
        textContainer.containerSize = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)

        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let documentHeight = max(minimumHeight, ceil(usedHeight + textView.textContainerInset.height * 2))
        let targetFrame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        if textView.frame != targetFrame {
            textView.frame = targetFrame
        }
        lastSizedViewport = viewport
        documentSizeInvalidated = false
    }
}

/// Mirrors Morrow Planner's Markdown rendering contract: the parser produces semantic runs
/// (body/headings/quote/code/table/separator plus inline emphasis/link state), and AppKit turns
/// those runs into a selectable attributed document. The parser is Swift Markdown's cmark-gfm
/// implementation, so tables, strikethrough and task-list nodes follow the same GFM family of
/// semantics as Planner's pulldown-cmark renderer.
enum PlannerMarkdownRenderer {
    private enum RunStyle: Equatable {
        case body
        case heading(Int)
        case quote
        case code
        case table
        case separator
    }

    private struct MarkdownRun: Equatable {
        var text: String
        var style: RunStyle
        var bold: Bool
        var italic: Bool
        var strikethrough: Bool
        var link: String?
    }

    private struct InlineState {
        var style: RunStyle = .body
        var boldDepth = 0
        var italicDepth = 0
        var strikethroughDepth = 0
        var link: String?
        var quoteDepth = 0
    }

    private struct ListState {
        var nextNumber: UInt?
    }

    static func render(_ markdown: String) -> NSAttributedString {
        let document = Document(parsing: markdown)
        var walker = RunBuilder()
        walker.visit(document)
        return attributedString(from: walker.finishedRuns())
    }

    static func rawAttributedString(_ markdown: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return NSAttributedString(
            string: markdown,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private struct RunBuilder: MarkupWalker {
        var runs: [MarkdownRun] = []
        var state = InlineState()
        var lists: [ListState] = []
        var listItemDepth = 0
        var inTableHead = false

        mutating func visitHeading(_ heading: Heading) {
            let previousStyle = state.style
            state.style = .heading(heading.level)
            descendInto(heading)
            append("\n\n")
            state.style = state.quoteDepth > 0 ? .quote : previousStyle
        }

        mutating func visitParagraph(_ paragraph: Paragraph) {
            descendInto(paragraph)
            append(listItemDepth > 0 ? "\n" : "\n\n")
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            let previousStyle = state.style
            state.quoteDepth += 1
            if state.style == .body { state.style = .quote }
            append("▎ ")
            descendInto(blockQuote)
            append("\n")
            state.quoteDepth = max(0, state.quoteDepth - 1)
            state.style = state.quoteDepth > 0 ? .quote : previousStyle
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            let previousStyle = state.style
            state.style = .code
            if let language = codeBlock.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
                append("\(language)\n")
            }
            append(codeBlock.code)
            append("\n\n")
            state.style = state.quoteDepth > 0 ? .quote : previousStyle
        }

        mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
            let wasRoot = lists.isEmpty
            lists.append(ListState(nextNumber: nil))
            descendInto(unorderedList)
            lists.removeLast()
            if wasRoot { append("\n") }
        }

        mutating func visitOrderedList(_ orderedList: OrderedList) {
            let wasRoot = lists.isEmpty
            lists.append(ListState(nextNumber: orderedList.startIndex))
            descendInto(orderedList)
            lists.removeLast()
            if wasRoot { append("\n") }
        }

        mutating func visitListItem(_ listItem: ListItem) {
            let depth = max(0, lists.count - 1)
            let indent = String(repeating: "    ", count: depth)
            var marker: String
            if let index = lists.indices.last, let number = lists[index].nextNumber {
                marker = "\(number). "
                lists[index].nextNumber = number + 1
                if let checkbox = listItem.checkbox {
                    marker += checkbox == .checked ? "☑ " : "☐ "
                }
            } else if let checkbox = listItem.checkbox {
                marker = checkbox == .checked ? "☑ " : "☐ "
            } else {
                marker = "• "
            }

            append(indent + marker)
            listItemDepth += 1
            descendInto(listItem)
            listItemDepth = max(0, listItemDepth - 1)
            append("\n")
        }

        mutating func visitEmphasis(_ emphasis: Emphasis) {
            state.italicDepth += 1
            descendInto(emphasis)
            state.italicDepth = max(0, state.italicDepth - 1)
        }

        mutating func visitStrong(_ strong: Strong) {
            state.boldDepth += 1
            descendInto(strong)
            state.boldDepth = max(0, state.boldDepth - 1)
        }

        mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
            state.strikethroughDepth += 1
            descendInto(strikethrough)
            state.strikethroughDepth = max(0, state.strikethroughDepth - 1)
        }

        mutating func visitLink(_ link: Markdown.Link) {
            let previousLink = state.link
            state.link = link.destination
            descendInto(link)
            state.link = previousLink
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            let previousStyle = state.style
            state.style = .code
            append(inlineCode.code)
            state.style = previousStyle
        }

        mutating func visitText(_ text: Markdown.Text) {
            var runState = state
            if inTableHead { runState.boldDepth += 1 }
            append(text.string, using: runState)
        }

        mutating func visitSoftBreak(_ softBreak: SoftBreak) {
            append("\n")
        }

        mutating func visitLineBreak(_ lineBreak: LineBreak) {
            append("\n")
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            let previousStyle = state.style
            state.style = .separator
            append("────────────\n")
            state.style = previousStyle
        }

        mutating func visitTable(_ table: Markdown.Table) {
            let previousStyle = state.style
            state.style = .table
            descendInto(table)
            append("\n")
            state.style = previousStyle
        }

        mutating func visitTableHead(_ tableHead: Markdown.Table.Head) {
            let previousStyle = state.style
            state.style = .table
            inTableHead = true
            descendInto(tableHead)
            append("\n")
            inTableHead = false
            state.style = previousStyle
        }

        mutating func visitTableRow(_ tableRow: Markdown.Table.Row) {
            descendInto(tableRow)
            append("\n")
        }

        mutating func visitTableCell(_ tableCell: Markdown.Table.Cell) {
            descendInto(tableCell)
            append("\t")
        }

        mutating func visitHTMLBlock(_ html: HTMLBlock) {
            // Keep raw HTML inert, matching Planner's preview safety behavior.
        }

        mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
            // Keep raw HTML inert, matching Planner's preview safety behavior.
        }

        mutating func append(_ text: String) {
            append(text, using: state)
        }

        mutating func append(_ text: String, using state: InlineState) {
            guard !text.isEmpty else { return }
            let run = MarkdownRun(
                text: text,
                style: state.style,
                bold: state.boldDepth > 0,
                italic: state.italicDepth > 0,
                strikethrough: state.strikethroughDepth > 0,
                link: state.link
            )
            if let last = runs.indices.last,
               runs[last].style == run.style,
               runs[last].bold == run.bold,
               runs[last].italic == run.italic,
               runs[last].strikethrough == run.strikethrough,
               runs[last].link == run.link {
                runs[last].text += run.text
            } else {
                runs.append(run)
            }
        }

        mutating func finishedRuns() -> [MarkdownRun] {
            while let lastIndex = runs.indices.last, runs[lastIndex].text.last == "\n" {
                runs[lastIndex].text.removeLast()
                if runs[lastIndex].text.isEmpty { runs.removeLast() }
            }
            return runs
        }
    }

    private static func attributedString(from runs: [MarkdownRun]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for run in runs {
            var font = NSFont.systemFont(ofSize: 15)
            var color = NSColor.labelColor
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3

            switch run.style {
            case .body:
                break
            case .heading(1):
                font = NSFont.systemFont(ofSize: 30, weight: .bold)
            case .heading(2):
                font = NSFont.systemFont(ofSize: 24, weight: .bold)
            case .heading(3):
                font = NSFont.systemFont(ofSize: 20, weight: .semibold)
            case .heading:
                font = NSFont.systemFont(ofSize: 16, weight: .semibold)
            case .quote:
                color = .secondaryLabelColor
                paragraph.headIndent = 18
                paragraph.firstLineHeadIndent = 18
            case .code:
                font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
                paragraph.headIndent = 12
                paragraph.firstLineHeadIndent = 12
            case .table:
                font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            case .separator:
                color = .separatorColor
            }

            var traits: NSFontTraitMask = []
            if run.bold { traits.insert(.boldFontMask) }
            if run.italic { traits.insert(.italicFontMask) }
            if !traits.isEmpty {
                font = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if run.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link, let url = URL(string: link) {
                attributes[.link] = url
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            output.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return output
    }
}
