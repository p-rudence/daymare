// A read-only text view whose links are handled on mouse-down, by exact hit-testing.
//
// AppKit's own link click is tracked from mouse-down to mouse-up and then handed the link object;
// if the text is redrawn in between (the page redraws many times a second), that object
// can already be gone, which crashed the app. Taking the click at once avoids the race.

import AppKit

class LinkTextView: NSTextView {
    /// Called with the link under the click (a URL). Return true if handled; otherwise web links open in the browser.
    var onLinkClick: ((URL) -> Bool)?

    /// The character exactly under a point in this view (not the nearest insertion point), if any.
    func characterIndex(under point: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < lm.numberOfGlyphs,
              lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(p) else { return nil }
        let i = lm.characterIndexForGlyph(at: glyph)
        return i < storage.length ? i : nil
    }

    func attribute(_ key: NSAttributedString.Key, under event: NSEvent) -> Any? {
        guard let i = characterIndex(under: convert(event.locationInWindow, from: nil)) else { return nil }
        return textStorage?.attribute(key, at: i, effectiveRange: nil)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let url = attribute(.link, under: event) as? URL {
            if onLinkClick?(url) != true, url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url) }
            return
        }
        super.mouseDown(with: event)
    }
}
