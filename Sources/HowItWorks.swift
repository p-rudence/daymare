// Help ▸ How Daymare Works: the whole app on one page, in the current look.

import AppKit

enum HowItWorks {
    private static var window: NSWindow?

    static func reset() { window?.orderOut(nil); window = nil }

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let (scroll, tv) = makeTextPane()
        var l = Lines(size: Look.current == .tianmu ? 16 : 16)
        let c = { (s: String) in Look.current.cap(s) }
        func head(_ s: String) { l.newline(); l.add(c(s), Ink.text, bold: true); l.newline() }
        func para(_ s: String) { l.add(c(s), Ink.soft); l.newline() }
        l.add(c("daymare"), Ink.text, bold: true); l.add("   "); l.add(c("trance made only of sound"), Ink.dim); l.newline()
        head("what it is")
        para("sessions of synthesized sound: no voice, no pictures, nothing recorded. every sound is made live,")
        para("and every session is a plain text file you can open, change or write yourself (Library › Open Sessions Folder).")
        head("how to listen")
        para("headphones in, eyes closed, lying back, at a gentle volume. AirPods with head tracking are best:")
        para("the sound-world stays put when you turn, and the session waits while you stir. without them it still works.")
        para("if both test tones play in both ears, turn Spatial Audio off for Daymare in Control Center › Sound.")
        head("the rooms")
        para("velvet: erotic sessions for adults. they build, hold you at the edge, pull back, and build again.")
        para("abyss: illusions: a stair that falls forever, a floor that tilts, sounds crawling through your head.")
        para("shrine: bells, fire and a turning room, for trance and a clear return.")
        para("rest: the sea, made for falling asleep. if you go still, it lets you.")
        head("answering it without opening your eyes")
        para("a nod (down, up, down) holds where you are; nod again to go on. a shake wakes you.")
        para("in velvet the nod means \"I'm close\" while it builds, \"let me go\" at the edge, and \"again\" afterwards.")
        para("on the AirPods stem: one press wakes, two presses are the nod.")
        para("keys: return play · space hold · n nod · w wake · esc stop · e ear test · c centre")
        head("care")
        para("never while driving or doing anything that needs your attention. stop if anything feels wrong.")
        para("there are no flashing lights, no voice and no suggestions: only sound.")
        tv.textStorage?.setAttributedString(l.text)
        let w = makeSuiteWindow(NSSize(width: 720, height: 640), autosave: "")
        w.title = "How Daymare Works"
        let root = LookBackdrop()
        w.contentView = root
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        var top = root.topAnchor, gap: CGFloat = Look.current == .tianmu ? 24 : 4
        if Look.current.ownsTitleBar {
            let bar = TitleBarView()
            bar.title = "How Daymare Works"
            bar.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(bar)
            NSLayoutConstraint.activate([bar.topAnchor.constraint(equalTo: root.topAnchor), bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                                         bar.trailingAnchor.constraint(equalTo: root.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: TitleBarView.height)])
            top = bar.bottomAnchor; gap = 6
        }
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: top, constant: gap), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                                     scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor)])
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
