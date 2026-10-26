import AVFoundation

/// Voz do J.A.R.V.I.S.: transforma cada frase em áudio (voz neural Kokoro ou voz do sistema),
/// passa pela cadeia de efeitos de IA e toca na ordem, enquanto o Gemma ainda está gerando.
@MainActor
@Observable
final class VoiceSynthesizer {

    enum Engine: String, CaseIterable, Identifiable {
        case system
        case neural

        var id: String { rawValue }
    }

    private(set) var isSpeaking = false
    /// Nível real do áudio tocado (0...1) — anima o reator.
    private(set) var level: Float = 0

    var voiceIdentifier = ""
    var language: JarvisLanguage = .portuguese
    var rate: Float = 0.52
    var engine: Engine = .system
    var neuralVoiceID = "bm_george"
    var aiEffect = true {
        didSet { output.effectEnabled = aiEffect }
    }

    /// Chamado quando a fila de falas termina.
    var onFinishedSpeaking: (@MainActor () -> Void)?

    let neural = NeuralVoice()

    private let output = VoiceOutput()
    /// Usado só para *gerar* o áudio (write); quem toca é a `VoiceOutput`, com efeitos.
    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var worker: Task<Void, Never>?

    init() {
        output.onLevel = { [weak self] in self?.level = $0 }
        output.onDrained = { [weak self] in self?.finishIfIdle() }
    }

    /// A voz neural só é usada em inglês (o Kokoro não fala português).
    var usesNeural: Bool { engine == .neural && language == .english }

    func speak(_ text: String) {
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        queue.append(clean)
        isSpeaking = true
        if worker == nil {
            worker = Task { [weak self] in await self?.drainQueue() }
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        queue.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        output.stop()
        isSpeaking = false
        level = 0
    }

    /// Pré-carrega a voz neural para a primeira fala não demorar.
    func warmUp() {
        guard usesNeural else { return }
        Task { await neural.prepare(voice: neuralVoiceID, retry: true) }
    }

    // MARK: Fila

    /// Gera o áudio de uma frase enquanto a anterior ainda está tocando.
    private func drainQueue() async {
        while !queue.isEmpty {
            let text = queue.removeFirst()
            let buffers = await render(text)
            if Task.isCancelled { return }
            buffers.forEach(output.play)
            // Respiro curto entre frases, como numa fala de verdade.
            if !buffers.isEmpty, let pause = Self.silence(seconds: 0.18) { output.play(pause) }
        }
        // Uma tarefa cancelada não pode mexer no estado da que a substituiu.
        guard !Task.isCancelled else { return }
        worker = nil
        finishIfIdle()
    }

    private func finishIfIdle() {
        guard isSpeaking, worker == nil, queue.isEmpty, !output.isBusy else { return }
        isSpeaking = false
        level = 0
        onFinishedSpeaking?()
    }

    private func render(_ text: String) async -> [AVAudioPCMBuffer] {
        if usesNeural, await neural.prepare(voice: neuralVoiceID) {
            do {
                let speech = try await neural.synthesize(text, voice: neuralVoiceID, speed: neuralSpeed)
                if let buffer = VoiceOutput.buffer(samples: speech.samples, sampleRate: speech.sampleRate) {
                    return [buffer]
                }
            } catch {
                print("Voz neural falhou, usando a do sistema: \(error)")
            }
        }
        return await renderSystem(text)
    }

    /// Velocidade do Kokoro equivalente ao controle deslizante (0,4–0,6 → ~0,7–1,1).
    private var neuralSpeed: Float { 0.9 + (rate - 0.5) * 2 }

    // MARK: Voz do sistema

    private func renderSystem(_ text: String) async -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = systemVoice()
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0

        let collector = BufferCollector()
        return await withCheckedContinuation { continuation in
            collector.continuation = continuation
            synthesizer.write(utterance, toBufferCallback: Self.makeWriteCallback(collector))
            // Rede de segurança: se o sistema nunca sinalizar o fim, não trava a conversa.
            Task {
                try? await Task.sleep(for: .seconds(20))
                collector.finish()
            }
        }
    }

    nonisolated private static func makeWriteCallback(
        _ collector: BufferCollector
    ) -> AVSpeechSynthesizer.BufferCallback {
        { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                collector.finish()  // buffer vazio = fim da fala
                return
            }
            collector.append(pcm)
        }
    }

    static func silence(seconds: Double) -> AVAudioPCMBuffer? {
        let format = AudioLevel.voiceFormat
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            channel.initialize(repeating: 0, count: Int(frames))
        }
        return buffer
    }

    /// Vozes instaladas para o idioma, das de maior qualidade para as de menor.
    static func voices(for language: JarvisLanguage) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language.rawValue }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    private func systemVoice() -> AVSpeechSynthesisVoice? {
        if !voiceIdentifier.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return chosen
        }
        // Qualidade primeiro (Premium > Aprimorada > Padrão): é o que mais deixa a fala natural.
        // Dentro da melhor qualidade instalada, prefira voz masculina, como a do Jarvis.
        let candidates = Self.voices(for: language)
        guard let best = candidates.first?.quality else {
            return AVSpeechSynthesisVoice(language: language.rawValue)
        }
        let top = candidates.filter { $0.quality == best }
        let preferredNames = ["Daniel", "Arthur", "Felipe", "Eddy", "Reed"]
        return top.first(where: { preferredNames.contains($0.name) && $0.gender == .male })
            ?? top.first(where: { $0.gender == .male })
            ?? top.first
    }

    // MARK: Texto

    /// Remove markdown/emojis que soariam estranhos quando falados.
    static func speakable(_ text: String) -> String {
        var s = text
        for token in ["**", "__", "`", "#", "*", "_", "•"] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        s = String(s.unicodeScalars.filter { !($0.properties.isEmojiPresentation) })
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Junta os buffers que o AVSpeechSynthesizer entrega (numa thread de áudio)
/// e devolve todos de uma vez, uma única vez.
private final class BufferCollector: @unchecked Sendable {
    var continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>?

    private let lock = NSLock()
    private let converter = PCMConverter()
    private var buffers: [AVAudioPCMBuffer] = []
    private var finished = false

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let converted = converter.convert(buffer) else { return }
        buffers.append(converted)
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let result = buffers
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
