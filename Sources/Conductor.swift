// The conductor runs a session: it walks the keyframes, waits for you when you stir, moves the
// spatial sounds, rings the bells, listens for your nod and shake and the AirPods stem, and decides
// how the session ends: a slow waking, or (in rest, when you've gone still) letting you sleep.
//
// It is driven by tick(dt), from a 30 Hz timer live or between render chunks offline.

import Foundation
import AVFoundation
import MediaPlayer
import CoreAudio

protocol Body: AnyObject {
    var receiving: Bool { get }
    var stillness: Double { get }
    var restless: Bool { get }
    var stillFor: Double { get }
    var yaw: Double { get }
    var pitch: Double { get }
}

extension Motion: Body {
    var stillness: Double { meter.stillness }
    var restless: Bool { meter.restless }
    var stillFor: Double { meter.stillFor }
}

/// For offline renders and tests: a listener who lies perfectly still (or doesn't, if told).
final class StillBody: Body {
    var receiving = false
    var stillness = 1.0
    var restless = false
    var stillFor = 9999.0
    var yaw = 0.0, pitch = 0.0
}

final class Conductor {
    enum Phase: Equatable { case idle, playing, waking, sleeping, stopping, test }

    let sound: SoundEngine
    let body: Body
    private(set) var session: Session?
    private(set) var phase = Phase.idle
    private(set) var clock: Double = 0          // session time (slows while you stir, stops on hold)
    private(set) var elapsed: Double = 0        // real time since start
    private(set) var hold = false
    private(set) var lingering = false

    /// Where an edging session is in its arc.
    enum Arc: Equatable { case build, rushing, plateau, cooling, void, countdown, release }
    private(set) var arc = Arc.build
    private(set) var pullBacks = 0
    private(set) var plateauTime: Double = 0
    private var rushTo: Double = 0, rushRate: Double = 1, rushThen = Arc.plateau
    private var rateNow: Double = 1
    private var voidLeft: Double = 0, countT: Double = 0, releaseT: Double = 0
    // the shapes edging lays over the session's own knobs, each eased
    private(set) var antic: Float = 0, crest: Float = 0, duck: Float = 0, lift: Float = 0
    private var paceCut = false
    private(set) var endedHow = ""
    private(set) var phaseTime: Double = 0
    var onChange: (() -> Void)?
    var onFinish: (() -> Void)?

    private var from: [Float] = []              // the knobs when waking or sleeping began
    private var stopFrom: Float = 1
    private var orbitAngle: Double = 0
    private var worldTurn: Double = 0
    private var swarmT: Double = 0
    private var nextBell = 0, bellCount: Float = 0, chimeCount: Float = 0
    private var rng = Rng(4242)
    private var stillSum: Double = 0, holds = 0
    private var chimedAt: Set<Int> = []
    private var activity: NSObjectProtocol?
    var testStep = ""

    init(sound: SoundEngine, body: Body) {
        self.sound = sound
        self.body = body
    }

    var isActive: Bool { phase != .idle }
    /// The output the session began on; if the system switches away from it, the session stops.
    private var outputDevice: AudioDeviceID = 0
    var depth: Double { guard let s = session, s.length > 0 else { return 0 } ; return min(1, clock / s.length) }
    func now(_ key: K) -> Float { sound[key] }

    // MARK: - Starting and ending

    func play(_ s: Session) {
        if isActive { finish("replaced") }
        if !sound.offline { outputDevice = SoundEngine.defaultOutputDevice() }
        session = s
        clock = 0; elapsed = 0; hold = false; lingering = false; endedHow = ""
        arc = .build; pullBacks = 0; plateauTime = 0
        antic = 0; crest = 0; duck = 0; lift = 0; paceCut = false; releaseT = 0; rateNow = 1
        stillSum = 0; holds = 0; orbitAngle = 0; worldTurn = 0; swarmT = 0; chimedAt = []
        for key in K.allCases where key.rawValue > K.flux.rawValue && key.rawValue < K.bellTrig0.rawValue {
            sound[key] = s.header[key] ?? key.defaultValue
        }
        sound.setSpace(s.space)
        apply(s.snapshot(at: 0), fade: 0)
        phase = .playing
        phaseTime = 0
        live { self.beginLive() }
        onChange?()
    }

    func wake() {
        guard phase == .playing || phase == .sleeping else { return }
        from = K.keyframable.map { sound[$0] }
        if phase == .sleeping { from[K.master.rawValue] = sound[.master] }
        phase = .waking
        phaseTime = 0
        chimedAt = []
        onChange?()
    }

    func sleep() {
        guard phase == .playing else { return }
        from = K.keyframable.map { sound[$0] }
        phase = .sleeping
        phaseTime = 0
        onChange?()
    }

    /// A quick, still-gentle stop (a few seconds' fade).
    func stop() {
        guard isActive, phase != .stopping else { return }
        stopFrom = sound[.master]
        phase = .stopping
        phaseTime = 0
        onChange?()
    }

    /// Jump to a point in the session (tests and renders); the fade-in counts as done.
    func seek(_ t: Double) {
        guard phase == .playing, let s = session else { return }
        clock = min(s.length - 0.01, max(0, t))
        elapsed = max(elapsed, s.fadeIn)
    }

    func toggleHold() {
        guard phase == .playing else { return }
        hold.toggle()
        if hold { holds += 1 }
        chime(hold ? 587.3 : 784)
        onChange?()
    }

    func earTest() {
        if isActive { finish("replaced") }
        if !sound.offline { outputDevice = SoundEngine.defaultOutputDevice() }
        session = nil
        for key in K.allCases { sound[key] = key == .master ? 1 : 0 }
        sound[.bell] = 0.8
        sound[.chimeFreq] = 880
        sound.setSpace("room")
        phase = .test
        phaseTime = 0
        live { self.beginLive() }
        onChange?()
    }

    private func finish(_ how: String) {
        let wasTest = phase == .test
        endedHow = how
        sound[.master] = 0
        sound[.testL] = 0; sound[.testR] = 0
        if let s = session, !wasTest, phase != .idle, !sound.offline { journal(s, how) }
        phase = .idle
        live { self.endLive() }
        onChange?()
        onFinish?()
    }

    private func journal(_ s: Session, _ how: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let still = elapsed > 0 ? Int(stillSum / elapsed * 100) : 0
        let motion = body.receiving ? "still \(still)%" : "no head data"
        let line = "\(f.string(from: Date()))  \(s.id)  \(timecode(clock)) of \(timecode(s.length)) in \(timecode(elapsed))  \(motion)  holds \(holds)\(s.hasEdge ? "  edges \(pullBacks)" : "")  \(how)\n"
        if let h = try? FileHandle(forWritingTo: Paths.journal) {
            // The throwing calls: a full disk mustn't take the app down with it.
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: Paths.journal, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - The tick

    func tick(_ dt: Double) {
        guard isActive else { return }
        phaseTime += dt
        elapsed += dt
        switch phase {
        case .idle: return
        case .playing: tickPlaying(dt)
        case .waking: tickWaking(dt)
        case .sleeping: tickSleeping(dt)
        case .stopping:
            let u = min(1, phaseTime / 3)
            sound[.master] = stopFrom * Float(1 - u)
            if u >= 1 { finish("stopped") }
        case .test: tickTest()
        }
        if phase != .idle && phase != .test { moveThings(dt) }
        if body.receiving { stillSum += body.stillness * dt }
        aim()
    }

    private func tickPlaying(_ dt: Double) {
        guard let s = session else { return }
        if s.hasEdge {
            tickArc(s, dt)
        } else {
            lingering = !hold && body.receiving && body.restless
            let rate = hold ? 0 : lingering ? 0.4 : 1
            clock = min(s.length, clock + dt * rate)
        }
        let fade = s.fadeIn > 0 ? min(1, elapsed / s.fadeIn) : 1
        var v = s.snapshot(at: clock)
        if s.hasEdge { shape(s, &v, dt) }
        apply(v, fade: Float(fade))
        if clock >= s.length {
            switch s.ending {
            case .wake: wake()
            case .sleep: sleep()
            case .auto:
                if s.room == .rest && (!body.receiving || body.stillFor > 150) { sleep() } else { wake() }
            }
        }
    }

    /// Edging. Stirring here is arousal, not distraction, so it speeds the build rather than slowing it.
    ///
    ///   build ─► (edge) plateau ─► hold runs out ─► cooling ─► void (the sea alone) ─► build …
    ///      └─ nod: rush to the edge     └─ nod, or the last cycle: countdown ─► release (the pace stops dead)
    ///                                                                    └─ nod later in release: again
    private func tickArc(_ s: Session, _ dt: Double) {
        lingering = false
        guard !hold, let edge = s.edge else { rateNow = 0; return }
        switch arc {
        case .build:
            let activity = body.receiving ? 1 - body.stillness : 0
            rateNow = 1 + s.drive * activity
            clock += dt * rateNow
            if clock >= edge { clock = edge; enterPlateau() }
        case .rushing:
            rateNow = rushRate
            let step = rushRate * dt
            if abs(rushTo - clock) <= step {
                clock = rushTo
                if rushThen == .plateau { enterPlateau() } else if rushThen == .void { enterVoid() } else { arc = rushThen }
            } else { clock += rushTo > clock ? step : -step }
        case .plateau:
            rateNow = 0
            plateauTime += dt
            // each hold a little longer than the last
            if plateauTime >= s.hold * (1 + 0.15 * Double(pullBacks)) {
                pullBacks += 1
                // a soft cap: after an hour and a half it lets you go at the next edge
                if (s.cycles > 0 && pullBacks >= s.cycles) || elapsed > 90 * 60 { beginCountdown() }
                else { rush(to: s.cool, over: 10, then: .void); arc = .cooling }
            }
        case .cooling:
            let step = rushRate * dt
            if clock - step <= s.cool { clock = s.cool; enterVoid() } else { clock -= step }
        case .void:
            voidLeft -= dt
            if voidLeft <= 0 { arc = .build; onChange?() }
        case .countdown:
            countT += dt
            // wordless: the pace quickens, bells climb
            let n = Int(countT / max(0.5, s.countdown / 10))
            if n > chimedAt.count {
                chimedAt.insert(chimedAt.count)
                let steps: [Float] = [1, 9 / 8, 5 / 4, 4 / 3, 3 / 2, 5 / 3, 15 / 8, 2, 9 / 4, 5 / 2, 3]
                ring(slot: n % 3, pitch: max(220, sound[.bellpitch]) * steps[min(steps.count - 1, n)], up: true)
            }
            if countT >= s.countdown { peak(s) }
        case .release:
            releaseT += dt
            clock = min(s.length, clock + dt)
        }
    }

    private func enterPlateau() {
        arc = .plateau
        plateauTime = 0
        onChange?()
    }

    /// The pull-back's near-silence: the sea alone, shorter each time.
    private func enterVoid() {
        arc = .void
        let lengths: [Double] = [45, 35, 28, 22, 18]
        voidLeft = lengths[min(lengths.count - 1, max(0, pullBacks - 1))]
        onChange?()
    }

    private func rush(to t: Double, over secs: Double, then: Arc) {
        rushTo = t
        rushRate = max(0.5, abs(t - clock) / secs)
        rushThen = then
        arc = .rushing
        onChange?()
    }

    private func beginCountdown() {
        arc = .countdown
        countT = 0
        chimedAt = []
        onChange?()
    }

    /// The crest: the pace stops dead, the chord blooms, and the release section plays from its start.
    private func peak(_ s: Session) {
        paceCut = true
        crest = 1
        antic = 0
        if let r = s.release, clock < r { clock = r }
        arc = .release
        releaseT = 0
        onChange?()
    }

    /// "I'm close" while building (rush to the edge); "let me go" at the edge (countdown, then release).
    /// Later in the release, "again" (back to the cool point to build once more). Never punished:
    /// a signal early is taken at its word.
    func signal() {
        guard phase == .playing, let s = session else { return }
        guard s.hasEdge, let edge = s.edge else { toggleHold(); return }
        switch arc {
        case .build, .cooling, .void:
            chime(659.3)
            rush(to: edge, over: min(12, max(3, (edge - clock) / 6)), then: .plateau)
        case .plateau, .rushing:
            chime(880)
            beginCountdown()
        case .release where releaseT > 30:
            chime(659.3)
            paceCut = false
            rush(to: s.cool, over: 8, then: .void)
            pullBacks = max(pullBacks, 1)
        default: break
        }
    }

    /// Edging's own shapes over the session's knobs: the riser and a rising Shepard before each edge,
    /// the shimmer and a climbing heart at it, near-silence after a pull-back, the pace cut at the crest.
    private func shape(_ s: Session, _ v: inout [Float], _ dt: Double) {
        guard let edge = s.edge else { return }
        let f = Float(dt)
        func ease(_ x: inout Float, _ to: Float, up: Float, down: Float) {
            let t = to > x ? up : down
            x += (to - x) * min(1, f / t)
        }
        var anticTo: Float = 0
        switch arc {
        case .build,
             .rushing where rushThen == .plateau:
            let toEdge = (edge - clock) / max(0.1, rateNow)
            anticTo = Float(min(1, max(0, 1 - toEdge / 16)))
        case .countdown:
            anticTo = 1
        default: break
        }
        ease(&antic, anticTo, up: 1.5, down: 3)
        ease(&crest, arc == .plateau ? 1 : 0, up: 3, down: arc == .release ? 25 : 8)
        ease(&duck, arc == .cooling || arc == .void ? 1 : 0, up: 2.5, down: 6)
        ease(&lift, arc == .plateau || arc == .countdown ? s.lift : 0, up: 15, down: 40)

        func at(_ k: K) -> Float { v[k.rawValue] }
        func put(_ k: K, _ x: Float) { v[k.rawValue] = x }
        put(.riser, max(at(.riser), antic * 0.9))
        put(.shimmer, max(at(.shimmer), crest * 0.7))
        put(.bpm, min(124, at(.bpm) + lift))
        if antic > 0.02 {
            // the endless fall turns into an endless climb
            put(.shepard, max(at(.shepard), antic * 0.5))
            put(.fall, at(.fall) + (-2.5 - at(.fall)) * antic)
        }
        if arc == .countdown { put(.tempo, at(.tempo) * 1.3); put(.surge, max(at(.surge), 0.9)) }
        if arc == .countdown || (arc == .release && releaseT < 12) { put(.bell, max(at(.bell), 0.45)) }
        if duck > 0.001 {
            for k in [K.guide, .binaural, .orbit, .heart, .swarm, .shepard, .fire, .bells, .pulse, .pace, .riser, .shimmer, .surge] {
                put(k, at(k) * (1 - duck))
            }
            put(.bed, at(.bed) + (max(at(.bed), 0.4) - at(.bed)) * duck)
            put(.bright, at(.bright) * (1 - 0.3 * duck))
        }
        if paceCut { put(.pace, 0) }
    }

    private func ring(slot: Int, pitch: Float, up: Bool) {
        let az = Double(slot - 1) * 0.6
        sound.place(sound.bellNodes[slot], Float(2.5 * sin(az)), up ? 1.2 : 0, Float(-2.5 * cos(az)))
        bellCount += 1
        sound[[K.bellFreq0, .bellFreq1, .bellFreq2][slot]] = pitch
        sound[[K.bellTrig0, .bellTrig1, .bellTrig2][slot]] = bellCount
    }

    private func tickWaking(_ dt: Double) {
        guard let s = session else { finish("woke"); return }
        let u = min(1, phaseTime / s.wake)
        let e = Float(u * u * (3 - 2 * u))
        var to = from
        func set(_ k: K, _ v: Float) { to[k.rawValue] = v }
        let f = { (k: K) in self.from[k.rawValue] }
        set(.beat, 12); set(.breath, 10); set(.exhale, 0.5)
        set(.bright, min(1, f(.bright) + 0.2)); set(.glow, min(1, f(.glow) + 0.25))
        set(.pulse, 0); set(.surge, 0); set(.shepard, 0); set(.swarm, 0); set(.turn, 0)
        set(.heart, f(.heart) * 0.3); set(.binaural, f(.binaural) * 0.6); set(.tide, f(.tide) * 0.5)
        set(.fire, f(.fire) * 0.6); set(.swell, min(f(.swell), 0.5))
        set(.pace, 0); set(.riser, 0); set(.shimmer, 0)
        var v = zip(from, to).map { $0 + ($1 - $0) * e }
        let base = from[K.master.rawValue]
        v[K.master.rawValue] = u < 0.72 ? base : base * Float(1 - (u - 0.72) / 0.28)
        apply(v, fade: 1)
        for (i, mark) in [0.5, 0.78].enumerated() where u >= mark && !chimedAt.contains(i) {
            chimedAt.insert(i)
            chime(i == 0 ? 784 : 1046.5)
        }
        if u >= 1 { finish(endedHow.isEmpty ? "woke" : endedHow) }
    }

    private func tickSleeping(_ dt: Double) {
        guard let s = session else { finish("slept"); return }
        let tail = max(60, s.sleepTail)
        let settle = min(1, phaseTime / 150)          // the music leaves over a few minutes
        var v = from
        for k in [K.guide, .binaural, .orbit, .bells, .heart, .swarm, .shepard, .pulse, .surge, .fire, .pace, .riser, .shimmer] {
            v[k.rawValue] = from[k.rawValue] * Float(1 - settle)
        }
        v[K.bed.rawValue] = from[K.bed.rawValue] + (max(from[K.bed.rawValue], 0.5) - from[K.bed.rawValue]) * Float(settle)
        v[K.bright.rawValue] = from[K.bright.rawValue] * Float(1 - 0.25 * settle)
        let fadeLen = min(600, tail / 3)
        let master = from[K.master.rawValue]
        v[K.master.rawValue] = phaseTime < tail - fadeLen ? master : master * Float(max(0, (tail - phaseTime) / fadeLen))
        apply(v, fade: 1)
        if phaseTime >= tail { finish("slept") }
    }

    private func tickTest() {
        let t = phaseTime
        sound[.testL] = (0.3..<3.3).contains(t) ? 1 : 0
        sound[.testR] = (4..<7).contains(t) ? 1 : 0
        if t < 3.6 { testStep = "left ear only" }
        else if t < 7.5 { testStep = "right ear only" }
        else if t < 27 { testStep = "a bell straight ahead: turn your head slowly; it should stay put in the room" }
        else { testStep = ""; finish("tested"); return }
        if t >= 7.5 {
            let n = Int((t - 7.5) / 2.2)
            if n >= nextBell {
                nextBell = n + 1
                sound.place(sound.bellNodes[0], 0, 0.2, -2.5)
                bellCount += 1
                sound[.bellFreq0] = 523.25
                sound[.bellTrig0] = bellCount
            }
        } else {
            nextBell = 0
        }
    }

    // MARK: - Space

    private func moveThings(_ dt: Double) {
        let spin = Double(sound[.spin]), r = Double(sound[.radius]), rise = Float(sound[.rise])
        if spin != 0 { orbitAngle += 2 * .pi * dt / spin }
        sound.place(sound.orbitNode, Float(r * sin(orbitAngle)), rise, Float(-r * cos(orbitAngle)))

        worldTurn += Double(sound[.turn]) * dt / 60

        // the swarm: two paths that loop around and through your head
        let flux = Double(max(0.2, sound[.flux]))
        swarmT += dt * flux * 0.35
        for (i, node) in sound.swarmNodes.enumerated() {
            let t = swarmT * (i == 0 ? 1 : 1.37) + Double(i) * 2.1
            let rad = 0.12 + 0.75 * abs(sin(t * 0.31))
            let x = rad * sin(t * 1.1), z = rad * cos(t * 0.83), y = 0.35 * sin(t * 0.57 + 1)
            sound.place(node, Float(x), Float(y), Float(z))
        }

        // bells: a Poisson rain at the session's rate, each from somewhere new
        let perMin = Double(sound[.bells])
        if perMin > 0, Double(rng.unit()) < perMin / 60 * dt {
            let slot = nextBell % 3
            nextBell += 1
            let az = Double(rng.next()) * .pi * 0.85
            let dist = 2.5 + 3 * Double(rng.unit())
            let h = Double(sound[.height]) * 2.2 + Double(rng.next()) * 0.4
            sound.place(sound.bellNodes[slot], Float(dist * sin(az)), Float(h), Float(-dist * cos(az)))
            let steps: [Float] = [1, 9.0 / 8, 5.0 / 4, 3.0 / 2, 5.0 / 3, 2]
            let pitch = sound[.bellpitch] * steps[Int(rng.unit() * 5.99)]
            bellCount += 1
            sound[[K.bellFreq0, .bellFreq1, .bellFreq2][slot]] = pitch
            sound[[K.bellTrig0, .bellTrig1, .bellTrig2][slot]] = bellCount
        }
    }

    /// Turn the listener with your head (so the room stays put), plus the room's own slow turning.
    private func aim() {
        let yaw = (Prefs.flipYaw ? -1 : 1) * body.yaw + worldTurn
        let pitch = (Prefs.flipPitch ? -1 : 1) * body.pitch
        sound.setListener(yaw: Float(yaw), pitch: Float(max(-80, min(80, pitch))), roll: 0)
    }

    private func chime(_ f: Float) {
        chimeCount += 1
        sound[.chimeFreq] = f
        sound[.chimeTrig] = chimeCount
    }

    private func apply(_ values: [Float], fade: Float) {
        for (i, key) in K.keyframable.enumerated() { sound[key] = values[i] }
        sound[.master] = values[K.master.rawValue] * fade
    }

    // MARK: - Live plumbing (engine, sleep, Now Playing, the AirPods stem, your head)

    private func live(_ f: () -> Void) { if !sound.offline { f() } }

    private func beginLive() {
        do { if !sound.engine.isRunning { try sound.start() } } catch { NSLog("Daymare: engine start failed: \(error)") }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "a Daymare session")
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [MPMediaItemPropertyTitle: "Daymare", MPNowPlayingInfoPropertyPlaybackRate: 1.0]
        info.playbackState = .playing
        Motion.shared.gesturesOn = phase == .playing
        if phase == .playing { Motion.shared.recenter() }
    }

    private func endLive() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        Motion.shared.gesturesOn = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.isActive else { return }
            self.sound.stop()
        }
    }

    /// The stem: one press wakes you (a second press while waking stops sooner), two presses hold.
    /// In rest, a pause that arrives while you've been still a long time is probably the AirPods
    /// deciding you've fallen asleep, so it lets you sleep instead.
    func wireRemote() {
        let c = MPRemoteCommandCenter.shared()
        let press: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            switch self.phase {
            case .playing:
                if self.session?.room == .rest && self.body.receiving && self.body.stillFor > 120 { self.sleep() } else { self.wake() }
            case .waking, .sleeping, .test: self.stop()
            default: break
            }
            return .success
        }
        for cmd in [c.togglePlayPauseCommand, c.pauseCommand, c.playCommand] {
            cmd.isEnabled = true
            cmd.addTarget(handler: press)
        }
        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { [weak self] _ in self?.signal(); return .success }
        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { [weak self] _ in self?.wake(); return .success }

        Motion.shared.onGesture = { [weak self] g in
            guard let self, self.phase == .playing else { return }
            switch g {
            case .nod: self.signal()
            case .shake: self.chime(987.8); self.wake()
            }
        }

        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: sound.engine, queue: .main) { [weak self] _ in
            guard let self, self.isActive else { return }
            // The output changed under us. If it's no longer the device the session began on (the AirPods
            // went back in their case, say), stop: a session must never carry on out of the speakers.
            if !self.sound.offline, SoundEngine.defaultOutputDevice() != self.outputDevice {
                self.sound.stop()
                self.finish("headphones gone")
                return
            }
            try? self.sound.start()
        }
    }
}
