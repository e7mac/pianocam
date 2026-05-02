import AVFoundation
import AppKit
import Combine
import CoreVideo
import Foundation
import SwiftUI

@MainActor
final class CompositedFrameSource: ObservableObject {
    private let compositor = FrameCompositor()
    private weak var camera: CameraSession?
    private weak var piano: PianoState?
    /// Shared with `CompositedPreviewNSView` to feed the display layer.
    let onComposited = PassthroughSubject<CMSampleBuffer, Never>()
    private let renderQueue = DispatchQueue(label: "pianocam.compositor", qos: .userInteractive)

    func bind(camera: CameraSession, piano: PianoState) {
        self.camera = camera
        self.piano = piano
        camera.onFrame = { [weak self] pixelBuffer, pts in
            self?.handle(camera: pixelBuffer, pts: pts)
        }
    }

    private func handle(camera pixelBuffer: CVPixelBuffer, pts: CMTime) {
        // Snapshot the active notes from the main actor.
        let active: [UInt8: UInt8] = DispatchQueue.main.sync { [weak self] in
            self?.piano?.activeVelocities ?? [:]
        }
        renderQueue.async { [weak self] in
            guard let self,
                  let out = self.compositor.composite(camera: pixelBuffer, activeNotes: active) else { return }
            guard let sb = Self.makeSampleBuffer(from: out, pts: pts) else { return }
            self.onComposited.send(sb)
        }
    }

    private static func makeSampleBuffer(from pb: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pb,
                                                     formatDescriptionOut: &fd)
        guard let fd else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pb,
                                                 formatDescription: fd,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sb)
        return sb
    }
}

struct CompositedPreviewView: NSViewRepresentable {
    let source: CompositedFrameSource

    func makeNSView(context: Context) -> CompositedPreviewNSView {
        let v = CompositedPreviewNSView()
        v.subscribe(to: source.onComposited)
        return v
    }

    func updateNSView(_ nsView: CompositedPreviewNSView, context: Context) {}
}

final class CompositedPreviewNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var cancellable: AnyCancellable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    func subscribe(to publisher: PassthroughSubject<CMSampleBuffer, Never>) {
        cancellable = publisher.receive(on: DispatchQueue.main).sink { [weak self] sb in
            guard let self else { return }
            if self.displayLayer.requiresFlushToResumeDecoding {
                self.displayLayer.flush()
            }
            self.displayLayer.enqueue(sb)
        }
    }
}
