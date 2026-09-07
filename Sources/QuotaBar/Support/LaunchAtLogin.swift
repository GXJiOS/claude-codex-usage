import Foundation
import ServiceManagement

/// Registers the app itself as a login item. `SMAppService` needs no helper bundle
/// and no user approval dialog; the switch lands in System Settings › Login Items.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the state actually in effect afterwards, so a failed write cannot
    /// leave the UI showing a switch the system did not honour.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            // The app runs unsandboxed from /Applications; a failure here is worth surfacing
            // in the settings tab rather than crashing.
            return isEnabled
        }
        return isEnabled
    }
}
