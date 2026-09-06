import AVFoundation
import SwiftUI
import UIKit

/// The live camera image, as a SwiftUI view.
struct CameraPreview: UIViewRepresentable {

    let session: CameraSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.layer.addSublayer(session.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        session.previewLayer.frame = uiView.bounds
    }

    final class PreviewView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.forEach { $0.frame = bounds }
        }
    }
}

/// Whether this process can possibly have a camera. Previews, unit tests and
/// the simulator cannot, and the capture screens offer a sample there so the
/// rest of the flow stays walkable.
enum CameraEnvironment {
    static var isSimulated: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}

/// A placeholder still for environments without a camera: a card-shaped
/// block of colour, encoded like a real capture would be.
enum SampleCapture {

    static func jpeg(label: String, tint: UIColor) -> Data {
        let size = CGSize(width: 1200, height: 760)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            tint.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 64, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            (label as NSString).draw(at: CGPoint(x: 60, y: 60), withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    /// A passport zone that verifies, for a fictional person of a real
    /// nationality, so the review screen has something true to show.
    static func passportZone(nationality: String = "USA") -> String {
        let number = "S1L4SAMPL"
        var line2 = number + (MRZParser.checkDigit(number) ?? "0") + nationality
        line2 += "900101" + (MRZParser.checkDigit("900101") ?? "0") + "F"
        line2 += "330101" + (MRZParser.checkDigit("330101") ?? "0")
        line2 += String(repeating: "<", count: 14) + "<"
        let start = line2.startIndex
        let composite = String(line2[start..<line2.index(start, offsetBy: 10)])
            + String(line2[line2.index(start, offsetBy: 13)..<line2.index(start, offsetBy: 20)])
            + String(line2[line2.index(start, offsetBy: 21)..<line2.index(start, offsetBy: 43)])
        line2 += MRZParser.checkDigit(composite) ?? "0"
        let line1 = ("P<" + nationality + "SAMPLE<<SILA").padding(toLength: 44, withPad: "<", startingAt: 0)
        return line1 + "\n" + line2
    }
}
