import ManagedSettings
import FamilyControls

/// Manages app shields using ManagedSettings framework
@MainActor
final class ShieldManager {
    private let store = ManagedSettingsStore()

    /// Apply shields to the selected apps and categories
    func applyShields(to selection: FamilyActivitySelection) {
        let applications = selection.applicationTokens
        let categories = selection.categoryTokens
        let webDomains = selection.webDomainTokens

        // Shield specific applications
        store.shield.applications = applications.isEmpty ? nil : applications

        // Shield app categories
        if categories.isEmpty {
            store.shield.applicationCategories = nil
        } else {
            store.shield.applicationCategories = .specific(categories)
        }

        // Shield web domains
        store.shield.webDomains = webDomains.isEmpty ? nil : webDomains

        print("Shields applied: \(applications.count) apps, \(categories.count) categories, \(webDomains.count) domains")
    }

    /// Remove all shields
    func removeAllShields() {
        store.clearAllSettings()
        print("All shields removed")
    }

    /// Check if any shields are currently active
    var hasActiveShields: Bool {
        let hasApps = store.shield.applications != nil && !store.shield.applications!.isEmpty
        let hasCategories = store.shield.applicationCategories != nil
        let hasDomains = store.shield.webDomains != nil && !store.shield.webDomains!.isEmpty
        return hasApps || hasCategories || hasDomains
    }
}
