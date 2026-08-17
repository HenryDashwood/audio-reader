import Foundation

/// Whether this process is a test run.
///
/// The app makes sound on purpose — the voice reading an article, the cues
/// marking that a tap registered — and in a test that sound comes out of the
/// machine's speakers for real. So the defaults behind both consult this and
/// hand back something silent, which means a test has to opt in to noise
/// rather than remember to opt out of it.
///
/// Deliberately the only place the check lives: scattered test detection is
/// how production behaviour starts quietly differing under test.
enum TestEnvironment {
    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        // Xcode sets these for the test host; the class check covers a test
        // bundle loaded some other way.
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()
}
