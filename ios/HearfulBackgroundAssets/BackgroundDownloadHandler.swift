import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Apple hosts and transfers the asset pack; the default managed implementation
/// handles scheduling, updates and installation. The app explicitly requests
/// the on-demand pack after the user taps Download in Settings.
@main
struct HearfulBackgroundDownloadHandler: StoreDownloaderExtension {}
