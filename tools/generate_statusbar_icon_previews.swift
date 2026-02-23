#!/usr/bin/env swift

import AppKit

struct PreviewSpec {
    let size: Int
}

let specs: [PreviewSpec] = [
    .init(size: 16),
    .init(size: 18),
    .init(size: 20),
    .init(size: 24),
    .init(size: 32)
]

let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
let outputDir = cwd.appendingPathComponent("artifacts/statusbar-icon-previews", isDirectory: true)

func drawStatusBarGlyph(pointSize: CGFloat, color: NSColor) -> NSImage {
    let size = NSSize(width: pointSize, height: pointSize)
    let image = NSImage(size: size)

    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high
    color.setStroke()

    func newStrokePath() -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 2.0
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        return path
    }

    let inset: CGFloat = max(0.55, pointSize * 0.045)
    var glyphRect = NSRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
    glyphRect.origin.y -= pointSize * 0.008

    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: glyphRect.minX, yBy: glyphRect.minY)
    transform.scaleX(by: glyphRect.width / 24.0, yBy: glyphRect.height / 24.0)
    transform.translateX(by: 24.0, yBy: 0.0)
    transform.scaleX(by: -1.0, yBy: 1.0)
    transform.concat()

    let topBody = newStrokePath()
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

    let midBar = newStrokePath()
    midBar.move(to: NSPoint(x: 6.0, y: 8.0))
    midBar.line(to: NSPoint(x: 18.0, y: 8.0))
    midBar.stroke()

    let rightOutlet = newStrokePath()
    rightOutlet.appendArc(withCenter: NSPoint(x: 16.5, y: 19.5),
                          radius: 2.5,
                          startAngle: -53.0,
                          endAngle: 179.0,
                          clockwise: false)
    rightOutlet.line(to: NSPoint(x: 14.0, y: 12.0))
    rightOutlet.stroke()

    let leftOutlet = newStrokePath()
    leftOutlet.appendArc(withCenter: NSPoint(x: 8.0, y: 17.0),
                         radius: 2.0,
                         startAngle: -134.5,
                         endAngle: 0.0,
                         clockwise: true)
    leftOutlet.line(to: NSPoint(x: 10.0, y: 12.0))
    leftOutlet.stroke()

    NSGraphicsContext.restoreGraphicsState()

    return image
}

func composite(glyph: NSImage, canvasSize: Int, background: NSColor) -> NSImage {
    let s = CGFloat(canvasSize)
    let image = NSImage(size: NSSize(width: s, height: s))

    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    background.setFill()
    rect.fill()
    glyph.draw(in: rect)

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "DocktorStatusBarPreview",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"]
        )
    }
    try data.write(to: url, options: .atomic)
}

try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

for spec in specs {
    let blackGlyph = drawStatusBarGlyph(pointSize: CGFloat(spec.size), color: .black)
    let whiteGlyph = drawStatusBarGlyph(pointSize: CGFloat(spec.size), color: .white)

    let templateURL = outputDir.appendingPathComponent("statusbar_template_\(spec.size).png")
    let lightURL = outputDir.appendingPathComponent("statusbar_on_light_\(spec.size).png")
    let darkURL = outputDir.appendingPathComponent("statusbar_on_dark_\(spec.size).png")

    try writePNG(blackGlyph, to: templateURL)
    try writePNG(composite(glyph: blackGlyph, canvasSize: spec.size, background: .white), to: lightURL)
    try writePNG(composite(glyph: whiteGlyph, canvasSize: spec.size, background: NSColor(calibratedWhite: 0.08, alpha: 1.0)), to: darkURL)

    print("Wrote \(templateURL.path)")
    print("Wrote \(lightURL.path)")
    print("Wrote \(darkURL.path)")
}
