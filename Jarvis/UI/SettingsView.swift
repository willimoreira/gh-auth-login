import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(JarvisAssistant.self) private var jarvis
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = jarvis.settings

        NavigationStack {
            Form {
                Section {
                    Picker("Modelo", selection: $settings.variant) {
                        ForEach(GemmaVariant.allCases) { variant in
                            VStack(alignment: .leading) {
                                Text(variant.displayName)
                                Text(variant.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(variant)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Núcleo cognitivo")
                } footer: {
                    Text("Roda 100% offline no iPhone via MLX. Trocar de modelo baixa os novos pesos uma única vez.")
                }

                Section("Personalidade") {
                    Picker("Idioma", selection: $settings.language) {
                        ForEach(JarvisLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Como devo chamá-lo?", text: $settings.honorific)
                    Toggle("Conversa contínua", isOn: $settings.continuousConversation)
                }

                Section {
                    Picker("Voz", selection: $settings.voiceIdentifier) {
                        Text("Automática (masculina)").tag("")
                        ForEach(VoiceSynthesizer.voices(for: settings.language), id: \.identifier) { voice in
                            Text("\(voice.name) · \(quality(voice))").tag(voice.identifier)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Velocidade da fala")
                        Slider(value: $settings.speechRate, in: 0.4...0.6)
                    }
                    Button("Testar voz") {
                        jarvis.voice.voiceIdentifier = settings.voiceIdentifier
                        jarvis.voice.language = settings.language
                        jarvis.voice.rate = settings.speechRate
                        jarvis.voice.speak(
                            settings.language == .portuguese
                                ? "Às suas ordens, \(settings.honorific). Todos os sistemas operacionais."
                                : "At your service, \(settings.honorific). All systems operational.")
                    }
                } header: {
                    Text("Voz")
                } footer: {
                    Text("Para uma voz mais próxima do filme, baixe vozes \"Aprimoradas\" ou \"Premium\" em Ajustes › Acessibilidade › Conteúdo Falado › Vozes (ex.: Daniel, inglês britânico).")
                }
            }
            .navigationTitle("Configurações")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        dismiss()
                        Task { await jarvis.settingsChanged() }
                    }
                }
            }
        }
        .tint(HUD.cyan)
        .preferredColorScheme(.dark)
        .onChange(of: settings.language) { _, _ in settings.voiceIdentifier = "" }
    }

    private func quality(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Aprimorada"
        default: "Padrão"
        }
    }
}
