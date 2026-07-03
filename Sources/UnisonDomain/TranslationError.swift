import Foundation

public enum TranslationError: Error, Equatable, Sendable {
    case permissionDenied(PermissionKind)
    case blackHole2chMissing
    case apiKeyInvalid
    case rateLimited(retryAfter: TimeInterval)
    case insufficientCredits
    case networkLost
    case inputDeviceUnavailable
    case outputDeviceUnavailable
    /// Raised when the orchestrator has been in `.translating` for
    /// ~`noDataTimeoutSeconds` without receiving a single audio or
    /// transcript delta. Catches "session looks healthy but nothing
    /// is happening" — usually a silent microphone (Process Tap not
    /// capturing any output, or hardware mic level zero), but also
    /// surfaces server-side stalls. User feedback was specific:
    /// "если какие-то ошибки, нужно же падать с ошибкой" — this is
    /// what makes the failure mode visible.
    case noDataFromServer
    /// Raised by `SilentFrameWatchdog` when the peer audio stream
    /// delivers all-zero samples for longer than the watchdog
    /// threshold. The most likely cause is a TCC audio-capture denial
    /// — `AudioHardwareCreateProcessTap` succeeds but the IOProc
    /// receives silent buffers. There is no public API to query TCC
    /// state for Process Tap, so runtime amplitude monitoring is the
    /// only reliable detection mechanism.
    case audioCaptureDenied
    /// The provider announced it will close the session soon (Gemini
    /// Live `goAway` — session time limit / server maintenance). Not a
    /// failure of anything on our side: the orchestrator treats it as a
    /// non-terminal signal and swaps in a fresh stream immediately
    /// (zero reconnect backoff) instead of waiting for the socket to
    /// actually die mid-utterance.
    case serverGoingAway

    public var shortMessage: String {
        switch self {
        case .permissionDenied(.microphone): "Нет доступа к микрофону"
        case .blackHole2chMissing: "Не установлен BlackHole 2ch"
        case .apiKeyInvalid: "Неверный API ключ"
        case .rateLimited: "Лимит OpenAI"
        case .insufficientCredits: "Закончились средства"
        case .networkLost: "Нет соединения"
        case .inputDeviceUnavailable: "Микрофон недоступен"
        case .outputDeviceUnavailable: "Выход аудио недоступен"
        case .noDataFromServer: "Микрофон не подаёт сигнал"
        case .audioCaptureDenied: "Нет доступа к захвату системного звука"
        case .serverGoingAway: "Сервер закрыл сессию"
        }
    }
}

extension TranslationError: LocalizedError {
    public var errorDescription: String? { shortMessage }
}
