import AVFoundation
import DesignSystem
import LaileCore
import SwiftUI
import UIKit

/// Live camera preview (aspect-fill). Mirrors the front camera like a mirror would.
public struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    public init(session: AVCaptureSession) { self.session = session }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) {}

    public final class PreviewView: UIView {
        public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// Draws the tracked skeleton over the preview, highlighting the joints being measured.
public struct SkeletonOverlay: View {
    let frame: PoseFrame?
    let highlight: [Joint]
    let mirrored: Bool
    let angleLabel: String?

    public init(frame: PoseFrame?, highlight: [Joint] = [], mirrored: Bool, angleLabel: String? = nil) {
        self.frame = frame
        self.highlight = highlight
        self.mirrored = mirrored
        self.angleLabel = angleLabel
    }

    public var body: some View {
        Canvas { context, size in
            guard let frame else { return }
            let rect = Self.imageRect(in: size, aspect: frame.imageAspect)
            func point(_ joint: Joint) -> CGPoint? {
                guard let lm = frame.landmark(joint) else { return nil }
                let x = mirrored ? 1 - lm.position.x : lm.position.x
                return CGPoint(x: rect.minX + x * rect.width, y: rect.minY + lm.position.y * rect.height)
            }
            for (a, b) in Joint.bones {
                guard let pa = point(a), let pb = point(b) else { continue }
                let emphasised = highlight.contains(a) && highlight.contains(b)
                var path = Path()
                path.move(to: pa)
                path.addLine(to: pb)
                context.stroke(path, with: .color(emphasised ? Theme.reward : .white.opacity(0.75)),
                               style: StrokeStyle(lineWidth: emphasised ? 7 : 4, lineCap: .round))
            }
            for joint in Joint.allCases {
                guard let p = point(joint) else { continue }
                let r: CGFloat = highlight.contains(joint) ? 8 : 5
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(highlight.contains(joint) ? Theme.reward : Theme.accent))
            }
            if let angleLabel, let vertex = highlight.count == 3 ? point(highlight[1]) : nil {
                let text = Text(angleLabel).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundColor(.white)
                context.draw(text, at: CGPoint(x: vertex.x + 36, y: vertex.y - 24))
            }
        }
        .allowsHitTesting(false)
    }

    /// Where an aspect-filled image of `aspect` (w/h) lands inside `size`.
    static func imageRect(in size: CGSize, aspect: Double) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        let viewAspect = size.width / size.height
        if viewAspect > aspect {
            let h = size.width / aspect
            return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
        } else {
            let w = size.height * aspect
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
        }
    }
}

/// Backdrop for the simulator / when there's no live camera image.
public struct SimulatedCameraBackdrop: View {
    public init() {}
    public var body: some View {
        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                Label("Simulated camera", systemImage: "camera.metering.unknown")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 132)
            }
    }
}
