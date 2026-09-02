import Cocoa

enum DockHitTest {
    enum PointKind: Equatable {
        case appDockIcon(String)
        case folderDockItem(URL)
        case dockBackground
        case outsideDock
    }

    static func bundleIdentifierAtPoint(_ point: CGPoint) -> String? {
        if case let .appDockIcon(bundle) = pointKind(at: point) {
            return bundle
        }
        return nil
    }

    static func folderURLAtPoint(_ point: CGPoint) -> URL? {
        if case let .folderDockItem(url) = pointKind(at: point) {
            return url
        }
        return nil
    }

    static func classifyDockItem(subrole: String?, url: URL?) -> PointKind? {
        switch subrole {
        case "AXFolderDockItem":
            guard let url, url.isFileURL else { return nil }
            return .folderDockItem(url.standardizedFileURL)
        case "AXApplicationDockItem":
            guard let bundleIdentifier = bundleIdentifier(forApplicationURL: url) else { return nil }
            return .appDockIcon(bundleIdentifier)
        default:
            break
        }

        // Some Dock folder stacks intermittently resolve without the expected folder subrole.
        // If AX still gives us a file URL that is not an app bundle, treat it as a folder item.
        if let url, url.isFileURL, bundleIdentifier(forApplicationURL: url) == nil {
            Logger.debug("Hit test falling back to folder classification for URL: \(url.path) subrole=\(subrole ?? "nil")")
            return .folderDockItem(url.standardizedFileURL)
        }

        return nil
    }

    static func pointKind(at point: CGPoint) -> PointKind {
        guard isNearDockEdge(point) else { return .outsideDock }
        guard let element = element(at: point) else { return .outsideDock }
        guard isInDockProcess(element) else { return .outsideDock }

        if let pointKind = dockItemKind(for: element) {
            return pointKind
        }

        var current: AXUIElement? = parent(of: element)
        while let el = current, isInDockProcess(el) {
            if let pointKind = dockItemKind(for: el) {
                return pointKind
            }
            current = parent(of: el)
        }

        Logger.debug("Hit test resolved Dock background.")
        return .dockBackground
    }

    static func neutralBackgroundPoint(near point: CGPoint,
                                       searchRadius: CGFloat = 120,
                                       step: CGFloat = 12) -> CGPoint? {
        if pointKind(at: point) == .dockBackground {
            return point
        }

        let offsets = stride(from: CGFloat(0), through: searchRadius, by: step).flatMap { distance -> [CGFloat] in
            distance == 0 ? [0] : [distance, -distance]
        }

        // Prefer short cardinal moves first; they are less likely to wander onto a neighboring
        // Dock item than a diagonal grid search when the pressed icon is large.
        for distance in stride(from: step, through: searchRadius, by: step) {
            let candidates = [
                CGPoint(x: point.x, y: point.y - distance),
                CGPoint(x: point.x, y: point.y + distance),
                CGPoint(x: point.x - distance, y: point.y),
                CGPoint(x: point.x + distance, y: point.y)
            ]
            for candidate in candidates where pointKind(at: candidate) == .dockBackground {
                return candidate
            }
        }

        for dy in offsets {
            for dx in offsets {
                if dx == 0, dy == 0 { continue }
                let candidate = CGPoint(x: point.x + dx, y: point.y + dy)
                if pointKind(at: candidate) == .dockBackground {
                    return candidate
                }
            }
        }

        // Final coarse fallback for large Dock magnification / spacing cases.
        for distance in stride(from: searchRadius + step, through: searchRadius + 72, by: 24) {
            let candidates = [
                CGPoint(x: point.x, y: point.y - distance),
                CGPoint(x: point.x - distance, y: point.y),
                CGPoint(x: point.x + distance, y: point.y)
            ]
            for candidate in candidates where pointKind(at: candidate) == .dockBackground {
                return candidate
            }
        }

        return nil
    }

    private static func isNearDockEdge(_ point: CGPoint, threshold: CGFloat = 140) -> Bool {
        // IMPORTANT: `point` is in Quartz global display coordinates (CGEvent.location),
        // where Y is measured from the top of the display (y grows downward).
        // Do not use NSScreen frames here (AppKit uses a flipped Y for screen coordinates).
        guard let bounds = displayBounds(containing: point) else {
            return false
        }

        let distLeft = point.x - bounds.minX
        let distRight = bounds.maxX - point.x
        let distBottom = bounds.maxY - point.y

        // Dock can be positioned on the left, right, or bottom edge.
        return distLeft <= threshold || distRight <= threshold || distBottom <= threshold
    }

    private static func displayBounds(containing point: CGPoint) -> CGRect? {
        var count: UInt32 = 0
        if CGGetActiveDisplayList(0, nil, &count) != .success || count == 0 {
            return nil
        }
        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        if CGGetActiveDisplayList(count, &displays, &count) != .success {
            return nil
        }
        for id in displays {
            let b = CGDisplayBounds(id)
            if b.contains(point) {
                return b
            }
        }
        return nil
    }

    private static func element(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
        guard result == .success else {
            Logger.debug("AXUIElementCopyElementAtPosition failed with \(result.rawValue)")
            return nil
        }
        return element
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard result == .success else { return nil }
        guard let cfValue = value, CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
        return (cfValue as! AXUIElement)
    }

    private static func isInDockProcess(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)
        guard result == .success else {
            Logger.debug("AXUIElementGetPid failed with \(result.rawValue)")
            return false
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            Logger.debug("No running app for pid \(pid)")
            return false
        }
        let inDock = app.bundleIdentifier == "com.apple.dock"
        if !inDock {
            Logger.debug("Element pid \(pid) bundle \(app.bundleIdentifier ?? "nil") is not Dock.")
        }
        return inDock
    }

    private static func dockItemKind(for element: AXUIElement) -> PointKind? {
        let subrole: String? = attribute(element, for: kAXSubroleAttribute)
        let url: URL? = attribute(element, for: kAXURLAttribute)

        if let pointKind = classifyDockItem(subrole: subrole, url: url) {
            switch pointKind {
            case .folderDockItem(let url):
                Logger.debug("Hit test resolved folder URL: \(url.path)")
            case .appDockIcon(let bundle):
                Logger.debug("Hit test resolved bundle: \(bundle)")
            case .dockBackground, .outsideDock:
                break
            }
            return pointKind
        }

        if subrole == "AXApplicationDockItem" {
            let title: String = attribute(element, for: kAXTitleAttribute) ?? ""
            Logger.debug("Hit test unresolved app Dock item title=\(title) url=\(url?.path ?? "nil")")
        }

        return nil
    }

    private static func bundleIdentifier(forApplicationURL url: URL?) -> String? {
        guard let url else { return nil }
        guard let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else {
            Logger.debug("No bundleIdentifier resolved from AXURL: \(url.path)")
            return nil
        }
        Logger.debug("Bundle from AXURL: \(bundleIdentifier)")
        return bundleIdentifier == "com.apple.dock" ? nil : bundleIdentifier
    }

    private static func attribute<T>(_ element: AXUIElement, for key: String) -> T? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success else { return nil }
        return value as? T
    }
}
