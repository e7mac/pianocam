//
//  VocalIsolator.swift
//  PianoCam
//
//  Vocal isolation via UVR-MDX-NET-Inst_HQ_3 (CoreML). Takes mono audio
//  in at any sample rate, returns mono audio with vocals removed (the
//  "instrumental" stem) at 44.1 kHz.
//
//  Model expects a stereo complex spectrogram tensor:
//    spec: [1, 4, 3072, 256]  (L_real, L_imag, R_real, R_imag,
//                              freq bins 0..3071, time frames)
//  with FFT params n_fft=6144, hop_length=1024.
//
//  We run STFT/iSTFT on the Swift side using Accelerate.
//

import Accelerate
import CoreML
import Foundation

final class VocalIsolator {
    /// Sample rate the model was trained on.
    static let sampleRate: Double = 44_100
    private let nFFT = 6144
    private let hopLength = 1024
    private let dimF = 3072         // model only uses first 3072 freq bins
    private let segmentSize = 256   // time frames per inference window
    private let trim: Int           // n_fft / 2
    private let chunkSize: Int      // hop_length * (segment_size - 1)
    private let genSize: Int        // chunk_size - 2*trim — useful output per chunk
    private let nBins: Int          // n_fft/2 + 1
    /// Output compensation factor from the model's metadata.
    private let compensate: Float = 1.022

    private let model: MLModel
    private let inputName: String
    private let outputName: String

    private let window: [Float]     // Hann window, length n_fft
    private let log2N: vDSP_Length
    private let fftSetup: FFTSetup

    /// CoreML compile + load. Reads `VocalIsolator.mlmodelc` (or .mlpackage) from the bundle.
    init() throws {
        guard let url = Bundle.main.url(forResource: "VocalIsolator", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "VocalIsolator", withExtension: "mlpackage") else {
            throw NSError(domain: "PianoCam", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "VocalIsolator model not in app bundle"
            ])
        }
        let compiledURL: URL = (url.pathExtension == "mlmodelc")
            ? url
            : try MLModel.compileModel(at: url)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        self.model = try MLModel(contentsOf: compiledURL, configuration: cfg)
        let desc = model.modelDescription
        guard let inName = desc.inputDescriptionsByName.keys.first,
              let outName = desc.outputDescriptionsByName.keys.first else {
            throw NSError(domain: "PianoCam", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "VocalIsolator missing input/output"
            ])
        }
        self.inputName = inName
        self.outputName = outName

        self.trim = nFFT / 2
        self.chunkSize = hopLength * (segmentSize - 1)
        self.genSize = chunkSize - 2 * trim
        self.nBins = nFFT / 2 + 1

        // Periodic Hann window — same convention as torch.hann_window(periodic=True).
        // Apple's vDSP_hann_window with vDSP_HANN_NORM is periodic; the unnormalized
        // form has cosine endpoints. We need the periodic form to match the model.
        var w = [Float](repeating: 0, count: nFFT)
        vDSP_hann_window(&w, vDSP_Length(nFFT), Int32(vDSP_HANN_DENORM))
        self.window = w

        self.log2N = vDSP_Length(log2(Double(nFFT)).rounded())
        guard let setup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
            throw NSError(domain: "PianoCam", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "FFT setup failed"
            ])
        }
        self.fftSetup = setup
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Run the input mono audio through the vocal isolator. Returns the
    /// instrumental stem at 44.1 kHz mono. `progress` is called from 0…1 as
    /// chunks are processed.
    func process(samples: [Float],
                 sampleRate srcSR: Double,
                 progress: ((Double) -> Void)? = nil) -> [Float] {
        // 1) Resample to 44.1 kHz.
        let mono = Self.linearResample(samples, from: srcSR, to: Self.sampleRate)
        if mono.isEmpty { return [] }

        // 2) Pad: trim zeros at start, plus enough at end so we have an integer
        //    number of `genSize` chunks plus the trailing trim.
        let needed = ((mono.count + genSize - 1) / genSize) * genSize
        let endPad = needed - mono.count + trim
        var padded = [Float](repeating: 0, count: trim)
        padded.reserveCapacity(trim + needed + trim)
        padded.append(contentsOf: mono)
        padded.append(contentsOf: [Float](repeating: 0, count: endPad))

        // 3) Process chunks. Each iteration takes `chunkSize` samples and emits
        //    the central `genSize` samples of the model output.
        var out = [Float]()
        out.reserveCapacity(needed)
        let nChunks = (padded.count - chunkSize) / genSize + 1
        var chunkIdx = 0
        var pos = 0
        while pos + chunkSize <= padded.count {
            let chunk = Array(padded[pos..<pos + chunkSize])
            let isolated = processChunk(chunk)
            // Keep middle `genSize` samples; the trim region on each side is
            // STFT-context not output.
            let mid = isolated[trim..<trim + genSize]
            out.append(contentsOf: mid)
            pos += genSize
            chunkIdx += 1
            progress?(Double(chunkIdx) / Double(nChunks))
        }

        // 4) Crop back to original length.
        if out.count > mono.count { out.removeLast(out.count - mono.count) }
        return out
    }

    // MARK: - Chunk processing (STFT → model → iSTFT)

    /// Run one `chunkSize`-sample chunk through the model and return the
    /// instrumental output of the same length.
    private func processChunk(_ chunk: [Float]) -> [Float] {
        // STFT → real/imag arrays of size [n_bins, n_frames].
        let (realLR, imagLR) = stft(chunk)
        // Pack into [1, 4, dimF, segmentSize] = L_real, L_imag, R_real, R_imag.
        // We feed the same mono signal to both L and R (model is stereo).
        guard let inputArr = try? MLMultiArray(
            shape: [1, 4, NSNumber(value: dimF), NSNumber(value: segmentSize)],
            dataType: .float32
        ) else { return [Float](repeating: 0, count: chunkSize) }

        let inPtr = inputArr.dataPointer.bindMemory(to: Float.self, capacity: inputArr.count)
        // Layout (row-major): channel-major. Strides:
        let cStride = dimF * segmentSize
        for c in 0..<4 {
            let src: [Float]
            switch c {
            case 0, 2: src = realLR    // L_real, R_real
            case 1, 3: src = imagLR    // L_imag, R_imag
            default: continue
            }
            // STFT output is laid out [bin][frame] row-major; same as model.
            let base = c * cStride
            // Only the first `dimF` bins go to the model.
            for b in 0..<dimF {
                let srcOff = b * segmentSize
                let dstOff = base + b * segmentSize
                src.withUnsafeBufferPointer { sp in
                    let sptr = sp.baseAddress!.advanced(by: srcOff)
                    inPtr.advanced(by: dstOff).update(from: sptr, count: segmentSize)
                }
            }
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: inputArr]),
              let out = try? model.prediction(from: provider),
              let outArr = out.featureValue(for: outputName)?.multiArrayValue else {
            return [Float](repeating: 0, count: chunkSize)
        }

        // Unpack output → real/imag arrays sized [n_bins, n_frames]. Pad bins
        // dimF..n_bins-1 with zeros (model only outputs up to dimF).
        var outRealLR = [Float](repeating: 0, count: nBins * segmentSize)
        var outImagLR = [Float](repeating: 0, count: nBins * segmentSize)
        let outPtr = outArr.dataPointer.bindMemory(to: Float.self, capacity: outArr.count)
        // We average L and R (since input was mono, model output should be ~symmetric).
        for f in 0..<segmentSize {
            for b in 0..<dimF {
                let lr = outPtr[0 * cStride + b * segmentSize + f]
                let li = outPtr[1 * cStride + b * segmentSize + f]
                let rr = outPtr[2 * cStride + b * segmentSize + f]
                let ri = outPtr[3 * cStride + b * segmentSize + f]
                outRealLR[b * segmentSize + f] = (lr + rr) * 0.5 * compensate
                outImagLR[b * segmentSize + f] = (li + ri) * 0.5 * compensate
            }
        }
        // Bins dimF..n_bins-1 stay zero (model didn't predict them).

        return istft(real: outRealLR, imag: outImagLR)
    }

    // MARK: - STFT / iSTFT (vDSP)

    /// Forward STFT: real input → (real, imag) arrays sized [n_bins, n_frames]
    /// laid out row-major as `[bin * n_frames + frame]`. Uses Hann window,
    /// `center=True` (symmetric reflect-pad of n_fft/2), hop = `hopLength`.
    private func stft(_ input: [Float]) -> (real: [Float], imag: [Float]) {
        // center=True padding via reflection at both ends.
        var padded = [Float](repeating: 0, count: input.count + 2 * trim)
        // Reflect-pad start: input[trim], input[trim-1], ..., input[1]
        for i in 0..<trim { padded[i] = input[trim - i] }
        // Copy input
        padded.withUnsafeMutableBufferPointer { dst in
            input.withUnsafeBufferPointer { src in
                dst.baseAddress!.advanced(by: trim).update(from: src.baseAddress!, count: input.count)
            }
        }
        // Reflect-pad end
        let n = input.count
        for i in 0..<trim { padded[trim + n + i] = input[n - 2 - i] }

        let nFrames = segmentSize
        var real = [Float](repeating: 0, count: nBins * nFrames)
        var imag = [Float](repeating: 0, count: nBins * nFrames)

        var windowed = [Float](repeating: 0, count: nFFT)
        var realPart = [Float](repeating: 0, count: nFFT / 2)
        var imagPart = [Float](repeating: 0, count: nFFT / 2)

        for f in 0..<nFrames {
            let off = f * hopLength
            // Apply window.
            padded.withUnsafeBufferPointer { sp in
                window.withUnsafeBufferPointer { wp in
                    vDSP_vmul(sp.baseAddress!.advanced(by: off), 1,
                              wp.baseAddress!, 1,
                              &windowed, 1,
                              vDSP_Length(nFFT))
                }
            }

            // Real → split-complex (interleaved layout reinterpretation).
            realPart.withUnsafeMutableBufferPointer { rp in
                imagPart.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { src in
                        src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) { dsp in
                            vDSP_ctoz(dsp, 2, &split, 1, vDSP_Length(nFFT / 2))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2N, FFTDirection(FFT_FORWARD))

                    // vDSP packs DC in realp[0], Nyquist in imagp[0]. Bins 1..N/2-1
                    // are (realp[i], imagp[i]). Scale by 0.5 to undo vDSP's 2x.
                    real[0 * nFrames + f] = rp[0] * 0.5
                    imag[0 * nFrames + f] = 0
                    real[(nBins - 1) * nFrames + f] = ip[0] * 0.5
                    imag[(nBins - 1) * nFrames + f] = 0
                    for b in 1..<(nFFT / 2) {
                        real[b * nFrames + f] = rp[b] * 0.5
                        imag[b * nFrames + f] = ip[b] * 0.5
                    }
                }
            }
        }
        return (real, imag)
    }

    /// Inverse STFT with overlap-add. Mirror of `stft` — assumes Hann window,
    /// hop = `hopLength`, center=True. Returns `chunkSize` samples.
    private func istft(real: [Float], imag: [Float]) -> [Float] {
        let nFrames = segmentSize
        // Output buffer: `chunkSize` samples after trimming center-pad.
        let paddedLen = chunkSize + 2 * trim
        var output = [Float](repeating: 0, count: paddedLen)
        var windowSumSq = [Float](repeating: 0, count: paddedLen)

        var realPart = [Float](repeating: 0, count: nFFT / 2)
        var imagPart = [Float](repeating: 0, count: nFFT / 2)
        var time = [Float](repeating: 0, count: nFFT)
        let scale: Float = 1.0 / Float(nFFT)

        for f in 0..<nFrames {
            // Repack bins to vDSP's split layout.
            realPart[0] = real[0 * nFrames + f] * 2     // undo our 0.5
            imagPart[0] = real[(nBins - 1) * nFrames + f] * 2  // Nyquist into imagp[0]
            for b in 1..<(nFFT / 2) {
                realPart[b] = real[b * nFrames + f] * 2
                imagPart[b] = imag[b * nFrames + f] * 2
            }

            realPart.withUnsafeMutableBufferPointer { rp in
                imagPart.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, log2N, FFTDirection(FFT_INVERSE))
                    // Convert split → real interleaved.
                    time.withUnsafeMutableBufferPointer { tp in
                        tp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) { dsp in
                            vDSP_ztoc(&split, 1, dsp, 2, vDSP_Length(nFFT / 2))
                        }
                    }
                    // Apply window (synthesis) and overlap-add into output.
                    vDSP_vsmul(time, 1, [scale], &time, 1, vDSP_Length(nFFT))
                    let off = f * hopLength
                    for i in 0..<nFFT {
                        output[off + i] += time[i] * window[i]
                        windowSumSq[off + i] += window[i] * window[i]
                    }
                }
            }
        }

        // Normalize by overlapping-window sum-of-squares to invert the
        // analysis window (synthesis-window choice = same Hann gives perfect
        // reconstruction at this hop / window combination, modulo edges).
        let eps: Float = 1e-8
        for i in 0..<paddedLen {
            output[i] /= max(windowSumSq[i], eps)
        }

        // Crop center-pad off both ends.
        return Array(output[trim..<trim + chunkSize])
    }

    // MARK: - Helpers

    /// Cheap linear-interpolation resampler. Good enough for the model's
    /// expected 44.1 kHz when input is close to that rate.
    static func linearResample(_ src: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
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
