// The voices: everything Daymare plays is synthesized here, sample by sample, on the audio thread.
// Nothing is recorded or borrowed. Each voice reads its knobs from the shared Float array `k`
// (written by the conductor about 30 times a second) and glides toward them per sample, so
// nothing ever clicks. No allocation, no locks, no printing in any render function.

import Foundation

@inline(__always) func kv(_ k: UnsafeMutablePointer<Float>, _ key: K) -> Float { k[key.rawValue] }

/// One-pole glide toward a target.
struct Glide {
    var v: Float
    init(_ v: Float) { self.v = v }
    @inline(__always) mutating func to(_ t: Float, _ a: Float) -> Float { v += (t - v) * a; return v }
}

/// xorshift32: fast, deterministic noise in -1…1.
struct Rng {
    var s: UInt32
    init(_ seed: UInt32) { s = seed == 0 ? 0x9E3779B9 : seed }
    @inline(__always) mutating func next() -> Float {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5
        return Float(s) / Float(UInt32.max) * 2 - 1
    }
    @inline(__always) mutating func unit() -> Float { (next() + 1) * 0.5 }
}

/// Paul Kellet's economy pink filter.
struct Pink {
    var b0: Float = 0, b1: Float = 0, b2: Float = 0
    @inline(__always) mutating func step(_ w: Float) -> Float {
        b0 = 0.99765 * b0 + w * 0.0990460
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        return (b0 + b1 + b2 + w * 0.1848) * 0.22
    }
}

/// Leaky-integrated white noise.
struct Brown {
    var b: Float = 0
    @inline(__always) mutating func step(_ w: Float) -> Float {
        b = (b + 0.02 * w) / 1.02
        return b * 3.2
    }
}

/// Topology-preserving state-variable filter; we use the band-pass.
struct SVF {
    var ic1: Float = 0, ic2: Float = 0
    var a1: Float = 0, a2: Float = 0, a3: Float = 0
    mutating func set(_ fc: Float, q: Float, sr: Float) {
        let g = tanf(.pi * max(20, min(fc.isFinite ? fc : 1000, sr * 0.45)) / sr)
        let k = 1 / q
        a1 = 1 / (1 + g * (g + k)); a2 = g * a1; a3 = g * a2
    }
    @inline(__always) mutating func band(_ x: Float) -> Float {
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2
        return v1
    }
}

/// 0 at the bottom of the out-breath, 1 at the top of the in-breath; a smooth rise, a longer smooth fall.
@inline(__always) func breathEnvelope(_ phase: Double, exhale: Float) -> Float {
    let inhale = Double(min(0.85, max(0.15, 1 - exhale)))
    let p = phase - floor(phase)
    if p < inhale { return Float(0.5 - 0.5 * cos(.pi * p / inhale)) }
    return Float(0.5 + 0.5 * cos(.pi * (p - inhale) / (1 - inhale)))
}

/// Shared clock slots, written by the bed (which runs first in each cycle) and read by the others.
enum Clock: Int { case breath, pulse, surge, frames, env, count }

// MARK: - Bed: noise, binaural carriers, chimes and ear tests (stereo, never spatialized)

final class BedVoice {
    let k: UnsafeMutablePointer<Float>, clock: UnsafeMutablePointer<Double>
    let sr: Float, a: Float
    var master = Glide(0), beat = Glide(6), carrier = Glide(200), bin = Glide(0), pulse = Glide(0)
    var breath = Glide(6), exhale = Glide(0.6), bed = Glide(0), bright = Glide(0.5), tide = Glide(0)
    var color = Glide(1), surge = Glide(0), wave = Glide(40), tl = Glide(0), tr = Glide(0)
    var phL = 0.0, phR = 0.0, breathPh = 0.0, pulsePh = 0.0, surgePh = 0.0, frames = 0.0, testPh = 0.0
    var rl = Rng(11), rr = Rng(23)
    var pl = Pink(), pr = Pink(), bl = Brown(), br = Brown()
    var l1: Float = 0, l2: Float = 0, r1: Float = 0, r2: Float = 0
    var lastChime: Float = 0, chimeEnv: Float = 0, chimePh = 0.0, chimeF: Float = 880, chimeDecay: Float

    init(k: UnsafeMutablePointer<Float>, clock: UnsafeMutablePointer<Double>, sr: Double) {
        self.k = k; self.clock = clock; self.sr = Float(sr)
        a = 1 - expf(-1 / (0.06 * Float(sr)))
        chimeDecay = expf(-1 / (1.4 * Float(sr)))
    }

    func render(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ n: Int) {
        let srd = Double(sr)
        let trig = kv(k, .chimeTrig)
        if trig != lastChime { lastChime = trig; chimeEnv = 1; chimePh = 0; chimeF = kv(k, .chimeFreq) }
        for i in 0..<n {
            let m = master.to(kv(k, .master), a)
            let bt = beat.to(kv(k, .beat), a), cr = carrier.to(kv(k, .carrier), a)
            let bg = bin.to(kv(k, .binaural), a), pu = pulse.to(kv(k, .pulse), a)
            let brr = breath.to(kv(k, .breath), a), ex = exhale.to(kv(k, .exhale), a)
            let bd = bed.to(kv(k, .bed), a), bri = bright.to(kv(k, .bright), a), td = tide.to(kv(k, .tide), a)
            let col = color.to(kv(k, .color), a)
            _ = surge.to(kv(k, .surge), a)
            let wv = wave.to(kv(k, .wave), a)

            breathPh += Double(max(1, brr)) / 60 / srd
            pulsePh += Double(bt) / srd
            surgePh += 1 / Double(max(4, wv)) / srd
            let env = breathEnvelope(breathPh, exhale: ex)

            // the bed: a sea that breathes in with you
            let wl = rl.next(), wr = rr.next()
            let nl = pl.step(wl) * (1 - col) + bl.step(wl) * col
            let nr = pr.step(wr) * (1 - col) + br.step(wr) * col
            let b = min(1, max(0, bri + td * 0.22 * (env - 0.5)))
            let fc = 110 * powf(80, b)
            let g = 1 - expf(-2 * .pi * fc / sr)
            l1 += (nl - l1) * g; l2 += (l1 - l2) * g
            r1 += (nr - r1) * g; r2 += (r1 - r2) * g
            let am = 1 - pu * 0.5 * (1 - Float(cos(2 * .pi * pulsePh)))
            let bedGain = bd * (1 - td * 0.65 + td * 0.65 * env) * am * 1.6
            var outL = l2 * bedGain, outR = r2 * bedGain

            // binaural carriers: each ear hears only its own
            phL += Double(cr - bt / 2) / srd
            phR += Double(cr + bt / 2) / srd
            if phL > 1 { phL -= 1 }
            if phR > 1 { phR -= 1 }
            outL += Float(sin(2 * .pi * phL)) * bg * 0.11
            outR += Float(sin(2 * .pi * phR)) * bg * 0.11

            // chime: a soft confirmation ping, dead centre
            if chimeEnv > 0.0001 {
                chimePh += Double(chimeF) / srd
                let c = (Float(sin(2 * .pi * chimePh)) + 0.3 * Float(sin(2 * .pi * chimePh * 2.76))) * chimeEnv * 0.12
                chimeEnv *= chimeDecay
                outL += c; outR += c
            }

            // ear test tones
            let tL = tl.to(kv(k, .testL), a), tR = tr.to(kv(k, .testR), a)
            if tL > 0.0001 || tR > 0.0001 {
                testPh += 523.25 / srd
                let s = Float(sin(2 * .pi * testPh)) * 0.15
                outL += s * tL; outR += s * tR
            }

            L[i] = outL * m
            R[i] = outR * m
            frames += 1
            if i == n - 1 {
                clock[Clock.breath.rawValue] = breathPh
                clock[Clock.pulse.rawValue] = pulsePh
                clock[Clock.surge.rawValue] = surgePh
                clock[Clock.frames.rawValue] = frames
                clock[Clock.env.rawValue] = Double(env)
            }
        }
    }
}

/// Values every non-bed voice needs from the shared clock, advanced locally inside a buffer.
struct Follow {
    var breath = 0.0, pulse = 0.0, surge = 0.0
    mutating func sync(_ c: UnsafeMutablePointer<Double>) {
        breath = c[Clock.breath.rawValue]; pulse = c[Clock.pulse.rawValue]; surge = c[Clock.surge.rawValue]
    }
}

// MARK: - Pad: the breathing chord, and the endless fall (stereo, into the reverb)

final class PadVoice {
    let k: UnsafeMutablePointer<Float>, clock: UnsafeMutablePointer<Double>
    let sr: Float, a: Float
    var master = Glide(0), guide = Glide(0), swell = Glide(1), tone = Glide(110), glow = Glide(0.4)
    var pulse = Glide(0), surge = Glide(0), beat = Glide(6), breath = Glide(6), exhale = Glide(0.6), wave = Glide(40)
    var shep = Glide(0), fall = Glide(1), riser = Glide(0), shimmer = Glide(0)
    var rsvf = SVF(), rrng = Rng(91), shPh2 = [Double](repeating: 0, count: 10), trem = 0.0, rcount = 0
    var ratios = [Glide](repeating: Glide(1), count: 5)
    var ph = [Double](repeating: 0, count: 10)
    var shPh = [Double](repeating: 0, count: 9)
    var shift = 0.0
    var f = Follow()
    var l1: Float = 0, l2: Float = 0, r1: Float = 0, r2: Float = 0
    static let slots: [K] = [.c1, .c2, .c3, .c4, .c5]
    static let detune: [Double] = [pow(2, -2.0 / 1200), pow(2, 2.0 / 1200)]

    init(k: UnsafeMutablePointer<Float>, clock: UnsafeMutablePointer<Double>, sr: Double) {
        self.k = k; self.clock = clock; self.sr = Float(sr)
        a = 1 - expf(-1 / (0.08 * Float(sr)))
        for i in 0..<5 { ratios[i] = Glide(kv(k, [K.c1, .c2, .c3, .c4, .c5][i])) }
        for i in 0..<10 { ph[i] = Double(i) * 0.137 }
    }

    func render(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ n: Int) {
        let srd = Double(sr)
        f.sync(clock)
        let count = Int(min(5, max(1, kv(k, .chordN))))
        let slots = PadVoice.slots
        for i in 0..<n {
            let m = master.to(kv(k, .master), a)
            let gd = guide.to(kv(k, .guide), a), sw = swell.to(kv(k, .swell), a)
            let tn = tone.to(kv(k, .tone), a), gl = glow.to(kv(k, .glow), a)
            let pu = pulse.to(kv(k, .pulse), a), sg = surge.to(kv(k, .surge), a)
            let bt = beat.to(kv(k, .beat), a), brr = breath.to(kv(k, .breath), a), ex = exhale.to(kv(k, .exhale), a)
            let wv = wave.to(kv(k, .wave), a)
            let sh = shep.to(kv(k, .shepard), a), fl = fall.to(kv(k, .fall), a)
            let rz = riser.to(kv(k, .riser), a), sm = shimmer.to(kv(k, .shimmer), a)

            f.breath += Double(max(1, brr)) / 60 / srd
            f.pulse += Double(bt) / srd
            f.surge += 1 / Double(max(4, wv)) / srd
            let env = breathEnvelope(f.breath, exhale: ex)
            let surgeMul = 1 - sg * 0.55 + sg * 0.55 * Float(sin(2 * .pi * f.surge))
            let am = 1 - pu * 0.45 * (1 - Float(cos(2 * .pi * f.pulse)))

            var sl: Float = 0, sr2: Float = 0
            if gd > 0.0005 {
                for v in 0..<count {
                    let r = ratios[v].to(kv(k, slots[v]), a)
                    let base = Double(tn * r)
                    for o in 0..<2 {
                        let idx = v * 2 + o
                        ph[idx] += base * PadVoice.detune[o] / srd
                        if ph[idx] > 1 { ph[idx] -= 1 }
                        let s = Float(sin(2 * .pi * ph[idx]))
                        let c = Float(cos(2 * .pi * ph[idx]))
                        let w = s + 0.28 * (2 * s * c) + 0.09 * s * (3 - 4 * s * s)
                        // higher chord tones a little quieter
                        let lvl: Float = 1 / (1 + Float(v) * 0.35)
                        if o == 0 { sl += w * lvl * 0.8; sr2 += w * lvl * 0.2 } else { sl += w * lvl * 0.2; sr2 += w * lvl * 0.8 }
                    }
                }
                let norm: Float = 1 / Float(count)
                let gb = min(1, max(0, gl + 0.3 * sw * (env - 0.5)))
                let fc = 140 * powf(32, gb)
                let g = 1 - expf(-2 * .pi * fc / sr)
                l1 += (sl * norm - l1) * g; l2 += (l1 - l2) * g
                r1 += (sr2 * norm - r1) * g; r2 += (r1 - r2) * g
            } else {
                l1 *= 0.999; l2 *= 0.999; r1 *= 0.999; r2 *= 0.999
            }
            let padGain = gd * (1 - sw + sw * env) * surgeMul * am * 0.55
            var outL = tanhf(l2 * 1.6) * padGain
            var outR = tanhf(r2 * 1.6) * padGain

            // Shepard–Risset: nine octave-spaced partials sliding forever under a fixed bell-shaped window
            if sh > 0.0005 {
                shift -= Double(fl) / 60 / srd
                shift -= floor(shift)
                var s: Float = 0
                for p in 0..<9 {
                    var pos = Double(p) + shift * 1
                    pos = pos.truncatingRemainder(dividingBy: 9)
                    if pos < 0 { pos += 9 }
                    let freq = 27.5 * pow(2, pos)
                    shPh[p] += freq / srd
                    if shPh[p] > 1 { shPh[p] -= 1 }
                    let w = Float(0.5 - 0.5 * cos(2 * .pi * pos / 9))
                    s += Float(sin(2 * .pi * shPh[p])) * w * w
                }
                s *= sh * 0.05
                outL += s; outR += s
            }

            // the riser: a rush of air climbing toward the crest
            if rz > 0.0005 {
                if rcount % 32 == 0 { rsvf.set(220 * powf(18, rz), q: 3.5, sr: sr) }
                rcount += 1
                let r = rsvf.band(rrng.next()) * rz * rz * 0.5
                outL += r; outR += r
            }
            // the shimmer: the chord two and three octaves up, trembling at 40 Hz, entering at the edge
            if sm > 0.0005 {
                trem += 40 / srd
                if trem > 1 { trem -= 1 }
                var s: Float = 0
                for v in 0..<count {
                    for j in 0..<2 {
                        let mult = j == 0 ? 2.0 : 4.0
                        let idx = v * 2 + j
                        shPh2[idx] += Double(tn * kv(k, PadVoice.slots[v])) * mult / srd
                        if shPh2[idx] > 1 { shPh2[idx] -= 1 }
                        s += Float(sin(2 * .pi * shPh2[idx])) * (j == 0 ? 1 : 0.5)
                    }
                }
                let tr = 0.75 + 0.25 * Float(sin(2 * .pi * trem))
                let x = s / Float(count) * sm * tr * 0.07
                outL += x * (1 + 0.2 * env); outR += x * (1.2 - 0.2 * env)
            }

            L[i] = outL * m
            R[i] = outR * m
        }
    }
}

// MARK: - Pace: a low, centred thump to follow (stereo, dry)

/// Tempo and pattern only change on the bar line, and tempo by at most 8% a bar,
/// so the pace never lurches.
final class PaceVoice {
    let k: UnsafeMutablePointer<Float>
    let sr: Float, a: Float
    var master = Glide(0), level = Glide(0)
    var tempo: Float = 72, pattern = 0, bar = 0, beatPos = 0.0, step = -1
    var env: Float = 0, pitchEnv: Float = 0, click: Float = 0, accent: Float = 1, ph = 0.0
    var rng = Rng(808), lp: Float = 0

    init(k: UnsafeMutablePointer<Float>, sr: Double) {
        self.k = k; self.sr = Float(sr)
        a = 1 - expf(-1 / (0.06 * Float(sr)))
        tempo = kv(k, .tempo)
    }

    /// Which eighth-notes (0…7) of this bar sound.
    @inline(__always) static func fires(_ pattern: Int, _ bar: Int, _ e: Int) -> Bool {
        switch pattern {
        case 1: return true                                         // doubles
        case 2: return e == 0 || e == 3 || e == 4 || e == 7         // swing
        case 3: return bar % 2 == 0 && e % 2 == 0                   // stop-go: a bar on, a bar off
        case 4: return bar % 4 != 3 && (e == 0 || e == 2 || e == 4) // break: three and a rest, every fourth bar silent
        case 5: return e == 0 || e == 4                             // halves
        default: return e % 2 == 0                                  // steady
        }
    }

    func render(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ n: Int) {
        let srd = Double(sr)
        let decay = expf(-1 / (0.11 * sr)), pdec = expf(-1 / (0.035 * sr)), cdec = expf(-1 / (0.004 * sr))
        let g = 1 - expf(-2 * .pi * 900 / sr)
        for i in 0..<n {
            let m = master.to(kv(k, .master), a), lv = level.to(kv(k, .pace), a)
            beatPos += Double(tempo) / 60 / srd
            if beatPos >= 4 {
                beatPos -= 4
                bar += 1
                let target = max(20, min(220, kv(k, .tempo)))
                tempo = min(tempo * 1.08, max(tempo * 0.92, target))
                let p = kv(k, .pattern)
                pattern = p.isFinite ? Int(max(0, min(5, p)).rounded()) : 0
            }
            let e = Int(beatPos * 2)
            if e != step {
                step = e
                if lv > 0.0005 && PaceVoice.fires(pattern, bar, e) {
                    env = 1; pitchEnv = 1; click = 1
                    accent = e == 0 ? 1 : e % 2 == 0 ? 0.78 : 0.55
                }
            }
            if env < 0.00005 { L[i] = 0; R[i] = 0; continue }
            ph += Double(50 + 38 * pitchEnv) / srd
            if ph > 1 { ph -= 1 }
            let s = Float(sin(2 * .pi * ph)) + 0.5 * Float(sin(4 * .pi * ph)) + 0.22 * Float(sin(6 * .pi * ph))
            lp += (rng.next() - lp) * g
            let out = (s * env * 0.55 + lp * click * 1.2) * accent * lv * m * 0.6
            L[i] = out; R[i] = out
            env *= decay; pitchEnv *= pdec; click *= cdec
        }
    }
}

// MARK: - Spatial voices (mono; the environment node places them in the room)

/// A struck bronze bell: church-bell partials (hum, prime, tierce, quint, nominal…), each with its own decay.
final class BellVoice {
    let k: UnsafeMutablePointer<Float>
    let sr: Float, a: Float, slot: Int
    var master = Glide(0), gain = Glide(0)
    static let trigKeys: [K] = [.bellTrig0, .bellTrig1, .bellTrig2]
    static let freqKeys: [K] = [.bellFreq0, .bellFreq1, .bellFreq2]
    static let ratios: [Double] = [0.5, 1.0, 1.183, 1.506, 2.0, 2.514, 2.662, 3.011]
    static let amps: [Float] = [0.45, 0.5, 0.42, 0.22, 0.35, 0.18, 0.12, 0.1]
    static let secs: [Float] = [9, 6, 4.5, 3, 2.6, 1.6, 1.2, 0.9]
    var decays = [Float](repeating: 0, count: 8)
    var env = [Float](repeating: 0, count: 8)
    var ph = [Double](repeating: 0, count: 8)
    var base: Double = 440, last: Float = 0, attack: Float = 1

    init(k: UnsafeMutablePointer<Float>, sr: Double, slot: Int) {
        self.k = k; self.sr = Float(sr); self.slot = slot
        a = 1 - expf(-1 / (0.05 * Float(sr)))
        for i in 0..<8 { decays[i] = expf(-1 / (BellVoice.secs[i] * Float(sr))) }
    }

    func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        let trigKey = BellVoice.trigKeys[slot]
        let freqKey = BellVoice.freqKeys[slot]
        let t = kv(k, trigKey)
        if t != last {
            last = t
            base = Double(kv(k, freqKey))
            for i in 0..<8 { env[i] = BellVoice.amps[i] }
            attack = 0
        }
        let srd = Double(sr)
        for i in 0..<n {
            let m = master.to(kv(k, .master), a), g = gain.to(kv(k, .bell), a)
            var s: Float = 0
            if env[0] > 0.00005 || env[1] > 0.00005 {
                for p in 0..<8 {
                    ph[p] += base * BellVoice.ratios[p] / srd
                    if ph[p] > 1 { ph[p] -= 1 }
                    s += Float(sin(2 * .pi * ph[p])) * env[p]
                    env[p] *= decays[p]
                }
                attack = min(1, attack + 1 / (0.003 * sr))
            }
            out[i] = s * attack * g * m * 0.5
        }
    }
}

/// The circling whisper: band-passed breath-noise (or a soft tone) that breathes with you.
final class OrbitVoice {
    let k: UnsafeMutablePointer<Float>, clock: UnsafeMutablePointer<Double>
    let sr: Float, a: Float
    var master = Glide(0), gain = Glide(0), pitch = Glide(800), toneMix = Glide(0)
    var surge = Glide(0), breath = Glide(6), exhale = Glide(0.6), wave = Glide(40)
    var rng = Rng(77), svf = SVF(), svf2 = SVF(), ph = 0.0, wob = 0.0
    var f = Follow()
    var count = 0

    init(k: UnsafeMutablePointer<Float>, clock: UnsafeMutablePointer<Double>, sr: Double) {
        self.k = k; self.clock = clock; self.sr = Float(sr)
        a = 1 - expf(-1 / (0.08 * Float(sr)))
    }

    func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        let srd = Double(sr)
        f.sync(clock)
        for i in 0..<n {
            let m = master.to(kv(k, .master), a), g = gain.to(kv(k, .orbit), a)
            let p = pitch.to(kv(k, .whisper), a), tm = toneMix.to(kv(k, .orbitTone), a)
            let sg = surge.to(kv(k, .surge), a), brr = breath.to(kv(k, .breath), a), ex = exhale.to(kv(k, .exhale), a)
            let wv = wave.to(kv(k, .wave), a)
            f.breath += Double(max(1, brr)) / 60 / srd
            f.surge += 1 / Double(max(4, wv)) / srd
            wob += 0.11 / srd
            if g < 0.0005 { out[i] = 0; continue }
            let env = breathEnvelope(f.breath, exhale: ex)
            if count % 64 == 0 {
                let fc = p * (1 + 0.18 * Float(sin(2 * .pi * wob)) + 0.12 * env)
                svf.set(fc, q: 2.2, sr: sr)
                svf2.set(fc * 1.9, q: 3, sr: sr)
            }
            count += 1
            let w = rng.next()
            let wind = (svf.band(w) + 0.35 * svf2.band(w)) * 0.9
            ph += Double(p) * (1 + 0.003 * sin(2 * .pi * wob * 40)) / srd
            if ph > 1 { ph -= 1 }
            let tone = Float(sin(2 * .pi * ph)) * 0.2
            let surgeMul = 1 - sg * 0.6 + sg * 0.6 * Float(sin(2 * .pi * f.surge))
            out[i] = (wind * (1 - tm) + tone * tm) * (0.45 + 0.55 * env) * surgeMul * g * m
        }
    }
}

/// A slow, warm heartbeat: lub, then a softer dub.
final class HeartVoice {
    let k: UnsafeMutablePointer<Float>, clock: UnsafeMutablePointer<Double>
    let sr: Float, a: Float
    var master = Glide(0), gain = Glide(0), bpm = Glide(60), surge = Glide(0), wave = Glide(40)
    var beatPh = 0.0, t = 0.0, env: Float = 0, ph = 0.0, pitchEnv: Float = 0, dubDone = true, f = Follow()

    init(k: UnsafeMutablePointer<Float>, clock: UnsafeMutablePointer<Double>, sr: Double) {
        self.k = k; self.clock = clock; self.sr = Float(sr)
        a = 1 - expf(-1 / (0.2 * Float(sr)))
    }

    func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        let srd = Double(sr)
        let decay = expf(-1 / (0.075 * sr)), pdec = expf(-1 / (0.04 * sr))
        f.sync(clock)
        for i in 0..<n {
            let m = master.to(kv(k, .master), a), g = gain.to(kv(k, .heart), a)
            let b = bpm.to(kv(k, .bpm), a), sg = surge.to(kv(k, .surge), a), wv = wave.to(kv(k, .wave), a)
            f.surge += 1 / Double(max(4, wv)) / srd
            beatPh += Double(max(20, b)) / 60 / srd
            t += 1 / srd
            if beatPh >= 1 { beatPh -= 1; t = 0; env = 1; pitchEnv = 1; dubDone = false }
            if !dubDone && t > 0.29 { dubDone = true; env = max(env, 0.62); pitchEnv = 0.8 }
            let freq = 46 + 34 * Double(pitchEnv)
            ph += freq / srd
            if ph > 1 { ph -= 1 }
            let s = Float(sin(2 * .pi * ph)) + 0.35 * Float(sin(4 * .pi * ph))
            let surgeMul = 1 - sg * 0.4 + sg * 0.4 * Float(sin(2 * .pi * f.surge))
            out[i] = s * env * g * m * surgeMul * 0.7
            env *= decay; pitchEnv *= pdec
        }
    }
}

/// A hearth: low rumble that flickers, and sparks that pop.
final class FireVoice {
    let k: UnsafeMutablePointer<Float>
    let sr: Float, a: Float
    var master = Glide(0), gain = Glide(0), crackle = Glide(0.4)
    var rng = Rng(5), brown = Brown(), lp1: Float = 0, lp2: Float = 0, flicker: Float = 0.5, flickT: Float = 0.5
    var pop = SVF(), popEnv: Float = 0, popAmp: Float = 0, hiss = SVF(), count = 0

    init(k: UnsafeMutablePointer<Float>, sr: Double) {
        self.k = k; self.sr = Float(sr)
        a = 1 - expf(-1 / (0.1 * Float(sr)))
        hiss.set(5200, q: 0.8, sr: Float(sr))
    }

    func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        let g0 = 1 - expf(-2 * .pi * 260 / sr)
        let popDecay = expf(-1 / (0.006 * sr))
        for i in 0..<n {
            let m = master.to(kv(k, .master), a), g = gain.to(kv(k, .fire), a), cr = crackle.to(kv(k, .crackle), a)
            if g < 0.0005 { out[i] = 0; continue }
            let w = rng.next()
            let b = brown.step(w)
            lp1 += (b - lp1) * g0; lp2 += (lp1 - lp2) * g0
            if count % 512 == 0 { flickT = 0.35 + 0.65 * rng.unit() }
            count += 1
            flicker += (flickT - flicker) * 0.0004
            var s = lp2 * flicker * 1.4
            // sparks
            if rng.unit() < cr * cr * 14 / sr {
                pop.set(1400 + 3800 * rng.unit(), q: 6, sr: sr)
                popEnv = 1; popAmp = 0.3 + 0.7 * rng.unit()
            }
            if popEnv > 0.0005 {
                s += pop.band(w * popEnv) * popAmp * 3
                popEnv *= popDecay
            }
            s += hiss.band(w) * 0.025 * flicker
            out[i] = s * g * m
        }
    }
}

/// The swarm: tiny pitched grains, placed (by the conductor) on paths that pass through your head.
final class SwarmVoice {
    let k: UnsafeMutablePointer<Float>
    let sr: Float, a: Float, seed: UInt32
    var master = Glide(0), gain = Glide(0), flux = Glide(3)
    var rng: Rng, svf = SVF()
    var grainT: Float = 0, grainLen: Float = 0, grainF: Double = 800, chirp: Double = 0, ph = 0.0, wait: Float = 0

    init(k: UnsafeMutablePointer<Float>, sr: Double, seed: UInt32) {
        self.k = k; self.sr = Float(sr); self.seed = seed
        rng = Rng(seed)
        a = 1 - expf(-1 / (0.1 * Float(sr)))
    }

    func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        let srd = Double(sr)
        for i in 0..<n {
            let m = master.to(kv(k, .master), a), g = gain.to(kv(k, .swarm), a), fx = flux.to(kv(k, .flux), a)
            if g < 0.0005 { out[i] = 0; continue }
            if grainLen <= 0 {
                wait -= 1 / sr
                if wait <= 0 {
                    grainLen = (0.02 + 0.07 * rng.unit()) * sr
                    grainT = 0
                    grainF = Double(500 + 2600 * rng.unit() * rng.unit())
                    chirp = Double(rng.next()) * 0.6
                    svf.set(Float(grainF) * 1.3, q: 5, sr: sr)
                    let rate = 1.5 + max(0, fx) * 3.2
                    wait = (0.4 + 1.2 * rng.unit()) / rate
                }
                out[i] = 0
                continue
            }
            let u = grainT / grainLen
            let w = 0.5 - 0.5 * cosf(2 * .pi * u)
            ph += grainF * (1 + chirp * Double(u)) / srd
            if ph > 1 { ph -= 1 }
            let s = Float(sin(2 * .pi * ph)) * 0.6 + svf.band(rng.next()) * 0.8
            out[i] = s * w * g * m * 0.5
            grainT += 1
            if grainT >= grainLen { grainLen = 0 }
        }
    }
}
