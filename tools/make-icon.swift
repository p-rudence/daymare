// Draws the Daymare icon (夢 on black, a faint ring around it) as a 1024px PNG.
import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let ink = NSColor(white: 0.96, alpha: 1)
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSColor.black.setFill()
tile.fill()
ink.withAlphaComponent(0.28).setStroke()
tile.lineWidth = 8
tile.stroke()
tile.addClip()

// rings, like sound spreading out from the centre
for (i, r) in [300.0, 360, 420].enumerated() {
    let ring = NSBezierPath(ovalIn: NSRect(x: 512 - r, y: 512 - r, width: 2 * r, height: 2 * r))
    ink.withAlphaComponent(0.10 - Double(i) * 0.03).setStroke()
    ring.lineWidth = 6
    ring.stroke()
}

let glow = NSShadow()
glow.shadowColor = ink.withAlphaComponent(0.35)
glow.shadowBlurRadius = 38
glow.shadowOffset = .zero
glow.set()

let font = NSFont(name: "PxPlus_IBM_VGA_8x16", size: 420) ?? .systemFont(ofSize: 400, weight: .light)
let s = NSAttributedString(string: "夢", attributes: [.font: font, .foregroundColor: ink])
let sz = s.size()
s.draw(at: NSPoint(x: (CGFloat(px) - sz.width) / 2, y: (CGFloat(px) - sz.height) / 2))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
