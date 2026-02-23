import Cocoa

enum DockHitTest {
    static func bundleIdentifierAtPoint(_ point: CGPoint) -> String? {
        guard isNearDockEdge(point) else { return nil }
        guard let element = element(at: point) else { return nil }
        guard isInDockProcess(element) else { return nil }

        var current: AXUIElement? = element
        while let el = current, isInDockProcess(el) {
            if let bundle = bundleIdentifier(for: el), bundle != "com.apple.dock" {
                Logger.debug("Hit test resolved bundle: \(bundle)")
                return bundle
            }
            current = parent(of: el)
        }
        Logger.debug("Hit test found no bundle while walking parents.")
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

    private static func bundleIdentifier(for element: AXUIElement) -> String? {
        if let url: URL = attribute(element, for: kAXURLAttribute) {
            if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                Logger.debug("Bundle from AXURL: \(id)")
                return id == "com.apple.dock" ? nil : id
            }
        }

        if let title: String = attribute(element, for: kAXTitleAttribute) {
            if let match = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == title }) {
                if let id = match.bundleIdentifier, id != "com.apple.dock" {
                    Logger.debug("Bundle from title match: \(id)")
                    return id
                }
            }
        }

        Logger.debug("No bundleIdentifier resolved for element.")
        return nil
    }

    private static func attribute<T>(_ element: AXUIElement, for key: String) -> T? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success else { return nil }
        return value as? T
    }
}
