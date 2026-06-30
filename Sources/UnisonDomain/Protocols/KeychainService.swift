public protocol KeychainService: Sendable {
    func loadAPIKey(for model: TranslationModel) -> String?
    func saveAPIKey(_ key: String, for model: TranslationModel) throws
    func deleteAPIKey(for model: TranslationModel) throws
}
