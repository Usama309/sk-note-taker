import Foundation

/// Reference-based acoustic echo canceller (NLMS adaptive filter).
///
/// On laptop speakers the remote participant's voice comes out of the speakers and the mic
/// re-records it, so the mic channel = local voice + a delayed copy of the system audio. Since
/// the system tap is a clean digital reference of exactly what the speakers played, we can
/// adaptively estimate the speaker→mic echo path and subtract it, leaving (near-)only the
/// local voice. This is what actually SEPARATES the two voices, instead of trying to guess
/// which transcribed words were echo after the fact.
///
/// The filter spans `taps` samples of reference history (0…`taps`/16 ms at 16 kHz), which must
/// cover the acoustic delay (~40–50 ms observed) plus the room tail. NLMS adapts per sample,
/// normalised by the reference energy so it converges regardless of speaker volume.
///
/// Adaptation is gated on reference energy (no update while the far-end is silent, so a region
/// where only the local user talks passes through untouched) and frozen during detected
/// double-talk (both talking) so the local voice is never fitted as echo.
public struct EchoCanceller: Sendable {
    public var taps: Int
    public var mu: Float
    public var eps: Float
    /// Reference short-term energy floor below which we treat the far-end as silent (skip
    /// both cancellation and adaptation — nothing to cancel).
    public var refEnergyFloor: Float
    /// Double-talk freeze: once the filter has converged, if the residual after cancellation
    /// stays a large fraction of the mic energy while the far-end is active, the extra energy
    /// is near-end speech — freeze adaptation (keep cancelling with the current filter).
    public var doubleTalkResidualRatio: Float

    public init(taps: Int = 768, mu: Float = 0.5, eps: Float = 1e-3,
                refEnergyFloor: Float = 1e-4, doubleTalkResidualRatio: Float = 0.5) {
        self.taps = taps
        self.mu = mu
        self.eps = eps
        self.refEnergyFloor = refEnergyFloor
        self.doubleTalkResidualRatio = doubleTalkResidualRatio
    }

    /// Estimates the bulk speaker→mic acoustic delay (samples) by finding the lag that
    /// maximises normalised cross-correlation between the mic and the reference over the first
    /// stretch where both carry energy. The adaptive filter is then aligned to this delay so a
    /// compact tap count covers the echo (plus room tail) instead of spanning empty lead time.
    public func estimateDelay(mic: [Float], reference: [Float],
                              maxLag: Int = 1920) -> Int {
        let n = min(mic.count, reference.count)
        guard n > maxLag + 16_000 else { return 0 }
        // Find the 1 s window carrying the MOST reference energy (strongest, cleanest echo).
        let win = 16_000
        var bestStart = -1
        var bestEnergy: Float = 0
        var i = 0
        while i + win + maxLag <= n {
            var e: Float = 0
            var k = i
            while k < i + win { e += reference[k] * reference[k]; k += 8 }
            if e > bestEnergy { bestEnergy = e; bestStart = i }
            i += win
        }
        guard bestStart >= 0, bestEnergy > 1e-3 else { return 0 }

        // Reference auto-energy over the window (constant across lags).
        var refEnergy: Float = 0
        var j = bestStart
        while j < bestStart + win { let r = reference[j]; refEnergy += r * r; j += 1 }
        guard refEnergy > 1e-6 else { return 0 }

        // Normalised cross-correlation vs lag; pick the peak |corr|.
        var bestLag = 0
        var best: Float = 0
        var lag = 0
        while lag < maxLag {
            var dot: Float = 0
            var micEnergy: Float = 0
            var m = bestStart
            while m < bestStart + win {
                let mi = mic[m + lag]
                dot += mi * reference[m]
                micEnergy += mi * mi
                m += 4
            }
            let denom = (micEnergy * refEnergy).squareRoot()
            let corr = denom > 1e-9 ? dot / denom : 0
            if abs(corr) > abs(best) { best = corr; bestLag = lag }
            lag += 4
        }
        return bestLag
    }

    /// Cleaned near-end (mic) signal. `mic` and `reference` must be the same 16 kHz timeline
    /// and sample-aligned (as they are in a stereo recording). Length = min of the two.
    /// A compact filter is aligned to the estimated echo delay so it converges quickly.
    public func process(mic: [Float], reference: [Float]) -> [Float] {
        let n = min(mic.count, reference.count)
        guard n > 0 else { return [] }
        let L = taps
        // Align the filter just ahead of the bulk echo delay so its taps sit over the echo
        // and its room tail (a little pre-margin catches early reflections).
        let d0 = estimateDelay(mic: mic, reference: reference)
        let base = max(0, d0 - 192)
        var w = [Float](repeating: 0, count: L)
        var out = [Float](repeating: 0, count: n)

        // Short-term energies for gating/DTD (~8 ms one-pole averages).
        let alpha: Float = 0.98
        var micPow: Float = 0
        var errPow: Float = 0
        // Converged once we've adapted over enough far-end-active samples.
        var adaptedSamples = 0
        let warmup = 3200   // ~0.2 s of far-end activity before trusting the DTD

        w.withUnsafeMutableBufferPointer { wp in
        reference.withUnsafeBufferPointer { rp in
        mic.withUnsafeBufferPointer { mp in
            for i in 0..<n {
                // Reference history for the echo at time i starts at (i - base): tap k reads
                // rp[i - base - k]. Only run once the whole tap window is in range.
                let top = i - base
                guard top >= 0 else { out[i] = mp[i]; continue }
                let kmax = min(L, top + 1)
                // y = wᵀ · x, and xnorm = xᵀx over the reference history window.
                var y: Float = 0
                var xnorm: Float = 0
                var k = 0
                while k < kmax {
                    let r = rp[top - k]
                    y += wp[k] * r
                    xnorm += r * r
                    k += 1
                }
                let e = mp[i] - y
                out[i] = e

                // Update running powers.
                let m = mp[i]
                micPow = alpha * micPow + (1 - alpha) * m * m
                errPow = alpha * errPow + (1 - alpha) * e * e

                // Only adapt when the far-end carries real energy (else there is no echo to
                // learn and the normalisation is meaningless).
                guard xnorm > refEnergyFloor else { continue }

                // Double-talk: after warmup, if the residual is still a big share of the mic
                // energy while the far-end is active, near-end speech is present → freeze.
                if adaptedSamples > warmup,
                   micPow > 0, errPow / micPow > doubleTalkResidualRatio {
                    continue
                }

                let g = mu * e / (xnorm + eps)
                var j = 0
                while j < kmax {
                    wp[j] += g * rp[top - j]
                    j += 1
                }
                adaptedSamples += 1
            }
        }}}
        return out
    }
}
