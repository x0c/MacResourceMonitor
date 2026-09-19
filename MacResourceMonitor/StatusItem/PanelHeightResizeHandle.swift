import AppKit

/// Invisible bottom/top edge that tracks a top-anchored height drag.
/// Cursor and tracking follow the overlay recipe: event-tracking loop, no keyboard steal.
@MainActor
final class PanelHeightResizeHandle: NSView {
    var growsDownward = true
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持通过归档创建高度拖边")
    }

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .handle }

    override func accessibilityLabel() -> String? {
        String(localized: "panel.resizeHeight")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        resizeCursor.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startHeight = window.frame.height
        let startY = NSEvent.mouseLocation.y
        var didDrag = false
        while true {
            guard let next = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                break
            }
            switch next.type {
            case .leftMouseDragged:
                let currentY = NSEvent.mouseLocation.y
                let delta = growsDownward ? (startY - currentY) : (currentY - startY)
                didDrag = true
                onDrag(startHeight + delta)
            case .leftMouseUp:
                if didDrag {
                    onEnd()
                }
                return
            default:
                break
            }
        }
        if didDrag {
            onEnd()
        }
    }

    private var resizeCursor: NSCursor {
        let position: NSCursor.FrameResizePosition = growsDownward ? .bottom : .top
        return NSCursor.frameResize(position: position, directions: [.inward, .outward])
    }
}
