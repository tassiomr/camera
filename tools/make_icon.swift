// Luminous Cam icon: glowing aperture diaphragm on graphite.
// Same family as Luminous (graphite, mint→blue→violet light, star flare) but a
// camera-specific shape, so it does not read as the Luminous crescent.
// Usage: swiftc -O tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon out.png [tinted]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let tinted = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "tinted"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    if tinted { let l = 0.3 * r + 0.59 * g + 0.11 * b; return CGColor(red: l, green: l, blue: l, alpha: a) }
    return CGColor(red: r, green: g, blue: b, alpha: a)
}
let center = CGPoint(x: S / 2, y: S / 2)

// Background: graphite with a soft lift, like Luminous.
let bg = CGGradient(colorsSpace: cs, colors: [c(0.12, 0.13, 0.16), c(0.03, 0.035, 0.045)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bg, startCenter: CGPoint(x: S * 0.42, y: S * 0.62), startRadius: 0, endCenter: center, endRadius: S * 0.78, options: [.drawsAfterEndLocation])

// Aperture geometry.
let R: CGFloat = 352           // outer radius of the blade ring
let r: CGFloat = 150           // hexagonal opening
let blades = 6
let rotation: CGFloat = .pi / 9
func vertex(_ i: Int) -> CGPoint {
    let a = rotation + CGFloat(i) * 2 * .pi / CGFloat(blades)
    return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
}
/// Extends the hexagon edge (i-1 → i) beyond vertex i until it meets the outer circle.
func rayEnd(_ i: Int) -> CGPoint {
    let p = vertex(i), q = vertex(i - 1)
    var d = CGPoint(x: p.x - q.x, y: p.y - q.y)
    let len = hypot(d.x, d.y); d = CGPoint(x: d.x / len, y: d.y / len)
    let f = CGPoint(x: p.x - center.x, y: p.y - center.y)
    let b = f.x * d.x + f.y * d.y
    let t = -b + sqrt(b * b - (f.x * f.x + f.y * f.y - R * R))
    return CGPoint(x: p.x + d.x * t, y: p.y + d.y * t)
}
func angle(_ p: CGPoint) -> CGFloat { atan2(p.y - center.y, p.x - center.x) }
func bladePath(_ i: Int) -> CGPath {
    let path = CGMutablePath()
    let v0 = vertex(i), v1 = vertex(i + 1)
    let q0 = rayEnd(i), q1 = rayEnd(i + 1)
    path.move(to: v0)
    path.addLine(to: q0)
    path.addArc(center: center, radius: R, startAngle: angle(q0), endAngle: angle(q1), clockwise: false)
    path.addLine(to: v1)
    path.closeSubpath()
    return path
}
let bladeColors: [(CGFloat, CGFloat, CGFloat)] = [
    (0.24, 0.89, 0.76), (0.18, 0.80, 0.86), (0.30, 0.62, 1.00),
    (0.45, 0.52, 1.00), (0.56, 0.48, 0.99), (0.34, 0.78, 0.92)
]

func drawBlades() {
    for i in 0..<blades {
        let path = bladePath(i)
        let (cr, cg, cb) = bladeColors[i]
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        // Light falls from the upper right: each blade is brighter near its outer edge.
        let g = CGGradient(colorsSpace: cs, colors: [c(cr * 0.28, cg * 0.3, cb * 0.38), c(cr * 0.9, cg * 0.9, cb * 0.95), c(min(1, cr + 0.25), min(1, cg + 0.12), min(1, cb + 0.05))] as CFArray,
                           locations: [0, 0.55, 1])!
        let mid = angle(vertex(i)) + .pi / CGFloat(blades)
        ctx.drawLinearGradient(g, start: CGPoint(x: center.x + r * 0.8 * cos(mid), y: center.y + r * 0.8 * sin(mid)),
                               end: CGPoint(x: center.x + R * cos(mid), y: center.y + R * sin(mid)), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
}

// Glow under the blades.
for (blur, alpha) in [(110.0, 0.45), (45.0, 0.55)] {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: c(0.30, 0.70, 0.95, alpha))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawBlades()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}
drawBlades()

// Blade seams: thin dark lines along each ray, with a light edge beside them.
ctx.setLineCap(.round)
for i in 0..<blades {
    ctx.setStrokeColor(c(0.02, 0.025, 0.035, 0.85)); ctx.setLineWidth(9)
    ctx.move(to: vertex(i)); ctx.addLine(to: rayEnd(i)); ctx.strokePath()
    ctx.setStrokeColor(c(1, 1, 1, 0.18)); ctx.setLineWidth(3)
    let v = vertex(i), q = rayEnd(i)
    let n = CGPoint(x: -(q.y - v.y), y: q.x - v.x); let l = hypot(n.x, n.y)
    ctx.move(to: CGPoint(x: v.x + n.x / l * 7, y: v.y + n.y / l * 7))
    ctx.addLine(to: CGPoint(x: q.x + n.x / l * 7, y: q.y + n.y / l * 7)); ctx.strokePath()
}

// Outer barrel ring.
ctx.setStrokeColor(c(0.03, 0.035, 0.045)); ctx.setLineWidth(26)
ctx.strokeEllipse(in: CGRect(x: center.x - R - 8, y: center.y - R - 8, width: 2 * (R + 8), height: 2 * (R + 8)))
let ringR = R + 30
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - ringR - 14, y: center.y - ringR - 14, width: 2 * (ringR + 14), height: 2 * (ringR + 14)))
ctx.addEllipse(in: CGRect(x: center.x - ringR + 14, y: center.y - ringR + 14, width: 2 * (ringR - 14), height: 2 * (ringR - 14)))
ctx.clip(using: .evenOdd)
let barrel = CGGradient(colorsSpace: cs, colors: [c(0.30, 0.32, 0.36), c(0.08, 0.085, 0.10), c(0.22, 0.24, 0.28)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(barrel, start: CGPoint(x: S * 0.2, y: S * 0.85), end: CGPoint(x: S * 0.8, y: S * 0.15), options: [])
ctx.restoreGState()

// Opening: deep glass with a reflection.
ctx.saveGState()
let hex = CGMutablePath()
hex.move(to: vertex(0)); for i in 1..<blades { hex.addLine(to: vertex(i)) }; hex.closeSubpath()
ctx.addPath(hex); ctx.clip()
let glass = CGGradient(colorsSpace: cs, colors: [c(0.07, 0.11, 0.14), c(0.005, 0.008, 0.015)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glass, startCenter: CGPoint(x: center.x - 40, y: center.y + 50), startRadius: 0, endCenter: center, endRadius: r, options: [.drawsAfterEndLocation])
ctx.setStrokeColor(c(0.7, 0.95, 1, 0.22)); ctx.setLineWidth(12)
ctx.addArc(center: center, radius: r * 0.68, startAngle: .pi * 0.58, endAngle: .pi * 0.9, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// The light: star flare caught in the lens (upper right of the opening).
let star = CGPoint(x: center.x + r * 0.42, y: center.y + r * 0.38)
let flare = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 1), c(0.8, 1, 0.96, 0.6), c(0.4, 0.9, 0.9, 0)] as CFArray, locations: [0, 0.14, 1])!
ctx.drawRadialGradient(flare, startCenter: star, startRadius: 0, endCenter: star, endRadius: 95, options: [])
ctx.setStrokeColor(c(1, 1, 1, 0.55)); ctx.setLineWidth(3)
for k in 0..<2 {
    let a = CGFloat(k) * .pi / 2 + .pi / 4
    ctx.move(to: CGPoint(x: star.x - 70 * cos(a), y: star.y - 70 * sin(a)))
    ctx.addLine(to: CGPoint(x: star.x + 70 * cos(a), y: star.y + 70 * sin(a)))
}
ctx.strokePath()
ctx.setFillColor(c(1, 1, 1)); ctx.fillEllipse(in: CGRect(x: star.x - 10, y: star.y - 10, width: 20, height: 20))

let img = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
