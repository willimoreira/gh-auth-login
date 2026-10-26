import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import UIKit

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
    /// Bytes já baixados e total esperado, para mostrar "1,4 de 3,6 GB".
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0

    private var container: ModelContainer?
    private var session: ChatSession?
    private var instructions = ""

    /// Ferramentas do assistente executivo (agenda, e-mail, mensagens…).
    var tools: ExecutiveTools?

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
        downloadedBytes = 0
        totalBytes = variant.downloadBytes

        removeStalePartialDownloads()

        // Se a tela bloquear, o iOS congela o download: mantém a tela acesa até terminar.
        UIApplication.shared.isIdleTimerDisabled = true
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.measureDownload(variant)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer {
            monitor.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }

        do {
            let container = try await #huggingFaceLoadModelContainer(
                configuration: variant.configuration
            ) { progress in
                Task { @MainActor [weak self] in
                    self?.report(progress.fractionCompleted)
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

    /// Atualiza o progresso só para frente (duas fontes: a biblioteca e a medição em disco).
    private func report(_ fraction: Double) {
        guard case .downloading(let current) = status else { return }
        if fraction >= 0.999 {
            status = .loading
        } else if fraction > current {
            status = .downloading(fraction)
        }
    }

    /// Downloads interrompidos deixam arquivos parciais que não são retomados; apaga antes de começar.
    private func removeStalePartialDownloads() {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let files = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("CFNetworkDownload") {
            try? fm.removeItem(at: file)
        }
    }

    /// A biblioteca de download não informa o progresso do arquivo grande de pesos,
    /// então medimos o que já chegou no disco (arquivos temporários + cache do Hugging Face).
    private func measureDownload(_ variant: GemmaVariant) {
        guard case .downloading = status else { return }
        let fm = FileManager.default
        var bytes: Int64 = 0

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        if let files = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files where file.lastPathComponent.hasPrefix("CFNetworkDownload") {
                bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }

        let repo = "models--" + variant.configuration.name.replacingOccurrences(of: "/", with: "--")
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let blobs = caches.appendingPathComponent("huggingface/hub/\(repo)/blobs")
            if let files = try? fm.contentsOfDirectory(at: blobs, includingPropertiesForKeys: [.fileSizeKey]) {
                for file in files {
                    bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
        }

        downloadedBytes = min(bytes, totalBytes)
        report(min(Double(bytes) / Double(max(totalBytes, 1)), 0.99))
    }

    /// Começa uma nova conversa (limpa a memória de curto prazo / KV cache).
    func resetConversation(instructions: String? = nil) {
        if let instructions { self.instructions = instructions }
        guard let container else { return }
        var dispatch: (@Sendable (ToolCall) async throws -> String)?
        if let tools {
            dispatch = { call in await tools.dispatch(call) }
        }
        session = ChatSession(
            container,
            instructions: self.instructions,
            generateParameters: GenerateParameters(
                maxTokens: 600,
                maxKVSize: 8192,
                temperature: 0.6,
                topP: 0.95,
                repetitionPenalty: 1.05
            ),
            tools: tools?.specs,
            toolDispatch: dispatch
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
