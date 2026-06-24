public struct Settings: Equatable, Codable, Sendable {
    public var sessionMode: SessionMode
    public var languagePair: LanguagePair
    public var inputDeviceUID: String?
    public var outputDeviceUID: String?
    public var excludedTapBundleIDs: [String]
    private var _originalMixVolume: Float
    public var saveHistoryEnabled: Bool
    public var historySizeLimitMB: Int

    public var originalMixVolume: Float {
        get { _originalMixVolume }
        set { _originalMixVolume = min(max(newValue, 0.0), 1.0) }
    }

    public init(
        sessionMode: SessionMode = .call,
        languagePair: LanguagePair = .default,
        inputDeviceUID: String? = nil,
        outputDeviceUID: String? = nil,
        excludedTapBundleIDs: [String] = [],
        originalMixVolume: Float = 0.2,
        saveHistoryEnabled: Bool = true,
        historySizeLimitMB: Int = 50
    ) {
        self.sessionMode = sessionMode
        self.languagePair = languagePair
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        self.excludedTapBundleIDs = excludedTapBundleIDs
        self._originalMixVolume = min(max(originalMixVolume, 0.0), 1.0)
        self.saveHistoryEnabled = saveHistoryEnabled
        self.historySizeLimitMB = historySizeLimitMB
    }

    public static let `default` = Settings()

    private enum CodingKeys: String, CodingKey {
        case sessionMode, languagePair, inputDeviceUID, outputDeviceUID
        case excludedTapBundleIDs
        case _originalMixVolume = "originalMixVolume"
        case saveHistoryEnabled, historySizeLimitMB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionMode = try c.decode(SessionMode.self, forKey: .sessionMode)
        self.languagePair = try c.decode(LanguagePair.self, forKey: .languagePair)
        self.inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        self.outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        self.excludedTapBundleIDs = try c.decodeIfPresent([String].self,
                                                          forKey: .excludedTapBundleIDs) ?? []
        let raw = try c.decode(Float.self, forKey: ._originalMixVolume)
        self._originalMixVolume = min(max(raw, 0.0), 1.0)
        self.saveHistoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .saveHistoryEnabled) ?? true
        self.historySizeLimitMB = try c.decodeIfPresent(Int.self, forKey: .historySizeLimitMB) ?? 50
    }
}
