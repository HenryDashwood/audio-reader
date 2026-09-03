import Foundation

/// The screen to open when the app is launched for an App Store screenshot.
///
/// Injecting taps into a simulator is not something the capture script can
/// rely on, so the screenshot flow names the screen instead:
///
///     SIMCTL_CHILD_HEARFUL_SCREENSHOT_SCREEN=show:4 \
///       xcrun simctl launch <udid> com.henrydashwood.hearful
///
/// Debug builds only, like the canned transcript: a release build never
/// reads the variable, so nothing shipped can be steered this way.
/// nonisolated: the input is immutable process-wide runtime metadata.
nonisolated enum ScreenshotRoute {
    enum Screen: Equatable, Sendable {
        case following
        case latest
        case settings
        /// A followed show's page, by the id the API gives it.
        case show(id: Int)
        /// An article open for reading, by episode id, from Latest.
        case article(episodeID: Int)
    }

    static let requested: Screen? = {
        #if DEBUG
            parse(ProcessInfo.processInfo.environment["HEARFUL_SCREENSHOT_SCREEN"])
        #else
            nil
        #endif
    }()

    static func parse(_ value: String?) -> Screen? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else {
            return nil
        }
        switch value {
        case "following": return .following
        case "latest": return .latest
        case "settings": return .settings
        default: break
        }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = Int(parts[1]), id > 0 else { return nil }
        switch parts[0] {
        case "show": return .show(id: id)
        case "article": return .article(episodeID: id)
        default: return nil
        }
    }
}
