// Daymare: trance sessions made only of sound, shaped around AirPods head tracking.
// No voice, no visuals. Everything is synthesized live; the sessions are plain text files.

import AppKit
import AVFoundation
import CoreMotion

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var main: MainWindowController!
    var conductor: Conductor!

    private var lookObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        NSApp.appearance = Look.current.appearance
        lookObserver = NotificationCenter.default.addObserver(forName: .lookChanged, object: nil, queue: .main) { _ in
            NSApp.appearance = Look.current.appearance
            HowItWorks.reset()
        }
        Library.installDefaults()
        writeKnobReference()
        Motion.shared.start()
        do {
            conductor = Conductor(sound: try SoundEngine(), body: Motion.shared)
        } catch {
            let a = NSAlert()
            a.messageText = "Daymare couldn't open the sound engine."
            a.informativeText = "\(error)"
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        conductor.wireRemote()
        buildMenu()
        main = MainWindowController(conductor: conductor)
        // The first launch asks two things first: are you an adult, and which look.
        if !LookPicker.confirmedAdult || !Look.chosen {
            LookPicker.show { [weak self] in self?.main.show() }
            return
        }
        main.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func chooseLook(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let l = Look(rawValue: raw) { Look.choose(l) }
    }
    @objc func showLookPicker() { LookPicker.show() }
    @objc func showHowItWorks() { HowItWorks.show() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { main.show() }
        return true
    }

    @objc func showMain() { main.show() }
    @objc func play() { main.playSelected() }
    @objc func hold() { conductor.toggleHold() }
    @objc func wake() { conductor.wake() }
    @objc func stop() { conductor.stop() }
    @objc func earTest() { conductor.earTest() }
    @objc func recenter() { Motion.shared.recenter() }
    @objc func openSessions() { NSWorkspace.shared.open(Paths.sessions) }
    @objc func reload() { main.reload() }
    @objc func journal() { main.openJournal() }
    @objc func knobs() { NSWorkspace.shared.open(Paths.sessions.appendingPathComponent("KNOBS.txt")) }
    @objc func toggleVelvet() { Prefs.showVelvet.toggle(); main.reload() }
    @objc func flipYaw() { Prefs.flipYaw.toggle() }
    @objc func flipPitch() { Prefs.flipPitch.toggle() }
    @objc func bigger() { Prefs.fontSize = min(32, Prefs.fontSize + 8); main.render() }
    @objc func smaller() { Prefs.fontSize = max(16, Prefs.fontSize - 8); main.render() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleVelvet) { item.state = Prefs.showVelvet ? .on : .off }
        if item.action == #selector(flipYaw) { item.state = Prefs.flipYaw ? .on : .off }
        if item.action == #selector(flipPitch) { item.state = Prefs.flipPitch ? .on : .off }
        if item.action == #selector(chooseLook(_:)) { item.state = (item.representedObject as? String) == Look.current.rawValue ? .on : .off }
        return true
    }

    private func buildMenu() {
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem()
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            top.submenu = m
            bar.addItem(top)
        }
        func item(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        menu("Daymare", [
            item("About Daymare", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("How Daymare Works", #selector(showHowItWorks)),
            .separator(),
            item("Hide Daymare", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit Daymare", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("Session", [
            item("Play", #selector(play), "\r", []),
            item("Hold / Go On", #selector(hold), " ", []),
            item("Wake", #selector(wake), "w", []),
            item("Stop", #selector(stop), "."),
            .separator(),
            item("Ear Test", #selector(earTest), "e", []),
            item("Centre Here", #selector(recenter), "c", []),
        ])
        menu("Library", [
            item("Open Sessions Folder", #selector(openSessions), "o", []),
            item("Knob Reference", #selector(knobs)),
            item("Reload Sessions", #selector(reload), "r", []),
            item("Journal", #selector(journal), "j", []),
            .separator(),
            item("Show Velvet", #selector(toggleVelvet), "v", [.command, .shift]),
        ])
        menu("View", [
            item("Bigger Text", #selector(bigger), "="),
            item("Smaller Text", #selector(smaller), "-"),
            .separator(),
            item("Flip Head Turn", #selector(flipYaw)),
            item("Flip Head Tilt", #selector(flipPitch)),
            .separator(),
        ] + Look.allCases.map { l in
            let i = item(l.title, #selector(chooseLook(_:)))
            i.representedObject = l.rawValue
            return i
        } + [item("Choose a Look…", #selector(showLookPicker))])
        menu("Window", [
            item("Daymare", #selector(showMain), "1"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        menu("Help", [item("How Daymare Works", #selector(showHowItWorks), "?")])
        NSApp.mainMenu = bar
        NSApp.windowsMenu = bar.items[bar.items.count - 2].submenu
        NSApp.helpMenu = bar.items.last?.submenu
    }
}

func writeKnobReference() {
    var t = "Daymare knobs\n\nA session file is a few header lines, then keyframes:\n\n"
    t += "  # Title\n  room: rest | shrine | abyss | velvet\n  about: one line for the list\n"
    t += "  length: 30:00        (optional; otherwise the last keyframe)\n"
    t += "  fade: 20s            (fade in)\n  wake: 45s            (how long waking takes)\n"
    t += "  sleep: 45            (rest: minutes of sea after the end if you have gone still)\n"
    t += "  ending: auto | wake | sleep\n"
    t += "  edge: 18:00          (edging: the peak; the session holds you here)\n"
    t += "  hold: 60s            (how long it holds you at the edge before pulling back)\n"
    t += "  cool: 11:00          (where a pull-back falls to before building again)\n"
    t += "  cycles: 3            (pull-backs before it lets you go; 0 = only when you nod)\n"
    t += "  release: 18:30       (where letting go plays from, to the end)\n"
    t += "  drive: 1             (how much your moving speeds the build)\n  space: hall | cathedral | chamber | plate | room | abyss | none\n"
    t += "  noise: pink | brown | 0–1\n  chord: 1 3/2 2       (1–5 ratios over tone)\n  orbit: wind | tone\n\n"
    t += "  at 0:00  beat 10 breath 7 bed .6\n  at 12:00 beat 4 breath 5.5\n\n"
    t += "Each knob glides in a straight line between the keyframes that name it.\n// starts a comment.\n\n"
    for k in K.keyframable {
        t += "  " + k.name.padding(toLength: 10, withPad: " ", startingAt: 0) + k.help
        t += "  [default \(k.defaultValue.clean)]\n"
    }
    t += "\nWhile playing: if your head stirs, the session waits (time runs slower) until you settle.\n"
    t += "A deliberate nod (down-up-down) holds the depth where it is; nod again to go on.\n"
    t += "In an edging session the nod means instead: building, \"I'm close\" (it rushes you to the edge);\n"
    t += "at the edge, \"let me go\" (release). Moving speeds the build instead of slowing it.\n"
    t += "A shake wakes you. On the stem: one press wakes, two presses are the nod.\n"
    try? t.write(to: Paths.sessions.appendingPathComponent("KNOBS.txt"), atomically: true, encoding: .utf8)
}

extension Float {
    var clean: String { self == rounded() ? String(Int(self)) : String(format: "%g", self) }
}

// MARK: - Entry

let args = CommandLine.arguments
if args.count > 1, args[1] == "--selftest" {
    exit(SelfTest.run())
}
if args.count > 3, args[1] == "--render" {
    // Daymare --render <session.txt> <out.m4a> [minutes]: the whole session as a file, as if you lay perfectly still.
    exit(SelfTest.renderFile(session: args[2], out: args[3], minutes: args.count > 4 ? Double(args[4]) : nil))
}
if args.count > 2, args[1] == "--looks" {
    // Daymare --looks <dir>: the window in each look, and the first-launch picker, as PNGs (silent: offline engine).
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    registerBundledFonts()
    let dir = URL(fileURLWithPath: args[2])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    TitleBarView.alwaysActive = true
    func save(_ v: NSView, _ name: String) {
        v.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.3)); v.displayIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }
    guard let engine = try? SoundEngine(offline: true) else { exit(1) }
    let mw = MainWindowController(conductor: Conductor(sound: engine, body: Motion.shared))
    mw.window.setContentSize(NSSize(width: 760, height: 560))
    mw.window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    mw.window.orderFrontRegardless()
    mw.preview(sessionNamed: "Goonsattva")
    for l in Look.allCases {
        Look.current = l
        NotificationCenter.default.post(name: .lookChanged, object: nil)
        mw.preview(sessionNamed: "Goonsattva")
        if let v = mw.window.contentView { save(v, "look-\(l.rawValue).png") }
    }
    Look.current = .tianmu
    if let pv = LookPicker().window?.contentView {
        pv.window?.setFrameOrigin(NSPoint(x: -30000, y: -30000)); pv.window?.orderFrontRegardless()
        save(pv, "picker.png")
    }
    print("wrote \(dir.path)")
    exit(0)
}
if args.count > 1, args[1] == "--motion" {
    // Daymare --motion [seconds]: print head samples per second (checks delivery when not frontmost).
    let secs = args.count > 2 ? Double(args[2]) ?? 20 : 20
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Motion.shared.start()
    print("auth \(CMHeadphoneMotionManager.authorizationStatus().rawValue) (0 not asked, 1 restricted, 2 denied, 3 allowed) · available \(Motion.shared.available)")
    var last = 0, n = 0
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        n += 1
        let m = Motion.shared
        print(String(format: "%2ds  %3d samples/s  yaw %6.1f  pitch %6.1f  energy %.3f  still %.2f  stillFor %.0fs",
                     n, m.samples - last, m.yaw, m.pitch, m.meter.energy, m.meter.stillness, m.meter.stillFor))
        fflush(stdout)
        last = m.samples
        if Double(n) >= secs { exit(m.samples > 0 ? 0 : 1) }
    }
    Motion.shared.onGesture = { print("gesture: \($0)"); fflush(stdout) }
    Motion.shared.gesturesOn = true
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
