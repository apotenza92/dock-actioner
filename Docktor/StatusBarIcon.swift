import AppKit

enum StatusBarIcon {
    static func image(pointSize: CGFloat = 18) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size)
        image.isTemplate = true

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.black.setStroke()

        let inset: CGFloat = max(0.55, pointSize * 0.045)
        var glyphRect = NSRect(
            x: inset,
            y: inset,
            width: size.width - inset * 2,
            height: size.height - inset * 2
        )
        glyphRect.origin.y -= pointSize * 0.008

        drawAirVentGlyph(in: glyphRect, mirroredHorizontally: true, flippedVertically: false)
        return image
    }

    private static func newStrokePath(lineWidth: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        return path
    }

    private static func drawAirVentGlyph(in rect: NSRect, mirroredHorizontally: Bool, flippedVertically: Bool) {
        NSGraphicsContext.saveGraphicsState()

        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 24.0, yBy: rect.height / 24.0)

        if mirroredHorizontally {
            transform.translateX(by: 24.0, yBy: 0.0)
            transform.scaleX(by: -1.0, yBy: 1.0)
        }

        if flippedVertically {
            transform.translateX(by: 0.0, yBy: 24.0)
            transform.scaleX(by: 1.0, yBy: -1.0)
        }

        transform.concat()

        let topBody = newStrokePath(lineWidth: 2.0)
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

        let midBar = newStrokePath(lineWidth: 2.0)
        midBar.move(to: NSPoint(x: 6.0, y: 8.0))
        midBar.line(to: NSPoint(x: 18.0, y: 8.0))
        midBar.stroke()

        let rightOutlet = newStrokePath(lineWidth: 2.0)
        rightOutlet.appendArc(withCenter: NSPoint(x: 16.5, y: 19.5),
                              radius: 2.5,
                              startAngle: -53.0,
                              endAngle: 179.0,
                              clockwise: false)
        rightOutlet.line(to: NSPoint(x: 14.0, y: 12.0))
        rightOutlet.stroke()

        let leftOutlet = newStrokePath(lineWidth: 2.0)
        leftOutlet.appendArc(withCenter: NSPoint(x: 8.0, y: 17.0),
                             radius: 2.0,
                             startAngle: -134.5,
                             endAngle: 0.0,
                             clockwise: true)
        leftOutlet.line(to: NSPoint(x: 10.0, y: 12.0))
        leftOutlet.stroke()

        NSGraphicsContext.restoreGraphicsState()
    }
}
