public struct Settings: Equatable, Codable, Sendable {
    public var sessionMode: SessionMode
    public var languagePair: LanguagePair
    public var inputDeviceUID: String?
    public var outputDeviceUID: String?
    public var excludedTapBundleIDs: [String]
    public var includedTapBundleIDs: [String]
    public var tapScopeMode: TapScopeMode
    public var translationModel: TranslationModel
    private var _originalMixVolume: Float

    public var originalMixVolume: Float {
        get { _originalMixVolume }
        set { _originalMixVolume = min(max(newValue, 0.0), 1.0) }
    }

    /// The app list that applies to the current mode.
    public var activeTapBundleIDs: [String] {
        tapScopeMode == .onlySelected ? includedTapBundleIDs : excludedTapBundleIDs
    }

    public init(
        sessionMode: SessionMode = .call,
        languagePair: LanguagePair = .default,
        inputDeviceUID: String? = nil,
        outputDeviceUID: String? = nil,
        excludedTapBundleIDs: [String] = [],
        includedTapBundleIDs: [String] = [],
        tapScopeMode: TapScopeMode = .allExcept,
        translationModel: TranslationModel = .openAIRealtime,
        originalMixVolume: Float = 0.2
    ) {
        self.sessionMode = sessionMode
        self.languagePair = languagePair
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        self.excludedTapBundleIDs = excludedTapBundleIDs
        self.includedTapBundleIDs = includedTapBundleIDs
        self.tapScopeMode = tapScopeMode
        self.translationModel = translationModel
        self._originalMixVolume = min(max(originalMixVolume, 0.0), 1.0)
    }

    public static let `default` = Settings()

    private enum CodingKeys: String, CodingKey {
        case sessionMode, languagePair, inputDeviceUID, outputDeviceUID
        case excludedTapBundleIDs, includedTapBundleIDs, tapScopeMode
        case translationModel
        case _originalMixVolume = "originalMixVolume"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionMode = try c.decode(SessionMode.self, forKey: .sessionMode)
        self.languagePair = try c.decode(LanguagePair.self, forKey: .languagePair)
        self.inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        self.outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        self.excludedTapBundleIDs = try c.decodeIfPresent([String].self,
                                                          forKey: .excludedTapBundleIDs) ?? []
        self.includedTapBundleIDs = try c.decodeIfPresent([String].self,
                                                          forKey: .includedTapBundleIDs) ?? []
        self.tapScopeMode = try c.decodeIfPresent(TapScopeMode.self,
                                                  forKey: .tapScopeMode) ?? .allExcept
        self.translationModel = try c.decodeIfPresent(TranslationModel.self,
                                                      forKey: .translationModel) ?? .openAIRealtime
        let raw = try c.decode(Float.self, forKey: ._originalMixVolume)
        self._originalMixVolume = min(max(raw, 0.0), 1.0)
    }
}
