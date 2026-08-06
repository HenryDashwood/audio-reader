import Testing

@testable import Hearful

// Proves the test target is wired to the app target and can see its types.
// Real tests arrive with the networking and speech layers.
@Test func appTargetIsImportable() {
    _ = ContentView()
}
