// The sound graph. One AVAudioEngine at the output's rate (48 kHz on AirPods):
//
//   bed (noise, binaural, chime, ear tests) ──────────────────────────┐   never spatialized: each
//   pad (breathing chord, Shepard fall) ──► reverb ───────────────────┤   binaural carrier must stay
//   bells ×3, whisper, heart, fire, swarm ×2 (mono) ──► environment ──┤   in its own ear
//                       (HRTF, listener turned by your head)          ├─► bus ─► limiter ─► out
//
// The same graph renders offline for --selftest and --render.

import AVFoundation
import CoreAudio
import AudioToolbox

final class SoundEngine {
    let engine = AVAudioEngine()
    let sr: Double
    let k: UnsafeMutablePointer<Float>
    let clock: UnsafeMutablePointer<Double>
    let env = AVAudioEnvironmentNode()
    let reverb = AVAudioUnitReverb()
    let bus = AVAudioMixerNode()
    let limiter: AVAudioUnitEffect
    let offline: Bool

    let bed: BedVoice, pad: PadVoice, pace: PaceVoice
    let bells: [BellVoice], orbit: OrbitVoice, heart: HeartVoice, fire: FireVoice, swarm: [SwarmVoice]
    private(set) var bellNodes: [AVAudioSourceNode] = []
    private(set) var orbitNode: AVAudioSourceNode!
    private(set) var heartNode: AVAudioSourceNode!
    private(set) var fireNode: AVAudioSourceNode!
    private(set) var swarmNodes: [AVAudioSourceNode] = []

    init(offline: Bool = false, sampleRate: Double? = nil) throws {
        self.offline = offline
        let hw = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sr = sampleRate ?? (offline || hw < 8000 ? 48000 : hw)
        self.sr = sr

        let k = UnsafeMutablePointer<Float>.allocate(capacity: K.allCases.count)
        for key in K.allCases { k[key.rawValue] = key.defaultValue }
        k[K.master.rawValue] = 0
        self.k = k
        let clock = UnsafeMutablePointer<Double>.allocate(capacity: Clock.count.rawValue)
        clock.initialize(repeating: 0, count: Clock.count.rawValue)
        self.clock = clock

        bed = BedVoice(k: k, clock: clock, sr: sr)
        pad = PadVoice(k: k, clock: clock, sr: sr)
        pace = PaceVoice(k: k, sr: sr)
        bells = (0..<3).map { BellVoice(k: k, sr: sr, slot: $0) }
        orbit = OrbitVoice(k: k, clock: clock, sr: sr)
        heart = HeartVoice(k: k, clock: clock, sr: sr)
        fire = FireVoice(k: k, sr: sr)
        swarm = [SwarmVoice(k: k, sr: sr, seed: 301), SwarmVoice(k: k, sr: sr, seed: 977)]

        limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))

        let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let mono = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!

        if offline {
            try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 4096)
        }

        // stereo voices
        let bedV = bed, padV = pad, paceV = pace
        let paceNode = AVAudioSourceNode(format: stereo) { _, _, frames, abl in
            let b = UnsafeMutableAudioBufferListPointer(abl)
            paceV.render(b[0].mData!.assumingMemoryBound(to: Float.self), b[1].mData!.assumingMemoryBound(to: Float.self), Int(frames))
            return noErr
        }
        let bedNode = AVAudioSourceNode(format: stereo) { _, _, frames, abl in
            let b = UnsafeMutableAudioBufferListPointer(abl)
            bedV.render(b[0].mData!.assumingMemoryBound(to: Float.self), b[1].mData!.assumingMemoryBound(to: Float.self), Int(frames))
            return noErr
        }
        let padNode = AVAudioSourceNode(format: stereo) { _, _, frames, abl in
            let b = UnsafeMutableAudioBufferListPointer(abl)
            padV.render(b[0].mData!.assumingMemoryBound(to: Float.self), b[1].mData!.assumingMemoryBound(to: Float.self), Int(frames))
            return noErr
        }

        func monoNode(_ render: @escaping (UnsafeMutablePointer<Float>, Int) -> Void) -> AVAudioSourceNode {
            AVAudioSourceNode(format: mono) { _, _, frames, abl in
                let b = UnsafeMutableAudioBufferListPointer(abl)
                render(b[0].mData!.assumingMemoryBound(to: Float.self), Int(frames))
                return noErr
            }
        }
        bellNodes = bells.map { v in monoNode { v.render($0, $1) } }
        let o = orbit, h = heart, f = fire
        orbitNode = monoNode { o.render($0, $1) }
        heartNode = monoNode { h.render($0, $1) }
        fireNode = monoNode { f.render($0, $1) }
        swarmNodes = swarm.map { v in monoNode { v.render($0, $1) } }

        for n in [bedNode, padNode, paceNode] as [AVAudioNode] + [reverb, env, bus, limiter] { engine.attach(n) }
        let spatial = bellNodes + [orbitNode!, heartNode!, fireNode!] + swarmNodes
        spatial.forEach { engine.attach($0) }

        // bed first, so the shared clock is fresh for the rest of the cycle
        engine.connect(bedNode, to: bus, format: stereo)
        engine.connect(paceNode, to: bus, format: stereo)
        engine.connect(padNode, to: reverb, format: stereo)
        engine.connect(reverb, to: bus, format: stereo)
        for n in spatial { engine.connect(n, to: env, format: mono) }
        engine.connect(env, to: bus, format: stereo)
        engine.connect(bus, to: limiter, format: stereo)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereo)

        env.outputType = .headphones
        env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        env.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        env.distanceAttenuationParameters.referenceDistance = 1
        env.distanceAttenuationParameters.maximumDistance = 40
        env.distanceAttenuationParameters.rolloffFactor = 0.7
        env.reverbParameters.enable = true
        env.reverbParameters.loadFactoryReverbPreset(.largeHall)
        env.reverbParameters.level = -4
        for n in spatial {
            n.renderingAlgorithm = .HRTFHQ
            n.sourceMode = .pointSource
            n.pointSourceInHeadMode = .mono
            n.reverbBlend = 0.3
        }
        heartNode.reverbBlend = 0.05
        swarmNodes.forEach { $0.reverbBlend = 0.12 }
        fireNode.reverbBlend = 0.15
        orbitNode.reverbBlend = 0.2
        setSpace("hall")
        place(heartNode, 0, -0.35, -0.45)
        place(fireNode, 0.2, -0.8, -1.8)

        // a gentle ceiling: the limiter catches peaks; levels inside are set well below it
        engine.mainMixerNode.outputVolume = 0.9
    }

    deinit {
        k.deallocate()
        clock.deallocate()
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() { engine.stop() }

    /// The system's default output device right now.
    static func defaultOutputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    func setSpace(_ name: String) {
        let presets: [String: AVAudioUnitReverbPreset] = [
            "hall": .largeHall, "cathedral": .cathedral, "chamber": .mediumChamber,
            "plate": .plate, "room": .mediumRoom, "abyss": .largeHall2,
        ]
        if name == "none" { reverb.wetDryMix = 0; return }
        reverb.loadFactoryPreset(presets[name] ?? .largeHall)
        reverb.wetDryMix = name == "abyss" ? 55 : name == "cathedral" ? 45 : 35
        env.reverbParameters.loadFactoryReverbPreset(name == "cathedral" ? .cathedral : name == "abyss" ? .largeHall2 : .largeHall)
    }

    subscript(key: K) -> Float {
        get { k[key.rawValue] }
        set { k[key.rawValue] = newValue }
    }

    func place(_ node: AVAudioSourceNode, _ x: Float, _ y: Float, _ z: Float) {
        node.position = AVAudio3DPoint(x: x, y: y, z: z)
    }

    /// Where you are facing, in degrees (yaw left positive, pitch up positive).
    func setListener(yaw: Float, pitch: Float, roll: Float) {
        env.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: yaw, pitch: pitch, roll: roll)
    }

    /// Offline only: render `frames` and hand each chunk to `sink`; `tick` runs between chunks
    /// with the chunk's duration, so the conductor can be driven exactly as it would be live.
    func renderOffline(frames total: Int, chunk: Int = 1024, tick: (Double) -> Void, sink: (AVAudioPCMBuffer) throws -> Void) throws {
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var done = 0
        while done < total {
            let n = min(chunk, total - done)
            tick(Double(n) / sr)
            let status = try engine.renderOffline(AVAudioFrameCount(n), to: buf)
            guard status == .success else { throw NSError(domain: "Daymare", code: 1, userInfo: [NSLocalizedDescriptionKey: "render status \(status.rawValue)"]) }
            try sink(buf)
            done += n
        }
    }
}
