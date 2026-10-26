import AVFoundation
import Speech

/// Reconhecimento de fala (no aparelho quando suportado) com medidor de nível do microfone
/// e detecção automática de fim de frase por silêncio.
///
/// No modo de prontidão (`wakeWords`), fica ouvindo sem parar até ouvir "Jarvis" e então
/// entrega só o comando que vem depois do nome.
@MainActor
@Observable
final class SpeechRecognizer {

    private(set) var transcript = ""
    private(set) var isListening = false
    /// Nível do microfone normalizado 0...1 — alimenta a animação do reator.
    private(set) var level: Float = 0

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var restartTimer: Timer?
    private var onFinish: ((String) -> Void)?
    private var onWake: (() -> Void)?
    private var wakeWords: [String]?
    private var wakeDetected = false

    /// Ouvindo à espera da palavra de ativação (ainda não chamado).
    var isStandby: Bool { isListening && wakeWords != nil && !wakeDetected }

    /// Segundos de silêncio, depois de ouvir alguma fala, para encerrar a captura.
    var silenceTimeout: TimeInterval = 1.4
    /// Desiste de ouvir se ninguém falar nada nesse intervalo.
    var noSpeechTimeout: TimeInterval = 8

    nonisolated static func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    func start(
        locale: Locale, wakeWords: [String]? = nil, onWake: (() -> Void)? = nil,
        onFinish: @escaping (String) -> Void
    ) throws {
        stop(deliver: false)
        transcript = ""
        self.onFinish = onFinish
        self.onWake = onWake
        self.wakeWords = wakeWords
        wakeDetected = false

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechError.unavailable
        }
        self.recognizer = recognizer

        try AudioSessionManager.activateForListening()

        beginRecognition()
        audioEngine.prepare()
        try audioEngine.start()
        isListening = true

        if wakeWords == nil {
            armSilenceTimer(after: noSpeechTimeout)
        } else {
            armRestartTimer()
        }
    }

    private func beginRecognition() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0, bufferSize: 1024, format: format,
            block: Self.makeTapBlock(request: request, owner: self))

        task = recognizer.recognitionTask(
            with: request, resultHandler: Self.makeResultHandler(owner: self))
    }

    /// Em prontidão, recomeça o reconhecimento de tempos em tempos para não acumular texto
    /// (e não esbarrar no limite de duração de uma sessão de reconhecimento).
    private func restartRecognition(keepingWake: Bool = false) {
        guard isListening else { return }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        transcript = ""
        beginRecognition()
        if !keepingWake { armRestartTimer() }
    }

    private func armRestartTimer() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isStandby else { return }
                self.restartRecognition()
            }
        }
    }

    /// O texto depois da última menção ao nome ("…Jarvis, que horas são?" → "que horas são?"),
    /// ou `nil` se o nome não foi dito.
    static func command(after wakeWords: [String], in text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let normalized = words.map {
            $0.lowercased()
                .folding(options: .diacriticInsensitive, locale: nil)
                .trimmingCharacters(in: .punctuationCharacters)
        }
        guard let index = normalized.lastIndex(where: { word in
            wakeWords.contains { word == $0 || word.hasPrefix($0) }
        }) else { return nil }
        return words[(index + 1)...].joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard isListening else { return }
        if let wakeWords {
            handleWake(wakeWords, text: text, isFinal: isFinal, failed: failed)
            return
        }
        if let text {
            transcript = text
            armSilenceTimer()
        }
        if isFinal || failed { stop(deliver: true) }
    }

    private func handleWake(_ wakeWords: [String], text: String?, isFinal: Bool, failed: Bool) {
        let command = text.flatMap { Self.command(after: wakeWords, in: $0) }
        if !wakeDetected {
            guard let command else {
                if isFinal || failed { restartRecognition() }
                return
            }
            wakeDetected = true
            restartTimer?.invalidate()
            onWake?()
            transcript = command
        } else if let spoken = command ?? text {
            // Numa sessão reiniciada depois do nome, o texto inteiro já é o comando.
            transcript = spoken
        }
        // Depois do nome, espera o comando terminar (ou um pouco mais, se ainda não veio).
        armSilenceTimer(after: transcript.isEmpty ? noSpeechTimeout : silenceTimeout)
        guard isFinal || failed else { return }
        if transcript.isEmpty {
            restartRecognition(keepingWake: true)
        } else {
            stop(deliver: true)
        }
    }

    // Os callbacks de áudio e de reconhecimento rodam fora da main thread; por isso são
    // criados em contexto `nonisolated` e só voltam para a MainActor via Task.
    nonisolated private static func makeTapBlock(
        request: SFSpeechAudioBufferRecognitionRequest, owner: SpeechRecognizer
    ) -> AVAudioNodeTapBlock {
        { [weak owner] buffer, _ in
            request.append(buffer)
            let value = rms(buffer)
            Task { @MainActor in owner?.level = value }
        }
    }

    nonisolated private static func makeResultHandler(
        owner: SpeechRecognizer
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in owner?.handle(text: text, isFinal: isFinal, failed: failed) }
        }
    }

    /// Para de ouvir. Se `deliver`, entrega o texto reconhecido ao callback.
    func stop(deliver: Bool = true) {
        silenceTimer?.invalidate()
        silenceTimer = nil
        restartTimer?.invalidate()
        restartTimer = nil
        let wasStandby = isStandby
        wakeWords = nil
        wakeDetected = false
        onWake = nil
        guard isListening || task != nil else { return }

        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        level = 0

        let text = wasStandby ? "" : transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = onFinish
        onFinish = nil
        if deliver { callback?(text) }  // texto vazio = ninguém falou
    }

    private func armSilenceTimer(after interval: TimeInterval? = nil) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: interval ?? silenceTimeout, repeats: false
        ) {
            [weak self] _ in
            Task { @MainActor in self?.stop(deliver: true) }
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(count))
        // Converte para escala perceptual 0...1 (~ -50 dB a 0 dB).
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 50))
    }
}

enum SpeechError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Reconhecimento de voz indisponível para este idioma."
    }
}

/// Duas configurações de áudio: uma para ouvir (microfone, inclusive o dos AirPods) e outra
/// para falar (saída de mídia: volume cheio e AirPods em alta qualidade).
/// O modo "chamada de voz" foi abandonado porque, sem processamento de voz, baixa o volume.
enum AudioSessionManager {
    static func activateForListening() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Retorna `true` se a configuração mudou (o engine de saída precisa ser reiniciado).
    @discardableResult
    static func activateForSpeaking() throws -> Bool {
        let session = AVAudioSession.sharedInstance()
        let changed = session.category != .playback
        if changed {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        return changed
    }
}
