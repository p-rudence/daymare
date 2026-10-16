// The one window: the sessions by room, and what is playing. Plain text; every word you can
// click is also a key. It is a remote control, not something to look at: a session is meant
// for closed eyes.

import AppKit

final class KeyView: LookBackdrop {
    var onKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

final class MainWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let conductor: Conductor
    private var tv: LinkTextView
    private var scroll: NSScrollView
    private var titleBar: TitleBarView?
    private var lookObserver: Any?
    private var sessions: [Session] = []
    private var errors: [String] = []
    private var selected = 0
    private var timer: Timer?
    private var lastTick = Date()
    private var frame = 0

    init(conductor: Conductor) {
        self.conductor = conductor
        window = makeSuiteWindow(NSSize(width: 760, height: 560), autosave: "daymare.main")
        (scroll, tv) = makeTextPane()
        super.init()
        buildContent()
        window.delegate = self
        lookObserver = NotificationCenter.default.addObserver(forName: .lookChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            dressWindow(self.window)
            (self.scroll, self.tv) = makeTextPane()
            self.buildContent()
            self.render()
        }
        conductor.onChange = { [weak self] in self?.render() }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// The page, under the look's own title bar when it draws one.
    private func buildContent() {
        let root = KeyView()
        window.contentView = root
        window.title = "Daymare"
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        var top = root.topAnchor
        var gap: CGFloat = Look.current == .tianmu ? 24 : 4
        titleBar = nil
        if Look.current.ownsTitleBar {
            let bar = TitleBarView()
            bar.title = "Daymare"
            bar.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: root.topAnchor),
                bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                bar.heightAnchor.constraint(equalToConstant: TitleBarView.height),
            ])
            titleBar = bar
            top = bar.bottomAnchor
            gap = 6
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top, constant: gap),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.onKey = { [weak self] in self?.key($0) ?? false }
        tv.onLinkClick = { [weak self] url in self?.link(url); return true }
        window.makeFirstResponder(root)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        render()
    }

    func reload() {
        let r = Library.load()
        sessions = r.sessions.filter { $0.room != .velvet || Prefs.showVelvet }
        errors = r.errors
        if let i = sessions.firstIndex(where: { $0.id == Prefs.lastSession }) { selected = i }
        selected = min(selected, max(0, sessions.count - 1))
        render()
    }

    private func tick() {
        let now = Date()
        let dt = min(0.2, now.timeIntervalSince(lastTick))
        lastTick = now
        conductor.tick(dt)
        frame += 1
        if frame % 8 == 0 { render() }
    }

    // MARK: - Drawing

    func render() {
        var l = Lines()
        let m = Motion.shared
        let look = Look.current, house = look == .tianmu
        if !m.receiving { m.refreshPermission() }
        func c(_ s: String) -> String { look.cap(s) }
        if house || !look.ownsTitleBar && look != .native { l.add(c("daymare"), Ink.text, bold: true); l.add("   ") } else { l.add(" ") }
        if m.denied {
            l.add(c("head tracking is off (System Settings › Privacy › Motion & Fitness)"), Ink.ember)
        } else if m.receiving {
            l.add(c("head "), Ink.dim)
            l.add(m.meter.restless ? "stirring " : "still    ", m.meter.restless ? Ink.soft : Ink.name)
            l.add(blockBar(m.meter.stillness, width: 10), Ink.dim)
        } else {
            l.add(c("no head data yet: put the AirPods in"), Ink.dim)
        }
        l.newline(); l.newline()

        var room: Room?
        for (i, s) in sessions.enumerated() {
            if s.room != room {
                if room != nil { l.newline() }
                room = s.room
                l.add(c(s.room.rawValue), s.room == .velvet ? Ink.ember : Ink.name, bold: true); l.newline()
            }
            let sel = i == selected
            let playing = conductor.session?.id == s.id && conductor.isActive
            // Columns by tab stops (the retro looks' fonts aren't monospaced); a long line wraps under its description.
            let k = Prefs.fontSize / 16
            let para = NSMutableParagraphStyle()
            para.tabStops = [NSTextTab(textAlignment: .right, location: 204 * k), NSTextTab(textAlignment: .left, location: 220 * k)]
            para.headIndent = 220 * k
            var row: [NSAttributedString.Key: Any] = [.paragraphStyle: para]
            if sel { row[.dmRow] = true }
            // On a selected row, Bevel's navy bar wants white words.
            let lit = sel && look == .bevel
            l.add(sel ? " ▸ " : "   ", lit ? .white : Ink.soft, extra: row)
            let title = house ? s.title.lowercased() : s.title
            l.add(title, playing ? Ink.ember : lit ? .white : sel ? Ink.text : Ink.soft, link: "play/\(i)", extra: row)
            l.add("\t\(s.minutes)m\t", lit ? .white : Ink.dim, extra: row)
            l.add(s.about, lit ? .white : Ink.dim, extra: row)
            l.newline()
        }
        if sessions.isEmpty { l.add(c("no sessions found in the sessions folder"), Ink.dim); l.newline() }

        l.newline()
        l.add(String(repeating: "─", count: house ? 60 : 48), Ink.line); l.newline()
        status(&l)

        if !errors.isEmpty {
            l.newline()
            for e in errors { l.add(e, Ink.ember); l.newline() }
        }
        l.newline()
        l.add("return play · space hold · n nod (close / let go) · w wake · esc stop", Ink.dim); l.newline()
        l.add("e ear test · c centre · ", Ink.dim)
        l.add("o sessions · r reload · j journal · f flip head turn", Ink.dim)
        tv.textStorage?.setAttributedString(l.text)
    }

    private func status(_ l: inout Lines) {
        let c = conductor
        switch c.phase {
        case .idle:
            l.add(" ")
            if !c.endedHow.isEmpty, c.endedHow != "tested" { l.add(Look.current.cap("last session \(c.endedHow)."), Ink.dim) }
            else { l.add(Look.current == .tianmu ? "choose a session. eyes closed, AirPods in, lie back." : "Choose a session. Eyes closed, AirPods in, lie back.", Ink.dim) }
            l.newline(); l.newline()
            l.add(" "); l.button("ear test", "test", tip: "left, right, and a bell that should stay put when you turn")
            l.newline()
        case .test:
            l.add(" " + Look.current.cap("ear test · \(c.testStep)"), Ink.soft); l.newline(); l.newline()
            l.add(" if the bell turns with your head, press f afterwards. if both tones were in both ears,", Ink.dim); l.newline()
            l.add(" turn Spatial Audio off for Daymare in Control Center › Sound.", Ink.dim); l.newline()
            l.newline(); l.add(" "); l.button("stop", "stop"); l.newline()
        default:
            guard let s = c.session else { return }
            var words = " \(Look.current == .tianmu ? s.title.lowercased() : s.title) · \(timecode(c.clock)) / \(timecode(s.length))"
            switch c.phase {
            case .playing where c.hold: words += " · holding here"
            case .playing where c.lingering: words += " · waiting for you"
            case .playing where s.hasEdge:
                switch c.arc {
                case .build: words += " · building"
                case .rushing: words += " · rushing"
                case .plateau: words += " · at the edge"
                case .cooling: words += " · pulling back"
                case .void: words += " · silence"
                case .countdown: words += " · here it comes"
                case .release: words += " · letting go"
                }
                if c.pullBacks > 0 { words += " · \(c.pullBacks) \(c.pullBacks == 1 ? "edge" : "edges")" }
            case .waking: words += " · waking"
            case .sleeping: words += " · letting you sleep"
            case .stopping: words += " · stopping"
            default: break
            }
            l.add(words, Ink.text); l.newline()
            l.add(" depth ", Ink.dim); l.add(blockBar(c.depth), Ink.name)
            l.add(String(format: "  beat %.1f hz · breath %.1f/min", c.now(.beat), c.now(.breath)), Ink.dim)
            l.newline(); l.newline()
            l.add(" ")
            if c.phase == .playing, s.hasEdge, c.arc != .countdown {
                let word = c.arc == .plateau || c.arc == .rushing ? "let go" : c.arc == .release ? "again" : "close"
                l.button(word, "signal", color: Ink.ember, tip: "same as a nod, or two presses on the stem")
                l.add(" ")
            }
            if c.phase == .playing { l.button(c.hold ? "go on" : "hold", "hold"); l.add(" ") }
            if c.phase == .playing || c.phase == .sleeping { l.button("wake", "wake"); l.add(" ") }
            l.button("stop", "stop")
            l.newline()
        }
    }

    // MARK: - Input

    private func link(_ url: URL) {
        let parts = url.absoluteString.replacingOccurrences(of: "daymare://", with: "").split(separator: "/")
        switch parts.first {
        case "play": if parts.count > 1, let i = Int(parts[1]) { selected = i; playSelected() }
        case "hold": conductor.toggleHold()
        case "signal": conductor.signal()
        case "wake": conductor.wake()
        case "stop": conductor.stop()
        case "test": conductor.earTest()
        default: break
        }
        render()
    }

    /// For screenshots: select a session by title without touching the saved choice.
    func preview(sessionNamed title: String) {
        if let i = sessions.firstIndex(where: { $0.title == title }) { selected = i }
        render()
    }

    func playSelected() {
        guard sessions.indices.contains(selected) else { return }
        // re-read the file, so an edit takes effect without reloading the app
        var s = sessions[selected]
        if let u = s.url {
            do { s = try SessionParser.load(u); errors = [] } catch { errors = ["\(u.lastPathComponent): \(error)"]; render(); return }
        }
        Prefs.lastSession = s.id
        conductor.play(s)
    }

    private func key(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command) { return false }
        switch e.keyCode {
        case 126: selected = max(0, selected - 1); render(); return true          // up
        case 125: selected = min(sessions.count - 1, selected + 1); render(); return true  // down
        case 36, 76: playSelected(); return true                                  // return
        case 53: conductor.stop(); return true                                    // esc
        case 49: conductor.toggleHold(); return true                              // space
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "w": conductor.wake()
        case "n": conductor.signal()
        case "e": conductor.earTest()
        case "c": Motion.shared.recenter()
        case "f": Prefs.flipYaw.toggle()
        case "r": reload()
        case "o": NSWorkspace.shared.open(Paths.sessions)
        case "j": openJournal()
        default: return false
        }
        render()
        return true
    }

    func openJournal() {
        if !FileManager.default.fileExists(atPath: Paths.journal.path) { try? "".write(to: Paths.journal, atomically: true, encoding: .utf8) }
        NSWorkspace.shared.open(Paths.journal)
    }
}
