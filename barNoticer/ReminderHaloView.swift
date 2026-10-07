import AppKit
import CoreImage

/// A single softly lit contour. The window includes transparent drawing space so
/// changing the user's outset changes the contour, rather than clipping its glow.
@MainActor
final class ReminderHaloView: NSView {
    static let drawingInset: CGFloat = 64
    let isPreview: Bool
    private let cornerRadius: CGFloat

    private let effectLayer = CALayer()
    private let bloomLayer = CALayer()
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let edgeLayer = CAGradientLayer()
    private let edgeMask = CAShapeLayer()
    private let boundaryLayer = CAShapeLayer()

    init(frame: NSRect, isPreview: Bool, cornerRadius: CGFloat = 24) {
        self.cornerRadius = cornerRadius
        self.isPreview = isPreview
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(effectLayer)
        effectLayer.addSublayer(bloomLayer)
        effectLayer.addSublayer(edgeLayer)
        effectLayer.addSublayer(boundaryLayer)
        for shape in [edgeMask, boundaryLayer] {
            shape.fillColor = NSColor.clear.cgColor
        }
        edgeMask.strokeColor = NSColor.white.cgColor
        edgeLayer.mask = edgeMask
        edgeLayer.startPoint = CGPoint(x: 0, y: 0.2)
        edgeLayer.endPoint = CGPoint(x: 1, y: 0.8)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func updateAppearance() {
        let workspace = NSWorkspace.shared
        let solid = workspace.accessibilityDisplayShouldReduceTransparency
        let contrast = workspace.accessibilityDisplayShouldIncreaseContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // In preview mode, draw a readable static boundary instead of a pulse.
        boundaryLayer.isHidden = !isPreview
        boundaryLayer.strokeColor = NSColor.white.withAlphaComponent(contrast ? 1 : 0.85).cgColor
        boundaryLayer.lineWidth = contrast ? 2 : 1.5
        boundaryLayer.shadowColor = NSColor.black.cgColor
        boundaryLayer.shadowOpacity = 0.8
        boundaryLayer.shadowRadius = 2
        boundaryLayer.shadowOffset = .zero
        bloomLayer.isHidden = isPreview || solid
        edgeLayer.isHidden = isPreview
        edgeLayer.colors = [
            NSColor(calibratedRed: 0.64, green: 0.85, blue: 1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.88, green: 0.88, blue: 1, alpha: 0.95).cgColor,
            NSColor(calibratedRed: 0.72, green: 0.62, blue: 1, alpha: 0.75).cgColor
        ]
        edgeMask.lineWidth = contrast ? 2 : 1.25
        edgeLayer.opacity = contrast || solid ? 1 : 0.95
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectLayer.frame = bounds
        let contentBounds = CGRect(origin: .zero, size: bounds.size)
        let contour = contentBounds.insetBy(dx: Self.drawingInset, dy: Self.drawingInset)
        let radius = max(0, min(cornerRadius, min(contour.width, contour.height) / 2))
        let path = CGPath(roundedRect: contour, cornerWidth: radius, cornerHeight: radius, transform: nil)
        for shape in [edgeMask, boundaryLayer] {
            shape.frame = contentBounds
            shape.path = path
        }
        edgeLayer.frame = contentBounds
        bloomLayer.frame = contentBounds
        if !bloomLayer.isHidden {
            bloomLayer.contents = makeBloom(in: contentBounds, path: path)
        }
        CATransaction.commit()
    }

    /// Render during layout, not per animation frame. A blurred
    /// gradient yields an actual halo on both light and dark desktop backgrounds.
    private func makeBloom(in bounds: CGRect, path: CGPath) -> CGImage? {
        let scale: CGFloat = window?.backingScaleFactor ?? 2
        guard let context = CGContext(data: nil, width: Int(bounds.width * scale),
            height: Int(bounds.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.addPath(path)
        context.setLineWidth(18)
        context.replacePathWithStrokedPath()
        context.clip()
        let colors = [
            NSColor(calibratedRed: 0.35, green: 0.68, blue: 1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.6, green: 0.6, blue: 1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.7, green: 0.45, blue: 1, alpha: 1).cgColor
        ]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray, locations: [0, 0.5, 1]) else { return nil }
        context.drawLinearGradient(gradient, start: .zero,
            end: CGPoint(x: bounds.width, y: bounds.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        guard let bitmap = context.makeImage() else { return nil }
        let original = CIImage(cgImage: bitmap)
        // A bright inner bloom holds the edge; a broad outer bloom diffuses into the desktop.
        // The 64 pt inset covers the outer blur's tail without a hard rectangular cutoff.
        let core = original.applyingGaussianBlur(sigma: 5 * scale)
        let atmosphere = original.applyingGaussianBlur(sigma: 16 * scale)
        return Self.imageContext.createCGImage(core.composited(over: atmosphere), from: original.extent)
    }

    func startPulse() {
        guard !isPreview else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectLayer.opacity = 0
        CATransaction.commit()
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 1, 1, 0]
        pulse.keyTimes = [0, 0.2, 0.7, 1]
        pulse.duration = ReminderPresentationTiming.flashDuration
        pulse.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeIn)
        ]
        effectLayer.add(pulse, forKey: "reminderHalo")
    }
}
