import CoreGraphics

enum SettingsLayout {
    static let pagePadding: CGFloat = 20
    static let rowSpacing: CGFloat = 10
    static let tableCellSpacing: CGFloat = 12
    static let actionModifierColumnWidth: CGFloat = 144
    static let actionColumnWidth: CGFloat = 184
    static let actionsContentWidth: CGFloat =
        actionModifierColumnWidth + actionColumnWidth * 3 + tableCellSpacing * 3
    // Reserve room for the scrollbar even when macOS always shows scrollbars.
    static let scrollBarAllowance: CGFloat = 17
    static let onboardingWidth: CGFloat = 540
    static let settingsHeight: CGFloat = 224
    static let initialHeight: CGFloat = 400
    static let minimumHeight: CGFloat = 340

    /// A single content size for every settings tab.
    static var contentSize: CGSize {
        CGSize(
            width: actionsContentWidth + pagePadding * 2 + scrollBarAllowance,
            height: settingsHeight
        )
    }
}

enum OnboardingSetup {
    static func canFinish(accessibilityGranted: Bool, inputMonitoringGranted: Bool) -> Bool {
        accessibilityGranted && inputMonitoringGranted
    }
}

enum SettingsWindowSizing {
    static func limitedSize(_ proposed: CGSize, to maximum: CGSize) -> CGSize {
        CGSize(
            width: min(max(1, proposed.width), max(1, maximum.width)),
            height: min(max(1, proposed.height), max(1, maximum.height))
        )
    }

    static func centeredFrame(size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let limited = limitedSize(size, to: visibleFrame.size)
        return CGRect(
            x: visibleFrame.midX - limited.width / 2,
            y: visibleFrame.midY - limited.height / 2,
            width: limited.width,
            height: limited.height
        )
    }

    static func topLeftAnchoredFrame(currentFrame: CGRect,
                                     targetSize: CGSize,
                                     visibleFrame: CGRect) -> CGRect {
        let limited = limitedSize(targetSize, to: visibleFrame.size)
        let proposed = CGRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - limited.height,
            width: limited.width,
            height: limited.height
        )
        let maximumX = visibleFrame.maxX - proposed.width
        let maximumY = visibleFrame.maxY - proposed.height
        return CGRect(
            x: min(max(proposed.minX, visibleFrame.minX), maximumX),
            y: min(max(proposed.minY, visibleFrame.minY), maximumY),
            width: proposed.width,
            height: proposed.height
        )
    }

    static func framesApproximatelyEqual(_ lhs: CGRect,
                                         _ rhs: CGRect,
                                         tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
