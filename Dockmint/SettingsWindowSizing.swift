import Foundation
import CoreGraphics

enum SettingsWindowSizing {
    static func onboardingFrameHeight(contentHeight: CGFloat,
                                      windowChromeHeight: CGFloat,
                                      maximumFrameHeight: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        min(contentHeight + windowChromeHeight, maximumFrameHeight)
    }

    static func onboardingFrame(currentFrame: CGRect,
                                targetHeight: CGFloat,
                                visibleFrame: CGRect) -> CGRect {
        let proposedFrame = CGRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetHeight,
            width: currentFrame.width,
            height: targetHeight
        )
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - proposedFrame.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - proposedFrame.height)
        return CGRect(
            x: min(max(proposedFrame.minX, visibleFrame.minX), maximumX),
            y: min(max(proposedFrame.minY, visibleFrame.minY), maximumY),
            width: proposedFrame.width,
            height: proposedFrame.height
        )
    }
}
