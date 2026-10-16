// The first thing Daymare shows: you're an adult (18+), and pick a look. View ▸ Look ▸ Choose… brings
// the looks back; the age question is asked once.

import AppKit

final class LookPicker: NSWindowController, NSWindowDelegate {
    private static var open: LookPicker?
    private var choice = Look.current
    private var rows: [LookRow] = []
    private let preview = NSImageView()
    private let use = NSButton(title: "", target: nil, action: nil)
    private let adult = NSButton(checkboxWithTitle: "I'm 18 or older", target: nil, action: nil)
    private var done: (() -> Void)?

    /// Asked once, on the first launch.
    static var confirmedAdult: Bool {
        get { UserDefaults.standard.bool(forKey: "confirmedAdult") }
        set { UserDefaults.standard.set(newValue, forKey: "confirmedAdult") }
    }

    /// Show the picker; `done` runs once a look is chosen (or the window is closed, keeping the current one).
    static func show(done: (() -> Void)? = nil) {
        if let p = open { p.window?.makeKeyAndOrderFront(nil); return }
        let p = LookPicker()
        p.done = done
        open = p
        p.window?.center()
        p.showWindow(nil)
        p.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    init() {
        let w = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(white: 0.06, alpha: 1)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.onKey = { [weak self] e in self?.key(e) ?? false }
        w.contentView = Backdrop()
        build()
        select(choice)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Welcome to Daymare")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.textColor = .white
        let sub = NSTextField(wrappingLabelWithString: "Trance made only of sound. Pick a look; everything works the same in each, and View ▸ Look changes it any time.")
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = NSColor(white: 0.62, alpha: 1)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        for l in Look.allCases {
            let r = LookRow(look: l) { [weak self] in self?.select(l) }
            r.onDouble = { [weak self] in self?.select(l); self?.confirm() }
            rows.append(r)
            list.addArrangedSubview(r)
            r.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }

        preview.imageScaling = .scaleProportionallyUpOrDown
        // The picture fits the space it's given; it never pushes the list aside.
        for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            preview.setContentCompressionResistancePriority(.init(1), for: o)
            preview.setContentHuggingPriority(.init(1), for: o)
        }
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true
        preview.layer?.borderWidth = 1
        preview.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        use.bezelStyle = .push
        use.controlSize = .large
        use.keyEquivalent = "\r"
        use.target = self
        use.action = #selector(confirmAction)

        let credit = NSTextField(wrappingLabelWithString: "Daymare is for adults: its velvet trances are made to play during sex or solo play. Use headphones at a gentle volume, never while driving.")
        credit.font = .systemFont(ofSize: 11)
        credit.textColor = NSColor(white: 0.5, alpha: 1)
        adult.attributedTitle = NSAttributedString(string: "I'm 18 or older", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                                                         .foregroundColor: NSColor.white])
        adult.target = self
        adult.action = #selector(adultChanged)
        adult.state = LookPicker.confirmedAdult ? .on : .off
        adult.isHidden = LookPicker.confirmedAdult

        for v in [title, sub, list, preview, use, credit, adult] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.widthAnchor.constraint(equalToConstant: 300),
            list.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 22),
            list.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            list.widthAnchor.constraint(equalToConstant: 300),
            credit.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            credit.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            credit.widthAnchor.constraint(equalToConstant: 300),
            adult.trailingAnchor.constraint(equalTo: use.leadingAnchor, constant: -16),
            adult.centerYAnchor.constraint(equalTo: use.centerYAnchor),

            preview.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 28),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            preview.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -12),
            preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 0.625),
            use.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            use.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
        ])
    }

    private func image(_ l: Look) -> NSImage? {
        Bundle.main.url(forResource: l.rawValue, withExtension: "jpg", subdirectory: "Looks").flatMap(NSImage.init(contentsOf:))
    }

    private func select(_ l: Look) {
        choice = l
        for r in rows { r.on = r.look == l }
        preview.image = image(l)
        use.title = "Use \(l.title)"
        use.isEnabled = adult.state == .on
    }

    @objc private func adultChanged() { use.isEnabled = adult.state == .on }

    @objc private func confirmAction() { confirm() }

    private func confirm() {
        guard adult.state == .on else { NSSound.beep(); return }
        LookPicker.confirmedAdult = true
        Look.choose(choice)
        window?.close()
    }

    private func key(_ e: NSEvent) -> Bool {
        let all = Look.allCases
        guard let i = all.firstIndex(of: choice) else { return false }
        switch e.keyCode {
        case 125: select(all[min(all.count - 1, i + 1)]); return true   // ↓
        case 126: select(all[max(0, i - 1)]); return true               // ↑
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        LookPicker.open = nil
        // Closed without saying 18+ on the first launch: Daymare doesn't open.
        guard LookPicker.confirmedAdult else { NSApp.terminate(nil); return }
        if !Look.chosen { Look.choose(Look.current) }
        let d = done
        done = nil
        d?()
    }
}

/// The picker's ground, drawn (not just the window's colour) so it's the same in every rendering.
private final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor(white: 0.06, alpha: 1).setFill(); bounds.fill() }
}

/// A window that offers its keys (arrows) to a closure first.
private final class KeyWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with e: NSEvent) { if onKey?(e) != true { super.keyDown(with: e) } }
}

/// One look in the list: its name and a line about it.
private final class LookRow: NSView {
    let look: Look
    var on = false { didSet { needsDisplay = true; name.textColor = on ? .white : NSColor(white: 0.82, alpha: 1) } }
    var onDouble: (() -> Void)?
    private let click: () -> Void
    private let name = NSTextField(labelWithString: "")

    init(look: Look, click: @escaping () -> Void) {
        self.look = look
        self.click = click
        super.init(frame: .zero)
        name.stringValue = look.title
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        let blurb = NSTextField(wrappingLabelWithString: look.blurb)
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = NSColor(white: 0.6, alpha: 1)
        let s = NSStackView(views: [name, blurb])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 2
        s.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(equalTo: bottomAnchor),
            s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurb.widthAnchor.constraint(equalToConstant: 272),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard on else { return }
        NSColor(white: 1, alpha: 0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        NSColor(white: 1, alpha: 0.16).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
    }

    /// The whole row is one target: clicks on its name or blurb belong to the row, not the labels.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { onDouble?() } else { click() }
    }
}
