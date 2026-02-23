import AppKit

enum FrontmostAppTracker {
    static func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

