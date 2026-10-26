import FluidAudio
import Foundation

/// Voz neural Kokoro-82M rodando no iPhone via Core ML (pacote FluidAudio).
/// Muito mais natural que as vozes padrão do sistema; tem vozes masculinas britânicas.
/// O Kokoro só fala inglês — em português o app volta para a voz do sistema.
@MainActor
@Observable
final class NeuralVoice {

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// Vozes masculinas britânicas do Kokoro, as mais próximas de um mordomo inglês.
    static let britishVoices: [(id: String, name: String)] = [
        ("bm_george", "George"),
        ("bm_daniel", "Daniel"),
        ("bm_lewis", "Lewis"),
        ("bm_fable", "Fable"),
    ]

    private(set) var status: Status = .idle

    private var manager: KokoroAneManager?
    private var loading: Task<KokoroAneManager, Error>?

    /// Baixa (na primeira vez) e carrega o modelo e a voz. Retorna se ficou pronto.
    /// Depois de uma falha só tenta de novo com `retry` (para não travar cada frase).
    @discardableResult
    func prepare(voice: String, retry: Bool = false) async -> Bool {
        if manager != nil { return true }
        if case .failed = status, !retry { return false }
        let task: Task<KokoroAneManager, Error>
        if let loading {
            task = loading
        } else {
            status = .loading
            task = Task {
                let manager = KokoroAneManager(variant: .english, defaultVoice: voice)
                try await manager.initialize(preloadVoices: [voice])
                return manager
            }
            loading = task
        }
        do {
            manager = try await task.value
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
        loading = nil
        return manager != nil
    }

    /// Gera a fala (amostras float mono) para um trecho de texto.
    func synthesize(_ text: String, voice: String, speed: Float) async throws -> (
        samples: [Float], sampleRate: Int
    ) {
        guard let manager else { throw NeuralVoiceError.notReady }
        let result = try await manager.synthesizeDetailed(text: text, voice: voice, speed: speed)
        return (result.samples, result.sampleRate)
    }
}

enum NeuralVoiceError: LocalizedError {
    case notReady

    var errorDescription: String? { "A voz neural ainda não foi carregada." }
}
