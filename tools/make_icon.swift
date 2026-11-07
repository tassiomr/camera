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
    if tinted { let l = 0.3*r + 0.59*g + 0.11*b; return CGColor(red: l, green: l, blue: l, alpha: a) }
    return CGColor(red: r, green: g, blue: b, alpha: a)
}
let center = CGPoint(x: S/2, y: S/2)

// Background: deep charcoal with soft center lift (Luminous-like).
let bg = CGGradient(colorsSpace: cs, colors: [c(0.11,0.12,0.15), c(0.035,0.04,0.05)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bg, startCenter: CGPoint(x: S*0.45, y: S*0.55), startRadius: 0, endCenter: center, endRadius: S*0.75, options: [.drawsAfterEndLocation])

// Lens barrel ring.
let R: CGFloat = 330
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x-R-34, y: center.y-R-34, width: 2*(R+34), height: 2*(R+34)))
ctx.addEllipse(in: CGRect(x: center.x-R+6, y: center.y-R+6, width: 2*(R-6), height: 2*(R-6)))
ctx.clip(using: .evenOdd)
let barrel = CGGradient(colorsSpace: cs, colors: [c(0.20,0.21,0.24), c(0.06,0.065,0.08)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(barrel, start: CGPoint(x: S*0.3, y: S*0.85), end: CGPoint(x: S*0.7, y: S*0.15), options: [])
ctx.restoreGState()

// Glowing crescent: outer circle minus offset inner circle → thick lower-left.
func crescentPath() -> CGPath {
    let p = CGMutablePath()
    p.addEllipse(in: CGRect(x: center.x-R, y: center.y-R, width: 2*R, height: 2*R))
    let r2 = R*0.93, off = CGPoint(x: 22, y: 26) // y up in CG
    p.addEllipse(in: CGRect(x: center.x-r2+off.x, y: center.y-r2+off.y, width: 2*r2, height: 2*r2))
    return p
}
func fillCrescent() {
    ctx.saveGState()
    ctx.addPath(crescentPath()); ctx.clip(using: .evenOdd)
    let lin = CGGradient(colorsSpace: cs, colors: [c(0.30,0.95,0.80), c(0.16,0.78,0.86), c(0.36,0.56,1.0), c(0.52,0.46,0.98)] as CFArray, locations: [0, 0.35, 0.7, 1])!
    ctx.drawLinearGradient(lin, start: CGPoint(x: S*0.25, y: S*0.78), end: CGPoint(x: S*0.78, y: S*0.2), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
// Glow: draw blurred copies via shadow.
for (blur, alpha) in [(90.0, 0.55), (40.0, 0.7)] {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: c(0.24,0.89,0.76, alpha))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    fillCrescent()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}
fillCrescent()

// Inner glass.
let gR: CGFloat = 255
let glassCenter = CGPoint(x: center.x+12, y: center.y+14)
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: glassCenter.x-gR, y: glassCenter.y-gR, width: 2*gR, height: 2*gR)); ctx.clip()
let glass = CGGradient(colorsSpace: cs, colors: [c(0.06,0.10,0.12), c(0.01,0.012,0.02)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glass, startCenter: CGPoint(x: glassCenter.x-60, y: glassCenter.y-70), startRadius: 0, endCenter: glassCenter, endRadius: gR, options: [])
ctx.setLineWidth(3)
for k in 1...4 {
    let r = gR * CGFloat(k) / 4.6
    ctx.setStrokeColor(c(0.24,0.89,0.76, 0.06 + 0.03*CGFloat(k)))
    ctx.strokeEllipse(in: CGRect(x: glassCenter.x-r, y: glassCenter.y-r, width: 2*r, height: 2*r))
}
// Reflection arc on glass (upper-left).
ctx.setLineWidth(18); ctx.setLineCap(.round)
ctx.setStrokeColor(c(0.6,0.95,0.9, 0.22))
ctx.addArc(center: glassCenter, radius: gR*0.72, startAngle: .pi*0.62, endAngle: .pi*0.86, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// Star flare (top-right), like Luminous.
let star = CGPoint(x: S*0.72, y: S*0.73)
let flare = CGGradient(colorsSpace: cs, colors: [c(1,1,1,1), c(0.75,1,0.95,0.55), c(0.4,0.9,0.85,0)] as CFArray, locations: [0, 0.12, 1])!
ctx.drawRadialGradient(flare, startCenter: star, startRadius: 0, endCenter: star, endRadius: 120, options: [])
ctx.setFillColor(c(1,1,1)); ctx.fillEllipse(in: CGRect(x: star.x-11, y: star.y-11, width: 22, height: 22))

let img = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
