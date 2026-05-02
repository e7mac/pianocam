import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import SwiftUI

/// Composites a camera frame plus the 88-key piano overlay into a 1080p
/// `CVPixelBuffer`. The same pipeline will eventually feed the camera
/// extension, but for now the output is rendered in-app via
/// `AVSampleBufferDisplayLayer` for verification.
final class FrameCompositor {
    static let outputWidth: Int = 1920
    static let outputHeight: Int = 1080

    private let ciContext: CIContext
    private let pool: CVPixelBufferPool
    private let pianoRenderer = PianoOverlayRenderer(width: outputWidth,
                                                     height: Int(Double(outputHeight) * 0.25))
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init() {
        ciContext = CIContext(options: [.useSoftwareRenderer: false])

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.outputWidth,
            kCVPixelBufferHeightKey as String: Self.outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        var pool: CVPixelBufferPool!
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        self.pool = pool
    }

    /// Composite one frame and return a fresh BGRA pixel buffer.
    func composite(camera: CVPixelBuffer, activeNotes: [UInt8: UInt8]) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let outBuffer = out else { return nil }

        let outRect = CGRect(x: 0, y: 0, width: Self.outputWidth, height: Self.outputHeight)

        // Camera, scaled+cropped to fill output (mirrored horizontally so it looks like a webcam).
        let cameraImage = CIImage(cvPixelBuffer: camera)
        let scaled = aspectFill(image: cameraImage, target: outRect)
        let mirrored = scaled
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: outRect.width, y: 0))

        // Piano overlay along the bottom 25%.
        let overlayHeight = CGFloat(pianoRenderer.height)
        let overlayImage = pianoRenderer.render(activeNotes: activeNotes)
        let overlayPositioned = overlayImage.transformed(
            by: CGAffineTransform(translationX: 0, y: 0)
        )

        // Composite overlay over camera.
        let composed = overlayPositioned
            .composited(over: mirrored)
            .cropped(to: outRect)
        _ = overlayHeight

        ciContext.render(composed, to: outBuffer, bounds: outRect, colorSpace: outputColorSpace)
        return outBuffer
    }

    private func aspectFill(image: CIImage, target: CGRect) -> CIImage {
        let src = image.extent
        let scaleX = target.width / src.width
        let scaleY = target.height / src.height
        let scale = max(scaleX, scaleY)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = target.midX - scaled.extent.midX
        let dy = target.midY - scaled.extent.midY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }
}
