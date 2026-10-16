// Your head, through the AirPods: where it faces (to hold the sound-world still while you turn),
// how still it is (to pace the descent), and two deliberate gestures (a nod and a shake).
//
// Apple's own nod/shake recognition is not open to apps, so the gestures are read here from raw
// attitude at about 25 Hz. Absolute yaw is never trusted for long: it jumps when another app
// starts spatial audio, so big jumps re-centre and the centre slowly follows wherever you settle.

import Foundation
import CoreMotion

enum Gesture { case nod, shake }

/// Pure: fed (time, pitch, yaw) in radians, reports a deliberate nod (down-up-down, or more) or shake.
/// A single slump or turn is not a gesture: it takes three quick alternating swings on one axis
/// while the other axis stays quiet.
struct GestureDetector {
    var swingRate: Double = 0.9          // rad/s that counts as a swing
    var window: Double = 1.6             // seconds for the whole gesture
    var refractory: Double = 2.0

    private var last: (t: Double, p: Double, y: Double)?
    private var pitchSwings: [(t: Double, sign: Int)] = []
    private var yawSwings: [(t: Double, sign: Int)] = []
    private var quietUntil: Double = 0

    mutating func feed(t: Double, pitch: Double, yaw: Double) -> Gesture? {
        defer { last = (t, pitch, yaw) }
        guard let l = last, t > l.t else { return nil }
        let dt = t - l.t
        if dt > 0.25 { pitchSwings.removeAll(); yawSwings.removeAll(); return nil }
        let pr = (pitch - l.p) / dt
        var dy = yaw - l.y
        if dy > .pi { dy -= 2 * .pi }
        if dy < -.pi { dy += 2 * .pi }
        let yr = dy / dt
        if t < quietUntil { return nil }

        func note(_ swings: inout [(t: Double, sign: Int)], _ rate: Double) {
            guard abs(rate) > swingRate else { return }
            let s = rate > 0 ? 1 : -1
            if let lastSwing = swings.last, lastSwing.sign == s { return }
            swings.append((t, s))
        }
        // the dominant axis takes the swing; the other must be clearly smaller
        if abs(pr) > abs(yr) * 1.6 { note(&pitchSwings, pr) }
        if abs(yr) > abs(pr) * 1.6 { note(&yawSwings, yr) }
        pitchSwings.removeAll { t - $0.t > window }
        yawSwings.removeAll { t - $0.t > window }

        if pitchSwings.count >= 3 {
            pitchSwings.removeAll(); yawSwings.removeAll(); quietUntil = t + refractory
            return .nod
        }
        if yawSwings.count >= 3 {
            pitchSwings.removeAll(); yawSwings.removeAll(); quietUntil = t + refractory
            return .shake
        }
        return nil
    }
}

/// Pure: motion energy in, a slow 0…1 stillness out, plus how long you've been still.
struct StillnessMeter {
    var energy: Double = 0.3                 // smoothed rad/s-ish
    var stillFor: Double = 0
    var stillBelow: Double = 0.06
    var restlessAbove: Double = 0.22

    var stillness: Double { min(1, max(0, 1 - (energy - stillBelow) / (restlessAbove - stillBelow))) }
    var restless: Bool { energy > restlessAbove }

    mutating func feed(rotation: Double, accel: Double, dt: Double) {
        let e = rotation + accel * 4
        let tau = e > energy ? 0.8 : 4.0     // rise quickly, settle slowly
        energy += (e - energy) * min(1, dt / tau)
        if energy < stillBelow * 1.5 { stillFor += dt } else { stillFor = 0 }
    }
}

final class Motion: NSObject, CMHeadphoneMotionManagerDelegate {
    static let shared = Motion()
    private let mgr = CMHeadphoneMotionManager()

    private(set) var connected = false
    private(set) var lastSample = Date.distantPast
    private(set) var denied = false
    var available: Bool { mgr.isDeviceMotionAvailable }
    var receiving: Bool { Date().timeIntervalSince(lastSample) < 2 }

    /// Relative to the centre, in degrees: yaw left positive, pitch up positive.
    private(set) var yaw: Double = 0, pitch: Double = 0, roll: Double = 0
    private var cYaw: Double = 0, cPitch: Double = 0, cRoll: Double = 0
    private var rawLast: (y: Double, p: Double, r: Double)?
    private var lastT: Double = 0
    var meter = StillnessMeter()
    private var detector = GestureDetector()
    var gesturesOn = false
    var onGesture: ((Gesture) -> Void)?
    var samples = 0

    func start() {
        mgr.delegate = self
        let auth = CMHeadphoneMotionManager.authorizationStatus()
        denied = auth == .denied || auth == .restricted
        guard mgr.isDeviceMotionAvailable, !denied else { return }
        mgr.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            if let m { self?.take(m) }
        }
    }

    /// Read the permission again (the first launch's answer arrives after `start`).
    func refreshPermission() {
        let auth = CMHeadphoneMotionManager.authorizationStatus()
        denied = auth == .denied || auth == .restricted
    }

    /// Wherever you're facing now becomes straight ahead.
    func recenter() {
        guard let r = rawLast else { return }
        cYaw = r.y; cPitch = r.p; cRoll = r.r
    }

    private func take(_ m: CMDeviceMotion) {
        samples += 1
        lastSample = Date()
        connected = true
        let t = m.timestamp
        let dt = lastT > 0 ? min(0.25, max(0.001, t - lastT)) : 0.04
        lastT = t
        let y = m.attitude.yaw, p = m.attitude.pitch, r = m.attitude.roll

        if let prev = rawLast {
            var jump = y - prev.y
            if jump > .pi { jump -= 2 * .pi }
            if jump < -.pi { jump += 2 * .pi }
            // a teleport, not a head turn: carry the centre along
            if abs(jump) > 0.35 { cYaw += jump }
        } else {
            cYaw = y; cPitch = p; cRoll = r
        }
        rawLast = (y, p, r)

        // the centre drifts toward where you settle (about a minute), so lying on your side is fine
        let follow = min(1, dt / 60)
        cYaw += wrap(y - cYaw) * follow
        cPitch += (p - cPitch) * follow
        cRoll += (r - cRoll) * follow

        yaw = wrap(y - cYaw) * 180 / .pi
        pitch = (p - cPitch) * 180 / .pi
        roll = (r - cRoll) * 180 / .pi

        let rr = m.rotationRate
        let ua = m.userAcceleration
        meter.feed(rotation: sqrt(rr.x * rr.x + rr.y * rr.y + rr.z * rr.z),
                   accel: sqrt(ua.x * ua.x + ua.y * ua.y + ua.z * ua.z), dt: dt)

        if let g = detector.feed(t: t, pitch: p, yaw: y), gesturesOn { onGesture?(g) }
    }

    private func wrap(_ a: Double) -> Double {
        var a = a
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) { connected = true }
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) { connected = false; rawLast = nil }
}
