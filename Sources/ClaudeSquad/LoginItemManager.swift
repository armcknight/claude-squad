import Foundation
import ServiceManagement

protocol LoginItemManagerProtocol: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

final class LoginItemManager: LoginItemManagerProtocol {
    private let appService = SMAppService.mainApp

    var isEnabled: Bool {
        appService.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try appService.register()
        } else {
            try appService.unregister()
        }
    }
}
