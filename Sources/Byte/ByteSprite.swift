import SwiftUI
import CoreGraphics
import Foundation

/// Byte — a chunky, friendly cartoon T-rex rendered as low-resolution pixel art
/// (Tamagotchi style). The silhouette comes from the same vector geometry as
/// before — body, tail, neck, head, snout, legs, tiny arms, a row of back spikes —
/// but it's rasterized onto a 48×36 grid with a hard 1-pixel outline, and the face
/// (eye, nostril, mouth/teeth, brow, blush) is authored directly in pixel
/// coordinates so each expression reads at this size. Displayed with nearest-neighbor
/// scaling (no smoothing) so the pixels stay crisp.
struct ByteSprite: View {
    enum Mood { case neutral, happy, thinking }

    /// Points per design unit. Design space is 140 × 104, so scale 0.72 ≈ 101 × 75 pt.
    var scale: CGFloat = 0.72
    var mood: Mood = .neutral

    static let imageNeutral: CGImage = makeImage(mood: .neutral)
    static let imageHappy: CGImage = makeImage(mood: .happy)
    static let imageThinking: CGImage = makeImage(mood: .thinking)

    private var image: CGImage {
        switch mood {
        case .neutral: return Self.imageNeutral
        case .happy: return Self.imageHappy
        case .thinking: return Self.imageThinking
        }
    }

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.none)            // keep the pixels crisp
            .antialiased(false)
            .frame(width: Self.dW * scale, height: Self.dH * scale)
    }

    // MARK: - Grid

    private static let dW = 140.0
    private static let dH = 104.0
    private static let AW = 48                // art-pixel grid width
    private static let AH = 36                // art-pixel grid height
    private static let SS = 4                 // supersample for clean silhouette edges

    // Palette (same color scheme as the smooth version)
    private static let BODY:  (Double, Double, Double) = (112, 182, 96)
    private static let BELLY: (Double, Double, Double) = (226, 233, 202)
    private static let OUT:   (Double, Double, Double) = (40, 72, 46)
    private static let RIDGE: (Double, Double, Double) = (82, 150, 82)
    private static let BLUSH: (Double, Double, Double) = (216, 120, 120)
    private static let WHITE: (Double, Double, Double) = (248, 250, 244)
    private static let PUPIL: (Double, Double, Double) = (28, 40, 30)
    private static let MOUTH: (Double, Double, Double) = (60, 30, 36)
    private static let TEETH: (Double, Double, Double) = (250, 250, 245)

    private static func u8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

    // MARK: - Geometry rasterization (into a high-res mask, design coords)

    private static func fillEllipse(_ mask: inout [Bool], _ W: Int, _ H: Int, _ s: Double,
                                    _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) {
        let x0 = max(0, Int((cx - rx) * s)), x1 = min(W - 1, Int((cx + rx) * s))
        let y0 = max(0, Int((cy - ry) * s)), y1 = min(H - 1, Int((cy + ry) * s))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            let dyv = ((Double(y) + 0.5) / s - cy) / ry
            for x in x0...x1 {
                let dxv = ((Double(x) + 0.5) / s - cx) / rx
                if dxv*dxv + dyv*dyv <= 1.0 { mask[y*W + x] = true }
            }
        }
    }

    private static func fillScan(_ pts: [(Double, Double)], _ s: Double,
                                 _ W: Int, _ H: Int, _ mask: inout [Bool]) {
        let n = pts.count
        for y in 0..<H {
            let yd = (Double(y) + 0.5) / s
            var xs: [Double] = []
            var j = n - 1
            for i in 0..<n {
                let (xi, yi) = pts[i], (xj, yj) = pts[j]
                if (yi > yd) != (yj > yd) { xs.append(xi + (yd - yi) / (yj - yi) * (xj - xi)) }
                j = i
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                let pa = max(0, Int(xs[k] * s)), pb = min(W - 1, Int(xs[k+1] * s))
                if pa <= pb { for x in pa...pb { mask[y*W + x] = true } }
                k += 2
            }
        }
    }

    /// Block-average a high-res mask down to the art grid → per-cell coverage 0…1.
    private static func downsample(_ m: [Bool], _ W: Int) -> [Double] {
        var out = [Double](repeating: 0, count: AW * AH)
        let inv = 1.0 / Double(SS * SS)
        for ay in 0..<AH {
            for ax in 0..<AW {
                var c = 0
                for sy in 0..<SS {
                    let row = (ay*SS + sy) * W
                    for sx in 0..<SS where m[row + ax*SS + sx] { c += 1 }
                }
                out[ay*AW + ax] = Double(c) * inv
            }
        }
        return out
    }

    /// One-step 4-neighbour erosion on the art grid (for the 1-pixel outline).
    private static func erode1(_ m: [Bool]) -> [Bool] {
        var e = m
        for y in 0..<AH {
            for x in 0..<AW {
                let i = y*AW + x
                if !m[i] { continue }
                let up = y > 0      ? m[i - AW] : false
                let dn = y < AH - 1 ? m[i + AW] : false
                let lf = x > 0      ? m[i - 1]  : false
                let rt = x < AW - 1 ? m[i + 1]  : false
                e[i] = up && dn && lf && rt
            }
        }
        return e
    }

    // MARK: - Image construction

    private static func makeImage(mood: Mood) -> CGImage {
        let W2 = AW * SS, H2 = AH * SS
        let s = Double(AW * SS) / dW                 // design → high-res scale

        // 1. High-res silhouette parts.
        var body = [Bool](repeating: false, count: W2*H2)
        fillEllipse(&body, W2, H2, s, 66, 62, 26, 22)                                  // body
        fillScan([(84,52),(104,47),(123,50),(134,55),(133,63),(116,62),(100,65),(85,72)], s, W2, H2, &body)  // tail
        fillScan([(30,32),(48,40),(55,60),(34,54)], s, W2, H2, &body)                   // neck
        fillEllipse(&body, W2, H2, s, 37, 27, 18, 15)                                  // head
        fillScan([(23,15),(8,25),(7,34),(25,39),(35,32),(31,19)], s, W2, H2, &body)     // snout
        fillEllipse(&body, W2, H2, s, 58, 82, 11, 15)                                  // front thigh
        fillEllipse(&body, W2, H2, s, 79, 83, 11, 14)                                  // back thigh
        fillScan([(50,88),(60,88),(61,97),(66,99),(45,99),(47,97)], s, W2, H2, &body)   // front foot
        fillScan([(73,89),(83,89),(84,98),(88,99),(71,99),(72,97)], s, W2, H2, &body)   // back foot
        fillEllipse(&body, W2, H2, s, 47, 59, 4.5, 6.5)                                // tiny arm
        fillScan([(44,61),(38,66),(40,68),(49,64)], s, W2, H2, &body)                   // forearm

        var belly = [Bool](repeating: false, count: W2*H2)
        fillEllipse(&belly, W2, H2, s, 60, 72, 18, 13)

        var spikes = [Bool](repeating: false, count: W2*H2)
        for xd in [44.0, 52, 60, 68, 76, 84] {
            let col = min(W2 - 1, max(0, Int(xd * s)))
            var topY = H2
            for y in 0..<H2 { if body[y*W2 + col] { topY = y; break } }
            let by = Double(topY) / s
            let h = xd < 70 ? 6.0 : 5.0
            fillScan([(xd-4, by+1), (xd, by-h), (xd+4, by+1)], s, W2, H2, &spikes)
        }

        // 2. Downsample to the art grid.
        let cb = downsample(body, W2), cbel = downsample(belly, W2), csp = downsample(spikes, W2)
        var artBody = [Bool](repeating: false, count: AW*AH)
        var artBelly = [Bool](repeating: false, count: AW*AH)
        var artSpike = [Bool](repeating: false, count: AW*AH)
        var full = [Bool](repeating: false, count: AW*AH)
        for i in 0..<AW*AH {
            artBody[i]  = cb[i] > 0.5
            artBelly[i] = cbel[i] > 0.5 && artBody[i]
            artSpike[i] = csp[i] > 0.35
            full[i] = artBody[i] || artSpike[i]
        }
        let inner = erode1(full)

        // 3. Paint base colours + 1-pixel outline.
        var px = [UInt8](repeating: 0, count: AW*AH*4)
        func put(_ x: Int, _ y: Int, _ c: (Double, Double, Double)) {
            guard x >= 0, x < AW, y >= 0, y < AH else { return }
            let i = (y*AW + x) * 4
            px[i] = u8(c.0); px[i+1] = u8(c.1); px[i+2] = u8(c.2); px[i+3] = 255
        }
        for y in 0..<AH {
            for x in 0..<AW {
                let i = y*AW + x
                if artSpike[i] { put(x, y, RIDGE) }
                else if artBody[i] { put(x, y, artBelly[i] ? BELLY : BODY) }
                if full[i] && !inner[i] { put(x, y, OUT) }
            }
        }

        // 4. Face, authored in pixel coordinates per expression.
        func ax(_ dx: Double) -> Int { Int((dx / dW * Double(AW)).rounded()) }
        func ay(_ dy: Double) -> Int { Int((dy / dH * Double(AH)).rounded()) }
        func hline(_ x0: Int, _ x1: Int, _ y: Int, _ c: (Double, Double, Double)) {
            if x0 <= x1 { for x in x0...x1 { put(x, y, c) } }
        }
        func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: (Double, Double, Double)) {
            guard x0 <= x1, y0 <= y1 else { return }
            for y in y0...y1 { for x in x0...x1 { put(x, y, c) } }
        }

        let eyeX: Int, eyeY: Int, pupDX: Int, pupDY: Int, browY: Int
        let openMouth: Bool, biggerMouth: Bool
        switch mood {
        case .happy:
            eyeX = ax(29); eyeY = ay(23); pupDX = 0; pupDY = 0; browY = ay(17)
            openMouth = true; biggerMouth = true
        case .thinking:
            eyeX = ax(29); eyeY = ay(23); pupDX = 1; pupDY = -1; browY = ay(19)
            openMouth = false; biggerMouth = false
        case .neutral:
            eyeX = ax(29); eyeY = ay(24); pupDX = 0; pupDY = 1; browY = ay(19)
            openMouth = true; biggerMouth = false
        }

        // blush + nostril
        put(ax(23), ay(31), BLUSH); put(ax(24), ay(31), BLUSH)
        put(ax(12), ay(27), OUT)

        // mouth
        if openMouth {
            let y0 = ay(33), y1 = ay(37) + (biggerMouth ? 1 : 0)
            let x0 = ax(10), x1 = ax(30)
            rect(x0, y0, x1, y1, MOUTH)
            var tx = x0 + 1
            while tx < x1 { put(tx, y0, TEETH); tx += 2 }          // top teeth
            tx = x0 + 2
            while tx < x1 { put(tx, y1, TEETH); tx += 3 }          // bottom teeth
        } else {
            hline(ax(11), ax(28), ay(35), OUT)                     // closed line
        }

        // eye (white block + pupil)
        rect(eyeX - 1, eyeY - 1, eyeX + 1, eyeY + 1, WHITE)
        put(eyeX + pupDX, eyeY + pupDY, PUPIL)
        if mood != .thinking { put(eyeX + pupDX, eyeY + pupDY - 1, PUPIL) }

        // brow
        hline(eyeX - 2, eyeX + 1, browY, OUT)
        if mood == .thinking { put(eyeX + 2, browY + 1, OUT) }     // inner furrow

        // 5. Wrap as a CGImage at the art resolution.
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: AW, height: AH, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: AW*4, space: cs, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }
}
