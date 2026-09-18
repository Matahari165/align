@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    let overlay: PoseOverlay
    let diagnosticsEnabled: Bool
    let upperBodyDevelopmentOptions: UpperBodyDevelopmentOptions
    let isPreviewEnabled: Bool

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.update(
            overlay: overlay,
            diagnosticsEnabled: diagnosticsEnabled,
            upperBodyDevelopmentOptions: upperBodyDevelopmentOptions,
            isPreviewEnabled: isPreviewEnabled
        )
    }
}

final class CameraPreviewNSView: NSView {
    private let mirroredContentLayer = CALayer()
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let jointLayer = CALayer()
    private let faceShapeLayer = CAShapeLayer()
    private let bodyShapeLayer = CAShapeLayer()
    private let silhouetteShapeLayer = CAShapeLayer()
    private let blazePoseShapeLayer = CAShapeLayer()
    private let upperBodyHeadShapeLayer = CAShapeLayer()
    private let upperBodyHeadLimitedShapeLayer = CAShapeLayer()
    private let upperBodyShoulderShapeLayer = CAShapeLayer()
    private let upperBodyShoulderLimitedShapeLayer = CAShapeLayer()
    private let upperBodyTorsoShapeLayer = CAShapeLayer()
    private let upperBodyTorsoLimitedShapeLayer = CAShapeLayer()
    private let upperBodyDerivedShapeLayer = CAShapeLayer()
    private let upperBodyROIShapeLayer = CAShapeLayer()
    private var blazePoseLabelLayers: [CATextLayer] = []
    private var lastRenderKey: RenderKey?

    private struct RenderKey: Equatable {
        let overlay: PoseOverlay
        let diagnosticsEnabled: Bool
        let upperBodyDevelopmentOptions: UpperBodyDevelopmentOptions
        let size: CGSize
        let backingScaleFactor: CGFloat
    }

    init(session: AVCaptureSession) {
        let alignNavy = NSColor(
            calibratedRed: 0.025,
            green: 0.075,
            blue: 0.105,
            alpha: 1
        )
        let alignTeal = NSColor(
            calibratedRed: 0.145,
            green: 0.805,
            blue: 0.825,
            alpha: 1
        )
        let alignAqua = NSColor(
            calibratedRed: 0.680,
            green: 0.940,
            blue: 0.920,
            alpha: 1
        )
        let alignAmber = NSColor(
            calibratedRed: 0.980,
            green: 0.690,
            blue: 0.350,
            alpha: 1
        )
        let alignQuiet = NSColor(
            calibratedRed: 0.580,
            green: 0.710,
            blue: 0.720,
            alpha: 1
        )
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = alignNavy.cgColor

        previewLayer.videoGravity = .resizeAspectFill
        configureUnmirroredPreviewConnection()
        mirroredContentLayer.anchorPoint = .zero
        jointLayer.masksToBounds = true
        faceShapeLayer.fillColor = NSColor.clear.cgColor
        faceShapeLayer.strokeColor = alignAqua.cgColor
        faceShapeLayer.lineWidth = 1.5
        faceShapeLayer.lineJoin = .round
        faceShapeLayer.lineCap = .round
        bodyShapeLayer.fillColor = alignTeal.withAlphaComponent(0.88).cgColor
        bodyShapeLayer.strokeColor = alignAqua.withAlphaComponent(0.84).cgColor
        bodyShapeLayer.lineWidth = 1
        silhouetteShapeLayer.fillColor = NSColor.clear.cgColor
        silhouetteShapeLayer.strokeColor = alignAmber.cgColor
        silhouetteShapeLayer.lineWidth = 2
        silhouetteShapeLayer.lineDashPattern = [6, 4]
        silhouetteShapeLayer.lineJoin = .round
        silhouetteShapeLayer.lineCap = .round
        blazePoseShapeLayer.fillColor = alignTeal.cgColor
        blazePoseShapeLayer.strokeColor = alignTeal.cgColor
        blazePoseShapeLayer.lineWidth = 3
        blazePoseShapeLayer.lineCap = .round
        configureDevelopmentLayer(upperBodyHeadShapeLayer, color: alignAqua, lineWidth: 2)
        configureLimitedLayer(upperBodyHeadLimitedShapeLayer, color: alignAqua)
        configureDevelopmentLayer(upperBodyShoulderShapeLayer, color: alignTeal, lineWidth: 2)
        configureLimitedLayer(upperBodyShoulderLimitedShapeLayer, color: alignTeal)
        configureDevelopmentLayer(upperBodyTorsoShapeLayer, color: alignAqua, lineWidth: 1.5)
        configureLimitedLayer(upperBodyTorsoLimitedShapeLayer, color: alignAqua)
        configureDevelopmentLayer(upperBodyDerivedShapeLayer, color: alignAmber, lineWidth: 2)
        upperBodyDerivedShapeLayer.lineDashPattern = [6, 4]
        configureDevelopmentLayer(upperBodyROIShapeLayer, color: alignQuiet, lineWidth: 1)
        upperBodyROIShapeLayer.fillColor = NSColor.clear.cgColor
        upperBodyROIShapeLayer.lineDashPattern = [2, 3]
        jointLayer.addSublayer(faceShapeLayer)
        jointLayer.addSublayer(bodyShapeLayer)
        jointLayer.addSublayer(silhouetteShapeLayer)
        jointLayer.addSublayer(blazePoseShapeLayer)
        jointLayer.addSublayer(upperBodyHeadShapeLayer)
        jointLayer.addSublayer(upperBodyHeadLimitedShapeLayer)
        jointLayer.addSublayer(upperBodyShoulderShapeLayer)
        jointLayer.addSublayer(upperBodyShoulderLimitedShapeLayer)
        jointLayer.addSublayer(upperBodyTorsoShapeLayer)
        jointLayer.addSublayer(upperBodyTorsoLimitedShapeLayer)
        jointLayer.addSublayer(upperBodyDerivedShapeLayer)
        jointLayer.addSublayer(upperBodyROIShapeLayer)
        mirroredContentLayer.addSublayer(previewLayer)
        mirroredContentLayer.addSublayer(jointLayer)
        layer?.addSublayer(mirroredContentLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        mirroredContentLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        mirroredContentLayer.position = .zero
        previewLayer.frame = mirroredContentLayer.bounds
        jointLayer.frame = mirroredContentLayer.bounds
        faceShapeLayer.frame = mirroredContentLayer.bounds
        bodyShapeLayer.frame = mirroredContentLayer.bounds
        silhouetteShapeLayer.frame = mirroredContentLayer.bounds
        blazePoseShapeLayer.frame = mirroredContentLayer.bounds
        upperBodyHeadShapeLayer.frame = mirroredContentLayer.bounds
        upperBodyHeadLimitedShapeLayer.frame = mirroredContentLayer.bounds
        upperBodyShoulderShapeLayer.frame = mirroredContentLayer.bounds
        upperBodyShoulderLimitedShapeLayer.frame = mirroredContentLayer.bounds
        upperBodyTorsoShapeLayer.frame = mirroredContentLayer.bounds
        upperBodyTorsoLimitedShapeLayer.frame = mirroredContentLayer.bounds
        upperBodyDerivedShapeLayer.frame = mirroredContentLayer.bounds
        upperBodyROIShapeLayer.frame = mirroredContentLayer.bounds
        mirroredContentLayer.setAffineTransform(
            PreviewMirrorTransform.layerTransform(width: bounds.width)
        )
        configureUnmirroredPreviewConnection()
    }

    func update(
        overlay: PoseOverlay,
        diagnosticsEnabled: Bool,
        upperBodyDevelopmentOptions: UpperBodyDevelopmentOptions,
        isPreviewEnabled: Bool
    ) {
        // The preview connection may be created only after the capture input is
        // configured. Reassert the single-mirror contract on SwiftUI updates.
        configureUnmirroredPreviewConnection()
        previewLayer.connection?.isEnabled = isPreviewEnabled

        let renderedOverlay = PoseOverlayRenderSelection.select(
            overlay,
            diagnosticsEnabled: diagnosticsEnabled
        )
        let renderKey = RenderKey(
            overlay: renderedOverlay,
            diagnosticsEnabled: diagnosticsEnabled,
            upperBodyDevelopmentOptions: upperBodyDevelopmentOptions,
            size: bounds.size,
            backingScaleFactor: window?.backingScaleFactor ?? 2
        )
        guard lastRenderKey != renderKey else { return }
        lastRenderKey = renderKey

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let facePath = CGMutablePath()
        for polyline in renderedOverlay.polylines where polyline.source == .face {
            let positions = polyline.locations.map { layerPosition(for: $0) }
            guard let first = positions.first else { continue }
            facePath.move(to: first)
            positions.dropFirst().forEach { facePath.addLine(to: $0) }
            if polyline.isClosed { facePath.closeSubpath() }
        }
        faceShapeLayer.path = facePath

        let bodyPath = CGMutablePath()
        for point in renderedOverlay.points where point.source == .body {
            let position = layerPosition(for: point.location)
            bodyPath.addEllipse(in: CGRect(
                x: position.x - 3,
                y: position.y - 3,
                width: 6,
                height: 6
            ))
        }
        bodyShapeLayer.path = bodyPath

        let silhouettePath = CGMutablePath()
        for polyline in renderedOverlay.polylines where polyline.source == .silhouette {
            let positions = polyline.locations.map { layerPosition(for: $0) }
            guard let first = positions.first else { continue }
            silhouettePath.move(to: first)
            positions.dropFirst().forEach { silhouettePath.addLine(to: $0) }
        }
        silhouetteShapeLayer.path = silhouettePath

        let blazePosePath = CGMutablePath()
        for polyline in renderedOverlay.polylines where
                polyline.source == .blazePose ||
                (!diagnosticsEnabled && polyline.source == .upperBodyShoulders) {
            let positions = polyline.locations.map { layerPosition(for: $0) }
            guard let first = positions.first else { continue }
            blazePosePath.move(to: first)
            positions.dropFirst().forEach { blazePosePath.addLine(to: $0) }
        }
        for point in renderedOverlay.points where
                point.source == .blazePose ||
                (!diagnosticsEnabled && point.source == .upperBodyShoulders) {
            let position = layerPosition(for: point.location)
            let radius: CGFloat = 6
            blazePosePath.addEllipse(in: CGRect(
                x: position.x - radius,
                y: position.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        blazePoseShapeLayer.path = blazePosePath
        upperBodyHeadShapeLayer.path = developmentPath(
            overlay: renderedOverlay,
            source: .upperBodyHead,
            limitedPoints: false
        )
        upperBodyHeadLimitedShapeLayer.path = developmentPath(
            overlay: renderedOverlay,
            source: .upperBodyHead,
            limitedPoints: true
        )
        upperBodyShoulderShapeLayer.path = developmentPath(
            overlay: renderedOverlay,
            source: .upperBodyShoulders,
            limitedPoints: false
        )
        upperBodyShoulderLimitedShapeLayer.path = developmentPath(
            overlay: renderedOverlay,
            source: .upperBodyShoulders,
            limitedPoints: true
        )
        upperBodyTorsoShapeLayer.path = developmentPath(
            overlay: renderedOverlay,
            source: .upperBodyTorso,
            limitedPoints: false
        )
        upperBodyTorsoLimitedShapeLayer.path = developmentPath(
            overlay: renderedOverlay,
            source: .upperBodyTorso,
            limitedPoints: true
        )
        upperBodyDerivedShapeLayer.path = developmentPath(
            overlay: renderedOverlay,
            source: .upperBodyDerived,
            limitedPoints: false
        )
        upperBodyROIShapeLayer.path = developmentPath(
            overlay: renderedOverlay,
            source: .upperBodyROI,
            limitedPoints: false
        )
        updateBlazePoseLabels(
            for: diagnosticsEnabled && upperBodyDevelopmentOptions.showsValues
                ? renderedOverlay
                : .empty
        )

        CATransaction.commit()
    }

    private func configureDevelopmentLayer(
        _ layer: CAShapeLayer,
        color: NSColor,
        lineWidth: CGFloat
    ) {
        layer.fillColor = color.cgColor
        layer.strokeColor = color.cgColor
        layer.lineWidth = lineWidth
        layer.lineCap = .round
        layer.lineJoin = .round
    }

    private func configureLimitedLayer(_ layer: CAShapeLayer, color: NSColor) {
        configureDevelopmentLayer(layer, color: color, lineWidth: 2)
        layer.fillColor = NSColor.clear.cgColor
    }

    private func developmentPath(
        overlay: PoseOverlay,
        source: PosePointSource,
        limitedPoints: Bool
    ) -> CGPath {
        let path = CGMutablePath()
        if !limitedPoints {
            for polyline in overlay.polylines where polyline.source == source {
                let positions = polyline.locations.map { layerPosition(for: $0) }
                guard let first = positions.first else { continue }
                path.move(to: first)
                positions.dropFirst().forEach { path.addLine(to: $0) }
                if polyline.isClosed { path.closeSubpath() }
            }
        }
        for point in overlay.points where point.source == source && point.isLimited == limitedPoints {
            let position = layerPosition(for: point.location)
            let radius: CGFloat = 3
            path.addEllipse(in: CGRect(
                x: position.x - radius,
                y: position.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        return path
    }

    private func updateBlazePoseLabels(for overlay: PoseOverlay) {
        blazePoseLabelLayers.forEach { $0.removeFromSuperlayer() }
        blazePoseLabelLayers.removeAll(keepingCapacity: true)
        for point in overlay.points where point.source == .blazePose ||
                point.source == .upperBodyShoulders ||
                point.source == .upperBodyHead ||
                point.source == .upperBodyTorso {
            let position = layerPosition(for: point.location)
            let label = CATextLayer()
            label.string = point.name
            label.fontSize = point.name == "CENTRE ESTIMÉ" ? 10 : 13
            label.font = NSFont.systemFont(ofSize: label.fontSize, weight: .bold)
            label.foregroundColor = NSColor(
                calibratedRed: 0.680,
                green: 0.940,
                blue: 0.920,
                alpha: 1
            ).cgColor
            label.backgroundColor = NSColor(
                calibratedRed: 0.025,
                green: 0.075,
                blue: 0.105,
                alpha: 0.86
            ).cgColor
            label.alignmentMode = .center
            label.cornerRadius = 4
            label.contentsScale = window?.backingScaleFactor ?? 2
            let width: CGFloat = point.name == "CENTRE ESTIMÉ" ? 100 : 92
            label.frame = CGRect(x: position.x - width / 2, y: position.y + 8, width: width, height: 18)
            // Le contenu caméra est miroir ; cette contre-transformation garde
            // les lettres lisibles tout en conservant leur position anatomique.
            label.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            jointLayer.addSublayer(label)
            blazePoseLabelLayers.append(label)
        }
    }

    private func layerPosition(for canonicalPoint: CGPoint) -> CGPoint {
        let devicePoint = VisionCoordinateMapper.previewDevicePoint(fromPoseOverlayPoint: canonicalPoint)
        return previewLayer.layerPointConverted(fromCaptureDevicePoint: devicePoint)
    }

    /// Keep the capture/preview coordinate system anatomical and unmirrored.
    /// The containing layer mirrors the video and every overlay together once.
    private func configureUnmirroredPreviewConnection() {
        guard let connection = previewLayer.connection else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }
    }
}
