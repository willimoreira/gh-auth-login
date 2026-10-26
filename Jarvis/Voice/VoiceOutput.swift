import AVFoundation

/// Saída de áudio do J.A.R.V.I.S.: toca os buffers de fala através de uma cadeia de efeitos
/// que dá o timbre de "IA saindo dos alto-falantes da oficina" e mede o nível real do som
/// para animar o reator.
///
///     player ─► EQ (corta graves, realça presença) ─► delay curtíssimo (timbre metálico)
///            ─► reverb de sala ─► mixer ─► alto-falante
@MainActor
final class VoiceOutput {

    static var format: AVAudioFormat { AudioLevel.voiceFormat }

    var onLevel: ((Float) -> Void)?
    /// Chamado quando o último buffer agendado termina de tocar.
    var onDrained: (() -> Void)?

    var effectEnabled = true {
        didSet { [eq, metallic, room].forEach { $0.bypass = !effectEnabled } }
    }

    var isBusy: Bool { pending > 0 }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 3)
    private let metallic = AVAudioUnitDelay()
    private let room = AVAudioUnitReverb()

    private var pending = 0
    /// Muda a cada `stop()` para ignorar callbacks de buffers descartados.
    private var generation = 0
    private var configObserver: NSObjectProtocol?

    init() {
        configureEffects()

        [player, eq, metallic, room].forEach { engine.attach($0) }
        engine.connect(player, to: eq, format: Self.format)
        engine.connect(eq, to: metallic, format: Self.format)
        engine.connect(metallic, to: room, format: Self.format)
        engine.connect(room, to: engine.mainMixerNode, format: Self.format)

        engine.mainMixerNode.installTap(
            onBus: 0, bufferSize: 1024, format: nil, block: Self.makeLevelTap(owner: self))

        // Fones/Bluetooth conectados mudam a rota de áudio e param o engine: religa sozinho.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartAfterRouteChange() }
        }
    }

    private func configureEffects() {
        // Corta o grave "de telefone" e destaca a presença da voz.
        let highPass = eq.bands[0]
        highPass.filterType = .highPass
        highPass.frequency = 140
        highPass.bypass = false

        let mud = eq.bands[1]
        mud.filterType = .parametric
        mud.frequency = 320
        mud.bandwidth = 1.0
        mud.gain = -3
        mud.bypass = false

        let presence = eq.bands[2]
        presence.filterType = .parametric
        presence.frequency = 3_200
        presence.bandwidth = 0.9
        presence.gain = 4
        presence.bypass = false

        // Atraso de ~11 ms com realimentação = filtro "pente": o brilho metálico de IA.
        metallic.delayTime = 0.011
        metallic.feedback = 45
        metallic.lowPassCutoff = 9_000
        metallic.wetDryMix = 16

        // Um pouco de ambiente, como se a voz viesse da oficina inteira.
        room.loadFactoryPreset(.mediumRoom)
        room.wetDryMix = 12
    }

    // MARK: Reprodução

    func play(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        ensureRunning()
        pending += 1
        player.scheduleBuffer(
            buffer, completionCallbackType: .dataPlayedBack,
            completionHandler: Self.makeCompletion(owner: self, generation: generation))
        if !player.isPlaying { player.play() }
    }

    func stop() {
        generation += 1
        pending = 0
        player.stop()
        onLevel?(0)
    }

    private func ensureRunning() {
        guard !engine.isRunning else { return }
        try? AudioSessionManager.activate()
        do {
            try engine.start()
        } catch {
            print("VoiceOutput: falha ao iniciar áudio: \(error)")
        }
    }

    private func restartAfterRouteChange() {
        let hadAudio = pending > 0
        ensureRunning()
        if hadAudio, !player.isPlaying { player.play() }
    }

    private func bufferFinished(generation: Int) {
        guard generation == self.generation, pending > 0 else { return }
        pending -= 1
        if pending == 0 {
            onLevel?(0)
            onDrained?()
        }
    }

    // MARK: Buffers

    /// Converte amostras float (ex.: saída do Kokoro) num buffer no formato interno.
    static func buffer(samples: [Float], sampleRate: Int) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
            let source = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        if source.sampleRate == AudioLevel.voiceFormat.sampleRate { return buffer }
        return PCMConverter().convert(buffer)
    }

    // Callbacks de áudio rodam fora da main thread; são criados em contexto `nonisolated`.

    nonisolated private static func makeCompletion(
        owner: VoiceOutput, generation: Int
    ) -> AVAudioPlayerNodeCompletionHandler {
        { [weak owner] _ in
            Task { @MainActor in owner?.bufferFinished(generation: generation) }
        }
    }

    nonisolated private static func makeLevelTap(owner: VoiceOutput) -> AVAudioNodeTapBlock {
        { [weak owner] buffer, _ in
            let value = AudioLevel.rms(buffer)
            Task { @MainActor in
                guard let owner, owner.pending > 0 else { return }
                owner.onLevel?(value)
            }
        }
    }
}

/// Converte buffers de qualquer formato (ex.: 22 kHz Int16 do AVSpeechSynthesizer)
/// para o formato interno da voz (`AudioLevel.voiceFormat`). Uma instância por fala, pois guarda estado.
final class PCMConverter {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = AudioLevel.voiceFormat
        if buffer.format == target { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

enum AudioLevel {
    /// Formato interno da voz: 24 kHz mono float (o mesmo do Kokoro, evita conversão).
    static let voiceFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    /// RMS do buffer em escala perceptual 0...1 (~ -50 dB a 0 dB).
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 50))
    }
}
