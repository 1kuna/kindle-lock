import ManagedSettingsUI
import ManagedSettings
import UIKit

/// Customizes the appearance of the shield screen shown when blocked apps are opened
class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    // MARK: - Application Shields

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        makeShieldConfiguration(isWebDomain: false)
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        makeShieldConfiguration(isWebDomain: false)
    }

    // MARK: - Web Domain Shields

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        makeShieldConfiguration(isWebDomain: true)
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        makeShieldConfiguration(isWebDomain: true)
    }

    // MARK: - Shield Configuration Builder

    private func makeShieldConfiguration(isWebDomain: Bool) -> ShieldConfiguration {
        let progress = ProgressReader.readCachedProgress()
        let subtitle = buildSubtitle(progress: progress, isWebDomain: isWebDomain)

        return ShieldConfiguration(
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

    private func buildSubtitle(progress: ShieldTodayProgress?, isWebDomain: Bool) -> String {
        let baseText = isWebDomain
            ? "Complete your daily reading goal to access this website."
            : "Complete your daily reading goal to unlock this app."

        guard let progress = progress else {
            return baseText
        }

        // Format: "3.2% of 5% goal"
        let readFormatted = String(format: "%.1f", progress.percentageRead)
        let goalFormatted = String(format: "%.0f", progress.percentageGoal)
        let progressText = "\(readFormatted)% of \(goalFormatted)% goal"

        return "\(progressText)\n\(baseText)"
    }
}
