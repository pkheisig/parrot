import Foundation
import ServiceManagement

struct LaunchAtLoginManager {
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    var isRegistered: Bool {
        guard isAvailable else { return false }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    var statusMessage: String? {
        guard isAvailable else {
            return "Available when running Parrot.app"
        }
        if SMAppService.mainApp.status == .requiresApproval {
            return "Allow Parrot in System Settings › General › Login Items"
        }
        return nil
    }

    func setRegistered(_ registered: Bool) throws {
        guard isAvailable else {
            throw LaunchAtLoginError.appBundleRequired
        }
        if registered {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    case appBundleRequired

    var errorDescription: String? {
        switch self {
        case .appBundleRequired:
            "Launch at login requires Parrot.app."
        }
    }
}
