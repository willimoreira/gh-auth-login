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

                Section {
                    NavigationLink {
                        AccountsView()
                    } label: {
                        Label("Contas de e-mail", systemImage: "envelope.badge.person.crop")
                    }
                } header: {
                    Text("Assistente executivo")
                } footer: {
                    Text("Agenda, lembretes e contatos do iPhone já funcionam. Conecte Gmail, Outlook ou iCloud para e-mails.")
                }

                Section("Personalidade") {
                    Picker("Idioma", selection: $settings.language) {
                        ForEach(JarvisLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Como devo chamá-lo?", text: $settings.honorific)
                    Toggle("Conversa contínua", isOn: $settings.continuousConversation)
                    Toggle("Sempre ativo (chamar \"Jarvis\")", isOn: $settings.alwaysOn)
                    Toggle("Avisos proativos", isOn: $settings.proactive)
                }

                Section {
                    Picker("Motor de voz", selection: $settings.voiceEngine) {
                        Text("Sistema (iPhone)").tag(VoiceSynthesizer.Engine.system)
                        Text("Neural Kokoro · beta").tag(VoiceSynthesizer.Engine.neural)
                    }
                    if settings.voiceEngine == .neural {
                        Picker("Voz britânica", selection: $settings.neuralVoice) {
                            ForEach(NeuralVoice.britishVoices, id: \.id) { voice in
                                Text(voice.name).tag(voice.id)
                            }
                        }
                        neuralStatus
                    }
                    Toggle("Efeito de IA na voz", isOn: $settings.aiVoiceEffect)
                } header: {
                    Text("Timbre")
                } footer: {
                    Text(
                        settings.language == .english
                            ? "A voz neural roda no iPhone (Core ML) e soa bem mais humana; baixa o modelo na primeira vez. É experimental: se der problema, volte para Sistema."
                            : "A voz neural só fala inglês: com o idioma em português o Jarvis usa a voz do sistema. O efeito de IA funciona com qualquer voz."
                    )
                }

                Section {
                    Picker("Voz do sistema", selection: $settings.voiceIdentifier) {
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
                        jarvis.voice.stop()
                        jarvis.applyVoiceSettings()
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

    @ViewBuilder
    private var neuralStatus: some View {
        switch jarvis.voice.neural.status {
        case .idle:
            Text("Será baixada ao testar ou ao falar.").font(.caption).foregroundStyle(.secondary)
        case .loading:
            HStack {
                ProgressView()
                Text("Baixando e preparando a voz neural…").font(.caption)
            }
        case .ready:
            Label("Voz neural pronta", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text("Falhou: \(message). Usando a voz do sistema.")
                .font(.caption).foregroundStyle(.red)
        }
    }

    private func quality(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Aprimorada"
        default: "Padrão"
        }
    }
}
