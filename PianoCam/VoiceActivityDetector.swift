//
//  VoiceActivityDetector.swift
//  PianoCam
//
//  Cheap voice-detection heuristic for gating Basic Pitch's input.
//  Idea: speech has a much lower spectral flatness than sustained piano
//  (vowels concentrate energy at formants 500/1500/2500 Hz; piano notes
//  spread energy across a clean harmonic comb). When we detect speech-like
//  spectra in a recent window, mute the audio fed to Basic Pitch.
//
//  Trade-off: gates legitimate piano during overlap, but at <30 ms latency
//  it doesn't add to the visible-key delay the way SoundAnalysis would.
//

import Accelerate
import Foundation

struct VoiceActivityDetector {
    /// Window of audio samples (Float32) to analyze. Should be ~25–50 ms worth
    /// of samples at the input sample rate.
    /// Returns true if the window looks more like speech than music.
    static func isSpeech(_ samples: [Float], sampleRate: Double) -> Bool {
        guard samples.count >= 256 else { return false }

        // 1) Energy gate — silent windows are not speech.
        var rms: Float = 0
        samples.withUnsafeBufferPointer { p in
            vDSP_rmsqv(p.baseAddress!, 1, &rms, vDSP_Length(samples.count))
        }
        guard rms > 0.005 else { return false }

        // 2) Zero-crossing rate — voiced speech ~1500–4000 zc/sec; sustained
        //    piano notes are typically <2000.
        var zcCount: Int = 0
        for i in 1..<samples.count {
            if (samples[i - 1] < 0) != (samples[i] < 0) { zcCount += 1 }
        }
        let zcr = Double(zcCount) * sampleRate / Double(samples.count)

        // 3) Spectral flatness — speech vowels concentrate energy at formants
        //    (low flatness ~0.05–0.2); piano harmonic combs are flatter
        //    (0.3–0.7). Compute via FFT magnitude geometric/arithmetic mean.
        let flat = spectralFlatness(samples)

        // Empirical decision rule (tune as needed):
        //   speech ≈ low flatness AND moderate-to-high ZCR
        let speechLikelihood = (flat < 0.20 ? 1 : 0) + (zcr > 1800 && zcr < 4500 ? 1 : 0)
        return speechLikelihood >= 2
    }

    private static func spectralFlatness(_ samples: [Float]) -> Float {
        // Pad / truncate to next power of two for FFT.
        let log2N = vDSP_Length(log2(Double(samples.count)).rounded(.down))
        let n = 1 << Int(log2N)
        guard n >= 64 else { return 1 }
        var input = Array(samples.prefix(n))
        var output = [Float](repeating: 0, count: n)

        // Hann window
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(n))

        guard let setup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else { return 1 }
        defer { vDSP_destroy_fftsetup(setup) }

        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var mag = [Float](repeating: 0, count: n / 2)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { ptr in
                        vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2N, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(n / 2))
            }
        }
        // Use bins ~50 Hz–4 kHz where speech formants live.
        // Approx bin = freq * n / sr.
        // For sr=44100, n=512: bin 1 ≈ 86 Hz, bin 47 ≈ 4 kHz.
        let binCount = mag.count
        var arithmeticSum: Float = 0
        var logSum: Float = 0
        var n2: Int = 0
        for i in 1..<binCount {
            let m = mag[i] + 1e-10
            arithmeticSum += m
            logSum += log(m)
            n2 += 1
        }
        guard n2 > 0 else { return 1 }
        let geo = exp(logSum / Float(n2))
        let arith = arithmeticSum / Float(n2)
        return arith > 0 ? geo / arith : 1
    }
}
