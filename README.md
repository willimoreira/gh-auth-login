# J.A.R.V.I.S. para iPhone — com Gemma 4 rodando no aparelho

Assistente virtual inspirado no J.A.R.V.I.S. do Tony Stark: interface HUD com reator arc animado,
conversa por voz em português (ou inglês britânico, como no filme) e o cérebro é o **Gemma 4**
do Google rodando **100% offline no iPhone** via [MLX Swift](https://github.com/ml-explore/mlx-swift-lm).

```
 ┌──────────── iPhone ─────────────────────────────────────────────┐
 │  🎙  SpeechRecognizer  (SFSpeechRecognizer no aparelho + nível do mic)
 │        │ texto
 │        ▼
 │  🧠  GemmaEngine  ── Gemma 4 E2B/E4B 4-bit · MLX · GPU Metal
 │        │ tokens em streaming
 │        ▼
 │  🔊  VoiceSynthesizer (AVSpeechSynthesizer, fala frase a frase)
 │        │
 │  💠  ArcReactorView reage a: ouvindo · processando · falando
 └─────────────────────────────────────────────────────────────────┘
```

## Recursos

- **Gemma 4 local**: `gemma-4-e2b-it-4bit` (~3,6 GB, padrão) ou `gemma-4-e4b-it-4bit` (~5 GB, mais esperto).
  Baixado do Hugging Face apenas na primeira execução; depois funciona em modo avião.
- **Voz completa**: toque no reator (ou no microfone), fale, e o Jarvis responde falando.
  A fala começa já na primeira frase gerada, sem esperar a resposta inteira.
- **Conversa contínua**: depois de responder, ele volta a ouvir sozinho (desligável).
- **Fim de fala automático**: detecta 1,4 s de silêncio e envia o comando.
- **Interromper**: toque no reator enquanto ele fala para cortá-lo e falar de novo.
- **Personalidade**: mordomo britânico, humor seco, chama você de "senhor" (configurável).
- **Sensores**: hora, data e bateria do iPhone vão como contexto em cada pergunta.
- **HUD**: reator arc com anéis girando em velocidades diferentes, equalizador radial que reage
  à voz, grade hexagonal, linha de varredura, cantoneiras e telemetria — azul em espera,
  branco-gelo ouvindo, âmbar processando.
- **Modo teclado** para usar em silêncio.

## Requisitos

| | |
|---|---|
| Mac | Xcode **26** ou mais novo |
| iPhone | iOS 17+; **8 GB de RAM recomendados** (iPhone 15 Pro, 16, 16 Pro, 17…). O E2B também roda em aparelhos de 6 GB, mais apertado. |
| Espaço | ~4 GB livres (E2B) ou ~6 GB (E4B) |

> O simulador do iOS **não** roda MLX na GPU — use um iPhone real.

## Como compilar

**Jeito rápido** — cole no Terminal do Mac (instala XcodeGen, baixa o código em `~/Developer/Jarvis`,
gera o projeto e abre o Xcode):

```bash
curl -fsSL https://raw.githubusercontent.com/willimoreira/gh-auth-login/claude/jarvis-virtual-assistant-gemma-e1v5u0/scripts/setup-mac.sh | bash
```

**Manual:**

```bash
brew install xcodegen
git clone <este repositório> && cd gh-auth-login
xcodegen generate          # gera Jarvis.xcodeproj a partir do project.yml
open Jarvis.xcodeproj
```

No Xcode:

1. Selecione o target **Jarvis › Signing & Capabilities** e escolha seu **Team** (Apple ID gratuito funciona).
2. Se pedir, clique em **Trust & Enable** para os macros do `MLXHuggingFace`.
3. Mude o esquema para **Release** (Product › Scheme › Edit Scheme › Run › Build Configuration) —
   em Debug o MLX fica bem mais lento.
4. Conecte o iPhone, ative o **Modo Desenvolvedor** nele e dê **Run**.

Na primeira abertura o app pede microfone e reconhecimento de voz, baixa o Gemma 4
(barra de progresso no HUD) e então cumprimenta você.

### Dica: a voz do filme

Em **Ajustes › Acessibilidade › Conteúdo Falado › Vozes**, baixe uma voz *Aprimorada* ou *Premium*.
Para o clima do filme, escolha idioma **English (British)** e a voz **Daniel** nas configurações do app.
Em português, as vozes masculinas são escolhidas automaticamente quando instaladas.

## Estrutura

```
project.yml                      # especificação do XcodeGen (pacotes SPM, Info.plist, entitlements)
Jarvis/
  App/JarvisApp.swift            # ponto de entrada
  Core/
    GemmaEngine.swift            # download, carga e streaming do Gemma 4 (MLX)
    JarvisAssistant.swift        # máquina de estados ouvir → pensar → falar
    JarvisPersona.swift          # personalidade (system prompt), saudação e sensores
    JarvisSettings.swift         # modelo, idioma, voz, tratamento, conversa contínua
  Voice/
    SpeechRecognizer.swift       # fala → texto, nível do microfone, detecção de silêncio
    VoiceSynthesizer.swift       # texto → fala, escolha de voz masculina, pulso p/ animação
  UI/
    ArcReactorView.swift         # reator arc animado (Canvas + TimelineView)
    HUDElements.swift            # fundo hexagonal, cantoneiras, painéis, barra de status
    ContentView.swift            # tela principal, histórico e progresso do download
    SettingsView.swift           # configurações
    Theme.swift                  # cores e fontes do HUD
```

O entitlement `com.apple.developer.kernel.increased-memory-limit` já está ativado para o iOS
permitir que o app use memória suficiente para o modelo.

## Próximos passos possíveis

- Palavra de ativação "Jarvis" sempre ouvindo.
- *Tool calling* do Gemma 4 para agir no aparelho (lembretes, calendário, lanterna, música).
- Visão: o Gemma 4 é multimodal — dá para mostrar a câmera e perguntar "Jarvis, o que é isso?".
- Atalhos da Siri / App Intents para abrir o Jarvis pelo botão de Ação.
