import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Apple hosts and transfers the natural voice's asset pack, and the default
/// managed implementation schedules, updates and installs it. The pack is
/// on-demand: nothing downloads until she taps Download in Settings.
@main
struct HearfulBackgroundDownloadHandler: StoreDownloaderExtension {}
