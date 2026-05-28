import Testing
@testable import UnisonDomain

@Test func translationError_isLocalizedError() {
    let err: any Error = TranslationError.apiKeyInvalid
    #expect(err.localizedDescription.isEmpty == false)
}

@Test func translationError_equality() {
    #expect(TranslationError.networkLost == .networkLost)
    #expect(TranslationError.rateLimited(retryAfter: 5) == .rateLimited(retryAfter: 5))
    #expect(TranslationError.rateLimited(retryAfter: 5) != .rateLimited(retryAfter: 10))
}

@Test func translationError_userFacingMessage_isShort() {
    let allCases: [TranslationError] = [
        .permissionDenied(.microphone), .blackHole2chMissing,
        .apiKeyInvalid, .rateLimited(retryAfter: 5), .insufficientCredits,
        .networkLost, .inputDeviceUnavailable, .outputDeviceUnavailable,
        .audioCaptureDenied
    ]
    for err in allCases {
        #expect(err.shortMessage.count < 60, "Message too long: \(err.shortMessage)")
    }
}
