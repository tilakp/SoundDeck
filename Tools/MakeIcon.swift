import AppKit
import CoreGraphics
import Foundation

// Renders the Sound Deck app icon at each required size.
//
// Drawn per-size rather than downscaled from one master: the waveform bars and the
// squircle edge stay crisp at 16pt, where a resampled 1024 master turns to mush.

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

/// macOS icon art sits inset inside the canvas with a shadow around it.
let artInset: CGFloat = 0.094      // ~824/1024
let cornerRatio: CGFloat = 0.2237  // Big Sur squircle radius

func squirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    // A continuous-curvature corner reads noticeably softer than a plain arc.
    let path = CGMutablePath()
    let r = min(radius, min(rect.width, rect.height) / 2)
    let c = r * 0.2929 // control-point offset for a smooth superelliptical corner
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY

    path.move(to: CGPoint(x: minX + r, y: minY))
    path.addLine(to: CGPoint(x: maxX - r, y: minY))
    path.addCurve(to: CGPoint(x: maxX, y: minY + r),
                  control1: CGPoint(x: maxX - c, y: minY),
                  control2: CGPoint(x: maxX, y: minY + c))
    path.addLine(to: CGPoint(x: maxX, y: maxY - r))
    path.addCurve(to: CGPoint(x: maxX - r, y: maxY),
                  control1: CGPoint(x: maxX, y: maxY - c),
                  control2: CGPoint(x: maxX - c, y: maxY))
    path.addLine(to: CGPoint(x: minX + r, y: maxY))
    path.addCurve(to: CGPoint(x: minX, y: maxY - r),
                  control1: CGPoint(x: minX + c, y: maxY),
                  control2: CGPoint(x: minX, y: maxY - c))
    path.addLine(to: CGPoint(x: minX, y: minY + r))
    path.addCurve(to: CGPoint(x: minX + r, y: minY),
                  control1: CGPoint(x: minX, y: minY + c),
                  control2: CGPoint(x: minX + c, y: minY))
    path.closeSubpath()
    return path
}

func renderIcon(size: Int) -> Data? {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let inset = dimension * artInset
    let artRect = CGRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)
    let radius = artRect.width * cornerRatio
    let shape = squirclePath(in: artRect, radius: radius)

    // Drop shadow beneath the tile.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -dimension * 0.012),
        blur: dimension * 0.035,
        color: NSColor(calibratedWhite: 0, alpha: 0.34).cgColor
    )
    context.addPath(shape)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    // Indigo -> violet body.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bodyColors = [
        NSColor(srgbRed: 0.404, green: 0.435, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 0.545, green: 0.373, blue: 0.976, alpha: 1).cgColor,
        NSColor(srgbRed: 0.702, green: 0.353, blue: 0.937, alpha: 1).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: bodyColors, locations: [0, 0.55, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: artRect.minX, y: artRect.maxY),
            end: CGPoint(x: artRect.maxX, y: artRect.minY),
            options: []
        )
    }

    // Soft highlight sweeping the top-left, so the tile reads as lit rather than flat.
    let glowColors = [
        NSColor(calibratedWhite: 1, alpha: 0.32).cgColor,
        NSColor(calibratedWhite: 1, alpha: 0).cgColor
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0, 1]) {
        context.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: artRect.minX + artRect.width * 0.26, y: artRect.maxY - artRect.height * 0.16),
            startRadius: 0,
            endCenter: CGPoint(x: artRect.minX + artRect.width * 0.26, y: artRect.maxY - artRect.height * 0.16),
            endRadius: artRect.width * 0.72,
            options: []
        )
    }
    context.restoreGState()

    // Inner rim light along the top edge.
    context.saveGState()
    context.addPath(squirclePath(in: artRect.insetBy(dx: dimension * 0.004, dy: dimension * 0.004),
                                 radius: radius - dimension * 0.004))
    context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.30).cgColor)
    context.setLineWidth(max(1, dimension * 0.006))
    context.strokePath()
    context.restoreGState()

    // Waveform glyph: symmetric bars around the centre line.
    // Heights are hand-tuned rather than random so every size renders identically.
    let heights: [CGFloat] = [0.30, 0.56, 0.86, 1.0, 0.72, 0.44, 0.66, 0.34]
    let glyphWidth = artRect.width * 0.60
    let glyphHeight = artRect.height * 0.46
    let slot = glyphWidth / CGFloat(heights.count)
    let barWidth = slot * 0.58
    let centerY = artRect.midY
    let startX = artRect.midX - glyphWidth / 2 + (slot - barWidth) / 2

    context.setFillColor(NSColor.white.cgColor)
    for (index, factor) in heights.enumerated() {
        let barHeight = max(barWidth, glyphHeight * factor)
        let rect = CGRect(
            x: startX + CGFloat(index) * slot,
            y: centerY - barHeight / 2,
            width: barWidth,
            height: barHeight
        )
        // Fully rounded caps; at 16pt this is what keeps the glyph from looking like a grid.
        context.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    }
    context.fillPath()

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    guard let data = renderIcon(size: size) else {
        FileHandle.standardError.write("failed at \(size)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = outputDirectory.appendingPathComponent("icon_\(size)x\(size).png")
    try data.write(to: url)
    print("wrote \(url.lastPathComponent)")
}

// The catalog references a duplicate 32pt file for the 16pt @2x slot.
let thirtyTwo = outputDirectory.appendingPathComponent("icon_32x32.png")
let duplicate = outputDirectory.appendingPathComponent("icon_32x32 1.png")
try? FileManager.default.removeItem(at: duplicate)
try FileManager.default.copyItem(at: thirtyTwo, to: duplicate)
print("wrote icon_32x32 1.png")
