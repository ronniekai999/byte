import SwiftUI
import CoreGraphics
import Foundation

/// Small pixel-art props that animate around Byte during care actions — a mouse he
/// chomps when fed, a little lake he drinks from, a ball he plays with. Authored as
/// character grids in the same pixel style and palette family as Byte, rendered once
/// into CGImages and shown with nearest-neighbour scaling.
enum Prop {
    case mouse, water, ball

    static let mouseImage: CGImage = make(grid: mouseGrid)
    static let waterImage: CGImage = make(grid: waterGrid)
    static let ballImage:  CGImage = make(grid: ballGrid)

    var image: CGImage {
        switch self {
        case .mouse: return Self.mouseImage
        case .water: return Self.waterImage
        case .ball:  return Self.ballImage
        }
    }

    private static func color(_ ch: Character) -> (Double, Double, Double)? {
        switch ch {
        case "D": return (54, 58, 66)       // shared dark outline
        case "G": return (158, 158, 170)    // mouse grey
        case "L": return (206, 206, 216)    // mouse belly
        case "P", "N": return (236, 158, 172) // pink ear / nose / tail
        case "K": return (28, 30, 36)       // eye
        case "b": return (54, 104, 168)     // water edge
        case "B": return (92, 158, 216)     // water fill
        case "h": return (198, 228, 250)    // water highlight
        case "r": return (224, 92, 92)      // ball
        case "s": return (252, 252, 252)    // ball shine
        case "o": return (150, 44, 44)      // ball outline
        default:  return nil                // '.' = transparent
        }
    }

    private static func u8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

    private static func make(grid: String) -> CGImage {
        // Trim per-line whitespace so source indentation doesn't matter ('.' = clear).
        let rows = grid.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Array($0) }
        let h = max(1, rows.count)
        let w = max(1, rows.map { $0.count }.max() ?? 1)
        var px = [UInt8](repeating: 0, count: w*h*4)
        for y in 0..<rows.count {
            let row = rows[y]
            for x in 0..<row.count {
                guard let c = color(row[x]) else { continue }
                let i = (y*w + x) * 4
                px[i] = u8(c.0); px[i+1] = u8(c.1); px[i+2] = u8(c.2); px[i+3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w*4, space: cs, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    // Grids (facing right where applicable). Indentation is stripped at parse time.
    private static let mouseGrid = """
    ............DDD..
    ...........DPPPD.
    .....DDDDD.DPGPD.
    ...DDGGGGGDDGGGD.
    ..DGLLGGGGGGGGKD.
    PDGLLLGGGGGGGGGND
    .PDDGGGGGGGGGGDD.
    ..DDGGGGGGGGGGD..
    ...D.DDD.DDD..D..
    """

    private static let waterGrid = """
    ......bbbbbbbbbb......
    ...bbBBBBBBBBBBBBbb...
    ..bBBBBhhBBBBBBhBBBb..
    .bBBBBBBBBBBBBBBBBBBb.
    .bBBBBBBBBBBBBBBBBBBb.
    ..bBBBBBBBBBBBBBBBBb..
    ...bbBBBBBBBBBBBBbb...
    ......bbbbbbbbbb......
    """

    private static let ballGrid = """
    ...oooo...
    ..orrrro..
    .orrsrrro.
    orrsrrrrro
    orrrrrrrro
    orrrrrrsro
    orrrrrrsro
    .orrrrrro.
    ..orrrro..
    ...oooo...
    """
}

/// Displays a prop at a given pixel size, optionally horizontally flipped.
struct PropSprite: View {
    let prop: Prop
    var pixel: CGFloat = 2
    var flip: Bool = false

    var body: some View {
        Image(decorative: prop.image, scale: 1)
            .resizable()
            .interpolation(.none)
            .antialiased(false)
            .frame(width: CGFloat(prop.image.width) * pixel,
                   height: CGFloat(prop.image.height) * pixel)
            .scaleEffect(x: flip ? -1 : 1, y: 1)
    }
}
