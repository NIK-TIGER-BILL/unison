import Foundation
import ServiceManagement
import UnisonDomain

/// Bridges the «Запускать при логине» toggle to `SMAppService`. Lives in
/// `UnisonApp` because ServiceManagement must stay out of `UnisonUI`.
///
/// Errors are logged, not surfaced: the common failure is running from
/// `swift run` (no .app bundle — SMAppService requires one), which is a
/// dev-only situation. The System Settings "Login Items" pane remains
/// the user-visible source of truth either way.
enum LoginItemService {
    private static let log = UnisonLog(category: "LoginItem")

    static func apply(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                log.info("login item registered (status=\(String(describing: SMAppService.mainApp.status)))")
            } else {
                try SMAppService.mainApp.unregister()
                log.info("login item unregistered")
            }
        } catch {
            log.error("login item \(enabled ? "register" : "unregister") failed: \(String(describing: error)) — likely not running from an .app bundle")
        }
    }
}
