// `Daymare --selftest`: parsing, gestures, stillness, and real offline renders of the sound graph
// (binaural isolation and frequencies, every shipped session at several depths, both endings).
// Must print ALL PASSED.

import Foundation
import AVFoundation

enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "  ok   " : "  FAIL ") + what)
        if !ok { failures += 1 }
    }

    static func run() -> Int32 {
        print("parser"); parser()
        print("gestures"); gestures()
        print("stillness"); stillness()
        print("binaural"); binaural()
        print("sessions"); sessions()
        print("endings"); endings()
        print("edging"); edging()
        print("hostile files"); hostile()
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    // MARK: -

    static func parser() {
        let text = """
        # Test Tide
        room: rest
        about: a test
        noise: brown
        chord: 1 3/2 2
        at 0:00 beat 10 breath 7 // a comment
        at 1:00 beat 6
        at 2:00 breath 5
        """
        do {
            let s = try SessionParser.parse(text, id: "t")
            check(s.title == "Test Tide", "title")
            check(s.room == .rest && s.about == "a test", "room and about")
            check(s.length == 120, "length from the last keyframe")
            check(s.value(.beat, at: 30) == 8, "beat glides halfway")
            check(s.value(.beat, at: 500) == 6, "beat holds after its last keyframe")
            check(s.value(.breath, at: 60) == 6, "breath glides across a keyframe that doesn't name it")
            check(s.value(.guide, at: 10) == K.guide.defaultValue, "unnamed knob keeps its default")
            check(s.header[.c2] == 1.5 && s.header[.chordN] == 3, "chord ratios")
            check(s.header[.color] == 1, "brown noise")
        } catch { check(false, "parse: \(error)") }
        do { _ = try SessionParser.parse("at 0:00 bogus 3"); check(false, "unknown knob rejected") } catch { check(true, "unknown knob rejected") }
        do { _ = try SessionParser.parse("at 2:00 beat 3\nat 1:00 beat 4"); check(false, "backwards time rejected") } catch { check(true, "backwards time rejected") }
        check(SessionParser.seconds("1:02:03") == 3723 && SessionParser.seconds("45m") == 2700 && SessionParser.seconds("90s") == 90, "time formats")
    }

    /// Hand-edited sessions with wild values: they're refused or tamed, never crash, never go silent or loud.
    static func hostile() {
        for bad in ["length: nan", "length: 1e300", "at 0:00 beat nan", "at 0:00 beat 1e39", "at inf beat 3", "lift: nan", "drive: inf"] {
            do { _ = try SessionParser.parse(bad + "\nat 0:00 beat 6\nat 1:00 beat 6"); check(false, "refused: \(bad)") }
            catch { check(true, "refused: \(bad)") }
        }
        do {
            let s = try SessionParser.parse("about: see https://example.org // a note\nat 0:00 beat 6\nat 1:00 beat 6")
            check(s.about == "see https://example.org", "a web address in about survives comment stripping (\(s.about))")
        } catch { check(false, "about with a URL: \(error)") }
        do {
            let s = try SessionParser.parse("fade: 0\nat 0:00 master 20 bed 3 guide 3 orbit .5 whisper -400 pace .5 pattern 1e20 tone 1e9\nat 1:00 beat 6")
            check(s.value(.whisper, at: 0) == 40 && s.value(.pattern, at: 0) == 5 && s.value(.master, at: 0) == 1, "wild knob values are clamped to their ranges")
            let (_, c, _) = try makeOffline()
            c.play(s)
            let (l, r) = try capture(c, secs: 6)
            check(!l.contains { !$0.isFinite } && !r.contains { !$0.isFinite }, "a wild session renders without broken samples")
            check(rms(Array(l.suffix(48000))) > 0.001, "a wild session still makes sound")
            check((l.map(abs).max() ?? 0) <= 1, "a wild session stays under the ceiling")
            // and the next session in the same engine is unharmed
            if let dir = Bundle.main.resourceURL?.appendingPathComponent("Sessions"), let tide = try? SessionParser.load(dir.appendingPathComponent("tide.txt")) {
                c.stop(); _ = try capture(c, secs: 6)
                c.play(tide)
                let (l2, _) = try capture(c, secs: 4)
                check(!l2.contains { !$0.isFinite } && rms(Array(l2.suffix(24000))) > 0.0005, "the next session after a wild one plays normally")
            }
        } catch { check(false, "wild session: \(error)") }
        // the reference card in the sessions folder isn't read as a session
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("daymare-knobs-\(getpid())")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? "Daymare knobs\n\nnot a session".write(to: tmp.appendingPathComponent("KNOBS.txt"), atomically: true, encoding: .utf8)
        try? "at 0:00 beat 6\nat 1:00 beat 6".write(to: tmp.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        let r = Library.load(from: tmp)
        check(r.errors.isEmpty && r.sessions.count == 1, "KNOBS.txt is not listed as a broken session")
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Synthetic head motion at 25 Hz.
    static func feed(_ d: inout GestureDetector, _ f: (Double) -> (Double, Double), secs: Double) -> [Gesture] {
        var out: [Gesture] = []
        var t = 0.0
        while t < secs {
            let (p, y) = f(t)
            if let g = d.feed(t: t, pitch: p, yaw: y) { out.append(g) }
            t += 0.04
        }
        return out
    }

    static func gestures() {
        var d = GestureDetector()
        // a double nod: pitch swings ±0.25 rad at ~1.6 Hz for ~1.3 s
        var g = feed(&d, { t in (t > 1 && t < 2.3 ? 0.25 * sin(2 * .pi * 1.6 * (t - 1)) : 0, 0) }, secs: 4)
        check(g == [.nod], "a double nod is a nod (got \(g))")
        d = GestureDetector()
        g = feed(&d, { t in (0, t > 1 && t < 2.3 ? 0.35 * sin(2 * .pi * 1.5 * (t - 1)) : 0) }, secs: 4)
        check(g == [.shake], "a head shake is a shake (got \(g))")
        d = GestureDetector()
        g = feed(&d, { t in (t > 1 ? -0.5 * min(1, (t - 1) / 0.4) : 0, 0) }, secs: 4)
        check(g.isEmpty, "a slump is not a nod")
        d = GestureDetector()
        g = feed(&d, { t in (0.02 * sin(2 * .pi * 0.25 * t), 0.6 * min(1, t / 3)) }, secs: 6)
        check(g.isEmpty, "a slow turn and breathing are not gestures")
    }

    static func stillness() {
        var m = StillnessMeter()
        for _ in 0..<(25 * 30) { m.feed(rotation: 0.01, accel: 0.002, dt: 0.04) }
        check(m.stillness > 0.95 && !m.restless && m.stillFor > 20, "lying still reads still")
        for _ in 0..<(25 * 2) { m.feed(rotation: 0.6, accel: 0.05, dt: 0.04) }
        check(m.restless && m.stillFor == 0, "a stir reads restless at once")
        for _ in 0..<(25 * 20) { m.feed(rotation: 0.01, accel: 0.002, dt: 0.04) }
        check(!m.restless, "settles again")
    }

    // MARK: - Sound

    static func goertzel(_ x: [Float], _ f: Double, _ sr: Double) -> Double {
        let w = 2 * Double.pi * f / sr, c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x { let s = Double(v) + c * s1 - s2; s2 = s1; s1 = s }
        return sqrt(max(0, s1 * s1 + s2 * s2 - c * s1 * s2)) / Double(x.count)
    }

    static func rms(_ x: [Float]) -> Double { sqrt(x.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, x.count))) }

    /// Render `secs` seconds through a conductor, collecting both channels.
    static func capture(_ c: Conductor, secs: Double) throws -> (l: [Float], r: [Float]) {
        var l: [Float] = [], r: [Float] = []
        let e = c.sound
        try e.renderOffline(frames: Int(secs * e.sr), tick: { c.tick($0) }) { buf in
            let n = Int(buf.frameLength)
            l += UnsafeBufferPointer(start: buf.floatChannelData![0], count: n)
            r += UnsafeBufferPointer(start: buf.floatChannelData![1], count: n)
        }
        return (l, r)
    }

    static func makeOffline() throws -> (SoundEngine, Conductor, StillBody) {
        let e = try SoundEngine(offline: true)
        try e.start()
        let b = StillBody()
        return (e, Conductor(sound: e, body: b), b)
    }

    static func binaural() {
        do {
            let (e, c, _) = try makeOffline()
            let s = try SessionParser.parse("ending: wake\nfade: 0\nat 0:00 beat 10 carrier 200 binaural 1 bed 0 guide 0\nat 1:00 beat 10")
            c.play(s)
            let (l, r) = try capture(c, secs: 2)
            let l2 = Array(l[Int(e.sr)...]), r2 = Array(r[Int(e.sr)...])
            let lLow = goertzel(l2, 195, e.sr), lHigh = goertzel(l2, 205, e.sr)
            let rLow = goertzel(r2, 195, e.sr), rHigh = goertzel(r2, 205, e.sr)
            check(lLow > 20 * lHigh, String(format: "left ear hears 195 Hz only (%.4f vs %.4f)", lLow, lHigh))
            check(rHigh > 20 * rLow, String(format: "right ear hears 205 Hz only (%.4f vs %.4f)", rHigh, rLow))

            c.earTest()
            let (tl, tr) = try capture(c, secs: 3)
            let a = Array(tl[Int(e.sr * 1)..<Int(e.sr * 3)]), b = Array(tr[Int(e.sr * 1)..<Int(e.sr * 3)])
            check(rms(a) > 0.03 && rms(b) < 0.0005, String(format: "ear test: left tone stays left (L %.4f, R %.6f)", rms(a), rms(b)))
        } catch { check(false, "binaural render: \(error)") }
    }

    static func sessions() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Sessions") else { check(false, "bundle sessions"); return }
        let r = Library.load(from: dir)
        check(r.errors.isEmpty, "every shipped session parses \(r.errors)")
        check(r.sessions.count >= 4, "\(r.sessions.count) sessions shipped")
        for s in r.sessions {
            do {
                let (_, c, _) = try makeOffline()
                c.play(s)
                var peak: Float = 0, worst = 1.0, best = 0.0, bad = false
                var parts: [String] = []
                // the start (with its fade), then a slice at a few depths
                for (i, at) in [0.0, 0.3, 0.6, 0.95].enumerated() {
                    if i > 0 { c.seek(s.length * at) }
                    let (l, r) = try capture(c, secs: i == 0 ? 30 : 12)
                    let tailL = Array(l.suffix(Int(c.sound.sr * 8)))
                    let lv = rms(tailL)
                    worst = min(worst, lv); best = max(best, lv)
                    peak = max(peak, l.map(abs).max() ?? 0, r.map(abs).max() ?? 0)
                    if l.contains(where: { !$0.isFinite }) || r.contains(where: { !$0.isFinite }) { bad = true }
                    parts.append(String(format: "%.0f", 20 * log10(max(lv, 1e-9))))
                }
                check(!bad, "\(s.id): no broken samples")
                check(peak <= 1.0, String(format: "\(s.id): peak %.2f within the ceiling", peak))
                check(worst > 0.004 && best < 0.35, "\(s.id): audible and comfortable (dBFS at depths: \(parts.joined(separator: " ")))")
            } catch { check(false, "\(s.id): \(error)") }
        }
    }

    static func endings() {
        do {
            let (_, c, body) = try makeOffline()
            let text = "room: rest\nfade: 2\nwake: 10\nsleep: 1\nat 0:00 bed .6 guide .4 binaural .3\nat 0:20 bed .6"
            c.play(try SessionParser.parse(text))
            _ = try capture(c, secs: 25)
            check(c.phase == .sleeping, "rest, lying still: lets you sleep (\(c.phase))")
            _ = try capture(c, secs: 64)
            check(c.phase == .idle && c.endedHow == "slept", "sleep tail ends quietly (\(c.endedHow))")

            body.receiving = true; body.stillFor = 10; body.restless = false
            c.play(try SessionParser.parse(text))
            _ = try capture(c, secs: 22)
            check(c.phase == .waking, "rest, not asleep: wakes you (\(c.phase))")
            let (l, _) = try capture(c, secs: 11)
            check(c.phase == .idle && rms(Array(l.suffix(4800))) < 0.001, "waking ends in silence")

            body.restless = true
            c.play(try SessionParser.parse(text.replacingOccurrences(of: "room: rest", with: "room: shrine")))
            _ = try capture(c, secs: 22)
            check(c.phase == .playing && c.clock < 12, String(format: "stirring slows the session (%.1fs in 22s)", c.clock))
            body.restless = false
            c.toggleHold()
            let held = c.clock
            _ = try capture(c, secs: 3)
            check(c.clock == held, "hold stops the clock")
            c.toggleHold()
            c.wake()
            _ = try capture(c, secs: 11)
            check(c.phase == .idle && c.endedHow == "woke", "wake on request")
        } catch { check(false, "endings: \(error)") }
    }

    static func edging() {
        do {
            let (_, c, body) = try makeOffline()
            let text = "room: velvet\nfade: 1\nwake: 5\nedge: 0:20\nhold: 4s\ncool: 0:10\ncycles: 2\nrelease: 0:25\ncountdown: 3\nat 0:00 heart .5 bpm 60 pace .5 tempo 80\nat 0:20 bpm 90\nat 0:40 bpm 60"
            let s = try SessionParser.parse(text)
            check(s.hasEdge && s.edge == 20 && s.cool == 10 && s.cycles == 2 && s.countdown == 3, "edge settings parse")
            c.play(s)
            _ = try capture(c, secs: 2)
            check(c.antic == 0, "no rush of air far from the edge")
            _ = try capture(c, secs: 16)
            check(c.antic > 0.3, String(format: "the riser climbs before the edge (%.2f)", c.antic))
            _ = try capture(c, secs: 3)
            check(c.arc == .plateau && c.clock == 20, "builds to the edge and holds (\(c.arc), \(c.clock))")
            _ = try capture(c, secs: 3)
            check(c.crest > 0.5 && c.lift > 1, String(format: "shimmer and a climbing heart at the edge (%.2f, +%.1f bpm)", c.crest, c.lift))
            _ = try capture(c, secs: 3)
            check(c.arc == .cooling && c.pullBacks == 1, "pulls back after the hold (\(c.arc))")
            _ = try capture(c, secs: 14)
            check(c.arc == .void && c.duck > 0.9, String(format: "then the sea alone (\(c.arc), duck %.2f)", c.duck))
            c.signal()
            check(c.arc == .rushing, "a nod in the silence rushes to the edge")
            _ = try capture(c, secs: 5)
            check(c.arc == .plateau, "arrives at the edge (\(c.arc))")
            c.signal()
            check(c.arc == .countdown, "a nod at the edge starts the countdown")
            _ = try capture(c, secs: 3.5)
            check(c.arc == .release && c.clock >= 25 && c.now(.pace) == 0, "the crest: release plays and the pace stops dead (\(c.arc), \(c.clock))")
            _ = try capture(c, secs: 18)
            check(c.phase == .idle || c.phase == .waking, "release plays out and wakes (\(c.phase))")

            body.receiving = true; body.stillness = 0
            c.play(s)
            _ = try capture(c, secs: 9)
            check(c.clock > 14, String(format: "moving speeds the build (%.1fs in 9s)", c.clock))
            body.stillness = 1
            c.play(s)
            _ = try capture(c, secs: 120)
            check(c.pullBacks == 2 && (c.arc == .release || c.phase != .playing), "lets go by itself after its cycles (\(c.arc), edges \(c.pullBacks))")

            // tempo never lurches: one bar can move it 8% at most
            let k = UnsafeMutablePointer<Float>.allocate(capacity: K.allCases.count)
            for key in K.allCases { k[key.rawValue] = key.defaultValue }
            k[K.tempo.rawValue] = 80; k[K.pace.rawValue] = 1; k[K.master.rawValue] = 1
            let p = PaceVoice(k: k, sr: 48000)
            let L = UnsafeMutablePointer<Float>.allocate(capacity: 160_000), R = UnsafeMutablePointer<Float>.allocate(capacity: 160_000)
            k[K.tempo.rawValue] = 160
            p.render(L, R, 48000 * 3 + 100)    // just over one bar (four beats) at 80
            check(abs(p.tempo - 86.4) < 0.01, String(format: "tempo moves 8%% at the bar (%.1f)", p.tempo))
            check(PaceVoice.fires(3, 1, 0) == false && PaceVoice.fires(3, 0, 2), "stop-go rests every other bar")
            k.deallocate(); L.deallocate(); R.deallocate()
        } catch { check(false, "edging: \(error)") }
    }

    // MARK: - Render to file

    static func renderFile(session path: String, out: String, minutes: Double?) -> Int32 {
        do {
            let s = try SessionParser.load(URL(fileURLWithPath: path))
            let (e, c, _) = try makeOffline()
            c.play(s)
            let file = try AVAudioFile(forWriting: URL(fileURLWithPath: out), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: e.sr, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
            ])
            let limit = (minutes ?? 600) * 60
            var t = 0.0
            while c.isActive && t < limit {
                try e.renderOffline(frames: Int(e.sr * 10), tick: { c.tick($0) }) { try file.write(from: $0) }
                t += 10
            }
            print("wrote \(out) (\(timecode(t)))")
            return 0
        } catch {
            print("render failed: \(error)")
            return 1
        }
    }
}
