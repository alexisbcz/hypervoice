import AppKit
import SwiftUI

/// What the speaker list and the Insert menu do to the script, through the editor so each change can be undone.
@Observable
final class ScriptEditorProxy {
    @ObservationIgnored fileprivate weak var textView: ScriptTextView?

    /// Puts text at the insertion point, with a space before it if it would touch a word.
    func insert(_ snippet: String) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let string = textView.string as NSString
        let needsSpace = range.location > 0 && !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: range.location - 1)) ?? " ")
        textView.replace(range, with: (needsSpace ? " " : "") + snippet)
        textView.window?.makeFirstResponder(textView)
    }

    /// Gives every line `name` speaks to `voice`.
    func recast(_ name: String, to voice: Voice) {
        textView?.recast(name, to: voice, only: nil)
    }
}

/// The script editor: speakers in their voice's color, pauses and sounds set apart, `@` to pick a speaker,
/// and a click on a speaker to change their voice.
struct ScriptEditor: NSViewRepresentable {
    @Binding var text: String
    let proxy: ScriptEditorProxy
    var fontSize: CGFloat
    /// Changes when voices or sounds do, so names that now match are recolored.
    var signature: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let scriptView = ScriptTextView(frame: .zero)
        scriptView.isVerticallyResizable = true
        scriptView.isHorizontallyResizable = false
        scriptView.autoresizingMask = [.width]
        scriptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scriptView.textContainer?.widthTracksTextView = true
        scrollView.documentView = scriptView
        scriptView.isRichText = false
        scriptView.allowsUndo = true
        scriptView.drawsBackground = false
        scriptView.textContainerInset = NSSize(width: 16, height: 20)
        scriptView.isAutomaticQuoteSubstitutionEnabled = false
        scriptView.isAutomaticDashSubstitutionEnabled = false
        scriptView.isAutomaticTextReplacementEnabled = false
        // Speakers are links so a click opens their menu; they keep their own color, not link blue.
        scriptView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        scriptView.delegate = context.coordinator
        scriptView.string = text
        scriptView.fontSize = fontSize
        proxy.textView = scriptView
        context.coordinator.highlight(scriptView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ScriptTextView else { return }
        proxy.textView = textView
        var changed = false
        if textView.string != text {
            textView.string = text
            changed = true
        }
        if textView.fontSize != fontSize || context.coordinator.signature != signature {
            textView.fontSize = fontSize
            context.coordinator.signature = signature
            changed = true
        }
        if changed { context.coordinator.highlight(textView) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptEditor
        var signature: String

        init(_ parent: ScriptEditor) {
            self.parent = parent
            signature = parent.signature
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ScriptTextView else { return }
            parent.text = textView.string
            highlight(textView)
            if textView.shouldOfferCompletion() {
                DispatchQueue.main.async { textView.complete(nil) }
            }
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            (textView as? ScriptTextView)?.completions(for: charRange) ?? []
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let textView = textView as? ScriptTextView,
                  let url = link as? URL, url.scheme == "hypervoice-speaker" else { return false }
            textView.showSpeakerMenu(at: charIndex)
            return true
        }

        func highlight(_ textView: ScriptTextView) {
            let script = Script(textView.string, library: Library.shared, fallback: nil)
            textView.highlight(script.tokens)
        }
    }
}

final class ScriptTextView: NSTextView {
    var fontSize: CGFloat = 15

    private var baseFont: NSFont { .systemFont(ofSize: fontSize) }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.35
        paragraph.paragraphSpacing = fontSize * 0.3
        return [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    // MARK: - Colors

    func highlight(_ tokens: [Script.Token]) {
        guard let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: whole)
        for token in tokens where NSMaxRange(token.range) <= storage.length {
            switch token.kind {
            case .speaker(let name, let voice):
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: voice.map { Self.color(for: $0.name) } ?? NSColor.systemOrange,
                    .link: URL(string: "hypervoice-speaker:\(token.range.location)")!,
                    .toolTip: voice.map { "\($0.name) · \($0.subtitle) — click to change" } ?? "No voice named \u{201C}\(name)\u{201D}: this speaker is skipped. Click to choose one.",
                ], range: token.range)
                if voice == nil {
                    storage.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                           .underlineColor: NSColor.systemOrange], range: token.range)
                }
            case .pause:
                storage.addAttributes([
                    .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize * 0.88, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                ], range: token.range)
            case .sound(let sound):
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: fontSize * 0.88, weight: .medium),
                    .foregroundColor: sound == nil ? NSColor.systemOrange : NSColor.systemTeal,
                    .backgroundColor: (sound == nil ? NSColor.systemOrange : NSColor.systemTeal).withAlphaComponent(0.12),
                    .toolTip: sound == nil ? "No sound by this name: skipped." : "Plays \(sound!.url.lastPathComponent)",
                ], range: token.range)
            }
        }
        storage.endEditing()
        typingAttributes = baseAttributes
    }

    /// The voice's avatar hue, made readable as text in both light and dark mode.
    static func color(for name: String) -> NSColor {
        let hue = VoiceAvatar.hue(for: name)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hue: hue, saturation: 0.55, brightness: 0.92, alpha: 1)
                : NSColor(hue: hue, saturation: 0.75, brightness: 0.58, alpha: 1)
        }
    }

    // MARK: - Completion

    private enum Context {
        case speaker
        case sound
    }

    /// What's being completed at the insertion point: a speaker after `@` at the start of a line,
    /// or a sound inside `[sound `. The range is the part typed so far.
    private func completionContext() -> (Context, NSRange)? {
        let cursor = selectedRange().location
        let string = self.string as NSString
        let lineStart = string.lineRange(for: NSRange(location: min(cursor, string.length), length: 0)).location
        let before = string.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
        let trimmed = before.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix("@"), !trimmed.dropFirst().contains(where: { ".,!?:".contains($0) }), trimmed.count <= 32 {
            let typed = trimmed.dropFirst().utf16.count
            return (.speaker, NSRange(location: cursor - typed, length: typed))
        }
        if let open = before.range(of: "[sound ", options: [.backwards, .caseInsensitive]), !before[open.upperBound...].contains("]") {
            let typed = before[open.upperBound...].utf16.count
            return (.sound, NSRange(location: cursor - typed, length: typed))
        }
        return nil
    }

    /// Right after typing the `@` that starts a line, or the space of `[sound `.
    func shouldOfferCompletion() -> Bool {
        guard let (_, range) = completionContext(), range.length == 0 else { return false }
        return true
    }

    override var rangeForUserCompletion: NSRange {
        completionContext()?.1 ?? super.rangeForUserCompletion
    }

    func completions(for range: NSRange) -> [String] {
        guard let (context, _) = completionContext() else { return [] }
        let typed = (string as NSString).substring(with: range)
        let names: [String] = switch context {
        case .speaker: Array(NSOrderedSet(array: Library.shared.allVoices.map(\.name))) as? [String] ?? []
        case .sound: Sounds.all.map(\.name)
        }
        return typed.isEmpty ? names : names.filter { $0.range(of: typed, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil }
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        let context = completionContext()?.0
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        // Escape cancels: leave what was typed.
        guard flag, movement != NSCancelTextMovement, let context else { return }
        switch context {
        case .speaker: insertText(" ", replacementRange: selectedRange())
        case .sound: insertText("]", replacementRange: selectedRange())
        }
    }

    // MARK: - Editing

    /// One undoable change.
    func replace(_ range: NSRange, with replacement: String) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + replacement.utf16.count, length: 0))
    }

    /// Renames a speaker to `voice`, on every line they speak, or only the marker at `only`.
    /// Each keeps its form: `@Name` or `Name:`.
    func recast(_ name: String, to voice: Voice, only location: Int?) {
        let script = Script(string, library: Library.shared, fallback: nil)
        let markers = script.tokens.filter { token in
            guard case .speaker(let written, _) = token.kind else { return false }
            return location.map { token.range.location == $0 } ?? (written.caseInsensitiveCompare(name) == .orderedSame)
        }
        guard !markers.isEmpty else { return }
        let string = self.string as NSString
        undoManager?.beginUndoGrouping()
        for marker in markers.reversed() {
            let old = string.substring(with: marker.range)
            let new = old.hasPrefix("@") ? "@\(voice.name)\(old.hasSuffix(":") ? ":" : "")" : "\(voice.name):"
            guard shouldChangeText(in: marker.range, replacementString: new) else { continue }
            textStorage?.replaceCharacters(in: marker.range, with: new)
            didChangeText()
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Change Voice")
    }

    func showSpeakerMenu(at index: Int) {
        let script = Script(string, library: Library.shared, fallback: nil)
        guard let token = script.tokens.first(where: { NSLocationInRange(index, $0.range) }),
              case .speaker(let name, let current) = token.kind else { return }
        let menu = NSMenu()
        let title = NSMenuItem(title: current.map { "\($0.name) · \($0.subtitle)" } ?? "No voice named \u{201C}\(name)\u{201D}", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        Self.addVoices(to: menu, current: current) { [weak self] voice in self?.recast(name, to: voice, only: nil) }
        menu.addItem(.separator())
        let only = NSMenuItem(title: "This Line Only", action: nil, keyEquivalent: "")
        only.submenu = NSMenu()
        Self.addVoices(to: only.submenu!, current: current) { [weak self] voice in self?.recast(name, to: voice, only: token.range.location) }
        menu.addItem(only)

        // Opened by a click, so it drops down from the pointer.
        guard let window else { return }
        menu.popUp(positioning: nil, at: convert(window.mouseLocationOutsideOfEventStream, from: nil), in: self)
    }

    /// Your voices, then each engine's built-in ones in a submenu, with the current one checked.
    static func addVoices(to menu: NSMenu, current: Voice?, choose: @escaping (Voice) -> Void) {
        let library = Library.shared
        if !library.voices.isEmpty {
            let header = NSMenuItem.sectionHeader(title: "My Voices")
            menu.addItem(header)
            for voice in library.voices { menu.addItem(item(voice, current: current, choose: choose)) }
            menu.addItem(.separator())
        }
        for engine in Engine.allCases where !engine.presets.isEmpty {
            let group = NSMenuItem(title: engine.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for preset in engine.presets {
                let voice = Voice.preset(preset, of: engine)
                let entry = item(voice, current: current, choose: choose)
                entry.title = "\(voice.name) — \(preset.language)"
                submenu.addItem(entry)
            }
            group.submenu = submenu
            if current?.isPreset == true, current?.engine == engine { group.state = .mixed }
            menu.addItem(group)
        }
    }

    private static func item(_ voice: Voice, current: Voice?, choose: @escaping (Voice) -> Void) -> NSMenuItem {
        let item = MenuAction.item(voice.name) { choose(voice) }
        item.state = current?.id == voice.id ? .on : .off
        item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [color(for: voice.name)])))
        return item
    }
}

/// Runs a closure for a menu item; the item keeps it alive as its represented object.
private final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }

    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}
