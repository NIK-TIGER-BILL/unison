import Testing
@testable import UnisonAudio

@Test func erle_halfAmplitudeResidual_isAboutSixDB() {
    let near = [Float](repeating: 0.4, count: 1000)
    let residual = [Float](repeating: 0.2, count: 1000)   // half → ~6.02 dB
    let erle = EchoMetrics.erleDB(reference: near, residual: residual)
    #expect(abs(erle - 6.02) < 0.1)
}

@Test func erle_silentResidual_isLargePositive() {
    let near = [Float](repeating: 0.4, count: 1000)
    let residual = [Float](repeating: 0, count: 1000)
    #expect(EchoMetrics.erleDB(reference: near, residual: residual) > 60)
}
