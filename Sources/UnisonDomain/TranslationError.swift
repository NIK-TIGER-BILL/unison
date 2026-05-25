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
    /// Raised when the orchestrator has been in `.translating` for
    /// ~`noDataTimeoutSeconds` without receiving a single audio or
    /// transcript delta. Catches "session looks healthy but nothing
    /// is happening" — usually a silent microphone (no system audio
    /// routed to BlackHole 16ch, or hardware mic level zero), but
    /// also surfaces server-side stalls. User feedback was specific:
    /// "если какие-то ошибки, нужно же падать с ошибкой" — this is
    /// what makes the failure mode visible.
    case noDataFromServer

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
        case .noDataFromServer: "Микрофон не подаёт сигнал"
        }
    }
}

extension TranslationError: LocalizedError {
    public var errorDescription: String? { shortMessage }
}
