import AVFoundation
import Speech

/// Reconhecimento de fala (no aparelho quando suportado) com medidor de nível do microfone
/// e detecção automática de fim de frase por silêncio.
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
    private var onFinish: ((String) -> Void)?

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

    func start(locale: Locale, onFinish: @escaping (String) -> Void) throws {
        stop(deliver: false)
        transcript = ""
        self.onFinish = onFinish

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechError.unavailable
        }
        self.recognizer = recognizer

        try AudioSessionManager.activate()

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

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
        armSilenceTimer(after: noSpeechTimeout)

        task = recognizer.recognitionTask(
            with: request, resultHandler: Self.makeResultHandler(owner: self))
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard isListening else { return }
        if let text {
            transcript = text
            armSilenceTimer()
        }
        if isFinal || failed { stop(deliver: true) }
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
        guard isListening || task != nil else { return }

        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        level = 0

        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
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

enum AudioSessionManager {
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}
