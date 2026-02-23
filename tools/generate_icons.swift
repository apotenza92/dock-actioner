#!/usr/bin/env swift

import AppKit

struct IconSpec {
    let size: Int
    let filename: String
}

struct IconTheme {
    let baseTop: NSColor
    let baseBottom: NSColor
    let diagonalTop: NSColor
    let diagonalMid: NSColor
    let diagonalBottom: NSColor
    let vignetteBottom: NSColor
    let glyphTopAlpha: CGFloat
    let glyphBottomAlpha: CGFloat
}

struct IconSet {
    let folderName: String
    let label: String
    let theme: IconTheme
}

let specs: [IconSpec] = [
    .init(size: 16, filename: "icon_16x16.png"),
    .init(size: 32, filename: "icon_16x16@2x.png"),
    .init(size: 32, filename: "icon_32x32.png"),
    .init(size: 64, filename: "icon_32x32@2x.png"),
    .init(size: 128, filename: "icon_128x128.png"),
    .init(size: 256, filename: "icon_128x128@2x.png"),
    .init(size: 256, filename: "icon_256x256.png"),
    .init(size: 512, filename: "icon_256x256@2x.png"),
    .init(size: 512, filename: "icon_512x512.png"),
    .init(size: 1024, filename: "icon_512x512@2x.png")
]

let stableTheme = IconTheme(
    baseTop: NSColor(calibratedRed: 1.00, green: 0.89, blue: 0.46, alpha: 1.0),
    baseBottom: NSColor(calibratedRed: 0.96, green: 0.44, blue: 0.14, alpha: 1.0),
    diagonalTop: NSColor(calibratedRed: 1.00, green: 0.96, blue: 0.78, alpha: 0.38),
    diagonalMid: NSColor(calibratedRed: 1.00, green: 0.68, blue: 0.27, alpha: 0.10),
    diagonalBottom: NSColor(calibratedRed: 0.86, green: 0.31, blue: 0.09, alpha: 0.22),
    vignetteBottom: NSColor(calibratedRed: 0.54, green: 0.18, blue: 0.04, alpha: 0.20),
    glyphTopAlpha: 0.99,
    glyphBottomAlpha: 0.74
)

let betaTheme = IconTheme(
    baseTop: NSColor(calibratedRed: 0.58, green: 0.79, blue: 1.00, alpha: 1.0),
    baseBottom: NSColor(calibratedRed: 0.29, green: 0.27, blue: 0.82, alpha: 1.0),
    diagonalTop: NSColor(calibratedRed: 0.92, green: 0.96, blue: 1.00, alpha: 0.36),
    diagonalMid: NSColor(calibratedRed: 0.60, green: 0.72, blue: 1.00, alpha: 0.11),
    diagonalBottom: NSColor(calibratedRed: 0.20, green: 0.18, blue: 0.58, alpha: 0.24),
    vignetteBottom: NSColor(calibratedRed: 0.12, green: 0.11, blue: 0.33, alpha: 0.22),
    glyphTopAlpha: 0.99,
    glyphBottomAlpha: 0.74
)

let iconSets: [IconSet] = [
    .init(folderName: "AppIcon.appiconset", label: "stable", theme: stableTheme),
    .init(folderName: "AppIconBeta.appiconset", label: "beta", theme: betaTheme)
]

let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
let assetsCatalog = cwd.appendingPathComponent("Docktor/Assets.xcassets", isDirectory: true)

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func newStrokePath(lineWidth: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.lineWidth = lineWidth
    path.lineJoinStyle = .round
    path.lineCapStyle = .round
    return path
}

func drawAirVentGlyph(
    in rect: NSRect,
    strokeColor: NSColor,
    lineWidth: CGFloat,
    mirroredHorizontally: Bool
) {
    NSGraphicsContext.saveGraphicsState()

    let transform = NSAffineTransform()
    transform.translateX(by: rect.minX, yBy: rect.minY)
    transform.scaleX(by: rect.width / 24.0, yBy: rect.height / 24.0)

    if mirroredHorizontally {
        transform.translateX(by: 24.0, yBy: 0.0)
        transform.scaleX(by: -1.0, yBy: 1.0)
    }

    transform.concat()
    strokeColor.setStroke()

    let topBody = newStrokePath(lineWidth: lineWidth)
    topBody.move(to: NSPoint(x: 6.0, y: 12.0))
    topBody.line(to: NSPoint(x: 4.0, y: 12.0))
    topBody.curve(to: NSPoint(x: 2.0, y: 10.0),
                  controlPoint1: NSPoint(x: 2.9, y: 12.0),
                  controlPoint2: NSPoint(x: 2.0, y: 11.1))
    topBody.line(to: NSPoint(x: 2.0, y: 5.0))
    topBody.curve(to: NSPoint(x: 4.0, y: 3.0),
                  controlPoint1: NSPoint(x: 2.0, y: 3.9),
                  controlPoint2: NSPoint(x: 2.9, y: 3.0))
    topBody.line(to: NSPoint(x: 20.0, y: 3.0))
    topBody.curve(to: NSPoint(x: 22.0, y: 5.0),
                  controlPoint1: NSPoint(x: 21.1, y: 3.0),
                  controlPoint2: NSPoint(x: 22.0, y: 3.9))
    topBody.line(to: NSPoint(x: 22.0, y: 10.0))
    topBody.curve(to: NSPoint(x: 20.0, y: 12.0),
                  controlPoint1: NSPoint(x: 22.0, y: 11.1),
                  controlPoint2: NSPoint(x: 21.1, y: 12.0))
    topBody.line(to: NSPoint(x: 18.0, y: 12.0))
    topBody.stroke()

    let midBar = newStrokePath(lineWidth: lineWidth)
    midBar.move(to: NSPoint(x: 6.0, y: 8.0))
    midBar.line(to: NSPoint(x: 18.0, y: 8.0))
    midBar.stroke()

    let rightOutlet = newStrokePath(lineWidth: lineWidth)
    rightOutlet.appendArc(withCenter: NSPoint(x: 16.5, y: 19.5),
                          radius: 2.5,
                          startAngle: -53.0,
                          endAngle: 179.0,
                          clockwise: false)
    rightOutlet.line(to: NSPoint(x: 14.0, y: 12.0))
    rightOutlet.stroke()

    let leftOutlet = newStrokePath(lineWidth: lineWidth)
    leftOutlet.appendArc(withCenter: NSPoint(x: 8.0, y: 17.0),
                         radius: 2.0,
                         startAngle: -134.5,
                         endAngle: 0.0,
                         clockwise: true)
    leftOutlet.line(to: NSPoint(x: 10.0, y: 12.0))
    leftOutlet.stroke()

    NSGraphicsContext.restoreGraphicsState()
}

func drawAirVentGlyphVerticalGradient(
    in rect: NSRect,
    lineWidth: CGFloat,
    mirroredHorizontally: Bool,
    topAlpha: CGFloat,
    bottomAlpha: CGFloat
) {
    let maskImage = NSImage(size: rect.size)
    maskImage.lockFocus()
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: rect.size).fill()
    drawAirVentGlyph(
        in: NSRect(origin: .zero, size: rect.size),
        strokeColor: .white,
        lineWidth: lineWidth,
        mirroredHorizontally: mirroredHorizontally
    )
    maskImage.unlockFocus()

    guard let maskCG = maskImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = NSGraphicsContext.current?.cgContext,
          let gradient = CGGradient(
              colorsSpace: CGColorSpaceCreateDeviceRGB(),
              colors: [
                  NSColor(calibratedWhite: 1.0, alpha: topAlpha).cgColor,
                  NSColor(calibratedWhite: 1.0, alpha: bottomAlpha).cgColor
              ] as CFArray,
              locations: [0.0, 1.0]
          ) else {
        drawAirVentGlyph(
            in: rect,
            strokeColor: NSColor(calibratedWhite: 1.0, alpha: bottomAlpha),
            lineWidth: lineWidth,
            mirroredHorizontally: mirroredHorizontally
        )
        return
    }

    ctx.saveGState()
    ctx.clip(to: rect, mask: maskCG)
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )
    ctx.restoreGState()
}

func drawIcon(size: Int, theme: IconTheme) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))

    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high
    let canvas = NSRect(x: 0, y: 0, width: s, height: s)
    NSColor.clear.setFill()
    canvas.fill()

    let outerInset = s * 0.06
    let outerRect = canvas.insetBy(dx: outerInset, dy: outerInset)
    let outer = roundedRect(outerRect, radius: s * 0.22)

    let baseGradient = NSGradient(colors: [theme.baseTop, theme.baseBottom])!
    baseGradient.draw(in: outer, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    outer.addClip()

    let diagonal = NSGradient(colors: [
        theme.diagonalTop,
        theme.diagonalMid,
        theme.diagonalBottom
    ])!
    diagonal.draw(in: outerRect, angle: -35)

    let subtleVignette = NSGradient(colors: [
        NSColor(calibratedWhite: 0.0, alpha: 0.0),
        theme.vignetteBottom
    ])!
    subtleVignette.draw(in: outerRect, relativeCenterPosition: NSPoint(x: 0.0, y: -0.15))

    NSGraphicsContext.restoreGraphicsState()

    var glyphRect = outerRect.insetBy(dx: s * 0.10, dy: s * 0.10)
    glyphRect.origin.y += s * 0.004

    drawAirVentGlyphVerticalGradient(
        in: glyphRect,
        lineWidth: 1.9,
        mirroredHorizontally: true,
        topAlpha: theme.glyphTopAlpha,
        bottomAlpha: theme.glyphBottomAlpha
    )

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DocktorIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try data.write(to: url, options: .atomic)
}

func appIconContentsJSON() -> String {
    """
    {
      "images" : [
        { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
        { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
        { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
        { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
        { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
        { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
        { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
        { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
        { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
        { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
}

guard fm.fileExists(atPath: assetsCatalog.path) else {
    fputs("Missing assets catalog: \(assetsCatalog.path)\n", stderr)
    exit(1)
}

for iconSet in iconSets {
    let iconsetURL = assetsCatalog.appendingPathComponent(iconSet.folderName, isDirectory: true)
    try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

    for spec in specs {
        let image = drawIcon(size: spec.size, theme: iconSet.theme)
        let out = iconsetURL.appendingPathComponent(spec.filename)
        try writePNG(image, to: out)
        print("Wrote \(out.path)")
    }

    let contentsURL = iconsetURL.appendingPathComponent("Contents.json")
    try appIconContentsJSON().data(using: .utf8)?.write(to: contentsURL, options: .atomic)
    print("Updated \(contentsURL.path) [\(iconSet.label)]")
}
