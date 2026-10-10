import Foundation
import AVFoundation

/// Plays a short, synthesized dino "stomp" — a heavy footfall modeled as a
/// pitch-dropping low body thud (≈130→45 Hz), a fast broadband contact transient,
/// a low ground rumble, and a tiny high "crack" for presence on small laptop
/// speakers (where the sub-bass barely reproduces). Generated in code so there's
/// no audio file to bundle.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    private lazy var stompWAV: Data = SoundPlayer.makeStompWAV()
    private var players: [AVAudioPlayer] = []

    func playStomp() {
        guard let p = try? AVAudioPlayer(data: stompWAV) else { return }
        p.volume = 0.34
        p.prepareToPlay()
        p.play()
        players.append(p)
        if players.count > 4 { players.removeFirst(players.count - 4) }  // allow brief overlap
    }

    // MARK: - Synthesis

    /// Simple one-pole low-pass over a buffer (used to band-limit noise).
    /// Subtracting it from the source gives a high-pass.
    private static func onepole(_ x: [Double], _ a: Double) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var acc = 0.0
        for i in 0..<x.count { acc += a * (x[i] - acc); y[i] = acc }
        return y
    }

    private static func makeStompWAV() -> Data {
        let sr = 44_100.0
        let dur = 0.34
        let n = Int(sr * dur)
        func noise() -> [Double] { (0..<n).map { _ in Double.random(in: -1...1) } }
        var s = [Double](repeating: 0, count: n)

        // 1) Low body thud: pitch drops 130 → 45 Hz fast; a little 2nd harmonic so the
        //    "boom" is still audible on speakers that can't reproduce deep sub-bass.
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sr
            let f = 45 + (130 - 45) * exp(-t / 0.018)
            phase += 2 * Double.pi * f / sr
            let env = (1 - exp(-t / 0.002)) * exp(-t * 16)
            s[i] += (sin(phase) + 0.3 * sin(2 * phase)) * env * 0.70
        }

        // 2) Contact transient: low-mid noise burst, very fast decay (the "thwump").
        let imp = onepole(noise(), 0.30)
        for i in 0..<n { s[i] += imp[i] * exp(-Double(i) / sr * 60) * 0.60 }

        // 3) Ground rumble: very-low-passed noise, medium decay (the room shaking).
        let rumble = onepole(noise(), 0.012)
        for i in 0..<n { s[i] += rumble[i] * exp(-Double(i) / sr * 9) * 0.55 }

        // 4) Contact crack: one short high-passed noise grain for presence/snap.
        let crack = noise()
        let crackLp = onepole(crack, 0.5)
        for i in 0..<n { s[i] += (crack[i] - crackLp[i]) * exp(-Double(i) / sr * 120) * 0.18 }

        // normalize to 0.9 peak
        var peak = 0.0
        for v in s { peak = max(peak, abs(v)) }
        if peak > 0 { let g = 0.9 / peak; for i in 0..<n { s[i] *= g } }

        // de-click the very start and end
        let ar = Int(0.003 * sr), rel = Int(0.03 * sr)
        for i in 0..<min(ar, n) { s[i] *= Double(i) / Double(ar) }
        for j in 0..<min(rel, n) { s[n - 1 - j] *= Double(j) / Double(rel) }

        return wav(s, sampleRate: Int(sr))
    }

    private static func wav(_ samples: [Double], sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let dataSize = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32_767)
            u16(UInt16(bitPattern: v))
        }
        return d
    }
}
