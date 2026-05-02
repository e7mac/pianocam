import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo

final class PianoCamExtensionStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private weak var device: CMIOExtensionDevice?

    private let width: Int32 = 1920
    private let height: Int32 = 1080
    private let frameRate: Int32 = 30
    private var timer: DispatchSourceTimer?
    private var frameCounter: UInt64 = 0
    private var pixelBufferPool: CVPixelBufferPool?
    private var formatDescription: CMFormatDescription?

    init(localizedName: String, streamID: UUID, device: CMIOExtensionDevice) {
        self.device = device
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
        configure()
    }

    private func configure() {
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &fd
        )
        formatDescription = fd

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        pixelBufferPool = pool
    }

    // MARK: - CMIOExtensionStreamSource

    var formats: [CMIOExtensionStreamFormat] {
        guard let formatDescription else { return [] }
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let format = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration,
            validFrameDurations: [frameDuration]
        )
        return [format]
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            props.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            props.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000 / Int64(frameRate)))
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.emitFrame() }
        self.timer = timer
        timer.resume()
    }

    func stopStream() throws {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Frame production (test pattern)

    private func emitFrame() {
        guard let pool = pixelBufferPool, let formatDescription else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return }

        drawTestPattern(into: pb, frame: frameCounter)
        frameCounter &+= 1

        var sampleBuffer: CMSampleBuffer?
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: now, decodeTimeStamp: .invalid)

        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescriptionOut: &fd
        )

        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescription: fd ?? formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sb = sampleBuffer else { return }
        stream.send(sb, discontinuity: [], hostTimeInNanoseconds: UInt64(now.seconds * 1_000_000_000))
    }

    private func drawTestPattern(into buffer: CVPixelBuffer, frame: UInt64) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let phase = Double(frame) * 0.05
        let bg = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = bg.advanced(by: y * stride)
            let yn = Double(y) / Double(h)
            for x in 0..<w {
                let xn = Double(x) / Double(w)
                let r = UInt8(0.5 * (sin(phase + xn * 6.0) + 1.0) * 255)
                let g = UInt8(0.5 * (sin(phase * 1.3 + yn * 8.0) + 1.0) * 255)
                let b = UInt8(0.5 * (sin(phase * 0.7 + (xn + yn) * 5.0) + 1.0) * 255)
                let p = row.advanced(by: x * 4)
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
    }
}
