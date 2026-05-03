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
    /// Forward and inverse DFT setups. We use the complex-DFT API (vDSP_DFT_zop)
    /// because n_fft = 6144 isn't a power of two — it's 2^11 · 3, supported by
    /// the prime-factor DFT but not by `vDSP_fft_zrip`.
    private let fwdDFT: vDSP_DFT_Setup
    private let invDFT: vDSP_DFT_Setup
    /// Reused zero buffer for the imag input to forward DFTs (real signal).
    private let zeroBuf: [Float]
    /// Periodic Hann window divided by sum-of-squares for synthesis-side
    /// normalization. Pre-computed since both window and squared window are
    /// invariant.
    private let synthesisWindowSqr: [Float]

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

        // Periodic Hann window: w[n] = 0.5 * (1 - cos(2π·n / N)). This matches
        // torch.hann_window(periodic=True), which is what the model was trained
        // with via librosa/torch's STFT.
        var w = [Float](repeating: 0, count: nFFT)
        for n in 0..<nFFT {
            w[n] = 0.5 * (1 - cos(2 * .pi * Float(n) / Float(nFFT)))
        }
        self.window = w
        var sqr = [Float](repeating: 0, count: nFFT)
        for i in 0..<nFFT { sqr[i] = w[i] * w[i] }
        self.synthesisWindowSqr = sqr

        guard let fwd = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(nFFT), .FORWARD),
              let inv = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(nFFT), .INVERSE) else {
            throw NSError(domain: "PianoCam", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "DFT setup failed for n_fft=\(nFFT)"
            ])
        }
        self.fwdDFT = fwd
        self.invDFT = inv
        self.zeroBuf = [Float](repeating: 0, count: nFFT)
    }

    deinit {
        vDSP_DFT_DestroySetup(fwdDFT)
        vDSP_DFT_DestroySetup(invDFT)
    }

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
        // center=True padding via reflection at both ends. Reflection axis is
        // the boundary sample (boundary itself NOT duplicated) — same as
        // torch's mode='reflect'.
        let n = input.count
        var padded = [Float](repeating: 0, count: n + 2 * trim)
        for i in 0..<trim { padded[i] = input[trim - i] }
        padded.withUnsafeMutableBufferPointer { dst in
            input.withUnsafeBufferPointer { src in
                dst.baseAddress!.advanced(by: trim).update(from: src.baseAddress!, count: n)
            }
        }
        for i in 0..<trim { padded[trim + n + i] = input[n - 2 - i] }

        let nFrames = segmentSize
        var real = [Float](repeating: 0, count: nBins * nFrames)
        var imag = [Float](repeating: 0, count: nBins * nFrames)

        var windowed = [Float](repeating: 0, count: nFFT)
        var outReal = [Float](repeating: 0, count: nFFT)
        var outImag = [Float](repeating: 0, count: nFFT)

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

            // Forward complex DFT. Real input means imag = 0 (zeroBuf).
            windowed.withUnsafeBufferPointer { wIn in
                zeroBuf.withUnsafeBufferPointer { zIn in
                    outReal.withUnsafeMutableBufferPointer { rOut in
                        outImag.withUnsafeMutableBufferPointer { iOut in
                            vDSP_DFT_Execute(fwdDFT,
                                             wIn.baseAddress!, zIn.baseAddress!,
                                             rOut.baseAddress!, iOut.baseAddress!)
                        }
                    }
                }
            }
            // Take the first n_fft/2+1 unique bins. (For real input, the
            // remaining bins are conjugate-symmetric.)
            for b in 0..<nBins {
                real[b * nFrames + f] = outReal[b]
                imag[b * nFrames + f] = outImag[b]
            }
        }
        return (real, imag)
    }

    /// Inverse STFT with overlap-add. Mirror of `stft` — assumes Hann window,
    /// hop = `hopLength`, center=True. Returns `chunkSize` samples.
    private func istft(real: [Float], imag: [Float]) -> [Float] {
        let nFrames = segmentSize
        let paddedLen = chunkSize + 2 * trim
        var output = [Float](repeating: 0, count: paddedLen)
        var windowSumSq = [Float](repeating: 0, count: paddedLen)

        var inReal = [Float](repeating: 0, count: nFFT)
        var inImag = [Float](repeating: 0, count: nFFT)
        var outReal = [Float](repeating: 0, count: nFFT)
        var outImag = [Float](repeating: 0, count: nFFT)
        let scale: Float = 1.0 / Float(nFFT)

        for f in 0..<nFrames {
            // Reconstruct the full N-point complex spectrum from the half:
            // bins 0..nBins-1 we have directly; bins nFFT-k = conj(bin k).
            for b in 0..<nBins {
                inReal[b] = real[b * nFrames + f]
                inImag[b] = imag[b * nFrames + f]
            }
            for k in 1..<(nFFT / 2) {
                inReal[nFFT - k] = inReal[k]
                inImag[nFFT - k] = -inImag[k]
            }
            // Inverse complex DFT.
            inReal.withUnsafeBufferPointer { rIn in
                inImag.withUnsafeBufferPointer { iIn in
                    outReal.withUnsafeMutableBufferPointer { rOut in
                        outImag.withUnsafeMutableBufferPointer { iOut in
                            vDSP_DFT_Execute(invDFT,
                                             rIn.baseAddress!, iIn.baseAddress!,
                                             rOut.baseAddress!, iOut.baseAddress!)
                        }
                    }
                }
            }
            // Inverse DFT in vDSP isn't normalized; divide by N. Imag part
            // should be ~0 for a real signal — discard it.
            vDSP_vsmul(outReal, 1, [scale], &outReal, 1, vDSP_Length(nFFT))

            // Apply synthesis window + overlap-add.
            let off = f * hopLength
            for i in 0..<nFFT {
                output[off + i] += outReal[i] * window[i]
                windowSumSq[off + i] += synthesisWindowSqr[i]
            }
        }

        // Normalize by overlapping-window sum-of-squares — inverts the
        // analysis-window weighting accumulated by overlap-add.
        let eps: Float = 1e-8
        for i in 0..<paddedLen {
            output[i] /= max(windowSumSq[i], eps)
        }
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
