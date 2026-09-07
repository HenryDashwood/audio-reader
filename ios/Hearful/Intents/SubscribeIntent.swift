import AppIntents

struct SubscribeIntent: AppIntent {
    static let title: LocalizedStringResource = "Follow a Show or Publication"
    static let description = IntentDescription(
        "Finds and follows a podcast, blog or newsletter by name, asking for detail when needed.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    @Parameter(
        title: "Show or publication",
        requestValueDialog: "Which show or publication would you like to follow?") var name: String
    static var parameterSummary: some ParameterSummary { Summary("Follow \(\.$name)") }
    init() {}
    init(name: String) { self.name = name }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MagpieRequestResult> & ProvidesDialog {
        let result = try await ShortcutConversation.run(
            "Follow \(name)",
            clarify: { try await $name.requestValue(IntentDialog("\($0)")) },
            foreground: { try await continueInForeground(IntentDialog("\($0)")) })
        return .result(value: result, dialog: IntentDialog("\(result.summary)"))
    }
}
