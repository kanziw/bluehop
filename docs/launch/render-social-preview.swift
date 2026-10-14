// Renders the 1280x640 GitHub social preview using only system fonts and drawn shapes (no external assets).
// Usage: swift docs/launch/render-social-preview.swift docs/launch/social-preview.png
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "social-preview.png"
let W: CGFloat = 1280, H: CGFloat = 640

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func font(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
}

func text(_ s: String, _ f: NSFont, _ c: NSColor, at p: CGPoint, center: Bool = false) {
    let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c]
    let size = (s as NSString).size(withAttributes: attrs)
    let origin = center ? CGPoint(x: p.x - size.width / 2, y: p.y) : p
    (s as NSString).draw(at: origin, withAttributes: attrs)
}

func bubble(_ r: CGRect, fill: NSColor, label: String, tailRight: Bool) {
    fill.setFill()
    NSBezierPath(roundedRect: r, xRadius: 34, yRadius: 34).fill()
    let tail = NSBezierPath()
    let x = tailRight ? r.maxX - 40 : r.minX + 40
    let dx: CGFloat = tailRight ? 30 : -30
    tail.move(to: CGPoint(x: x - 18, y: r.minY + 6))
    tail.line(to: CGPoint(x: x + dx, y: r.minY - 22))
    tail.line(to: CGPoint(x: x + 18, y: r.minY + 6))
    tail.close()
    tail.fill()
    text(label, font("Helvetica Neue Bold", 34, .bold), .white, at: CGPoint(x: r.midX, y: r.midY - 20), center: true)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

color(0x0F172A).setFill()
CGRect(x: 0, y: 0, width: W, height: H).fill()

text("bluehop", font("Menlo Bold", 84, .bold), .white, at: CGPoint(x: 80, y: 470))
text("iMessage to Telegram relay for one chat", font("Helvetica Neue", 40, .regular), color(0xCBD5E1), at: CGPoint(x: 82, y: 405))

bubble(CGRect(x: 80, y: 190, width: 360, height: 120), fill: color(0x2563EB), label: "one iMessage chat", tailRight: false)
bubble(CGRect(x: 840, y: 190, width: 360, height: 120), fill: color(0x0EA5E9), label: "one Telegram chat", tailRight: true)

let arrow = NSBezierPath()
arrow.lineWidth = 8
arrow.lineCapStyle = .round
arrow.move(to: CGPoint(x: 480, y: 270)); arrow.line(to: CGPoint(x: 800, y: 270))
arrow.move(to: CGPoint(x: 775, y: 292)); arrow.line(to: CGPoint(x: 800, y: 270)); arrow.line(to: CGPoint(x: 775, y: 248))
arrow.move(to: CGPoint(x: 800, y: 230)); arrow.line(to: CGPoint(x: 480, y: 230))
arrow.move(to: CGPoint(x: 505, y: 252)); arrow.line(to: CGPoint(x: 480, y: 230)); arrow.line(to: CGPoint(x: 505, y: 208))
color(0x94A3B8).setStroke()
arrow.stroke()
text("your Mac", font("Menlo", 26, .regular), color(0x94A3B8), at: CGPoint(x: 640, y: 290), center: true)

text("Swift · zero dependencies · no web UI · no open ports · no cloud", font("Helvetica Neue", 30, .regular),
     color(0xE2E8F0), at: CGPoint(x: 640, y: 80), center: true)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
