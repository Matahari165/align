import CoreGraphics

nonisolated enum PreviewMirrorTransform {
    /// Mirrors the rendered preview around its vertical axis. This transform is
    /// presentation-only: Vision and pose coordinates remain anatomical.
    static func layerTransform(width: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: width, y: 0)
            .scaledBy(x: -1, y: 1)
    }

    static func mirroredNormalizedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: 1 - point.x, y: point.y)
    }
}
