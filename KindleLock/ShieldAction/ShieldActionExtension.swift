import ManagedSettingsUI
import ManagedSettings

/// Handles button taps on the shield screen
class ShieldActionExtension: ShieldActionDelegate {

    // MARK: - Application Shield Actions

    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        handleAction(action, completionHandler: completionHandler)
    }

    // MARK: - Web Domain Shield Actions

    override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        handleAction(action, completionHandler: completionHandler)
    }

    // MARK: - Action Handler

    private func handleAction(
        _ action: ShieldAction,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            // Open Kindle app
            // Note: Extensions can't directly open URLs, so we defer to the system
            // The user will need to manually open Kindle or the main app
            completionHandler(.defer)

        case .secondaryButtonPressed:
            // Open main KindleLock app to check progress
            // Similarly, we defer to let the user navigate
            completionHandler(.defer)

        @unknown default:
            completionHandler(.close)
        }
    }
}
