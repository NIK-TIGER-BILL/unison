import Foundation

/// Echo-cancellation quality metrics, shared by tests and the aec-eval CLI.
public enum EchoMetrics {
    /// Echo Return Loss Enhancement in dB: how much the residual is below
    /// the reference, in RMS terms. Higher is better. A silent residual is
    /// clamped to a large finite value so callers don't get +inf.
    public static func erleDB(reference: [Float], residual: [Float]) -> Double {
        let refRMS = rms(reference)
        let resRMS = rms(residual)
        guard refRMS > 1e-9 else { return 0 }
        guard resRMS > 1e-9 else { return 120 }
        return 20.0 * log10(Double(refRMS) / Double(resRMS))
    }

    public static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        return (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
    }
}
