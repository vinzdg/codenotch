import AppKit
import SwiftUI

/// The pill's text, with images in it: a native text view, because a
/// SwiftUI field holds plain text only and an attached image has to sit in
/// the sentence, next to the word it belongs with.
///
/// Each image is a small rounded frame inline in the text. Sending turns it
/// back into the path of its file, at the same place in the message, which
/// is how a terminal writes a dropped file and how Claude Code opens one.
struct DockChatComposer: NSViewRepresentable {
    @ObservedObject var model: DockChatModel
    var fontSize: CGFloat
    var enabled: Bool
    /// Read so a change of look in Settings repaints the text at once; it
    /// kept the old look's colour until something else redrew it.
    @AppStorage(Preferences.codedockLookKey) private var look = "dark"

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder

        let text = ComposerTextView()
        text.delegate = context.coordinator
        text.drawsBackground = false
        text.isRichText = true
        text.importsGraphics = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        // No Writing Tools button, no grey predicted text: macOS hangs its
        // Apple Intelligence swirl on any text view it can, and in a pill
        // this small it read as a Siri button sitting in the message.
        if #available(macOS 15.1, *) { text.writingToolsBehavior = .none }
        text.inlinePredictionType = .no
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        // Drops go to the pill, which turns images into frames; left to the
        // text view, a dropped file came in as its path, or full size.
        text.unregisterDraggedTypes()
        text.onFocusChange = { [weak model] focused in
            DispatchQueue.main.async { model?.editing = focused }
        }
        scroll.documentView = text
        context.coordinator.textView = text
        // A rebuilt view picks up where the last one was, and is not taken
        // for a request to empty it.
        context.coordinator.clearToken = model.clearToken
        context.coordinator.focusToken = model.focusToken
        context.coordinator.replaceToken = model.replaceToken
        context.coordinator.blurToken = model.blurToken
        text.textStorage?.setAttributedString(model.storedText)
        apply(to: text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? ComposerTextView else { return }
        let coordinator = context.coordinator
        apply(to: text)
        text.isEditable = enabled
        // Growing from one line to two kept the scroll of the one-line box,
        // so a long message showed only a fragment of its last line with an
        // empty line under it. Once the new height is laid out, show the end
        // of the text, filling the box rather than scrolled past it.
        DispatchQueue.main.async { Self.settleScroll(scroll, text) }
        if coordinator.clearToken != model.clearToken {
            coordinator.clearToken = model.clearToken
            text.string = ""
            coordinator.publish()
        }
        if coordinator.replaceToken != model.replaceToken {
            coordinator.replaceToken = model.replaceToken
            if let attributed = model.replacementAttributed {
                text.textStorage?.setAttributedString(attributed)
            } else {
                text.string = model.replacement
            }
            text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
            coordinator.publish()
        }
        if coordinator.blurToken != model.blurToken {
            coordinator.blurToken = model.blurToken
            if text.window?.firstResponder === text {
                text.window?.makeFirstResponder(nil)
            }
        }
        if coordinator.focusToken != model.focusToken {
            coordinator.focusToken = model.focusToken
            DispatchQueue.main.async {
                // Key first, then the text: so the cursor is drawn on the
                // very first click.
                text.window?.makeKey()
                text.window?.makeFirstResponder(text)
                (text as? ComposerTextView)?.placeCaret()
            }
        }
        if !model.pendingInserts.isEmpty {
            let inserts = model.pendingInserts
            DispatchQueue.main.async {
                model.pendingInserts = []
                coordinator.insert(inserts)
            }
        }
    }

    /// One line of the pill's text, so the box is always a whole number of
    /// lines and a scrolled message never shows half a line at the top.
    static let lineHeight: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        return ceil(NSLayoutManager().defaultLineHeight(for: font))
    }()

    static func settleScroll(_ scroll: NSScrollView, _ text: NSTextView) {
        guard let manager = text.layoutManager, let container = text.textContainer else { return }
        manager.ensureLayout(for: container)
        // Lines that hold text; the empty line the layout keeps for the
        // cursor after the end is not one. Counted in, an empty box was
        // scrolled a line down, and the cursor drawn out of sight above it.
        var used: CGFloat = lineHeight
        if (text.string as NSString).length > 0 {
            let glyphs = manager.glyphRange(for: container)
            var lines = 0
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in lines += 1 }
            if (text.string as NSString).hasSuffix("\n") { lines += 1 }
            used = CGFloat(max(1, lines)) * lineHeight
        }
        let visible = scroll.contentView.bounds.height
        let size = NSSize(width: scroll.contentSize.width, height: max(used, visible))
        if text.frame.size != size { text.setFrameSize(size) }
        // Scrolled by whole lines, and only when that changes: set again on
        // every key it nudged the text a point each time, which read as a
        // flicker while typing.
        let bottom = max(0, ((used - visible) / lineHeight).rounded(.up) * lineHeight)
        guard abs(scroll.contentView.bounds.origin.y - bottom) > 0.5 else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Every line exactly `lineHeight` tall, image or not: an inline frame is
    /// taller than the letters and pushed its line apart.
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }()

    /// Font, colour and cursor — set only when the look or the size has
    /// changed. Set on every refresh, several times a second while a session
    /// works, they restarted the cursor's blink each time and it flickered.
    private func apply(to text: NSTextView) {
        guard let composer = text as? ComposerTextView else { return }
        let theme = DockTheme.current
        let key = "\(theme.rawValue)|\(fontSize)"
        guard composer.appliedLook != key else { return }
        composer.appliedLook = key
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let colour = theme.nsInk.withAlphaComponent(0.9)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colour,
            .paragraphStyle: Self.paragraph,
        ]
        text.typingAttributes = attributes
        text.defaultParagraphStyle = Self.paragraph
        composer.caretColor = theme.nsInk
        if let storage = text.textStorage, storage.length > 0 {
            let selection = text.selectedRanges
            storage.beginEditing()
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if value == nil { storage.addAttributes(attributes, range: range) }
            }
            storage.endEditing()
            text.selectedRanges = selection
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: DockChatModel
        weak var textView: NSTextView?
        var clearToken = 0
        var focusToken = 0
        var replaceToken = 0
        var blurToken = 0

        init(model: DockChatModel) { self.model = model }

        /// A number key with nothing typed, while a question shows, answers it.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString: String?) -> Bool {
            if model.question != nil, !model.slashOpen, let typed = replacementString,
               typed.count == 1, typed.first?.isNumber == true,
               textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               model.answer(key: typed) {
                return false
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            publish()
            if let text = textView, let scroll = text.enclosingScrollView {
                DispatchQueue.main.async { DockChatComposer.settleScroll(scroll, text) }
            }
        }

        /// Return sends; ⇧Return is a new line.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // With the slash list open, the keys are its: arrows choose,
            // Tab writes the command out, Return runs it, Escape closes it.
            if model.slashOpen {
                switch selector {
                case #selector(NSResponder.moveUp(_:)): model.moveSlash(-1); return true
                case #selector(NSResponder.moveDown(_:)): model.moveSlash(1); return true
                case #selector(NSResponder.insertTab(_:)): model.acceptSlash(send: false); return true
                case #selector(NSResponder.cancelOperation(_:)): model.dismissSlash(); return true
                case #selector(NSResponder.insertNewline(_:)):
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) != true {
                        model.acceptSlash(send: true)
                        return true
                    }
                default: break
                }
            }
            // A question showing: the arrows and Return are its, as they are
            // in the terminal — whatever is typed waits. (A message sent now
            // would land in the terminal's own question list.)
            if model.question != nil, !model.slashOpen {
                switch selector {
                case #selector(NSResponder.moveUp(_:)): model.moveQuestion(-1); return true
                case #selector(NSResponder.moveDown(_:)): model.moveQuestion(1); return true
                case #selector(NSResponder.insertNewline(_:)): model.answerHighlighted(); return true
                default: break
                }
            }
            // Escape closes what is open above the pill first.
            if selector == #selector(NSResponder.cancelOperation(_:)), model.listOpen || model.historyOpen {
                if model.listOpen { model.listOpen = false } else { model.historyOpen = false }
                return true
            }
            // Escape in the pill is Escape in the terminal: it stops a
            // working session, as it would there.
            if selector == #selector(NSResponder.cancelOperation(_:)),
               model.selected?.state == .busy {
                model.stop()
                return true
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                model.send()
            }
            return true
        }

        /// Puts each image into the text where the cursor is, as a frame.
        func insert(_ attachments: [DockChatModel.Attachment]) {
            guard let textView, let storage = textView.textStorage else { return }
            textView.window?.makeFirstResponder(textView)
            var location = textView.selectedRange().location
            if location == NSNotFound || location > storage.length { location = storage.length }
            let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let piece = NSMutableAttributedString()
            for attachment in attachments {
                piece.append(NSAttributedString(attachment: ImageFrame(attachment, font: font)))
                piece.append(NSAttributedString(string: " ", attributes: textView.typingAttributes))
            }
            // A space before the frame too, unless it starts the text or a word
            // already ends there.
            if location > 0 {
                let previous = (storage.string as NSString).character(at: location - 1)
                if let scalar = UnicodeScalar(previous), !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    piece.insert(NSAttributedString(string: " ", attributes: textView.typingAttributes), at: 0)
                }
            }
            storage.insert(piece, at: location)
            textView.setSelectedRange(NSRange(location: location + piece.length, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
            publish()
        }

        /// The text as it is shown, and as it will be sent.
        func publish() {
            guard let storage = textView?.textStorage else { return }
            var outgoing = ""
            var images = 0
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
                if let frame = attributes[.attachment] as? ImageFrame {
                    images += 1
                    outgoing += DockChatModel.escaped(frame.url.path)
                } else {
                    outgoing += (storage.string as NSString).substring(with: range)
                }
            }
            model.storedText = NSAttributedString(attributedString: storage)
            model.composed(display: storage.string, outgoing: outgoing, images: images)
        }
    }
}

/// An image in the text: its own file, drawn as a small rounded frame a
/// little taller than the letters beside it.
final class ImageFrame: NSTextAttachment {
    let url: URL

    init(_ attachment: DockChatModel.Attachment, font: NSFont) {
        url = attachment.url
        super.init(data: nil, ofType: nil)
        // No taller than a line, which every line now is exactly.
        let side = min(ceil(font.capHeight * 2.3), DockChatComposer.lineHeight)
        image = Self.framed(attachment.thumbnail, side: side)
        // Sat on the baseline and centred on the letters' height.
        bounds = CGRect(x: 0, y: font.descender, width: side, height: side)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func framed(_ image: NSImage, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let radius = side * 0.24
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.addClip()
            // Filled, not fitted: a frame, cropped to its square.
            let size = image.size
            let scale = max(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            image.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                  width: drawn.width, height: drawn.height))
            NSColor.white.withAlphaComponent(0.25).setStroke()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: radius, yRadius: radius)
            edge.lineWidth = 1
            edge.stroke()
            return true
        }
    }
}

/// Says when it gains and loses the keyboard, which the pill needs to know
/// to step its ring and status aside.
final class ComposerTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    /// The look and size last applied — see DockChatComposer.apply.
    var appliedLook = ""

    // MARK: - Its own cursor

    /// macOS blinks a text view's cursor only in the active app, and the pill
    /// never makes Codenotch active — that is the point of it — so the system
    /// cursor never showed. This one is drawn here instead: a thin bar at the
    /// insertion point, blinking at the usual rate, while this has the keyboard
    /// in a key window. The system's own is made clear so the two never double.
    /// Typing here means the keyboard is here: this has focus in a window
    /// that is key. Focus alone it kept from launch, and after a click in
    /// another app, so "Chat here…" never came back.
    func reportFocus() {
        let typing = window?.isKeyWindow == true && window?.firstResponder === self
        onFocusChange?(typing)
    }

    /// Drawn by itself rather than through a layer: a layer handed to a
    /// view inside a text view was laid out but never painted.
    private let caretView = CaretView()
    private var blinkTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    var caretColor: NSColor = .white {
        didSet { caretView.color = caretColor }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        insertionPointColor = .clear
        caretView.color = caretColor
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.placeCaret()
                    self.reportFocus()
                }
            })
        }
        placeCaret()
    }

    /// Where the insertion point is, and whether to show it.
    func placeCaret() {
        let showing = window?.isKeyWindow == true && window?.firstResponder === self
            && selectedRange().length == 0
        guard showing else {
            caretView.isHidden = true
            blinkTimer?.invalidate()
            blinkTimer = nil
            return
        }
        // Where the text system itself says the insertion point is on
        // screen — the rectangle it gives input methods — brought back into
        // the scroll view. Worked out by hand from the layout, it came out a
        // line off whenever the box had scrolled.
        let height = DockChatComposer.lineHeight
        let host: NSView = enclosingScrollView ?? self
        if caretView.superview !== host {
            caretView.removeFromSuperview()
            host.addSubview(caretView, positioned: .above, relativeTo: nil)
        }
        let onScreen = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 0),
                                 actualRange: nil)
        guard let window else {
            caretView.isHidden = true
            return
        }
        var rect: NSRect
        if onScreen == .zero || (string as NSString).length == 0 {
            // Nothing typed: the start of the first line showing.
            let visible = enclosingScrollView?.contentView.bounds.height ?? height
            rect = NSRect(x: 0, y: host.isFlipped ? 0 : visible - height, width: 1.5, height: height)
        } else {
            rect = host.convert(window.convertFromScreen(onScreen), from: nil)
        }
        rect.size.width = 1.5
        // Centred on the line, at the line's height less a point each end.
        rect.origin.y = rect.midY - (height - 2) / 2
        rect.size.height = height - 2
        caretView.isHidden = !host.bounds.insetBy(dx: -2, dy: -2).intersects(rect)
        caretView.frame = rect
        if blinkTimer == nil, !caretView.isHidden { blink() }
    }

    /// On for about half a second, off for half, starting on, as the system's does.
    private func blink() {
        caretView.isHidden = false
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.caretView.isHidden.toggle()
            }
        }
    }

    /// Typing or moving restarts the blink on, as the system's does.
    private func restartBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        placeCaret()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        restartBlink()
    }

    override func didChangeText() {
        super.didChangeText()
        restartBlink()
    }

    override func layout() {
        super.layout()
        placeCaret()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            reportFocus()
            // On the first click the window becomes key only after this, and
            // the layout may not be ready: placed now and again just after.
            DispatchQueue.main.async { self.restartBlink() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.restartBlink() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.restartBlink() }
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            DispatchQueue.main.async { self.reportFocus() }
            DispatchQueue.main.async { self.placeCaret() }
        }
        return resigned
    }
}

/// A plain filled bar — the pill's own text cursor.
final class CaretView: NSView {
    var color: NSColor = .white { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 0.75, yRadius: 0.75).fill()
    }
}
