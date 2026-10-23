import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum SwipeDirection { case left, right, up, down }

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onSwipe: ((SwipeDirection) -> Void)?

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var fired = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began {
            accumulatedX = 0
            accumulatedY = 0
            fired = false
        }
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        accumulatedX += event.scrollingDeltaX * sign
        accumulatedY += event.scrollingDeltaY * sign

        if !fired {
            if abs(accumulatedX) > 50, abs(accumulatedX) > abs(accumulatedY) {
                fired = true
                onSwipe?(accumulatedX > 0 ? .right : .left)
            } else if abs(accumulatedY) > 40, abs(accumulatedY) > abs(accumulatedX) {
                fired = true
                onSwipe?(accumulatedY > 0 ? .down : .up)
            }
        }

        if event.phase == .ended || event.phase == .cancelled {
            accumulatedX = 0
            accumulatedY = 0
            fired = false
        }
        super.scrollWheel(with: event)
    }
}
