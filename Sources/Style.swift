// The page Daymare is drawn as. In the house look (Tianmu): OLED black, the IBM VGA 8x16 pixel font,
// grey inks, clickable plain text. In the other looks (Look.swift) the same page wears that era's
// colours and type, and its clickable words become buttons.

import AppKit

let pixelFontName = "PxPlus_IBM_VGA_8x16"
/// The layout unit the looks' fonts are sized against.
let uiSize: CGFloat = 16

func pixelFont(_ size: CGFloat = Prefs.fontSize) -> NSFont { uiFont(size) }

/// The house roles of colour, resolved in the current look.
enum Ink {
    static var text: NSColor { Palette.current.text }
    static var soft: NSColor { Palette.current.soft }
    static var name: NSColor { Palette.current.name }
    static var dim: NSColor { Palette.current.dim }
    static var faint: NSColor { Palette.current.faint }
    static var line: NSColor { Palette.current.line }
    static var ember: NSColor { Palette.current.ember }
    static var window: NSColor { Palette.current.window }
}

extension NSAttributedString.Key {
    /// Draw this run as a button (the boxed looks).
    static let dmButton = NSAttributedString.Key("dmButton")
    /// This line is the selected row: a highlight bar the width of the page.
    static let dmRow = NSAttributedString.Key("dmRow")
}

enum Prefs {
    private static let d = UserDefaults.standard

    /// Whole-pixel steps of the VGA font only (16, 24, 32), so it stays crisp.
    static var fontSize: CGFloat {
        get { let v = d.double(forKey: "fontSize"); return v >= 16 ? v : 16 }
        set { d.set(newValue, forKey: "fontSize") }
    }
    /// The velvet room shows unless hidden.
    static var showVelvet: Bool {
        get { !d.bool(forKey: "hideVelvet") }
        set { d.set(!newValue, forKey: "hideVelvet") }
    }
    /// If the room turns with your head instead of staying put, flip this.
    static var flipYaw: Bool {
        get { d.bool(forKey: "flipYaw") }
        set { d.set(newValue, forKey: "flipYaw") }
    }
    static var flipPitch: Bool {
        get { d.bool(forKey: "flipPitch") }
        set { d.set(newValue, forKey: "flipPitch") }
    }
    static var lastSession: String {
        get { d.string(forKey: "lastSession") ?? "" }
        set { d.set(newValue, forKey: "lastSession") }
    }
}

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Daymare")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var sessions: URL { support.appendingPathComponent("Sessions") }
    static var journal: URL { support.appendingPathComponent("journal.txt") }
}

/// 0:07 / 3:04 / 1:02:03
func timecode(_ t: Double) -> String {
    let t = min(360_000, max(0, t.isFinite ? t : 0))
    let whole = Int(t)
    let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// `[████████░░░░░░░░]` in CP437 blocks, which the VGA font draws natively.
func blockBar(_ fraction: Double, width: Int = 20) -> String {
    let n = Int((min(1, max(0, fraction)) * Double(width)).rounded())
    return "[" + String(repeating: "█", count: n) + String(repeating: "░", count: width - n) + "]"
}

/// Builds attributed lines in the pixel font, with `daymare://` links for clickable words.
struct Lines {
    private(set) var text = NSMutableAttributedString()
    let size: CGFloat

    init(size: CGFloat = Prefs.fontSize) { self.size = size }

    mutating func add(_ s: String, _ color: NSColor = Ink.text, link: String? = nil, tip: String? = nil, bold: Bool = false, extra: [NSAttributedString.Key: Any] = [:]) {
        var a: [NSAttributedString.Key: Any] = [.font: bold && Look.current != .tianmu ? uiFont(size, bold: true) : pixelFont(size), .foregroundColor: color]
        // Geneva has no bold on today's Macs: thicken the strokes, as Sooth's Platinum titles do.
        if bold && Look.current == .platinum { a[.strokeWidth] = -2.5; a[.strokeColor] = color }
        a.merge(extra) { $1 }
        if let link, let url = URL(string: "daymare://" + link) {
            a[.link] = url
            a[.cursor] = NSCursor.pointingHand
        }
        if let tip { a[.toolTip] = tip }
        text.append(NSAttributedString(string: s, attributes: a))
    }

    /// `[word]` as a link: brackets dim, word bright. The boxed looks draw it as a button instead.
    mutating func button(_ word: String, _ link: String, color: NSColor = Ink.soft, tip: String? = nil) {
        guard Look.current != .tianmu else {
            add("[", Ink.dim)
            add(word, color, link: link, tip: tip)
            add("]", Ink.dim)
            return
        }
        // Thin spaces either side give the label room inside its box.
        let ink: NSColor = Look.current == .native || Look.current == .bevel || Look.current == .platinum ? Ink.text : color
        add("\u{2002}" + Look.current.cap(word) + "\u{2002}", color == Ink.ember ? Ink.ember : ink, link: link, tip: tip,
            extra: [.dmButton: true])
    }

    mutating func newline() { add("\n") }
}

/// Draws the look's parts behind the text: a bar behind the selected row, a button behind each `[word]`.
final class LookLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let tc = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.dmRow, in: chars) { v, r, _ in
            guard v != nil else { return }
            let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            // Every line the row wraps onto.
            var line = CGRect.null
            enumerateLineFragments(forGlyphRange: g) { rect, _, _, _, _ in line = line.union(rect) }
            guard !line.isNull else { return }
            line.origin.x = origin.x; line.origin.y += origin.y
            line.size.width = tc.size.width
            let bar = line.insetBy(dx: 6, dy: 0)
            switch Look.current {
            case .tianmu: NSColor(white: 0.1, alpha: 1).setFill(); bar.fill()
            case .glass: Chrome.gloss(bar, radius: 5, on: true)
            case .native: Palette.current.pick.setFill(); NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5).fill()
            default: Palette.current.pick.setFill(); bar.fill()
            }
        }
        guard Look.current != .tianmu else { return }
        storage.enumerateAttribute(.dmButton, in: chars) { v, r, _ in
            guard v != nil else { return }
            let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            var box = boundingRect(forGlyphRange: g, in: tc)
            box.origin.x += origin.x; box.origin.y += origin.y
            Chrome.button(box.insetBy(dx: 0, dy: -2).integral)
        }
    }
}

/// A plain, scrolling, read-only text pane.
func makeTextPane() -> (NSScrollView, LinkTextView) {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    // TextKit 1 with our own layout manager, which draws the look's buttons and row bar.
    let storage = NSTextStorage()
    let lm = LookLayoutManager()
    storage.addLayoutManager(lm)
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    lm.addTextContainer(container)
    let tv = LinkTextView(frame: .zero, textContainer: container)
    tv.isEditable = false
    tv.isSelectable = false
    tv.drawsBackground = false
    tv.textContainerInset = NSSize(width: 14, height: 10)
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.textContainer?.widthTracksTextView = true
    tv.linkTextAttributes = [:]
    scroll.documentView = tv
    return (scroll, tv)
}

/// The suite window: black, no title, content under the titlebar (other looks dress it their way).
func makeSuiteWindow(_ size: NSSize, autosave: String) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                     backing: .buffered, defer: false)
    dressWindow(w)
    w.isReleasedWhenClosed = false
    if !autosave.isEmpty {
        if !w.setFrameUsingName(autosave) { w.center() }
        w.setFrameAutosaveName(autosave)
    } else {
        w.center()
    }
    return w
}
