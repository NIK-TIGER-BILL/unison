import Foundation

public enum TranslationError: Error, Equatable, Sendable {
    case permissionDenied(PermissionKind)
    case blackHole2chMissing
    case blackHole16chMissing
    case apiKeyInvalid
    case rateLimited(retryAfter: TimeInterval)
    case insufficientCredits
    case networkLost
    case inputDeviceUnavailable
    case outputDeviceUnavailable

    public var shortMessage: String {
        switch self {
        case .permissionDenied(.microphone): "Нет доступа к микрофону"
        case .blackHole2chMissing: "Не установлен BlackHole 2ch"
        case .blackHole16chMissing: "Не установлен BlackHole 16ch"
        case .apiKeyInvalid: "Неверный API ключ"
        case .rateLimited: "Лимит OpenAI"
        case .insufficientCredits: "Закончились средства"
        case .networkLost: "Нет соединения"
        case .inputDeviceUnavailable: "Микрофон недоступен"
        case .outputDeviceUnavailable: "Выход аудио недоступен"
        }
    }
}

extension TranslationError: LocalizedError {
    public var errorDescription: String? { shortMessage }
}
