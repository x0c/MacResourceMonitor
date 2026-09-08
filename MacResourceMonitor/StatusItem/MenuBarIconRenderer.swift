import AppKit
import CoreText

enum NetworkSpeedEmphasis: Equatable {
    case balanced
    case upload
    case download

    static func resolve(
        uploadBytesPerSecond: Double?,
        downloadBytesPerSecond: Double?
    ) -> Self {
        guard let uploadBytesPerSecond, let downloadBytesPerSecond else {
            return .balanced
        }
        if uploadBytesPerSecond > downloadBytesPerSecond {
            return .upload
        }
        if downloadBytesPerSecond > uploadBytesPerSecond {
            return .download
        }
        return .balanced
    }
}

@MainActor
enum MenuBarIconRenderer {
    static let pointSize: CGFloat = 19

    private static let ringWidth: CGFloat = 2
    private static let trackOpacity: CGFloat = 0.3
    private static let outerRadius: CGFloat = 7.5
    private static let innerRadius: CGFloat = 4.35
    private static let menuBarHeight: CGFloat = 22
    private static let visualBlockHeight: CGFloat = 17
    private static let visualBlockInset = (menuBarHeight - visualBlockHeight) / 2
    private static let readingGap: CGFloat = 2
    private static let unitColumnGap: CGFloat = 2
    private static let baseSpeedFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
    private static let prominentSpeedFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    private static let secondarySpeedFont = NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .regular)
    private static let arrowColumnWidth = textWidth("↑", font: baseSpeedFont)
    /// 紧凑上限：数字最多三位；单位取三档里最宽者，避免日常两位数左侧大空白，同时刷新外框仍固定。
    private static let stableRateColumnWidth = textWidth("999", font: prominentSpeedFont)
    private static let stableUnitColumnWidth = max(
        textWidth("KB/s", font: prominentSpeedFont),
        textWidth("MB/s", font: prominentSpeedFont),
        textWidth("GB/s", font: prominentSpeedFont)
    )
    static let networkWidth = stableRateColumnWidth + readingGap + stableUnitColumnWidth + unitColumnGap + arrowColumnWidth

    static func image(
        cpuPercent: Double,
        memoryPercent: Double
    ) -> NSImage {
        // 必须先栅格成位图再标模板：NSCustomImageRep 的 drawingHandler
        // 会在状态项上直接落黑笔，绕过系统按 alpha 着色，深色菜单栏里就一直发黑。
        makeTemplateImage(size: NSSize(width: pointSize, height: menuBarHeight)) { context, rect in
            let center = CGPoint(x: pointSize / 2, y: rect.midY)
            drawRing(
                in: context,
                center: center,
                radius: outerRadius,
                progress: cpuPercent
            )
            drawRing(
                in: context,
                center: center,
                radius: innerRadius,
                progress: memoryPercent
            )
        }
    }

    static func networkImage(
        uploadBytesPerSecond: Double?,
        downloadBytesPerSecond: Double?
    ) -> NSImage {
        let networkLayout = makeNetworkLayout(
            uploadBytesPerSecond: uploadBytesPerSecond,
            downloadBytesPerSecond: downloadBytesPerSecond
        )
        return makeTemplateImage(size: NSSize(width: networkWidth, height: menuBarHeight)) { context, _ in
            drawNetworkSpeed(
                layout: networkLayout,
                originX: 0,
                using: context
            )
        }
    }

    /// 动态菜单栏图：纯黑 + alpha 画进位图，交给系统按菜单栏明暗着色。
    ///
    /// `NSGraphicsContext(bitmapImageRep:)` 的坐标系已经按 `rep.size`（点）映射到像素，
    /// **禁止再 `scaleBy(backingScaleFactor)`**——否则图案被放大裁切，圆环会变成 Wi‑Fi 弧。
    private static func makeTemplateImage(
        size: NSSize,
        draw: (CGContext, NSRect) -> Void
    ) -> NSImage {
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
        let pixelsWide = max(1, Int((size.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((size.height * scale).rounded(.up)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            let fallback = NSImage(size: size)
            fallback.isTemplate = true
            return fallback
        }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
            let fallback = NSImage(size: size)
            fallback.isTemplate = true
            return fallback
        }
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(true)
        context.clear(CGRect(origin: .zero, size: size))
        draw(context, NSRect(origin: .zero, size: size))

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    private static func makeNetworkLayout(
        uploadBytesPerSecond: Double?,
        downloadBytesPerSecond: Double?
    ) -> NetworkLayout {
        let reading = NetworkRateFormatter.pair(
            uploadBytesPerSecond: uploadBytesPerSecond,
            downloadBytesPerSecond: downloadBytesPerSecond
        )
        let emphasis = NetworkSpeedEmphasis.resolve(
            uploadBytesPerSecond: uploadBytesPerSecond,
            downloadBytesPerSecond: downloadBytesPerSecond
        )
        let topLine = makeTextLine(
            rate: reading.upload,
            unit: reading.unit ?? "",
            arrow: "↑",
            readingFont: speedFont(for: .upload, emphasis: emphasis)
        )
        let bottomLine = makeTextLine(
            rate: reading.download,
            unit: reading.unit ?? "",
            arrow: "↓",
            readingFont: speedFont(for: .download, emphasis: emphasis)
        )
        return NetworkLayout(
            topLine: topLine,
            bottomLine: bottomLine,
            rateColumnWidth: stableRateColumnWidth,
            unitColumnWidth: stableUnitColumnWidth,
            arrowColumnWidth: arrowColumnWidth
        )
    }

    private static func drawNetworkSpeed(
        layout: NetworkLayout,
        originX: CGFloat,
        using context: CGContext
    ) {
        let arrowX = originX + layout.rateColumnWidth + readingGap + layout.unitColumnWidth + unitColumnGap
        let unitRightX = arrowX - unitColumnGap
        let baselines = edgeAnchoredBaselines(topLine: layout.topLine, bottomLine: layout.bottomLine, context: context)
        let topRateRightX = leftEdge(of: layout.topLine.unit, rightAlignedAt: unitRightX, in: context) - readingGap
        let bottomRateRightX = leftEdge(of: layout.bottomLine.unit, rightAlignedAt: unitRightX, in: context) - readingGap

        draw(layout.topLine.rate, at: topRateRightX, baselineY: baselines.top, alignment: .right, in: context)
        draw(layout.bottomLine.rate, at: bottomRateRightX, baselineY: baselines.bottom, alignment: .right, in: context)
        draw(layout.topLine.unit, at: unitRightX, baselineY: baselines.top, alignment: .right, in: context)
        draw(layout.bottomLine.unit, at: unitRightX, baselineY: baselines.bottom, alignment: .right, in: context)
        draw(layout.topLine.arrow, at: arrowX + layout.arrowColumnWidth, baselineY: baselines.top, alignment: .right, in: context)
        draw(layout.bottomLine.arrow, at: arrowX + layout.arrowColumnWidth, baselineY: baselines.bottom, alignment: .right, in: context)
    }

    private static func makeTextLine(
        rate: String,
        unit: String,
        arrow: String,
        readingFont: NSFont
    ) -> NetworkTextLine {
        let readingAttributes: [NSAttributedString.Key: Any] = [
            .font: readingFont,
            .foregroundColor: NSColor.black
        ]
        let arrowAttributes: [NSAttributedString.Key: Any] = [
            .font: baseSpeedFont,
            .foregroundColor: NSColor.black
        ]
        return NetworkTextLine(
            rate: CTLineCreateWithAttributedString(NSAttributedString(string: rate, attributes: readingAttributes)),
            unit: CTLineCreateWithAttributedString(NSAttributedString(string: unit, attributes: readingAttributes)),
            arrow: CTLineCreateWithAttributedString(NSAttributedString(string: arrow, attributes: arrowAttributes))
        )
    }

    private static func speedFont(
        for direction: NetworkSpeedEmphasis,
        emphasis: NetworkSpeedEmphasis
    ) -> NSFont {
        guard emphasis != .balanced else { return baseSpeedFont }
        return direction == emphasis ? prominentSpeedFont : secondarySpeedFont
    }

    private static func edgeAnchoredBaselines(
        topLine: NetworkTextLine,
        bottomLine: NetworkTextLine,
        context: CGContext
    ) -> (top: CGFloat, bottom: CGFloat) {
        let topBounds = topLine.imageBounds(in: context)
        let bottomBounds = bottomLine.imageBounds(in: context)
        let topBaseline = visualBlockInset + visualBlockHeight - topBounds.maxY
        let bottomBaseline = visualBlockInset - bottomBounds.minY
        return (top: topBaseline, bottom: bottomBaseline)
    }

    private static func draw(
        _ line: CTLine,
        at x: CGFloat,
        baselineY: CGFloat,
        alignment: NSTextAlignment,
        in context: CGContext
    ) {
        let bounds = glyphBounds(of: line, in: context)
        guard !bounds.isNull else { return }
        let originX = alignment == .right ? x - bounds.maxX : x - bounds.minX
        context.textPosition = CGPoint(x: originX, y: baselineY)
        CTLineDraw(line, context)
    }

    private static func leftEdge(
        of line: CTLine,
        rightAlignedAt x: CGFloat,
        in context: CGContext
    ) -> CGFloat {
        let bounds = glyphBounds(of: line, in: context)
        guard !bounds.isNull else { return x }
        return x - bounds.width
    }

    private static func glyphBounds(of line: CTLine, in context: CGContext) -> CGRect {
        let previousTextPosition = context.textPosition
        context.textPosition = .zero
        defer { context.textPosition = previousTextPosition }
        return CTLineGetImageBounds(line, context)
    }

    private struct NetworkLayout {
        let topLine: NetworkTextLine
        let bottomLine: NetworkTextLine
        let rateColumnWidth: CGFloat
        let unitColumnWidth: CGFloat
        let arrowColumnWidth: CGFloat

    }

    private struct NetworkTextLine {
        let rate: CTLine
        let unit: CTLine
        let arrow: CTLine

        func imageBounds(in context: CGContext) -> CGRect {
            [rate, unit, arrow]
                .map { MenuBarIconRenderer.glyphBounds(of: $0, in: context) }
                .reduce(.null) { $0.union($1) }
        }
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func drawRing(
        in context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        progress: Double
    ) {
        let bounds = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )

        context.saveGState()
        defer { context.restoreGState() }

        context.setLineWidth(ringWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        // 模板图只用灰度 0 + alpha；禁止灰 RGB，系统会按 alpha 重新着色。
        context.setStrokeColor(CGColor(gray: 0, alpha: trackOpacity))
        context.strokeEllipse(in: bounds)

        let normalized = min(max(progress, 0), 100) / 100
        guard normalized > 0 else { return }

        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        if normalized >= 1 {
            context.strokeEllipse(in: bounds)
            return
        }

        let startAngle = CGFloat.pi / 2
        let endAngle = startAngle - (CGFloat.pi * 2 * CGFloat(normalized))
        context.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        context.strokePath()
    }
}
