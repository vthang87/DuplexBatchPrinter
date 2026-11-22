// Builds the Tauri icon source from the Swift app's artwork.
//
// Resources/AppIcon.png is a full-bleed square with black corners and no
// alpha, so macOS shows it as a black square that is larger than other Dock
// icons. This crops the rounded tile, masks it with a continuous rounded rect
// and centers it on a transparent 1024x1024 canvas using Apple's 824pt grid.
//
//   swift desktop/scripts/make-app-icon.swift Resources/AppIcon.png desktop/app-icon.png
//   cd desktop && npx tauri icon app-icon.png
import AppKit
import QuartzCore

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: make-app-icon.swift <input.png> <output.png>\n".data(using: .utf8)!)
    exit(64)
}

let canvas = 1024
let tile: CGFloat = 824
/// Slightly rounder than Apple's 185 so the source's black corners are fully clipped.
let cornerRadius: CGFloat = 210
/// Pixels trimmed from each edge of the source tile, removing its
/// anti-aliased black rim (the drawn tile spans 0...1252 of 1254).
let sourceInset: CGFloat = 8

guard let data = FileManager.default.contents(atPath: args[1]),
      let rep = NSBitmapImageRep(data: data),
      let source = rep.cgImage
else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

let side = CGFloat(min(source.width, source.height)) - 2 // drawn tile excludes the last 2px
let crop = CGRect(x: sourceInset, y: sourceInset, width: side - 2 * sourceInset, height: side - 2 * sourceInset)
guard let cropped = source.cropping(to: crop) else { exit(1) }

let layer = CALayer()
layer.frame = CGRect(x: 0, y: 0, width: tile, height: tile)
layer.contents = cropped
layer.contentsGravity = .resize
layer.cornerRadius = cornerRadius
layer.cornerCurve = .continuous
layer.masksToBounds = true

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }
ctx.interpolationQuality = .high
let margin = (CGFloat(canvas) - tile) / 2
ctx.translateBy(x: margin, y: margin)
layer.render(in: ctx)

guard let output = ctx.makeImage() else { exit(1) }
let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) (\(canvas)x\(canvas), tile \(Int(tile)), radius \(Int(cornerRadius)))")
