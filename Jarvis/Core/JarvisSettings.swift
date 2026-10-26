import Foundation
import MLXLLM
import MLXLMCommon

/// Variantes do Gemma 4 que cabem num iPhone (pesos 4-bit, rodando 100% no aparelho via MLX).
enum GemmaVariant: String, CaseIterable, Identifiable {
    case e2b
    case e4b

    var id: String { rawValue }

    var configuration: ModelConfiguration {
        switch self {
        case .e2b: LLMRegistry.gemma4_e2b_it_4bit
        case .e4b: LLMRegistry.gemma4_e4b_it_4bit
        }
    }

    var displayName: String {
        switch self {
        case .e2b: "Gemma 4 E2B"
        case .e4b: "Gemma 4 E4B"
        }
    }

    var detail: String {
        switch self {
        case .e2b: "~3,6 GB · rápido · recomendado para a maioria dos iPhones"
        case .e4b: "~5 GB · mais inteligente · iPhone 15 Pro / 16 Pro / 17 (8 GB RAM)"
        }
    }
}

enum JarvisLanguage: String, CaseIterable, Identifiable {
    case portuguese = "pt-BR"
    case english = "en-GB"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    var displayName: String {
        switch self {
        case .portuguese: "Português (Brasil)"
        case .english: "English (British — clássico)"
        }
    }
}

/// Preferências persistidas em UserDefaults.
@Observable
final class JarvisSettings {
    private let defaults = UserDefaults.standard

    var variant: GemmaVariant {
        didSet { defaults.set(variant.rawValue, forKey: "variant") }
    }
    var language: JarvisLanguage {
        didSet { defaults.set(language.rawValue, forKey: "language") }
    }
    /// Identificador da voz do AVSpeechSynthesizer; vazio = escolha automática.
    var voiceIdentifier: String {
        didSet { defaults.set(voiceIdentifier, forKey: "voice") }
    }
    /// Como o Jarvis chama você ("senhor", "Sr. Moreira", ...).
    var honorific: String {
        didSet { defaults.set(honorific, forKey: "honorific") }
    }
    /// Volta a ouvir automaticamente depois de responder.
    var continuousConversation: Bool {
        didSet { defaults.set(continuousConversation, forKey: "continuous") }
    }
    var speechRate: Float {
        didSet { defaults.set(speechRate, forKey: "rate") }
    }
    /// Motor de voz: do sistema (todas as línguas) ou neural Kokoro (só inglês).
    var voiceEngine: VoiceSynthesizer.Engine {
        didSet { defaults.set(voiceEngine.rawValue, forKey: "voiceEngine") }
    }
    /// Voz britânica do Kokoro ("bm_george", "bm_daniel", ...).
    var neuralVoice: String {
        didSet { defaults.set(neuralVoice, forKey: "neuralVoice") }
    }
    /// Efeito de IA (EQ + timbre metálico + ambiente) aplicado à voz.
    var aiVoiceEffect: Bool {
        didSet { defaults.set(aiVoiceEffect, forKey: "aiEffect") }
    }

    init() {
        variant = GemmaVariant(rawValue: defaults.string(forKey: "variant") ?? "") ?? .e2b
        language = JarvisLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .portuguese
        voiceIdentifier = defaults.string(forKey: "voice") ?? ""
        honorific = defaults.string(forKey: "honorific") ?? "senhor"
        continuousConversation = defaults.object(forKey: "continuous") as? Bool ?? true
        speechRate = defaults.object(forKey: "rate") as? Float ?? 0.52
        voiceEngine =
            VoiceSynthesizer.Engine(rawValue: defaults.string(forKey: "voiceEngine") ?? "") ?? .system
        neuralVoice = defaults.string(forKey: "neuralVoice") ?? "bm_george"
        aiVoiceEffect = defaults.object(forKey: "aiEffect") as? Bool ?? true
    }
}
