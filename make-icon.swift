// make-icon.swift — renders the Refresh Network app icon master (1024×1024 PNG).
// Run: swift make-icon.swift   →   icon-master.png
// build.sh turns this into AppIcon.icns via sips + iconutil.
//
// Design: blue squircle background, a white Wi-Fi glyph, and a small white
// badge in the lower-right holding a blue circular-refresh arrow.

import AppKit
import Foundation

let canvas: CGFloat = 1024

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    color.set()
    let rect = NSRect(origin: .zero, size: image.size)
    image.draw(in: rect)
    rect.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func symbol(_ name: String, point: CGFloat, weight: NSFont.Weight) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: point, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let configured = base.withSymbolConfiguration(cfg) else {
        fatalError("missing SF Symbol: \(name)")
    }
    return configured
}

let img = NSImage(size: NSSize(width: canvas, height: canvas))
img.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }
ctx.setShouldAntialias(true)

// --- Rounded-square background with a vertical blue gradient (Apple-ish squircle) ---
let inset: CGFloat = 92
let bgRect = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let corner: CGFloat = bgRect.width * 0.2237
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: corner, yRadius: corner)

ctx.saveGState()
bgPath.addClip()
let top = NSColor(srgbRed: 0.286, green: 0.560, blue: 0.984, alpha: 1)   // #498FFB
let bottom = NSColor(srgbRed: 0.094, green: 0.392, blue: 0.918, alpha: 1) // #1864EA
let gradient = NSGradient(starting: top, ending: bottom)!
gradient.draw(in: bgRect, angle: -90)
ctx.restoreGState()

// --- White Wi-Fi glyph, centered and nudged up to leave room for the badge ---
let wifi = tinted(symbol("wifi", point: 480, weight: .semibold), .white)
let wifiSize = wifi.size
let wifiOrigin = NSPoint(
    x: (canvas - wifiSize.width) / 2,
    y: (canvas - wifiSize.height) / 2 + 70
)
wifi.draw(at: wifiOrigin, from: .zero, operation: .sourceOver, fraction: 1)

// --- Lower-right refresh badge: white circle + blue circular-arrow symbol ---
let badgeR: CGFloat = 168
let badgeCenter = NSPoint(x: 690, y: 320)
let badgeRect = NSRect(x: badgeCenter.x - badgeR, y: badgeCenter.y - badgeR,
                       width: badgeR * 2, height: badgeR * 2)

// soft ring so the white badge reads against the white Wi-Fi glyph
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
NSColor.white.setFill()
NSBezierPath(ovalIn: badgeRect).fill()
ctx.restoreGState()

let refresh = tinted(symbol("arrow.triangle.2.circlepath", point: 196, weight: .bold),
                     NSColor(srgbRed: 0.094, green: 0.392, blue: 0.918, alpha: 1))
let rSize = refresh.size
let rOrigin = NSPoint(x: badgeCenter.x - rSize.width / 2,
                      y: badgeCenter.y - rSize.height / 2)
refresh.draw(at: rOrigin, from: .zero, operation: .sourceOver, fraction: 1)

img.unlockFocus()

// --- Write PNG ---
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to encode PNG")
}
let out = URL(fileURLWithPath: "icon-master.png")
try! png.write(to: out)
print("wrote \(out.path) (\(Int(canvas))×\(Int(canvas)))")
