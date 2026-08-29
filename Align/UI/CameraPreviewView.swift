@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    let overlay: PoseOverlay

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.update(overlay: overlay)
    }
}

final class CameraPreviewNSView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let jointLayer = CALayer()
    private let faceShapeLayer = CAShapeLayer()
    private let bodyShapeLayer = CAShapeLayer()
    private let silhouetteShapeLayer = CAShapeLayer()

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        previewLayer.videoGravity = .resizeAspectFill
        configureMirroring()
        jointLayer.masksToBounds = true
        faceShapeLayer.fillColor = NSColor.clear.cgColor
        faceShapeLayer.strokeColor = NSColor.systemCyan.cgColor
        faceShapeLayer.lineWidth = 1.5
        faceShapeLayer.lineJoin = .round
        faceShapeLayer.lineCap = .round
        bodyShapeLayer.fillColor = NSColor.systemGreen.cgColor
        bodyShapeLayer.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        bodyShapeLayer.lineWidth = 1
        silhouetteShapeLayer.fillColor = NSColor.clear.cgColor
        silhouetteShapeLayer.strokeColor = NSColor.systemPink.cgColor
        silhouetteShapeLayer.lineWidth = 2
        silhouetteShapeLayer.lineDashPattern = [6, 4]
        silhouetteShapeLayer.lineJoin = .round
        silhouetteShapeLayer.lineCap = .round
        jointLayer.addSublayer(faceShapeLayer)
        jointLayer.addSublayer(bodyShapeLayer)
        jointLayer.addSublayer(silhouetteShapeLayer)
        layer?.addSublayer(previewLayer)
        layer?.addSublayer(jointLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        jointLayer.frame = bounds
        faceShapeLayer.frame = bounds
        bodyShapeLayer.frame = bounds
        silhouetteShapeLayer.frame = bounds
        configureMirroring()
    }

    func update(overlay: PoseOverlay) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let facePath = CGMutablePath()
        for polyline in overlay.polylines where polyline.source == .face {
            let positions = polyline.locations.map { layerPosition(for: $0) }
            guard let first = positions.first else { continue }
            facePath.move(to: first)
            positions.dropFirst().forEach { facePath.addLine(to: $0) }
            if polyline.isClosed { facePath.closeSubpath() }
        }
        faceShapeLayer.path = facePath

        let bodyPath = CGMutablePath()
        for point in overlay.points where point.source == .body {
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
        for polyline in overlay.polylines where polyline.source == .silhouette {
            let positions = polyline.locations.map { layerPosition(for: $0) }
            guard let first = positions.first else { continue }
            silhouettePath.move(to: first)
            positions.dropFirst().forEach { silhouettePath.addLine(to: $0) }
        }
        silhouetteShapeLayer.path = silhouettePath

        CATransaction.commit()
    }

    private func layerPosition(for canonicalPoint: CGPoint) -> CGPoint {
        let devicePoint = VisionCoordinateMapper.previewDevicePoint(fromPoseOverlayPoint: canonicalPoint)
        return previewLayer.layerPointConverted(fromCaptureDevicePoint: devicePoint)
    }

    private func configureMirroring() {
        guard let connection = previewLayer.connection else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
    }
}
