#!/usr/bin/env swift
// Welcome banner generator: turns Vincent's `startupimage.png` (pin + "Local IA" wordmark on a transparent
// background) into the `WelcomeBanner` image set, with a light and a dark appearance.
//
// Run from anywhere:  swift Design/banner/generate.swift
// Input:   Design/banner/startupimage.png
// Output:  Localia/Assets.xcassets/WelcomeBanner.imageset/{welcome-banner-light,welcome-banner-dark}.png + Contents.json
//
// The source is already cut out, so only the colours change: each pixel keeps its alpha (anti-aliasing included)
// and takes a flat ink colour. The pin and "IA" use the logo teal (Theme.accent: #045A54 light, #4FD1C5 dark);
// "Local" is near-black in light mode and near-white in dark mode. The canvas is trimmed to the ink.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let input = root.appendingPathComponent("Design/banner/startupimage.png")
let outDir = root.appendingPathComponent("Localia/Assets.xcassets/WelcomeBanner.imageset")

guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fatalError("Cannot read \(input.path)")
}
let w = image.width, h = image.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let readContext = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
readContext.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

// Ink columns of the source: [pin] [L o c a l] [I A]. "Local" sits strictly between these two bounds.
let wordStart = 540, wordEnd = 1640

// Bounding box of the ink, plus a small margin.
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<h { for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 8 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
let pad = 12
minX = max(0, minX - pad); minY = max(0, minY - pad); maxX = min(w - 1, maxX + pad); maxY = min(h - 1, maxY + pad)
let cw = maxX - minX + 1, ch = maxY - minY + 1

struct RGB { let r, g, b: UInt8 }
func rgb(_ hex: UInt32) -> RGB { RGB(r: UInt8(hex >> 16 & 0xFF), g: UInt8(hex >> 8 & 0xFF), b: UInt8(hex & 0xFF)) }

func render(teal: RGB, word: RGB, to name: String) throws {
    var out = [UInt8](repeating: 0, count: cw * ch * 4)
    for y in 0..<ch { for x in 0..<cw {
        let sx = x + minX, sy = y + minY
        let a = pixels[(sy * w + sx) * 4 + 3]
        guard a > 0 else { continue }
        let ink = (wordStart...wordEnd).contains(sx) ? word : teal
        let i = (y * cw + x) * 4
        // Premultiplied output.
        out[i] = UInt8(Int(ink.r) * Int(a) / 255)
        out[i + 1] = UInt8(Int(ink.g) * Int(a) / 255)
        out[i + 2] = UInt8(Int(ink.b) * Int(a) / 255)
        out[i + 3] = a
    } }
    let ctx = CGContext(data: &out, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let url = outDir.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Cannot write \(url.path)") }
    print("wrote \(url.path) (\(cw)x\(ch))")
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try render(teal: rgb(0x045A54), word: rgb(0x0E1B1F), to: "welcome-banner-light.png")
try render(teal: rgb(0x4FD1C5), word: rgb(0xF2F5F4), to: "welcome-banner-dark.png")

let contents = """
{
  "images" : [
    {
      "filename" : "welcome-banner-light.png",
      "idiom" : "universal",
      "scale" : "2x"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "welcome-banner-dark.png",
      "idiom" : "universal",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
