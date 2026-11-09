#!/usr/bin/env swift
// Localia icon generator: one vector definition of the mark (map pin + four-point sparkle), rendered to
// SVG sources, the macOS AppIcon set, the menu-bar template PDFs and preview PNGs.
//
// Run from anywhere:  swift Design/icon/generate.swift [extra-preview-dir]
// Outputs (paths relative to the repo root):
//   Design/icon/*.svg                                     vector sources
//   Design/icon/previews/*.png                            variant (a) and (b) renders, side by side
//   Localia/Assets.xcassets/AppIcon.appiconset/*          16…1024 px, variant (a)
//   Localia/Assets.xcassets/MenuBarOutline.imageset/*     template PDF, local mode off
//   Localia/Assets.xcassets/MenuBarFilled.imageset/*      template PDF, local mode on
// With an extra directory, menu-bar and small-size inspection previews are written there too.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Path model (y down, like SVG)

struct Pt { var x: Double; var y: Double }

enum Op { case move(Pt), line(Pt), curve(Pt, Pt, Pt), close }

struct Shape {
    var ops: [Op] = []

    mutating func move(_ p: Pt) { ops.append(.move(p)) }
    mutating func line(_ p: Pt) { ops.append(.line(p)) }
    mutating func curve(_ a: Pt, _ b: Pt, _ c: Pt) { ops.append(.curve(a, b, c)) }
    mutating func close() { ops.append(.close) }

    /// Appends a circular arc as cubic Béziers, continuing the current subpath. Angles in radians;
    /// with y down, an increasing angle runs clockwise on screen.
    mutating func arc(center c: Pt, radius r: Double, from a0: Double, to a1: Double) {
        let n = max(1, Int((abs(a1 - a0) / (.pi / 2)).rounded(.up)))
        let step = (a1 - a0) / Double(n)
        let k = 4.0 / 3.0 * tan(step / 4)
        for i in 0..<n {
            let s = a0 + step * Double(i), e = s + step
            let p0 = Pt(x: c.x + r * cos(s), y: c.y + r * sin(s))
            let p3 = Pt(x: c.x + r * cos(e), y: c.y + r * sin(e))
            curve(Pt(x: p0.x - k * r * sin(s), y: p0.y + k * r * cos(s)),
                  Pt(x: p3.x + k * r * sin(e), y: p3.y - k * r * cos(e)), p3)
        }
    }

    static func + (a: Shape, b: Shape) -> Shape { Shape(ops: a.ops + b.ops) }

    func map(_ f: (Pt) -> Pt) -> Shape {
        Shape(ops: ops.map {
            switch $0 {
            case .move(let p): .move(f(p))
            case .line(let p): .line(f(p))
            case .curve(let a, let b, let c): .curve(f(a), f(b), f(c))
            case .close: .close
            }
        })
    }

    func placed(scale s: Double, x: Double, y: Double) -> Shape { map { Pt(x: $0.x * s + x, y: $0.y * s + y) } }

    var svg: String {
        func f(_ v: Double) -> String {
            let s = String(format: "%.2f", v)
            let t = s.contains(".") ? String(s.reversed().drop(while: { $0 == "0" }).drop(while: { $0 == "." }).reversed()) : s
            return t == "-0" ? "0" : t
        }
        func p(_ q: Pt) -> String { "\(f(q.x)) \(f(q.y))" }
        return ops.map {
            switch $0 {
            case .move(let a): "M\(p(a))"
            case .line(let a): "L\(p(a))"
            case .curve(let a, let b, let c): "C\(p(a)) \(p(b)) \(p(c))"
            case .close: "Z"
            }
        }.joined(separator: " ")
    }

    var cg: CGPath {
        let path = CGMutablePath()
        for op in ops {
            switch op {
            case .move(let a): path.move(to: CGPoint(x: a.x, y: a.y))
            case .line(let a): path.addLine(to: CGPoint(x: a.x, y: a.y))
            case .curve(let a, let b, let c):
                path.addCurve(to: CGPoint(x: c.x, y: c.y), control1: CGPoint(x: a.x, y: a.y), control2: CGPoint(x: b.x, y: b.y))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

// MARK: - The mark (unit: pin circle radius = 1, origin at the circle centre)
// Proportions measured on Vincent's source raster (logoapps-localia): circle r = 374 px, tip 1.47 r below
// the centre, sparkle arms 0.57 r.

let tipDistance = 1.51      // centre → apex of the unrounded tip
let tipRadius = 0.08        // rounding of the tip
let pinBottom = tipDistance - tipRadius / (1 / tipDistance) + tipRadius

/// Teardrop: a circle continued by its two tangents to a rounded tip.
func pin(radius r: Double = 1, tip d: Double = tipDistance, tipRadius rt: Double = tipRadius) -> Shape {
    let alpha = acos(r / d)
    let sinB = r / d
    let thL = Double.pi / 2 + alpha, thR = Double.pi / 2 - alpha
    let f = Pt(x: 0, y: d - rt / sinB)
    var s = Shape()
    s.move(Pt(x: f.x + rt * cos(thL), y: f.y + rt * sin(thL)))
    s.line(Pt(x: r * cos(thL), y: r * sin(thL)))
    s.arc(center: Pt(x: 0, y: 0), radius: r, from: thL, to: thR + 2 * .pi)
    s.line(Pt(x: f.x + rt * cos(thR), y: f.y + rt * sin(thR)))
    s.arc(center: f, radius: rt, from: thR, to: thL)
    s.close()
    return s
}

/// The pin shrunk inward by `w` (same centre, parallel sides): the inner edge of an outline of width `w`.
func pinInset(_ w: Double) -> Shape {
    pin(radius: 1 - w, tip: tipDistance * (1 - w), tipRadius: max(tipRadius - w, 0.02))
}

/// Symmetric four-point sparkle with concave sides. `pinch` places the side controls on the axes: 0.45 is a
/// quarter circle (thin waist), higher is plumper; `spread` tilts the controls off the axes so the points
/// taper instead of ending in needles. `tip` rounds the points (fraction of the arm).
func sparkle(arm L: Double, pinch k: Double, spread a: Double = 0.07, tip e: Double = 0.045) -> Shape {
    let q = e * L, h = 3 * e * L
    // One quadrant: rounded cap at the top point, then the concave side down to the right point.
    let quadrant: [Op] = [
        .curve(Pt(x: -q, y: -L + 0.2 * h), Pt(x: q, y: -L + 0.2 * h), Pt(x: q, y: -L + h)),
        .curve(Pt(x: q + a * L, y: -k * L), Pt(x: k * L, y: -q - a * L), Pt(x: L - h, y: -q)),
    ]
    func rot(_ p: Pt, _ i: Int) -> Pt { (0..<i).reduce(p) { r, _ in Pt(x: -r.y, y: r.x) } }
    var s = Shape()
    s.move(Pt(x: -q, y: -L + h))
    for i in 0..<4 {
        for op in quadrant {
            if case .curve(let a, let b, let c) = op { s.curve(rot(a, i), rot(b, i), rot(c, i)) }
        }
    }
    s.close()
    return s
}

/// Filled pin with the sparkle cut out (fill even-odd).
func mark(arm: Double = 0.57, pinch: Double = 0.5) -> Shape { pin() + sparkle(arm: arm, pinch: pinch) }

// MARK: - Colours

func rgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: a)
}
func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }

let teal: UInt32 = 0x045A54

struct Variant {
    let name: String
    let bgTop: UInt32, bgBottom: UInt32
    let pinTop: UInt32, pinBottom: UInt32
    let pinShadow: Double            // opacity of the soft shadow under the pin
}

// (a) white tile, teal pin, white sparkle — the shipped icon.
let variantA = Variant(name: "a", bgTop: 0xFFFFFF, bgBottom: 0xE6EFED, pinTop: 0x0A7068, pinBottom: 0x034A45, pinShadow: 0.22)
// (b) teal tile, white pin, sparkle cut out to the teal.
let variantB = Variant(name: "b", bgTop: 0x0F8A7F, bgBottom: 0x033F3B, pinTop: 0xFFFFFF, pinBottom: 0xDDEDEA, pinShadow: 0.30)

// MARK: - App icon (1024 grid: 824 px body, 100 px margins, continuous corners)

let canvas = 1024.0, body = 824.0

/// macOS-style squircle (superellipse, n = 5) of side `size` centred on the canvas.
func squircle(size: Double = body) -> Shape {
    let a = size / 2, n = 5.0, c = canvas / 2
    var s = Shape()
    let steps = 720
    for i in 0..<steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let p = Pt(x: c + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n), y: c + a * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n))
        if i == 0 { s.move(p) } else { s.line(p) }
    }
    s.close()
    return s
}

/// The mark placed on the 1024 canvas. Small sizes get a larger, plumper glyph so the sparkle survives.
func iconMark(small: Bool) -> Shape {
    let height = small ? 610.0 : 560.0
    let r = height / (1 + pinBottom)
    let cy = canvas / 2 - (pinBottom - 1) / 2 * r
    return mark(arm: small ? 0.6 : 0.57, pinch: small ? 0.58 : 0.5).placed(scale: r, x: canvas / 2, y: cy)
}

func drawIcon(_ v: Variant, in ctx: CGContext, scale s: Double, small: Bool) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let tile = squircle().cg
    // Tile drop shadow (Apple grid: soft, below), skipped at tiny sizes where it only muddies the edge.
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 20 * s, color: rgb(0x000000, 0.28))
        ctx.addPath(tile); ctx.setFillColor(rgb(v.bgBottom)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(v.bgTop), rgb(v.bgBottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    // Hairline inner edge so the white tile reads on a white desktop.
    ctx.addPath(tile); ctx.setStrokeColor(rgb(0x000000, v.name == "a" ? 0.10 : 0.0)); ctx.setLineWidth(small ? 24 : 4); ctx.strokePath()

    let m = iconMark(small: small).cg
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 28 * s, color: rgb(0x01302C, v.pinShadow))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(m); ctx.setFillColor(rgb(v.pinBottom)); ctx.fillPath(using: .evenOdd)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
    ctx.addPath(m); ctx.clip(using: .evenOdd)
    let pg = CGGradient(colorsSpace: cs, colors: [rgb(v.pinTop), rgb(v.pinBottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(pg, start: CGPoint(x: 0, y: 200), end: CGPoint(x: 0, y: 830), options: [])
    ctx.restoreGState()
}

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func renderIcon(_ v: Variant, px: Int) -> CGImage {
    let ctx = bitmap(px, px)
    let s = Double(px) / canvas
    ctx.translateBy(x: 0, y: Double(px)); ctx.scaleBy(x: s, y: -s)
    drawIcon(v, in: ctx, scale: s, small: px <= 32)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
    precondition(CGImageDestinationFinalize(d), "PNG write failed: \(url.path)")
}

func write(_ text: String, _ url: URL) {
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

func iconSVG(_ v: Variant) -> String {
    let sm = iconMark(small: false)
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
      <!-- Localia app icon, variant (\(v.name)). Generated by generate.swift; do not edit by hand. -->
      <defs>
        <linearGradient id="bg" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="\(hex(v.bgTop))"/><stop offset="1" stop-color="\(hex(v.bgBottom))"/>
        </linearGradient>
        <linearGradient id="pin" x1="0" y1="200" x2="0" y2="830" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="\(hex(v.pinTop))"/><stop offset="1" stop-color="\(hex(v.pinBottom))"/>
        </linearGradient>
        <filter id="tileShadow" x="-10%" y="-10%" width="120%" height="125%">
          <feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000" flood-opacity="0.28"/>
        </filter>
        <filter id="pinShadow" x="-20%" y="-20%" width="140%" height="140%">
          <feDropShadow dx="0" dy="14" stdDeviation="14" flood-color="#01302C" flood-opacity="\(v.pinShadow)"/>
        </filter>
      </defs>
      <path d="\(squircle().svg)" fill="url(#bg)" filter="url(#tileShadow)"/>
      <path d="\(sm.svg)" fill="url(#pin)" fill-rule="evenodd" filter="url(#pinShadow)"/>
    </svg>

    """
}

// MARK: - Menu-bar template (18 pt canvas, 16 pt glyph)

let barCanvas = 18.0, barGlyph = 16.0, barStroke = 1.5

func barShape(filled: Bool) -> Shape {
    let r = barGlyph / (1 + pinBottom)
    let cy = barCanvas / 2 - (pinBottom - 1) / 2 * r
    let w = barStroke / r
    // Filled: solid pin, sparkle knocked out. Outline: pin ring with a solid sparkle inside
    // (the SF Symbols `x` / `x.fill` convention). Both fill even-odd.
    let unit = filled ? pin() + sparkle(arm: 0.6, pinch: 0.62)
                      : pin() + pinInset(w) + sparkle(arm: 0.5, pinch: 0.62)
    return unit.placed(scale: r, x: barCanvas / 2, y: cy)
}

func writeTemplatePDF(_ shape: Shape, _ url: URL) {
    var box = CGRect(x: 0, y: 0, width: barCanvas, height: barCanvas)
    let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextCreator: "Localia generate.swift"] as CFDictionary)!
    ctx.beginPDFPage(nil)
    ctx.translateBy(x: 0, y: barCanvas); ctx.scaleBy(x: 1, y: -1)
    ctx.addPath(shape.cg); ctx.setFillColor(rgb(0x000000)); ctx.fillPath(using: .evenOdd)
    ctx.endPDFPage(); ctx.closePDF()
}

func barSVG(_ shape: Shape, _ label: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18" width="18" height="18">
      <!-- Localia menu-bar template, \(label). Generated by generate.swift; do not edit by hand. -->
      <path d="\(shape.svg)" fill="#000" fill-rule="evenodd"/>
    </svg>

    """
}

/// A strip of menu bar with both glyphs, as the system draws a template image (black on light, white on dark).
func menuBarPreview(dark: Bool, scale: Int) -> CGImage {
    let wPt = 76.0, hPt = 24.0
    let ctx = bitmap(Int(wPt) * scale, Int(hPt) * scale)
    let s = Double(scale)
    ctx.translateBy(x: 0, y: hPt * s); ctx.scaleBy(x: s, y: -s)
    ctx.setFillColor(rgb(dark ? 0x232325 : 0xE8E8EA)); ctx.fill(CGRect(x: 0, y: 0, width: wPt, height: hPt))
    let ink = dark ? rgb(0xFFFFFF, 0.92) : rgb(0x000000, 0.85)
    for (i, filled) in [false, true].enumerated() {
        ctx.saveGState()
        ctx.translateBy(x: 12 + Double(i) * 34, y: (hPt - barCanvas) / 2)
        ctx.addPath(barShape(filled: filled).cg); ctx.setFillColor(ink); ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}

/// Composites images left to right on a background, optionally enlarged with nearest-neighbour sampling.
func row(_ images: [CGImage], zoom: Int = 1, gap: Int = 40, bg: UInt32) -> CGImage {
    let w = images.reduce(gap) { $0 + $1.width * zoom + gap }
    let h = (images.map(\.height).max() ?? 0) * zoom + 2 * gap
    let ctx = bitmap(w, h)
    ctx.setFillColor(rgb(bg)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .none
    var x = gap
    for img in images {
        let iw = img.width * zoom, ih = img.height * zoom
        ctx.draw(img, in: CGRect(x: x, y: (h - ih) / 2, width: iw, height: ih))
        x += iw + gap
    }
    return ctx.makeImage()!
}

// MARK: - Main

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let root = here.deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
let previews = here.appendingPathComponent("previews")
let assets = root.appendingPathComponent("Localia/Assets.xcassets")
let appIcon = assets.appendingPathComponent("AppIcon.appiconset")
let barOff = assets.appendingPathComponent("MenuBarOutline.imageset")
let barOn = assets.appendingPathComponent("MenuBarFilled.imageset")
for dir in [previews, appIcon, barOff, barOn] { try! fm.createDirectory(at: dir, withIntermediateDirectories: true) }

// Vector sources.
let markShape = mark()
let markBox = markShape.placed(scale: 100, x: 100, y: 100)
write("""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 \(String(format: "%.2f", 100 + 100 * pinBottom))" width="200" height="\(Int((100 + 100 * pinBottom).rounded(.up)))">
  <!-- Localia mark: map pin with a four-point sparkle cut out. Generated by generate.swift; do not edit by hand. -->
  <path d="\(markBox.svg)" fill="\(hex(teal))" fill-rule="evenodd"/>
</svg>

""", here.appendingPathComponent("localia-mark.svg"))
write(iconSVG(variantA), here.appendingPathComponent("app-icon-a.svg"))
write(iconSVG(variantB), here.appendingPathComponent("app-icon-b.svg"))
write(barSVG(barShape(filled: false), "outline (local mode off)"), here.appendingPathComponent("menubar-outline.svg"))
write(barSVG(barShape(filled: true), "filled (local mode on)"), here.appendingPathComponent("menubar-filled.svg"))

// App icon set (variant a).
var entries: [String] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        writePNG(renderIcon(variantA, px: pt * scale), appIcon.appendingPathComponent(name))
        entries.append("""
            {
              "filename" : "\(name)",
              "idiom" : "mac",
              "scale" : "\(scale)x",
              "size" : "\(pt)x\(pt)"
            }
        """)
    }
}
write("{\n  \"images\" : [\n\(entries.joined(separator: ",\n"))\n  ],\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n",
      appIcon.appendingPathComponent("Contents.json"))
write("{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n", assets.appendingPathComponent("Contents.json"))

// Menu-bar templates.
for (dir, file, filled) in [(barOff, "menubar-outline.pdf", false), (barOn, "menubar-filled.pdf", true)] {
    writeTemplatePDF(barShape(filled: filled), dir.appendingPathComponent(file))
    write("""
    {
      "images" : [
        {
          "filename" : "\(file)",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "properties" : {
        "preserves-vector-representation" : true,
        "template-rendering-intent" : "template"
      }
    }

    """, dir.appendingPathComponent("Contents.json"))
}

// Committed previews: both variants at 1024 and side by side.
let a1024 = renderIcon(variantA, px: 1024), b1024 = renderIcon(variantB, px: 1024)
writePNG(a1024, previews.appendingPathComponent("app-icon-a.png"))
writePNG(b1024, previews.appendingPathComponent("app-icon-b.png"))
writePNG(row([a1024, b1024], bg: 0xDCDCE0), previews.appendingPathComponent("app-icon-variants.png"))

// Inspection previews (optional directory).
if CommandLine.arguments.count > 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[1])
    try! fm.createDirectory(at: out, withIntermediateDirectories: true)
    writePNG(a1024, out.appendingPathComponent("app-icon-1024.png"))
    writePNG(renderIcon(variantA, px: 128), out.appendingPathComponent("app-icon-128.png"))
    writePNG(renderIcon(variantA, px: 32), out.appendingPathComponent("app-icon-32.png"))
    writePNG(row([a1024, b1024], bg: 0xDCDCE0), out.appendingPathComponent("variants-side-by-side.png"))
    let sizes = [128, 64, 32, 16]
    for (bg, label) in [(0xF2F2F4 as UInt32, "light"), (0x1C1C1E as UInt32, "dark")] {
        writePNG(row(sizes.map { renderIcon(variantA, px: $0) } + sizes.map { renderIcon(variantB, px: $0) }, gap: 24, bg: bg),
                 out.appendingPathComponent("app-icon-sizes-\(label).png"))
    }
    writePNG(row([renderIcon(variantA, px: 16), renderIcon(variantA, px: 32), renderIcon(variantB, px: 16), renderIcon(variantB, px: 32)],
                 zoom: 8, gap: 16, bg: 0xF2F2F4), out.appendingPathComponent("app-icon-small-zoom8.png"))
    for dark in [false, true] {
        for scale in [1, 2] {
            let img = menuBarPreview(dark: dark, scale: scale)
            let tag = "\(dark ? "dark" : "light")-\(scale)x"
            writePNG(img, out.appendingPathComponent("menubar-\(tag).png"))
            writePNG(row([img], zoom: scale == 1 ? 10 : 5, gap: 0, bg: 0), out.appendingPathComponent("menubar-\(tag)-zoom.png"))
        }
    }
}
print("Icons generated in \(root.path)")
