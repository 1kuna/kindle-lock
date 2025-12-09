import ManagedSettingsUI
import ManagedSettings
import UIKit

/// Customizes the appearance of the shield screen shown when blocked apps are opened
class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    // MARK: - Application Shields

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        makeShieldConfiguration(
            subtitle: "Complete your daily reading goal to unlock this app."
        )
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        makeShieldConfiguration(
            subtitle: "Complete your daily reading goal to unlock this app."
        )
    }

    // MARK: - Web Domain Shields

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        makeShieldConfiguration(
            subtitle: "Complete your daily reading goal to access this website."
        )
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        makeShieldConfiguration(
            subtitle: "Complete your daily reading goal to access this website."
        )
    }

    // MARK: - Shield Configuration Builder

    private func makeShieldConfiguration(subtitle: String) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterial,
            backgroundColor: UIColor.systemBackground.withAlphaComponent(0.8),
            icon: UIImage(systemName: "book.closed.fill"),
            title: ShieldConfiguration.Label(
                text: "Read First!",
                color: UIColor.label
            ),
            subtitle: ShieldConfiguration.Label(
                text: subtitle,
                color: UIColor.secondaryLabel
            ),
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "Open Kindle",
                color: UIColor.white
            ),
            primaryButtonBackgroundColor: UIColor.systemGreen,
            secondaryButtonLabel: ShieldConfiguration.Label(
                text: "Check Progress",
                color: UIColor.systemBlue
            )
        )
    }
}
