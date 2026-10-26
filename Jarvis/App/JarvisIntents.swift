import AppIntents

/// "E aí Siri, falar com o Jarvis" — também pode ir no botão de Ação do iPhone.
struct TalkToJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Falar com o Jarvis"
    static let description = IntentDescription("Abre o J.A.R.V.I.S. já ouvindo o seu comando.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        JarvisAssistant.current?.requestListening()
        return .result()
    }
}

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToJarvisIntent(),
            phrases: [
                "Falar com o \(.applicationName)",
                "Chamar o \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Falar com o Jarvis",
            systemImageName: "waveform.circle"
        )
    }
}
