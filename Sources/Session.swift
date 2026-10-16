// A session is a plain text file: a few header lines, then keyframes.
//
//   # Tide
//   room: rest
//   about: the sea breathes with you
//   noise: brown
//   at 0:00   beat 10  breath 7  bed .7
//   at 15:00  beat 4.5 breath 5.5
//
// Each knob glides in a straight line between the keyframes that name it,
// holds its first value before them and its last value after.

import Foundation

/// Every number the conductor hands the sound engine. Shared with the audio thread as a flat Float array.
enum K: Int, CaseIterable {
    // keyframable
    case master, beat, carrier, binaural, pulse
    case breath, exhale, guide, swell, tone, glow
    case bed, bright, tide, surge, wave
    case bells, bell, bellpitch, height
    case orbit, spin, radius, rise, whisper
    case heart, bpm, fire, crackle
    case shepard, fall, turn, swarm, flux
    case pace, tempo, pattern, riser, shimmer
    // header (fixed per session)
    case color, orbitTone, chordN, c1, c2, c3, c4, c5
    // triggers and tests (written by the conductor)
    case bellTrig0, bellTrig1, bellTrig2, bellFreq0, bellFreq1, bellFreq2
    case chimeTrig, chimeFreq, testL, testR

    static let keyframable: [K] = Array(allCases.prefix(through: K.shimmer.rawValue))

    var name: String { "\(self)" }

    var defaultValue: Float {
        switch self {
        case .master: return 1
        case .beat: return 6
        case .carrier: return 200
        case .breath: return 6
        case .exhale: return 0.6
        case .swell: return 1
        case .tone: return 110
        case .glow: return 0.4
        case .bright: return 0.5
        case .wave: return 40
        case .bell: return 0.5
        case .bellpitch: return 440
        case .height: return 0.5
        case .spin: return 60
        case .radius: return 2
        case .whisper: return 800
        case .bpm: return 60
        case .crackle: return 0.4
        case .fall: return 1
        case .flux: return 3
        case .tempo: return 72
        case .color: return 1
        case .chordN: return 3
        case .c1: return 1
        case .c2: return 1.5
        case .c3: return 2
        case .c4: return 3
        case .c5: return 4
        case .chimeFreq: return 880
        default: return 0
        }
    }

    /// The values a knob may take. A session file can't push the sound past these (a wild level or
    /// pitch would only pin the limiter or upset a filter).
    var range: ClosedRange<Float> {
        switch self {
        case .beat: return 0...40
        case .carrier: return 40...1000
        case .breath: return 1...30
        case .exhale: return 0.3...0.85
        case .tone: return 20...2000
        case .wave: return 2...600
        case .bells: return 0...60
        case .bellpitch: return 40...4000
        case .height: return -1...1
        case .spin: return -600...600
        case .radius: return 0...20
        case .rise: return -10...10
        case .whisper: return 40...8000
        case .bpm: return 20...200
        case .fall: return -10...10
        case .turn: return -720...720
        case .flux: return 0...20
        case .tempo: return 20...240
        case .pattern: return 0...5
        default: return 0...1   // every level, and the 0–1 shapes
        }
    }

    func clamp(_ v: Float) -> Float { min(range.upperBound, max(range.lowerBound, v)) }

    /// What each knob means, for the session-file reference.
    var help: String {
        switch self {
        case .master: return "overall level, 0–1"
        case .beat: return "binaural beat and pulse rate, Hz (10 alpha, 6 theta, 3 delta)"
        case .carrier: return "binaural carrier pitch, Hz (150–400)"
        case .binaural: return "binaural tone level, 0–1"
        case .pulse: return "how much the bed and pad throb at the beat rate, 0–1"
        case .breath: return "breathing pace, breaths per minute"
        case .exhale: return "share of each breath that is out-breath, 0.5–0.75"
        case .guide: return "breathing pad level, 0–1"
        case .swell: return "how much the pad rises and falls with the breath, 0–1"
        case .tone: return "pad root pitch, Hz"
        case .glow: return "pad brightness, 0–1"
        case .bed: return "noise bed level, 0–1"
        case .bright: return "noise bed brightness, 0–1 (low is a far sea)"
        case .tide: return "how much the bed swells with the breath, 0–1"
        case .surge: return "slow waves of intensity through pad, heart and whisper, 0–1"
        case .wave: return "seconds per surge wave"
        case .bells: return "bells per minute"
        case .bell: return "bell level, 0–1"
        case .bellpitch: return "bell pitch, Hz"
        case .height: return "how high the bells ring, -1 below to 1 above"
        case .orbit: return "circling whisper level, 0–1"
        case .spin: return "seconds per circle (negative turns the other way, 0 holds still)"
        case .radius: return "circle radius, metres"
        case .rise: return "circle height, metres"
        case .whisper: return "whisper pitch, Hz"
        case .heart: return "heartbeat level, 0–1"
        case .bpm: return "heartbeat pace"
        case .fire: return "fire level, 0–1"
        case .crackle: return "how often the fire pops, 0–1"
        case .shepard: return "endless falling tone level, 0–1 (the Shepard–Risset illusion)"
        case .fall: return "octaves per minute it falls (negative rises forever)"
        case .turn: return "degrees per minute the whole sound-world rotates around you"
        case .swarm: return "level of the sounds that move through your head, 0–1"
        case .flux: return "how fast the swarm moves, about 1 slow to 10 frantic"
        case .pace: return "the pace: a low centred thump to follow, 0–1"
        case .tempo: return "pace tempo, beats per minute (changes only on the bar, at most 8% a bar)"
        case .pattern: return "pace pattern: 0 steady, 1 doubles, 2 swing, 3 stop-go, 4 break, 5 halves"
        case .riser: return "a rising rush of air, 0–1 (edging adds it by itself before each edge)"
        case .shimmer: return "a high shimmering chord, 0–1 (edging adds it by itself at each edge)"
        default: return ""
        }
    }
}

enum Room: String, CaseIterable {
    /// Listed in this order: velvet first.
    case velvet, abyss, shrine, rest
}

enum Ending: String {
    case auto, wake, sleep
}

struct Session {
    var id = ""                    // file name without extension
    var title = "untitled"
    var room = Room.rest
    var about = ""
    var length: Double = 0         // seconds
    var fadeIn: Double = 20
    var wake: Double = 45          // seconds of waking
    var sleepTail: Double = 45 * 60
    var ending = Ending.auto
    // edging: a build to `edge`, held for `hold` seconds, then pulled back to `cool` and built
    // again; after `cycles` pull-backs (0 = never, only on your signal) it lets go into `release`.
    var edge: Double?
    var cool: Double = 0
    var release: Double?
    var hold: Double = 60
    var cycles = 3
    var drive: Double = 1
    var lift: Float = 8            // bpm the heart climbs while you're held at the edge
    var countdown: Double = 12     // seconds of rising countdown before release
    var hasEdge: Bool { edge != nil }
    var space = "hall"
    var header: [K: Float] = [:]
    var tracks: [K: [(t: Double, v: Float)]] = [:]
    var url: URL?

    /// Plain wording for the list.
    var minutes: Int { Int((length / 60).rounded()) }

    func value(_ k: K, at t: Double) -> Float {
        if let h = header[k] { return h }
        guard let pts = tracks[k], let first = pts.first else { return k.defaultValue }
        if t <= first.t { return first.v }
        for i in 1..<pts.count where t < pts[i].t {
            let a = pts[i - 1], b = pts[i]
            let u = Float((t - a.t) / (b.t - a.t))
            return a.v + (b.v - a.v) * u
        }
        return pts.last!.v
    }

    /// Every keyframable knob at time t, in K order.
    func snapshot(at t: Double) -> [Float] {
        K.keyframable.map { value($0, at: t) }
    }
}

struct SessionError: Error, CustomStringConvertible {
    let line: Int
    let message: String
    var description: String { "line \(line): \(message)" }
}

enum SessionParser {
    static let byName: [String: K] = Dictionary(uniqueKeysWithValues: K.keyframable.map { ($0.name, $0) })

    /// "1:30", "1:02:03", "90s", "45m", "2h", "90". Hand-edited files are trusted with nothing:
    /// a time must be finite and within a day.
    static func seconds(_ s: String) -> Double? {
        guard let t = rawSeconds(s), t.isFinite, t >= 0, t <= 86_400 else { return nil }
        return t
    }

    private static func rawSeconds(_ s: String) -> Double? {
        let s = s.trimmingCharacters(in: .whitespaces).lowercased()
        if s.contains(":") {
            let parts = s.split(separator: ":").map { Double($0) }
            if parts.contains(where: { $0 == nil }) { return nil }
            return parts.reduce(0) { $0 * 60 + $1! }
        }
        if let last = s.last, "smh".contains(last), let n = Double(s.dropLast()) {
            return n * (last == "s" ? 1 : last == "m" ? 60 : 3600)
        }
        return Double(s)
    }

    /// A finite number (or a ratio like 3/2); nan, inf and overflow are refused.
    static func number(_ s: String) -> Float? {
        var v: Float?
        if s.contains("/") {
            let p = s.split(separator: "/")
            guard p.count == 2, let a = Float(p[0]), let b = Float(p[1]), b != 0 else { return nil }
            v = a / b
        } else {
            v = Float(s)
        }
        guard let v, v.isFinite else { return nil }
        return v
    }

    static func parse(_ text: String, id: String = "") throws -> Session {
        var s = Session()
        s.id = id
        s.title = id.isEmpty ? "untitled" : id.replacingOccurrences(of: "-", with: " ")
        var sawTitle = false
        var lastAt: Double = -1

        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let n = i + 1
            var line = raw
            // `//` starts a comment at the start of a line or after a space (so "https://" in an about line survives).
            if line.hasPrefix("//") { line = "" }
            else if let r = line.range(of: #"\s//"#, options: .regularExpression) { line = String(line[..<r.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                if !sawTitle {
                    s.title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                    sawTitle = true
                }
                continue
            }

            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if words.first == "at" {
                guard words.count >= 2, let t = seconds(words[1]) else { throw SessionError(line: n, message: "\"at\" needs a time, like at 4:00") }
                if t < lastAt { throw SessionError(line: n, message: "keyframes must go forward in time") }
                lastAt = t
                var j = 2
                while j < words.count {
                    let name = words[j].lowercased()
                    guard let k = byName[name] else { throw SessionError(line: n, message: "unknown knob \"\(words[j])\"") }
                    guard j + 1 < words.count, let v = number(words[j + 1]) else { throw SessionError(line: n, message: "\(name) needs a number") }
                    s.tracks[k, default: []].append((t, k.clamp(v)))
                    j += 2
                }
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { throw SessionError(line: n, message: "expected \"key: value\" or \"at <time> …\"") }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "title": s.title = val
            case "room":
                guard let r = Room(rawValue: val.lowercased()) else { throw SessionError(line: n, message: "room is rest, shrine, velvet or abyss") }
                s.room = r
            case "about": s.about = val
            case "length":
                guard let t = seconds(val) else { throw SessionError(line: n, message: "length needs a time") }
                s.length = t
            case "fade":
                guard let t = seconds(val) else { throw SessionError(line: n, message: "fade needs seconds") }
                s.fadeIn = t
            case "wake":
                guard let t = seconds(val) else { throw SessionError(line: n, message: "wake needs seconds") }
                s.wake = max(5, t)
            case "sleep":
                guard let t = seconds(val) else { throw SessionError(line: n, message: "sleep needs minutes") }
                s.sleepTail = val.contains(where: { ":smh".contains($0) }) ? t : t * 60
            case "ending":
                guard let e = Ending(rawValue: val.lowercased()) else { throw SessionError(line: n, message: "ending is auto, wake or sleep") }
                s.ending = e
            case "space":
                s.space = val.lowercased()
            case "edge", "cool", "release":
                guard let t = seconds(val) else { throw SessionError(line: n, message: "\(key) needs a time, like 18:00") }
                if key == "edge" { s.edge = t } else if key == "cool" { s.cool = t } else { s.release = t }
            case "hold":
                guard let t = seconds(val) else { throw SessionError(line: n, message: "hold needs seconds") }
                s.hold = max(5, t)
            case "cycles":
                guard let c = Int(val), c >= 0 else { throw SessionError(line: n, message: "cycles is a whole number (0 = only on your signal)") }
                s.cycles = c
            case "lift":
                guard let v = Float(val), v.isFinite else { throw SessionError(line: n, message: "lift is beats per minute, like 8") }
                s.lift = max(0, min(60, v))
            case "countdown":
                guard let t = seconds(val) else { throw SessionError(line: n, message: "countdown needs seconds") }
                s.countdown = max(3, t)
            case "drive":
                guard let d = Double(val), d.isFinite else { throw SessionError(line: n, message: "drive is a number, like 1") }
                s.drive = max(0, min(10, d))
            case "noise":
                switch val.lowercased() {
                case "pink": s.header[.color] = 0
                case "brown": s.header[.color] = 1
                default:
                    guard let v = number(val) else { throw SessionError(line: n, message: "noise is pink, brown or 0–1") }
                    s.header[.color] = min(1, max(0, v))
                }
            case "orbit":
                switch val.lowercased() {
                case "wind", "whisper": s.header[.orbitTone] = 0
                case "tone": s.header[.orbitTone] = 1
                default: throw SessionError(line: n, message: "orbit is wind or tone")
                }
            case "chord":
                let rs = val.split(separator: " ").compactMap { number(String($0)) }
                guard !rs.isEmpty, rs.count <= 5 else { throw SessionError(line: n, message: "chord takes 1–5 ratios, like 1 3/2 2") }
                s.header[.chordN] = Float(rs.count)
                let slots: [K] = [.c1, .c2, .c3, .c4, .c5]
                for (i, r) in rs.enumerated() { s.header[slots[i]] = max(0.05, min(32, r)) }   // ratios over the tone, kept audible
            default:
                throw SessionError(line: n, message: "unknown setting \"\(key)\"")
            }
        }
        if s.length <= 0 { s.length = lastAt > 0 ? lastAt : 60 }
        if let e = s.edge {
            guard e < s.length else { throw SessionError(line: 0, message: "edge must come before the end") }
            if s.cool >= e { throw SessionError(line: 0, message: "cool must come before edge") }
            if s.release == nil { s.release = e }
            if s.release! < e { throw SessionError(line: 0, message: "release must come at or after edge") }
        }
        return s
    }

    static func load(_ url: URL) throws -> Session {
        let text = try String(contentsOf: url, encoding: .utf8)
        var s = try parse(text, id: url.deletingPathExtension().lastPathComponent)
        s.url = url
        return s
    }
}

/// The session files on disk, grouped by room. Bundled sessions are copied out on first run,
/// so you can edit your copies freely (or delete them: a deleted one stays deleted).
enum Library {
    /// Copies bundled sessions out. A file you haven't touched since it was installed is updated
    /// to the new bundled version; one you've edited is left alone.
    static func installDefaults() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.sessions, withIntermediateDirectories: true)
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Sessions"),
              let files = try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) else { return }
        let d = UserDefaults.standard
        var installed = d.dictionary(forKey: "installedSessions") as? [String: String] ?? [:]
        for f in files where f.pathExtension == "txt" {
            guard let fresh = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let name = f.lastPathComponent
            let dest = Paths.sessions.appendingPathComponent(name)
            let mine = try? String(contentsOf: dest, encoding: .utf8)
            // First time: install it. Later: update it only if it's still exactly as we left it.
            // (Deleted by you, it stays deleted: its record is the tombstone.)
            if (mine == nil && installed[name] == nil) || (mine != nil && mine == installed[name] && mine != fresh) {
                try? fresh.write(to: dest, atomically: true, encoding: .utf8)
                installed[name] = fresh
            } else if installed[name] == nil, mine == fresh {
                installed[name] = fresh
            }
        }
        d.set(installed, forKey: "installedSessions")
    }

    static func load(from dir: URL = Paths.sessions) -> (sessions: [Session], errors: [String]) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" && $0.lastPathComponent != "KNOBS.txt" }   // the reference card isn't a session
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [Session] = [], errs: [String] = []
        for f in files {
            do { out.append(try SessionParser.load(f)) } catch { errs.append("\(f.lastPathComponent): \(error)") }
        }
        let order = Room.allCases
        out.sort { (order.firstIndex(of: $0.room)!, $0.length) < (order.firstIndex(of: $1.room)!, $1.length) }
        return (out, errs)
    }
}
