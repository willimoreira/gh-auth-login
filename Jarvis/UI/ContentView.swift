import SwiftUI

struct ContentView: View {
    @Environment(JarvisAssistant.self) private var jarvis
    @State private var typed = ""
    @State private var showSettings = false
    @State private var showKeyboard = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            HUDBackground()

            VStack(spacing: 14) {
                StatusBar(mode: jarvis.mode, modelName: jarvis.settings.variant.displayName)

                Spacer(minLength: 0)

                reactor

                Text(captionText)
                    .font(HUD.mono(12, weight: .medium))
                    .foregroundStyle(HUD.ice.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 34)
                    .animation(.easeInOut, value: captionText)

                Spacer(minLength: 0)

                if let pending = jarvis.tools.pending {
                    PendingActionCard(
                        summary: pending.summary,
                        onConfirm: { jarvis.confirmPendingAction() },
                        onCancel: { jarvis.cancelPendingAction() })
                    .transition(.opacity)
                }

                if case .ready = jarvis.engine.status {
                    TranscriptView(lines: jarvis.lines)
                        .frame(maxHeight: jarvis.tools.pending == nil ? 230 : 140)
                } else {
                    ModelStatusView(
                        status: jarvis.engine.status,
                        downloaded: jarvis.engine.downloadedBytes,
                        total: jarvis.engine.totalBytes
                    ) {
                        Task { await jarvis.loadModel() }
                    }
                }

                controls
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .presentationDetents([.large])
        }
        .sheet(item: Bindable(jarvis.tools.messaging).composeDraft) { draft in
            MessageComposeView(draft: draft) { _ in
                jarvis.tools.messaging.composeDraft = nil
            }
            .ignoresSafeArea()
        }
        .animation(.easeInOut, value: jarvis.tools.pending?.summary)
        .task { await jarvis.boot() }
    }

    private var reactor: some View {
        ArcReactorView(mode: jarvis.mode, energy: jarvis.energy)
            .frame(maxWidth: 320)
            .contentShape(Circle())
            .onTapGesture { jarvis.reactorTapped() }
            .accessibilityLabel("Reator: toque para falar com o Jarvis")
    }

    private var captionText: String {
        switch jarvis.mode {
        case .listening:
            jarvis.ears.transcript.isEmpty ? "Estou ouvindo, \(jarvis.settings.honorific)…" : jarvis.ears.transcript
        case .thinking: "Analisando…"
        case .offline: "Inicializando sistemas…"
        case .idle: "Toque no reator para falar"
        case .standby: "Diga “Jarvis” ou toque no reator"
        case .speaking: ""
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if showKeyboard {
                TextField("", text: $typed, prompt: Text("Digite um comando…").foregroundStyle(HUD.cyan.opacity(0.4)))
                    .font(HUD.mono(14))
                    .foregroundStyle(HUD.ice)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit(submitTyped)
                    .padding(10)
                    .overlay(CornerBrackets(length: 8).stroke(HUD.cyan, lineWidth: 1))
                hudButton("paperplane.fill", action: submitTyped)
                    .disabled(!jarvis.engine.isReady)
            } else {
                hudButton("arrow.counterclockwise") { jarvis.newConversation() }
                Spacer()
                hudButton(jarvis.mode == .listening ? "stop.fill" : "mic.fill", large: true) {
                    jarvis.reactorTapped()
                }
                .disabled(!jarvis.engine.isReady)
                Spacer()
                hudButton("gearshape.fill") { showSettings = true }
            }
            hudButton(showKeyboard ? "xmark" : "keyboard") {
                showKeyboard.toggle()
                inputFocused = showKeyboard
            }
        }
    }

    private func submitTyped() {
        let text = typed
        typed = ""
        jarvis.send(text)
    }

    private func hudButton(_ symbol: String, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 22 : 16, weight: .semibold))
                .foregroundStyle(HUD.cyan)
                .frame(width: large ? 64 : 44, height: large ? 64 : 44)
                .background(Circle().fill(HUD.cyan.opacity(0.08)))
                .overlay(Circle().stroke(HUD.cyan.opacity(0.7), lineWidth: 1))
                .glow(HUD.cyan, radius: large ? 8 : 4)
        }
        .buttonStyle(.plain)
    }
}

/// Histórico da conversa com efeito de terminal.
struct TranscriptView: View {
    var lines: [JarvisAssistant.Line]

    var body: some View {
        HUDPanel(title: "Registro de comunicação") {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(lines) { line in
                            row(line).id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lines) { _, newLines in
                    if let last = newLines.last {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ line: JarvisAssistant.Line) -> some View {
        let (tag, color): (String, Color) = switch line.speaker {
        case .user: ("VOCÊ", HUD.ice.opacity(0.7))
        case .jarvis: ("JARVIS", HUD.cyan)
        case .system: ("SISTEMA", HUD.amber)
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tag)
                .font(HUD.mono(9, weight: .bold))
                .foregroundStyle(color.opacity(0.7))
                .frame(width: 52, alignment: .leading)
            Text(line.text.isEmpty ? "▍" : line.text)
                .font(HUD.mono(13))
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }
}

/// Download/carga do Gemma 4 com barra de progresso no estilo HUD.
struct ModelStatusView: View {
    var status: GemmaEngine.Status
    var downloaded: Int64 = 0
    var total: Int64 = 0
    var retry: () -> Void

    var body: some View {
        HUDPanel(title: "Núcleo cognitivo · Gemma 4") {
            switch status {
            case .idle:
                Text("Aguardando inicialização…").font(HUD.mono(12)).foregroundStyle(HUD.ice)
            case .downloading(let fraction):
                Text("Baixando rede neural (apenas na primeira vez)…")
                    .font(HUD.mono(12)).foregroundStyle(HUD.ice)
                progressBar(fraction)
                Text(String(format: "%.0f%%", fraction * 100) + sizeText)
                    .font(HUD.mono(11, weight: .bold)).foregroundStyle(HUD.cyan)
                Text("Mantenha o app aberto e no Wi-Fi.")
                    .font(HUD.mono(10)).foregroundStyle(HUD.ice.opacity(0.6))
            case .loading:
                Text("Carregando pesos na GPU…").font(HUD.mono(12)).foregroundStyle(HUD.ice)
                progressBar(1)
            case .failed(let message):
                Text("Falha: \(message)").font(HUD.mono(11)).foregroundStyle(HUD.red)
                Button("TENTAR NOVAMENTE", action: retry)
                    .font(HUD.mono(12, weight: .bold))
                    .foregroundStyle(HUD.cyan)
            case .ready:
                EmptyView()
            }
        }
    }

    private var sizeText: String {
        guard total > 0 else { return "" }
        let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_000_000_000) }
        return " · \(gb(downloaded)) de \(gb(total)) GB"
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(HUD.cyan.opacity(0.12))
                Rectangle()
                    .fill(HUD.cyan)
                    .frame(width: geo.size.width * fraction)
                    .glow(HUD.cyan, radius: 6)
            }
        }
        .frame(height: 6)
        .animation(.linear, value: fraction)
    }
}
