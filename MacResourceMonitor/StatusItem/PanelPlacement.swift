import Foundation

/// 菜单栏浮层只允许锚在真实状态项旁；空矩形不能拿去定位。
nonisolated enum PanelPlacement {
    private enum MenuBarEdge {
        case top
        case bottom
    }

    static func isMenuBarAnchor(_ rect: NSRect, screens: [NSRect]) -> Bool {
        menuBarEdge(for: rect, screens: screens) != nil
    }

    static func maxHeight(
        anchor: NSRect?,
        screens: [NSRect],
        visibleScreens: [NSRect],
        fallbackVisible: NSRect
    ) -> CGFloat {
        let gap: CGFloat = 6
        let margin: CGFloat = 8
        if let anchor,
           let edge = menuBarEdge(for: anchor, screens: screens) {
            let visible = visibleScreen(containing: anchor, screens: screens, visibles: visibleScreens) ?? fallbackVisible
            switch edge {
            case .top:
                return max(0, anchor.minY - gap - (visible.minY + margin))
            case .bottom:
                return max(0, visible.maxY - (anchor.maxY + gap))
            }
        }
        return max(0, fallbackVisible.height - gap - margin)
    }

    static func fittedSize(
        preferredHeight: CGFloat,
        minHeight: CGFloat,
        width: CGFloat,
        anchor: NSRect?,
        screens: [NSRect],
        visibleScreens: [NSRect],
        fallbackVisible: NSRect
    ) -> CGSize {
        let maximum = maxHeight(
            anchor: anchor,
            screens: screens,
            visibleScreens: visibleScreens,
            fallbackVisible: fallbackVisible
        )
        let height = min(max(preferredHeight, minHeight), maximum)
        return CGSize(width: width, height: max(height, 0))
    }

    /// Top menu bar: the far edge is the bottom, so height grows downward.
    static func growsDownward(anchor: NSRect?, screens: [NSRect]) -> Bool {
        guard let anchor, let edge = menuBarEdge(for: anchor, screens: screens) else {
            return true
        }
        return edge == .top
    }

    static func origin(
        anchor: NSRect?,
        size: CGSize,
        screens: [NSRect],
        visibleScreens: [NSRect],
        fallbackVisible: NSRect
    ) -> CGPoint {
        if let anchor,
           let edge = menuBarEdge(for: anchor, screens: screens) {
            let visible = visibleScreen(containing: anchor, screens: screens, visibles: visibleScreens) ?? fallbackVisible
            var origin = CGPoint(x: anchor.midX - size.width / 2, y: 0)
            switch edge {
            case .top:
                origin.y = anchor.minY - size.height - 6
            case .bottom:
                origin.y = anchor.maxY + 6
            }
            origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
            origin.y = min(origin.y, visible.maxY - size.height)
            origin.y = max(origin.y, visible.minY + 8)
            return origin
        }
        return CGPoint(
            x: fallbackVisible.midX - size.width / 2,
            y: fallbackVisible.maxY - size.height - 6
        )
    }

    private static func menuBarEdge(for rect: NSRect, screens: [NSRect]) -> MenuBarEdge? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        guard let screen = screens.first(where: { $0.insetBy(dx: -4, dy: -4).contains(CGPoint(x: rect.midX, y: rect.midY)) }) else {
            return nil
        }
        if rect.midY >= screen.maxY - 48, rect.midY <= screen.maxY + 4 {
            return .top
        }
        if rect.midY <= screen.minY + 48, rect.midY >= screen.minY - 4 {
            return .bottom
        }
        return nil
    }

    private static func visibleScreen(containing rect: NSRect, screens: [NSRect], visibles: [NSRect]) -> NSRect? {
        guard let index = screens.firstIndex(where: {
            $0.insetBy(dx: -4, dy: -4).contains(CGPoint(x: rect.midX, y: rect.midY))
        }), visibles.indices.contains(index) else {
            return nil
        }
        return visibles[index]
    }
}
