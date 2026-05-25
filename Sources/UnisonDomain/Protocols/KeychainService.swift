public protocol KeychainService: Sendable {
    func loadAPIKey() -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAPIKey() throws
}
