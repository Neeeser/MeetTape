import AppKit
import MeetTapeCore
import MeetTapeServices
import SwiftUI

/// What the reader asked for by right-clicking a block.
enum TranscriptParagraphAction: Equatable {
    /// Divide the turn at this moment and give everything after it to someone.
    /// The line named is the one the boundary falls in.
    case split(atSeconds: Double, utteranceID: String)
    /// Give this stretch to someone and leave the words either side alone,
    /// across the lines the selection touched.
    case assign(startSeconds: Double, endSeconds: Double, utteranceIDs: [String])
}

/// One speaker's turn as a paragraph that can be selected, copied and divided.
///
/// An `NSTextView` rather than a `Text`, for one reason: SwiftUI can render a
/// selectable string but cannot say what is selected, and pulling a phrase out
/// to another speaker is a question about the selection. Left-click keeps its
/// ordinary meaning, so copying a quote still works, and the two corrections
/// live on the context menu where a right-click on text is already expected.
struct TranscriptParagraph: NSViewRepresentable {
    var text: String
    var spans: [TranscriptWordSpan]
    var people: [SpeakerDirectoryEntry]
    var onAction: (TranscriptParagraphAction, SpeakerDirectoryEntry?) -> Void
    /// Chosen "New person…", so the panel can ask for a name.
    var onNewPerson: (TranscriptParagraphAction) -> Void

    func makeNSView(context: Context) -> TranscriptTextView {
        let view = TranscriptTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // The container is sized from the width SwiftUI proposes rather than
        // from the view's own frame. A container that tracks the view measures
        // against whatever width it has at that instant, which during the first
        // layout pass is nothing, and the block reports a height of zero.
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        return view
    }

    func updateNSView(_ view: TranscriptTextView, context: Context) {
        if view.string != text {
            view.string = text
            view.invalidateIntrinsicContentSize()
        }
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .labelColor
        view.spans = spans
        view.people = people
        view.onAction = onAction
        view.onNewPerson = onNewPerson
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: TranscriptTextView, context: Context
    ) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

/// The text view behind a block, holding what a click has to be resolved
/// against.
final class TranscriptTextView: NSTextView {
    var spans: [TranscriptWordSpan] = []
    var people: [SpeakerDirectoryEntry] = []
    var onAction: ((TranscriptParagraphAction, SpeakerDirectoryEntry?) -> Void)?
    var onNewPerson: ((TranscriptParagraphAction) -> Void)?

    /// The height this paragraph needs at a given width. Laid out rather than
    /// estimated, because a turn can be one line or twenty.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let manager = layoutManager else { return 0 }
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    /// Wraps at the width it was given, so what is measured is what is drawn.
    override func layout() {
        textContainer?.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        super.layout()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard !spans.isEmpty else { return menu }
        let selection = selectedRange()
        let action: TranscriptParagraphAction
        let title: String
        if selection.length > 0, let range = selectedSpanRange(selection) {
            action = .assign(
                startSeconds: range.start, endSeconds: range.end, utteranceIDs: range.lines
            )
            title = "Assign selection to"
        } else {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            guard let boundary = nearestBoundary(to: index) else { return menu }
            action = .split(atSeconds: boundary.startSeconds, utteranceID: boundary.utteranceID)
            title = "Split here, and this speaker is"
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for person in people {
            submenu.addItem(ClosureMenuItem(title: person.identity.resolvedName) {
                [weak self] in self?.onAction?(action, person)
            })
        }
        if !people.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(ClosureMenuItem(title: "New person…") {
            [weak self] in self?.onNewPerson?(action)
        })
        item.submenu = submenu
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    /// The word boundary nearest a character index, as the moment it starts.
    ///
    /// Nearest rather than the word under the pointer, because the reader is
    /// aiming at the gap between two words and the gap belongs to both.
    func nearestBoundary(to index: Int) -> TranscriptWordSpan? {
        // From the second word on: splitting before the first would leave one
        // piece with nothing in it.
        var best: TranscriptWordSpan?
        var distance = Int.max
        for span in spans.dropFirst() where abs(span.location - index) < distance {
            distance = abs(span.location - index)
            best = span
        }
        return best
    }

    /// The moments a selected range covers, and the lines it touched.
    func selectedSpanRange(_ range: NSRange) -> (start: Double, end: Double, lines: [String])? {
        let touched = spans.filter {
            $0.location < range.location + range.length && range.location < $0.location + $0.length
        }
        guard let first = touched.first, let last = touched.last else { return nil }
        var lines: [String] = []
        for span in touched where lines.last != span.utteranceID {
            lines.append(span.utteranceID)
        }
        return (first.startSeconds, last.endSeconds, lines)
    }
}

/// A menu item that runs a closure, so the menu can be built where the context
/// it needs already is.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
