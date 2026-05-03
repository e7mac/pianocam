//
//  VideoProcessor.swift
//  PianoCam
//
//  Offline pipeline: take an existing video file, run Basic Pitch over its
//  audio track to produce a timeline of MIDI events, then re-encode the
//  video with the piano-overlay composited onto each frame.
//

import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import OnnxRuntimeBindings

@MainActor
final class VideoProcessor: ObservableObject {
    enum Phase: String {
        case idle = "Idle"
        case analyzingAudio = "Analyzing audio"
        case rendering = "Rendering"
        case finished = "Done"
        case failed = "Failed"
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastOutputURL: URL?

    private var task: Task<Void, Never>?

    func process(input: URL, output: URL,
                 settings: BasicPitchInference.Settings) {
        task?.cancel()
        progress = 0
        lastError = nil
        lastOutputURL = nil
        phase = .analyzingAudio

        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await self?.run(input: input, output: output, settings: settings)
            } catch {
                await MainActor.run {
                    self?.phase = .failed
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    private nonisolated func run(input: URL, output: URL,
                                 settings: BasicPitchInference.Settings) async throws {
        let asset = AVURLAsset(url: input)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "PianoCam.VideoProcessor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Input has no audio track"])
        }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "PianoCam.VideoProcessor", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Input has no video track"])
        }

        // 1) Analyze audio offline → events timeline.
        let events = try await analyzeAudio(asset: asset, audioTrack: audioTrack,
                                            settings: settings)

        await MainActor.run {
            self.phase = .rendering
            self.progress = 0
        }

        // 2) Render new video.
        try await renderVideo(asset: asset,
                              videoTrack: videoTrack,
                              audioTrack: audioTrack,
                              events: events,
                              outputURL: output)

        await MainActor.run {
            self.phase = .finished
            self.progress = 1
            self.lastOutputURL = output
        }
    }

    // MARK: - Audio analysis

    private nonisolated func analyzeAudio(asset: AVAsset,
                                          audioTrack: AVAssetTrack,
                                          settings: BasicPitchInference.Settings) async throws -> [(time: TimeInterval, event: MIDIEvent)] {
        // Read mono float samples at original SR.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1
        ]
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        guard reader.canAdd(trackOutput) else {
            throw NSError(domain: "PianoCam.VideoProcessor", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot read audio track"])
        }
        reader.add(trackOutput)
        reader.startReading()

        let nativeTimeScale = try await audioTrack.load(.naturalTimeScale)
        let nativeSR = nativeTimeScale > 0 ? Double(nativeTimeScale) : 44_100.0
        let durationCM = try await asset.load(.duration)
        let assetDuration = max(0.001, CMTimeGetSeconds(durationCM))

        var allSamples: [Float] = []
        while let sample = trackOutput.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var lengthAtOffset = 0, totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                        totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            guard let dp = dataPointer else { continue }
            let count = totalLength / MemoryLayout<Float>.size
            allSamples.append(contentsOf: UnsafeBufferPointer(
                start: UnsafeRawPointer(dp).bindMemory(to: Float.self, capacity: count),
                count: count))
        }
        guard reader.status == .completed else {
            throw NSError(domain: "PianoCam.VideoProcessor", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Audio read failed: \(reader.error?.localizedDescription ?? "unknown")"])
        }

        // Determine actual sample rate from asset (more reliable than track.naturalTimeScale).
        let sampleCount = allSamples.count
        let approxSR = Double(sampleCount) / assetDuration
        let sr = approxSR > 8000 ? approxSR : nativeSR
        NSLog("VideoProcessor: audio samples=\(sampleCount) sr=\(Int(sr))")

        // Resample to 22050 for Basic Pitch.
        let target: Double = 22_050
        var resampled = Self.linearResample(allSamples, from: sr, to: target)

        // Speech rejection: zero out ~100 ms chunks that look speech-like.
        if speechRejectionEnabled {
            let chunkSize = Int(target * 0.1)   // 100 ms
            var i = 0
            var muted = 0
            while i < resampled.count {
                let end = min(i + chunkSize, resampled.count)
                let slice = Array(resampled[i..<end])
                if VoiceActivityDetector.isSpeech(slice, sampleRate: target) {
                    for j in i..<end { resampled[j] = 0 }
                    muted += 1
                }
                i = end
            }
            NSLog("VideoProcessor: speech rejection muted \(muted) chunks")
        }

        let analyzer = try OfflineBasicPitchAnalyzer()
        let events = analyzer.process(samples: resampled,
                                      sampleRate: target,
                                      settings: settings) { fraction in
            Task { @MainActor in self.progress = fraction }
        }
        return events
    }

    /// Whether to gate speech-like audio out of the offline analysis. The UI
    /// flips this on `HostState.vadEnabled`; we read it once when processing starts.
    nonisolated(unsafe) var speechRejectionEnabled: Bool = false

    // MARK: - Video render

    private nonisolated func renderVideo(asset: AVAsset,
                                         videoTrack: AVAssetTrack,
                                         audioTrack: AVAssetTrack,
                                         events: [(time: TimeInterval, event: MIDIEvent)],
                                         outputURL: URL) async throws {
        // Clean any stale file at the output path.
        try? FileManager.default.removeItem(at: outputURL)

        // Reader: BGRA video frames + passthrough audio.
        let reader = try AVAssetReader(asset: asset)
        let videoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoSettings)

        let audioFormatDescriptions = try await audioTrack.load(.formatDescriptions)
        let audioChannels = audioFormatDescriptions.first.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame
        } ?? 2
        let audioTimeScale = try await audioTrack.load(.naturalTimeScale)
        let audioSampleRate = audioTimeScale > 0 ? Double(audioTimeScale) : 44_100
        let audioOut = AVAssetReaderTrackOutput(track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: Int(audioChannels),
                AVSampleRateKey: audioSampleRate
            ])
        if reader.canAdd(videoOut) { reader.add(videoOut) }
        if reader.canAdd(audioOut) { reader.add(audioOut) }
        guard reader.startReading() else {
            throw NSError(domain: "PianoCam.VideoProcessor", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Reader failed to start"])
        }

        // Writer
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerVideoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(naturalSize.width),
            AVVideoHeightKey: Int(naturalSize.height)
        ]
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerVideoSettings)
        videoWriterInput.expectsMediaDataInRealTime = false
        videoWriterInput.transform = preferredTransform

        let audioWriterInput = AVAssetWriterInput(mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000
            ])
        audioWriterInput.expectsMediaDataInRealTime = false

        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(naturalSize.width),
                kCVPixelBufferHeightKey as String: Int(naturalSize.height)
            ])

        if writer.canAdd(videoWriterInput) { writer.add(videoWriterInput) }
        if writer.canAdd(audioWriterInput) { writer.add(audioWriterInput) }
        guard writer.startWriting() else {
            throw NSError(domain: "PianoCam.VideoProcessor", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Writer failed: \(writer.error?.localizedDescription ?? "unknown")"])
        }
        writer.startSession(atSourceTime: .zero)

        let totalDurationCM = try await asset.load(.duration)
        let totalDuration = max(0.001, CMTimeGetSeconds(totalDurationCM))
        let pianoState = PianoState()
        var eventIdx = 0
        let sortedEvents = events.sorted { $0.time < $1.time }
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        // Drive video first; then drain audio. Both use requestMediaDataWhenReady.
        let videoQueue = DispatchQueue(label: "pianocam.videoproc.video")
        let audioQueue = DispatchQueue(label: "pianocam.videoproc.audio")

        await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            group.enter()
            videoWriterInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoWriterInput.isReadyForMoreMediaData {
                    guard let sample = videoOut.copyNextSampleBuffer() else {
                        videoWriterInput.markAsFinished()
                        group.leave()
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let timeSec = pts.seconds
                    while eventIdx < sortedEvents.count && sortedEvents[eventIdx].time <= timeSec {
                        pianoState.handle(sortedEvents[eventIdx].event)
                        eventIdx += 1
                    }
                    guard let sourcePB = CMSampleBufferGetImageBuffer(sample) else { continue }
                    if let composited = self.compositeFrame(source: sourcePB,
                                                            pianoState: pianoState,
                                                            ciContext: ciContext) {
                        if !pixelAdaptor.append(composited, withPresentationTime: pts) {
                            NSLog("VideoProcessor: video append failed at \(timeSec)")
                        }
                    }
                    Task { @MainActor in
                        if totalDuration > 0 {
                            self.progress = min(1, timeSec / totalDuration)
                        }
                    }
                }
            }

            group.enter()
            audioWriterInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioWriterInput.isReadyForMoreMediaData {
                    guard let sample = audioOut.copyNextSampleBuffer() else {
                        audioWriterInput.markAsFinished()
                        group.leave()
                        return
                    }
                    audioWriterInput.append(sample)
                }
            }

            group.notify(queue: .main) {
                writer.finishWriting {
                    continuation.resume()
                }
            }
        }

        if writer.status == .failed {
            throw NSError(domain: "PianoCam.VideoProcessor", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Writer failed: \(writer.error?.localizedDescription ?? "unknown")"])
        }
    }

    // MARK: - Compositing

    private func compositeFrame(source: CVPixelBuffer,
                                pianoState: PianoState,
                                ciContext: CIContext) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(source)
        let h = CVPixelBufferGetHeight(source)
        let attrs = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ] as CFDictionary
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                  attrs, &output) == kCVReturnSuccess,
              let out = output else { return nil }

        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(out),
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(out),
                                  space: cs,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                            | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return nil
        }

        // Camera in top 70%.
        let pianoFraction: CGFloat = 0.30
        let camRegion = CGRect(x: 0, y: CGFloat(h) * pianoFraction,
                               width: CGFloat(w),
                               height: CGFloat(h) * (1 - pianoFraction))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let ci = CIImage(cvPixelBuffer: source)
        let camW = ci.extent.width, camH = ci.extent.height
        let scale = max(camRegion.width / camW, camRegion.height / camH)
        let scaledW = camW * scale, scaledH = camH * scale
        let drawRect = CGRect(
            x: camRegion.minX + (camRegion.width - scaledW) / 2,
            y: camRegion.minY + (camRegion.height - scaledH) / 2,
            width: scaledW, height: scaledH)
        if let cg = ciContext.createCGImage(ci, from: ci.extent) {
            ctx.saveGState()
            ctx.clip(to: camRegion)
            ctx.draw(cg, in: drawRect)
            ctx.restoreGState()
        }

        PianoOverlay.draw(into: ctx,
                          rect: CGRect(x: 0, y: 0, width: w, height: h),
                          heightFraction: pianoFraction,
                          activeNotes: pianoState.activeVelocities,
                          pedals: pianoState.pedalsState)
        return out
    }

    // MARK: - Helpers

    private nonisolated static func linearResample(_ src: [Float],
                                                   from srcRate: Double,
                                                   to dstRate: Double) -> [Float] {
        if abs(srcRate - dstRate) < 1 { return src }
        let ratio = srcRate / dstRate
        let outCount = Int(Double(src.count) / ratio)
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Double(i) * ratio
            let i0 = Int(pos)
            let i1 = min(i0 + 1, src.count - 1)
            let frac = Float(pos - Double(i0))
            out[i] = src[i0] * (1 - frac) + src[i1] * frac
        }
        return out
    }
}

// MARK: - Offline Basic Pitch

/// Runs Basic Pitch in batch over a long buffer. Same model + post-processing
/// as the realtime path; just no streaming gating.
private final class OfflineBasicPitchAnalyzer {
    private let env: ORTEnv
    private let session: ORTSession

    init() throws {
        env = try ORTEnv(loggingLevel: .warning)
        guard let url = Bundle.main.url(forResource: "BasicPitch", withExtension: "onnx") else {
            throw NSError(domain: "PianoCam", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "BasicPitch.onnx not in app bundle"
            ])
        }
        let opts = try ORTSessionOptions()
        try? opts.appendCoreMLExecutionProvider(with: ORTCoreMLExecutionProviderOptions())
        session = try ORTSession(env: env, modelPath: url.path, sessionOptions: opts)
    }

    /// Returns a sorted list of (time, event) tuples. Scans every model frame
    /// in every window, so staccato events keep their real timestamps.
    func process(samples: [Float],
                 sampleRate: Double,
                 settings: BasicPitchInference.Settings,
                 progress: @escaping (Double) -> Void) -> [(time: TimeInterval, event: MIDIEvent)] {
        let windowSize = 43_844
        let frameCount = 172
        let pitchCount = 88
        let frameDuration = (Double(windowSize) / sampleRate) / Double(frameCount)  // ≈11.6ms
        let hop = windowSize / 4
        let totalDuration = Double(samples.count) / sampleRate

        // Time-indexed structures keyed by pitch.
        var lastOnsetAt: [UInt8: TimeInterval] = [:]
        var lastActiveAt: [UInt8: TimeInterval] = [:]
        var onTimes: [UInt8: TimeInterval] = [:]   // when each currently-on note fired
        var events: [(TimeInterval, MIDIEvent)] = []

        let onsetCooldown: TimeInterval = 0.04     // dedup repeated onset detections
        let releaseGap: TimeInterval = 0.12        // emit note-off after this much silence

        var windowStart = 0
        while windowStart + windowSize <= samples.count {
            // Peak-normalize.
            var window = Array(samples[windowStart..<windowStart + windowSize])
            var peak: Float = 0
            for s in window { let a = abs(s); if a > peak { peak = a } }
            if peak > 0.001 {
                let gain: Float = 0.9 / peak
                for i in 0..<window.count { window[i] *= gain }
            }

            guard let (note, onset) = runInference(audio: window) else {
                windowStart += hop
                continue
            }
            let windowStartTime = Double(windowStart) / sampleRate

            // Walk every frame; emit note-on at actual onset times (deduped).
            for f in 0..<frameCount {
                let frameTime = windowStartTime + Double(f) * frameDuration
                let base = f * pitchCount
                for p in 0..<pitchCount {
                    let midi = UInt8(21 + p)
                    let oVal = onset[base + p]
                    let nVal = note[base + p]

                    if oVal >= settings.onsetThreshold {
                        let last = lastOnsetAt[midi] ?? -1
                        if frameTime - last >= onsetCooldown {
                            // If still considered on, emit a noteOff first so the
                            // visualizer re-attacks cleanly.
                            if onTimes[midi] != nil {
                                events.append((frameTime, .noteOff(note: midi)))
                                onTimes.removeValue(forKey: midi)
                            }
                            events.append((frameTime, .noteOn(note: midi, velocity: 100)))
                            onTimes[midi] = frameTime
                            lastOnsetAt[midi] = frameTime
                            lastActiveAt[midi] = frameTime
                        }
                    }

                    if nVal >= settings.frameThreshold {
                        lastActiveAt[midi] = frameTime
                    }
                }
            }

            // Sweep release: any held note that's been silent for releaseGap is off.
            for (midi, _) in onTimes {
                let last = lastActiveAt[midi] ?? 0
                let now = windowStartTime + Double(frameCount) * frameDuration
                if now - last > releaseGap {
                    events.append((last + releaseGap, .noteOff(note: midi)))
                    onTimes.removeValue(forKey: midi)
                }
            }

            progress(min(1, Double(windowStart + windowSize) / Double(samples.count)))
            windowStart += hop
        }

        // Final note-offs at the end.
        for (midi, _) in onTimes {
            events.append((totalDuration, .noteOff(note: midi)))
        }
        return events.sorted { $0.0 < $1.0 }
    }

    private func runInference(audio: [Float]) -> (note: [Float], onset: [Float])? {
        do {
            let shape: [NSNumber] = [1, NSNumber(value: audio.count), 1]
            let bytes = audio.count * MemoryLayout<Float>.stride
            let data = NSMutableData(length: bytes)!
            audio.withUnsafeBufferPointer { src in
                memcpy(data.mutableBytes, src.baseAddress, bytes)
            }
            let input = try ORTValue(tensorData: data, elementType: .float, shape: shape)

            let outA = "StatefulPartitionedCall:1"
            let outB = "StatefulPartitionedCall:2"
            let outputs = try session.run(
                withInputs: ["serving_default_input_2:0": input],
                outputNames: Set([outA, outB]),
                runOptions: nil
            )
            guard let valA = outputs[outA], let valB = outputs[outB] else { return nil }
            let dataA = try valA.tensorData() as Data
            let dataB = try valB.tensorData() as Data

            let probsA = Array(dataA.withUnsafeBytes { $0.bindMemory(to: Float.self) })
            let probsB = Array(dataB.withUnsafeBytes { $0.bindMemory(to: Float.self) })
            let aMean = probsA.reduce(0, +) / Float(probsA.count)
            let bMean = probsB.reduce(0, +) / Float(probsB.count)
            let noteProbs = aMean >= bMean ? probsA : probsB
            let onsetProbs = aMean >= bMean ? probsB : probsA
            return (noteProbs, onsetProbs)
        } catch {
            return nil
        }
    }
}
