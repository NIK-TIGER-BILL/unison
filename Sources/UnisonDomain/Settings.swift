public struct Settings: Equatable, Codable, Sendable {
    public var sessionMode: SessionMode
    public var languagePair: LanguagePair
    public var inputDeviceUID: String?
    public var outputDeviceUID: String?
    private var _originalMixVolume: Float

    public var originalMixVolume: Float {
        get { _originalMixVolume }
        set { _originalMixVolume = min(max(newValue, 0.0), 1.0) }
    }

    public init(
        sessionMode: SessionMode = .call,
        languagePair: LanguagePair = .default,
        inputDeviceUID: String? = nil,
        outputDeviceUID: String? = nil,
        originalMixVolume: Float = 0.2
    ) {
        self.sessionMode = sessionMode
        self.languagePair = languagePair
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        self._originalMixVolume = min(max(originalMixVolume, 0.0), 1.0)
    }

    public static let `default` = Settings()

    private enum CodingKeys: String, CodingKey {
        case sessionMode, languagePair, inputDeviceUID, outputDeviceUID
        case _originalMixVolume = "originalMixVolume"
    }
}
