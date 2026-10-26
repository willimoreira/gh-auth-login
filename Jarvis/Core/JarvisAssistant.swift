import SwiftUI

/// Orquestra o ciclo: ouvir → pensar (Gemma 4) → falar.
@MainActor
@Observable
final class JarvisAssistant {

    enum Mode: Equatable {
        case offline      // modelo ainda não carregado
        case idle
        case listening
        case thinking
        case speaking
    }

    struct Line: Identifiable, Equatable {
        enum Speaker { case user, jarvis, system }
        let id = UUID()
        let speaker: Speaker
        var text: String
    }

    let settings = JarvisSettings()
    let engine = GemmaEngine()
    let ears = SpeechRecognizer()
    let voice = VoiceSynthesizer()

    private(set) var mode: Mode = .offline
    private(set) var lines: [Line] = []
    private(set) var permissionsGranted = false

    private var generation: Task<Void, Never>?
    private var greeted = false

    /// Energia 0...1 usada pela animação do reator, conforme o estado.
    var energy: Float {
        switch mode {
        case .listening: ears.level
        case .speaking: max(voice.level, 0.15)
        case .thinking: 0.35
        default: 0
        }
    }

    init() {
        voice.onFinishedSpeaking = { [weak self] in self?.didFinishSpeaking() }
    }

    // MARK: Ciclo de vida

    func boot() async {
        applyVoiceSettings()
        permissionsGranted = await SpeechRecognizer.requestAuthorization()
        await loadModel()
    }

    func loadModel() async {
        mode = .offline
        await engine.load(settings.variant, instructions: instructions)
        guard engine.isReady else { return }
        mode = .idle
        if !greeted {
            greeted = true
            say(JarvisPersona.greeting(language: settings.language, honorific: settings.honorific))
        }
    }

    /// Reaplica idioma/voz/persona depois de mudanças nas configurações.
    func settingsChanged() async {
        applyVoiceSettings()
        if engine.loadedVariant != settings.variant {
            await loadModel()
        } else {
            engine.resetConversation(instructions: instructions)
        }
    }

    func newConversation() {
        cancelAll()
        lines.removeAll()
        engine.resetConversation(instructions: instructions)
        greeted = false
        if engine.isReady {
            greeted = true
            say(JarvisPersona.greeting(language: settings.language, honorific: settings.honorific))
        }
    }

    // MARK: Interação

    /// Toque no reator: começa a ouvir, encerra a escuta ou interrompe a fala.
    func reactorTapped() {
        switch mode {
        case .idle: startListening()
        case .listening: ears.stop(deliver: true)
        case .speaking, .thinking:
            cancelAll()
            startListening()
        case .offline: break
        }
    }

    func startListening() {
        guard engine.isReady else { return }
        guard permissionsGranted else {
            append(.system, "Permita microfone e reconhecimento de voz em Ajustes para falar comigo.")
            return
        }
        voice.stop()
        do {
            try ears.start(locale: settings.language.locale) { [weak self] text in
                self?.send(text)
            }
            mode = .listening
            haptic(.light)
        } catch {
            append(.system, error.localizedDescription)
            mode = .idle
        }
    }

    /// Envia um comando (falado ou digitado) ao Gemma e fala a resposta em streaming.
    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, engine.isReady else {
            if mode == .listening { mode = .idle }
            return
        }
        cancelAll()
        append(.user, prompt)
        let replyID = append(.jarvis, "")
        mode = .thinking
        haptic(.medium)

        let context = JarvisPersona.deviceContext(language: settings.language)
        let fullPrompt = "\(context)\n\(prompt)"

        generation = Task { [weak self] in
            guard let self else { return }
            var sentence = ""
            do {
                for try await chunk in self.engine.stream(fullPrompt) {
                    if Task.isCancelled { break }
                    self.update(replyID) { $0 += chunk }
                    sentence += chunk
                    // Fala cada frase assim que ela termina, sem esperar a resposta inteira.
                    while let cut = Self.sentenceBoundary(in: sentence) {
                        let ready = String(sentence[..<cut])
                        sentence = String(sentence[cut...])
                        self.speakChunk(ready)
                    }
                }
                if !Task.isCancelled { self.speakChunk(sentence) }
            } catch where !Task.isCancelled {
                let message =
                    "Perdão, \(self.settings.honorific). Falha nos sistemas: \(error.localizedDescription)"
                self.update(replyID) { $0 = message }
                self.speakChunk(message)
            } catch {}
            // Uma geração cancelada não pode mexer no estado da geração que a substituiu.
            guard !Task.isCancelled else { return }
            self.generation = nil
            if !self.voice.isSpeaking { self.finishTurn() }
        }
    }

    // MARK: Internos

    private var instructions: String {
        JarvisPersona.instructions(language: settings.language, honorific: settings.honorific)
    }

    private func applyVoiceSettings() {
        voice.language = settings.language
        voice.voiceIdentifier = settings.voiceIdentifier
        voice.rate = settings.speechRate
    }

    private func say(_ text: String) {
        append(.jarvis, text)
        speakChunk(text)
    }

    private func speakChunk(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        mode = .speaking
        voice.speak(text)
    }

    private func didFinishSpeaking() {
        guard mode == .speaking else { return }
        // Ainda gerando? Volta a "pensar" até a próxima frase chegar.
        if generation != nil {
            mode = .thinking
            return
        }
        finishTurn()
    }

    /// Fim da resposta: volta à espera ou, em conversa contínua, já começa a ouvir.
    private func finishTurn() {
        mode = .idle
        if settings.continuousConversation, lines.last?.speaker == .jarvis {
            startListening()
        }
    }

    private func cancelAll() {
        generation?.cancel()
        generation = nil
        ears.stop(deliver: false)
        voice.stop()
        if engine.isReady { mode = .idle }
    }

    @discardableResult
    private func append(_ speaker: Line.Speaker, _ text: String) -> UUID {
        let line = Line(speaker: speaker, text: text)
        lines.append(line)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        return line.id
    }

    private func update(_ id: UUID, _ change: (inout String) -> Void) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        change(&lines[index].text)
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// Posição logo após o fim da primeira frase completa (., !, ?, … ou quebra de linha).
    static func sentenceBoundary(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            if char == "\n" { return next }
            if ".!?…".contains(char) {
                // Evita cortar números decimais ("3.5") e exige espaço depois da pontuação.
                if next < text.endIndex, text[next].isWhitespace {
                    return next
                }
            }
            index = next
        }
        return nil
    }
}
