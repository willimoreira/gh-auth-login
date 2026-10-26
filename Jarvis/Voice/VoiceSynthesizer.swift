import AVFoundation

/// Voz do J.A.R.V.I.S.: fala frase a frase enquanto o Gemma ainda está gerando,
/// e expõe um "nível" sintético para animar o reator durante a fala.
@MainActor
@Observable
final class VoiceSynthesizer: NSObject {

    private(set) var isSpeaking = false
    private(set) var level: Float = 0

    var voiceIdentifier = ""
    var language: JarvisLanguage = .portuguese
    var rate: Float = 0.52

    /// Chamado quando a fila de falas termina.
    var onFinishedSpeaking: (@MainActor () -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var pending = 0
    private var decay: Timer?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        try? AudioSessionManager.activate()

        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = voice()
        utterance.rate = rate
        utterance.pitchMultiplier = language == .english ? 0.92 : 0.9
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0.05
        pending += 1
        isSpeaking = true
        synthesizer.speak(utterance)
        startDecay()
    }

    func stop() {
        pending = 0
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        level = 0
    }

    // MARK: Vozes

    /// Vozes instaladas para o idioma, das de maior qualidade para as de menor.
    static func voices(for language: JarvisLanguage) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language.rawValue }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    private func voice() -> AVSpeechSynthesisVoice? {
        if !voiceIdentifier.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return chosen
        }
        let candidates = Self.voices(for: language)
        // Jarvis tem voz masculina e grave: prefira masculinas (ex.: "Daniel" en-GB, "Felipe" pt-BR).
        let preferredNames = ["Daniel", "Arthur", "Felipe", "Eddy", "Reed"]
        if let named = candidates.first(where: { preferredNames.contains($0.name) && $0.gender == .male }) {
            return named
        }
        return candidates.first(where: { $0.gender == .male })
            ?? candidates.first
            ?? AVSpeechSynthesisVoice(language: language.rawValue)
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

    // MARK: Animação

    private func pulse() {
        level = Float.random(in: 0.55...1.0)
    }

    private func startDecay() {
        guard decay == nil else { return }
        decay = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.level *= 0.86
                if !self.isSpeaking, self.level < 0.01 {
                    self.level = 0
                    self.decay?.invalidate()
                    self.decay = nil
                }
            }
        }
    }

    private func utteranceFinished() {
        guard pending > 0 else { return }
        pending -= 1
        if pending == 0 {
            isSpeaking = false
            onFinishedSpeaking?()
        }
    }
}

extension VoiceSynthesizer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.pulse() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.utteranceFinished() }
    }
}
