import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Baixa (uma única vez), carrega e conversa com o Gemma 4 rodando localmente via MLX (GPU/Metal).
@MainActor
@Observable
final class GemmaEngine {

    enum Status: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var loadedVariant: GemmaVariant?

    private var container: ModelContainer?
    private var session: ChatSession?
    private var instructions = ""

    var isReady: Bool { status == .ready }

    func load(_ variant: GemmaVariant, instructions: String) async {
        if loadedVariant == variant, container != nil {
            resetConversation(instructions: instructions)
            return
        }

        container = nil
        session = nil
        loadedVariant = nil
        self.instructions = instructions

        // Mantém o cache de buffers da GPU pequeno para não estourar a RAM do iPhone.
        Memory.cacheLimit = 32 * 1024 * 1024
        status = .downloading(0)

        do {
            let container = try await #huggingFaceLoadModelContainer(
                configuration: variant.configuration
            ) { progress in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.status else { return }
                    let fraction = progress.fractionCompleted
                    self.status = fraction >= 0.999 ? .loading : .downloading(fraction)
                }
            }
            self.container = container
            self.loadedVariant = variant
            resetConversation(instructions: instructions)
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Começa uma nova conversa (limpa a memória de curto prazo / KV cache).
    func resetConversation(instructions: String? = nil) {
        if let instructions { self.instructions = instructions }
        guard let container else { return }
        session = ChatSession(
            container,
            instructions: self.instructions,
            generateParameters: GenerateParameters(
                maxTokens: 400,
                maxKVSize: 4096,
                temperature: 0.7,
                topP: 0.95,
                repetitionPenalty: 1.05
            )
        )
    }

    /// Gera a resposta em streaming, pedaço a pedaço.
    func stream(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        guard let session else {
            return AsyncThrowingStream { $0.finish(throwing: JarvisError.modelNotReady) }
        }
        return session.streamResponse(to: prompt)
    }
}

enum JarvisError: LocalizedError {
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case .modelNotReady: "O modelo Gemma ainda não foi carregado."
        }
    }
}
