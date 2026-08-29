import Foundation

// Commande depuis Align/Align :
// env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -o /tmp/preview-mirror-harness Align/UI/PreviewMirrorTransform.swift Tests/PreviewMirrorHarness.swift && /tmp/preview-mirror-harness

@main
private enum PreviewMirrorHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let anatomicalLeft = CGPoint(x: 0.20, y: 0.35)
        let displayed = PreviewMirrorTransform.mirroredNormalizedPoint(anatomicalLeft)
        expect(abs(displayed.x - 0.80) < 0.000_001, "le miroir doit inverser x une seule fois")
        expect(displayed.y == anatomicalLeft.y, "le miroir ne doit pas inverser la verticale")
        let restored = PreviewMirrorTransform.mirroredNormalizedPoint(displayed)
        expect(
            abs(restored.x - anatomicalLeft.x) < 0.000_001
                && abs(restored.y - anatomicalLeft.y) < 0.000_001,
            "deux miroirs doivent revenir au point anatomique initial"
        )

        let width: CGFloat = 760
        let transformed = CGPoint(x: 152, y: 200).applying(
            PreviewMirrorTransform.layerTransform(width: width)
        )
        expect(abs(transformed.x - 608) < 0.000_001, "la couche doit être réfléchie autour de sa largeur")
        expect(transformed.y == 200, "la transformation de couche doit préserver y")

        print("PreviewMirrorHarness: OK")
    }
}
